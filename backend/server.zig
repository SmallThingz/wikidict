const std = @import("std");
const zhttp = @import("zhttp");

const decoder = @import("decoder");
const encoder = @import("encoder");
const renderer = @import("renderer");
const format = encoder.format;
const cli_args = @import("cli_args");

const ReqCtx = zhttp.ReqCtx;
const Header = zhttp.response.Header;

pub const ServeOptions = struct {
    db_path: []const u8 = "data/enwiktionary.bin",
    input_path: []const u8 = "enwiktionary.xml",
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
    // Preloaded SPA shell returned for both `/` and `/entry/...`.
    index_html: []const u8,
    // Monotonic counter used to walk pseudo-randomly across entries without extra state.
    random_counter: std.atomic.Value(u64),

    fn init(io: std.Io, allocator: std.mem.Allocator, options: ServeOptions) !AppContext {
        try ensureDictionary(io, allocator, options);
        return .{
            .allocator = allocator,
            .db = try decoder.openDictionary(allocator, io, options.db_path),
            .db_path = try allocator.dupe(u8, options.db_path),
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
        self.allocator.free(self.index_html);
    }

    fn nextRandomWord(self: *AppContext) []const u8 {
        if (self.db.entries.len == 0) return "";
        const counter = self.random_counter.fetchAdd(0x9e3779b97f4a7c15, .monotonic);
        const index: usize = @intCast(counter % self.db.entries.len);
        return self.db.entryAt(@intCast(index)).word();
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

const App = zhttp.Server(.{
    .Context = AppContext,
    .middlewares = .{AssetsMw},
    .operations = .{zhttp.operations.Static},
    .routes = .{
        zhttp.get("/", IndexPage),
        zhttp.get("/entry/{*path}", EntryPage),
        zhttp.get("/api/stats", StatsEndpoint),
        zhttp.get("/api/random", RandomEndpoint),
        zhttp.get("/api/search", SearchEndpoint),
        zhttp.get("/api/lookup/{term}", LookupEndpoint),
    },
});

pub fn serve(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const options = ServeOptions{
        .db_path = cli_args.flagValue(args, "--db") orelse "data/enwiktionary.bin",
        .port = (try cli_args.parseOptionalIntFlag(u16, args, "--port")) orelse 3000,
        .input_path = cli_args.flagValue(args, "--input") orelse "enwiktionary.xml",
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
    return if (kind == format.lookup_kind_alternative_form) "alternative_form" else "title";
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

fn ensureDictionary(io: std.Io, allocator: std.mem.Allocator, options: ServeOptions) !void {
    if (try dictionaryLooksUsable(io, allocator, options.db_path)) {
        return;
    }

    try deleteFileIfExists(io, options.db_path);
    const cache_path = try std.fmt.allocPrint(allocator, "{s}.idx", .{options.db_path});
    defer allocator.free(cache_path);
    try deleteFileIfExists(io, cache_path);

    std.debug.print(
        "building dictionary binary at {s} from {s}\n",
        .{ options.db_path, options.input_path },
    );

    _ = try encoder.buildDictionary(io, allocator, .{
        .input_path = options.input_path,
        .output_path = options.db_path,
    });
}

fn dictionaryLooksUsable(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !bool {
    var dict = decoder.openDictionary(allocator, io, path) catch |err| switch (err) {
        error.FileNotFound,
        error.InvalidDictionaryFile,
        error.UnsupportedDictionaryVersion,
        error.InvalidDictionaryCache,
        error.InvalidEncoding,
        => return false,
        else => return err,
    };
    defer dict.deinit();

    return dict.header.entry_count != 0 or dict.header.records_len != 0;
}

fn deleteFileIfExists(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
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

test "dictionaryLooksUsable rejects placeholder header-only dictionary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/placeholder.bin", .{tmp.sub_path});
    defer std.testing.allocator.free(rel_path);

    var file = try tmp.dir.createFile(std.testing.io, "placeholder.bin", .{ .truncate = true });
    defer file.close(std.testing.io);
    const header = format.Header.init(0, 0, 0, @sizeOf(format.Header), 0);
    try file.writePositionalAll(std.testing.io, std.mem.asBytes(&header), 0);

    try std.testing.expect(!(try dictionaryLooksUsable(std.testing.io, std.testing.allocator, rel_path)));
}

test "dictionaryLooksUsable rejects invalidly encoded dictionary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/broken.bin", .{tmp.sub_path});
    defer std.testing.allocator.free(rel_path);

    var file = try tmp.dir.createFile(std.testing.io, "broken.bin", .{ .truncate = true });
    defer file.close(std.testing.io);

    const encoded_title = try encoder.compact_encoding.encodeAlloc(std.testing.allocator, "broken");
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

    try std.testing.expect(!(try dictionaryLooksUsable(std.testing.io, std.testing.allocator, rel_path)));
}

test "ensureDictionary rebuilds placeholder dictionary from xml input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const xml_rel = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/sample.xml", .{tmp.sub_path});
    defer std.testing.allocator.free(xml_rel);
    const db_rel = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/dict.bin", .{tmp.sub_path});
    defer std.testing.allocator.free(db_rel);

    var xml_file = try tmp.dir.createFile(std.testing.io, "sample.xml", .{ .truncate = true });
    defer xml_file.close(std.testing.io);
    try xml_file.writePositionalAll(std.testing.io,
        \\<mediawiki>
        \\<page>
        \\<title>color</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\# [[light]]
        \\</text></revision>
        \\</page>
        \\</mediawiki>
    , 0);

    var placeholder = try tmp.dir.createFile(std.testing.io, "dict.bin", .{ .truncate = true });
    defer placeholder.close(std.testing.io);
    const header = format.Header.init(0, 0, 0, @sizeOf(format.Header), 0);
    try placeholder.writePositionalAll(std.testing.io, std.mem.asBytes(&header), 0);

    try ensureDictionary(std.testing.io, std.testing.allocator, .{
        .db_path = db_rel,
        .input_path = xml_rel,
    });

    var dict = try decoder.openDictionary(std.testing.allocator, std.testing.io, db_rel);
    defer dict.deinit();
    try std.testing.expect(dict.header.entry_count != 0);

    const hits = try dict.lookupExact(std.testing.allocator, "color");
    defer std.testing.allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
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
