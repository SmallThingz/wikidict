const std = @import("std");
const ir = @import("ir.zig");
const abi = @import("../abi/globals.zig");
pub const Stats = struct { loads: u64 = 0, stores: u64 = 0, user_slots: u64 = 0, legacy: u64 = 0 };

pub fn run(a: std.mem.Allocator, p: *ir.Program) !Stats {
    var stats = Stats{};
    const linked = p.module_roots.items.len != 0;
    if (p.global_shape != null) return stats;
    var names: std.StringHashMapUnmanaged(u32) = .empty;
    defer names.deinit(a);
    var shape = ir.Shape{ .field_count = abi.count };
    var owned = true;
    defer if (owned) shape.deinit(a);
    var reflected = false;
    if (linked) for (abi.names, 0..) |name, slot| {
        try names.put(a, name, @intCast(slot));
        try shape.field_keys.append(a, try p.internOwned(name));
    };
    for (p.functions.items) |*maybe| if (maybe.*) |*f| for (f.insts.items) |*inst| {
        if (inst.op == .get_global_slot and inst.aux == abi.id("_G")) reflected = true;
        if (inst.op != .get_global and inst.op != .set_global) continue;
        const name = p.strings.items[inst.aux];
        reflected = reflected or std.mem.eql(u8, name, "_G") or std.mem.eql(u8, name, "getfenv") or std.mem.eql(u8, name, "setfenv");
        const slot = if (abi.find(name)) |id| id else if (linked) blk: {
            if (names.get(name)) |id| break :blk id;
            const id = shape.field_count;
            try names.put(a, name, id);
            try shape.field_keys.append(a, inst.aux);
            shape.field_count += 1;
            stats.user_slots += 1;
            break :blk id;
        } else {
            stats.legacy += 1;
            continue;
        };
        if (inst.op == .get_global) {
            inst.op = .get_global_slot;
            stats.loads += 1;
        } else {
            inst.op = .set_global_slot;
            stats.stores += 1;
        }
        inst.aux = slot;
    };
    if (linked) {
        // Names are needed only when this image can expose its environment.
        // The slot layout and native ABI do not depend on those names.
        if (!reflected) shape.field_keys.clearRetainingCapacity();
        shape.open = reflected;
        p.global_shape = @intCast(p.shapes.items.len);
        try p.shapes.append(a, shape);
        owned = false;
    }
    return stats;
}
