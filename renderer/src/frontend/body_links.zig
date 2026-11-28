//! Semantic keyboard navigation over source-owned occurrences. No screen-text matching.
const std = @import("std");
const model = @import("model.zig");
const T = @import("blob_encoder").presentation_types;
const disclosure = @import("disclosure_state.zig");
const A = std.mem.Allocator;

pub const Field = enum { block_spans, table_caption, cell_spans, figure_content, figure_caption, flow_spans };
pub const Identity = struct {
    path: disclosure.Path,
    field: Field,
    span: usize,
    // Maintained visual-fallback emission within this exact source span, never a rendered row ordinal.
    leaf: usize,
    pub fn equal(a: Identity, b: Identity) bool {
        return disclosure.Path.equal(a.path, b.path) and a.field == b.field and a.span == b.span and a.leaf == b.leaf;
    }
};
pub const Action = enum { internal, external, media };
pub const Occurrence = struct {
    id: Identity,
    label: []const u8,
    target: []const u8,
    language: []const u8,
    fragment: ?[]const u8,
    action: Action,
};
pub const max_links = 4096;
pub const max_owned_bytes = 2 * 1024 * 1024;

pub const State = struct {
    arena: ?std.heap.ArenaAllocator = null,
    items: std.ArrayList(Occurrence) = .empty,
    focused: ?Identity = null,
    section: usize = 0,
    unavailable: bool = false,
    owned_bytes: usize = 0,
    remaining: usize = T.max_presentation_items,

    pub fn deinit(self: *State) void { self.reset(); }
    pub fn reset(self: *State) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }
    pub fn begin(self: *State, a: A) void {
        const focus = self.focused;
        self.reset();
        self.arena = std.heap.ArenaAllocator.init(a);
        self.focused = focus;
    }
    fn refuse(self: *State) void {
        self.unavailable = true;
        self.items.clearRetainingCapacity();
        self.focused = null;
    }
    fn charge(self: *State) bool {
        if (self.unavailable) return false;
        if (self.remaining == 0) { self.refuse(); return false; }
        self.remaining -= 1;
        return true;
    }
    pub fn focusedIndex(self: State) ?usize {
        if (self.focused) |id| for (self.items.items, 0..) |item, i| if (Identity.equal(id, item.id)) return i;
        return null;
    }
    pub fn current(self: State) ?Occurrence {
        return if (self.focusedIndex()) |i| self.items.items[i] else null;
    }
    pub fn end(self: *State) void {
        if (self.focusedIndex() == null) self.focused = null;
    }
    pub fn move(self: *State, forward: bool) bool {
        if (self.unavailable or self.items.items.len == 0) return false;
        const n = self.items.items.len;
        const next = if (self.focusedIndex()) |i| (if (forward) (i + 1) % n else (i + n - 1) % n)
            else if (forward) @as(usize, 0) else n - 1;
        self.focused = self.items.items[next].id;
        return true;
    }
    pub fn clearFocus(self: *State) bool {
        const changed = self.focused != null;
        self.focused = null;
        return changed;
    }
    fn observe(self: *State, id: Identity, span: model.Span) !void {
        if (!self.charge()) return;
        if (span.kind != .link and span.kind != .external_link) return;
        if (span.target.len == 0 and span.target_fragment == null) return;
        const label = if (span.text.len == 0 and span.trail.len == 0) "[media or empty label]" else span.text;
        const size = label.len + span.trail.len + span.target.len + span.language.len + (if (span.target_fragment) |fragment| fragment.len else 0);
        if (self.items.items.len == max_links or size > max_owned_bytes - self.owned_bytes) { self.refuse(); return; }
        const a = (if (self.arena) |*arena| arena.allocator() else return error.InvalidPresentation);
        for (self.items.items) |old| if (Identity.equal(old.id, id)) return error.InvalidPresentation;
        try self.items.append(a, .{ .id = id, .label = try std.mem.concat(a, u8, &.{ label, span.trail }),
            .target = try a.dupe(u8, span.target), .language = try a.dupe(u8, span.language),
            .fragment = if (span.target_fragment) |fragment| try a.dupe(u8, fragment) else null,
            .action = action(span) });
        self.owned_bytes += size;
    }
    pub fn spans(self: *State, values: []const model.Span, path: disclosure.Path, field: Field) anyerror!void {
        for (values, 0..) |span, index| {
            if (!self.charge()) return;
            const Emit = struct {
                state: *State, path: disclosure.Path, field: Field, span: usize, leaf: usize = 0,
                fn emit(context: *@This(), value: model.Span) !void {
                    const id: Identity = .{ .path = context.path, .field = context.field, .span = context.span, .leaf = context.leaf };
                    context.leaf += 1;
                    try context.state.observe(id, value);
                }
            };
            var context: Emit = .{ .state = self, .path = path, .field = field, .span = index };
            // Same terminal fallback as output.zig: inherited actions retained, clipped absolute children omitted.
            const one: []const model.Span = &.{span};
            try T.visitRubyVisualFallback(one, &context, Emit.emit);
        }
    }
    pub fn collectBlock(self: *State, value: model.Block, path: disclosure.Path, controls: *const disclosure.State) !void {
        self.block(value, path, controls) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => self.refuse(), // Navigation cannot suppress an otherwise readable body.
        };
    }
    pub fn block(self: *State, value: model.Block, path: disclosure.Path, controls: *const disclosure.State) anyerror!void {
        if (path.section != self.section or !self.charge()) return;
        if (T.contentBox(value)) |box| {
            const edge: disclosure.Edge = if (value.description_body != null) .description else .container;
            for (box.blocks, 0..) |child, i| {
                if (box.disclosure) |policy| if (i == policy.content_index and controls.closed(path, policy.initially_collapsed)) continue;
                try self.block(child, try path.child(edge, i, 0), controls);
            }
            return;
        }
        if (value.table) |table_value| return self.table(table_value, path, controls);
        if (value.flow) |parts| return self.flow(parts, path, controls);
        if (value.figure) |figure_value| return self.figure(figure_value, path, controls);
        try self.spans(value.spans, path, .block_spans);
    }
    fn table(self: *State, value: model.Table, path: disclosure.Path, controls: *const disclosure.State) anyerror!void {
        if (!self.charge()) return;
        if (value.caption_blocks) |blocks| {
            for (blocks, 0..) |child, i| try self.block(child, try path.child(.table_caption, i, 0), controls);
        } else try self.spans(value.caption, path, .table_caption);
        for (value.rows, 0..) |row, r| for (row.cells, 0..) |cell, c| {
            if (!self.charge()) return;
            const cell_path = try path.child(.table_cell, r, c);
            if (cell.blocks) |blocks| {
                for (blocks, 0..) |child, i| try self.block(child, try cell_path.child(.cell_block, i, 0), controls);
            } else {
                try self.spans(cell.spans, cell_path, .cell_spans);
                if (cell.nested_table) |nested| try self.table(nested, try cell_path.child(.nested_table, 0, 0), controls);
            }
        };
    }
    fn figure(self: *State, value: T.Figure, path: disclosure.Path, controls: *const disclosure.State) anyerror!void {
        if (!self.charge()) return;
        try self.spans(&.{value.content.span()}, path, .figure_content);
        if (value.caption_blocks) |blocks| {
            for (blocks, 0..) |child, i| try self.block(child, try path.child(.figure_caption, i, 0), controls);
        } else try self.spans(value.caption, path, .figure_caption);
    }
    fn flow(self: *State, values: []const T.FlowPart, path: disclosure.Path, controls: *const disclosure.State) anyerror!void {
        for (values, 0..) |part, i| {
            if (!self.charge()) return;
            const part_path = try path.child(.flow, i, 0);
            switch (part.kind) {
                .@"inline" => try self.spans(part.spans, part_path, .flow_spans),
                .figure => try self.figure(part.figure orelse return error.InvalidPresentation, part_path, controls),
                .scope => try self.flow((part.scope orelse return error.InvalidPresentation).parts, try part_path.child(.scope, 0, 0), controls),
            }
        }
    }
};

pub fn action(span: model.Span) Action {
    if (span.image != null or span.audio_control != null) return .media;
    var classes = std.mem.tokenizeAny(u8, span.classes, " \t\r\n\x0c");
    while (classes.next()) |name| if (std.mem.eql(u8, name, "wikidict-media") or std.mem.startsWith(u8, name, "wikidict-media-file-")) return .media;
    if (std.ascii.startsWithIgnoreCase(span.target, "File:") or std.ascii.startsWithIgnoreCase(span.target, "Image:") or std.ascii.startsWithIgnoreCase(span.target, "Media:")) return .media;
    if (span.kind == .external_link) return .external;
    return .internal;
}


test "TUI body links01 typed occurrences survive aliasing bidi and snapshot replacement" {
    const a = std.testing.allocator;
    const repeated = [_]model.Span{.{ .kind = .link, .text = "same", .target = "target", .language = "it", .target_fragment = "part" }};
    const nested: model.Block = .{ .kind = .paragraph, .flow = &.{.{ .kind = .scope, .scope = .{
        .mode = .isolate, .resolved_direction = .rtl, .parts = &.{.{ .kind = .@"inline", .spans = &repeated }},
    } }} };
    const table: model.Block = .{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{
        .{ .blocks = &.{nested} }, .{ .blocks = &.{nested} },
    } }} } };
    var controls: disclosure.State = .{}; defer controls.deinit(a);
    var state: State = .{}; defer state.deinit();
    state.begin(a); state.section = 9;
    try state.block(table, .{ .section = 9, .block = 3 }, &controls); state.end();
    try std.testing.expectEqual(@as(usize, 2), state.items.items.len);
    try std.testing.expect(!Identity.equal(state.items.items[0].id, state.items.items[1].id));
    try std.testing.expect(state.move(true)); try std.testing.expect(state.move(true));
    const selected = state.focused.?;
    // A new arena/snapshot may move all addresses; typed identity remains fixed.
    state.begin(a); state.section = 9;
    try state.block(table, .{ .section = 9, .block = 3 }, &controls); state.end();
    try std.testing.expect(Identity.equal(selected, state.focused.?));
    try std.testing.expectEqualStrings("it", state.current().?.language);
    try std.testing.expectEqualStrings("part", state.current().?.fragment.?);
    try std.testing.expectEqualStrings("target", state.current().?.target);
    state.reset(); try std.testing.expect(state.current() == null and state.focused == null);
}

test "TUI body links01 collapsed ancestry removes only descendants and keeps caption occurrences" {
    const a = std.testing.allocator;
    const caption: model.Block = .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "caption", .target = "caption" }} };
    const child: model.Block = .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "child", .target = "child" }} };
    const owner: model.Block = .{ .kind = .container, .container = .{ .blocks = &.{ caption, child }, .disclosure = .{
        .content_index = 1, .initially_collapsed = true, .expand_label = "show", .collapse_label = "hide",
    } } };
    const path: disclosure.Path = .{ .section = 9, .block = 1 };
    var controls: disclosure.State = .{}; defer controls.deinit(a);
    var state: State = .{}; defer state.deinit();
    state.begin(a); state.section = 9; try state.block(owner, path, &controls); state.end();
    try std.testing.expectEqual(@as(usize, 1), state.items.items.len);
    try std.testing.expectEqualStrings("caption", state.items.items[0].target);
    try controls.observe(a, .{ .path = path, .initially_collapsed = true, .offset = 0 });
    try std.testing.expect(controls.move(true)); try std.testing.expect(try controls.toggle(a));
    state.begin(a); state.section = 9; try state.block(owner, path, &controls); state.end();
    try std.testing.expect(state.move(false)); try std.testing.expectEqualStrings("child", state.current().?.target);
    try std.testing.expect(try controls.toggle(a));
    state.begin(a); state.section = 9; try state.block(owner, path, &controls); state.end();
    try std.testing.expectEqual(@as(usize, 1), state.items.items.len);
    try std.testing.expect(state.focused == null);
}

test "TUI body links01 literal targets fragments media and borrowed bytes remain distinct" {
    const a = std.testing.allocator;
    var state: State = .{}; defer state.deinit();
    state.begin(a);
    {
        var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit();
        const scratch = arena.allocator();
        const spans = [_]model.Span{
            .{ .kind = .link, .text = "legacy", .target = try scratch.dupe(u8, "word#literal") },
            .{ .kind = .link, .text = "explicit", .target = try scratch.dupe(u8, "word"), .target_fragment = try scratch.dupe(u8, "anchor"), .language = "it" },
            .{ .kind = .external_link, .text = "external", .target = "https://example.invalid/" },
            .{ .kind = .link, .text = "media", .target = "File:Voice.ogg" },
        };
        try state.spans(&spans, .{ .section = 0, .block = 0 }, .block_spans);
    }
    state.end();
    try std.testing.expectEqualStrings("word#literal", state.items.items[0].target);
    try std.testing.expect(state.items.items[0].fragment == null);
    try std.testing.expectEqualStrings("word", state.items.items[1].target);
    try std.testing.expectEqualStrings("anchor", state.items.items[1].fragment.?);
    try std.testing.expectEqual(Action.external, state.items.items[2].action);
    try std.testing.expectEqual(Action.media, state.items.items[3].action);
    state.remaining = 0;
    try state.spans(&.{.{ .kind = .link, .text = "not partial", .target = "x" }}, .{ .section = 0, .block = 0 }, .block_spans);
    try std.testing.expect(state.unavailable and state.items.items.len == 0 and state.focused == null);
}
