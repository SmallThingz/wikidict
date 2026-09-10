const std = @import("std");
const rt = @import("zig_runtime");

pub const PageExistsFn = *const fn (?*anyopaque, []const u8) anyerror!bool;
pub const PageContentFn = *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!?[]const u8;
pub const FramePreprocessFn = *const fn (?*anyopaque, std.mem.Allocator, []const u8, []const u8, *rt.Table) anyerror![]const u8;
pub const FrameExpandTemplateFn = *const fn (?*anyopaque, std.mem.Allocator, []const u8, *rt.Table) anyerror![]const u8;
pub const FrameExtensionTagFn = *const fn (?*anyopaque, std.mem.Allocator, []const u8, ?rt.Value, ?*rt.Table) anyerror![]const u8;
pub const FrameParserFunctionFn = *const fn (?*anyopaque, std.mem.Allocator, []const u8, ?rt.Value, ?rt.Value) anyerror![]const u8;
pub const TextUnstripNoWikiFn = *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror![]const u8;

pub const InterwikiRow = struct {
    prefix: []const u8,
    url: []const u8,
    is_local: bool,
    is_current_wiki: bool,
    is_protocol_relative: bool,
};
pub const SiteInterwikiMapFn = *const fn (?*anyopaque) anyerror![]const InterwikiRow;

pub const Host = struct {
    ctx: ?*anyopaque = null,
    current_title: []const u8 = "",
    now_unix: ?i64 = null,
    page_exists: ?PageExistsFn = null,
    page_content: ?PageContentFn = null,
    frame_preprocess: ?FramePreprocessFn = null,
    frame_expand_template: ?FrameExpandTemplateFn = null,
    frame_extension_tag: ?FrameExtensionTagFn = null,
    frame_parser_function: ?FrameParserFunctionFn = null,
    text_unstrip_no_wiki: ?TextUnstripNoWikiFn = null,
    site_interwiki_map: ?SiteInterwikiMapFn = null,
};

pub fn set(runtime: *rt.Context, host: ?*Host) void {
    runtime.setHost(if (host) |value| value else null);
}

pub fn get(runtime: *const rt.Context) ?*Host {
    return @ptrCast(@alignCast(runtime.host orelse return null));
}
