const std = @import("std");
const Gzip = @import("figure_raw_gzip");
const Transport = @import("wikimedia_dump").SourceTransport;
const Scope = @import("lua_program").WikitextProvider.CategoryTreeScope;
const A = std.mem.Allocator;
const Tree = @This();
const stride = 1024 * 1024;
const chunk = 32 * 1024;
// Two hundred title fields plus the category and scope. Limit only the new transport.
const max_row = 1024 * 1024;

pub const Row = struct {
    key: []const u8,
    members: []const u8,

    pub fn parse(line: []const u8) !Row {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const category = fields.next() orelse return error.InvalidCategoryTreeSnapshot;
        const scope = fields.next() orelse return error.InvalidCategoryTreeSnapshot;
        if (category.len == 0 or std.meta.stringToEnum(Scope, scope) == null)
            return error.InvalidCategoryTreeSnapshot;
        const end = category.len + 1 + scope.len;
        var count: usize = 0;
        while (fields.next()) |title| {
            if (title.len == 0 or count == 200) return error.InvalidCategoryTreeSnapshot;
            count += 1;
        }
        return .{ .key = line[0..end], .members = if (line.len == end) "" else line[end+1..] };
    }
};

const Entry = struct {
    hash: u64,
    offset: u32,
    length: u32,
    fn less(_: void, l: Entry, r: Entry) bool { return l.hash < r.hash; }
    fn compare(hash: u64, row: Entry) std.math.Order { return std.math.order(hash, row.hash); }
};

// The flate decoder owns its Huffman tables, bit cursor, pending match state and
// gzip footer state by value. Its only live buffer references are the fixed
// compressed input and the inflater history window. Rebind both on restoration.
const Checkpoint = struct {
    decoder: Gzip,
    input_seek: usize,
};

a: A,
rows: std.ArrayList(Entry) = .empty,
checkpoints: std.ArrayList(Checkpoint) = .empty,
queried: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
logical_sha256: [32]u8 = undefined,
logical_bytes: u64 = 0,
bytes: []const u8,
identity: Transport.FileIdentity,
file: std.Io.File,
io: std.Io,
path: []const u8,

pub fn init(a: A, io: std.Io, file: std.Io.File, path: []const u8, bytes: []const u8) !Tree {
    var self: Tree = .{ .a=a, .io=io, .file=file, .path=path, .bytes=bytes, .identity=try Transport.fileIdentity(file) };
    errdefer self.clearIndex();
    try self.check();
    var input: std.Io.Reader = .fixed(bytes);
    var window: [std.compress.flate.max_window_len]u8 = @splat(0);
    var decoder = Gzip.initBounded(&input, &window, std.math.maxInt(u32));
    var digest: std.crypto.hash.sha2.Sha256 = .init(.{});
    var buffer: [chunk]u8 = undefined;
    var partial: std.ArrayList(u8) = .empty;
    defer partial.deinit(a);
    var start: u64 = 0;
    while (!decoder.done) {
        if (decoder.offset % stride == 0) {
            var checkpoint: Checkpoint = .{ .decoder=decoder, .input_seek=input.seek };
            checkpoint.decoder.inflater.input = undefined;
            const saved = try a.dupe(u8, &window);
            errdefer a.free(saved);
            checkpoint.decoder.inflater.reader.buffer = saved;
            try self.checkpoints.append(a, checkpoint);
        }
        const base = decoder.offset;
        const n = try Gzip.readAt(&decoder, &buffer, base);
        digest.update(buffer[0..n]);
        var p: usize = 0;
        while (p < n) {
            const end = std.mem.indexOfScalarPos(u8, buffer[0..n], p, '\n') orelse n;
            const part = buffer[p..end];
            if (part.len + partial.items.len > max_row) return error.CategoryTreeSnapshotTooLarge;
            if (end == n or partial.items.len != 0) try partial.appendSlice(a, part);
            if (end == n) break;
            try self.add(if (partial.items.len == 0) part else partial.items, start);
            partial.clearRetainingCapacity();
            p = end + 1;
            start = base + p;
        }
    }
    if (partial.items.len != 0) try self.add(partial.items, start);
    self.logical_sha256 = digest.finalResult();
    self.logical_bytes = decoder.offset;
    std.sort.pdq(Entry, self.rows.items, {}, Entry.less);
    try self.checkDuplicateKeys();
    try self.check();
    return self;
}

fn check(self: *const Tree) !void {
    if (!std.meta.eql(self.identity, try Transport.fileIdentity(self.file)) or
        !std.meta.eql(self.identity, try Transport.pathIdentity(self.io, self.path)))
        return error.CategoryTreeSourceChanged;
}

fn add(self: *Tree, line: []const u8, start: u64) !void {
    if (line.len == 0 or line[0] == '#') return;
    const row = try Row.parse(line);
    try self.rows.append(self.a,.{ .hash=std.hash.Wyhash.hash(0,row.key), .offset=@intCast(start), .length=@intCast(line.len) });
}

fn readRow(self: *const Tree, a: A, entry: Entry) ![]u8 {
    const cp = &self.checkpoints.items[entry.offset / stride];
    var input: std.Io.Reader = .fixed(self.bytes);
    input.seek = cp.input_seek;
    var decoder = cp.decoder;
    decoder.inflater.input = &input;
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    @memcpy(&window, cp.decoder.inflater.reader.buffer);
    decoder.inflater.reader.buffer = &window;
    var scratch: [chunk]u8 = undefined;
    while (decoder.offset < entry.offset) {
        const n = @min(scratch.len,entry.offset-decoder.offset);
        if (try Gzip.readAt(&decoder, scratch[0..n], decoder.offset) != n) return error.InvalidCategoryTreeSnapshot;
    }
    const line = try a.alloc(u8, entry.length);
    errdefer a.free(line);
    if (try Gzip.readAt(&decoder,line,decoder.offset) != entry.length) return error.InvalidCategoryTreeSnapshot;
    return line;
}

fn checkDuplicateKeys(self: *Tree) !void {
    var i: usize = 0;
    while (i < self.rows.items.len) {
        var end = i+1;
        while (end < self.rows.items.len and self.rows.items[end].hash == self.rows.items[i].hash) end += 1;
        if (end > i+1) {
            var arena = std.heap.ArenaAllocator.init(self.a);
            defer arena.deinit();
            var keys: std.StringHashMapUnmanaged(void) = .empty;
            for (self.rows.items[i..end]) |entry| {
                const line = try self.readRow(self.a, entry);
                defer self.a.free(line);
                const key = (try Row.parse(line)).key;
                if ((try keys.getOrPut(arena.allocator(), try arena.allocator().dupe(u8,key))).found_existing)
                    return error.DuplicateCategoryTree;
            }
        }
        i=end;
    }
}

pub fn lookup(self: *Tree, key: []const u8, scoped: ?A) ![]const u8 {
    try self.check();
    const hash = std.hash.Wyhash.hash(0,key);
    const i = std.sort.lowerBound(Entry,self.rows.items,hash,Entry.compare);
    for (self.rows.items[i..]) |entry| {
        if (entry.hash != hash) break;
        if (self.queried.get(entry.offset)) |line| {
            const row = try Row.parse(line);
            if (std.mem.eql(u8,row.key,key)) return row.members;
            continue;
        }
        const allocator = scoped orelse self.a;
        const line = try self.readRow(allocator, entry);
        var retained = false;
        defer if (!retained) allocator.free(line);
        const row = try Row.parse(line);
        if (!std.mem.eql(u8,row.key,key)) continue;
        try self.check();
        if (scoped == null) try self.queried.put(self.a,entry.offset,line);
        retained = true;
        return row.members;
    }
    return error.CategoryTreeSnapshotMissing;
}

fn clearIndex(self: *Tree) void {
    for (self.checkpoints.items) |cp| self.a.free(cp.decoder.inflater.reader.buffer);
    self.checkpoints.deinit(self.a);
    self.rows.deinit(self.a);
    var lines = self.queried.valueIterator();
    while (lines.next()) |line| self.a.free(line.*);
    self.queried.deinit(self.a);
}

pub fn deinit(self: *Tree) void {
    self.clearIndex();
    self.file.close(self.io);
    self.a.free(self.path);
    self.* = undefined;
}

pub fn indexBytes(self: *const Tree) usize {
    return self.rows.capacity * @sizeOf(Entry) + self.checkpoints.capacity * @sizeOf(Checkpoint) +
        self.checkpoints.items.len * std.compress.flate.max_window_len;
}
