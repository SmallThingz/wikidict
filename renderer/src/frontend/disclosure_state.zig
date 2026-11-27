//! Ephemeral terminal interaction. No stored Entry, wire or export mutation.
const std = @import("std");

pub const Edge = enum { container, description, table_caption, table_cell, cell_block, nested_table, figure_caption, flow, scope };
pub const Step = struct { kind: Edge, index: usize, second: usize = 0 };
pub const Path = struct {
    section: usize,
    block: usize,
    steps: [64]Step = undefined,
    len: usize = 0,
    pub fn child(self: Path, kind: Edge, index: usize, second: usize) !Path {
        if (self.len == self.steps.len) return error.InvalidPresentation;
        var result = self;
        result.steps[result.len] = .{ .kind = kind, .index = index, .second = second };
        result.len += 1;
        return result;
    }
    pub fn equal(a: Path, b: Path) bool {
        if (a.section != b.section or a.block != b.block or a.len != b.len) return false;
        for (a.steps[0..a.len], b.steps[0..b.len]) |x, y|
            if (x.kind != y.kind or x.index != y.index or x.second != y.second) return false;
        return true;
    }
};

pub const Visible = struct { path: Path, initially_collapsed: bool, offset: usize };
pub const State = struct {
    toggled: std.ArrayList(Path) = .empty,
    visible: std.ArrayList(Visible) = .empty,
    focused: ?Path = null,

    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        self.toggled.deinit(a);
        self.visible.deinit(a);
    }
    pub fn reset(self: *State) void {
        self.toggled.clearRetainingCapacity();
        self.visible.clearRetainingCapacity();
        self.focused = null;
    }
    pub fn begin(self: *State) void { self.visible.clearRetainingCapacity(); }
    pub fn end(self: *State) void {
        if (self.focusedIndex() == null) self.focused = null;
    }
    pub fn isFocused(self: State, path: Path) bool {
        return if (self.focused) |focused| Path.equal(focused, path) else false;
    }
    fn toggleIndex(self: State, path: Path) ?usize {
        for (self.toggled.items, 0..) |value, i| if (Path.equal(value, path)) return i;
        return null;
    }
    pub fn closed(self: State, path: Path, initially: bool) bool {
        return initially != (self.toggleIndex(path) != null);
    }
    pub fn observe(self: *State, a: std.mem.Allocator, value: Visible) !void {
        for (self.visible.items) |old| if (Path.equal(old.path, value.path)) return error.InvalidPresentation;
        try self.visible.append(a, value);
    }
    fn focusedIndex(self: State) ?usize {
        for (self.visible.items, 0..) |value, i| if (self.isFocused(value.path)) return i;
        return null;
    }
    pub fn move(self: *State, forward: bool) bool {
        const n = self.visible.items.len;
        if (n == 0) return false;
        const next = if (self.focusedIndex()) |i|
            (if (forward) (i + 1) % n else (i + n - 1) % n)
        else if (forward) @as(usize, 0) else n - 1;
        self.focused = self.visible.items[next].path;
        return true;
    }
    pub fn toggle(self: *State, a: std.mem.Allocator) !bool {
        const i = self.focusedIndex() orelse return false;
        const path = self.visible.items[i].path;
        if (self.toggleIndex(path)) |at| _ = self.toggled.orderedRemove(at) else try self.toggled.append(a, path);
        return true;
    }
    pub fn focusedOffset(self: State) ?usize {
        return if (self.focusedIndex()) |i| self.visible.items[i].offset else null;
    }
};
