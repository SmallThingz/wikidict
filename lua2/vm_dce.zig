const std = @import("std");
const ir = @import("vm_ir.zig");
const lua = @import("root.zig");
const inline_pass = @import("vm_inline.zig");
const exec = @import("vm_exec.zig");
const rt = @import("vm_runtime.zig");

pub fn removeUnreachableFunctions(allocator: std.mem.Allocator, program: *ir.Program) !u32 {
    if (program.functions.items.len == 0) return 0;
    if (program.root_function >= program.functions.items.len) return error.BadRootFunction;
    const reachable = try allocator.alloc(bool, program.functions.items.len);
    defer allocator.free(reachable);
    @memset(reachable, false);
    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(allocator);
    reachable[program.root_function] = true;
    try queue.append(allocator, program.root_function);
    if (program.module_roots.items.len != 0 and program.function_modules.items.len != program.functions.items.len) return error.BadModuleMap;
    for (program.module_roots.items) |root| {
        if (root >= reachable.len) return error.BadRootFunction;
        if (!reachable[root]) {
            reachable[root] = true;
            try queue.append(allocator, root);
        }
    }
    while (queue.pop()) |function_id| {
        const function = program.functions.items[function_id] orelse return error.IncompleteProgram;
        for (function.insts.items) |inst| {
            const target = switch (inst.op) {
                .closure, .load_function, .register_function => inst.aux,
                .direct_call, .direct_call_vararg, .call_scoped, .call_scoped_vararg, .call_local, .call_local_vararg => inst.a,
                else => continue,
            };
            if (target >= reachable.len) return error.BadFunctionReference;
            if (!reachable[target]) {
                reachable[target] = true;
                try queue.append(allocator, target);
            }
        }
    }

    const remap = try allocator.alloc(u32, program.functions.items.len);
    defer allocator.free(remap);
    @memset(remap, std.math.maxInt(u32));
    var next: u32 = 0;
    for (reachable, 0..) |keep, old| if (keep) {
        remap[old] = next;
        next += 1;
    };

    var compact: std.ArrayList(?ir.Function) = .empty;
    errdefer {
        for (compact.items) |*maybe| if (maybe.*) |*function| function.deinit(allocator);
        compact.deinit(allocator);
    }
    try compact.ensureTotalCapacity(allocator, next);
    for (program.functions.items, 0..) |*maybe, old| {
        if (!reachable[old]) {
            if (maybe.*) |*function| function.deinit(allocator);
            maybe.* = null;
            continue;
        }
        const function = maybe.* orelse return error.IncompleteProgram;
        maybe.* = null;
        for (function.insts.items) |*inst| switch (inst.op) {
            .closure, .load_function, .register_function => inst.aux = remap[inst.aux],
            .direct_call, .direct_call_vararg, .call_scoped, .call_scoped_vararg, .call_local, .call_local_vararg => inst.a = remap[inst.a],
            else => {},
        };

        try compact.append(allocator, function);
    }
    const removed: u32 = @intCast(program.functions.items.len - compact.items.len);
    program.functions.deinit(allocator);
    program.functions = compact;
    program.root_function = remap[program.root_function];
    for (program.module_roots.items) |*root| root.* = remap[root.*];
    if (program.function_modules.items.len != 0) {
        var out: usize = 0;
        for (reachable, 0..) |keep, old| if (keep) {
            program.function_modules.items[out] = program.function_modules.items[old];
            out += 1;
        };
        program.function_modules.shrinkRetainingCapacity(out);
    }

    return removed;
}

fn expectSame(source: []const u8) !void {
    var chunk_a = try lua.parse(std.testing.allocator, source);
    defer chunk_a.deinit();
    var chunk_b = try lua.parse(std.testing.allocator, source);
    defer chunk_b.deinit();
    var baseline = try ir.lowerChunk(std.testing.allocator, &chunk_a);
    defer baseline.deinit();
    var optimized = try ir.lowerChunk(std.testing.allocator, &chunk_b);
    defer optimized.deinit();
    _ = try inline_pass.run(std.testing.allocator, &optimized);
    _ = try removeUnreachableFunctions(std.testing.allocator, &optimized);

    var arena_a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_a.deinit();
    var arena_b = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_b.deinit();
    var vm_a = try exec.Vm.init(arena_a.allocator());
    var vm_b = try exec.Vm.init(arena_b.allocator());
    const a = try vm_a.executeRoot(&baseline, &.{});
    defer exec.Vm.freeResults(a);
    const b = try vm_b.executeRoot(&optimized, &.{});
    defer exec.Vm.freeResults(b);
    try std.testing.expectEqual(a.len, b.len);
    for (a, b) |lhs, rhs| try std.testing.expect(rt.rawEqual(lhs, rhs));
}

test "inlined function body becomes unreachable and is removed" {
    const source =
        \\local function add1(x)
        \\  return x + 1
        \\end
        \\local y = add1(4)
        \\return y
    ;
    var chunk = try lua.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var program = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer program.deinit();
    try std.testing.expectEqual(@as(usize, 2), program.functions.items.len);
    _ = try inline_pass.run(std.testing.allocator, &program);
    const removed = try removeUnreachableFunctions(std.testing.allocator, &program);
    try std.testing.expectEqual(@as(u32, 1), removed);
    try std.testing.expectEqual(@as(usize, 1), program.functions.items.len);
}

test "inlining plus function DCE preserves captured mutation" {
    try expectSame(
        \\local x = 3
        \\local function f(n) x = x + n; return x end
        \\local y = f(5)
        \\return y, x
    );
}
