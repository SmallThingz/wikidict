const std = @import("std");

pub const RequestSection = struct {
    title: []const u8,
    level: u8,
    html: []const u8,
};

pub const WorkerRequest = struct {
    mode: []const u8 = "compare",
    db_tag: []const u8,
    entry_index: usize,
    title: []const u8,
    raw: []const u8,
    sections: []const RequestSection,
};

pub const WorkerResponse = struct {
    ok: bool,
    cached: ?bool = null,
    kind: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    our: ?[]const u8 = null,
    parsoid: ?[]const u8 = null,
};

pub const LocalWorkerOptions = struct {
    cache_path: []const u8 = "data/parsoid-render.db",
    cache_only: bool = false,
};

pub const LocalWorker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_only: bool,
    cache_mutex: std.Io.Mutex = .init,
    cache: Cache,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        entry_count: usize,
        options: LocalWorkerOptions,
    ) !LocalWorker {
        return .{
            .allocator = allocator,
            .io = io,
            .cache_only = options.cache_only,
            .cache = try Cache.open(allocator, io, options.cache_path, entry_count),
        };
    }

    pub fn deinit(self: *LocalWorker) void {
        self.cache.deinit();
    }

    pub fn compare(self: *LocalWorker, allocator: std.mem.Allocator, request: WorkerRequest) !WorkerResponse {
        const mode_prime = std.mem.eql(u8, request.mode, "prime");
        const raw_hash = hashRaw(request.raw);

        const reference_text = if (mode_prime or self.cache_only) blk: {
            const reference = try self.getCachedReferenceAlloc(allocator, request.db_tag, request.entry_index, raw_hash);
            if (reference) |cached| break :blk cached;
            if (self.cache_only) {
                return .{
                    .ok = false,
                    .kind = "cache_miss",
                    .summary = "cache miss",
                };
            }

            var render_result = try runPhpReferenceRendererAlloc(allocator, self.io, request.title, request.raw);
            defer render_result.deinit(allocator);

            const rendered = switch (render_result.term) {
                .exited => |code| if (code == 0)
                    try allocator.dupe(u8, std.mem.trim(u8, render_result.stdout, " \t\r\n"))
                else
                    return .{
                        .ok = false,
                        .kind = "worker_error",
                        .summary = try phpRendererFailureSummaryAlloc(allocator, code, render_result.stderr),
                    },
                else => return .{
                    .ok = false,
                    .kind = "worker_error",
                    .summary = try allocator.dupe(u8, "php reference renderer terminated unexpectedly"),
                },
            };
            defer allocator.free(rendered);
            const stored = try self.putRenderedReferenceAlloc(allocator, request.db_tag, request.entry_index, raw_hash, rendered);
            break :blk stored;
        } else blk: {
            var render_result = try runPhpReferenceRendererAlloc(allocator, self.io, request.title, request.raw);
            defer render_result.deinit(allocator);

            const rendered = switch (render_result.term) {
                .exited => |code| if (code == 0)
                    try allocator.dupe(u8, std.mem.trim(u8, render_result.stdout, " \t\r\n"))
                else
                    return .{
                        .ok = false,
                        .kind = "worker_error",
                        .summary = try phpRendererFailureSummaryAlloc(allocator, code, render_result.stderr),
                    },
                else => return .{
                    .ok = false,
                    .kind = "worker_error",
                    .summary = try allocator.dupe(u8, "php reference renderer terminated unexpectedly"),
                },
            };
            _ = try self.putRenderedReferenceAlloc(allocator, request.db_tag, request.entry_index, raw_hash, rendered);
            break :blk rendered;
        };
        defer allocator.free(reference_text);
        const normalized_reference = try normalizeCanonicalHtmlForComparisonAlloc(allocator, reference_text);
        defer allocator.free(normalized_reference);

        if (mode_prime) return .{
            .ok = true,
            .cached = true,
        };

        const ours = try canonicalizeRequestSectionsAlloc(allocator, request.sections);
        defer allocator.free(ours);
        const normalized_ours = try normalizeCanonicalHtmlForComparisonAlloc(allocator, ours);
        defer allocator.free(normalized_ours);
        if (std.mem.eql(u8, normalized_ours, normalized_reference)) return .{ .ok = true };

        const mismatch_index = firstMismatchIndex(normalized_ours, normalized_reference);
        const summary = try mismatchSummaryAlloc(allocator, normalized_ours, normalized_reference, mismatch_index);
        return .{
            .ok = false,
            .kind = "mismatch",
            .summary = summary,
            .our = try excerptAroundAlloc(allocator, normalized_ours, mismatch_index),
            .parsoid = try excerptAroundAlloc(allocator, normalized_reference, mismatch_index),
        };
    }

    fn getCachedReferenceAlloc(
        self: *LocalWorker,
        allocator: std.mem.Allocator,
        db_tag: []const u8,
        entry_index: usize,
        raw_hash: u64,
    ) !?[]u8 {
        self.cache_mutex.lockUncancelable(self.io);
        defer self.cache_mutex.unlock(self.io);
        return self.cache.getAlloc(allocator, db_tag, entry_index, raw_hash);
    }

    fn putRenderedReferenceAlloc(
        self: *LocalWorker,
        allocator: std.mem.Allocator,
        db_tag: []const u8,
        entry_index: usize,
        raw_hash: u64,
        rendered: []const u8,
    ) ![]u8 {
        self.cache_mutex.lockUncancelable(self.io);
        defer self.cache_mutex.unlock(self.io);

        if (try self.cache.getAlloc(allocator, db_tag, entry_index, raw_hash)) |existing| {
            return existing;
        }

        try self.cache.put(db_tag, entry_index, raw_hash, rendered);
        return allocator.dupe(u8, rendered);
    }
};

pub fn hashRaw(raw: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(raw);
    return hasher.final();
}

pub fn renderReferenceCanonicalAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    title: []const u8,
    raw: []const u8,
) ![]u8 {
    var result = try runPhpReferenceRendererAlloc(allocator, io, title, raw);
    defer result.deinit(allocator);

    return switch (result.term) {
        .exited => |code| if (code == 0)
            allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"))
        else
            error.PhpReferenceRendererFailed,
        else => error.PhpReferenceRendererFailed,
    };
}

pub fn canonicalizeRequestSectionsAlloc(allocator: std.mem.Allocator, sections: []const RequestSection) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (sections, 0..) |section, idx| {
        if (idx != 0) try out.append(allocator, '\n');
        const line = try std.fmt.allocPrint(allocator, "@{d}:{s}\n{s}", .{
            section.level,
            section.title,
            std.mem.trim(u8, section.html, " \t\r\n"),
        });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }

    return out.toOwnedSlice(allocator);
}

const PhpRendererResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *PhpRendererResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn runPhpReferenceRendererAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    title: []const u8,
    raw: []const u8,
) !PhpRendererResult {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "php", "tools/parsoid_reference_render.php", "--title", title },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    try std.Io.File.writeStreamingAll(child.stdin.?, io, raw);
    child.stdin.?.close(io);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    while (multi_reader.fill(1024, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }

    try multi_reader.checkAnyError();

    const term = try child.wait(io);
    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    errdefer allocator.free(stderr);

    return .{
        .term = term,
        .stdout = stdout,
        .stderr = stderr,
    };
}

fn phpRendererFailureSummaryAlloc(allocator: std.mem.Allocator, exit_code: u8, stderr: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, stderr, " \t\r\n");
    if (trimmed.len != 0) return excerptAroundAlloc(allocator, trimmed, 0);
    return std.fmt.allocPrint(allocator, "php reference renderer exited with code {d}", .{exit_code});
}

fn normalizeCanonicalHtmlForComparisonAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (asciiStartsWithIgnoreCase(input[i..], "<a")) {
            const end = std.mem.indexOfScalarPos(u8, input, i, '>') orelse break;
            i = end + 1;
            continue;
        }
        if (asciiStartsWithIgnoreCase(input[i..], "</a>")) {
            i += "</a>".len;
            continue;
        }
        if (asciiStartsWithIgnoreCase(input[i..], "&nbsp;")) {
            try out.append(allocator, ' ');
            i += "&nbsp;".len;
            continue;
        }
        if (i + 1 < input.len and input[i] == 0xC2 and input[i + 1] == 0xA0) {
            try out.append(allocator, ' ');
            i += 2;
            continue;
        }
        try out.append(allocator, input[i]);
        i += 1;
    }

    if (i < input.len) try out.appendSlice(allocator, input[i..]);
    return out.toOwnedSlice(allocator);
}

fn asciiStartsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

fn firstMismatchIndex(ours: []const u8, reference: []const u8) usize {
    const max_len = @min(ours.len, reference.len);
    var idx: usize = 0;
    while (idx < max_len and ours[idx] == reference[idx]) : (idx += 1) {}
    return idx;
}

fn mismatchSummaryAlloc(allocator: std.mem.Allocator, ours: []const u8, reference: []const u8, idx: usize) ![]u8 {
    const max_len = @min(ours.len, reference.len);
    if (idx == max_len and ours.len != reference.len) {
        return std.fmt.allocPrint(allocator, "length differs: ours={d} reference={d}", .{
            ours.len,
            reference.len,
        });
    }

    const line = 1 + std.mem.count(u8, ours[0..@min(idx, ours.len)], "\n");
    return std.fmt.allocPrint(allocator, "first mismatch at byte {d} (line {d})", .{ idx, line });
}

fn excerptAroundAlloc(allocator: std.mem.Allocator, input: []const u8, center: usize) ![]u8 {
    const radius = 768;
    if (input.len <= radius * 2) return allocator.dupe(u8, input);

    const safe_center = @min(center, input.len);
    const start = safe_center -| radius;
    const end = @min(input.len, safe_center + radius);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (start != 0) try out.appendSlice(allocator, "...[truncated]...\n");
    try out.appendSlice(allocator, input[start..end]);
    if (end != input.len) try out.appendSlice(allocator, "\n...[truncated]...");
    return out.toOwnedSlice(allocator);
}

const cache_magic = "PZCACHE1".*;
const cache_version: u32 = 3;

const CacheHeader = extern struct {
    magic: [8]u8,
    version: u32,
    entry_count: u32,
    payload_offset: u64,
};

const CacheRecord = extern struct {
    db_tag_hash: u64 = 0,
    raw_hash: u64 = 0,
    data_offset: u64 = 0,
    data_len: u32 = 0,
    flags: u32 = 0,
};

const Cache = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    records: []CacheRecord,
    payload_end: u64,
    path: []u8,

    fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        entry_count: usize,
    ) !Cache {
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);

        var file = try std.Io.Dir.cwd().createFile(io, path, .{
            .read = true,
            .truncate = false,
        });
        errdefer file.close(io);

        const stat = try file.stat(io);
        const expected_payload_offset = @sizeOf(CacheHeader) + @sizeOf(CacheRecord) * entry_count;
        if (stat.size < @sizeOf(CacheHeader)) {
            file.close(io);
            file = try reinitializeCacheFile(io, path, entry_count);
        } else {
            var header: CacheHeader = undefined;
            _ = try file.readPositionalAll(io, std.mem.asBytes(&header), 0);
            const valid = std.mem.eql(u8, &header.magic, &cache_magic) and
                header.version == cache_version and
                header.entry_count == entry_count and
                header.payload_offset == expected_payload_offset and
                stat.size >= header.payload_offset;
            if (!valid) {
                file.close(io);
                file = try reinitializeCacheFile(io, path, entry_count);
            }
        }

        const records = try allocator.alloc(CacheRecord, entry_count);
        errdefer allocator.free(records);

        if (records.len != 0) {
            _ = try file.readPositionalAll(io, std.mem.sliceAsBytes(records), @sizeOf(CacheHeader));
        }

        const final_stat = try file.stat(io);
        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .records = records,
            .payload_end = final_stat.size,
            .path = owned_path,
        };
    }

    fn deinit(self: *Cache) void {
        self.file.close(self.io);
        if (self.records.len != 0) self.allocator.free(self.records);
        self.allocator.free(self.path);
    }

    fn getAlloc(
        self: *Cache,
        allocator: std.mem.Allocator,
        db_tag: []const u8,
        entry_index: usize,
        raw_hash: u64,
    ) !?[]u8 {
        if (entry_index >= self.records.len) return null;
        const record = self.records[entry_index];
        if (record.flags == 0) return null;
        if (record.db_tag_hash != hashDbTag(db_tag)) return null;
        if (record.raw_hash != raw_hash) return null;
        if (record.data_len == 0) return null;

        const len = std.math.cast(usize, record.data_len) orelse return error.InvalidDictionaryCache;
        const bytes = try allocator.alloc(u8, len);
        errdefer allocator.free(bytes);
        _ = try self.file.readPositionalAll(self.io, bytes, record.data_offset);
        return bytes;
    }

    fn put(
        self: *Cache,
        db_tag: []const u8,
        entry_index: usize,
        raw_hash: u64,
        rendered: []const u8,
    ) !void {
        if (entry_index >= self.records.len) return;
        if (rendered.len == 0) return;

        const data_len = std.math.cast(u32, rendered.len) orelse return error.RecordTooLarge;
        const write_offset = self.payload_end;
        try self.file.writePositionalAll(self.io, rendered, write_offset);
        self.payload_end += rendered.len;

        var record = CacheRecord{
            .db_tag_hash = hashDbTag(db_tag),
            .raw_hash = raw_hash,
            .data_offset = write_offset,
            .data_len = data_len,
            .flags = 1,
        };
        self.records[entry_index] = record;
        const record_offset = @sizeOf(CacheHeader) + entry_index * @sizeOf(CacheRecord);
        try self.file.writePositionalAll(self.io, std.mem.asBytes(&record), record_offset);
    }
};

fn reinitializeCacheFile(io: std.Io, path: []const u8, entry_count: usize) !std.Io.File {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{
        .read = true,
        .truncate = true,
    });
    const payload_offset = @sizeOf(CacheHeader) + @sizeOf(CacheRecord) * entry_count;
    var header = CacheHeader{
        .magic = cache_magic,
        .version = cache_version,
        .entry_count = std.math.cast(u32, entry_count) orelse return error.TooManyEntries,
        .payload_offset = payload_offset,
    };
    try file.writePositionalAll(io, std.mem.asBytes(&header), 0);

    if (entry_count != 0) {
        const zeros = try std.heap.page_allocator.alloc(CacheRecord, entry_count);
        defer std.heap.page_allocator.free(zeros);
        @memset(zeros, .{});
        try file.writePositionalAll(io, std.mem.sliceAsBytes(zeros), @sizeOf(CacheHeader));
    }
    return file;
}

fn hashDbTag(db_tag: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(1);
    hasher.update(db_tag);
    return hasher.final();
}

fn testTempPath(allocator: std.mem.Allocator, sub_path: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ sub_path, name });
}

const PrimeThreadArgs = struct {
    worker: *LocalWorker,
    db_tag: []const u8,
    entry_index: usize,
    raw: []const u8,
};

fn primeWorkerThread(args: PrimeThreadArgs) !void {
    const response = try args.worker.compare(std.heap.page_allocator, .{
        .mode = "prime",
        .db_tag = args.db_tag,
        .entry_index = args.entry_index,
        .title = "test",
        .raw = args.raw,
        .sections = &.{},
    });
    if (!response.ok) return error.UnexpectedWorkerResponse;
}

test "LocalWorker supports concurrent cache population" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cache_path = try testTempPath(std.testing.allocator, &tmp.sub_path, "parsoid-cache.db");
    defer std.testing.allocator.free(cache_path);

    var worker = try LocalWorker.init(std.testing.allocator, std.testing.io, 8, .{
        .cache_path = cache_path,
    });
    defer worker.deinit();

    const raws = [_][]const u8{
        "==English==\n===Noun===\n# alpha\n",
        "==English==\n===Verb===\n# beta\n",
        "==English==\n===Adjective===\n# gamma\n",
        "==English==\n===Proper noun===\n# delta\n",
    };

    var threads: [raws.len]std.Thread = undefined;
    for (&threads, raws, 0..) |*thread, raw, idx| {
        thread.* = try std.Thread.spawn(.{}, primeWorkerThread, .{
            PrimeThreadArgs{
                .worker = &worker,
                .db_tag = "test-db-tag",
                .entry_index = idx,
                .raw = raw,
            },
        });
    }
    for (threads) |thread| thread.join();

    var cached_only = try LocalWorker.init(std.testing.allocator, std.testing.io, 8, .{
        .cache_path = cache_path,
        .cache_only = true,
    });
    defer cached_only.deinit();

    for (raws, 0..) |raw, idx| {
        const response = try cached_only.compare(std.testing.allocator, .{
            .mode = "prime",
            .db_tag = "test-db-tag",
            .entry_index = idx,
            .title = "test",
            .raw = raw,
            .sections = &.{},
        });
        try std.testing.expect(response.ok);
    }
}
