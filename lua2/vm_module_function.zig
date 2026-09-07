const std = @import("std");
const ir = @import("vm_ir.zig");
const cfg = @import("vm_graph.zig");

pub const Stats = struct {
    functions: u64 = 0,
    captured_functions: u64 = 0,
    cyclic: u64 = 0,
    detached: u64 = 0,
    outer_upvalue: u64 = 0,
};

fn reaches(a: std.mem.Allocator, graph: *const cfg.Graph, start: u32, target: u32) !bool {
    const seen = try a.alloc(bool, graph.blocks.items.len);
    defer a.free(seen);
    @memset(seen, false);
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(a);
    try work.append(a, start);
    seen[start] = true;
    while (work.pop()) |block| {
        if (block == target) return true;
        for (graph.blocks.items[block].succ) |next_opt| if (next_opt) |next| {
            if (seen[next]) continue;
            seen[next] = true;
            try work.append(a, next);
        };
    }
    return false;
}
fn cyclicBlock(a: std.mem.Allocator, graph: *const cfg.Graph, block: u32) !bool {
    for (graph.blocks.items[block].succ) |next_opt| if (next_opt) |next| {
        if (try reaches(a, graph, next, block)) return true;
    };
    return false;
}

const CaptureStatus = enum { safe, detached, outer_upvalue };
fn captureStatus(root: *const ir.Function, child: *const ir.Function) CaptureStatus {
    for (child.upvalues.items) |up| {
        if (up.source != .local or up.index >= root.reg_count) return .outer_upvalue;
        for (root.insts.items) |inst| {
            if (inst.op == .detach_cell and inst.a == up.index) return .detached;
        }
    }
    return .safe;
}

pub fn run(a: std.mem.Allocator, p: *ir.Program) !Stats {
    var stats = Stats{};
    if (p.module_roots.items.len == 0) return stats;
    for (p.module_roots.items) |root_id| {
        if (root_id >= p.functions.items.len) return error.BadFunctionReference;
        const root = &(p.functions.items[root_id] orelse return error.IncompleteProgram);
        var graph = try cfg.build(a, root);
        defer graph.deinit();
        const cyclic = try a.alloc(?bool, graph.blocks.items.len);
        defer a.free(cyclic);
        @memset(cyclic, null);
        for (root.insts.items, 0..) |*inst, pc| {
            if (inst.op != .closure) continue;
            if (inst.aux >= p.functions.items.len) return error.BadFunctionReference;
            const child = p.functions.items[inst.aux] orelse return error.IncompleteProgram;
            const block = graph.block_of_pc[pc];
            const repeats = if (cyclic[block]) |value| value else blk: {
                const value = try cyclicBlock(a, &graph, block);
                cyclic[block] = value;
                break :blk value;
            };
            if (repeats) {
                stats.cyclic += 1;
                continue;
            }
            switch (captureStatus(root, &child)) {
                .safe => {},
                .detached => {
                    stats.detached += 1;
                    continue;
                },
                .outer_upvalue => {
                    stats.outer_upvalue += 1;
                    continue;
                },
            }
            inst.op = .load_function;
            stats.functions += 1;
            stats.captured_functions += @intFromBool(child.upvalues.items.len != 0);
        }
    }
    return stats;
}

const lua = @import("root.zig");
const exec = @import("vm_exec.zig");
const link = @import("vm_link_image.zig");
const rt = @import("vm_runtime.zig");

fn linked(source: []const u8) !link.Image {
    var chunk = try lua.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var program = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer program.deinit();
    var image = link.Image.init(std.testing.allocator);
    errdefer image.deinit();
    _ = try image.appendModule(&program);
    return image;
}

fn callNumber(vm: *exec.Vm, value: rt.Value, args: []const rt.Value) !f64 {
    const out = try vm.callValue(value, args);
    defer exec.Vm.freeResults(out);
    if (out.len != 1 or out[0] != .number) return error.BadTestResult;
    return out[0].number;
}
test "module singleton functions become numeric values while loop closures remain distinct" {
    var image = try linked("local export={}; function export.once(x)return x+1 end; for i=1,2 do export[i]=function()return i end end; return export");
    defer image.deinit();
    const stats = try run(std.testing.allocator, &image.program);
    try std.testing.expectEqual(@as(u64, 1), stats.functions);
    var loads: usize = 0;
    var closures: usize = 0;
    const root = image.program.functions.items[image.program.module_roots.items[0]].?;
    for (root.insts.items) |inst| {
        loads += @intFromBool(inst.op == .load_function);
        closures += @intFromBool(inst.op == .closure);
    }
    try std.testing.expectEqual(@as(usize, 1), loads);
    try std.testing.expect(closures != 0);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const out = try vm.executeRoot(&image.program, &.{});
    defer exec.Vm.freeResults(out);
    const once = out[0].table.rawGet(.{ .string = "once" }).?;
    try std.testing.expectEqual(@as(f64, 5), try callNumber(&vm, once, &.{.{ .number = 4 }}));
    try std.testing.expect(!rt.rawEqual(out[0].table.rawGet(.{ .number = 1 }).?, out[0].table.rawGet(.{ .number = 2 }).?));
}
test "captured module functions share one environment without closure objects" {
    var image = try linked("local n=1; local export={}; function export.add(x)n=n+x;return n end; function export.get()return n end; return export");
    defer image.deinit();
    const stats = try run(std.testing.allocator, &image.program);
    try std.testing.expectEqual(@as(u64, 2), stats.functions);
    try std.testing.expectEqual(@as(u64, 2), stats.captured_functions);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const root = try vm.executeRoot(&image.program, &.{});
    defer exec.Vm.freeResults(root);
    const table = root[0].table;
    const add = table.rawGet(.{ .string = "add" }).?;
    const get = table.rawGet(.{ .string = "get" }).?;
    try std.testing.expect(add == .function and get == .function);
    try std.testing.expect(add.function.env == get.function.env);
    try std.testing.expectEqual(@as(f64, 4), try callNumber(&vm, add, &.{.{ .number = 3 }}));
    try std.testing.expectEqual(@as(f64, 4), try callNumber(&vm, get, &.{}));
    try std.testing.expectEqual(@as(f64, 9), try callNumber(&vm, add, &.{.{ .number = 5 }}));
}
test "module function identity belongs to one module activation" {
    var image = try linked("local n=1; return function()n=n+1;return n end");
    defer image.deinit();
    const stats = try run(std.testing.allocator, &image.program);
    try std.testing.expectEqual(@as(u64, 1), stats.captured_functions);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const first = try vm.executeRoot(&image.program, &.{});
    defer exec.Vm.freeResults(first);
    const second = try vm.executeRoot(&image.program, &.{});
    defer exec.Vm.freeResults(second);
    try std.testing.expect(first[0] == .function and second[0] == .function);
    try std.testing.expect(!rt.rawEqual(first[0], second[0]));
    try std.testing.expectEqual(@as(f64, 2), try callNumber(&vm, first[0], &.{}));
    try std.testing.expectEqual(@as(f64, 2), try callNumber(&vm, second[0], &.{}));
}

test "detached captured cells retain ordinary closure identity" {
    var image = try linked("local n=1; local function f()return n end; return f");
    defer image.deinit();
    const root_id = image.program.module_roots.items[0];
    var root = &image.program.functions.items[root_id].?;
    var closure_pc: usize = 0;
    var capture_reg: u32 = 0;
    for (root.insts.items, 0..) |inst, pc| if (inst.op == .closure) {
        closure_pc = pc;
        const child = image.program.functions.items[inst.aux].?;
        capture_reg = child.upvalues.items[0].index;
        break;
    };
    var insts: std.ArrayList(ir.Inst) = .empty;
    for (root.insts.items, 0..) |inst, pc| {
        try insts.append(std.testing.allocator, inst);
        if (pc == closure_pc) try insts.append(std.testing.allocator, .{ .op = .detach_cell, .a = capture_reg });
    }
    root.insts.deinit(std.testing.allocator);
    root.insts = insts;
    const stats = try run(std.testing.allocator, &image.program);
    try std.testing.expectEqual(@as(u64, 0), stats.functions);
    try std.testing.expectEqual(@as(u64, 1), stats.detached);
    var still_closure = false;
    for (root.insts.items) |inst| still_closure = still_closure or inst.op == .closure;
    try std.testing.expect(still_closure);
}
