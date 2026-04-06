const std = @import("std");
const support = @import("template_compiler_support.zig");

pub const TemplateClass = support.TemplateClass;

pub fn classifyTemplate(_: []const u8) ?TemplateClass {
    return null;
}

pub fn renderTemplateByName(
    _: *std.ArrayList(u8),
    _: std.mem.Allocator,
    _: []const u8,
    _: *const support.TemplateArgs,
) !bool {
    return false;
}
