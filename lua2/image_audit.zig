const std = @import("std");
const codec = @import("vm_codec.zig");
const ir = @import("vm_ir.zig");
const wire = @import("vm_wire.zig");
const verify = @import("vm_verify.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.Usage;
    var file = try std.Io.Dir.cwd().openFile(init.io, args[1], .{});
    defer file.close(init.io);
    const stat = try file.stat(init.io);
    const bytes = try std.posix.mmap(null, @intCast(stat.size), .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
    defer std.posix.munmap(bytes);
    const a = std.heap.smp_allocator;
    var program = try codec.deserializeBorrowed(a, bytes);
    defer program.deinit();
    try verify.run(a, &program);
    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(a);
    var string_bytes: u64 = 0;
    var duplicate_strings: u64 = 0;
    var contiguous = true;
    var expected: ?usize = null;
    for (program.strings.items) |text| {
        if (expected) |address| if (address != @intFromPtr(text.ptr)) {
            contiguous = false;
        };
        expected = @intFromPtr(text.ptr) + text.len;
        string_bytes += text.len;
        const entry = try names.getOrPut(a, text);
        if (entry.found_existing) duplicate_strings += 1;
    }
    var nodes = [_]u64{0} ** @typeInfo(ir.ConstNode).@"union".fields.len;
    for (program.constants.items) |node| nodes[@intFromEnum(std.meta.activeTag(node))] += 1;
    var instructions: u64 = 0;
    var frame_slots: u64 = 0;
    var instruction_bytes: u64 = 0;
    var op_counts = [_]u64{0} ** @typeInfo(ir.Opcode).@"enum".fields.len;
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(a);
    for (program.functions.items) |maybe| if (maybe) |function| {
        instructions += function.insts.items.len;
        frame_slots += function.reg_count;
        scratch.clearRetainingCapacity();
        for (function.insts.items, 0..) |inst, pc| {
            op_counts[@intFromEnum(inst.op)] += 1;
            try wire.writeInst(&scratch, a, @intCast(pc), inst);
        }
        instruction_bytes += scratch.items.len;
    };
    const encoded = try codec.serialize(a, &program);
    defer a.free(encoded);
    if (!std.mem.eql(u8, bytes, encoded)) return error.UnstableRoundtrip;
    if (!contiguous or duplicate_strings != 0) return error.InvalidGlobalStringPool;
    std.debug.print("IMAGE bytes={d} modules={d} functions={d} instructions={d} instruction_bytes={d} registers={d}\n", .{ bytes.len, program.module_roots.items.len, program.functions.items.len, instructions, instruction_bytes, frame_slots });
    std.debug.print("STRINGS count={d} bytes={d} duplicates={d} contiguous={}\n", .{ program.strings.items.len, string_bytes, duplicate_strings, contiguous });
    inline for (@typeInfo(ir.ConstNode).@"union".fields, 0..) |field, index| std.debug.print("CONSTANT {s} {d}\n", .{ field.name, nodes[index] });
    inline for (@typeInfo(ir.Opcode).@"enum".fields, 0..) |field, index| if (op_counts[index] != 0) {
        std.debug.print("OP {s} {d}\n", .{ field.name, op_counts[index] });
    };
    std.debug.print("ROUNDTRIP exact=true verifier=pass\n", .{});
}
