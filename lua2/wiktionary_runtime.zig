const std = @import("std");
const ir = @import("vm_ir.zig");
const codec = @import("vm_codec.zig");
const bundle = @import("vm_bundle.zig");
const exec = @import("vm_exec.zig");
const rt = @import("vm_runtime.zig");
const lib = @import("lua_stdlib.zig");
const ustring_lib = @import("scribunto_ustring.zig");
const language_lib = @import("mw_language.zig");
const html_lib = @import("mw_html.zig");
const lua_pattern = @import("lua_pattern.zig");
const parser_expr = @import("parser_expr.zig");

const Value = rt.Value;
const ManifestRow = struct { page_id: u64, title: []const u8 };

const State = enum { unloaded, loading, loaded };
const ModuleSlot = struct {
    page_id: u64,
    title: []const u8,
    program: ?*ir.Program = null,
};
const ModuleState = struct {
    state: State = .unloaded,
    value: Value = .nil,
    loader: ?Value = null,
};
const TemplateSlot = struct {
    page_id: u64,
    title: []const u8,
    redirect: ?[]const u8 = null,
    body: ?[]const u8 = null,
    transcluded: ?[]const u8 = null,
};

const InterwikiRow = struct {
    prefix: []const u8,
    url: []const u8,
    is_local: bool,
    is_current_wiki: bool,
    is_protocol_relative: bool,
};

const MappedBundle = struct {
    bytes: []align(std.heap.page_size_min) const u8,

    fn deinit(self: *MappedBundle) void {
        std.posix.munmap(self.bytes);
    }
};

const LoaderCtx = struct { runtime: *Runtime, slot: *ModuleSlot };
const StubCtx = struct { runtime: *Runtime, name: []const u8 };

pub const PageContentProvider = struct {
    ctx: *anyopaque,
    get: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, title: []const u8) anyerror!?[]const u8,
    exists: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, title: []const u8) anyerror!bool,
};

fn installUstringStringAliases(a: std.mem.Allocator, string: *rt.Table, ustring: *rt.Table) !void {
    inline for (.{
        .{ "isutf8", "isutf8" },
        .{ "byteoffset", "byteoffset" },
        .{ "codepoint", "codepoint" },
        .{ "gcodepoint", "gcodepoint" },
        .{ "toNFC", "toNFC" },
        .{ "toNFD", "toNFD" },
        .{ "uchar", "char" },
        .{ "ulen", "len" },
        .{ "usub", "sub" },
        .{ "uupper", "upper" },
        .{ "ulower", "lower" },
        .{ "ufind", "find" },
        .{ "umatch", "match" },
        .{ "ugmatch", "gmatch" },
        .{ "ugsub", "gsub" },
    }) |entry| try string.rawSet(a, .{ .string = entry[0] }, ustring.rawGet(.{ .string = entry[1] }) orelse return error.MissingUstringFunction);
}

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    page_allocator: std.mem.Allocator,
    persistent_allocator: std.mem.Allocator,
    io: std.Io,
    modules_dir: []const u8,
    modules: std.StringHashMapUnmanaged(*ModuleSlot) = .empty,
    module_states: std.AutoHashMapUnmanaged(*ModuleSlot, *ModuleState) = .empty,
    load_data_cache: std.AutoHashMapUnmanaged(*ModuleSlot, Value) = .empty,
    load_data_loading: std.AutoHashMapUnmanaged(*ModuleSlot, void) = .empty,
    redirects: std.StringHashMapUnmanaged([]const u8) = .empty,
    program_titles: std.AutoHashMapUnmanaged(*const ir.Program, []const u8) = .empty,
    bundle_map: ?MappedBundle = null,
    bundle_index: ?bundle.BlobIndex = null,
    templates: std.StringHashMapUnmanaged(*TemplateSlot) = .empty,
    templates_dir: ?[]const u8 = null,
    wikibase_sitelinks: std.StringHashMapUnmanaged([]const u8) = .empty,
    wikibase_absent_sitelinks: std.StringHashMapUnmanaged(void) = .empty,
    interwiki_rows: std.ArrayList(InterwikiRow) = .empty,
    title_metatable: ?*rt.Table = null,
    title_equals: ?Value = null,
    package_loaded: ?*rt.Table = null,
    package_loaders: ?*rt.Table = null,
    current_frame: ?*rt.Table = null,
    current_page_title: []const u8 = "Smoke",
    current_page_source: ?[]const u8 = null,
    current_page_revision_id: []const u8 = "",
    page_now_unix: i64 = 0,
    page_content_provider: ?PageContentProvider = null,
    last_missing_module: ?[]const u8 = null,
    last_missing_template: ?[]const u8 = null,
    last_missing_wikibase: ?[]const u8 = null,
    last_malformed_wikitext: ?[]const u8 = null,
    last_unsupported_parser: ?[]const u8 = null,
    last_not_implemented: ?[]const u8 = null,
    page_heading_count: usize = 0,
    fake_heading_count: usize = 0,
    strip_counter: u32 = 0,
    strip_values: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    page_line: std.ArrayList(u8) = .empty,

    const InvocationState = struct {
        module_states: std.AutoHashMapUnmanaged(*ModuleSlot, *ModuleState),
        title_metatable: ?*rt.Table,
        title_equals: ?Value,
        package_loaded: ?*rt.Table,
        package_loaders: ?*rt.Table,
        current_frame: ?*rt.Table,
    };

    fn saveInvocationState(self: *Runtime) InvocationState {
        return .{
            .module_states = self.module_states,
            .title_metatable = self.title_metatable,
            .title_equals = self.title_equals,
            .package_loaded = self.package_loaded,
            .package_loaders = self.package_loaders,
            .current_frame = self.current_frame,
        };
    }

    fn resetInvocationState(self: *Runtime) void {
        self.module_states = .empty;
        self.title_metatable = null;
        self.title_equals = null;
        self.package_loaded = null;
        self.package_loaders = null;
        self.current_frame = null;
    }

    fn restoreInvocationState(self: *Runtime, state: InvocationState) void {
        self.module_states = state.module_states;
        self.title_metatable = state.title_metatable;
        self.title_equals = state.title_equals;
        self.package_loaded = state.package_loaded;
        self.package_loaders = state.package_loaders;
        self.current_frame = state.current_frame;
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io, modules_dir: []const u8) Runtime {
        return .{ .allocator = allocator, .page_allocator = allocator, .persistent_allocator = allocator, .io = io, .modules_dir = modules_dir };
    }
    pub fn setPageContentProvider(self: *Runtime, provider: PageContentProvider) void {
        self.page_content_provider = provider;
    }

    pub fn setCurrentRevisionId(self: *Runtime, revision_id: []const u8) void {
        self.current_page_revision_id = revision_id;
    }

    pub fn setPageNowUnix(self: *Runtime, timestamp: i64) void {
        self.page_now_unix = timestamp;
    }

    pub fn beginPage(self: *Runtime, allocator: std.mem.Allocator, page_title: []const u8) void {
        self.allocator = allocator;
        self.page_allocator = allocator;
        self.module_states = .empty;
        self.load_data_cache = .empty;
        self.load_data_loading = .empty;
        self.title_metatable = null;
        self.title_equals = null;
        self.package_loaded = null;
        self.package_loaders = null;
        self.current_frame = null;
        self.current_page_title = page_title;
        self.current_page_source = null;
        self.current_page_revision_id = "";
        self.page_now_unix = std.Io.Clock.real.now(self.io).toSeconds();
        self.last_missing_module = null;
        self.last_missing_template = null;
        self.last_missing_wikibase = null;
        self.last_malformed_wikitext = null;
        self.last_unsupported_parser = null;
        self.last_not_implemented = null;
        self.page_heading_count = 0;
        self.fake_heading_count = 0;
        self.strip_counter = 0;
        self.strip_values = .empty;
        self.page_line = .empty;
    }

    pub fn loadBundle(self: *Runtime, path: []const u8) !void {
        if (self.bundle_map) |*mapped| mapped.deinit();
        const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
        const bytes = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
        self.bundle_map = .{ .bytes = bytes };
        self.bundle_index = try bundle.index(self.persistent_allocator, bytes);
    }

    pub fn loadManifest(self: *Runtime, path: []const u8) !void {
        const bytes = try readAll(self.io, self.persistent_allocator, path);
        var pos: usize = 0;
        while (pos < bytes.len) {
            const nl = std.mem.indexOfScalarPos(u8, bytes, pos, '\n') orelse bytes.len;
            const line = bytes[pos..nl];
            pos = @min(nl + 1, bytes.len);
            if (line.len == 0) continue;
            const row = try std.json.parseFromSliceLeaky(ManifestRow, self.persistent_allocator, line, .{ .ignore_unknown_fields = true });
            const slot = try self.persistent_allocator.create(ModuleSlot);
            slot.* = .{ .page_id = row.page_id, .title = row.title };
            try self.modules.put(self.persistent_allocator, row.title, slot);
        }
    }

    pub fn loadRedirects(self: *Runtime, usage_path: []const u8) !void {
        const bytes = try readAll(self.io, self.persistent_allocator, usage_path);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "M\t")) continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            _ = fields.next();
            const from = fields.next() orelse continue;
            const to = fields.next() orelse continue;
            try self.redirects.put(self.persistent_allocator, try unescape(self.persistent_allocator, from), try unescape(self.persistent_allocator, to));
        }
    }
    pub fn loadSiblingTemplates(self: *Runtime) !void {
        const slash = std.mem.lastIndexOfScalar(u8, self.modules_dir, '/') orelse return error.ModulesDirNeedsParent;
        const root = self.modules_dir[0..slash];
        const manifest = try std.fmt.allocPrint(self.persistent_allocator, "{s}/template-manifest.tsv", .{root});
        const dir = try std.fmt.allocPrint(self.persistent_allocator, "{s}/templates", .{root});
        try self.loadTemplateManifest(manifest, dir);
    }

    pub fn loadSiblingWikibaseSitelinks(self: *Runtime) !void {
        const slash = std.mem.lastIndexOfScalar(u8, self.modules_dir, '/') orelse return error.ModulesDirNeedsParent;
        const root = self.modules_dir[0..slash];
        const path = try std.fmt.allocPrint(self.persistent_allocator, "{s}/wikibase-sitelinks.tsv", .{root});
        try self.loadWikibaseSitelinks(path);
    }

    pub fn loadWikibaseSitelinks(self: *Runtime, path: []const u8) !void {
        const bytes = try readAll(self.io, self.persistent_allocator, path);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const qid = fields.next() orelse continue;
            const site = fields.next() orelse continue;
            const title_raw = fields.next() orelse continue;
            const key = try std.fmt.allocPrint(self.persistent_allocator, "{s}\x1f{s}", .{ qid, site });
            if (title_raw.len == 0) {
                try self.wikibase_absent_sitelinks.put(self.persistent_allocator, key, {});
            } else {
                const title = try unescape(self.persistent_allocator, title_raw);
                try self.wikibase_sitelinks.put(self.persistent_allocator, key, title);
            }
        }
    }

    const WikibaseSitelinkLookup = union(enum) {
        title: []const u8,
        absent,
        unknown,
    };

    fn wikibaseSitelink(self: *Runtime, qid: []const u8, site: []const u8) !WikibaseSitelinkLookup {
        const key = try std.fmt.allocPrint(self.allocator, "{s}\x1f{s}", .{ qid, site });
        if (self.wikibase_sitelinks.get(key)) |title| return .{ .title = title };
        if (self.wikibase_absent_sitelinks.contains(key)) return .absent;
        return .unknown;
    }

    pub fn loadSiblingInterwikiMap(self: *Runtime) !void {
        const slash = std.mem.lastIndexOfScalar(u8, self.modules_dir, '/') orelse return error.ModulesDirNeedsParent;
        const root = self.modules_dir[0..slash];
        const path = try std.fmt.allocPrint(self.persistent_allocator, "{s}/interwiki-map.tsv", .{root});
        try self.loadInterwikiMap(path);
    }

    pub fn loadInterwikiMap(self: *Runtime, path: []const u8) !void {
        const bytes = try readAll(self.io, self.persistent_allocator, path);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const prefix_raw = fields.next() orelse continue;
            const local_raw = fields.next() orelse continue;
            const current_raw = fields.next() orelse continue;
            const protocol_raw = fields.next() orelse continue;
            const url_raw = fields.next() orelse continue;
            try self.interwiki_rows.append(self.persistent_allocator, .{
                .prefix = try unescape(self.persistent_allocator, prefix_raw),
                .url = try unescape(self.persistent_allocator, url_raw),
                .is_local = std.mem.eql(u8, local_raw, "1"),
                .is_current_wiki = std.mem.eql(u8, current_raw, "1"),
                .is_protocol_relative = std.mem.eql(u8, protocol_raw, "1"),
            });
        }
    }

    pub fn loadTemplateManifest(self: *Runtime, manifest_path: []const u8, templates_dir: []const u8) !void {
        self.templates_dir = try self.persistent_allocator.dupe(u8, templates_dir);
        const bytes = try readAll(self.io, self.persistent_allocator, manifest_path);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const id_raw = fields.next() orelse continue;
            const title_raw = fields.next() orelse continue;
            _ = fields.next(); // source byte count
            const redirect_raw = fields.next() orelse "";
            const id = std.fmt.parseInt(u64, id_raw, 10) catch continue;
            const title_decoded = try unescape(self.persistent_allocator, title_raw);
            const title = try normalizeTemplateName(self.persistent_allocator, title_decoded);
            const slot = try self.persistent_allocator.create(TemplateSlot);
            slot.* = .{
                .page_id = id,
                .title = title,
                .redirect = if (redirect_raw.len == 0) null else try normalizeTemplateName(self.persistent_allocator, try unescape(self.persistent_allocator, redirect_raw)),
            };
            try self.templates.put(self.persistent_allocator, title, slot);
        }
    }

    fn canonicalTemplateSlot(self: *Runtime, raw_name: []const u8) !?*TemplateSlot {
        var name = try normalizeTemplateName(self.allocator, raw_name);
        var depth: usize = 0;
        while (self.templates.get(name)) |slot| {
            if (slot.redirect) |target| {
                if (depth >= 64) return error.TemplateRedirectLoop;
                name = target;
                depth += 1;
                continue;
            }
            return slot;
        }
        return null;
    }

    fn ensureTemplateBody(self: *Runtime, slot: *TemplateSlot) ![]const u8 {
        if (slot.transcluded) |text| return text;
        const dir = self.templates_dir orelse return error.TemplateStoreNotLoaded;
        if (slot.body == null) {
            const path = try std.fmt.allocPrint(self.persistent_allocator, "{s}/{d}.wiki", .{ dir, slot.page_id });
            slot.body = try readAll(self.io, self.persistent_allocator, path);
        }
        slot.transcluded = try transcludeDecodedAlloc(self.persistent_allocator, slot.body.?);
        return slot.transcluded.?;
    }

    fn observePageLine(self: *Runtime, raw: []const u8) void {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len < 3 or line[0] != '=') return;
        var left: usize = 0;
        while (left < line.len and left < 6 and line[left] == '=') : (left += 1) {}
        if (left == 0 or left >= line.len) return;
        var end = std.mem.trimEnd(u8, line, " \t").len;
        var right: usize = 0;
        while (end > 0 and right < 6 and line[end - 1] == '=') : (right += 1) end -= 1;
        if (right < left or end <= left) return;
        self.page_heading_count += 1;
    }

    fn observePageOutput(self: *Runtime, text: []const u8) !void {
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, text, start, '\n')) |nl| {
            try self.page_line.appendSlice(self.page_allocator, text[start..nl]);
            self.observePageLine(self.page_line.items);
            self.page_line.items.len = 0;
            start = nl + 1;
        }
        try self.page_line.appendSlice(self.page_allocator, text[start..]);
    }

    fn noteMalformed(self: *Runtime, host_title: []const u8, text: []const u8, open: usize, kind: []const u8) void {
        const end = @min(text.len, open + 240);
        self.last_malformed_wikitext = std.fmt.allocPrint(self.allocator, "{s}\t{s}\t{s}", .{ host_title, kind, text[open..end] }) catch host_title;
    }

    pub fn expandFragment(self: *Runtime, vm: *exec.Vm, page_title: []const u8, source: []const u8) anyerror![]const u8 {
        self.current_page_title = page_title;
        // Keep the exact raw source for mw.title:getContent(); Wiktionary's own
        // parser deliberately observes comments. The MediaWiki preprocessor,
        // however, removes comments before interpreting template arguments.
        self.current_page_source = source;
        const preprocessed = try stripDecodedComments(self.allocator, source);
        const params = try rt.newTable(self.allocator);
        return self.expandPageWikitext(vm, preprocessed, params, page_title);
    }

    fn expandPageWikitext(self: *Runtime, vm: *exec.Vm, text: []const u8, params: *rt.Table, host_title: []const u8) anyerror![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, text, pos, "{{")) |open| {
            const literal = text[pos..open];
            try self.observePageOutput(literal);
            try out.appendSlice(self.allocator, literal);
            const expanded = if (open + 2 < text.len and text[open + 2] == '{') blk: {
                const close = findParamEnd(text, open) orelse {
                    const literal_open = "{{{";
                    try self.observePageOutput(literal_open);
                    try out.appendSlice(self.allocator, literal_open);
                    pos = open + literal_open.len;
                    continue;
                };
                const value = try self.expandParameter(vm, text[open + 3 .. close], params, host_title, 1);
                pos = close + 3;
                break :blk value;
            } else blk: {
                const close = findTemplateEnd(text, open) orelse {
                    const literal_open = "{{";
                    try self.observePageOutput(literal_open);
                    try out.appendSlice(self.allocator, literal_open);
                    pos = open + literal_open.len;
                    continue;
                };
                const value = try self.expandConstruct(vm, text[open + 2 .. close], params, host_title, 1);
                pos = close + 2;
                break :blk value;
            };
            try self.observePageOutput(expanded);
            try out.appendSlice(self.allocator, expanded);
        }
        const tail = text[pos..];
        try self.observePageOutput(tail);
        try out.appendSlice(self.allocator, tail);
        return out.toOwnedSlice(self.allocator);
    }

    fn expandTemplateByName(self: *Runtime, vm: *exec.Vm, raw_name: []const u8, args: *rt.Table, depth: usize) anyerror![]const u8 {
        if (depth > 128) return error.TemplateDepth;
        const slot = try self.canonicalTemplateSlot(raw_name) orelse {
            self.last_missing_template = try self.allocator.dupe(u8, raw_name);
            return error.TemplateNotFound;
        };
        const body = try self.ensureTemplateBody(slot);
        return self.expandWikitext(vm, body, args, slot.title, depth + 1);
    }

    fn expandWikitext(self: *Runtime, vm: *exec.Vm, text: []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        if (depth > 128) return error.TemplateDepth;
        var out: std.ArrayList(u8) = .empty;
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, text, pos, "{{")) |open| {
            try out.appendSlice(self.allocator, text[pos..open]);
            if (open + 2 < text.len and text[open + 2] == '{') {
                const close = findParamEnd(text, open) orelse {
                    const literal_open = "{{{";
                    try out.appendSlice(self.allocator, literal_open);
                    pos = open + literal_open.len;
                    continue;
                };
                const expanded = try self.expandParameter(vm, text[open + 3 .. close], params, host_title, depth + 1);
                try out.appendSlice(self.allocator, expanded);
                pos = close + 3;
            } else {
                const close = findTemplateEnd(text, open) orelse {
                    const literal_open = "{{";
                    try out.appendSlice(self.allocator, literal_open);
                    pos = open + literal_open.len;
                    continue;
                };
                const expanded = try self.expandConstruct(vm, text[open + 2 .. close], params, host_title, depth + 1);
                try out.appendSlice(self.allocator, expanded);
                pos = close + 2;
            }
        }
        try out.appendSlice(self.allocator, text[pos..]);
        return out.toOwnedSlice(self.allocator);
    }

    fn expandParameter(self: *Runtime, vm: *exec.Vm, inside: []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const split = splitParameter(inside);
        const expanded_key = try self.expandWikitext(vm, split.key, params, host_title, depth + 1);
        const key_text = std.mem.trim(u8, expanded_key, " \t\r\n");
        const key: Value = if (std.fmt.parseInt(i64, key_text, 10)) |n| .{ .number = @floatFromInt(n) } else |_| .{ .string = key_text };
        if (params.rawGet(key)) |value| return valueToWikitext(self.allocator, value);
        if (split.default) |fallback| return self.expandWikitext(vm, fallback, params, host_title, depth + 1);
        return std.fmt.allocPrint(self.allocator, "{{{{{{{s}}}}}}}", .{inside});
    }

    fn buildExpandedArgs(self: *Runtime, vm: *exec.Vm, raw_args: []const []const u8, caller_params: *rt.Table, host_title: []const u8, depth: usize) anyerror!*rt.Table {
        const out = try rt.newTable(self.allocator);
        var positional: i64 = 1;
        for (raw_args) |raw| {
            if (findTopDelimiter(raw, '=')) |eq| {
                const key_expanded = try self.expandWikitext(vm, raw[0..eq], caller_params, host_title, depth + 1);
                const key_text = std.mem.trim(u8, key_expanded, " \t\r\n");
                if (key_text.len == 0) continue;
                const key: Value = if (std.fmt.parseInt(i64, key_text, 10)) |n| .{ .number = @floatFromInt(n) } else |_| .{ .string = key_text };
                const value_raw = std.mem.trim(u8, raw[eq + 1 ..], " \t\r\n");
                const value = try self.expandWikitext(vm, value_raw, caller_params, host_title, depth + 1);
                try out.rawSet(self.allocator, key, .{ .string = value });
            } else {
                const value = try self.expandWikitext(vm, raw, caller_params, host_title, depth + 1);
                try out.rawSet(self.allocator, .{ .number = @floatFromInt(positional) }, .{ .string = value });
                positional += 1;
            }
        }
        return out;
    }

    fn expandConstruct(self: *Runtime, vm: *exec.Vm, content: []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        try splitWikitextTop(self.allocator, content, '|', &parts);
        if (parts.items.len == 0) {
            self.noteMalformed(host_title, content, 0, "empty construct");
            return error.MalformedWikitext;
        }
        var raw_head = std.mem.trim(u8, parts.items[0], " \t\r\n");
        if (raw_head.len == 0) {
            self.noteMalformed(host_title, content, 0, "empty head");
            return error.MalformedWikitext;
        }
        // `subst:` and `safesubst:` are preprocessor modifiers, not part of
        // the template/parser-function title.  Dumped templates commonly use
        // `safesubst:<noinclude/>#invoke:...`; transclusion stripping removes
        // the noinclude tag before this point, leaving the modifier to strip.
        if (raw_head.len >= 10 and std.ascii.eqlIgnoreCase(raw_head[0..10], "safesubst:"))
            raw_head = std.mem.trim(u8, raw_head[10..], " \t\r\n")
        else if (raw_head.len >= 6 and std.ascii.eqlIgnoreCase(raw_head[0..6], "subst:"))
            raw_head = std.mem.trim(u8, raw_head[6..], " \t\r\n");
        if (raw_head.len == 0) {
            self.noteMalformed(host_title, content, 0, "empty head after subst");
            return error.MalformedWikitext;
        }

        if (try magicWord(self, raw_head)) |value| return value;
        if (findTopDelimiter(raw_head, ':')) |colon| {
            const name = std.mem.trim(u8, raw_head[0..colon], " \t\r\n");
            const first = raw_head[colon + 1 ..];
            if (std.ascii.eqlIgnoreCase(name, "uc"))
                return self.expandCaseParser(vm, first, params, host_title, depth + 1, true, false);
            if (std.ascii.eqlIgnoreCase(name, "lc"))
                return self.expandCaseParser(vm, first, params, host_title, depth + 1, false, false);
            if (std.ascii.eqlIgnoreCase(name, "ucfirst"))
                return self.expandCaseParser(vm, first, params, host_title, depth + 1, true, true);
            if (std.ascii.eqlIgnoreCase(name, "lcfirst"))
                return self.expandCaseParser(vm, first, params, host_title, depth + 1, false, true);
            if (std.ascii.eqlIgnoreCase(name, "fullurl"))
                return self.expandFullUrlParser(vm, first, parts.items[1..], params, host_title, depth + 1, false);
            if (std.ascii.eqlIgnoreCase(name, "fullurle"))
                return self.expandFullUrlParser(vm, first, parts.items[1..], params, host_title, depth + 1, true);
            if (std.ascii.eqlIgnoreCase(name, "localurl"))
                return self.expandLocalOrCanonicalUrlParser(vm, first, parts.items[1..], params, host_title, depth + 1, .local);
            if (std.ascii.eqlIgnoreCase(name, "canonicalurl"))
                return self.expandLocalOrCanonicalUrlParser(vm, first, parts.items[1..], params, host_title, depth + 1, .canonical);
            if (std.ascii.eqlIgnoreCase(name, "urlencode"))
                return self.expandUrlencodeParser(vm, first, parts.items[1..], params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "padleft"))
                return self.expandPadParser(vm, first, parts.items[1..], params, host_title, depth + 1, true);
            if (std.ascii.eqlIgnoreCase(name, "padright"))
                return self.expandPadParser(vm, first, parts.items[1..], params, host_title, depth + 1, false);
            if (std.ascii.eqlIgnoreCase(name, "#invoke"))
                return self.expandInvoke(vm, first, parts.items[1..], params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#if")) {
                const condition_text = try self.expandWikitext(vm, first, params, host_title, depth + 1);
                const chosen = if (std.mem.trim(u8, condition_text, " \t\r\n").len != 0)
                    (if (parts.items.len > 1) parts.items[1] else "")
                else
                    (if (parts.items.len > 2) parts.items[2] else "");
                return self.expandWikitext(vm, chosen, params, host_title, depth + 1);
            }
            if (std.ascii.eqlIgnoreCase(name, "#ifeq"))
                return self.expandIfEq(vm, first, parts.items[1..], params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#ifexist"))
                return self.expandIfExist(vm, first, parts.items[1..], params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#switch"))
                return self.expandSwitch(vm, first, parts.items[1..], params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#expr"))
                return self.expandExprParser(vm, first, params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#ifexpr"))
                return self.expandIfExpr(vm, first, parts.items[1..], params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#tag"))
                return self.expandTagParser(vm, first, parts.items[1..], params, host_title, depth + 1);
            if (name.len != 0 and name[0] == '#') {
                self.last_unsupported_parser = try self.allocator.dupe(u8, raw_head);
                return error.UnsupportedParserFunction;
            }
        }
        if (raw_head[0] == '#') {
            self.last_unsupported_parser = try self.allocator.dupe(u8, raw_head);
            return error.UnsupportedParserFunction;
        }
        const title = try self.expandWikitext(vm, raw_head, params, host_title, depth + 1);
        const args = try self.buildExpandedArgs(vm, parts.items[1..], params, host_title, depth + 1);
        return self.expandTemplateByName(vm, title, args, depth + 1);
    }

    fn pageExists(self: *Runtime, raw_title: []const u8) anyerror!bool {
        var title = try normalizeName(self.allocator, raw_title);
        if (title.len != 0 and title[0] == ':')
            title = std.mem.trim(u8, title[1..], " \t\r\n");
        if (title.len == 0) return false;
        if (std.mem.indexOfScalar(u8, title, '#')) |hash| title = title[0..hash];
        if (title.len == 0) return false;

        if (std.mem.eql(u8, title, self.current_page_title) and self.current_page_source != null) return true;
        if (self.page_content_provider) |provider|
            if (try provider.exists(provider.ctx, self.allocator, title)) return true;

        const ns = namespaceOf(title);
        if (ns.id == 828) return (try self.canonicalSlot(title)) != null;
        if (ns.id == 10) return (try self.canonicalTemplateSlot(title)) != null;
        return false;
    }

    fn expandIfExist(self: *Runtime, vm: *exec.Vm, raw_title: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const expanded_title = try self.expandWikitext(vm, raw_title, params, host_title, depth + 1);
        const exists = try self.pageExists(expanded_title);
        const chosen = if (exists)
            (if (args.len > 0) args[0] else "")
        else
            (if (args.len > 1) args[1] else "");
        return self.expandWikitext(vm, chosen, params, host_title, depth + 1);
    }

    fn expandTagParser(self: *Runtime, vm: *exec.Vm, raw_tag: []const u8, raw_args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const expanded_tag = try self.expandWikitext(vm, raw_tag, params, host_title, depth + 1);
        const tag = std.mem.trim(u8, expanded_tag, " \t\r\n");
        if (!std.ascii.eqlIgnoreCase(tag, "ref") and !std.ascii.eqlIgnoreCase(tag, "references")) {
            self.last_unsupported_parser = try std.fmt.allocPrint(self.allocator, "#tag:{s}", .{tag});
            return error.UnsupportedParserFunction;
        }
        const content = if (raw_args.len == 0)
            ""
        else
            try self.expandWikitext(vm, raw_args[0], params, host_title, depth + 1);
        var attrs: ?*rt.Table = null;
        if (raw_args.len > 1) {
            const table = try rt.newTable(self.allocator);
            for (raw_args[1..]) |raw| {
                const eq = findTopDelimiter(raw, '=') orelse continue;
                const raw_key = std.mem.trim(u8, raw[0..eq], " \t\r\n");
                if (raw_key.len == 0) continue;
                const key_expanded = try self.expandWikitext(vm, raw_key, params, host_title, depth + 1);
                const key = std.mem.trim(u8, key_expanded, " \t\r\n");
                if (key.len == 0) continue;
                const value = try self.expandWikitext(vm, raw[eq + 1 ..], params, host_title, depth + 1);
                try table.rawSet(self.allocator, .{ .string = key }, .{ .string = value });
            }
            attrs = table;
        }
        return serializeExtensionTag(self.allocator, if (std.ascii.eqlIgnoreCase(tag, "ref")) "ref" else "references", content, attrs);
    }

    fn unicodeCase(_: *Runtime, vm: *exec.Vm, text: []const u8, upper: bool) anyerror![]const u8 {
        const mw = vm.globals.rawGet(.{ .string = "mw" }) orelse return error.MissingMw;
        if (mw != .table) return error.MissingMw;
        const ustring = mw.table.rawGet(.{ .string = "ustring" }) orelse return error.MissingUstring;
        if (ustring != .table) return error.MissingUstring;
        const function = ustring.table.rawGet(.{ .string = if (upper) "upper" else "lower" }) orelse return error.MissingUstringFunction;
        const result = try vm.callValue(function, &.{.{ .string = text }});
        defer exec.Vm.freeResults(result);
        if (result.len == 0 or result[0] != .string) return error.StringExpected;
        return result[0].string;
    }

    fn expandCaseParser(self: *Runtime, vm: *exec.Vm, raw: []const u8, params: *rt.Table, host_title: []const u8, depth: usize, upper: bool, first_only: bool) anyerror![]const u8 {
        const expanded = try self.expandWikitext(vm, raw, params, host_title, depth + 1);
        if (!first_only or expanded.len == 0) return self.unicodeCase(vm, expanded, upper);
        const first_len = std.unicode.utf8ByteSequenceLength(expanded[0]) catch return error.InvalidUtf8;
        if (first_len > expanded.len) return error.InvalidUtf8;
        const first = try self.unicodeCase(vm, expanded[0..first_len], upper);
        return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ first, expanded[first_len..] });
    }

    fn expandFullUrlParser(self: *Runtime, vm: *exec.Vm, raw: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize, escaped: bool) anyerror![]const u8 {
        const title = std.mem.trim(u8, try self.expandWikitext(vm, raw, params, host_title, depth + 1), " \t\r\n");
        const query: ?[]const u8 = if (args.len == 0) null else try self.expandWikitext(vm, args[0], params, host_title, depth + 1);
        return buildWikiUrlRawQuery(self.allocator, title, query, .full, escaped, null);
    }

    fn expandLocalOrCanonicalUrlParser(self: *Runtime, vm: *exec.Vm, raw: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize, kind: WikiUrlKind) anyerror![]const u8 {
        const title = std.mem.trim(u8, try self.expandWikitext(vm, raw, params, host_title, depth + 1), " \t\r\n");
        const query: ?[]const u8 = if (args.len == 0) null else try self.expandWikitext(vm, args[0], params, host_title, depth + 1);
        return buildWikiUrlRawQuery(self.allocator, title, query, kind, false, null);
    }

    fn expandUrlencodeParser(self: *Runtime, vm: *exec.Vm, raw: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const expanded = try self.expandWikitext(vm, raw, params, host_title, depth + 1);
        var call_args: [2]Value = undefined;
        call_args[0] = .{ .string = expanded };
        var count: usize = 1;
        if (args.len != 0) {
            const mode = std.mem.trim(u8, try self.expandWikitext(vm, args[0], params, host_title, depth + 1), " \t\r\n");
            if (mode.len != 0) {
                call_args[1] = .{ .string = mode };
                count = 2;
            }
        }
        const result = try uriEncodeCall(null, vm, call_args[0..count], self.allocator);
        defer exec.Vm.freeResults(result);
        if (result.len == 0 or result[0] != .string) return error.StringExpected;
        return result[0].string;
    }

    fn appendRepeatedPad(out: *std.ArrayList(u8), a: std.mem.Allocator, pad: []const u8, count: usize) !void {
        if (count == 0 or pad.len == 0) return;
        var remaining = count;
        while (remaining != 0) {
            var i: usize = 0;
            while (i < pad.len and remaining != 0) : (remaining -= 1) {
                const len = std.unicode.utf8ByteSequenceLength(pad[i]) catch return error.InvalidUtf8;
                if (i + len > pad.len) return error.InvalidUtf8;
                try out.appendSlice(a, pad[i .. i + len]);
                i += len;
            }
        }
    }

    fn expandPadParser(self: *Runtime, vm: *exec.Vm, raw: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize, left: bool) anyerror![]const u8 {
        const source = try self.expandWikitext(vm, raw, params, host_title, depth + 1);
        const target_raw = if (args.len != 0)
            std.mem.trim(u8, try self.expandWikitext(vm, args[0], params, host_title, depth + 1), " \t\r\n")
        else
            "0";
        const target = std.fmt.parseInt(usize, target_raw, 10) catch return source;
        const source_len = std.unicode.utf8CountCodepoints(source) catch return error.InvalidUtf8;
        if (target <= source_len) return source;
        const pad = if (args.len > 1)
            try self.expandWikitext(vm, args[1], params, host_title, depth + 1)
        else
            "0";
        if (pad.len == 0) return source;
        _ = std.unicode.utf8CountCodepoints(pad) catch return error.InvalidUtf8;
        const need = target - source_len;
        var out: std.ArrayList(u8) = .empty;
        if (left) {
            try appendRepeatedPad(&out, self.allocator, pad, need);
            try out.appendSlice(self.allocator, source);
        } else {
            try out.appendSlice(self.allocator, source);
            try appendRepeatedPad(&out, self.allocator, pad, need);
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn exprError(self: *Runtime, err: anyerror) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "<strong class=\"error\">Expression error: {s}</strong>", .{@errorName(err)});
    }

    fn expandExprParser(self: *Runtime, vm: *exec.Vm, raw: []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const expanded = std.mem.trim(u8, try self.expandWikitext(vm, raw, params, host_title, depth + 1), " \t\r\n");
        const value = parser_expr.eval(self.allocator, expanded) catch |err| return self.exprError(err);
        return parser_expr.format(self.allocator, value) catch |err| return self.exprError(err);
    }

    fn expandIfExpr(self: *Runtime, vm: *exec.Vm, raw: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const expanded = std.mem.trim(u8, try self.expandWikitext(vm, raw, params, host_title, depth + 1), " \t\r\n");
        const value = parser_expr.eval(self.allocator, expanded) catch |err| return self.exprError(err);
        const chosen = if (value != 0)
            (if (args.len > 0) args[0] else "")
        else
            (if (args.len > 1) args[1] else "");
        return self.expandWikitext(vm, chosen, params, host_title, depth + 1);
    }

    fn expandInvoke(self: *Runtime, vm: *exec.Vm, module_expr: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const module_raw = try self.expandWikitext(vm, module_expr, params, host_title, depth + 1);
        const module_trimmed = std.mem.trim(u8, module_raw, " \t\r\n");
        const module_name = if (module_trimmed.len >= 7 and std.ascii.eqlIgnoreCase(module_trimmed[0..7], "Module:"))
            module_trimmed
        else
            try std.fmt.allocPrint(self.allocator, "Module:{s}", .{module_trimmed});
        const function_name = if (args.len != 0)
            std.mem.trim(u8, try self.expandWikitext(vm, args[0], params, host_title, depth + 1), " \t\r\n")
        else
            "main";
        const page_allocator = self.allocator;
        var invoke_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer invoke_arena.deinit();
        const saved_diagnostics = self.saveDiagnostics();
        var diagnostics_failed = false;
        defer if (!diagnostics_failed) self.restoreDiagnostics(saved_diagnostics);
        errdefer {
            diagnostics_failed = true;
            self.preserveLoadDataDiagnostics(page_allocator);
        }

        self.allocator = invoke_arena.allocator();
        defer self.allocator = page_allocator;

        const invoke_args = try self.buildExpandedArgs(vm, if (args.len > 0) args[1..] else &.{}, params, host_title, depth + 1);
        const parent = try makeFrameWithArgsTable(self, host_title, params, null);
        const frame = try makeFrameWithArgsTable(self, module_name, invoke_args, parent);

        // Scribunto's mw.executeModule() runs every #invoke in a fresh cloned
        // environment. In particular package.loaded and module-local state must
        // not leak from an earlier #invoke on the same page.
        const saved_invocation = self.saveInvocationState();
        self.resetInvocationState();
        defer self.restoreInvocationState(saved_invocation);
        var invoke_vm = try exec.Vm.init(self.allocator);
        try self.install(&invoke_vm);
        const result = invoke(self, &invoke_vm, module_name, function_name, frame) catch |err| {
            vm.failure = invoke_vm.failure;
            vm.last_error = switch (invoke_vm.last_error) {
                .string => |text| .{ .string = try page_allocator.dupe(u8, text) },
                .nil, .boolean, .number => invoke_vm.last_error,
                .table, .closure, .native => .nil,
            };
            return err;
        };
        defer exec.Vm.freeResults(result);
        if (result.len == 0) return "";
        const rendered = try valueToWikitext(self.allocator, result[0]);
        return page_allocator.dupe(u8, rendered);
    }

    fn expandIfEq(self: *Runtime, vm: *exec.Vm, lhs_raw: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const lhs = std.mem.trim(u8, try self.expandWikitext(vm, lhs_raw, params, host_title, depth + 1), " \t\r\n");
        const rhs = if (args.len != 0) std.mem.trim(u8, try self.expandWikitext(vm, args[0], params, host_title, depth + 1), " \t\r\n") else "";
        const chosen = if (std.mem.eql(u8, lhs, rhs))
            (if (args.len > 1) args[1] else "")
        else
            (if (args.len > 2) args[2] else "");
        return self.expandWikitext(vm, chosen, params, host_title, depth + 1);
    }

    fn expandSwitch(self: *Runtime, vm: *exec.Vm, key_raw: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const key = std.mem.trim(u8, try self.expandWikitext(vm, key_raw, params, host_title, depth + 1), " \t\r\n");
        var pending = false;
        var fallback: ?[]const u8 = null;
        var trailing: ?[]const u8 = null;
        for (args) |raw_case| {
            if (findTopDelimiter(raw_case, '=')) |eq| {
                const label_raw = std.mem.trim(u8, raw_case[0..eq], " \t\r\n");
                const value_raw = raw_case[eq + 1 ..];
                if (std.ascii.eqlIgnoreCase(label_raw, "#default")) {
                    fallback = value_raw;
                    if (pending) return self.expandWikitext(vm, value_raw, params, host_title, depth + 1);
                    continue;
                }
                const label = std.mem.trim(u8, try self.expandWikitext(vm, label_raw, params, host_title, depth + 1), " \t\r\n");
                if (pending or std.mem.eql(u8, key, label))
                    return self.expandWikitext(vm, value_raw, params, host_title, depth + 1);
                pending = false;
            } else {
                trailing = raw_case;
                const label = std.mem.trim(u8, try self.expandWikitext(vm, raw_case, params, host_title, depth + 1), " \t\r\n");
                if (std.mem.eql(u8, key, label)) pending = true;
            }
        }
        if (fallback) |value| return self.expandWikitext(vm, value, params, host_title, depth + 1);
        if (trailing) |value| return self.expandWikitext(vm, value, params, host_title, depth + 1);
        return "";
    }

    pub fn install(self: *Runtime, vm: *exec.Vm) !void {
        try lib.install(vm);
        const package = try rt.newTable(self.allocator);
        const loaded = try rt.newTable(self.allocator);
        const loaders = try rt.newTable(self.allocator);
        self.package_loaded = loaded;
        self.package_loaders = loaders;
        try package.rawSet(self.allocator, .{ .string = "loaded" }, .{ .table = loaded });
        try package.rawSet(self.allocator, .{ .string = "loaders" }, .{ .table = loaders });
        try loaders.rawSet(self.allocator, .{ .number = 2 }, try rt.newNative(self.allocator, self, mainLoaderCall));
        try vm.globals.rawSet(self.allocator, .{ .string = "package" }, .{ .table = package });
        try vm.globals.rawSet(self.allocator, .{ .string = "require" }, try rt.newNative(self.allocator, self, requireCall));

        const mw = try rt.newTable(self.allocator);
        try mw.rawSet(self.allocator, .{ .string = "loadData" }, try rt.newNative(self.allocator, self, loadDataCall));
        try mw.rawSet(self.allocator, .{ .string = "clone" }, try rt.newNative(self.allocator, self, cloneCall));
        try mw.rawSet(self.allocator, .{ .string = "getCurrentFrame" }, try rt.newNative(self.allocator, self, currentFrameCall));
        const ustring = try rt.newTable(self.allocator);
        if (vm.globals.rawGet(.{ .string = "string" })) |string_value| if (string_value == .table) {
            var it = string_value.table.map.iterator();
            while (it.next()) |entry| try ustring.rawSet(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
        };
        try ustring_lib.install(self.allocator, ustring);
        if (vm.globals.rawGet(.{ .string = "string" })) |string_value| if (string_value == .table)
            try installUstringStringAliases(self.allocator, string_value.table, ustring);
        try mw.rawSet(self.allocator, .{ .string = "ustring" }, .{ .table = ustring });
        try installMwBasics(self, vm, mw);
        try vm.globals.rawSet(self.allocator, .{ .string = "mw" }, .{ .table = mw });
    }

    fn canonicalSlot(self: *Runtime, raw_name: []const u8) !?*ModuleSlot {
        if (self.modules.get(raw_name)) |slot| return slot;
        const normalized = try normalizeName(self.allocator, raw_name);
        if (self.modules.get(normalized)) |slot| return slot;
        var name = normalized;
        var depth: usize = 0;
        while (self.redirects.get(name)) |target| {
            if (depth >= 64) return error.RedirectLoop;
            if (self.modules.get(target)) |slot| return slot;
            name = target;
            depth += 1;
        }
        return null;
    }
    fn ensureCompiled(self: *Runtime, slot: *ModuleSlot) !void {
        if (slot.program != null) return;
        const index = self.bundle_index orelse return error.ModuleBundleNotLoaded;
        const blob = index.get(slot.title) orelse return error.ModuleNotInBundle;
        const program = try self.persistent_allocator.create(ir.Program);
        program.* = try codec.deserializeBorrowed(self.persistent_allocator, blob);
        slot.program = program;
        try self.program_titles.put(self.persistent_allocator, program, slot.title);
    }

    fn stateFor(self: *Runtime, slot: *ModuleSlot) !*ModuleState {
        if (self.module_states.get(slot)) |state| return state;
        const state = try self.allocator.create(ModuleState);
        state.* = .{};
        try self.module_states.put(self.allocator, slot, state);
        return state;
    }

    fn requireSlot(self: *Runtime, vm: *exec.Vm, slot: *ModuleSlot) !Value {
        const state = try self.stateFor(slot);
        if (state.state == .loaded) return state.value;
        if (state.state == .loading) return error.ModuleLoadLoop;
        try self.ensureCompiled(slot);
        state.state = .loading;
        errdefer state.state = .unloaded;
        const result = try vm.executeRoot(slot.program.?, &.{.{ .string = slot.title }});
        defer exec.Vm.freeResults(result);
        var value = if (result.len != 0) result[0] else Value.nil;
        if (value == .nil) {
            if (self.package_loaded.?.rawGet(.{ .string = slot.title })) |loaded| value = loaded else value = .{ .boolean = true };
        }
        if (value == .table and std.mem.eql(u8, slot.title, "Module:Scribunto"))
            try self.installScribuntoFastPaths(value.table);
        if (std.mem.eql(u8, slot.title, "Module:memoize"))
            value = try self.installMemoizeFastPath(value);
        if (std.mem.eql(u8, slot.title, "Module:string/char"))
            value = try self.installStringCharFastPath(value);
        if (std.mem.eql(u8, slot.title, "Module:table/shallowCopy"))
            value = try self.installShallowCopyFastPath(value);
        try self.package_loaded.?.rawSet(self.allocator, .{ .string = slot.title }, value);
        state.value = value;
        state.state = .loaded;
        return value;
    }

    fn installScribuntoFastPath(self: *Runtime, exports: *rt.Table, name: []const u8, call: rt.NativeCall) !void {
        const original = exports.rawGet(.{ .string = name }) orelse return;
        const ctx = try self.allocator.create(HotLuaFallbackCtx);
        ctx.* = .{ .original = original };
        try exports.rawSet(self.allocator, .{ .string = name }, try rt.newNative(self.allocator, ctx, call));
    }

    fn installScribuntoFastPaths(self: *Runtime, exports: *rt.Table) !void {
        try self.installScribuntoFastPath(exports, "php_trim", scribuntoPhpTrimFastCall);
        try self.installScribuntoFastPath(exports, "scribunto_parameter_key", scribuntoParameterKeyFastCall);
    }

    fn installShallowCopyFastPath(self: *Runtime, original: Value) !Value {
        const ctx = try self.allocator.create(HotLuaFallbackCtx);
        ctx.* = .{ .original = original };
        return rt.newNative(self.allocator, ctx, shallowCopyFastCall);
    }

    fn installStringCharFastPath(self: *Runtime, original: Value) !Value {
        const ctx = try self.allocator.create(HotLuaFallbackCtx);
        ctx.* = .{ .original = original };
        return rt.newNative(self.allocator, ctx, stringCharFastCall);
    }

    fn installMemoizeFastPath(self: *Runtime, original: Value) !Value {
        const ctx = try self.allocator.create(MemoizeFactoryCtx);
        ctx.* = .{ .original = original };
        return rt.newNative(self.allocator, ctx, memoizeFactoryFastCall);
    }

    pub fn requireByName(self: *Runtime, vm: *exec.Vm, raw_name: []const u8) !Value {
        if (self.package_loaded.?.rawGet(.{ .string = raw_name })) |value| return value;
        const slot = try self.canonicalSlot(raw_name) orelse {
            self.last_missing_module = raw_name;
            return error.ModuleNotFound;
        };
        const value = try self.requireSlot(vm, slot);
        try self.package_loaded.?.rawSet(self.allocator, .{ .string = raw_name }, value);
        return value;
    }

    fn promoteLoadDataValue(self: *Runtime, value: Value, seen: *std.AutoHashMapUnmanaged(*rt.Table, *rt.Table)) !Value {
        return switch (value) {
            .nil, .boolean, .number => value,
            .string => |text| .{ .string = try self.page_allocator.dupe(u8, text) },
            .closure, .native => error.LoadDataUnsupportedValue,
            .table => |source| blk: {
                if (source.metatable != null) return error.LoadDataMetatable;
                if (seen.get(source)) |existing| break :blk .{ .table = existing };
                const copy = try rt.newTable(self.page_allocator);
                try seen.put(self.allocator, source, copy);
                var it = source.map.iterator();
                while (it.next()) |entry| {
                    const key = try self.promoteLoadDataValue(entry.key_ptr.*, seen);
                    const item = try self.promoteLoadDataValue(entry.value_ptr.*, seen);
                    try copy.rawSet(self.page_allocator, key, item);
                }
                copy.append_index = source.append_index;
                copy.read_only = true;
                break :blk .{ .table = copy };
            },
        };
    }

    const diagnostic_fields = .{ "last_missing_module", "last_missing_template", "last_missing_wikibase", "last_malformed_wikitext", "last_unsupported_parser", "last_not_implemented" };
    const DiagnosticState = [diagnostic_fields.len]?[]const u8;
    fn saveDiagnostics(self: *const Runtime) DiagnosticState {
        var saved: DiagnosticState = undefined;
        inline for (diagnostic_fields, 0..) |field, i| saved[i] = @field(self, field);
        return saved;
    }
    fn restoreDiagnostics(self: *Runtime, saved: DiagnosticState) void {
        inline for (diagnostic_fields, 0..) |field, i| @field(self, field) = saved[i];
    }
    fn preserveLoadDataDiagnostics(self: *Runtime, caller_allocator: std.mem.Allocator) void {
        if (self.last_missing_module) |v| self.last_missing_module = caller_allocator.dupe(u8, v) catch null;
        if (self.last_missing_template) |v| self.last_missing_template = caller_allocator.dupe(u8, v) catch null;
        if (self.last_missing_wikibase) |v| self.last_missing_wikibase = caller_allocator.dupe(u8, v) catch null;
        if (self.last_malformed_wikitext) |v| self.last_malformed_wikitext = caller_allocator.dupe(u8, v) catch null;
        if (self.last_unsupported_parser) |v| self.last_unsupported_parser = caller_allocator.dupe(u8, v) catch null;
        if (self.last_not_implemented) |v| self.last_not_implemented = caller_allocator.dupe(u8, v) catch null;
    }

    fn loadDataByName(self: *Runtime, raw_name: []const u8) !Value {
        const slot = try self.canonicalSlot(raw_name) orelse {
            self.last_missing_module = raw_name;
            return error.ModuleNotFound;
        };
        if (self.load_data_cache.get(slot)) |value| return value;
        if (self.load_data_loading.contains(slot)) return error.LoadDataLoop;
        try self.load_data_loading.put(self.page_allocator, slot, {});
        defer _ = self.load_data_loading.remove(slot);

        const caller_allocator = self.allocator;
        var eval_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer eval_arena.deinit();
        const saved_diagnostics = self.saveDiagnostics();
        var diagnostics_failed = false;
        defer if (!diagnostics_failed) self.restoreDiagnostics(saved_diagnostics);
        errdefer {
            diagnostics_failed = true;
            self.preserveLoadDataDiagnostics(caller_allocator);
        }

        const saved = self.saveInvocationState();
        self.allocator = eval_arena.allocator();
        self.resetInvocationState();
        defer {
            self.restoreInvocationState(saved);
            self.allocator = caller_allocator;
        }

        var data_vm = try exec.Vm.init(self.allocator);
        try self.install(&data_vm);
        const empty_args = try rt.newTable(self.allocator);
        const empty_frame = try makeFrameWithArgsTable(self, "empty", empty_args, null);
        self.current_frame = empty_frame.table;
        const raw_value = try self.requireSlot(&data_vm, slot);
        if (raw_value != .table) return error.LoadDataExpectedTable;
        var seen: std.AutoHashMapUnmanaged(*rt.Table, *rt.Table) = .empty;
        const value = try self.promoteLoadDataValue(raw_value, &seen);
        try self.load_data_cache.put(self.page_allocator, slot, value);
        return value;
    }
    fn loaderFor(self: *Runtime, slot: *ModuleSlot) !Value {
        const state = try self.stateFor(slot);
        if (state.loader) |loader| return loader;
        const ctx = try self.allocator.create(LoaderCtx);
        ctx.* = .{ .runtime = self, .slot = slot };
        const loader = try rt.newNative(self.allocator, ctx, loaderCall);
        state.loader = loader;
        return loader;
    }

    fn cloneValue(self: *Runtime, value: Value) !Value {
        var seen: std.AutoHashMapUnmanaged(*rt.Table, *rt.Table) = .empty;
        return self.cloneValueSeen(value, &seen);
    }

    fn cloneValueSeen(self: *Runtime, value: Value, seen: *std.AutoHashMapUnmanaged(*rt.Table, *rt.Table)) !Value {
        if (value != .table) return value;
        if (seen.get(value.table)) |old| return .{ .table = old };
        const copy = try rt.newTable(self.allocator);
        try seen.put(self.allocator, value.table, copy);
        var it = value.table.map.iterator();
        while (it.next()) |entry| {
            const key = try self.cloneValueSeen(entry.key_ptr.*, seen);
            const val = try self.cloneValueSeen(entry.value_ptr.*, seen);
            try copy.rawSet(self.allocator, key, val);
        }
        if (value.table.metatable) |mt|
            copy.metatable = (try self.cloneValueSeen(.{ .table = mt }, seen)).table;
        return .{ .table = copy };
    }
};

fn requireCall(ctx: ?*anyopaque, raw_vm: *anyopaque, args: []const Value, _: std.mem.Allocator) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.ModuleNameExpected;
    const runtime: *Runtime = @ptrCast(@alignCast(ctx.?));
    const vm: *exec.Vm = @ptrCast(@alignCast(raw_vm));
    const out = try std.heap.smp_allocator.alloc(Value, 1);
    out[0] = try runtime.requireByName(vm, args[0].string);
    return out;
}
fn loaderCall(ctx: ?*anyopaque, raw_vm: *anyopaque, _: []const Value, _: std.mem.Allocator) ![]const Value {
    const loader: *LoaderCtx = @ptrCast(@alignCast(ctx.?));
    const vm: *exec.Vm = @ptrCast(@alignCast(raw_vm));
    const out = try std.heap.smp_allocator.alloc(Value, 1);
    out[0] = try loader.runtime.requireSlot(vm, loader.slot);
    return out;
}

fn mainLoaderCall(ctx: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.ModuleNameExpected;
    const runtime: *Runtime = @ptrCast(@alignCast(ctx.?));
    const slot = try runtime.canonicalSlot(args[0].string) orelse return one(a, .nil);
    return one(a, try runtime.loaderFor(slot));
}

const MemoizeFactoryCtx = struct { original: Value };

const SimpleMemoCtx = struct {
    func: Value,
    memo: *rt.Table,
    nil_key: *rt.Table,
    neg_zero_key: *rt.Table,
    pos_nan_key: *rt.Table,
    neg_nan_key: *rt.Table,
    nil_output: *rt.Table,
};

fn memoSentinel(a: std.mem.Allocator) !*rt.Table {
    return rt.newTable(a);
}

fn memoSimpleKey(ctx: *SimpleMemoCtx, value: Value) Value {
    return switch (value) {
        .nil => .{ .table = ctx.nil_key },
        .number => |n| blk: {
            const bits: u64 = @bitCast(n);
            if (std.math.isNan(n))
                break :blk .{ .table = if ((bits >> 63) == 0) ctx.pos_nan_key else ctx.neg_nan_key };
            if (n == 0 and (bits >> 63) != 0)
                break :blk .{ .table = ctx.neg_zero_key };
            break :blk value;
        },
        else => value,
    };
}

fn simpleMemoCall(ctx_raw: ?*anyopaque, raw_vm: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    const ctx: *SimpleMemoCtx = @ptrCast(@alignCast(ctx_raw.?));
    const key = memoSimpleKey(ctx, if (args.len == 0) .nil else args[0]);
    if (ctx.memo.rawGet(key)) |cached| {
        if (cached == .table and cached.table == ctx.nil_output) return one(a, .nil);
        return one(a, cached);
    }
    const vm: *exec.Vm = @ptrCast(@alignCast(raw_vm));
    const results = try vm.callValue(ctx.func, args);
    defer exec.Vm.freeResults(results);
    const output: Value = if (results.len == 0) .nil else results[0];
    try ctx.memo.rawSet(a, key, if (output == .nil) .{ .table = ctx.nil_output } else output);
    return one(a, output);
}

fn memoizeFactoryFastCall(ctx_raw: ?*anyopaque, raw_vm: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len < 2 or !Value.truthy(args[1]))
        return callHotFallback(ctx_raw, raw_vm, args);
    const ctx = try a.create(SimpleMemoCtx);
    ctx.* = .{
        .func = if (args.len == 0) .nil else args[0],
        .memo = try rt.newTable(a),
        .nil_key = try memoSentinel(a),
        .neg_zero_key = try memoSentinel(a),
        .pos_nan_key = try memoSentinel(a),
        .neg_nan_key = try memoSentinel(a),
        .nil_output = try memoSentinel(a),
    };
    return one(a, try rt.newNative(a, ctx, simpleMemoCall));
}

const HotLuaFallbackCtx = struct { original: Value };

fn callHotFallback(ctx_raw: ?*anyopaque, raw_vm: *anyopaque, args: []const Value) ![]const Value {
    const ctx: *HotLuaFallbackCtx = @ptrCast(@alignCast(ctx_raw.?));
    const vm: *exec.Vm = @ptrCast(@alignCast(raw_vm));
    return vm.callValue(ctx.original, args);
}

fn isPhpTrimByte(c: u8) bool {
    return c == 0 or c == ' ' or c == '\t' or c == '\n' or c == 0x0b or c == '\r';
}

fn phpTrimSlice(text: []const u8) []const u8 {
    var first: usize = 0;
    while (first < text.len and isPhpTrimByte(text[first])) : (first += 1) {}
    var last = text.len;
    while (last > first and isPhpTrimByte(text[last - 1])) : (last -= 1) {}
    return text[first..last];
}

fn shallowCopyFastCall(ctx_raw: ?*anyopaque, raw_vm: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len == 0) return one(a, .nil);
    if (args[0] != .table) return one(a, args[0]);
    const source = args[0].table;
    const raw = args.len > 1 and Value.truthy(args[1]);
    if (!raw and source.metatable != null) return callHotFallback(ctx_raw, raw_vm, args);
    const copy = try rt.newTable(a);
    var it = source.map.iterator();
    while (it.next()) |entry|
        try copy.rawSet(a, entry.key_ptr.*, entry.value_ptr.*);
    return one(a, .{ .table = copy });
}

fn utf8EncodedLen(cp: u32) usize {
    return if (cp < 0x80) 1 else if (cp < 0x800) 2 else if (cp < 0x10000) 3 else 4;
}

fn encodeRawCodepoint(out: []u8, cp: u32) usize {
    if (cp < 0x80) {
        out[0] = @intCast(cp);
        return 1;
    }
    if (cp < 0x800) {
        out[0] = @intCast(0xC0 + (cp >> 6));
        out[1] = @intCast(0x80 + (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = @intCast(0xE0 + (cp >> 12));
        out[1] = @intCast(0x80 + ((cp >> 6) & 0x3F));
        out[2] = @intCast(0x80 + (cp & 0x3F));
        return 3;
    }
    out[0] = @intCast(0xF0 + (cp >> 18));
    out[1] = @intCast(0x80 + ((cp >> 12) & 0x3F));
    out[2] = @intCast(0x80 + ((cp >> 6) & 0x3F));
    out[3] = @intCast(0x80 + (cp & 0x3F));
    return 4;
}

fn stringCharFastCall(ctx_raw: ?*anyopaque, raw_vm: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len == 0) return &.{};
    var bytes: usize = 0;
    for (args) |arg| {
        if (arg != .number) return callHotFallback(ctx_raw, raw_vm, args);
        const n = arg.number;
        if (!std.math.isFinite(n) or n < 0 or n > 0x10FFFF or @floor(n) != n)
            return callHotFallback(ctx_raw, raw_vm, args);
        bytes += utf8EncodedLen(@intFromFloat(n));
    }
    const out = try a.alloc(u8, bytes);
    var pos: usize = 0;
    for (args) |arg| {
        const cp: u32 = @intFromFloat(arg.number);
        pos += encodeRawCodepoint(out[pos..], cp);
    }
    return one(a, .{ .string = out });
}

fn scribuntoPhpTrimFastCall(ctx_raw: ?*anyopaque, raw_vm: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len != 0 and args[0] == .string)
        return one(a, .{ .string = phpTrimSlice(args[0].string) });
    return callHotFallback(ctx_raw, raw_vm, args);
}

fn smallScribuntoInteger(text: []const u8) ?f64 {
    if (std.mem.eql(u8, text, "0")) return 0;
    var pos: usize = 0;
    var negative = false;
    if (text.len != 0 and text[0] == '-') {
        negative = true;
        pos = 1;
    }
    if (pos >= text.len or text[pos] < '1' or text[pos] > '9') return null;
    var n: u64 = 0;
    while (pos < text.len) : (pos += 1) {
        const c = text[pos];
        if (c < '0' or c > '9') return null;
        const digit: u64 = c - '0';
        if (n > 900719925474099 or (n == 900719925474099 and digit > 2)) return null;
        n = n * 10 + digit;
    }
    const v: f64 = @floatFromInt(n);
    return if (negative) -v else v;
}

fn scribuntoParameterKeyFastCall(ctx_raw: ?*anyopaque, raw_vm: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len == 0) return one(a, .nil);
    switch (args[0]) {
        .string => |raw| {
            const no_trim = args.len > 1 and Value.truthy(args[1]);
            const text = if (no_trim) raw else phpTrimSlice(raw);
            if (smallScribuntoInteger(text)) |n| return one(a, .{ .number = n });
            return one(a, .{ .string = text });
        },
        .number => |n| {
            if (std.math.isFinite(n) and @floor(n) == n and n >= -9007199254740992.0 and n <= 9007199254740992.0)
                return one(a, .{ .number = n });
            return callHotFallback(ctx_raw, raw_vm, args);
        },
        else => return one(a, .nil),
    }
}

fn loadDataCall(ctx: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.ModuleNameExpected;
    const runtime: *Runtime = @ptrCast(@alignCast(ctx.?));
    return one(a, try runtime.loadDataByName(args[0].string));
}

fn cloneCall(ctx: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len == 0) return one(a, .nil);
    const runtime: *Runtime = @ptrCast(@alignCast(ctx.?));
    return one(a, try runtime.cloneValue(args[0]));
}

fn one(_: std.mem.Allocator, value: Value) ![]const Value {
    const out = try std.heap.smp_allocator.alloc(Value, 1);
    out[0] = value;
    return out;
}
fn readAll(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    const out = try a.alloc(u8, len);
    _ = try file.readPositionalAll(io, out, 0);
    return out;
}

fn normalizeName(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.indexOfScalar(u8, trimmed, '_') == null) return trimmed;
    const out = try a.dupe(u8, trimmed);
    std.mem.replaceScalar(u8, out, '_', ' ');
    return out;
}

fn normalizeTemplateName(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const name = std.mem.trim(u8, raw, " \t\r\n");
    const has_prefix = name.len >= 9 and std.ascii.eqlIgnoreCase(name[0..9], "Template:");
    const body = if (has_prefix) std.mem.trim(u8, name[9..], " \t\r\n") else name;
    const out = try a.alloc(u8, 9 + body.len);
    @memcpy(out[0..9], "Template:");
    @memcpy(out[9..], body);
    for (out) |*c| if (c.* == '_') {
        c.* = ' ';
    };
    return out;
}

fn findCiPos(hay: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return @min(start, hay.len);
    var i = start;
    while (i + needle.len <= hay.len) : (i += 1)
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return i;
    return null;
}

fn decodedTagEnd(text: []const u8, start: usize) ?usize {
    const p = std.mem.indexOfScalarPos(u8, text, start, '>') orelse return null;
    return p + 1;
}

fn decodedSelfClosing(text: []const u8, start: usize, end: usize) bool {
    if (end <= start + 1) return false;
    var i = end - 2;
    while (i > start and std.ascii.isWhitespace(text[i])) : (i -= 1) {}
    return text[i] == '/';
}

fn stripDecodedComments(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (findCiPos(text, pos, "<!--")) |open| {
        try out.appendSlice(a, text[pos..open]);
        const close = findCiPos(text, open + 4, "-->") orelse {
            pos = text.len;
            break;
        };
        pos = close + 3;
    }
    try out.appendSlice(a, text[pos..]);
    return out.toOwnedSlice(a);
}

fn appendDecodedTranscludedRange(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, begin: usize, end: usize) !void {
    var pos = begin;
    while (pos < end) {
        const lt = std.mem.indexOfScalarPos(u8, text, pos, '<') orelse {
            try out.appendSlice(a, text[pos..end]);
            break;
        };
        if (lt >= end) {
            try out.appendSlice(a, text[pos..end]);
            break;
        }
        try out.appendSlice(a, text[pos..lt]);
        if (findCiPos(text, lt, "<noinclude") == lt) {
            const open_end = decodedTagEnd(text, lt) orelse return error.MalformedTransclusionTag;
            if (open_end > end) return error.MalformedTransclusionTag;
            if (decodedSelfClosing(text, lt, open_end)) {
                pos = open_end;
                continue;
            }
            const close = findCiPos(text, open_end, "</noinclude") orelse return error.MalformedTransclusionTag;
            pos = decodedTagEnd(text, close) orelse return error.MalformedTransclusionTag;
            continue;
        }
        if (findCiPos(text, lt, "</noinclude") == lt or
            findCiPos(text, lt, "<includeonly") == lt or
            findCiPos(text, lt, "</includeonly") == lt or
            findCiPos(text, lt, "<onlyinclude") == lt or
            findCiPos(text, lt, "</onlyinclude") == lt)
        {
            pos = decodedTagEnd(text, lt) orelse return error.MalformedTransclusionTag;
            continue;
        }
        try out.append(a, '<');
        pos = lt + 1;
    }
}

fn transcludeDecodedAlloc(a: std.mem.Allocator, text: []const u8) ![]u8 {
    const no_comments = try stripDecodedComments(a, text);
    var out: std.ArrayList(u8) = .empty;
    if (findCiPos(no_comments, 0, "<onlyinclude")) |_| {
        var pos: usize = 0;
        while (findCiPos(no_comments, pos, "<onlyinclude")) |open| {
            const open_end = decodedTagEnd(no_comments, open) orelse break;
            const close = findCiPos(no_comments, open_end, "</onlyinclude") orelse break;
            try appendDecodedTranscludedRange(a, &out, no_comments, open_end, close);
            pos = decodedTagEnd(no_comments, close) orelse no_comments.len;
        }
    } else try appendDecodedTranscludedRange(a, &out, no_comments, 0, no_comments.len);
    return out.toOwnedSlice(a);
}

fn unescape(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '\\' or i + 1 >= raw.len) {
            try out.append(a, raw[i]);
            i += 1;
            continue;
        }
        i += 1;
        const c = raw[i];
        i += 1;
        try out.append(a, switch (c) {
            't' => '\t',
            'n' => '\n',
            'r' => '\r',
            '\\' => '\\',
            else => c,
        });
    }
    return out.toOwnedSlice(a);
}

fn findTemplateEnd(s: []const u8, start: usize) ?usize {
    if (start + 1 >= s.len or !std.mem.eql(u8, s[start .. start + 2], "{{")) return null;
    var stack: [128]u8 = undefined;
    var depth: usize = 1;
    stack[0] = 2;
    var i = start + 2;
    while (i < s.len) {
        if (i + 2 < s.len and std.mem.eql(u8, s[i .. i + 3], "{{{")) {
            if (depth == stack.len) return null;
            stack[depth] = 3;
            depth += 1;
            i += 3;
            continue;
        }
        if (i + 1 < s.len and std.mem.eql(u8, s[i .. i + 2], "{{")) {
            if (depth == stack.len) return null;
            stack[depth] = 2;
            depth += 1;
            i += 2;
            continue;
        }
        if (stack[depth - 1] == 3 and i + 2 < s.len and std.mem.eql(u8, s[i .. i + 3], "}}}")) {
            depth -= 1;
            i += 3;
            continue;
        }
        if (stack[depth - 1] == 2 and i + 1 < s.len and std.mem.eql(u8, s[i .. i + 2], "}}")) {
            depth -= 1;
            if (depth == 0) return i;
            i += 2;
            continue;
        }
        i += 1;
    }
    return null;
}

fn findParamEnd(s: []const u8, start: usize) ?usize {
    if (start + 2 >= s.len or !std.mem.eql(u8, s[start .. start + 3], "{{{")) return null;
    var stack: [128]u8 = undefined;
    var depth: usize = 1;
    stack[0] = 3;
    var i = start + 3;
    while (i < s.len) {
        if (i + 2 < s.len and std.mem.eql(u8, s[i .. i + 3], "{{{")) {
            if (depth == stack.len) return null;
            stack[depth] = 3;
            depth += 1;
            i += 3;
            continue;
        }
        if (i + 1 < s.len and std.mem.eql(u8, s[i .. i + 2], "{{")) {
            if (depth == stack.len) return null;
            stack[depth] = 2;
            depth += 1;
            i += 2;
            continue;
        }
        if (stack[depth - 1] == 3 and i + 2 < s.len and std.mem.eql(u8, s[i .. i + 3], "}}}")) {
            depth -= 1;
            if (depth == 0) return i;
            i += 3;
            continue;
        }
        if (stack[depth - 1] == 2 and i + 1 < s.len and std.mem.eql(u8, s[i .. i + 2], "}}")) {
            depth -= 1;
            i += 2;
            continue;
        }
        i += 1;
    }
    return null;
}

fn isOpaqueParserTag(name: []const u8) bool {
    inline for (&.{
        "nowiki",  "pre",      "gallery",      "indicator",  "ref",             "references", "templatestyles",
        "math",    "ce",       "chem",         "score",      "syntaxhighlight", "source",     "timeline",
        "hiero",   "poem",     "categorytree", "charinsert", "graph",           "mapframe",   "maplink",
        "section", "inputbox", "imagemap",
    }) |tag| if (std.ascii.eqlIgnoreCase(name, tag)) return true;
    return false;
}

fn rawTagEnd(s: []const u8, start: usize) ?usize {
    var quote: u8 = 0;
    var i = start + 1;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            continue;
        }
        if (c == '>') return i + 1;
    }
    return null;
}

fn opaqueParserRegionEnd(s: []const u8, start: usize) ?usize {
    if (start >= s.len or s[start] != '<') return null;
    if (std.mem.startsWith(u8, s[start..], "<!--")) {
        const close = std.mem.indexOfPos(u8, s, start + 4, "-->") orelse return s.len;
        return close + 3;
    }
    var p = start + 1;
    if (p >= s.len or s[p] == '/') return null;
    while (p < s.len and std.ascii.isWhitespace(s[p])) : (p += 1) {}
    const name_start = p;
    while (p < s.len and (std.ascii.isAlphanumeric(s[p]) or s[p] == '-')) : (p += 1) {}
    if (p == name_start) return null;
    const name = s[name_start..p];
    if (!isOpaqueParserTag(name)) return null;
    const open_end = rawTagEnd(s, start) orelse return s.len;
    var before_gt = open_end - 1;
    while (before_gt > start and std.ascii.isWhitespace(s[before_gt - 1])) : (before_gt -= 1) {}
    if (before_gt > start and s[before_gt - 1] == '/') return open_end;

    var search = open_end;
    while (std.mem.indexOfScalarPos(u8, s, search, '<')) |lt| {
        if (lt + 2 + name.len <= s.len and s[lt + 1] == '/' and std.ascii.eqlIgnoreCase(s[lt + 2 .. lt + 2 + name.len], name)) {
            const after = lt + 2 + name.len;
            if (after >= s.len or s[after] == '>' or std.ascii.isWhitespace(s[after]))
                return rawTagEnd(s, lt) orelse s.len;
        }
        search = lt + 1;
    }
    return s.len;
}

fn findTopDelimiter(s: []const u8, needle: u8) ?usize {
    var braces: [128]u8 = undefined;
    var brace_depth: usize = 0;
    var square: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (opaqueParserRegionEnd(s, i)) |end| {
            i = end;
            continue;
        }
        if (i + 2 < s.len and std.mem.eql(u8, s[i .. i + 3], "{{{")) {
            if (brace_depth == braces.len) return null;
            braces[brace_depth] = 3;
            brace_depth += 1;
            i += 3;
            continue;
        }
        if (i + 1 < s.len and std.mem.eql(u8, s[i .. i + 2], "{{")) {
            if (brace_depth == braces.len) return null;
            braces[brace_depth] = 2;
            brace_depth += 1;
            i += 2;
            continue;
        }
        if (brace_depth != 0 and braces[brace_depth - 1] == 3 and i + 2 < s.len and std.mem.eql(u8, s[i .. i + 3], "}}}")) {
            brace_depth -= 1;
            i += 3;
            continue;
        }
        if (brace_depth != 0 and braces[brace_depth - 1] == 2 and i + 1 < s.len and std.mem.eql(u8, s[i .. i + 2], "}}")) {
            brace_depth -= 1;
            i += 2;
            continue;
        }
        if (i + 1 < s.len and std.mem.eql(u8, s[i .. i + 2], "[[")) {
            square += 1;
            i += 2;
            continue;
        }
        if (i + 1 < s.len and std.mem.eql(u8, s[i .. i + 2], "]]") and square != 0) {
            square -= 1;
            i += 2;
            continue;
        }
        if (s[i] == needle and brace_depth == 0 and square == 0) return i;
        i += 1;
    }
    return null;
}

fn splitWikitextTop(a: std.mem.Allocator, s: []const u8, delimiter: u8, out: *std.ArrayList([]const u8)) !void {
    var start: usize = 0;
    var pos: usize = 0;
    while (pos < s.len) {
        const rel = findTopDelimiter(s[pos..], delimiter) orelse break;
        const cut = pos + rel;
        try out.append(a, s[start..cut]);
        start = cut + 1;
        pos = start;
    }
    try out.append(a, s[start..]);
}

const ParameterSplit = struct { key: []const u8, default: ?[]const u8 };
fn splitParameter(s: []const u8) ParameterSplit {
    if (findTopDelimiter(s, '|')) |bar| return .{ .key = s[0..bar], .default = s[bar + 1 ..] };
    return .{ .key = s, .default = null };
}

fn valueToWikitext(a: std.mem.Allocator, value: Value) ![]const u8 {
    return switch (value) {
        .nil => "",
        .string => |text| text,
        .number => |number| try rt.numberToString(a, number),
        .boolean => |b| if (b) "true" else "false",
        .table, .closure, .native => error.WikitextScalarExpected,
    };
}

const current_month_names = [_][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};

fn magicWord(runtime: *Runtime, raw: []const u8) !?[]const u8 {
    const head = std.mem.trim(u8, raw, " \t\r\n");
    const page = runtime.current_page_title;
    const ns = namespaceOf(page);
    if (std.ascii.eqlIgnoreCase(head, "PAGENAME")) return ns.text;
    if (std.ascii.eqlIgnoreCase(head, "FULLPAGENAME")) return page;
    if (std.ascii.eqlIgnoreCase(head, "NAMESPACE")) return ns.name;
    if (std.ascii.eqlIgnoreCase(head, "BASEPAGENAME")) return if (std.mem.lastIndexOfScalar(u8, ns.text, '/')) |slash| ns.text[0..slash] else ns.text;
    if (std.ascii.eqlIgnoreCase(head, "SUBPAGENAME")) return if (std.mem.lastIndexOfScalar(u8, ns.text, '/')) |slash| ns.text[slash + 1 ..] else ns.text;
    if (std.ascii.eqlIgnoreCase(head, "REVISIONID")) return runtime.current_page_revision_id;
    if (std.mem.eql(u8, head, "!")) return "|";
    if (std.mem.eql(u8, head, "!!")) return "||";
    if (std.mem.eql(u8, head, "=")) return "=";

    const is_current = std.ascii.startsWithIgnoreCase(head, "CURRENT");
    if (!is_current) return null;
    const c = language_lib.civilFromUnix(runtime.page_now_unix);
    if (std.ascii.eqlIgnoreCase(head, "CURRENTYEAR"))
        return try std.fmt.allocPrint(runtime.allocator, "{d:0>4}", .{@as(u64, @intCast(c.year))});
    if (std.ascii.eqlIgnoreCase(head, "CURRENTMONTH"))
        return try std.fmt.allocPrint(runtime.allocator, "{d:0>2}", .{c.month});
    if (std.ascii.eqlIgnoreCase(head, "CURRENTMONTH1"))
        return try std.fmt.allocPrint(runtime.allocator, "{d}", .{c.month});
    if (std.ascii.eqlIgnoreCase(head, "CURRENTMONTHNAME")) return current_month_names[c.month - 1];
    if (std.ascii.eqlIgnoreCase(head, "CURRENTMONTHABBREV")) return current_month_names[c.month - 1][0..3];
    if (std.ascii.eqlIgnoreCase(head, "CURRENTDAY"))
        return try std.fmt.allocPrint(runtime.allocator, "{d}", .{c.day});
    if (std.ascii.eqlIgnoreCase(head, "CURRENTDAY2"))
        return try std.fmt.allocPrint(runtime.allocator, "{d:0>2}", .{c.day});
    if (std.ascii.eqlIgnoreCase(head, "CURRENTDOW"))
        return try std.fmt.allocPrint(runtime.allocator, "{d}", .{language_lib.weekdaySunday0(runtime.page_now_unix)});
    const seconds_in_day = @mod(runtime.page_now_unix, @as(i64, std.time.s_per_day));
    const sod = if (seconds_in_day < 0) seconds_in_day + std.time.s_per_day else seconds_in_day;
    const hour: u8 = @intCast(@divFloor(sod, std.time.s_per_hour));
    const minute: u8 = @intCast(@divFloor(@mod(sod, std.time.s_per_hour), std.time.s_per_min));
    const second: u8 = @intCast(@mod(sod, std.time.s_per_min));
    if (std.ascii.eqlIgnoreCase(head, "CURRENTTIME"))
        return try std.fmt.allocPrint(runtime.allocator, "{d:0>2}:{d:0>2}", .{ hour, minute });
    if (std.ascii.eqlIgnoreCase(head, "CURRENTHOUR"))
        return try std.fmt.allocPrint(runtime.allocator, "{d:0>2}", .{hour});
    if (std.ascii.eqlIgnoreCase(head, "CURRENTTIMESTAMP"))
        return try std.fmt.allocPrint(runtime.allocator, "{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}", .{ @as(u64, @intCast(c.year)), c.month, c.day, hour, minute, second });
    return null;
}

pub const FrameArg = struct { key: Value, value: Value };
const FrameCtx = struct {
    runtime: *Runtime,
    table: *rt.Table,
    parent: ?*rt.Table,
    title: []const u8,
};

fn frameGetParent(ctx_raw: ?*anyopaque, _: *anyopaque, _: []const Value, a: std.mem.Allocator) ![]const Value {
    const ctx: *FrameCtx = @ptrCast(@alignCast(ctx_raw.?));
    return one(a, if (ctx.parent) |parent| .{ .table = parent } else .nil);
}

fn frameGetTitle(ctx_raw: ?*anyopaque, _: *anyopaque, _: []const Value, a: std.mem.Allocator) ![]const Value {
    const ctx: *FrameCtx = @ptrCast(@alignCast(ctx_raw.?));
    return one(a, .{ .string = ctx.title });
}

fn currentFrameCall(ctx_raw: ?*anyopaque, _: *anyopaque, _: []const Value, a: std.mem.Allocator) ![]const Value {
    const runtime: *Runtime = @ptrCast(@alignCast(ctx_raw.?));
    return one(a, if (runtime.current_frame) |frame| .{ .table = frame } else .nil);
}

const nowiki_marker_prefix = "\x7f'\"`UNIQ--nowiki-";
const nowiki_marker_suffix = "-QINU`\"'\x7f";

fn makeNowikiMarker(a: std.mem.Allocator, id: u32) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}{X:0>8}{s}", .{ nowiki_marker_prefix, id, nowiki_marker_suffix });
}

fn appendExtensionAttrEscaped(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '"' => try out.appendSlice(a, "&quot;"),
        else => try out.append(a, c),
    };
}

fn serializeExtensionTag(a: std.mem.Allocator, name: []const u8, content: ?[]const u8, attrs: ?*rt.Table) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '<');
    try out.appendSlice(a, name);
    if (attrs) |table| {
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(a);
        var it = table.map.iterator();
        while (it.next()) |entry| if (entry.key_ptr.* == .string and entry.value_ptr.* != .nil)
            try keys.append(a, entry.key_ptr.string);
        std.mem.sort([]const u8, keys.items, {}, struct {
            fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.order(u8, lhs, rhs) == .lt;
            }
        }.less);
        for (keys.items) |key| {
            const value = table.rawGet(.{ .string = key }).?;
            const text = try valueToWikitext(a, value);
            try out.append(a, ' ');
            try out.appendSlice(a, key);
            try out.appendSlice(a, "=\"");
            try appendExtensionAttrEscaped(&out, a, text);
            try out.append(a, '"');
        }
    }
    if (content) |body| {
        try out.append(a, '>');
        try out.appendSlice(a, body);
        try out.appendSlice(a, "</");
        try out.appendSlice(a, name);
        try out.append(a, '>');
    } else {
        try out.appendSlice(a, "/>");
    }
    return out.toOwnedSlice(a);
}

fn frameExtensionTagCall(ctx_raw: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    const ctx: *FrameCtx = @ptrCast(@alignCast(ctx_raw.?));
    if (args.len < 2 or args[1] != .string) return error.ExtensionTagNameExpected;
    const name = args[1].string;
    if (std.ascii.eqlIgnoreCase(name, "nowiki")) {
        const content = if (args.len > 2 and args[2] == .string) args[2].string else "";
        const id = ctx.runtime.strip_counter;
        ctx.runtime.strip_counter +%= 1;
        const stored = try ctx.runtime.page_allocator.dupe(u8, content);
        try ctx.runtime.strip_values.put(ctx.runtime.page_allocator, id, stored);
        return one(a, .{ .string = try makeNowikiMarker(a, id) });
    }
    const attrs: ?*rt.Table = if (args.len <= 3 or args[3] == .nil) null else switch (args[3]) {
        .table => |table| table,
        else => return error.TableExpected,
    };
    if (std.ascii.eqlIgnoreCase(name, "ref") or std.ascii.eqlIgnoreCase(name, "references")) {
        // Scribunto routes extensionTag() through #tag. At the preprocessing
        // stage exercised by replay, Cite returns literal extension markup;
        // nil content is coerced to the empty string rather than a self-close.
        const content = if (args.len <= 2 or args[2] == .nil) "" else try valueToWikitext(a, args[2]);
        return one(a, .{ .string = try serializeExtensionTag(a, if (std.ascii.eqlIgnoreCase(name, "ref")) "ref" else "references", content, attrs) });
    }
    if (!std.ascii.eqlIgnoreCase(name, "templatestyles")) {
        ctx.runtime.last_not_implemented = try std.fmt.allocPrint(ctx.runtime.allocator, "frame:extensionTag({s})", .{name});
        return error.NotImplemented;
    }
    const content: ?[]const u8 = if (args.len <= 2 or args[2] == .nil) null else switch (args[2]) {
        .string => |text| text,
        else => return error.StringExpected,
    };
    return one(a, .{ .string = try serializeExtensionTag(a, "templatestyles", content, attrs) });
}

fn framePreprocessCall(ctx_raw: ?*anyopaque, raw_vm: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    const ctx: *FrameCtx = @ptrCast(@alignCast(ctx_raw.?));
    const vm: *exec.Vm = @ptrCast(@alignCast(raw_vm));
    if (args.len < 2 or args[1] != .string) return error.StringExpected;
    const source = args[1].string;
    if (source.len >= 2 and source[0] == '=' and source[source.len - 1] == '=' and
        std.mem.indexOf(u8, source, nowiki_marker_prefix) != null)
    {
        const number = ctx.runtime.page_heading_count + ctx.runtime.fake_heading_count;
        ctx.runtime.fake_heading_count += 1;
        const marker = try std.fmt.allocPrint(a, "\x7f'\"`UNIQ--h-{d}--QINU`\"'\x7f", .{number});
        return one(a, .{ .string = marker });
    }
    const frame_args = ctx.table.rawGet(.{ .string = "args" }) orelse .nil;
    if (frame_args != .table) return error.TableExpected;
    return one(a, .{ .string = try ctx.runtime.expandWikitext(vm, source, frame_args.table, ctx.title, 0) });
}

fn frameExpandTemplateCall(ctx_raw: ?*anyopaque, raw_vm: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    const ctx: *FrameCtx = @ptrCast(@alignCast(ctx_raw.?));
    const vm: *exec.Vm = @ptrCast(@alignCast(raw_vm));
    if (args.len < 2 or args[1] != .table) return error.TemplateSpecExpected;
    const spec: Value = args[1];
    const title_value = try vm.getIndex(spec, .{ .string = "title" });
    if (title_value != .string) return error.TemplateTitleExpected;
    const args_value = try vm.getIndex(spec, .{ .string = "args" });
    const template_args = switch (args_value) {
        .nil => try rt.newTable(ctx.runtime.allocator),
        .table => |table| table,
        else => return error.TemplateArgsExpected,
    };
    const rendered = try ctx.runtime.expandTemplateByName(vm, title_value.string, template_args, 0);
    return one(a, .{ .string = rendered });
}

const FrameParserCall = struct {
    name: []const u8,
    first: ?Value = null,
    second: ?Value = null,
};

fn decodeFrameParserCall(args: []const Value) !FrameParserCall {
    if (args.len < 2) return error.ParserFunctionNameExpected;
    if (args[1] == .string) return .{
        .name = args[1].string,
        .first = if (args.len > 2) args[2] else null,
        .second = if (args.len > 3) args[3] else null,
    };
    if (args[1] != .table) return error.ParserFunctionNameExpected;
    const spec = args[1].table;
    const name = spec.rawGet(.{ .string = "name" }) orelse return error.ParserFunctionNameExpected;
    if (name != .string) return error.ParserFunctionNameExpected;
    const raw_args = spec.rawGet(.{ .string = "args" });
    if (raw_args) |value| {
        if (value == .table) return .{
            .name = name.string,
            .first = value.table.rawGet(.{ .number = 1 }),
            .second = value.table.rawGet(.{ .number = 2 }),
        };
        return .{ .name = name.string, .first = value };
    }
    return .{ .name = name.string };
}

fn formattedDateSpan(runtime: *Runtime, raw: []const u8, style_raw: ?[]const u8) ![]const u8 {
    const parsed = language_lib.parseExplicitDate(raw) catch return raw;
    if (!parsed.has_day) return raw;
    const c = parsed.civil;
    const canonical = try std.fmt.allocPrint(runtime.allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(c.year)), c.month, c.day });
    const style = if (style_raw) |value| std.mem.trim(u8, value, " \t\r\n") else "";
    const display = if (style.len == 0)
        raw
    else if (std.ascii.eqlIgnoreCase(style, "dmy"))
        try std.fmt.allocPrint(runtime.allocator, "{d} {s} {d}", .{ c.day, current_month_names[c.month - 1], c.year })
    else if (std.ascii.eqlIgnoreCase(style, "mdy"))
        try std.fmt.allocPrint(runtime.allocator, "{s} {d}, {d}", .{ current_month_names[c.month - 1], c.day, c.year })
    else if (std.ascii.eqlIgnoreCase(style, "ymd"))
        try std.fmt.allocPrint(runtime.allocator, "{d} {s} {d}", .{ c.year, current_month_names[c.month - 1], c.day })
    else if (std.ascii.eqlIgnoreCase(style, "ISO 8601"))
        canonical
    else
        raw;
    return std.fmt.allocPrint(runtime.allocator, "<span class=\"mw-formatted-date\" title=\"{s}\">{s}</span>", .{ canonical, display });
}

fn frameCallParserFunctionCall(ctx_raw: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    const ctx: *FrameCtx = @ptrCast(@alignCast(ctx_raw.?));
    const call = try decodeFrameParserCall(args);
    if (std.ascii.eqlIgnoreCase(call.name, "DEFAULTSORT") or std.ascii.eqlIgnoreCase(call.name, "DISPLAYTITLE"))
        return one(a, .{ .string = "" });
    if (std.ascii.eqlIgnoreCase(call.name, "#formatdate")) {
        if (call.first == null or call.first.? != .string) return error.StringExpected;
        const style: ?[]const u8 = if (call.second) |value| switch (value) {
            .nil => null,
            .string => |text| text,
            else => return error.StringExpected,
        } else null;
        return one(a, .{ .string = try formattedDateSpan(ctx.runtime, call.first.?.string, style) });
    }
    ctx.runtime.last_not_implemented = try std.fmt.allocPrint(ctx.runtime.allocator, "frame:callParserFunction({s})", .{call.name});
    return error.NotImplemented;
}

fn makeFrameWithArgsTable(runtime: *Runtime, title: []const u8, arg_table: *rt.Table, parent: ?Value) !Value {
    const frame = try rt.newTable(runtime.allocator);
    const parent_table: ?*rt.Table = if (parent) |p| switch (p) {
        .table => |t| t,
        else => return error.ParentFrameExpected,
    } else null;
    const ctx = try runtime.allocator.create(FrameCtx);
    ctx.* = .{ .runtime = runtime, .table = frame, .parent = parent_table, .title = title };
    try frame.rawSet(runtime.allocator, .{ .string = "args" }, .{ .table = arg_table });
    try frame.rawSet(runtime.allocator, .{ .string = "getParent" }, try rt.newNative(runtime.allocator, ctx, frameGetParent));
    try frame.rawSet(runtime.allocator, .{ .string = "getTitle" }, try rt.newNative(runtime.allocator, ctx, frameGetTitle));
    try frame.rawSet(runtime.allocator, .{ .string = "expandTemplate" }, try rt.newNative(runtime.allocator, ctx, frameExpandTemplateCall));
    try frame.rawSet(runtime.allocator, .{ .string = "preprocess" }, try rt.newNative(runtime.allocator, ctx, framePreprocessCall));
    try frame.rawSet(runtime.allocator, .{ .string = "extensionTag" }, try rt.newNative(runtime.allocator, ctx, frameExtensionTagCall));
    try frame.rawSet(runtime.allocator, .{ .string = "callParserFunction" }, try rt.newNative(runtime.allocator, ctx, frameCallParserFunctionCall));
    return .{ .table = frame };
}

pub fn makeFrame(runtime: *Runtime, title: []const u8, args: []const FrameArg, parent: ?Value) !Value {
    const arg_table = try rt.newTable(runtime.allocator);
    for (args) |arg| try arg_table.rawSet(runtime.allocator, arg.key, arg.value);
    return makeFrameWithArgsTable(runtime, title, arg_table, parent);
}

pub fn invoke(runtime: *Runtime, vm: *exec.Vm, module_name: []const u8, function_name: []const u8, frame: Value) ![]const Value {
    if (frame != .table) return error.FrameExpected;
    const saved = runtime.current_frame;
    runtime.current_frame = frame.table;
    defer runtime.current_frame = saved;
    const module = try runtime.requireByName(vm, module_name);
    const callable = if (function_name.len == 0) module else try vm.getIndex(module, .{ .string = function_name });
    return vm.callValue(callable, &.{frame});
}

fn hostSetNative(runtime: *Runtime, table: *rt.Table, name: []const u8, call: rt.NativeCall, ctx: ?*anyopaque) !void {
    try table.rawSet(runtime.allocator, .{ .string = name }, try rt.newNative(runtime.allocator, ctx, call));
}

fn notImplementedCall(ctx_raw: ?*anyopaque, _: *anyopaque, _: []const Value, _: std.mem.Allocator) ![]const Value {
    const ctx: *StubCtx = @ptrCast(@alignCast(ctx_raw.?));
    ctx.runtime.last_not_implemented = ctx.name;
    return error.NotImplemented;
}

fn hostSetNotImplemented(runtime: *Runtime, table: *rt.Table, field: []const u8, full_name: []const u8) !void {
    const ctx = try runtime.allocator.create(StubCtx);
    ctx.* = .{ .runtime = runtime, .name = full_name };
    try hostSetNative(runtime, table, field, notImplementedCall, ctx);
}

fn noOpCall(_: ?*anyopaque, _: *anyopaque, _: []const Value, _: std.mem.Allocator) ![]const Value {
    return &.{};
}

fn falseCall(_: ?*anyopaque, _: *anyopaque, _: []const Value, a: std.mem.Allocator) ![]const Value {
    return one(a, .{ .boolean = false });
}

fn interwikiMapCall(ctx_raw: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    const runtime: *Runtime = @ptrCast(@alignCast(ctx_raw.?));
    const filter: enum { all, local, nonlocal } = if (args.len == 0 or args[0] == .nil)
        .all
    else if (args[0] != .string)
        return error.StringExpected
    else if (std.mem.eql(u8, args[0].string, "local"))
        .local
    else if (std.mem.eql(u8, args[0].string, "!local"))
        .nonlocal
    else
        return error.InvalidInterwikiFilter;

    const map = try rt.newTable(runtime.allocator);
    for (runtime.interwiki_rows.items) |row| {
        if (filter == .local and !row.is_local) continue;
        if (filter == .nonlocal and row.is_local) continue;
        const entry = try rt.newTable(runtime.allocator);
        try entry.rawSet(runtime.allocator, .{ .string = "prefix" }, .{ .string = row.prefix });
        try entry.rawSet(runtime.allocator, .{ .string = "url" }, .{ .string = row.url });
        try entry.rawSet(runtime.allocator, .{ .string = "isProtocolRelative" }, .{ .boolean = row.is_protocol_relative });
        try entry.rawSet(runtime.allocator, .{ .string = "isLocal" }, .{ .boolean = row.is_local });
        try entry.rawSet(runtime.allocator, .{ .string = "isTranscludable" }, .{ .boolean = false });
        try entry.rawSet(runtime.allocator, .{ .string = "isCurrentWiki" }, .{ .boolean = row.is_current_wiki });
        try entry.rawSet(runtime.allocator, .{ .string = "isExtraLanguageLink" }, .{ .boolean = false });
        try map.rawSet(runtime.allocator, .{ .string = row.prefix }, .{ .table = entry });
    }
    return one(a, .{ .table = map });
}

fn wikibaseSitelinkCall(ctx_raw: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len < 2 or args[0] != .string or args[1] != .string) return error.StringExpected;
    const runtime: *Runtime = @ptrCast(@alignCast(ctx_raw.?));
    const qid = args[0].string;
    const site = args[1].string;
    switch (try runtime.wikibaseSitelink(qid, site)) {
        .title => |title| return one(a, .{ .string = title }),
        .absent => return one(a, .nil),
        .unknown => {
            runtime.last_missing_wikibase = try std.fmt.allocPrint(runtime.allocator, "{s}\t{s}", .{ qid, site });
            return error.WikibaseDataMissing;
        },
    }
}

fn dumpObjectCall(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len == 0) return one(a, .{ .string = "nil" });
    const text: []const u8 = switch (args[0]) {
        .nil => "nil",
        .boolean => |b| if (b) "true" else "false",
        .number => |n| try rt.numberToString(a, n),
        .string => |s| s,
        .table => "table",
        .closure, .native => "function",
    };
    return one(a, .{ .string = text });
}

fn namespaceSpecById(id: i32) ?NamespaceSpec {
    for (wiktionary_namespaces) |spec| if (spec.id == id) return spec;
    return null;
}

fn namespaceSpecByName(name: []const u8) ?NamespaceSpec {
    if (name.len == 0) return namespaceSpecById(0);
    for (wiktionary_namespaces) |spec| {
        if (std.ascii.eqlIgnoreCase(name, spec.name) or std.ascii.eqlIgnoreCase(name, spec.canonical_name)) return spec;
        for (spec.aliases) |alias| if (std.ascii.eqlIgnoreCase(name, alias)) return spec;
    }
    return null;
}

fn namespaceOf(title: []const u8) struct { id: i32, name: []const u8, text: []const u8 } {
    if (std.mem.indexOfScalar(u8, title, ':')) |colon| {
        if (namespaceSpecByName(title[0..colon])) |spec|
            return .{ .id = spec.id, .name = spec.name, .text = title[colon + 1 ..] };
    }
    return .{ .id = 0, .name = "", .text = title };
}

const TitleCtx = struct { runtime: *Runtime, title: []const u8 };

fn titleGetContentCall(ctx_raw: ?*anyopaque, _: *anyopaque, _: []const Value, a: std.mem.Allocator) ![]const Value {
    const ctx: *TitleCtx = @ptrCast(@alignCast(ctx_raw.?));
    if (std.mem.eql(u8, ctx.title, ctx.runtime.current_page_title))
        if (ctx.runtime.current_page_source) |source| return one(a, .{ .string = source });
    if (ctx.runtime.page_content_provider) |provider|
        if (try provider.get(provider.ctx, ctx.runtime.allocator, ctx.title)) |source| return one(a, .{ .string = source });

    const ns = namespaceOf(ctx.title);
    if (ns.id == 10) {
        if (try ctx.runtime.canonicalTemplateSlot(ctx.title)) |slot| return one(a, .{ .string = try ctx.runtime.ensureTemplateBody(slot) });
    } else if (ns.id == 828) {
        if (try ctx.runtime.canonicalSlot(ctx.title)) |slot| {
            const path = try std.fmt.allocPrint(ctx.runtime.allocator, "{s}/{d}.lua", .{ ctx.runtime.modules_dir, slot.page_id });
            return one(a, .{ .string = try readAll(ctx.runtime.io, ctx.runtime.allocator, path) });
        }
    }
    return one(a, .nil);
}

fn titleUrlCall(ctx_raw: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator, kind: WikiUrlKind) ![]const Value {
    const ctx: *TitleCtx = @ptrCast(@alignCast(ctx_raw.?));
    const query = if (args.len > 1) args[1] else Value.nil;
    const proto = if (kind == .full and args.len > 2 and args[2] == .string) args[2].string else null;
    const query_text = try buildQueryArgument(ctx.runtime, query);
    return one(a, .{ .string = try buildWikiUrlRawQuery(ctx.runtime.allocator, ctx.title, query_text, kind, false, proto) });
}

fn titleFullUrlCall(ctx_raw: ?*anyopaque, raw: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    return titleUrlCall(ctx_raw, raw, args, a, .full);
}

fn titleLocalUrlCall(ctx_raw: ?*anyopaque, raw: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    return titleUrlCall(ctx_raw, raw, args, a, .local);
}

fn titleCanonicalUrlCall(ctx_raw: ?*anyopaque, raw: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    return titleUrlCall(ctx_raw, raw, args, a, .canonical);
}

fn titleCompareValues(lhs: Value, rhs: Value) !std.math.Order {
    if (lhs != .table or rhs != .table) return error.TableExpected;
    const li = lhs.table.rawGet(.{ .string = "interwiki" }) orelse return error.InvalidTitle;
    const ri = rhs.table.rawGet(.{ .string = "interwiki" }) orelse return error.InvalidTitle;
    if (li != .string or ri != .string) return error.InvalidTitle;
    const iw = std.mem.order(u8, li.string, ri.string);
    if (iw != .eq) return iw;

    const ln = lhs.table.rawGet(.{ .string = "namespace" }) orelse return error.InvalidTitle;
    const rn = rhs.table.rawGet(.{ .string = "namespace" }) orelse return error.InvalidTitle;
    if (ln != .number or rn != .number) return error.InvalidTitle;
    if (ln.number < rn.number) return .lt;
    if (ln.number > rn.number) return .gt;

    const lt = lhs.table.rawGet(.{ .string = "text" }) orelse return error.InvalidTitle;
    const rt_ = rhs.table.rawGet(.{ .string = "text" }) orelse return error.InvalidTitle;
    if (lt != .string or rt_ != .string) return error.InvalidTitle;
    return std.mem.order(u8, lt.string, rt_.string);
}

fn titleEqualsCall(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len < 2 or args[0] != .table or args[1] != .table) return one(a, .{ .boolean = false });
    return one(a, .{ .boolean = (try titleCompareValues(args[0], args[1])) == .eq });
}

fn titleLessCall(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len < 2) return error.MissingArgument;
    return one(a, .{ .boolean = (try titleCompareValues(args[0], args[1])) == .lt });
}

fn titleCompareCall(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len < 2) return error.MissingArgument;
    const order = try titleCompareValues(args[0], args[1]);
    const result: f64 = switch (order) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
    return one(a, .{ .number = result });
}

fn normalizeTitleFragment(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_space = false;
    for (raw) |c| {
        const space = c == '_' or std.ascii.isWhitespace(c);
        if (space) {
            if (!in_space) try out.append(a, ' ');
            in_space = true;
        } else {
            try out.append(a, c);
            in_space = false;
        }
    }
    if (out.items.len != 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
    return out.toOwnedSlice(a);
}

fn titleMetaIndexCall(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len < 2 or args[0] != .table or args[1] != .string) return one(a, .nil);
    const t = args[0].table;
    const key = args[1].string;
    const fragment: Value = t.rawGet(.{ .string = "__fragment" }) orelse .{ .string = "" };
    if (std.mem.eql(u8, key, "fragment")) return one(a, fragment);
    if (std.mem.eql(u8, key, "fullText")) {
        const prefixed = t.rawGet(.{ .string = "prefixedText" }) orelse return one(a, .nil);
        if (prefixed != .string or fragment != .string) return one(a, .nil);
        if (fragment.string.len == 0) return one(a, prefixed);
        return one(a, .{ .string = try std.fmt.allocPrint(a, "{s}#{s}", .{ prefixed.string, fragment.string }) });
    }
    return one(a, .nil);
}

fn titleMetaNewIndexCall(ctx_raw: ?*anyopaque, _: *anyopaque, args: []const Value, _: std.mem.Allocator) ![]const Value {
    if (args.len < 3 or args[0] != .table) return error.TableExpected;
    const runtime: *Runtime = @ptrCast(@alignCast(ctx_raw.?));
    if (args[1] == .string and std.mem.eql(u8, args[1].string, "fragment")) {
        if (args[2] != .string) return error.StringExpected;
        const normalized = try normalizeTitleFragment(runtime.allocator, args[2].string);
        try args[0].table.rawSet(runtime.allocator, .{ .string = "__fragment" }, .{ .string = normalized });
        return &.{};
    }
    try args[0].table.rawSet(runtime.allocator, args[1], args[2]);
    return &.{};
}

fn ensureTitleMetatable(runtime: *Runtime) !*rt.Table {
    if (runtime.title_metatable) |mt| return mt;
    const mt = try rt.newTable(runtime.allocator);
    const eq = try rt.newNative(runtime.allocator, runtime, titleEqualsCall);
    const lt = try rt.newNative(runtime.allocator, runtime, titleLessCall);
    try mt.rawSet(runtime.allocator, .{ .string = "__eq" }, eq);
    try mt.rawSet(runtime.allocator, .{ .string = "__lt" }, lt);
    try mt.rawSet(runtime.allocator, .{ .string = "__index" }, try rt.newNative(runtime.allocator, runtime, titleMetaIndexCall));
    try mt.rawSet(runtime.allocator, .{ .string = "__newindex" }, try rt.newNative(runtime.allocator, runtime, titleMetaNewIndexCall));
    runtime.title_metatable = mt;
    runtime.title_equals = eq;
    return mt;
}

fn makeTitleValue(runtime: *Runtime, title: []const u8) !Value {
    const t = try rt.newTable(runtime.allocator);
    const hash = std.mem.indexOfScalar(u8, title, '#');
    const base_title = if (hash) |p| title[0..p] else title;
    const fragment_raw = if (hash) |p| title[p + 1 ..] else "";
    const fragment = try normalizeTitleFragment(runtime.allocator, fragment_raw);
    const ns = namespaceOf(base_title);
    const slash = std.mem.lastIndexOfScalar(u8, ns.text, '/');
    const first_slash = std.mem.indexOfScalar(u8, ns.text, '/');
    try t.rawSet(runtime.allocator, .{ .string = "text" }, .{ .string = ns.text });
    try t.rawSet(runtime.allocator, .{ .string = "prefixedText" }, .{ .string = base_title });
    try t.rawSet(runtime.allocator, .{ .string = "__fragment" }, .{ .string = fragment });
    try t.rawSet(runtime.allocator, .{ .string = "namespace" }, .{ .number = @floatFromInt(ns.id) });
    try t.rawSet(runtime.allocator, .{ .string = "nsText" }, .{ .string = ns.name });
    try t.rawSet(runtime.allocator, .{ .string = "subpageText" }, .{ .string = if (slash) |p| ns.text[p + 1 ..] else ns.text });
    try t.rawSet(runtime.allocator, .{ .string = "baseText" }, .{ .string = if (slash) |p| ns.text[0..p] else ns.text });
    try t.rawSet(runtime.allocator, .{ .string = "rootText" }, .{ .string = if (first_slash) |p| ns.text[0..p] else ns.text });
    try t.rawSet(runtime.allocator, .{ .string = "isSubpage" }, .{ .boolean = slash != null });
    try t.rawSet(runtime.allocator, .{ .string = "interwiki" }, .{ .string = "" });
    t.metatable = try ensureTitleMetatable(runtime);
    try t.rawSet(runtime.allocator, .{ .string = "exists" }, .{ .boolean = try runtime.pageExists(base_title) });
    const ctx = try runtime.allocator.create(TitleCtx);
    ctx.* = .{ .runtime = runtime, .title = base_title };
    try t.rawSet(runtime.allocator, .{ .string = "getContent" }, try rt.newNative(runtime.allocator, ctx, titleGetContentCall));
    try t.rawSet(runtime.allocator, .{ .string = "fullUrl" }, try rt.newNative(runtime.allocator, ctx, titleFullUrlCall));
    try t.rawSet(runtime.allocator, .{ .string = "localUrl" }, try rt.newNative(runtime.allocator, ctx, titleLocalUrlCall));
    try t.rawSet(runtime.allocator, .{ .string = "canonicalUrl" }, try rt.newNative(runtime.allocator, ctx, titleCanonicalUrlCall));
    return .{ .table = t };
}

fn titleWithNamespace(runtime: *Runtime, text_raw: []const u8, namespace: ?Value) !?[]const u8 {
    const text = try normalizeName(runtime.allocator, text_raw);
    if (text.len == 0) return null;
    if (namespace == null or namespace.? == .nil) return text;
    const spec = switch (namespace.?) {
        .number => |n| namespaceSpecById(@intFromFloat(@trunc(n))),
        .string => |name| namespaceSpecByName(name),
        else => null,
    } orelse return null;
    if (spec.id == 0) return text;
    return try std.fmt.allocPrint(runtime.allocator, "{s}:{s}", .{ spec.name, text });
}

fn titleNewCall(ctx_raw: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    const runtime: *Runtime = @ptrCast(@alignCast(ctx_raw.?));
    if (args.len == 0 or args[0] != .string) return one(a, .nil);
    const title = try titleWithNamespace(runtime, args[0].string, if (args.len > 1) args[1] else null) orelse return one(a, .nil);
    return one(a, try makeTitleValue(runtime, title));
}

fn titleMakeCall(ctx_raw: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    const runtime: *Runtime = @ptrCast(@alignCast(ctx_raw.?));
    if (args.len < 2 or args[1] != .string) return one(a, .nil);
    const title = try titleWithNamespace(runtime, args[1].string, args[0]) orelse return one(a, .nil);
    return one(a, try makeTitleValue(runtime, title));
}

fn titleCurrentCall(ctx_raw: ?*anyopaque, _: *anyopaque, _: []const Value, a: std.mem.Allocator) ![]const Value {
    const runtime: *Runtime = @ptrCast(@alignCast(ctx_raw.?));
    return one(a, try makeTitleValue(runtime, runtime.current_page_title));
}

const TextGsplitCtx = struct {
    source: []const u8,
    pattern: []const u8,
    plain: bool,
    find: Value,
    sub: Value,
    next_index: i64 = 1,
    codepoint_len: i64,
    done: bool = false,
};

fn textGsplitCtx(vm: *exec.Vm, source: []const u8, pattern: []const u8, plain: bool) !TextGsplitCtx {
    const mw = vm.globals.rawGet(.{ .string = "mw" }) orelse return error.NotImplemented;
    if (mw != .table) return error.TableExpected;
    const ustring = mw.table.rawGet(.{ .string = "ustring" }) orelse return error.NotImplemented;
    if (ustring != .table) return error.TableExpected;
    const find = ustring.table.rawGet(.{ .string = "find" }) orelse return error.NotImplemented;
    const sub = ustring.table.rawGet(.{ .string = "sub" }) orelse return error.NotImplemented;
    const count = std.unicode.utf8CountCodepoints(source) catch return error.InvalidUtf8;
    return .{
        .source = source,
        .pattern = pattern,
        .plain = plain,
        .find = find,
        .sub = sub,
        .codepoint_len = @intCast(count),
    };
}

fn textGsplitNext(ctx_raw: ?*anyopaque, vm_raw: *anyopaque, _: []const Value, a: std.mem.Allocator) ![]const Value {
    const ctx: *TextGsplitCtx = @ptrCast(@alignCast(ctx_raw.?));
    if (ctx.done) return &.{};
    const vm: *exec.Vm = @ptrCast(@alignCast(vm_raw));
    const found = try vm.callValue(ctx.find, &.{
        .{ .string = ctx.source },
        .{ .string = ctx.pattern },
        .{ .number = @floatFromInt(ctx.next_index) },
        .{ .boolean = ctx.plain },
    });
    defer exec.Vm.freeResults(found);

    if (found.len == 0 or found[0] == .nil) {
        const tail = try vm.callValue(ctx.sub, &.{
            .{ .string = ctx.source },
            .{ .number = @floatFromInt(ctx.next_index) },
        });
        defer exec.Vm.freeResults(tail);
        ctx.done = true;
        return one(a, if (tail.len == 0) .{ .string = "" } else tail[0]);
    }
    if (found.len < 2 or found[0] != .number or found[1] != .number) return error.InvalidSplitMatch;
    const first: i64 = @intFromFloat(@trunc(found[0].number));
    const last: i64 = @intFromFloat(@trunc(found[1].number));

    if (last < first) {
        const piece = try vm.callValue(ctx.sub, &.{
            .{ .string = ctx.source },
            .{ .number = @floatFromInt(ctx.next_index) },
            .{ .number = @floatFromInt(first) },
        });
        defer exec.Vm.freeResults(piece);
        if (first < ctx.codepoint_len) ctx.next_index = first + 1 else ctx.done = true;
        return one(a, if (piece.len == 0) .{ .string = "" } else piece[0]);
    }

    const value: Value = if (first > ctx.next_index) blk: {
        const piece = try vm.callValue(ctx.sub, &.{
            .{ .string = ctx.source },
            .{ .number = @floatFromInt(ctx.next_index) },
            .{ .number = @floatFromInt(first - 1) },
        });
        defer exec.Vm.freeResults(piece);
        break :blk if (piece.len == 0) .{ .string = "" } else piece[0];
    } else .{ .string = "" };
    ctx.next_index = last + 1;
    return one(a, value);
}

fn textGsplitCall(_: ?*anyopaque, vm_raw: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len < 2 or args[0] != .string or args[1] != .string) return error.StringExpected;
    const vm: *exec.Vm = @ptrCast(@alignCast(vm_raw));
    const ctx = try a.create(TextGsplitCtx);
    ctx.* = try textGsplitCtx(vm, args[0].string, args[1].string, args.len > 2 and args[2].truthy());
    const out = try std.heap.smp_allocator.alloc(Value, 3);
    out[0] = try rt.newNative(a, ctx, textGsplitNext);
    out[1] = .nil;
    out[2] = .nil;
    return out;
}

fn textSplitCall(ctx_raw: ?*anyopaque, vm_raw: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len < 2 or args[0] != .string or args[1] != .string) return error.StringExpected;
    const runtime: *Runtime = @ptrCast(@alignCast(ctx_raw.?));
    const vm: *exec.Vm = @ptrCast(@alignCast(vm_raw));
    var split = try textGsplitCtx(vm, args[0].string, args[1].string, args.len > 2 and args[2].truthy());
    const out = try rt.newTable(runtime.allocator);
    var index: usize = 1;
    while (true) {
        const result = try textGsplitNext(&split, vm, &.{}, a);
        defer exec.Vm.freeResults(result);
        if (result.len == 0) break;
        try out.rawSet(runtime.allocator, .{ .number = @floatFromInt(index) }, result[0]);
        index += 1;
    }
    return one(a, .{ .table = out });
}

fn replaceLiteralAlloc(a: std.mem.Allocator, source: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    if (needle.len == 0 or std.mem.indexOf(u8, source, needle) == null) return source;
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, source, pos, needle)) |at| {
        try out.appendSlice(a, source[pos..at]);
        try out.appendSlice(a, replacement);
        pos = at + needle.len;
    }
    try out.appendSlice(a, source[pos..]);
    return out.toOwnedSlice(a);
}

fn nowikiLineEscape(c: u8) ?[]const u8 {
    return switch (c) {
        '!' => "&#33;",
        '#' => "&#35;",
        '*' => "&#42;",
        ':' => "&#58;",
        ' ' => "&#32;",
        '\n' => "&#10;",
        '\r' => "&#13;",
        '\t' => "&#9;",
        else => null,
    };
}

fn appendNowikiPrimary(out: *std.ArrayList(u8), a: std.mem.Allocator, source: []const u8) !void {
    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        const repl: ?[]const u8 = switch (c) {
            '"' => "&#34;",
            '&' => "&#38;",
            '\'' => "&#39;",
            '<' => "&#60;",
            '=' => "&#61;",
            '>' => "&#62;",
            '[' => "&#91;",
            ']' => "&#93;",
            '{' => "&#123;",
            '|' => "&#124;",
            '}' => "&#125;",
            ';' => "&#59;",
            else => null,
        };
        if (repl) |r| try out.appendSlice(a, r) else try out.append(a, c);
        i += 1;
    }
}

fn protectNowikiLineStarts(a: std.mem.Allocator, source: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var at_line_start = true;
    while (i < source.len) {
        if (at_line_start) {
            if (i + 4 <= source.len and std.mem.eql(u8, source[i .. i + 4], "----")) {
                try out.appendSlice(a, "&#45;---");
                i += 4;
                at_line_start = false;
                continue;
            }
            if (nowikiLineEscape(source[i])) |r| {
                try out.appendSlice(a, r);
                i += 1;
                at_line_start = false;
                continue;
            }
        }
        const c = source[i];
        try out.append(a, c);
        i += 1;
        at_line_start = false;
        if (c == '\n' or c == '\r') {
            if (i + 4 <= source.len and std.mem.eql(u8, source[i .. i + 4], "----")) {
                try out.appendSlice(a, "&#45;---");
                i += 4;
                at_line_start = false;
            } else if (i < source.len) {
                if (nowikiLineEscape(source[i])) |r| {
                    try out.appendSlice(a, r);
                    i += 1;
                    at_line_start = false;
                } else at_line_start = false;
            } else at_line_start = false;
        }
    }
    return out.toOwnedSlice(a);
}

fn protectMagicLinkWhitespace(a: std.mem.Allocator, source: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < source.len) {
        var prefix_len: usize = 0;
        if (std.mem.startsWith(u8, source[i..], "ISBN")) prefix_len = 4 else if (std.mem.startsWith(u8, source[i..], "RFC")) prefix_len = 3 else if (std.mem.startsWith(u8, source[i..], "PMID")) prefix_len = 4;
        if (prefix_len != 0 and i + prefix_len < source.len) {
            const ws = source[i + prefix_len];
            const entity: ?[]const u8 = switch (ws) {
                ' ' => "&#32;",
                '\t' => "&#9;",
                '\r' => "&#13;",
                '\n' => "&#10;",
                0x0c => "&#12;",
                else => null,
            };
            if (entity) |e| {
                try out.appendSlice(a, source[i .. i + prefix_len]);
                try out.appendSlice(a, e);
                i += prefix_len + 1;
                continue;
            }
        }
        try out.append(a, source[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

fn protectNowikiProtocols(a: std.mem.Allocator, source: []const u8) ![]const u8 {
    const protocols = [_][]const u8{
        "bitcoin", "ftp",    "ftps", "geo",    "git",  "gopher",    "http", "https", "irc",  "ircs",
        "magnet",  "mailto", "mms",  "news",   "nntp", "redis",     "sftp", "sip",   "sips", "sms",
        "ssh",     "svn",    "tel",  "telnet", "urn",  "worldwind", "xmpp",
    };
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < source.len) {
        var matched: ?[]const u8 = null;
        for (protocols) |protocol| {
            if (i + protocol.len < source.len and source[i + protocol.len] == ':' and std.ascii.eqlIgnoreCase(source[i .. i + protocol.len], protocol)) {
                matched = protocol;
                break;
            }
        }
        if (matched) |protocol| {
            try out.appendSlice(a, source[i .. i + protocol.len]);
            try out.appendSlice(a, "&#58;");
            i += protocol.len + 1;
        } else {
            try out.append(a, source[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(a);
}

fn textNowikiCall(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    var stage1: std.ArrayList(u8) = .empty;
    try appendNowikiPrimary(&stage1, a, args[0].string);
    var text: []const u8 = try stage1.toOwnedSlice(a);
    text = try protectNowikiLineStarts(a, text);
    text = try replaceLiteralAlloc(a, text, "!!", "&#33;!");
    text = try replaceLiteralAlloc(a, text, "__", "_&#95;");
    text = try replaceLiteralAlloc(a, text, "://", "&#58;//");
    text = try replaceLiteralAlloc(a, text, "~~~", "~~&#126;");
    text = try replaceLiteralAlloc(a, text, "＿", "&#xFF3F;");
    if (text.len != 0) {
        const first: ?[]const u8 = switch (text[0]) {
            '-' => "&#45;",
            '+' => "&#43;",
            '_' => "&#95;",
            '~' => "&#126;",
            else => null,
        };
        if (first) |r| text = try std.fmt.allocPrint(a, "{s}{s}", .{ r, text[1..] });
    }
    if (text.len != 0) {
        const last: ?[]const u8 = switch (text[text.len - 1]) {
            '_' => "&#95;",
            '~' => "&#126;",
            '\r' => "&#13;",
            '\n' => "&#10;",
            '\t' => "&#9;",
            else => null,
        };
        if (last) |r| text = try std.fmt.allocPrint(a, "{s}{s}", .{ text[0 .. text.len - 1], r });
    }
    text = try protectMagicLinkWhitespace(a, text);
    text = try protectNowikiProtocols(a, text);
    return one(a, .{ .string = text });
}

fn textUnstripCall(ctx_raw: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const source = args[0].string;
    if (std.mem.indexOfScalar(u8, source, 0x7f) != null) {
        const runtime: *Runtime = @ptrCast(@alignCast(ctx_raw.?));
        runtime.last_not_implemented = "mw.text.unstrip(strip marker)";
        return error.NotImplemented;
    }
    return one(a, .{ .string = source });
}

fn textUnstripNoWikiCall(ctx_raw: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const runtime: *Runtime = @ptrCast(@alignCast(ctx_raw.?));
    const source = args[0].string;
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, source, pos, nowiki_marker_prefix)) |at| {
        try out.appendSlice(a, source[pos..at]);
        const id_start = at + nowiki_marker_prefix.len;
        const suffix_at = std.mem.indexOfPos(u8, source, id_start, nowiki_marker_suffix) orelse {
            try out.appendSlice(a, source[at..]);
            pos = source.len;
            break;
        };
        const marker_end = suffix_at + nowiki_marker_suffix.len;
        const id = std.fmt.parseInt(u32, source[id_start..suffix_at], 16) catch {
            try out.appendSlice(a, source[at..marker_end]);
            pos = marker_end;
            continue;
        };
        if (runtime.strip_values.get(id)) |content|
            try out.appendSlice(a, content)
        else
            try out.appendSlice(a, source[at..marker_end]);
        pos = marker_end;
    }
    try out.appendSlice(a, source[pos..]);
    return one(a, .{ .string = try out.toOwnedSlice(a) });
}

fn textTrimCall(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const chars = if (args.len > 1 and args[1] == .string) args[1].string else " \t\r\n\x0b\x0c";
    return one(a, .{ .string = std.mem.trim(u8, args[0].string, chars) });
}

fn textListToTextCall(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const t = args[0].table;
    const n = t.rawLen();
    const separator = if (args.len > 1 and args[1] == .string) args[1].string else ", ";
    const conjunction = if (args.len > 2 and args[2] == .string) args[2].string else " and ";
    var pieces: std.ArrayList([]const u8) = .empty;
    var total: usize = 0;
    for (0..n) |i| {
        const value = t.rawGet(.{ .number = @floatFromInt(i + 1) }) orelse .nil;
        const text = try rt.toConcatString(a, value);
        try pieces.append(a, text);
        total += text.len;
        if (i + 1 < n) total += if (i + 2 == n) conjunction.len else separator.len;
    }
    const out = try a.alloc(u8, total);
    var pos: usize = 0;
    for (pieces.items, 0..) |piece, i| {
        @memcpy(out[pos .. pos + piece.len], piece);
        pos += piece.len;
        if (i + 1 < n) {
            const sep = if (i + 2 == n) conjunction else separator;
            @memcpy(out[pos .. pos + sep.len], sep);
            pos += sep.len;
        }
    }
    return one(a, .{ .string = out });
}

fn appendAnchorEncoded(out: *std.ArrayList(u8), a: std.mem.Allocator, source: []const u8) !void {
    var i: usize = 0;
    var pending_separator = false;
    while (i < source.len) {
        if (i + 1 < source.len and source[i] == '[' and source[i + 1] == '[') {
            if (std.mem.indexOfPos(u8, source, i + 2, "]]")) |close| {
                const inner = source[i + 2 .. close];
                const shown = if (std.mem.lastIndexOfScalar(u8, inner, '|')) |bar| inner[bar + 1 ..] else inner;
                try appendAnchorEncoded(out, a, shown);
                i = close + 2;
                continue;
            }
        }
        if (source[i] == '<') {
            if (std.mem.indexOfScalarPos(u8, source, i + 1, '>')) |close| {
                i = close + 1;
                continue;
            }
        }
        if (source[i] == '&') {
            if (std.mem.startsWith(u8, source[i..], "&nbsp;")) {
                pending_separator = out.items.len != 0;
                i += 6;
                continue;
            }
            if (std.mem.startsWith(u8, source[i..], "&amp;")) {
                if (pending_separator and out.items.len != 0 and out.items[out.items.len - 1] != '_') try out.append(a, '_');
                pending_separator = false;
                try out.appendSlice(a, "&amp;");
                i += 5;
                continue;
            }
        }
        const c = source[i];
        if (c == '_' or std.ascii.isWhitespace(c)) {
            pending_separator = out.items.len != 0;
            i += 1;
            continue;
        }
        if (pending_separator and out.items.len != 0 and out.items[out.items.len - 1] != '_') try out.append(a, '_');
        pending_separator = false;
        switch (c) {
            '&' => try out.appendSlice(a, "&amp;"),
            '"' => try out.appendSlice(a, "&quot;"),
            '\'' => try out.appendSlice(a, "&#039;"),
            '[' => try out.appendSlice(a, "&#91;"),
            ']' => try out.appendSlice(a, "&#93;"),
            '{' => try out.appendSlice(a, "&#123;"),
            else => try out.append(a, c),
        }
        i += 1;
    }
}

const WikiUrlKind = enum { local, full, canonical };

fn appendWikiEncoded(out: *std.ArrayList(u8), a: std.mem.Allocator, source: []const u8) !void {
    for (source) |c| {
        const safe = std.ascii.isAlphanumeric(c) or c == '!' or c == '$' or c == '(' or c == ')' or c == '*' or c == ',' or c == '.' or c == '/' or c == ':' or c == ';' or c == '@' or c == '~' or c == '_' or c == '-';
        if (safe) try out.append(a, c) else if (c == ' ') try out.append(a, '_') else try appendPercentByte(out, a, c);
    }
}

fn appendQueryEncoded(out: *std.ArrayList(u8), a: std.mem.Allocator, source: []const u8) !void {
    for (source) |c| {
        const safe = std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '~' or c == '-';
        if (safe) try out.append(a, c) else if (c == ' ') try out.append(a, '+') else try appendPercentByte(out, a, c);
    }
}

fn appendAmpEscaped(out: *std.ArrayList(u8), a: std.mem.Allocator, source: []const u8, escaped: bool) !void {
    if (!escaped) return out.appendSlice(a, source);
    var start: usize = 0;
    for (source, 0..) |c, i| if (c == '&') {
        try out.appendSlice(a, source[start..i]);
        try out.appendSlice(a, "&amp;");
        start = i + 1;
    };
    try out.appendSlice(a, source[start..]);
}

fn buildWikiUrlRawQuery(a: std.mem.Allocator, raw_title: []const u8, query: ?[]const u8, kind: WikiUrlKind, escaped: bool, proto_override: ?[]const u8) ![]const u8 {
    const title = std.mem.trim(u8, raw_title, " \t\r\n");
    const hash = std.mem.indexOfScalar(u8, title, '#');
    const base_title = if (hash) |i| title[0..i] else title;
    const fragment = if (hash) |i| title[i + 1 ..] else "";
    var out: std.ArrayList(u8) = .empty;
    switch (kind) {
        .local => {},
        .full => {
            if (proto_override) |proto| {
                if (std.ascii.eqlIgnoreCase(proto, "http") or std.ascii.eqlIgnoreCase(proto, "https")) {
                    try out.appendSlice(a, proto);
                    try out.appendSlice(a, "://en.wiktionary.org");
                } else {
                    try out.appendSlice(a, "//en.wiktionary.org");
                }
            } else try out.appendSlice(a, "//en.wiktionary.org");
        },
        .canonical => try out.appendSlice(a, "https://en.wiktionary.org"),
    }
    if (query) |q| {
        try out.appendSlice(a, "/w/index.php?title=");
        try appendWikiEncoded(&out, a, base_title);
        if (q.len != 0) {
            try out.appendSlice(a, if (escaped) "&amp;" else "&");
            try appendAmpEscaped(&out, a, q, escaped);
        }
    } else {
        try out.appendSlice(a, "/wiki/");
        try appendWikiEncoded(&out, a, base_title);
    }
    if (fragment.len != 0) {
        try out.append(a, '#');
        try appendWikiEncoded(&out, a, fragment);
    }
    return out.toOwnedSlice(a);
}

fn queryScalarText(a: std.mem.Allocator, value: Value) !?[]const u8 {
    return switch (value) {
        .nil => null,
        .string => |s| s,
        .number => |n| try rt.numberToString(a, n),
        .boolean => |b| if (b) "1" else null,
        else => error.WikitextScalarExpected,
    };
}

fn buildQueryArgument(runtime: *Runtime, value: Value) !?[]const u8 {
    if (value == .nil) return null;
    if (value == .string) return value.string;
    if (value != .table) return error.WikitextScalarExpected;
    var entries: std.ArrayList(struct { key: []const u8, value: Value }) = .empty;
    defer entries.deinit(runtime.allocator);
    var it = value.table.map.iterator();
    while (it.next()) |e| {
        const key = try queryScalarText(runtime.allocator, e.key_ptr.*) orelse continue;
        try entries.append(runtime.allocator, .{ .key = key, .value = e.value_ptr.* });
    }
    std.mem.sort(@TypeOf(entries.items[0]), entries.items, {}, struct {
        fn less(_: void, lhs: @TypeOf(entries.items[0]), rhs: @TypeOf(entries.items[0])) bool {
            return std.mem.order(u8, lhs.key, rhs.key) == .lt;
        }
    }.less);
    var out: std.ArrayList(u8) = .empty;
    for (entries.items, 0..) |entry, i| {
        if (i != 0) try out.append(runtime.allocator, '&');
        try appendQueryEncoded(&out, runtime.allocator, entry.key);
        if (entry.value == .boolean and !entry.value.boolean) continue;
        const text = try queryScalarText(runtime.allocator, entry.value) orelse continue;
        try out.append(runtime.allocator, '=');
        try appendQueryEncoded(&out, runtime.allocator, text);
    }
    const owned = try out.toOwnedSlice(runtime.allocator);
    return @as([]const u8, owned);
}

const UriStringCtx = struct { url: []const u8 };

fn uriObjectToStringCall(ctx_raw: ?*anyopaque, _: *anyopaque, _: []const Value, a: std.mem.Allocator) ![]const Value {
    const ctx: *UriStringCtx = @ptrCast(@alignCast(ctx_raw.?));
    return one(a, .{ .string = ctx.url });
}

fn makeUriObject(runtime: *Runtime, url: []const u8) !Value {
    const object = try rt.newTable(runtime.allocator);
    const mt = try rt.newTable(runtime.allocator);
    const ctx = try runtime.allocator.create(UriStringCtx);
    ctx.* = .{ .url = url };
    try mt.rawSet(runtime.allocator, .{ .string = "__tostring" }, try rt.newNative(runtime.allocator, ctx, uriObjectToStringCall));
    object.metatable = mt;
    const scheme_end = std.mem.indexOf(u8, url, "//");
    const authority_start: usize = if (scheme_end) |i| i + 2 else 0;
    if (scheme_end) |i| if (i != 0 and url[i - 1] == ':') try object.rawSet(runtime.allocator, .{ .string = "protocol" }, .{ .string = url[0 .. i - 1] });
    if (authority_start != 0) {
        const path_start = std.mem.indexOfScalarPos(u8, url, authority_start, '/') orelse url.len;
        try object.rawSet(runtime.allocator, .{ .string = "host" }, .{ .string = url[authority_start..path_start] });
        const query_at = std.mem.indexOfScalarPos(u8, url, path_start, '?');
        const frag_at = std.mem.indexOfScalarPos(u8, url, path_start, '#');
        const path_end = @min(query_at orelse url.len, frag_at orelse url.len);
        try object.rawSet(runtime.allocator, .{ .string = "path" }, .{ .string = url[path_start..path_end] });
        if (frag_at) |f| try object.rawSet(runtime.allocator, .{ .string = "fragment" }, .{ .string = url[f + 1 ..] });
    }
    return .{ .table = object };
}

fn uriUrlCall(ctx_raw: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator, kind: WikiUrlKind) ![]const Value {
    const runtime: *Runtime = @ptrCast(@alignCast(ctx_raw.?));
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const query = try buildQueryArgument(runtime, if (args.len > 1) args[1] else .nil);
    const url = try buildWikiUrlRawQuery(runtime.allocator, args[0].string, query, kind, false, null);
    return one(a, try makeUriObject(runtime, url));
}

fn uriFullUrlCall(ctx_raw: ?*anyopaque, raw: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    return uriUrlCall(ctx_raw, raw, args, a, .full);
}

fn uriLocalUrlCall(ctx_raw: ?*anyopaque, raw: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    return uriUrlCall(ctx_raw, raw, args, a, .local);
}

fn uriCanonicalUrlCall(ctx_raw: ?*anyopaque, raw: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    return uriUrlCall(ctx_raw, raw, args, a, .canonical);
}

fn uriMode(args: []const Value) !enum { query, path, wiki } {
    if (args.len < 2 or args[1] == .nil) return .query;
    if (args[1] != .string) return error.StringExpected;
    const mode = args[1].string;
    if (std.ascii.eqlIgnoreCase(mode, "QUERY")) return .query;
    if (std.ascii.eqlIgnoreCase(mode, "PATH")) return .path;
    if (std.ascii.eqlIgnoreCase(mode, "WIKI")) return .wiki;
    return error.InvalidUriEncoding;
}

fn appendPercentByte(out: *std.ArrayList(u8), a: std.mem.Allocator, byte: u8) !void {
    const hex = "0123456789ABCDEF";
    try out.append(a, '%');
    try out.append(a, hex[byte >> 4]);
    try out.append(a, hex[byte & 0xf]);
}

fn uriEncodeCall(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const mode = try uriMode(args);
    var out: std.ArrayList(u8) = .empty;
    for (args[0].string) |c| {
        const raw_safe = std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '~' or c == '-';
        const wiki_safe = raw_safe or c == '!' or c == '$' or c == '(' or c == ')' or c == '*' or c == ',' or c == '/' or c == ':' or c == ';' or c == '@';
        if ((mode == .wiki and wiki_safe) or (mode != .wiki and raw_safe)) {
            try out.append(a, c);
        } else if (c == ' ') {
            if (mode == .query) try out.append(a, '+') else if (mode == .wiki) try out.append(a, '_') else try out.appendSlice(a, "%20");
        } else try appendPercentByte(&out, a, c);
    }
    return one(a, .{ .string = try out.toOwnedSlice(a) });
}

fn hexNibble(c: u8) ?u8 {
    return if (c >= '0' and c <= '9') c - '0' else if (c >= 'a' and c <= 'f') c - 'a' + 10 else if (c >= 'A' and c <= 'F') c - 'A' + 10 else null;
}

fn uriDecodeCall(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const mode = try uriMode(args);
    const source = args[0].string;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        if ((mode == .query and c == '+') or (mode == .wiki and c == '_')) {
            try out.append(a, ' ');
            i += 1;
            continue;
        }
        if (c == '%' and i + 2 < source.len) {
            if (hexNibble(source[i + 1])) |hi| if (hexNibble(source[i + 2])) |lo| {
                try out.append(a, (hi << 4) | lo);
                i += 3;
                continue;
            };
        }
        try out.append(a, c);
        i += 1;
    }
    return one(a, .{ .string = try out.toOwnedSlice(a) });
}

fn uriAnchorEncodeCall(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    var out: std.ArrayList(u8) = .empty;
    try appendAnchorEncoded(&out, a, args[0].string);
    return one(a, .{ .string = try out.toOwnedSlice(a) });
}

const NamespaceSpec = struct {
    id: i32,
    name: []const u8,
    canonical_name: []const u8,
    has_subpages: bool,
    aliases: []const []const u8 = &.{},
};

fn addNamespace(runtime: *Runtime, namespaces: *rt.Table, spec: NamespaceSpec) !void {
    const ns = try rt.newTable(runtime.allocator);
    const aliases = try rt.newTable(runtime.allocator);
    for (spec.aliases) |alias| try aliases.append(runtime.allocator, .{ .string = alias });
    try ns.rawSet(runtime.allocator, .{ .string = "id" }, .{ .number = @floatFromInt(spec.id) });
    try ns.rawSet(runtime.allocator, .{ .string = "name" }, .{ .string = spec.name });
    try ns.rawSet(runtime.allocator, .{ .string = "canonicalName" }, .{ .string = spec.canonical_name });
    try ns.rawSet(runtime.allocator, .{ .string = "hasSubpages" }, .{ .boolean = spec.has_subpages });
    try ns.rawSet(runtime.allocator, .{ .string = "aliases" }, .{ .table = aliases });
    try namespaces.rawSet(runtime.allocator, .{ .number = @floatFromInt(spec.id) }, .{ .table = ns });
    if (spec.name.len != 0) try namespaces.rawSet(runtime.allocator, .{ .string = spec.name }, .{ .table = ns });
}

const wiktionary_namespaces = [_]NamespaceSpec{
    .{ .id = -2, .name = "Media", .canonical_name = "Media", .has_subpages = false },
    .{ .id = -1, .name = "Special", .canonical_name = "Special", .has_subpages = false },
    .{ .id = 0, .name = "", .canonical_name = "", .has_subpages = false },
    .{ .id = 1, .name = "Talk", .canonical_name = "Talk", .has_subpages = true },
    .{ .id = 2, .name = "User", .canonical_name = "User", .has_subpages = true },
    .{ .id = 3, .name = "User talk", .canonical_name = "User talk", .has_subpages = true },
    .{ .id = 4, .name = "Wiktionary", .canonical_name = "Project", .has_subpages = true, .aliases = &.{"WT"} },
    .{ .id = 5, .name = "Wiktionary talk", .canonical_name = "Project talk", .has_subpages = true },
    .{ .id = 6, .name = "File", .canonical_name = "File", .has_subpages = false, .aliases = &.{"Image"} },
    .{ .id = 7, .name = "File talk", .canonical_name = "File talk", .has_subpages = true, .aliases = &.{"Image talk"} },
    .{ .id = 8, .name = "MediaWiki", .canonical_name = "MediaWiki", .has_subpages = true },
    .{ .id = 9, .name = "MediaWiki talk", .canonical_name = "MediaWiki talk", .has_subpages = true },
    .{ .id = 10, .name = "Template", .canonical_name = "Template", .has_subpages = true, .aliases = &.{"T"} },
    .{ .id = 11, .name = "Template talk", .canonical_name = "Template talk", .has_subpages = true },
    .{ .id = 12, .name = "Help", .canonical_name = "Help", .has_subpages = true },
    .{ .id = 13, .name = "Help talk", .canonical_name = "Help talk", .has_subpages = true },
    .{ .id = 14, .name = "Category", .canonical_name = "Category", .has_subpages = false, .aliases = &.{"CAT"} },
    .{ .id = 15, .name = "Category talk", .canonical_name = "Category talk", .has_subpages = true },
    .{ .id = 90, .name = "Thread", .canonical_name = "Thread", .has_subpages = false },
    .{ .id = 91, .name = "Thread talk", .canonical_name = "Thread talk", .has_subpages = false },
    .{ .id = 92, .name = "Summary", .canonical_name = "Summary", .has_subpages = false },
    .{ .id = 93, .name = "Summary talk", .canonical_name = "Summary talk", .has_subpages = false },
    .{ .id = 100, .name = "Appendix", .canonical_name = "Appendix", .has_subpages = true, .aliases = &.{"AP"} },
    .{ .id = 101, .name = "Appendix talk", .canonical_name = "Appendix talk", .has_subpages = true },
    .{ .id = 106, .name = "Rhymes", .canonical_name = "Rhymes", .has_subpages = true },
    .{ .id = 107, .name = "Rhymes talk", .canonical_name = "Rhymes talk", .has_subpages = true },
    .{ .id = 108, .name = "Transwiki", .canonical_name = "Transwiki", .has_subpages = true },
    .{ .id = 109, .name = "Transwiki talk", .canonical_name = "Transwiki talk", .has_subpages = true },
    .{ .id = 110, .name = "Thesaurus", .canonical_name = "Thesaurus", .has_subpages = true, .aliases = &.{ "WS", "Wikisaurus" } },
    .{ .id = 111, .name = "Thesaurus talk", .canonical_name = "Thesaurus talk", .has_subpages = true, .aliases = &.{"Wikisaurus talk"} },
    .{ .id = 114, .name = "Citations", .canonical_name = "Citations", .has_subpages = true },
    .{ .id = 115, .name = "Citations talk", .canonical_name = "Citations talk", .has_subpages = true },
    .{ .id = 116, .name = "Sign gloss", .canonical_name = "Sign gloss", .has_subpages = true },
    .{ .id = 117, .name = "Sign gloss talk", .canonical_name = "Sign gloss talk", .has_subpages = true },
    .{ .id = 118, .name = "Reconstruction", .canonical_name = "Reconstruction", .has_subpages = true, .aliases = &.{"RC"} },
    .{ .id = 119, .name = "Reconstruction talk", .canonical_name = "Reconstruction talk", .has_subpages = true },
    .{ .id = 710, .name = "TimedText", .canonical_name = "TimedText", .has_subpages = false },
    .{ .id = 711, .name = "TimedText talk", .canonical_name = "TimedText talk", .has_subpages = false },
    .{ .id = 828, .name = "Module", .canonical_name = "Module", .has_subpages = true, .aliases = &.{"MOD"} },
    .{ .id = 829, .name = "Module talk", .canonical_name = "Module talk", .has_subpages = true },
    .{ .id = 1728, .name = "Event", .canonical_name = "Event", .has_subpages = true },
    .{ .id = 1729, .name = "Event talk", .canonical_name = "Event talk", .has_subpages = true },
    .{ .id = 2600, .name = "Topic", .canonical_name = "Topic", .has_subpages = false },
};

fn installStubTable(runtime: *Runtime, parent: *rt.Table, name: []const u8, funcs: []const []const u8) !*rt.Table {
    const table = try rt.newTable(runtime.allocator);
    for (funcs) |func| {
        const full_name = try std.fmt.allocPrint(runtime.allocator, "mw.{s}.{s}", .{ name, func });
        try hostSetNotImplemented(runtime, table, func, full_name);
    }
    try parent.rawSet(runtime.allocator, .{ .string = name }, .{ .table = table });
    return table;
}

fn installMwBasics(runtime: *Runtime, _: *exec.Vm, mw: *rt.Table) !void {
    try hostSetNative(runtime, mw, "dumpObject", dumpObjectCall, runtime);
    try hostSetNative(runtime, mw, "log", noOpCall, runtime);
    try hostSetNative(runtime, mw, "logObject", noOpCall, runtime);
    try hostSetNative(runtime, mw, "addWarning", noOpCall, runtime);
    try hostSetNative(runtime, mw, "isSubsting", falseCall, runtime);

    const title = try rt.newTable(runtime.allocator);
    _ = try ensureTitleMetatable(runtime);
    try title.rawSet(runtime.allocator, .{ .string = "equals" }, runtime.title_equals.?);
    try hostSetNative(runtime, title, "compare", titleCompareCall, runtime);
    try hostSetNative(runtime, title, "new", titleNewCall, runtime);
    try hostSetNative(runtime, title, "makeTitle", titleMakeCall, runtime);
    try hostSetNative(runtime, title, "getCurrentTitle", titleCurrentCall, runtime);
    try hostSetNotImplemented(runtime, title, "newBatch", "mw.title.newBatch");
    try mw.rawSet(runtime.allocator, .{ .string = "title" }, .{ .table = title });

    const text = try rt.newTable(runtime.allocator);
    try hostSetNative(runtime, text, "trim", textTrimCall, runtime);
    try hostSetNative(runtime, text, "split", textSplitCall, runtime);
    try hostSetNative(runtime, text, "gsplit", textGsplitCall, runtime);
    try hostSetNative(runtime, text, "unstrip", textUnstripCall, runtime);
    try hostSetNative(runtime, text, "unstripNoWiki", textUnstripNoWikiCall, runtime);
    try hostSetNative(runtime, text, "listToText", textListToTextCall, runtime);
    try hostSetNative(runtime, text, "nowiki", textNowikiCall, runtime);
    inline for (&.{ "jsonEncode", "jsonDecode", "tag", "truncate", "encode", "decode" }) |name|
        try hostSetNotImplemented(runtime, text, name, try std.fmt.allocPrint(runtime.allocator, "mw.text.{s}", .{name}));
    try mw.rawSet(runtime.allocator, .{ .string = "text" }, .{ .table = text });

    const site = try rt.newTable(runtime.allocator);
    const namespaces = try rt.newTable(runtime.allocator);
    for (wiktionary_namespaces) |spec| try addNamespace(runtime, namespaces, spec);
    try site.rawSet(runtime.allocator, .{ .string = "namespaces" }, .{ .table = namespaces });
    const stats = try rt.newTable(runtime.allocator);
    try hostSetNotImplemented(runtime, stats, "pagesInCategory", "mw.site.stats.pagesInCategory");
    try site.rawSet(runtime.allocator, .{ .string = "stats" }, .{ .table = stats });
    try hostSetNative(runtime, site, "interwikiMap", interwikiMapCall, runtime);
    try mw.rawSet(runtime.allocator, .{ .string = "site" }, .{ .table = site });

    const uri = try installStubTable(runtime, mw, "uri", &.{});
    try hostSetNative(runtime, uri, "fullUrl", uriFullUrlCall, runtime);
    try hostSetNative(runtime, uri, "localUrl", uriLocalUrlCall, runtime);
    try hostSetNative(runtime, uri, "canonicalUrl", uriCanonicalUrlCall, runtime);
    try hostSetNative(runtime, uri, "encode", uriEncodeCall, runtime);
    try hostSetNative(runtime, uri, "decode", uriDecodeCall, runtime);
    try hostSetNative(runtime, uri, "anchorEncode", uriAnchorEncodeCall, runtime);
    try html_lib.install(runtime.allocator, mw);
    try language_lib.install(runtime.allocator, runtime.io, mw);
    const wikibase = try installStubTable(runtime, mw, "wikibase", &.{
        "getEntity",      "getDescription",  "getLabel",          "getEntityIdForCurrentPage",
        "getSitelink",    "getEntityUrl",    "getBestStatements", "getLabelWithLang",
        "getLabelByLang", "isValidEntityId", "entityExists",
    });
    try hostSetNative(runtime, wikibase, "sitelink", wikibaseSitelinkCall, runtime);
    _ = try installStubTable(runtime, mw, "message", &.{"new"});
    _ = try installStubTable(runtime, mw, "hash", &.{"hashValue"});

    const ext = try rt.newTable(runtime.allocator);
    const data = try rt.newTable(runtime.allocator);
    try hostSetNotImplemented(runtime, data, "get", "mw.ext.data.get");
    try ext.rawSet(runtime.allocator, .{ .string = "data" }, .{ .table = data });
    try mw.rawSet(runtime.allocator, .{ .string = "ext" }, .{ .table = ext });
}

pub fn titleForProgram(runtime: *const Runtime, program: *const ir.Program) ?[]const u8 {
    return runtime.program_titles.get(program);
}

test "Lua dictionary iteration with Unicode keys drives longest-prefix conversion" {
    const lua = @import("root.zig");
    const source =
        \\local d = { ["ā"] = "aː", ["ī"] = "iː", ["g"] = "ɡ" }
        \\local word, ph = "grātīs", {}
        \\while mw.ustring.len(word) > 0 do
        \\  local longest = ""
        \\  for letter in pairs(d) do
        \\    local n = mw.ustring.len(letter)
        \\    if n > mw.ustring.len(longest) and mw.ustring.sub(word, 1, n) == letter then longest = letter end
        \\  end
        \\  if mw.ustring.len(longest) > 0 then
        \\    table.insert(ph, d[longest]); word = mw.ustring.sub(word, mw.ustring.len(longest) + 1)
        \\  else
        \\    table.insert(ph, mw.ustring.sub(word, 1, 1)); word = mw.ustring.sub(word, 2)
        \\  end
        \\end
        \\return table.concat(ph)
    ;
    var chunk = try lua.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var program = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), std.testing.io, "modules");
    var vm = try exec.Vm.init(arena.allocator());
    try runtime.install(&vm);
    const out = try vm.executeRoot(&program, &.{});
    defer exec.Vm.freeResults(out);
    try std.testing.expectEqualStrings("ɡraːtiːs", out[0].string);
}

test "frame formatdate matches MediaWiki date-order output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), std.testing.io, "modules");
    const args = try rt.newTable(runtime.allocator);
    const frame = try makeFrameWithArgsTable(&runtime, "test", args, null);
    const direct = try frameCallParserFunctionCall(frame.table.rawGet(.{ .string = "callParserFunction" }).?.native.ctx, undefined, &.{ frame, .{ .string = "#formatdate" }, .{ .string = "1864-09-02" }, .{ .string = "dmy" } }, runtime.allocator);
    defer exec.Vm.freeResults(direct);
    try std.testing.expectEqualStrings("<span class=\"mw-formatted-date\" title=\"1864-09-02\">2 September 1864</span>", direct[0].string);
    const partial = try formattedDateSpan(&runtime, "1864-9", "dmy");
    try std.testing.expectEqualStrings("1864-9", partial);
    const spec = try rt.newTable(runtime.allocator);
    try spec.rawSet(runtime.allocator, .{ .string = "name" }, .{ .string = "#formatdate" });
    try spec.rawSet(runtime.allocator, .{ .string = "args" }, .{ .string = "2009-04-18" });
    const table_call = try frameCallParserFunctionCall(frame.table.rawGet(.{ .string = "callParserFunction" }).?.native.ctx, undefined, &.{ frame, .{ .table = spec } }, runtime.allocator);
    defer exec.Vm.freeResults(table_call);
    try std.testing.expectEqualStrings("<span class=\"mw-formatted-date\" title=\"2009-04-18\">2009-04-18</span>", table_call[0].string);
}

test "page preprocessing removes comments without changing raw getContent source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), std.testing.io, "modules");
    runtime.beginPage(arena.allocator(), "Commented");
    var vm = try exec.Vm.init(arena.allocator());
    const raw = "A<!-- hidden | x=y -->B";
    const rendered = try runtime.expandFragment(&vm, "Commented", raw);
    try std.testing.expectEqualStrings("AB", rendered);
    try std.testing.expectEqualStrings(raw, runtime.current_page_source.?);
    const comment_arg = try stripDecodedComments(arena.allocator(), "en\n<!-- title is Latin -->\n");
    try std.testing.expectEqualStrings("en\n\n", comment_arg);
}

test "top-level delimiters ignore parser extension tags and comments" {
    const math = "<math>z</math> is the '''free''' variable in <math>\\forall x\\exists y:xy=z</math>.";
    try std.testing.expect(findTopDelimiter(math, '=') == null);
    try std.testing.expectEqual(@as(?usize, 1), findTopDelimiter("x=<math>a=b</math>", '='));
    const ref = "<ref name=\"a=b\">x=y|z</ref>|tail";
    try std.testing.expectEqual(@as(?usize, std.mem.indexOf(u8, ref, "|tail").?), findTopDelimiter(ref, '|'));
    try std.testing.expect(findTopDelimiter("<!-- x=y|z -->plain", '=') == null);
}

test "top-level delimiters preserve typed template and parameter nesting" {
    const nested = "#if:{{{1|}}}|{{#switch:{{{2|}}}|cog=Cognates|#default={{#if:{{{2|}}}|{{{2|}}}|Terms}}}}|{{error|1=x}}";
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(std.testing.allocator);
    try splitWikitextTop(std.testing.allocator, nested, '|', &parts);
    try std.testing.expectEqual(@as(usize, 3), parts.items.len);
    try std.testing.expectEqualStrings("#if:{{{1|}}}", parts.items[0]);
    try std.testing.expectEqualStrings("{{error|1=x}}", parts.items[2]);
}

test "MediaWiki ifexist checks local page existence and expands only the selected branch" {
    const Provider = struct {
        fn get(_: *anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!?[]const u8 {
            return null;
        }
        fn exists(_: *anyopaque, _: std.mem.Allocator, title: []const u8) anyerror!bool {
            return std.mem.eql(u8, title, "Known page");
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), std.testing.io, "modules");
    var provider_ctx: u8 = 0;
    runtime.setPageContentProvider(.{ .ctx = &provider_ctx, .get = Provider.get, .exists = Provider.exists });
    runtime.beginPage(arena.allocator(), "cat");
    var vm = try exec.Vm.init(arena.allocator());
    try runtime.install(&vm);
    const params = try rt.newTable(arena.allocator());

    try std.testing.expectEqualStrings("yes", try runtime.expandFragment(&vm, "cat", "{{#ifexist: cat|yes|{{#not-a-function:x}}}}"));
    try std.testing.expectEqualStrings("known", try runtime.expandConstruct(&vm, "#ifexist: Known_page#section|known|missing", params, "test", 0));
    try std.testing.expectEqualStrings("no", try runtime.expandConstruct(&vm, "#ifexist: Missing page|{{#not-a-function:x}}|no", params, "test", 0));
}

test "parameter matcher preserves nested template braces in defaults" {
    const nested = "{{{sc|{{mul-symbol/script|{{bestscript|mul|{{{head|{{pagename}}}}}}}}}}}}";
    try std.testing.expectEqual(nested.len - 3, findParamEnd(nested, 0).?);
    const inner = "{{{head|{{pagename}}}}}";
    try std.testing.expectEqual(inner.len - 3, findParamEnd(inner, 0).?);
}

test "MediaWiki padleft and padright count Unicode codepoints and cycle padding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), std.testing.io, "modules");
    runtime.beginPage(arena.allocator(), "Pad");
    var vm = try exec.Vm.init(arena.allocator());
    try runtime.install(&vm);
    const params = try rt.newTable(arena.allocator());
    inline for (.{
        .{ "padleft:abc|5", "00abc" },        .{ "padright:abc|5", "abc00" },
        .{ "padleft:abc|8|xyz", "xyzxyabc" }, .{ "padright:abc|8|xyz", "abcxyzxy" },
        .{ "padleft:é|3|ø", "øøé" },
        .{ "padleft:|3|ab", "aba" },          .{ "padleft:abcdef|3|x", "abcdef" },
        .{ "padleft:a|4|", "a" },
    }) |case| try std.testing.expectEqualStrings(case[1], try runtime.expandConstruct(&vm, case[0], params, "test", 0));
}

test "MediaWiki expr and ifexpr parser functions use ExprParser precedence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), std.testing.io, "modules");
    runtime.beginPage(arena.allocator(), "Expr");
    var vm = try exec.Vm.init(arena.allocator());
    try runtime.install(&vm);
    const params = try rt.newTable(arena.allocator());
    try params.rawSet(arena.allocator(), .{ .string = "page" }, .{ .string = "6" });
    try std.testing.expectEqualStrings("335", try runtime.expandConstruct(&vm, "#expr:{{{page}}}+329", params, "test", 0));
    try std.testing.expectEqualStrings("yes", try runtime.expandConstruct(&vm, "#ifexpr:2 < 3 and not 0|yes|no", params, "test", 0));
    const invalid = try runtime.expandConstruct(&vm, "#expr:1/0", params, "test", 0);
    try std.testing.expect(std.mem.startsWith(u8, invalid, "<strong class=\"error\">"));
}

test "Wikibase sitelink cache distinguishes verified absence from unknown data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), std.testing.io, "modules");
    const absent_key = try std.fmt.allocPrint(arena.allocator(), "Q1\x1fenwiki", .{});
    try runtime.wikibase_absent_sitelinks.put(arena.allocator(), absent_key, {});
    try std.testing.expect((try runtime.wikibaseSitelink("Q1", "enwiki")) == .absent);
    try std.testing.expect((try runtime.wikibaseSitelink("Q2", "enwiki")) == .unknown);
}

test "MediaWiki urlencode parser function uses URI modes and nested magic words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), std.testing.io, "modules");
    runtime.beginPage(arena.allocator(), "A B");
    var vm = try exec.Vm.init(arena.allocator());
    try runtime.install(&vm);
    const params = try rt.newTable(arena.allocator());
    try std.testing.expectEqualStrings("A+B", try runtime.expandConstruct(&vm, "urlencode:{{pagename}}", params, "test", 0));
    try std.testing.expectEqualStrings("a%20b", try runtime.expandConstruct(&vm, "urlencode:a b|PATH", params, "test", 0));
    try std.testing.expectEqualStrings("%C3%A9_%CE%B1", try runtime.expandConstruct(&vm, "urlencode:é α|WIKI", params, "test", 0));
}

test "mw.text nowiki follows Scribunto escaping rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{
        .{ "[[x|y]]", "&#91;&#91;x&#124;y&#93;&#93;" },
        .{ "# item\n* two", "&#35; item\n&#42; two" },
        .{ "----\n__TOC__", "&#45;---\n_&#95;TOC_&#95;" },
        .{ "http://x ISBN 1", "http&#58;//x ISBN&#32;1" },
        .{ "mailto:x@y", "mailto&#58;x@y" },
        .{ "~abc_", "&#126;abc&#95;" },
    }) |case| {
        const got = try textNowikiCall(null, undefined, &.{.{ .string = case[0] }}, a);
        defer exec.Vm.freeResults(got);
        try std.testing.expectEqualStrings(case[1], got[0].string);
    }
}

test "mw.text gsplit uses Unicode separators and empty separator semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), std.testing.io, "modules");
    var vm = try exec.Vm.init(arena.allocator());
    try runtime.install(&vm);

    const gsplit = vm.globals.rawGet(.{ .string = "mw" }).?.table.rawGet(.{ .string = "text" }).?.table.rawGet(.{ .string = "gsplit" }).?;
    const created = try vm.callValue(gsplit, &.{ .{ .string = "가나다" }, .{ .string = "" } });
    defer exec.Vm.freeResults(created);
    const iterator = created[0];
    inline for (.{ "가", "나", "다" }) |expected| {
        const item = try vm.callValue(iterator, &.{});
        defer exec.Vm.freeResults(item);
        try std.testing.expectEqualStrings(expected, item[0].string);
    }
    const done = try vm.callValue(iterator, &.{});
    defer exec.Vm.freeResults(done);
    try std.testing.expectEqual(@as(usize, 0), done.len);

    const split = vm.globals.rawGet(.{ .string = "mw" }).?.table.rawGet(.{ .string = "text" }).?.table.rawGet(.{ .string = "split" }).?;
    const pieces = try vm.callValue(split, &.{ .{ .string = "α,β,,γ" }, .{ .string = "," }, .{ .boolean = true } });
    defer exec.Vm.freeResults(pieces);
    try std.testing.expectEqualStrings("α", pieces[0].table.rawGet(.{ .number = 1 }).?.string);
    try std.testing.expectEqualStrings("β", pieces[0].table.rawGet(.{ .number = 2 }).?.string);
    try std.testing.expectEqualStrings("", pieces[0].table.rawGet(.{ .number = 3 }).?.string);
    try std.testing.expectEqualStrings("γ", pieces[0].table.rawGet(.{ .number = 4 }).?.string);
}

test "unmatched template and parameter openers remain literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), std.testing.io, "modules");
    var vm = try exec.Vm.init(arena.allocator());
    const params = try rt.newTable(arena.allocator());
    for ([_][]const u8{ "{{", "{{foo", "a{{b", "{{{", "{{{foo", "a{{{b" }) |source| {
        const got = try runtime.expandWikitext(&vm, source, params, "test", 0);
        try std.testing.expectEqualStrings(source, got);
    }
}

test "template title normalization keeps namespace" {
    const a = std.testing.allocator;
    const x = try normalizeTemplateName(a, "Template:zh_l");
    defer a.free(x);
    const y = try normalizeTemplateName(a, "zh_l");
    defer a.free(y);
    try std.testing.expectEqualStrings("Template:zh l", x);
    try std.testing.expectEqualStrings("Template:zh l", y);
}

test "MediaWiki tag parser function expands Cite body and attributes" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), threaded.io(), ".");
    runtime.beginPage(arena.allocator(), "Smoke");
    var vm = try exec.Vm.init(arena.allocator());
    try runtime.install(&vm);
    const params = try rt.newTable(arena.allocator());
    const got = try runtime.expandWikitext(&vm, "{{#tag:ref|{{uc:abc}}|name=a&b|group=q\"z}}", params, "Smoke", 0);
    try std.testing.expectEqualStrings("<ref group=\"q&quot;z\" name=\"a&amp;b\">ABC</ref>", got);
    const refs = try runtime.expandWikitext(&vm, "{{#tag:references|}}", params, "Smoke", 0);
    try std.testing.expectEqualStrings("<references></references>", refs);
}

test "Cite extension tags serialize content and escaped attributes" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), threaded.io(), ".");
    runtime.beginPage(arena.allocator(), "Smoke");
    const frame = try makeFrame(&runtime, "Smoke", &.{}, null);
    const attrs = try rt.newTable(arena.allocator());
    try attrs.rawSet(arena.allocator(), .{ .string = "name" }, .{ .string = "a&b" });
    try attrs.rawSet(arena.allocator(), .{ .string = "group" }, .{ .string = "q\"z" });
    const method = frame.table.rawGet(.{ .string = "extensionTag" }).?;
    var vm = try exec.Vm.init(arena.allocator());
    const out = try vm.callValue(method, &.{ frame, .{ .string = "ref" }, .{ .string = "a<b&c" }, .{ .table = attrs } });
    defer exec.Vm.freeResults(out);
    // Attribute order follows our deterministic table serialization; MediaWiki
    // treats the order as semantically irrelevant.
    try std.testing.expectEqualStrings("<ref group=\"q&quot;z\" name=\"a&amp;b\">a<b&c</ref>", out[0].string);

    const empty = try vm.callValue(method, &.{ frame, .{ .string = "ref" }, .nil, .{ .table = attrs } });
    defer exec.Vm.freeResults(empty);
    try std.testing.expect(std.mem.startsWith(u8, empty[0].string, "<ref "));
    try std.testing.expect(std.mem.endsWith(u8, empty[0].string, "></ref>"));
}

test "templatestyles extension serialization is deterministic" {
    const a = std.testing.allocator;
    const attrs = try rt.newTable(a);
    defer {
        attrs.deinit(a);
        a.destroy(attrs);
    }
    try attrs.rawSet(a, .{ .string = "wrapper" }, .{ .string = ".x&y" });
    try attrs.rawSet(a, .{ .string = "src" }, .{ .string = "a\"b.css" });
    const rendered = try serializeExtensionTag(a, "templatestyles", null, attrs);
    defer a.free(rendered);
    try std.testing.expectEqualStrings("<templatestyles src=\"a&quot;b.css\" wrapper=\".x&amp;y\"/>", rendered);
}

test "mw.uri.anchorEncode matches MediaWiki fragment normalization" {
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "English: work", .expected = "English:_work" },
        .{ .input = "a b_c", .expected = "a_b_c" },
        .{ .input = "a&b", .expected = "a&amp;b" },
        .{ .input = "a<b>", .expected = "a" },
        .{ .input = "é α", .expected = "é_α" },
        .{ .input = "[[foo]]", .expected = "foo" },
        .{ .input = "[[foo|bar baz]]", .expected = "bar_baz" },
        .{ .input = "  a  b  ", .expected = "a_b" },
        .{ .input = "a\"b", .expected = "a&quot;b" },
        .{ .input = "a[b]", .expected = "a&#91;b&#93;" },
        .{ .input = "a{b}", .expected = "a&#123;b}" },
        .{ .input = "a'b", .expected = "a&#039;b" },
        .{ .input = "a&nbsp;b", .expected = "a_b" },
        .{ .input = "<i>x</i> y", .expected = "x_y" },
    };
    for (cases) |case| {
        var out: std.ArrayList(u8) = .empty;
        try appendAnchorEncoded(&out, std.testing.allocator, case.input);
        const got = try out.toOwnedSlice(std.testing.allocator);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(case.expected, got);
    }
}

test "title objects expose Scribunto comparison metamethods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), std.testing.io, "modules");
    var vm = try exec.Vm.init(arena.allocator());
    const a_title = try makeTitleValue(&runtime, "A");
    const b_title = try makeTitleValue(&runtime, "B");
    const mt = a_title.table.metatable.?;
    try std.testing.expect(mt.rawGet(.{ .string = "__eq" }) != null);
    try std.testing.expect(mt.rawGet(.{ .string = "__lt" }) != null);
    try std.testing.expect(try vm.comparison(.lt, a_title, b_title));
    try std.testing.expect(!(try vm.comparison(.eq, a_title, b_title)));
    try std.testing.expect(try vm.comparison(.eq, a_title, a_title));
}

test "MediaWiki punctuation magic words expand without template lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), std.testing.io, "modules");
    try std.testing.expectEqualStrings("|", (try magicWord(&runtime, "!")).?);
    try std.testing.expectEqualStrings("||", (try magicWord(&runtime, "!!")).?);
    try std.testing.expectEqualStrings("=", (try magicWord(&runtime, "=")).?);
}

test "REVISIONID magic word uses page replay revision" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), std.testing.io, "modules");
    runtime.beginPage(arena.allocator(), "dictionary");
    runtime.setCurrentRevisionId("123456");
    try std.testing.expectEqualStrings("123456", (try magicWord(&runtime, "REVISIONID")).?);
}

test "MediaWiki CURRENT date magic words share one UTC page instant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), std.testing.io, "modules");
    runtime.beginPage(arena.allocator(), "Clock");
    runtime.setPageNowUnix(1709176029); // 2024-02-29 03:07:09 UTC
    inline for (.{
        .{ "CURRENTYEAR", "2024" },          .{ "CURRENTMONTH", "02" },                 .{ "CURRENTMONTH1", "2" },
        .{ "CURRENTMONTHNAME", "February" }, .{ "CURRENTMONTHABBREV", "Feb" },          .{ "CURRENTDAY", "29" },
        .{ "CURRENTDAY2", "29" },            .{ "CURRENTDOW", "4" },                    .{ "CURRENTTIME", "03:07" },
        .{ "CURRENTHOUR", "03" },            .{ "CURRENTTIMESTAMP", "20240229030709" },
    }) |case| try std.testing.expectEqualStrings(case[1], (try magicWord(&runtime, case[0])).?);
}

test "Scribunto title fragment and fullText semantics are dynamic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), std.testing.io, "modules");
    var vm = try exec.Vm.init(arena.allocator());
    const title = try makeTitleValue(&runtime, "Module talk:Test Framework# _ frag _ frag _ ");
    try std.testing.expectEqualStrings(" frag frag", (try vm.getIndex(title, .{ .string = "fragment" })).string);
    try std.testing.expectEqualStrings("Module talk:Test Framework# frag frag", (try vm.getIndex(title, .{ .string = "fullText" })).string);
    try vm.setIndex(title, .{ .string = "fragment" }, .{ .string = "__new__frag__" });
    try std.testing.expectEqualStrings(" new frag", (try vm.getIndex(title, .{ .string = "fragment" })).string);
    try std.testing.expectEqualStrings("Module talk:Test Framework# new frag", (try vm.getIndex(title, .{ .string = "fullText" })).string);
}

test "Wiktionary namespace metadata includes aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), std.testing.io, "modules");
    const namespaces = try rt.newTable(runtime.allocator);
    for (wiktionary_namespaces) |spec| try addNamespace(&runtime, namespaces, spec);
    const module = namespaces.rawGet(.{ .number = 828 }).?.table;
    try std.testing.expectEqualStrings("Module", module.rawGet(.{ .string = "canonicalName" }).?.string);
    const aliases = module.rawGet(.{ .string = "aliases" }).?.table;
    try std.testing.expectEqualStrings("MOD", aliases.rawGet(.{ .number = 1 }).?.string);
    const project = namespaces.rawGet(.{ .number = 4 }).?.table;
    try std.testing.expectEqualStrings("Project", project.rawGet(.{ .string = "canonicalName" }).?.string);
}

test "Scribunto installs Unicode string aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), std.testing.io, "modules");
    var vm = try exec.Vm.init(arena.allocator());
    try runtime.install(&vm);
    const string = vm.globals.rawGet(.{ .string = "string" }).?.table;
    inline for (&.{ "isutf8", "byteoffset", "codepoint", "gcodepoint", "toNFC", "toNFD", "uchar", "ulen", "usub", "uupper", "ulower", "ufind", "umatch", "ugmatch", "ugsub" }) |name|
        try std.testing.expect(string.rawGet(.{ .string = name }) != null);
    const lower = try vm.getIndex(.{ .string = "ÄBC" }, .{ .string = "ulower" });
    const out = try vm.callValue(lower, &.{.{ .string = "ÄBC" }});
    defer exec.Vm.freeResults(out);
    try std.testing.expectEqualStrings("äbc", out[0].string);
}

test "MediaWiki case parser functions use Unicode casing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), std.testing.io, "modules");
    runtime.beginPage(arena.allocator(), "Smoke");
    var vm = try exec.Vm.init(arena.allocator());
    try runtime.install(&vm);
    try std.testing.expectEqualStrings("ÄBC", try runtime.expandFragment(&vm, "Smoke", "{{uc:äbc}}"));
    try std.testing.expectEqualStrings("äbc", try runtime.expandFragment(&vm, "Smoke", "{{lc:ÄBC}}"));
    try std.testing.expectEqualStrings("Äbc", try runtime.expandFragment(&vm, "Smoke", "{{ucfirst:äbc}}"));
    try std.testing.expectEqualStrings("äBC", try runtime.expandFragment(&vm, "Smoke", "{{lcfirst:ÄBC}}"));
}

test "MediaWiki full/local/canonical URL parser functions match Wiktionary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), std.testing.io, "modules");
    runtime.beginPage(arena.allocator(), "Smoke");
    var vm = try exec.Vm.init(arena.allocator());
    try runtime.install(&vm);
    const params = try rt.newTable(arena.allocator());
    try std.testing.expectEqualStrings("//en.wiktionary.org/wiki/Template:de-corr", try runtime.expandConstruct(&vm, "fullurl:Template:de-corr", params, "Smoke", 0));
    try std.testing.expectEqualStrings("//en.wiktionary.org/w/index.php?title=A_B&action=edit", try runtime.expandConstruct(&vm, "fullurl:A B|action=edit", params, "Smoke", 0));
    try std.testing.expectEqualStrings("//en.wiktionary.org/w/index.php?title=A_B&amp;action=edit", try runtime.expandConstruct(&vm, "fullurle:A B|action=edit", params, "Smoke", 0));
    try std.testing.expectEqualStrings("/wiki/A_B", try runtime.expandConstruct(&vm, "localurl:A B", params, "Smoke", 0));
    try std.testing.expectEqualStrings("https://en.wiktionary.org/wiki/A_B", try runtime.expandConstruct(&vm, "canonicalurl:A B", params, "Smoke", 0));
    try std.testing.expectEqualStrings("//en.wiktionary.org/wiki/A/B_C#D_E", try runtime.expandConstruct(&vm, "fullurl:A/B C#D E", params, "Smoke", 0));
}

test "mw.uri fullUrl returns a tostring-compatible URI object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), std.testing.io, "modules");
    var vm = try exec.Vm.init(arena.allocator());
    try lib.install(&vm);
    const args = try rt.newTable(arena.allocator());
    try args.rawSet(arena.allocator(), .{ .string = "action" }, .{ .string = "edit" });
    const result = try uriFullUrlCall(&runtime, &vm, &.{ .{ .string = "Example" }, .{ .table = args } }, arena.allocator());
    defer exec.Vm.freeResults(result);
    try std.testing.expect(result[0] == .table);
    const tostring_fn = vm.globals.rawGet(.{ .string = "tostring" }).?;
    const rendered = try vm.callValue(tostring_fn, &.{result[0]});
    defer exec.Vm.freeResults(rendered);
    try std.testing.expectEqualStrings("//en.wiktionary.org/w/index.php?title=Example&action=edit", rendered[0].string);
}

test "title URL methods share MediaWiki URL construction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), std.testing.io, "modules");
    var vm = try exec.Vm.init(arena.allocator());
    const title = try makeTitleValue(&runtime, "A B");
    const full = try vm.getIndex(title, .{ .string = "fullUrl" });
    const query = try rt.newTable(arena.allocator());
    try query.rawSet(arena.allocator(), .{ .string = "action" }, .{ .string = "edit" });
    const result = try vm.callValue(full, &.{ title, .{ .table = query }, .{ .string = "https" } });
    defer exec.Vm.freeResults(result);
    try std.testing.expectEqualStrings("https://en.wiktionary.org/w/index.php?title=A_B&action=edit", result[0].string);
}

test "mw.uri encode and decode follow Scribunto modes" {
    const a = std.testing.allocator;
    const query = try uriEncodeCall(null, undefined, &.{ .{ .string = "a b/c" }, .{ .string = "QUERY" } }, a);
    defer exec.Vm.freeResults(query);
    defer a.free(query[0].string);
    try std.testing.expectEqualStrings("a+b%2Fc", query[0].string);
    const path = try uriEncodeCall(null, undefined, &.{ .{ .string = "a b/c" }, .{ .string = "PATH" } }, a);
    defer exec.Vm.freeResults(path);
    defer a.free(path[0].string);
    try std.testing.expectEqualStrings("a%20b%2Fc", path[0].string);
    const wiki = try uriEncodeCall(null, undefined, &.{ .{ .string = "a b/c" }, .{ .string = "WIKI" } }, a);
    defer exec.Vm.freeResults(wiki);
    defer a.free(wiki[0].string);
    try std.testing.expectEqualStrings("a_b/c", wiki[0].string);
    const decoded = try uriDecodeCall(null, undefined, &.{ .{ .string = "a_b%2Fc%5F" }, .{ .string = "WIKI" } }, a);
    defer exec.Vm.freeResults(decoded);
    defer a.free(decoded[0].string);
    try std.testing.expectEqualStrings("a b/c_", decoded[0].string);
}

test "native simple memoizer preserves special key and nil-output semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var vm = try exec.Vm.init(a);

    const TargetCtx = struct { calls: usize = 0 };
    var target_ctx = TargetCtx{};
    const target = try rt.newNative(a, &target_ctx, struct {
        fn call(raw: ?*anyopaque, _: *anyopaque, args: []const Value, alloc: std.mem.Allocator) ![]const Value {
            const ctx: *TargetCtx = @ptrCast(@alignCast(raw.?));
            ctx.calls += 1;
            if (args.len != 0 and args[0] == .string and std.mem.eql(u8, args[0].string, "nil"))
                return one(alloc, .nil);
            if (args.len > 1) return one(alloc, args[1]);
            return one(alloc, .{ .number = @floatFromInt(ctx.calls) });
        }
    }.call);
    var factory_ctx = MemoizeFactoryCtx{ .original = .nil };
    const factory = try rt.newNative(a, &factory_ctx, memoizeFactoryFastCall);
    const made = try vm.callValue(factory, &.{ target, .{ .boolean = true } });
    defer exec.Vm.freeResults(made);
    const memo = made[0];

    const Case = struct {
        fn call(v: *exec.Vm, f: Value, args: []const Value) !Value {
            const out = try v.callValue(f, args);
            defer exec.Vm.freeResults(out);
            return if (out.len == 0) .nil else out[0];
        }
    };

    try std.testing.expectEqual(@as(f64, 1), (try Case.call(&vm, memo, &.{.nil})).number);
    try std.testing.expectEqual(@as(f64, 1), (try Case.call(&vm, memo, &.{.nil})).number);
    try std.testing.expectEqual(@as(usize, 1), target_ctx.calls);

    const pos_zero: Value = .{ .number = 0.0 };
    const neg_zero: Value = .{ .number = @bitCast(@as(u64, 0x8000000000000000)) };
    try std.testing.expectEqual(@as(f64, 2), (try Case.call(&vm, memo, &.{pos_zero})).number);
    try std.testing.expectEqual(@as(f64, 3), (try Case.call(&vm, memo, &.{neg_zero})).number);
    try std.testing.expectEqual(@as(f64, 2), (try Case.call(&vm, memo, &.{pos_zero})).number);
    try std.testing.expectEqual(@as(f64, 3), (try Case.call(&vm, memo, &.{neg_zero})).number);

    const pos_nan1: Value = .{ .number = @bitCast(@as(u64, 0x7ff8000000000001)) };
    const pos_nan2: Value = .{ .number = @bitCast(@as(u64, 0x7ff8000000000011)) };
    const neg_nan: Value = .{ .number = @bitCast(@as(u64, 0xfff8000000000001)) };
    try std.testing.expectEqual(@as(f64, 4), (try Case.call(&vm, memo, &.{pos_nan1})).number);
    try std.testing.expectEqual(@as(f64, 4), (try Case.call(&vm, memo, &.{pos_nan2})).number);
    try std.testing.expectEqual(@as(f64, 5), (try Case.call(&vm, memo, &.{neg_nan})).number);

    const t1: Value = .{ .table = try rt.newTable(a) };
    const t2: Value = .{ .table = try rt.newTable(a) };
    try std.testing.expectEqual(@as(f64, 6), (try Case.call(&vm, memo, &.{t1})).number);
    try std.testing.expectEqual(@as(f64, 6), (try Case.call(&vm, memo, &.{t1})).number);
    try std.testing.expectEqual(@as(f64, 7), (try Case.call(&vm, memo, &.{t2})).number);

    try std.testing.expect((try Case.call(&vm, memo, &.{.{ .string = "nil" }})) == .nil);
    try std.testing.expect((try Case.call(&vm, memo, &.{.{ .string = "nil" }})) == .nil);
    try std.testing.expectEqual(@as(usize, 8), target_ctx.calls);

    const extra_a = try Case.call(&vm, memo, &.{ .{ .string = "extra" }, .{ .string = "a" } });
    const extra_b = try Case.call(&vm, memo, &.{ .{ .string = "extra" }, .{ .string = "b" } });
    try std.testing.expect(extra_a == .string and std.mem.eql(u8, extra_a.string, "a"));
    try std.testing.expect(extra_b == .string and std.mem.eql(u8, extra_b.string, "a"));
    try std.testing.expectEqual(@as(usize, 9), target_ctx.calls);
}

test "native string char fast path encodes raw Unicode codepoints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var vm = try exec.Vm.init(a);
    var fallback = HotLuaFallbackCtx{ .original = .nil };

    const none = try stringCharFastCall(&fallback, &vm, &.{}, a);
    try std.testing.expectEqual(@as(usize, 0), none.len);

    const out = try stringCharFastCall(&fallback, &vm, &.{
        .{ .number = 0x00 },
        .{ .number = 0x7F },
        .{ .number = 0x80 },
        .{ .number = 0x7FF },
        .{ .number = 0x800 },
        .{ .number = 0xD800 },
        .{ .number = 0x10000 },
        .{ .number = 0x10FFFF },
    }, a);
    defer exec.Vm.freeResults(out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualSlices(u8, &.{
        0x00, 0x7F,
        0xC2, 0x80,
        0xDF, 0xBF,
        0xE0, 0xA0,
        0x80, 0xED,
        0xA0, 0x80,
        0xF0, 0x90,
        0x80, 0x80,
        0xF4, 0x8F,
        0xBF, 0xBF,
    }, out[0].string);
}

test "native shallow copy preserves raw copy and metatable fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var vm = try exec.Vm.init(a);

    const source = try rt.newTable(a);
    try source.rawSet(a, .{ .string = "x" }, .{ .number = 7 });
    const fallback_marker = try rt.newTable(a);
    const FallbackCtx = struct { calls: usize = 0, marker: *rt.Table };
    var fallback_ctx = FallbackCtx{ .marker = fallback_marker };
    const fallback = try rt.newNative(a, &fallback_ctx, struct {
        fn call(raw: ?*anyopaque, _: *anyopaque, _: []const Value, alloc: std.mem.Allocator) ![]const Value {
            const ctx: *FallbackCtx = @ptrCast(@alignCast(raw.?));
            ctx.calls += 1;
            return one(alloc, .{ .table = ctx.marker });
        }
    }.call);
    var ctx = HotLuaFallbackCtx{ .original = fallback };

    const plain = try shallowCopyFastCall(&ctx, &vm, &.{.{ .table = source }}, a);
    defer exec.Vm.freeResults(plain);
    try std.testing.expect(plain[0] == .table and plain[0].table != source);
    try std.testing.expectEqual(@as(f64, 7), plain[0].table.rawGet(.{ .string = "x" }).?.number);
    try std.testing.expectEqual(@as(usize, 0), fallback_ctx.calls);

    const mt = try rt.newTable(a);
    source.metatable = mt;
    const delegated = try shallowCopyFastCall(&ctx, &vm, &.{.{ .table = source }}, a);
    defer exec.Vm.freeResults(delegated);
    try std.testing.expect(delegated[0] == .table and delegated[0].table == fallback_marker);
    try std.testing.expectEqual(@as(usize, 1), fallback_ctx.calls);

    const raw_copy = try shallowCopyFastCall(&ctx, &vm, &.{ .{ .table = source }, .{ .boolean = true } }, a);
    defer exec.Vm.freeResults(raw_copy);
    try std.testing.expect(raw_copy[0] == .table and raw_copy[0].table != source);
    try std.testing.expectEqual(@as(f64, 7), raw_copy[0].table.rawGet(.{ .string = "x" }).?.number);
    try std.testing.expectEqual(@as(usize, 1), fallback_ctx.calls);

    const scalar = try shallowCopyFastCall(&ctx, &vm, &.{.{ .string = "same" }}, a);
    defer exec.Vm.freeResults(scalar);
    try std.testing.expect(scalar[0] == .string and std.mem.eql(u8, scalar[0].string, "same"));
}

test "native Scribunto trim and parameter key match module edge cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var vm = try exec.Vm.init(a);

    const FallbackCtx = struct { calls: usize = 0 };
    var fallback_ctx = FallbackCtx{};
    const fallback = try rt.newNative(a, &fallback_ctx, struct {
        fn call(raw: ?*anyopaque, _: *anyopaque, _: []const Value, alloc: std.mem.Allocator) ![]const Value {
            const ctx: *FallbackCtx = @ptrCast(@alignCast(raw.?));
            ctx.calls += 1;
            return one(alloc, .{ .string = "fallback" });
        }
    }.call);
    var ctx = HotLuaFallbackCtx{ .original = fallback };

    const trimmed = try scribuntoPhpTrimFastCall(&ctx, &vm, &.{.{ .string = " \t\n\x0b\r\x00 hello \x00\r" }}, a);
    defer exec.Vm.freeResults(trimmed);
    try std.testing.expectEqualStrings("hello", trimmed[0].string);
    const empty = try scribuntoPhpTrimFastCall(&ctx, &vm, &.{.{ .string = " \t\n\x0b\r\x00" }}, a);
    defer exec.Vm.freeResults(empty);
    try std.testing.expectEqualStrings("", empty[0].string);

    const Case = struct {
        fn call(v: *exec.Vm, c: *HotLuaFallbackCtx, alloc: std.mem.Allocator, args: []const Value) !Value {
            const out = try scribuntoParameterKeyFastCall(c, v, args, alloc);
            defer exec.Vm.freeResults(out);
            return out[0];
        }
    };
    try std.testing.expectEqual(@as(f64, 1), (try Case.call(&vm, &ctx, a, &.{.{ .string = " 1 " }})).number);
    const raw = try Case.call(&vm, &ctx, a, &.{ .{ .string = " 1 " }, .{ .boolean = true } });
    try std.testing.expect(raw == .string and std.mem.eql(u8, raw.string, " 1 "));
    try std.testing.expectEqual(@as(f64, 0), (try Case.call(&vm, &ctx, a, &.{.{ .string = "0" }})).number);
    const neg_zero = try Case.call(&vm, &ctx, a, &.{.{ .string = "-0" }});
    try std.testing.expect(neg_zero == .string and std.mem.eql(u8, neg_zero.string, "-0"));
    const leading_zero = try Case.call(&vm, &ctx, a, &.{.{ .string = "01" }});
    try std.testing.expect(leading_zero == .string and std.mem.eql(u8, leading_zero.string, "01"));
    try std.testing.expectEqual(@as(f64, 9007199254740992.0), (try Case.call(&vm, &ctx, a, &.{.{ .string = "9007199254740992" }})).number);
    try std.testing.expectEqual(@as(f64, -9007199254740992.0), (try Case.call(&vm, &ctx, a, &.{.{ .string = "-9007199254740992" }})).number);
    const too_large = try Case.call(&vm, &ctx, a, &.{.{ .string = "9007199254740993" }});
    try std.testing.expect(too_large == .string and std.mem.eql(u8, too_large.string, "9007199254740993"));
    const delegated = try Case.call(&vm, &ctx, a, &.{.{ .number = 1.5 }});
    try std.testing.expect(delegated == .string and std.mem.eql(u8, delegated.string, "fallback"));
    try std.testing.expectEqual(@as(usize, 1), fallback_ctx.calls);
}

fn addDiagnosticTestModule(runtime: *Runtime, title: []const u8, source: []const u8) !void {
    const a = runtime.persistent_allocator;
    var chunk = try @import("root.zig").parse(a, source);
    const program = try a.create(ir.Program);
    program.* = try ir.lowerChunk(a, &chunk);
    const slot = try a.create(ModuleSlot);
    slot.* = .{ .page_id = 1, .title = title, .program = program };
    try runtime.modules.put(a, title, slot);
}
test "successful loadData restores caller diagnostics after a caught error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), std.testing.io, "modules");
    try addDiagnosticTestModule(&runtime, "Module:Data", "pcall(function()require('missing'..' ephemeral')end);return {x=7}");
    const outer = "caller diagnostic";
    runtime.last_missing_module = outer;
    const out = try runtime.loadDataByName("Module:Data");
    try std.testing.expectEqual(@as(f64, 7), out.table.rawGet(.{ .string = "x" }).?.number);
    try std.testing.expectEqual(@intFromPtr(outer.ptr), @intFromPtr(runtime.last_missing_module.?.ptr));
}
test "successful invoke restores caller diagnostics after a caught error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), std.testing.io, "modules");
    try addDiagnosticTestModule(&runtime, "Module:Safe", "return {main=function()pcall(function()require('missing'..' ephemeral')end);return 'ok' end}");
    var vm = try exec.Vm.init(arena.allocator());
    try runtime.install(&vm);
    const outer = "caller diagnostic";
    runtime.last_missing_module = outer;
    try std.testing.expectEqualStrings("ok", try runtime.expandFragment(&vm, "Test", "{{#invoke:Safe|main}}"));
    try std.testing.expectEqual(@intFromPtr(outer.ptr), @intFromPtr(runtime.last_missing_module.?.ptr));
}
test "escaping loadData errors promote diagnostic text before arena teardown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), std.testing.io, "modules");
    try addDiagnosticTestModule(&runtime, "Module:BadData", "require('missing'..' transient');return {}");
    runtime.last_missing_module = "caller diagnostic";
    try std.testing.expectError(error.ModuleNotFound, runtime.loadDataByName("Module:BadData"));
    try std.testing.expectEqualStrings("missing transient", runtime.last_missing_module.?);
}
test "escaping invoke errors promote diagnostic text before arena teardown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = Runtime.init(arena.allocator(), std.testing.io, "modules");
    try addDiagnosticTestModule(&runtime, "Module:BadInvoke", "return {main=function()require('missing'..' transient')end}");
    var vm = try exec.Vm.init(arena.allocator());
    try runtime.install(&vm);
    try std.testing.expectError(error.ModuleNotFound, runtime.expandFragment(&vm, "Test", "{{#invoke:BadInvoke|main}}"));
    try std.testing.expectEqualStrings("missing transient", runtime.last_missing_module.?);
}
