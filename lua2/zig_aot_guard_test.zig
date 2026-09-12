const std = @import("std");
const lua = @import("root.zig");
const ir = @import("vm_ir.zig");
const opt = @import("vm_optimize.zig");
const aot = @import("zig_aot.zig");
const exec = @import("vm_exec.zig");
const codec = @import("vm_codec.zig");
const aot_hint = @import("vm_aot_hint.zig");

const source =
    \\local seed=10
    \\local function predicted(x)return x+seed end
    \\local function other(x)return x+100 end
    \\local function invoke(f)return f(4) end
    \\return invoke(predicted),invoke(other),invoke
;

fn guardedProgram(a: std.mem.Allocator) !ir.Program {
    var chunk = try lua.parse(a, source);
    defer chunk.deinit();
    var program = try ir.lowerChunk(a, &chunk);
    errdefer program.deinit();
    _ = try opt.runAot(a, &program);
    var predicted: ?u32 = null;
    for (program.functions.items, 0..) |maybe, id| if (maybe) |function| {
        if (function.param_count == 1 and function.upvalues.items.len == 1)
            predicted = @intCast(id);
    };
    const target = predicted orelse return error.MissingPredictedFunction;
    var tagged = false;
    for (program.functions.items) |*maybe| if (maybe.*) |*function| {
        if (function.param_count != 1) continue;
        for (function.insts.items) |*inst| {
            if (inst.op != .call) continue;
            try aot_hint.set(inst, target);
            tagged = true;
        }
    };
    if (!tagged) return error.MissingDynamicCall;
    return program;
}

test "guarded AOT hint preserves VM semantics and emits one guard" {
    const a = std.testing.allocator;
    var program = try guardedProgram(a);
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const values = try vm.executeRoot(&program, &.{});
    defer exec.Vm.freeResults(values);
    try std.testing.expectEqual(@as(f64, 14), values[0].number);
    try std.testing.expectEqual(@as(f64, 104), values[1].number);
    const generated = try aot.generate(a, &program);
    defer a.free(generated.source);
    try std.testing.expectEqual(@as(u64, 1), generated.stats.guarded_calls);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, ".callKnownDirect(") != null);
}

test "proven AOT call emits direct target without an identity dispatch" {
    const a = std.testing.allocator;
    var program = try guardedProgram(a);
    defer program.deinit();
    for (program.functions.items) |*maybe| if (maybe.*) |*function| {
        for (function.insts.items) |*inst| if (aot_hint.target(inst.*)) |target| {
            aot_hint.clear(inst);
            try aot_hint.setDirect(inst, target);
        };
    };
    const generated = try aot.generate(a, &program);
    defer a.free(generated.source);
    try std.testing.expectEqual(@as(u64, 1), generated.stats.direct_calls);
    try std.testing.expectEqual(@as(u64, 0), generated.stats.guarded_calls);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "const callable_") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, ".callDirectFunction(") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, ".invokeKnown(") == null);
}

test "AOT call hints are not serialized into VM bytecode" {
    const a = std.testing.allocator;
    var program = try guardedProgram(a);
    defer program.deinit();
    const bytes = try codec.serialize(a, &program);
    defer a.free(bytes);
    var restored = try codec.deserialize(a, bytes);
    defer restored.deinit();
    for (restored.functions.items) |maybe| if (maybe) |function|
        for (function.insts.items) |inst|
            try std.testing.expectEqual(@as(?u32, null), aot_hint.target(inst));
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.Usage;
    const a = std.heap.smp_allocator;
    var program = try guardedProgram(a);
    defer program.deinit();
    const generated = try aot.generate(a, &program);
    defer a.free(generated.source);
    var file = try std.Io.Dir.cwd().createFile(init.io, args[1], .{ .truncate = true });
    defer file.close(init.io);
    try file.writePositionalAll(init.io, generated.source, 0);
    std.debug.print("GUARD_AOT target_count={d} bytes={d}\n", .{
        generated.stats.guarded_calls,
        generated.source.len,
    });
}
