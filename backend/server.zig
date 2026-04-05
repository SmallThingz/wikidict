const std = @import("std");
const zhttp = @import("zhttp");

const decoder = @import("decoder");
const renderer = @import("renderer");
const system_theme = @import("theme.zig");
const format = decoder.format;
const compact_encoding = decoder.compact_encoding;
const cli_args = @import("cli_args");

const ReqCtx = zhttp.ReqCtx;
const Header = zhttp.response.Header;

pub const ServeOptions = struct {
    db_path: []const u8 = "data/wiktionary.bin",
    port: u16 = 3000,
};

const json_headers: []const Header = &.{
    .{ .name = "content-type", .value = "application/json; charset=utf-8" },
    .{ .name = "cache-control", .value = "no-store, max-age=0" },
    .{ .name = "pragma", .value = "no-cache" },
    .{ .name = "access-control-allow-origin", .value = "*" },
};
const html_headers: []const Header = &.{
    .{ .name = "content-type", .value = "text/html; charset=utf-8" },
    .{ .name = "cache-control", .value = "no-store, max-age=0" },
    .{ .name = "pragma", .value = "no-cache" },
};

const AppContext = struct {
    allocator: std.mem.Allocator,
    db: decoder.Dictionary,
    db_path: []const u8,
    theme_palette: system_theme.Palette,
    // Preloaded SPA shell returned for both `/` and `/entry/...`.
    index_html: []const u8,
    // Monotonic counter used to walk pseudo-randomly across entries without extra state.
    random_counter: std.atomic.Value(u64),

    fn init(io: std.Io, allocator: std.mem.Allocator, options: ServeOptions) !AppContext {
        return .{
            .allocator = allocator,
            .db = try decoder.openDictionary(allocator, io, options.db_path),
            .db_path = try allocator.dupe(u8, options.db_path),
            .theme_palette = try system_theme.detectSystemPalette(io, allocator),
            .index_html = blk: {
                var file = try std.Io.Dir.cwd().openFile(io, "frontend/dist/index.html", .{});
                defer file.close(io);

                const stat = try file.stat(io);
                const len = std.math.cast(usize, stat.size) orelse return error.FileTooLarge;
                const buffer = try allocator.alloc(u8, len);
                errdefer allocator.free(buffer);
                _ = try file.readPositionalAll(io, buffer, 0);
                break :blk buffer;
            },
            .random_counter = .init(0x9e3779b97f4a7c15),
        };
    }

    fn deinit(self: *AppContext) void {
        self.db.deinit();
        self.allocator.free(self.db_path);
        self.theme_palette.deinit(self.allocator);
        self.allocator.free(self.index_html);
    }

    fn nextRandomWord(self: *AppContext) []const u8 {
        if (self.db.entries.len == 0) return "";
        const counter = self.random_counter.fetchAdd(0x9e3779b97f4a7c15, .monotonic);
        const index: usize = @intCast(counter % self.db.entries.len);
        return self.db.entryAt(@intCast(index)).word();
    }

    fn wordOfDay(self: *AppContext, day_number: u64) []const u8 {
        const index = findSelectableIndex(self.db.entries.len, day_number, self) orelse return "";
        return self.db.entryAt(index).word();
    }

    fn isSelectableWord(self: *const AppContext, index: usize) bool {
        return self.db.entryAt(@intCast(index)).hasRaw();
    }
};

const AssetsMw = zhttp.middleware.Static(.{
    .dir = "frontend/dist/assets",
    .mount = "/assets",
});

const IndexPage = struct {
    pub const Info: zhttp.router.EndpointInfo = .{
        .operations = &.{zhttp.operations.Static},
    };

    pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !zhttp.Res {
        return htmlResponse(req.ctx().index_html);
    }
};

const EntryPage = struct {
    pub const Info: zhttp.router.EndpointInfo = .{};

    pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !zhttp.Res {
        return htmlResponse(req.ctx().index_html);
    }
};

const StatsEndpoint = struct {
    pub const Info: zhttp.router.EndpointInfo = .{};

    pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !zhttp.Res {
        const db = &req.ctx().db;
        return jsonResponse(req.allocator(), .{
            .path = req.ctx().db_path,
            .entries = db.header.entry_count,
            .rawEntries = db.header.raw_entry_count,
            .redirects = db.header.redirect_count,
            .lookups = db.lookups.len,
            .recordsBytes = db.header.records_len,
            .version = format.version,
        });
    }
};

const RandomEndpoint = struct {
    pub const Info: zhttp.router.EndpointInfo = .{};

    pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !zhttp.Res {
        return jsonResponse(req.allocator(), .{
            .word = req.ctx().nextRandomWord(),
        });
    }
};

const WordOfDayEndpoint = struct {
    pub const Info: zhttp.router.EndpointInfo = .{
        .query = struct {
            day: zhttp.parse.Optional(zhttp.parse.String),
        },
    };

    pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !zhttp.Res {
        const requested_day = req.queryParam(.day) orelse "";
        const day_number = if (requested_day.len != 0)
            try parseDayKey(requested_day)
        else
            currentUtcDayNumber();

        return jsonResponse(req.allocator(), .{
            .day = if (requested_day.len != 0) requested_day else try formatDayKeyAlloc(req.allocator(), day_number),
            .word = req.ctx().wordOfDay(day_number),
        });
    }
};

const SystemThemeEndpoint = struct {
    pub const Info: zhttp.router.EndpointInfo = .{};

    pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !zhttp.Res {
        return jsonResponse(req.allocator(), try system_theme.jsonPaletteAlloc(req.allocator(), &req.ctx().theme_palette));
    }
};

const SearchEndpoint = struct {
    pub const Info: zhttp.router.EndpointInfo = .{
        .query = struct {
            q: zhttp.parse.Optional(zhttp.parse.String),
            limit: zhttp.parse.Optional(zhttp.parse.Int(u16)),
        },
    };

    const SuggestionJson = struct {
        matched: []const u8,
        word: []const u8,
        kind: []const u8,
        aliasOnly: bool,
        summary: []const u8,
    };

    pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !zhttp.Res {
        const query = req.queryParam(.q) orelse "";
        const limit = @min(@as(usize, req.queryParam(.limit) orelse 12), 64);
        const hits = try req.ctx().db.suggest(req.allocator(), query, limit);

        var suggestions: std.ArrayList(SuggestionJson) = .empty;
        for (hits) |hit| {
            const entry = req.ctx().db.entryAt(hit.entry_index);
            var derived = try entry.derivedAlloc(req.allocator());
            defer derived.deinit(req.allocator());
            try suggestions.append(req.allocator(), .{
                .matched = hit.matched,
                .word = entry.word(),
                .kind = lookupKindString(hit.kind),
                .aliasOnly = derived.alias_only,
                .summary = derived.summary,
            });
        }

        return jsonResponse(req.allocator(), .{
            .query = query,
            .suggestions = try suggestions.toOwnedSlice(req.allocator()),
        });
    }
};

const LookupEndpoint = struct {
    pub const Info: zhttp.router.EndpointInfo = .{};

    const RenderedSectionJson = struct {
        id: []const u8,
        title: []const u8,
        level: u8,
        html: []const u8,
    };

    const EntryJson = struct {
        word: []const u8,
        normalized: []const u8,
        aliasOnly: bool,
        aliasHintLabel: []const u8,
        altForms: []const []const u8,
        canonicalTargets: []const []const u8,
        incomingAliases: []const []const u8,
        renderedSections: []const RenderedSectionJson,
        // Filtered raw English wikitext stored in the dictionary payload.
        raw: []const u8,
        summary: []const u8,
    };

    const HitJson = struct {
        matched: []const u8,
        kind: []const u8,
        entry: EntryJson,
    };

    pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !zhttp.Res {
        const term = req.paramValue(.term);
        const hits = try req.ctx().db.lookupExact(req.allocator(), term);

        var payload_hits: std.ArrayList(HitJson) = .empty;
        for (hits) |hit| {
            const entry = req.ctx().db.entryAt(hit.entry_index);
            var derived = try entry.derivedAlloc(req.allocator());
            defer derived.deinit(req.allocator());
            const summary = try req.allocator().dupe(u8, derived.summary);
            const raw = if (try entry.rawEnglishAlloc(req.allocator())) |value| value else "";
            const rendered_sections = if (raw.len != 0)
                try renderSectionJsonAlloc(req.allocator(), &req.ctx().db, raw)
            else
                &.{};
            const alias_hint_label = if (derived.alias_hint_label.len != 0)
                try req.allocator().dupe(u8, derived.alias_hint_label)
            else
                "";
            const alt_forms = try dupeSliceOfSlices(req.allocator(), derived.alt_forms.items);
            const canonical_targets = try dupeSliceOfSlices(req.allocator(), derived.canonical_targets.items);
            const incoming_aliases = try entry.incomingAliases().toOwnedSlice(req.allocator());
            const normalized = try entry.normalizedAlloc(req.allocator());

            try payload_hits.append(req.allocator(), .{
                .matched = hit.matched,
                .kind = lookupKindString(hit.kind),
                .entry = .{
                    .word = entry.word(),
                    .normalized = normalized,
                    .aliasOnly = derived.alias_only,
                    .aliasHintLabel = alias_hint_label,
                    .altForms = alt_forms,
                    .canonicalTargets = canonical_targets,
                    .incomingAliases = incoming_aliases,
                    .renderedSections = rendered_sections,
                    .raw = raw,
                    .summary = summary,
                },
            });
        }

        return jsonResponse(req.allocator(), .{
            .query = term,
            .hits = try payload_hits.toOwnedSlice(req.allocator()),
        });
    }
};

const App = blk: {
    @setEvalBranchQuota(12_000);
    break :blk zhttp.Server(.{
    .Context = AppContext,
    .middlewares = .{AssetsMw},
    .operations = .{zhttp.operations.Static},
    .routes = .{
        zhttp.get("/", IndexPage),
        zhttp.get("/entry/{*path}", EntryPage),
        zhttp.get("/api/stats", StatsEndpoint),
        zhttp.get("/api/word-of-day", WordOfDayEndpoint),
        zhttp.get("/api/theme/system", SystemThemeEndpoint),
        zhttp.get("/api/random", RandomEndpoint),
        zhttp.get("/api/search", SearchEndpoint),
        zhttp.get("/api/lookup/{term}", LookupEndpoint),
    },
    });
};

pub fn serve(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const options = ServeOptions{
        .db_path = cli_args.flagValue(args, "--db") orelse "data/wiktionary.bin",
        .port = (try cli_args.parseOptionalIntFlag(u16, args, "--port")) orelse 3000,
    };

    var ctx = try AppContext.init(io, allocator, options);
    defer ctx.deinit();

    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(options.port) };
    std.debug.print("dictionary server ready on http://127.0.0.1:{d}\n", .{options.port});
    std.debug.print("dictionary binary: {s}\n", .{ctx.db_path});
    try App.run(.{
        .gpa = allocator,
        .io = io,
        .address = addr,
        .ctx = &ctx,
    });
}

fn lookupKindString(kind: u8) []const u8 {
    return switch (kind) {
        format.lookup_kind_alternative_form => "alternative_form",
        2 => "alias_expansion",
        else => "title",
    };
}

fn dupeSliceOfSlices(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, values.len);
    for (values, out) |value, *slot| {
        slot.* = try allocator.dupe(u8, value);
    }
    return out;
}

fn renderSectionJsonAlloc(
    allocator: std.mem.Allocator,
    dict: *const decoder.Dictionary,
    raw_english: []const u8,
) ![]const LookupEndpoint.RenderedSectionJson {
    const rendered = try renderer.html_render.renderEnglishSectionWithOptionsAlloc(allocator, raw_english, .{
        .link_resolver = .{
            .context = @ptrCast(dict),
            .resolve = resolveRendererLink,
        },
    });
    const out = try allocator.alloc(LookupEndpoint.RenderedSectionJson, rendered.len);
    for (rendered, out) |section, *slot| {
        slot.* = .{
            .id = section.id,
            .title = section.title,
            .level = section.level,
            .html = section.html,
        };
    }
    return out;
}

fn resolveRendererLink(
    context: *const anyopaque,
    allocator: std.mem.Allocator,
    term: []const u8,
) !?[]const u8 {
    const dict: *const decoder.Dictionary = @ptrCast(@alignCast(context));
    return dict.resolveLinkTargetAlloc(allocator, term);
}

fn htmlResponse(body: []const u8) zhttp.Res {
    return .{
        .status = .ok,
        .headers = html_headers,
        .body = body,
    };
}

fn jsonResponse(allocator: std.mem.Allocator, value: anytype) !zhttp.Res {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    var json_stream: std.json.Stringify = .{
        .writer = &writer.writer,
    };
    try json_stream.write(value);

    return .{
        .status = .ok,
        .headers = json_headers,
        .body = writer.written(),
    };
}

fn currentUtcDayNumber() u64 {
    var now: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &now);
    return @intCast(@divFloor(now.sec, std.time.s_per_day));
}

fn parseDayKey(value: []const u8) !u64 {
    if (value.len != 10 or value[4] != '-' or value[7] != '-') return error.InvalidDayKey;
    const year = try std.fmt.parseInt(i32, value[0..4], 10);
    const month = try std.fmt.parseInt(u8, value[5..7], 10);
    const day = try std.fmt.parseInt(u8, value[8..10], 10);
    if (month < 1 or month > 12) return error.InvalidDayKey;
    if (day < 1 or day > daysInMonth(year, month)) return error.InvalidDayKey;
    return @intCast(daysFromCivil(year, month, day));
}

fn formatDayKeyAlloc(allocator: std.mem.Allocator, day_number: u64) ![]u8 {
    const civil = civilFromDays(@intCast(day_number));
    if (civil.year < 0 or civil.year > 9999) return error.InvalidDayKey;
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u32, @intCast(civil.year)),
        civil.month,
        civil.day,
    });
}

const CivilDate = struct {
    year: i32,
    month: u8,
    day: u8,
};

fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn isLeapYear(year: i32) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or (@mod(year, 400) == 0);
}

fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    var y = year;
    const m: i64 = @intCast(month);
    const d: i64 = @intCast(day);
    y -= if (month <= 2) 1 else 0;
    const era = @divFloor(y, 400);
    const yoe: i64 = y - era * 400;
    const month_bias: i64 = if (m > 2) -3 else 9;
    const doy = @divFloor(153 * (m + month_bias) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(days_since_epoch: i64) CivilDate {
    const z = days_since_epoch + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var year: i32 = @intCast(yoe + era * 400);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const month_bias: i64 = if (mp < 10) 3 else -9;
    const month_i: i64 = mp + month_bias;
    const month: u8 = @intCast(month_i);
    year += if (month <= 2) 1 else 0;
    return .{ .year = year, .month = month, .day = day };
}

fn splitMix64(value: u64) u64 {
    var z = value +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

fn strideForLength(seed: u64, len: usize) usize {
    if (len <= 1) return 1;
    var stride = @as(usize, @intCast(splitMix64(seed ^ 0xd1b54a32d192ed03) % len));
    if (stride == 0) stride = 1;
    while (std.math.gcd(stride, len) != 1) {
        stride = if (stride + 1 >= len) 1 else stride + 1;
    }
    return stride;
}

fn findSelectableIndex(len: usize, day_number: u64, context: anytype) ?u32 {
    if (len == 0) return null;
    const seed = splitMix64(day_number ^ 0x6a09e667f3bcc909);
    var index: usize = @intCast(seed % len);
    const stride = strideForLength(seed, len);
    var attempts: usize = 0;
    while (attempts < len) : (attempts += 1) {
        if (context.isSelectableWord(index)) return @intCast(index);
        index = (index + stride) % len;
    }
    return @intCast(seed % len);
}

test "parseDayKey round trips a civil date" {
    const day_number = try parseDayKey("2026-04-05");
    const formatted = try formatDayKeyAlloc(std.testing.allocator, day_number);
    defer std.testing.allocator.free(formatted);

    try std.testing.expectEqualStrings("2026-04-05", formatted);
}

test "parseDayKey rejects invalid calendar dates" {
    try std.testing.expectError(error.InvalidDayKey, parseDayKey("2026-02-30"));
    try std.testing.expectError(error.InvalidDayKey, parseDayKey("20260405"));
}

test "findSelectableIndex is deterministic and skips unselectable entries" {
    const FakeContext = struct {
        selectable: []const bool,

        fn isSelectableWord(self: @This(), index: usize) bool {
            return self.selectable[index];
        }
    };

    const ctx = FakeContext{ .selectable = &.{ false, false, true, false, true } };
    const first = findSelectableIndex(ctx.selectable.len, 20_185, ctx).?;
    const second = findSelectableIndex(ctx.selectable.len, 20_185, ctx).?;
    const next_day = findSelectableIndex(ctx.selectable.len, 20_186, ctx).?;

    try std.testing.expectEqual(first, second);
    try std.testing.expect(ctx.selectable[first]);
    try std.testing.expect(ctx.selectable[next_day]);
}

test "backend rejects invalidly encoded dictionary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/broken.bin", .{tmp.sub_path});
    defer std.testing.allocator.free(rel_path);

    var file = try tmp.dir.createFile(std.testing.io, "broken.bin", .{ .truncate = true });
    defer file.close(std.testing.io);

    const encoded_title = try compact_encoding.encodeAlloc(std.testing.allocator, "broken");
    defer std.testing.allocator.free(encoded_title);

    var record: std.ArrayList(u8) = .empty;
    defer record.deinit(std.testing.allocator);
    try record.append(std.testing.allocator, format.record_flag_has_raw);
    var len_buf: [10]u8 = undefined;
    try record.appendSlice(std.testing.allocator, format.encodeVarUInt(&len_buf, encoded_title.len));
    try record.appendSlice(std.testing.allocator, encoded_title);
    try record.appendSlice(std.testing.allocator, format.encodeVarUInt(&len_buf, 0));

    const header = format.Header.init(1, 1, 0, @sizeOf(format.Header), record.items.len);
    try file.writePositionalAll(std.testing.io, std.mem.asBytes(&header), 0);
    try file.writePositionalAll(std.testing.io, record.items, @sizeOf(format.Header));

    try std.testing.expectError(error.InvalidDictionaryFile, AppContext.init(std.testing.io, std.testing.allocator, .{
        .db_path = rel_path,
        .port = 0,
    }));
}

test "dupeSliceOfSlices makes owned string copies" {
    var first = try std.testing.allocator.dupe(u8, "alpha");
    defer std.testing.allocator.free(first);
    var second = try std.testing.allocator.dupe(u8, "beta");
    defer std.testing.allocator.free(second);

    const source = [_][]const u8{ first, second };
    const copied = try dupeSliceOfSlices(std.testing.allocator, &source);
    defer {
        for (copied) |value| std.testing.allocator.free(value);
        std.testing.allocator.free(copied);
    }

    first[0] = 'z';
    second[0] = 'y';

    try std.testing.expectEqualStrings("alpha", copied[0]);
    try std.testing.expectEqualStrings("beta", copied[1]);
}
