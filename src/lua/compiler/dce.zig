const std = @import("std");
const ir = @import("ir.zig");
const inline_pass = @import("inline.zig");

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
