//! Native integration boundary. Compiler, codec and VM stay owned by lua2/.
//! Updating the VM must update this adapter rather than duplicating its wire grammar.
pub const Runtime = @import("lua2/wiktionary_runtime.zig").Runtime;
pub const Vm = @import("lua2/vm_exec.zig").Vm;
pub const compileBundle = @import("lua2/bundle_compile.zig").main;

pub const runtime_api = @import("lua2/wiktionary_runtime.zig");
pub const values = @import("lua2/vm_runtime.zig");
pub const bundle = @import("lua2/vm_bundle.zig");
const std = @import("std");

/// Additional, revision-pinned modules use the existing compiler and bundle codec.
/// Their borrowed bytes must outlive the runtime. Duplicate module bodies are rejected.
pub fn loadAdditionalBundle(runtime: *Runtime, bytes: []const u8) !void {
    const a = runtime.persistent_allocator;
    var extra = try bundle.index(a, bytes);
    defer extra.by_title.deinit(a);
    if (runtime.bundle_index == null) runtime.bundle_index = .{};
    var it = extra.by_title.iterator();
    while (it.next()) |entry| {
        const item = try runtime.bundle_index.?.by_title.getOrPut(a, entry.key_ptr.*);
        if (item.found_existing) return error.DuplicateModule;
        item.value_ptr.* = entry.value_ptr.*;
    }
}

/// Expand a construct with the real page context intact, unlike expandFragment,
/// which intentionally treats the fragment itself as the current page source.
pub fn preprocess(runtime: *Runtime, vm: *Vm, text: []const u8) ![]const u8 {
    const frame = try runtime_api.makeFrame(runtime, runtime.current_page_title, &.{}, null);
    const func = frame.table.rawGet(.{ .string = "preprocess" }) orelse return error.MissingPreprocessor;
    const result = try vm.callValue(func, &.{ frame, .{ .string = text } });
    defer Vm.freeResults(result);
    if (result.len != 1 or result[0] != .string) return error.InvalidExpansion;
    return result[0].string;
}

pub const ir = @import("lua2/vm_ir.zig");
pub const refs = @import("lua2/vm_ref.zig");
pub const codec = @import("lua2/vm_codec.zig");
pub const lua = @import("lua2/root.zig");
