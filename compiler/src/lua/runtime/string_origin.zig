//! Private build-time string-origin prototype. No Value/Context/Callable field
//! or Lua operation changes. Metadata allocator must be page-arena owned. Callers must supply an already-proved Text, never
//! a guessed clean Value.string; each owner must be retired before its storage
//! can be reused. A ledger is one page epoch, not an absence/empty-ledger proof.
const std = @import("std");
const dependency = @import("missing_dependency");
const A = std.mem.Allocator;
const hooks = @import("zig_runtime").string_origins;
var epoch_counter: std.atomic.Value(u64) = .init(1);
pub fn nextEpoch() u64 {
    var value = epoch_counter.load(.monotonic);
    while (value != std.math.maxInt(u64)) {
        if (epoch_counter.cmpxchgWeak(value, value + 1, .monotonic, .monotonic)) |changed| value = changed else return value;
    }
    return 0; // Exhaustion declines metadata instead of reusing a page epoch.
}
pub const Ledger = struct {
    const Key = struct { ptr: usize, len: usize };
    const Entry = struct { bytes: []const u8, value: dependency.Text, owner: usize, live: bool = true };
    a: A,
    page_epoch: u64,
    entries: std.ArrayList(Entry) = .empty,
    exact: std.AutoHashMapUnmanaged(Key, usize) = .empty,
    // Exact operations are indexed. Borrowed-view and retirement scans share a
    // finite page budget, so optional proof cannot become quadratic unbounded work.
    scan_remaining: usize = 4 * 1024 * 1024,
    metadata_bytes: usize = 0,
    poisoned: bool = false,

    pub fn init(a: A, page_epoch: u64) Ledger { return .{ .a = a, .page_epoch = page_epoch }; }
    pub fn deinit(self: *Ledger) void { self.exact.deinit(self.a); self.entries.deinit(self.a); }
    fn scan(self: *Ledger) bool {
        if (self.poisoned) return false;
        if (self.scan_remaining == 0) { self.poisoned = true; return false; }
        self.scan_remaining -= 1;
        return true;
    }
    pub fn retireOwner(self: *Ledger, owner: usize) void {
        for (self.entries.items) |*entry| {
            if (!self.scan()) return;
            if (entry.owner == owner) entry.live = false;
        }
    }
    pub fn retireInterval(self: *Ledger, bytes: []const u8) void {
        const start = @intFromPtr(bytes.ptr);
        const end = start +| bytes.len;
        for (self.entries.items) |*entry| {
            if (!self.scan()) return;
            const at = @intFromPtr(entry.bytes.ptr);
            if (at >= start and at <= end and entry.bytes.len <= end - at) entry.live = false;
        }
    }
    pub fn lookup(self: *Ledger, bytes: []const u8) !?dependency.Text {
        if (self.poisoned or self.page_epoch == 0) return null;
        if (self.exact.get(.{ .ptr = @intFromPtr(bytes.ptr), .len = bytes.len })) |index| {
            const entry = self.entries.items[index];
            if (entry.live) {
                var value = entry.value; value.bytes = bytes;
                if (value.generated_links.len != 0) value.generated_source = bytes;
                return value;
            }
        }
        // Most-recent exact definitions shadow older entries. Different text
        // with equal bytes never matches; only an owned interval may be sliced.
        var i = self.entries.items.len;
        while (i != 0) {
            if (!self.scan()) return null;
            i -= 1; const entry = self.entries.items[i]; if (!entry.live) continue;
            const start = std.math.sub(usize, @intFromPtr(bytes.ptr), @intFromPtr(entry.bytes.ptr)) catch continue;
            if (start > entry.bytes.len or bytes.len > entry.bytes.len - start) continue;
            var result = try dependency.slice(self.a, entry.value, start, start + bytes.len);
            result.bytes = bytes;
            if (result.generated_links.len != 0) result.generated_source = bytes;
            return result;
        }
        return null;
    }
    pub fn read(self: *Ledger, bytes: []const u8) !dependency.Text {
        return (try self.lookup(bytes)) orelse dependency.Text.transformed(bytes);
    }
    pub fn remember(self: *Ledger, owner: usize, value: dependency.Text) !void {
        if (self.poisoned or self.page_epoch == 0) return;
        const cost = @sizeOf(Entry) +| value.bytes.len +| value.ranges.len *| @sizeOf(dependency.Range) +|
            value.literal_curly_ranges.len *| @sizeOf(dependency.LiteralRange) +|
            value.generated_links.len *| @sizeOf(dependency.generated_link.Range);
        if (cost > dependency.max_metadata_bytes -| self.metadata_bytes) {
            self.poisoned = true; self.entries.clearRetainingCapacity(); return;
        }
        const owned = try dependency.duplicate(self.a, value);
        try self.entries.append(self.a, .{ .bytes = value.bytes, .value = owned, .owner = owner });
        try self.exact.put(self.a, .{ .ptr = @intFromPtr(value.bytes.ptr), .len = value.bytes.len }, self.entries.items.len - 1);
        self.metadata_bytes += cost;
    }
    fn publish(self: *Ledger, owner: usize, actual: []const u8, proved: dependency.Text) !void {
        // Equality verifies this already-identified operation's copy contract;
        // it never searches arbitrary values for a matching source.
        var result = proved;
        if (!std.mem.eql(u8, actual, proved.bytes)) {
            result = dependency.Text.transformed(actual);
            result.lost_missing_range = proved.lost_missing_range or proved.ranges.len != 0;
        }
        else {
            result.bytes = actual;
            if (result.generated_links.len != 0) result.generated_source = actual;
        }
        try self.remember(owner, result);
    }
    pub fn copied(self: *Ledger, owner: usize, source: []const u8, actual: []const u8) !void {
        try self.publish(owner, actual, try self.read(source));
    }
    pub fn copiedFrom(self: *Ledger, other: *Ledger, owner: usize, source: []const u8, actual: []const u8) !void {
        const value = if (self.page_epoch != 0 and self.page_epoch == other.page_epoch)
            try other.read(source) else dependency.Text.transformed(source);
        try self.publish(owner, actual, value);
    }
    pub fn sliced(self: *Ledger, owner: usize, source: []const u8, start: usize, end: usize, actual: []const u8) !void {
        if (start > end or end > source.len) return self.remember(owner, dependency.Text.transformed(actual));
        const value = try self.read(source);
        try self.publish(owner, actual, try dependency.slice(self.a, value, start, end));
    }
    pub fn concatenated(self: *Ledger, owner: usize, sources: []const []const u8, actual: []const u8) !void {
        var out: dependency.Builder = .{}; defer out.deinit(self.a);
        for (sources) |source| try out.append(self.a, try self.read(source));
        try self.publish(owner, actual, try out.finish(self.a));
    }
    fn missingFree(value: dependency.Text) bool {
        return !value.unknown and !value.lost_missing_range and value.ranges.len == 0 and value.literal_curly_ranges.len == 0 and
            value.generated_source == null and value.generated_links.len == 0;
    }
    // A structural copy-span proof for the same already-executed formatter.
    // Only literal text, unadorned string %s and %% are mapped. Flags, numeric
    // conversions, replacement callbacks and unsupported formatting stay unknown.
    pub fn formattedSimple(self: *Ledger, owner: usize, format: []const u8, args: []const []const u8, actual: []const u8) !void {
        var out: dependency.Builder = .{}; defer out.deinit(self.a);
        const format_origin = try self.read(format);
        var pos: usize = 0; var literal: usize = 0; var arg: usize = 0;
        while (pos < format.len) {
            if (format[pos] != '%') { pos += 1; continue; }
            try out.append(self.a, try dependency.slice(self.a, format_origin, literal, pos));
            if (pos + 1 == format.len) return self.remember(owner, dependency.Text.transformed(actual));
            const spec = try dependency.slice(self.a, format_origin, pos, pos + 2);
            switch (format[pos + 1]) {
                '%' => try out.append(self.a, if (missingFree(spec)) dependency.Text.untracked("%") else dependency.Text.transformed("%")),
                's' => {
                    if (arg == args.len or !missingFree(spec)) return self.remember(owner, dependency.Text.transformed(actual));
                    try out.append(self.a, try self.read(args[arg])); arg += 1;
                },
                else => return self.remember(owner, dependency.Text.transformed(actual)),
            }
            pos += 2; literal = pos;
        }
        try out.append(self.a, try dependency.slice(self.a, format_origin, literal, format.len));
        try self.publish(owner, actual, try out.finish(self.a));
    }
};

test "owned invoke string copies slices concat and simple formatting preserve exact missing origins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ledger = Ledger.init(a, 1); defer ledger.deinit();
    const input = "Hindi missing Rajpal tail";
    const origin: dependency.Text = .{ .bytes = input, .ranges = &.{.{ .start = 14, .end = 20, .occurrence = 7 }} };
    try ledger.remember(11, origin);
    const copied = try a.dupe(u8, input); try ledger.copied(12, input, copied);
    try std.testing.expectEqualDeep(origin.ranges, (try ledger.read(copied)).ranges);
    const sub = copied[6..20]; try ledger.sliced(12, copied, 6, 20, sub);
    try std.testing.expectEqualDeep(&[_]dependency.Range{.{ .start = 8, .end = 14, .occurrence = 7 }}, (try ledger.read(sub)).ranges);
    try ledger.remember(13, dependency.Text.untracked("<")); try ledger.remember(13, dependency.Text.untracked(">"));
    const joined = try std.mem.concat(a, u8, &.{ "<", sub, ">" }); try ledger.concatenated(14, &.{ "<", sub, ">" }, joined);
    try std.testing.expectEqualDeep(&[_]dependency.Range{.{ .start = 9, .end = 15, .occurrence = 7 }}, (try ledger.read(joined)).ranges);
    const fmt = "[%s]%%"; try ledger.remember(15, dependency.Text.untracked(fmt));
    const formatted = try std.mem.concat(a, u8, &.{ "[", sub, "]%" }); try ledger.formattedSimple(16, fmt, &.{sub}, formatted);
    const result = try ledger.read(formatted); try std.testing.expect(!result.unknown);
    try std.testing.expectEqualDeep(&[_]dependency.Range{.{ .start = 9, .end = 15, .occurrence = 7 }}, result.ranges);
}

test "invoke origin ledger rejects prior page equal bytes retired owners exposed replacement and unproved format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var old = Ledger.init(a, 41); defer old.deinit(); var current = Ledger.init(a, 42); defer current.deinit();
    const original = try a.dupe(u8, "clean literal"); try old.remember(1, dependency.Text.untracked(original));
    const imported = try a.dupe(u8, original); try current.copiedFrom(&old, 2, original, imported);
    try std.testing.expect((try current.read(imported)).unknown);
    const equal_foreign = try a.dupe(u8, original); try std.testing.expect((try old.read(equal_foreign)).unknown);
    old.retireOwner(1); try std.testing.expect((try old.read(original)).unknown);
    const format = "%04d"; try current.remember(3, dependency.Text.untracked(format));
    try current.formattedSimple(3, format, &.{}, "0007"); try std.testing.expect((try current.read("0007")).unknown);
    const fmt = "%s"; try current.remember(4, dependency.Text.untracked(fmt));
    const changed_argument = try a.dupe(u8, "unregistered replacement");
    try current.formattedSimple(4, fmt, &.{changed_argument}, changed_argument);
    try std.testing.expect((try current.read(changed_argument)).unknown);
    const known = try a.dupe(u8, "owned"); try current.remember(5, dependency.Text.untracked(known));
    const newbytes = try a.dupe(u8, known); try current.copied(6, known, newbytes);
    try std.testing.expect(!(try current.read(newbytes)).unknown);
}

fn fromOpaque(data: *anyopaque) *Ledger { return @ptrCast(@alignCast(data)); }
fn observeCopy(data: *anyopaque, owner: usize, source: []const u8, actual: []const u8) !void { try fromOpaque(data).copied(owner, source, actual); }
fn observeConcat(data: *anyopaque, owner: usize, sources: []const []const u8, actual: []const u8) !void { try fromOpaque(data).concatenated(owner, sources, actual); }
fn observeSlice(data: *anyopaque, owner: usize, source: []const u8, start: usize, end: usize, actual: []const u8) !void { try fromOpaque(data).sliced(owner, source, start, end, actual); }
fn observeFormat(data: *anyopaque, owner: usize, format: []const u8, args: []const []const u8, actual: []const u8) !void { try fromOpaque(data).formattedSimple(owner, format, args, actual); }
fn observeLiteral(data: *anyopaque, bytes: []const u8) !void { try fromOpaque(data).remember(0, dependency.Text.untracked(bytes)); }
fn observeRetire(data: *anyopaque, owner: usize) void { fromOpaque(data).retireOwner(owner); }
pub fn observer(value: *Ledger) hooks.Observer {
    return .{ .data = value, .copy = observeCopy, .concat = observeConcat, .slice = observeSlice,
        .format = observeFormat, .literal = observeLiteral, .retire = observeRetire };
}

test "mutable frame replacement and retained module strings do not acquire a new page origin" {
    const rt = @import("zig_runtime");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var context = try rt.Context.init(a, 1); defer context.deinit();
    var first = Ledger.init(a, nextEpoch()); defer first.deinit();
    var first_observer = observer(&first); const previous = hooks.enter(&first_observer); defer hooks.restore(previous);
    const original = try a.dupe(u8, "Rajpal");
    try first.remember(@intFromPtr(&context), .{ .bytes = original, .ranges = &.{.{ .start = 0, .end = 6, .occurrence = 1 }} });
    const copied = try context.ownString(original);
    const frame_args = try context.newTable();
    try frame_args.rawSet(a, .{ .number = 1 }, .{ .string = copied });
    try std.testing.expectEqual(@as(usize, 1), (try first.read(frame_args.rawGet(.{ .number = 1 }).?.string)).ranges.len);
    const replacement = try a.dupe(u8, copied);
    try frame_args.rawSet(a, .{ .number = 1 }, .{ .string = replacement });
    try std.testing.expect((try first.read(frame_args.rawGet(.{ .number = 1 }).?.string)).unknown);
    // Retain the exact old Value/table across epochs, not just equal new bytes.
    const module_cache = try context.newTable();
    try module_cache.rawSet(a, .{ .string = "saved" }, .{ .string = copied });
    var second = Ledger.init(a, nextEpoch()); defer second.deinit();
    try std.testing.expect((try second.read(module_cache.rawGet(.{ .string = "saved" }).?.string)).unknown);
    first.retireInterval(original);
    try std.testing.expect((try first.read(original)).unknown);
    first.retireOwner(@intFromPtr(&context));
    try std.testing.expect((try first.read(copied)).unknown);
}

test "nested origin observer allocation failure remains operational after inner Lua scope returns" {
    const Failure = struct { fn literal(_: *anyopaque, _: []const u8) !void { return error.OutOfMemory; } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    var origins = Ledger.init(arena.allocator(), nextEpoch()); defer origins.deinit();
    var outer = observer(&origins); const previous = hooks.enter(&outer); defer hooks.restore(previous);
    var inner = observer(&origins); inner.literal = Failure.literal;
    const saved = hooks.enter(&inner);
    hooks.literal("explicit source literal");
    hooks.restore(saved);
    try std.testing.expectError(error.OutOfMemory, hooks.check());
}

test "origin proof scan exhaustion declines metadata without guessing an equal string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var origins = Ledger.init(a, nextEpoch()); defer origins.deinit();
    const source = try a.dupe(u8, "known"); try origins.remember(1, dependency.Text.untracked(source));
    try std.testing.expect(!(try origins.read(source)).unknown);
    origins.scan_remaining = 0;
    try std.testing.expect((try origins.read(try a.dupe(u8, source))).unknown);
    try std.testing.expect((try origins.read(source)).unknown);
}
