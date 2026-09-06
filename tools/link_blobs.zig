//! Link a freshly staged blob directory. Never invokes the VM or downloads data.
const std = @import("std");
const enc = @import("encoder");
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or args.len > 3) return error.Usage;
    const stats = try enc.name_linker.linkRoot(init.io, init.gpa, args[1], if (args.len == 3) args[2] else null);
    std.debug.print("LINKED symbols={d} template_programs={d} functions={d} modules={d} parser_functions={d} records={d} bytecode_programs={d}\n", .{ stats.symbols, stats.templates, stats.functions, stats.modules, stats.parsers, stats.records, stats.bytecode_programs });
}
