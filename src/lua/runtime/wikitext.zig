const std = @import("std");
const rt = @import("zig_runtime");
const host_api = @import("host.zig");
const frame_lib = @import("frame.zig");
const namespace_lib = @import("namespaces.zig");
const preprocess = @import("lua_wikitext_preprocess");
const parser_expr = @import("lua_wikitext_expression");
const language_lib = @import("language.zig");
const dateformat_lib = @import("dateformat.zig");
const uri_lib = @import("uri.zig");
const ustring_lib = @import("ustring.zig");
const text_lib = @import("text.zig");
const stdlib = @import("zig_stdlib");
const Value = rt.Value;

const nowiki_marker_prefix = "\x7f'\"`UNIQ--nowiki-";
const nowiki_marker_suffix = "-QINU`\"'\x7f";

fn makeNowikiMarker(a: std.mem.Allocator, id: u32) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}{X:0>8}{s}", .{ nowiki_marker_prefix, id, nowiki_marker_suffix });
}

fn canonicalExtensionTag(raw: []const u8) ?[]const u8 {
    inline for (&.{
        "nowiki",  "pre",      "gallery",      "indicator",       "ref",             "references", "templatestyles",
        "math",    "ce",       "chem",         "score",           "syntaxhighlight", "source",     "timeline",
        "hiero",   "poem",     "categorytree", "charinsert",      "graph",           "mapframe",   "maplink",
        "section", "inputbox", "imagemap",     "dynamicpagelist",
    }) |name| if (std.ascii.eqlIgnoreCase(raw, name)) return name;
    return null;
}

pub const InstallScribuntoFn = *const fn (
    *?*anyopaque,
    ?*anyopaque,
    std.mem.Allocator,
    *rt.Context,
    u32,
    u32,
    u32,
) anyerror!void;

pub const CallSymbolKind = enum { template, module, function };
pub const CallSymbol = struct {
    id: usize,
    text: []const u8,
    module_id: ?u32 = null,
};

pub const Provider = struct {
    pub const CategoryTreeScope = enum { main, pages };
    pub const ExternalData = host_api.ExternalData;
    pub const CategoryStats = host_api.CategoryStats;
    pub const InterfaceMessage = host_api.InterfaceMessage;
    pub const FileMetadata = host_api.FileMetadata;
    pub const InterwikiRow = host_api.InterwikiRow;
    pub const WikibaseEntityText = host_api.WikibaseEntityText;
    pub const SymbolKind = CallSymbolKind;
    pub const Symbol = CallSymbol;
    pub const PageMetadata = struct {
        page_id: u64,
        revision_id: u64,
        revision_timestamp: []const u8,
        revision_user: []const u8,
        content_model: []const u8,
    };
    pub const TransclusionBody = struct {
        text: []const u8,
        title: []const u8,
        borrowed: bool,
    };
    ctx: ?*anyopaque = null,
    get: *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!?[]const u8,
    get_transclusion: ?*const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!?[]const u8 = null,
    get_transclusion_body: ?*const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!?TransclusionBody = null,
    redirect_target: ?*const fn (?*anyopaque, []const u8) anyerror!?[]const u8 = null,
    page_metadata: ?*const fn (?*anyopaque, []const u8) anyerror!?PageMetadata = null,
    exists: *const fn (?*anyopaque, []const u8) anyerror!bool,
    external_data: ?*const fn (?*anyopaque, []const u8) anyerror!?ExternalData = null,
    category_stats: ?*const fn (?*anyopaque, []const u8) anyerror!?CategoryStats = null,
    interface_message: ?*const fn (?*anyopaque, std.mem.Allocator, []const u8, []const u8) anyerror!?InterfaceMessage = null,
    file_metadata: ?*const fn (?*anyopaque, []const u8) anyerror!FileMetadata = null,
    category_tree: ?*const fn (?*anyopaque, std.mem.Allocator, []const u8, CategoryTreeScope) anyerror![]const []const u8 = null,
    interwiki_map: ?*const fn (?*anyopaque) anyerror![]const InterwikiRow = null,
    wikibase_sitelink: ?*const fn (?*anyopaque, []const u8, []const u8) anyerror!?[]const u8 = null,
    wikibase_entity_text: ?*const fn (?*anyopaque, []const u8) anyerror!WikibaseEntityText = null,
    language_known_tag: ?*const fn (?*anyopaque, []const u8) anyerror!bool = null,
    resolve_call_symbol: ?*const fn (?*anyopaque, *rt.Context, []const u8, CallSymbolKind) anyerror!?CallSymbol = null,
    get_template_symbol: ?*const fn (?*anyopaque, std.mem.Allocator, usize) anyerror!?[]const u8 = null,
};

const LazyTemplateArgs = struct {
    target: *rt.Table,
    raw_values: *rt.Table,
    caller_params: *rt.Table,
    caller_title: []const u8,
    depth: usize,
};

pub const Expander = struct {
    runtime: *rt.Context,
    env_slot: u32,
    string_slot: u32,
    mw_slot: u32,
    provider: Provider,
    install_scribunto: ?InstallScribuntoFn = null,
    scribunto_state: ?*anyopaque = null,
    scribunto_shared: ?*anyopaque = null,
    host: host_api.Host = .{},
    current_source: ?[]const u8 = null,
    page_allocator: ?std.mem.Allocator = null,
    page_heading_count: usize = 0,
    fake_heading_count: usize = 0,
    display_title: ?[]const u8 = null,
    strip_counter: u32 = 0,
    strip_values: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    page_line: std.ArrayList(u8) = .empty,
    max_depth: usize = 512,
    max_template_depth: usize = 128,
    template_depth: usize = 0,
    lazy_template_args: std.ArrayList(LazyTemplateArgs) = .empty,

    pub fn attach(self: *Expander) void {
        self.host.ctx = self;
        self.host.page_exists = hostPageExists;
        self.host.page_content = hostPageContent;
        self.host.page_redirect = hostPageRedirect;
        self.host.page_id = hostPageId;
        self.host.page_content_model = hostPageContentModel;
        self.host.frame_preprocess = hostFramePreprocess;
        self.host.frame_expand_template = hostFrameExpandTemplate;
        self.host.frame_extension_tag = hostFrameExtensionTag;
        self.host.frame_parser_function = hostFrameParserFunction;
        self.host.text_unstrip_no_wiki = hostTextUnstripNoWiki;
        self.host.external_data = hostExternalData;
        self.host.category_stats = hostCategoryStats;
        self.host.interface_message = if (self.provider.interface_message != null) hostInterfaceMessage else null;
        self.host.file_metadata = hostFileMetadata;
        self.host.site_interwiki_map = hostSiteInterwikiMap;
        self.host.wikibase_sitelink = hostWikibaseSitelink;
        self.host.wikibase_entity_text = hostWikibaseEntityText;
        self.host.language_known_tag = hostLanguageKnownTag;
        host_api.set(self.runtime, &self.host);
    }

    pub fn beginPage(self: *Expander, title: []const u8, source: []const u8, now_unix: ?i64) void {
        self.host.current_title = title;
        self.host.now_unix = now_unix;
        self.current_source = source;
        self.page_allocator = self.runtime.allocator;
        self.scribunto_state = null;
        self.page_heading_count = 0;
        self.fake_heading_count = 0;
        self.display_title = null;
        self.strip_counter = 0;
        self.strip_values = .empty;
        self.page_line = .empty;
        self.template_depth = 0;
        self.lazy_template_args = .empty;
        self.attach();
    }

    fn ensureScribunto(self: *Expander) !void {
        if (self.runtime.getGlobal(self.mw_slot) == .table) return;
        const install = self.install_scribunto orelse return error.MissingScribuntoInstaller;
        try install(
            &self.scribunto_state,
            self.scribunto_shared,
            self.runtime.allocator,
            self.runtime,
            self.env_slot,
            self.string_slot,
            self.mw_slot,
        );
    }

    fn recordDisplayTitle(self: *Expander, value: []const u8) ![]const u8 {
        const a = self.page_allocator orelse self.runtime.allocator;
        const previous = self.display_title;
        self.display_title = try a.dupe(u8, value);
        if (previous) |old| if (!std.mem.eql(u8, old, value))
            return "<span class=\"error\"><strong>Warning:</strong> Display title overrides earlier display title.</span>";
        return "";
    }

    fn hostPageContent(raw: ?*anyopaque, a: std.mem.Allocator, title: []const u8) anyerror!?[]const u8 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const canonical = try namespace_lib.canonicalizeTitle(a, title);
        if (std.mem.eql(u8, canonical, self.host.current_title)) if (self.current_source) |source| return source;
        return self.provider.get(self.provider.ctx, a, canonical);
    }

    fn hostPageRedirect(raw: ?*anyopaque, title: []const u8) anyerror!?[]const u8 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const get = self.provider.redirect_target orelse return null;
        const canonical = try namespace_lib.canonicalizeTitle(self.runtime.allocator, title);
        return get(self.provider.ctx, canonical);
    }

    fn hostPageId(raw: ?*anyopaque, title: []const u8) anyerror!?u64 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const get = self.provider.page_metadata orelse return null;
        const canonical = try namespace_lib.canonicalizeTitle(self.runtime.allocator, title);
        const metadata = (try get(self.provider.ctx, canonical)) orelse return null;
        return metadata.page_id;
    }

    fn hostPageContentModel(raw: ?*anyopaque, title: []const u8) anyerror!?[]const u8 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const get = self.provider.page_metadata orelse return null;
        const canonical = try namespace_lib.canonicalizeTitle(self.runtime.allocator, title);
        const metadata = (try get(self.provider.ctx, canonical)) orelse return null;
        return metadata.content_model;
    }

    fn hostExternalData(raw: ?*anyopaque, title: []const u8) anyerror!?host_api.ExternalData {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const get = self.provider.external_data orelse return error.NotImplemented;
        return get(self.provider.ctx, title);
    }

    fn hostCategoryStats(raw: ?*anyopaque, db_key: []const u8) anyerror!?host_api.CategoryStats {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const get = self.provider.category_stats orelse return error.NotImplemented;
        return get(self.provider.ctx, db_key);
    }

    fn hostInterfaceMessage(raw: ?*anyopaque, a: std.mem.Allocator, language: []const u8, key: []const u8) anyerror!?host_api.InterfaceMessage {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const get = self.provider.interface_message orelse return null;
        return get(self.provider.ctx, a, language, key);
    }

    fn hostFileMetadata(raw: ?*anyopaque, title: []const u8) anyerror!host_api.FileMetadata {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const get = self.provider.file_metadata orelse return error.NotImplemented;
        return get(self.provider.ctx, title);
    }

    fn hostSiteInterwikiMap(raw: ?*anyopaque) anyerror![]const host_api.InterwikiRow {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const get = self.provider.interwiki_map orelse return error.NotImplemented;
        return get(self.provider.ctx);
    }

    fn hostWikibaseSitelink(raw: ?*anyopaque, entity_id: []const u8, global_site_id: []const u8) anyerror!?[]const u8 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const get = self.provider.wikibase_sitelink orelse return error.NotImplemented;
        return get(self.provider.ctx, entity_id, global_site_id);
    }

    fn hostWikibaseEntityText(raw: ?*anyopaque, entity_id: []const u8) anyerror!host_api.WikibaseEntityText {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const get = self.provider.wikibase_entity_text orelse return error.NotImplemented;
        return get(self.provider.ctx, entity_id);
    }

    fn hostLanguageKnownTag(raw: ?*anyopaque, code: []const u8) anyerror!bool {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const get = self.provider.language_known_tag orelse return error.NotImplemented;
        return get(self.provider.ctx, code);
    }

    fn hostPageExists(raw: ?*anyopaque, title: []const u8) anyerror!bool {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const canonical = try namespace_lib.canonicalizeTitle(self.runtime.allocator, title);
        if (std.mem.eql(u8, canonical, self.host.current_title) and self.current_source != null) return true;
        if (try self.provider.exists(self.provider.ctx, canonical)) return true;
        if (namespace_lib.ofTitle(canonical).id == 828) {
            _ = self.runtime.resolveModule(canonical) catch return false;
            return true;
        }
        return false;
    }

    pub fn expandFragment(self: *Expander, title: []const u8, source: []const u8, now_unix: ?i64) anyerror![]const u8 {
        self.beginPage(title, source, now_unix);
        const stripped = try preprocess.stripDecodedComments(self.runtime.allocator, source);
        defer self.runtime.allocator.free(stripped);
        const params = try self.runtime.newTable();
        return self.expandPageWikitext(stripped, params, title);
    }

    fn observePageLine(self: *Expander, raw: []const u8) void {
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

    fn observePageOutput(self: *Expander, text: []const u8) !void {
        const a = self.page_allocator orelse return error.MissingPageAllocator;
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, text, start, '\n')) |nl| {
            try self.page_line.appendSlice(a, text[start..nl]);
            self.observePageLine(self.page_line.items);
            self.page_line.items.len = 0;
            start = nl + 1;
        }
        try self.page_line.appendSlice(a, text[start..]);
    }

    fn expandPageWikitext(self: *Expander, text: []const u8, params: *rt.Table, host_title: []const u8) anyerror![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var pos: usize = 0;
        while (preprocess.findNextConstructOutsideLiteralTags(text, pos)) |construct| {
            const literal = text[pos..construct.open];
            try self.observePageOutput(literal);
            try out.appendSlice(self.runtime.allocator, literal);
            const expanded = switch (construct.kind) {
                .parameter => blk: {
                    const value = try self.expandParameter(text[construct.open + 3 .. construct.close], params, host_title, 1);
                    pos = construct.close + 3;
                    break :blk value;
                },
                .template => blk: {
                    const value = try self.expandConstruct(text[construct.open + 2 .. construct.close], params, host_title, 1);
                    pos = construct.close + 2;
                    break :blk value;
                },
            };
            try self.observePageOutput(expanded);
            try out.appendSlice(self.runtime.allocator, expanded);
        }
        const tail = text[pos..];
        try self.observePageOutput(tail);
        try out.appendSlice(self.runtime.allocator, tail);
        return out.toOwnedSlice(self.runtime.allocator);
    }

    fn valueToWikitext(self: *Expander, value: Value) ![]const u8 {
        return switch (value) {
            .nil => "",
            .string => |text| text,
            .number => |number| rt.numberToString(self.runtime.allocator, number),
            .boolean => |boolean| if (boolean) "true" else "false",
            .table, .callable => error.WikitextScalarExpected,
        };
    }

    fn normalizeTransclusionName(self: *Expander, raw: []const u8, host_title: ?[]const u8) ![]const u8 {
        const name = std.mem.trim(u8, raw, " \t\r\n");
        if (name.len == 0) return error.MalformedWikitext;

        if (name[0] == ':') {
            const direct = std.mem.trim(u8, name[1..], " \t\r\n");
            if (direct.len == 0) return error.MalformedWikitext;
            return namespace_lib.canonicalizeTitle(self.runtime.allocator, direct);
        }

        if (name[0] == '/') if (host_title) |base_raw| {
            const base = try namespace_lib.canonicalizeTitle(self.runtime.allocator, base_raw);
            const ns = namespace_lib.ofTitle(base);
            const spec = namespace_lib.byId(ns.id) orelse return error.InvalidNamespace;
            if (spec.has_subpages)
                return std.fmt.allocPrint(self.runtime.allocator, "{s}{s}", .{ base, name });
        };

        if (std.mem.indexOfScalar(u8, name, ':')) |colon| {
            if (namespace_lib.byName(name[0..colon]) != null)
                return namespace_lib.canonicalizeTitle(self.runtime.allocator, name);
        }

        const out = try std.fmt.allocPrint(self.runtime.allocator, "Template:{s}", .{name});
        return namespace_lib.canonicalizeTitle(self.runtime.allocator, out);
    }

    const InterwikiTransclusion = union(enum) {
        normal,
        current_wiki: []const u8,
        literal,
        external,
    };

    fn classifyInterwikiTransclusion(self: *Expander, raw_name: []const u8) anyerror!InterwikiTransclusion {
        const name = std.mem.trim(u8, raw_name, " \t\r\n");
        if (name.len == 0 or name[0] == ':') return .normal;
        const colon = std.mem.indexOfScalar(u8, name, ':') orelse return .normal;
        if (colon == 0) return .normal;
        const prefix = std.mem.trim(u8, name[0..colon], " \t\r\n");
        if (prefix.len == 0 or namespace_lib.byName(prefix) != null) return .normal;
        const get = self.provider.interwiki_map orelse return .normal;
        const rows = try get(self.provider.ctx);
        for (rows) |row| {
            if (!std.ascii.eqlIgnoreCase(row.prefix, prefix)) continue;
            const body = std.mem.trimStart(u8, name[colon + 1 ..], " \t\r\n");
            if (row.is_current_wiki) return .{ .current_wiki = body };
            return if (row.is_transcludable) .external else .literal;
        }
        return .normal;
    }

    fn expandTemplateSource(self: *Expander, title: []const u8, raw: []const u8, args: *rt.Table, depth: usize) anyerror![]const u8 {
        const body = try preprocess.transcludeDecodedAlloc(self.runtime.allocator, raw);
        defer self.runtime.allocator.free(body);
        return self.expandWikitext(body, args, title, depth + 1);
    }

    fn missingTemplateMarkup(self: *Expander, title: []const u8) ![]const u8 {
        // MediaWiki Parser::braceSubstitution renders any valid but unavailable
        // transclusion as a link, including main, User, and other namespaces.
        return std.fmt.allocPrint(self.runtime.allocator, "[[:{s}]]", .{title});
    }

    const MissingTemplate = enum { link, lua_error };

    fn missingTemplateResult(self: *Expander, raw_name: []const u8, title: []const u8, mode: MissingTemplate) ![]const u8 {
        if (mode == .link) return self.missingTemplateMarkup(title);
        // Scribunto expandTemplate differs from wikitext brace substitution:
        // callers must be able to catch a missing template with Lua pcall.
        self.runtime.last_error = .{ .string = try std.fmt.allocPrint(
            self.runtime.allocator,
            "expandTemplate: template \"{s}\" does not exist",
            .{raw_name},
        ) };
        return error.LuaRaised;
    }

    fn expandTemplateByName(self: *Expander, raw_name: []const u8, args: *rt.Table, host_title: ?[]const u8, depth: usize, missing: MissingTemplate) anyerror![]const u8 {
        if (depth > self.max_depth) return error.TemplateDepth;
        if (self.template_depth >= self.max_template_depth) return error.TemplateDepth;
        self.template_depth += 1;
        defer self.template_depth -= 1;
        const title = try self.normalizeTransclusionName(raw_name, host_title);
        if (self.provider.get_transclusion_body) |get| {
            const body = (try get(self.provider.ctx, self.runtime.allocator, title)) orelse
                return self.missingTemplateResult(raw_name, title, missing);
            defer if (!body.borrowed) self.runtime.allocator.free(body.text);
            return self.expandWikitext(body.text, args, body.title, depth + 1);
        }
        const raw = if (self.provider.get_transclusion) |get|
            (try get(self.provider.ctx, self.runtime.allocator, title)) orelse
                return self.missingTemplateResult(raw_name, title, missing)
        else
            (try hostPageContent(self, self.runtime.allocator, title)) orelse
                return self.missingTemplateResult(raw_name, title, missing);
        return self.expandTemplateSource(title, raw, args, depth);
    }

    fn expandTemplateBySymbol(self: *Expander, symbol: CallSymbol, args: *rt.Table, host_title: ?[]const u8, depth: usize) anyerror![]const u8 {
        if (depth > self.max_depth) return error.TemplateDepth;
        if (self.template_depth >= self.max_template_depth) return error.TemplateDepth;
        self.template_depth += 1;
        defer self.template_depth -= 1;
        const title = try self.normalizeTransclusionName(symbol.text, host_title);
        if (self.provider.get_template_symbol == null) if (self.provider.get_transclusion_body) |get| {
            const body = (try get(self.provider.ctx, self.runtime.allocator, title)) orelse return self.missingTemplateMarkup(title);
            defer if (!body.borrowed) self.runtime.allocator.free(body.text);
            return self.expandWikitext(body.text, args, body.title, depth + 1);
        };
        const raw = if (self.provider.get_template_symbol) |get|
            (try get(self.provider.ctx, self.runtime.allocator, symbol.id)) orelse return self.missingTemplateMarkup(title)
        else if (self.provider.get_transclusion) |get|
            (try get(self.provider.ctx, self.runtime.allocator, title)) orelse return self.missingTemplateMarkup(title)
        else
            (try hostPageContent(self, self.runtime.allocator, title)) orelse return self.missingTemplateMarkup(title);
        return self.expandTemplateSource(title, raw, args, depth);
    }

    fn expandWikitext(self: *Expander, text: []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        if (depth > self.max_depth) return error.TemplateDepth;
        var out: std.ArrayList(u8) = .empty;
        var pos: usize = 0;
        while (preprocess.findNextConstructOutsideLiteralTags(text, pos)) |construct| {
            try out.appendSlice(self.runtime.allocator, text[pos..construct.open]);
            switch (construct.kind) {
                .parameter => {
                    const expanded = try self.expandParameter(text[construct.open + 3 .. construct.close], params, host_title, depth + 1);
                    try out.appendSlice(self.runtime.allocator, expanded);
                    pos = construct.close + 3;
                },
                .template => {
                    const expanded = try self.expandConstruct(text[construct.open + 2 .. construct.close], params, host_title, depth + 1);
                    try out.appendSlice(self.runtime.allocator, expanded);
                    pos = construct.close + 2;
                },
            }
        }
        try out.appendSlice(self.runtime.allocator, text[pos..]);
        return out.toOwnedSlice(self.runtime.allocator);
    }

    fn lazyTemplateArgsFor(self: *const Expander, params: *rt.Table) ?LazyTemplateArgs {
        var i = self.lazy_template_args.items.len;
        while (i != 0) {
            i -= 1;
            const lazy = self.lazy_template_args.items[i];
            if (lazy.target == params) return lazy;
        }
        return null;
    }

    fn resolveLazyTemplateArg(self: *Expander, params: *rt.Table, key: Value) anyerror!?[]const u8 {
        const lazy = self.lazyTemplateArgsFor(params) orelse return null;
        const raw = lazy.raw_values.rawGet(key) orelse return null;
        if (raw != .string) return error.StringExpected;
        const expanded = try self.expandWikitext(raw.string, lazy.caller_params, lazy.caller_title, lazy.depth + 1);
        try params.rawSet(self.runtime.allocator, key, .{ .string = expanded });
        return expanded;
    }

    fn materializeLazyTemplateArgs(self: *Expander, params: *rt.Table) anyerror!void {
        const lazy = self.lazyTemplateArgsFor(params) orelse return;
        var it = lazy.raw_values.iterator();
        while (it.next()) |entry| {
            if (params.rawGet(entry.key_ptr.*) != null) continue;
            _ = (try self.resolveLazyTemplateArg(params, entry.key_ptr.*)) orelse return error.MissingTemplateArgument;
        }
    }

    fn expandParameter(self: *Expander, inside: []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const split = preprocess.splitParameter(inside);
        const expanded_key = try self.expandWikitext(split.key, params, host_title, depth + 1);
        const key_text = std.mem.trim(u8, expanded_key, " \t\r\n");
        const key: Value = if (std.fmt.parseInt(i64, key_text, 10)) |number|
            .{ .number = @floatFromInt(number) }
        else |_|
            .{ .string = key_text };
        if (params.rawGet(key)) |value| return self.valueToWikitext(value);
        if (try self.resolveLazyTemplateArg(params, key)) |value| return value;
        if (split.default) |fallback| return self.expandWikitext(fallback, params, host_title, depth + 1);
        return std.fmt.allocPrint(self.runtime.allocator, "{{{{{{{s}}}}}}}", .{inside});
    }

    fn buildTemplateArgs(self: *Expander, raw_args: []const []const u8, caller_params: *rt.Table, host_title: []const u8, depth: usize) anyerror!*rt.Table {
        const out = try self.runtime.newTable();
        if (raw_args.len == 0) return out;
        const raw_values = try self.runtime.newTable();
        var positional: i64 = 1;
        for (raw_args) |raw| {
            if (preprocess.findTopDelimiter(raw, '=')) |eq| {
                const key_expanded = try self.expandWikitext(raw[0..eq], caller_params, host_title, depth + 1);
                const key_text = std.mem.trim(u8, key_expanded, " \t\r\n");
                if (key_text.len == 0) continue;
                const key: Value = if (std.fmt.parseInt(i64, key_text, 10)) |number|
                    .{ .number = @floatFromInt(number) }
                else |_|
                    .{ .string = key_text };
                const value_raw = std.mem.trim(u8, raw[eq + 1 ..], " \t\r\n");
                try raw_values.rawSet(self.runtime.allocator, key, .{ .string = value_raw });
            } else {
                try raw_values.rawSet(
                    self.runtime.allocator,
                    .{ .number = @floatFromInt(positional) },
                    .{ .string = raw },
                );
                positional += 1;
            }
        }
        const page_a = self.page_allocator orelse self.runtime.allocator;
        try self.lazy_template_args.append(page_a, .{
            .target = out,
            .raw_values = raw_values,
            .caller_params = caller_params,
            .caller_title = host_title,
            .depth = depth,
        });
        return out;
    }

    fn buildExpandedArgs(self: *Expander, raw_args: []const []const u8, caller_params: *rt.Table, host_title: []const u8, depth: usize) anyerror!*rt.Table {
        const out = try self.runtime.newTable();
        var positional: i64 = 1;
        for (raw_args) |raw| {
            if (preprocess.findTopDelimiter(raw, '=')) |eq| {
                const key_expanded = try self.expandWikitext(raw[0..eq], caller_params, host_title, depth + 1);
                const key_text = std.mem.trim(u8, key_expanded, " \t\r\n");
                if (key_text.len == 0) continue;
                const key: Value = if (std.fmt.parseInt(i64, key_text, 10)) |number|
                    .{ .number = @floatFromInt(number) }
                else |_|
                    .{ .string = key_text };
                const value_raw = std.mem.trim(u8, raw[eq + 1 ..], " \t\r\n");
                const value = try self.expandWikitext(value_raw, caller_params, host_title, depth + 1);
                try out.rawSet(self.runtime.allocator, key, .{ .string = value });
            } else {
                const value = try self.expandWikitext(raw, caller_params, host_title, depth + 1);
                try out.rawSet(self.runtime.allocator, .{ .number = @floatFromInt(positional) }, .{ .string = value });
                positional += 1;
            }
        }
        return out;
    }

    fn formatMagic(self: *Expander, comptime format: []const u8, args: anytype) !?[]const u8 {
        const text: []const u8 = try std.fmt.allocPrint(self.runtime.allocator, format, args);
        return text;
    }

    fn isEscapedTitleMagicName(raw: []const u8) bool {
        inline for (&.{
            "PAGENAMEE",     "FULLPAGENAMEE",    "NAMESPACEE",       "BASEPAGENAMEE",
            "ROOTPAGENAMEE", "SUBPAGENAMEE",     "SUBJECTSPACEE",    "ARTICLESPACEE",
            "TALKSPACEE",    "SUBJECTPAGENAMEE", "ARTICLEPAGENAMEE", "TALKPAGENAMEE",
        }) |name| if (std.ascii.eqlIgnoreCase(raw, name)) return true;
        return false;
    }

    fn isTitleMagicName(raw: []const u8) bool {
        inline for (&.{
            "PAGENAME",     "FULLPAGENAME", "NAMESPACE",       "NAMESPACENUMBER",
            "BASEPAGENAME", "ROOTPAGENAME", "SUBPAGENAME",     "SUBJECTSPACE",
            "ARTICLESPACE", "TALKSPACE",    "SUBJECTPAGENAME", "ARTICLEPAGENAME",
            "TALKPAGENAME",
        }) |name| if (std.ascii.eqlIgnoreCase(raw, name)) return true;
        return isEscapedTitleMagicName(raw);
    }

    fn namespacedPageAlloc(self: *Expander, spec: namespace_lib.Spec, text: []const u8) ![]const u8 {
        if (spec.id == 0) return text;
        return std.fmt.allocPrint(self.runtime.allocator, "{s}:{s}", .{ spec.name, text });
    }

    fn titleMagic(self: *Expander, raw_name: []const u8, raw_page: ?[]const u8) !?[]const u8 {
        const name = std.mem.trim(u8, raw_name, " \t\r\n");
        if (!isTitleMagicName(name)) return null;
        const escaped = isEscapedTitleMagicName(name);
        const base_name = if (escaped) name[0 .. name.len - 1] else name;
        const requested = if (raw_page) |value| blk: {
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            break :blk if (trimmed.len == 0) self.host.current_title else trimmed;
        } else self.host.current_title;
        const canonical_with_fragment = try namespace_lib.canonicalizeTitle(self.runtime.allocator, requested);
        const page = if (std.mem.indexOfScalar(u8, canonical_with_fragment, '#')) |hash|
            canonical_with_fragment[0..hash]
        else
            canonical_with_fragment;
        const ns = namespace_lib.ofTitle(page);
        const ns_spec = namespace_lib.byId(ns.id) orelse return error.InvalidNamespace;
        if (std.ascii.eqlIgnoreCase(base_name, "NAMESPACENUMBER")) return self.formatMagic("{d}", .{ns.id});
        const value: []const u8 = result: {
            if (std.ascii.eqlIgnoreCase(base_name, "PAGENAME")) break :result ns.text;
            if (std.ascii.eqlIgnoreCase(base_name, "FULLPAGENAME")) break :result page;
            if (std.ascii.eqlIgnoreCase(base_name, "NAMESPACE")) break :result ns.name;
            if (std.ascii.eqlIgnoreCase(base_name, "BASEPAGENAME"))
                break :result if (ns_spec.has_subpages)
                    (if (std.mem.lastIndexOfScalar(u8, ns.text, '/')) |slash| ns.text[0..slash] else ns.text)
                else
                    ns.text;
            if (std.ascii.eqlIgnoreCase(base_name, "ROOTPAGENAME"))
                break :result if (ns_spec.has_subpages)
                    (if (std.mem.indexOfScalar(u8, ns.text, '/')) |slash| ns.text[0..slash] else ns.text)
                else
                    ns.text;
            if (std.ascii.eqlIgnoreCase(base_name, "SUBPAGENAME"))
                break :result if (ns_spec.has_subpages)
                    (if (std.mem.lastIndexOfScalar(u8, ns.text, '/')) |slash| ns.text[slash + 1 ..] else ns.text)
                else
                    ns.text;

            const subject = namespace_lib.subjectSpec(ns.id) orelse break :result "";
            if (std.ascii.eqlIgnoreCase(base_name, "SUBJECTSPACE") or std.ascii.eqlIgnoreCase(base_name, "ARTICLESPACE"))
                break :result subject.name;
            if (std.ascii.eqlIgnoreCase(base_name, "SUBJECTPAGENAME") or std.ascii.eqlIgnoreCase(base_name, "ARTICLEPAGENAME"))
                break :result try self.namespacedPageAlloc(subject, ns.text);
            const talk = namespace_lib.talkSpec(ns.id) orelse break :result "";
            if (std.ascii.eqlIgnoreCase(base_name, "TALKSPACE")) break :result talk.name;
            if (std.ascii.eqlIgnoreCase(base_name, "TALKPAGENAME")) break :result try self.namespacedPageAlloc(talk, ns.text);
            unreachable;
        };
        return if (escaped) @as(?[]const u8, try uri_lib.wikiEncodeAlloc(self.runtime.allocator, value)) else value;
    }

    fn isRevisionMagicName(raw: []const u8) bool {
        return std.ascii.eqlIgnoreCase(raw, "PAGEID") or
            std.ascii.eqlIgnoreCase(raw, "REVISIONID") or
            std.ascii.eqlIgnoreCase(raw, "REVISIONTIMESTAMP") or
            std.ascii.eqlIgnoreCase(raw, "REVISIONYEAR") or
            std.ascii.eqlIgnoreCase(raw, "REVISIONMONTH") or
            std.ascii.eqlIgnoreCase(raw, "REVISIONMONTH1") or
            std.ascii.eqlIgnoreCase(raw, "REVISIONDAY") or
            std.ascii.eqlIgnoreCase(raw, "REVISIONDAY2") or
            std.ascii.eqlIgnoreCase(raw, "REVISIONUSER");
    }

    fn pageMetadataFor(self: *Expander, raw_page: ?[]const u8) !?Provider.PageMetadata {
        const get = self.provider.page_metadata orelse return error.MissingPageMetadata;
        const requested = if (raw_page) |value| blk: {
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            break :blk if (trimmed.len == 0) self.host.current_title else trimmed;
        } else self.host.current_title;
        const canonical_with_fragment = try namespace_lib.canonicalizeTitle(self.runtime.allocator, requested);
        const page = if (std.mem.indexOfScalar(u8, canonical_with_fragment, '#')) |hash|
            canonical_with_fragment[0..hash]
        else
            canonical_with_fragment;
        return get(self.provider.ctx, page);
    }

    fn compactRevisionTimestamp(self: *Expander, raw: []const u8) ![]const u8 {
        if (raw.len != 20 or raw[4] != '-' or raw[7] != '-' or raw[10] != 'T' or raw[13] != ':' or raw[16] != ':' or raw[19] != 'Z') return error.InvalidRevisionTimestamp;
        const out = try self.runtime.allocator.alloc(u8, 14);
        @memcpy(out[0..4], raw[0..4]);
        @memcpy(out[4..6], raw[5..7]);
        @memcpy(out[6..8], raw[8..10]);
        @memcpy(out[8..10], raw[11..13]);
        @memcpy(out[10..12], raw[14..16]);
        @memcpy(out[12..14], raw[17..19]);
        return out;
    }

    fn revisionMagic(self: *Expander, head: []const u8, raw_page: ?[]const u8) !?[]const u8 {
        if (!isRevisionMagicName(head)) return null;
        const metadata = (try self.pageMetadataFor(raw_page)) orelse return "";
        if (std.ascii.eqlIgnoreCase(head, "PAGEID")) return self.formatMagic("{d}", .{metadata.page_id});
        if (std.ascii.eqlIgnoreCase(head, "REVISIONID")) return self.formatMagic("{d}", .{metadata.revision_id});
        if (std.ascii.eqlIgnoreCase(head, "REVISIONUSER")) return metadata.revision_user;
        const ts = metadata.revision_timestamp;
        if (ts.len != 20 or ts[4] != '-' or ts[7] != '-' or ts[10] != 'T' or ts[13] != ':' or ts[16] != ':' or ts[19] != 'Z') return error.InvalidRevisionTimestamp;
        if (std.ascii.eqlIgnoreCase(head, "REVISIONTIMESTAMP")) return @as(?[]const u8, try self.compactRevisionTimestamp(ts));
        if (std.ascii.eqlIgnoreCase(head, "REVISIONYEAR")) return ts[0..4];
        if (std.ascii.eqlIgnoreCase(head, "REVISIONMONTH")) return ts[5..7];
        if (std.ascii.eqlIgnoreCase(head, "REVISIONMONTH1")) {
            const month = try std.fmt.parseInt(u8, ts[5..7], 10);
            return self.formatMagic("{d}", .{month});
        }
        if (std.ascii.eqlIgnoreCase(head, "REVISIONDAY2")) return ts[8..10];
        if (std.ascii.eqlIgnoreCase(head, "REVISIONDAY")) {
            const day = try std.fmt.parseInt(u8, ts[8..10], 10);
            return self.formatMagic("{d}", .{day});
        }
        return null;
    }

    fn magicWord(self: *Expander, raw: []const u8) !?[]const u8 {
        const head = std.mem.trim(u8, raw, " \t\r\n");
        if (try self.titleMagic(head, null)) |value| return value;
        if (try self.revisionMagic(head, null)) |value| return value;
        if (std.mem.eql(u8, head, "!")) return "|";
        if (std.mem.eql(u8, head, "!!")) return "||";
        if (std.mem.eql(u8, head, "=")) return "=";
        if (std.ascii.eqlIgnoreCase(head, "SERVER")) return uri_lib.site_server;
        if (std.ascii.eqlIgnoreCase(head, "SERVERNAME")) return uri_lib.site_server_name;
        if (!std.ascii.startsWithIgnoreCase(head, "CURRENT")) return null;
        const now = self.host.now_unix orelse return error.MissingCurrentTime;
        const civil = language_lib.civilFromUnix(now);
        const months = [_][]const u8{
            "January", "February", "March",     "April",   "May",      "June",
            "July",    "August",   "September", "October", "November", "December",
        };
        if (std.ascii.eqlIgnoreCase(head, "CURRENTYEAR")) return self.formatMagic("{d:0>4}", .{@as(u64, @intCast(civil.year))});
        if (std.ascii.eqlIgnoreCase(head, "CURRENTMONTH")) return self.formatMagic("{d:0>2}", .{civil.month});
        if (std.ascii.eqlIgnoreCase(head, "CURRENTMONTH1")) return self.formatMagic("{d}", .{civil.month});
        if (std.ascii.eqlIgnoreCase(head, "CURRENTMONTHNAME") or std.ascii.eqlIgnoreCase(head, "CURRENTMONTHNAMEGEN")) return months[civil.month - 1];
        if (std.ascii.eqlIgnoreCase(head, "CURRENTMONTHABBREV")) return months[civil.month - 1][0..3];
        if (std.ascii.eqlIgnoreCase(head, "CURRENTDAY")) return self.formatMagic("{d}", .{civil.day});
        if (std.ascii.eqlIgnoreCase(head, "CURRENTDAY2")) return self.formatMagic("{d:0>2}", .{civil.day});
        const weekday = language_lib.weekdaySunday0(now);
        if (std.ascii.eqlIgnoreCase(head, "CURRENTDOW")) return self.formatMagic("{d}", .{weekday});
        if (std.ascii.eqlIgnoreCase(head, "CURRENTDAYNAME")) {
            const names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
            return names[weekday];
        }
        if (std.ascii.eqlIgnoreCase(head, "CURRENTWEEK")) return self.formatMagic("{d:0>2}", .{language_lib.isoWeek(now, civil)});
        const day_seconds = @mod(now, @as(i64, std.time.s_per_day));
        const seconds = if (day_seconds < 0) day_seconds + std.time.s_per_day else day_seconds;
        const hour: u8 = @intCast(@divFloor(seconds, std.time.s_per_hour));
        const minute: u8 = @intCast(@divFloor(@mod(seconds, std.time.s_per_hour), std.time.s_per_min));
        const second: u8 = @intCast(@mod(seconds, std.time.s_per_min));
        if (std.ascii.eqlIgnoreCase(head, "CURRENTTIME")) return self.formatMagic("{d:0>2}:{d:0>2}", .{ hour, minute });
        if (std.ascii.eqlIgnoreCase(head, "CURRENTHOUR")) return self.formatMagic("{d:0>2}", .{hour});
        if (std.ascii.eqlIgnoreCase(head, "CURRENTTIMESTAMP"))
            return self.formatMagic("{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}", .{
                @as(u64, @intCast(civil.year)), civil.month, civil.day, hour, minute, second,
            });
        return null;
    }

    fn unicodeCase(self: *Expander, text: []const u8, upper: bool) anyerror![]const u8 {
        try self.ensureScribunto();
        const mw = self.runtime.getGlobal(self.mw_slot);
        if (mw != .table) return error.MissingMw;
        const ustring = try self.runtime.getIndex(mw, .{ .string = "ustring" });
        if (ustring != .table) return error.MissingUstring;
        const callable = try self.runtime.getIndex(ustring, .{ .string = if (upper) "upper" else "lower" });
        const result = try self.runtime.callValue(callable, &.{.{ .string = text }});
        defer rt.freeResults(result);
        if (result.len == 0 or result[0] != .string) return error.StringExpected;
        return result[0].string;
    }

    fn contentLanguageFirstCase(self: *Expander, text: []const u8, upper: bool) anyerror![]const u8 {
        try self.ensureScribunto();
        const mw = self.runtime.getGlobal(self.mw_slot);
        if (mw != .table) return error.MissingMw;
        const get_language = try self.runtime.getIndex(mw, .{ .string = "getContentLanguage" });
        const language_result = try self.runtime.callValue(get_language, &.{});
        defer rt.freeResults(language_result);
        if (language_result.len == 0 or language_result[0] != .table) return error.TableExpected;
        const language = language_result[0];
        const callable = try self.runtime.getIndex(language, .{ .string = if (upper) "ucfirst" else "lcfirst" });
        const result = try self.runtime.callValue(callable, &.{ language, .{ .string = text } });
        defer rt.freeResults(result);
        if (result.len == 0 or result[0] != .string) return error.StringExpected;
        return result[0].string;
    }

    fn expandCaseParser(self: *Expander, raw: []const u8, params: *rt.Table, host_title: []const u8, depth: usize, upper: bool, first_only: bool) anyerror![]const u8 {
        const expanded = try self.expandWikitext(raw, params, host_title, depth + 1);
        return if (first_only) self.contentLanguageFirstCase(expanded, upper) else self.unicodeCase(expanded, upper);
    }

    fn numericStringEqual(lhs: []const u8, rhs: []const u8) bool {
        if (std.fmt.parseInt(i128, lhs, 10)) |left| {
            if (std.fmt.parseInt(i128, rhs, 10)) |right| return left == right else |_| {}
        } else |_| {}
        const left = std.fmt.parseFloat(f64, lhs) catch return false;
        const right = std.fmt.parseFloat(f64, rhs) catch return false;
        if (!std.math.isFinite(left) or !std.math.isFinite(right)) return false;
        return left == right;
    }

    fn ifEqEqual(lhs: []const u8, rhs: []const u8) bool {
        return std.mem.eql(u8, lhs, rhs) or numericStringEqual(lhs, rhs);
    }

    fn expandTrimmedParserArgument(self: *Expander, raw: []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        return std.mem.trim(u8, try self.expandWikitext(raw, params, host_title, depth + 1), " \t\r\n");
    }

    fn expandIfEq(self: *Expander, lhs_raw: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const lhs = std.mem.trim(u8, try self.expandWikitext(lhs_raw, params, host_title, depth + 1), " \t\r\n");
        const rhs = if (args.len != 0) std.mem.trim(u8, try self.expandWikitext(args[0], params, host_title, depth + 1), " \t\r\n") else "";
        const chosen = if (ifEqEqual(lhs, rhs))
            (if (args.len > 1) args[1] else "")
        else
            (if (args.len > 2) args[2] else "");
        return self.expandTrimmedParserArgument(chosen, params, host_title, depth + 1);
    }

    fn expandPlural(self: *Expander, number_raw: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const expanded_number = std.mem.trim(u8, try self.expandWikitext(number_raw, params, host_title, depth + 1), " \t\r\n");
        const number = try language_lib.parseFormattedNumberAlloc(self.runtime.allocator, expanded_number);

        var forms: std.ArrayList([]const u8) = .empty;
        defer forms.deinit(self.runtime.allocator);
        for (args) |raw_form| {
            if (preprocess.findTopDelimiter(raw_form, '=')) |eq| {
                const label_expanded = std.mem.trim(
                    u8,
                    try self.expandWikitext(raw_form[0..eq], params, host_title, depth + 1),
                    " \t\r\n",
                );
                const label = try language_lib.parseFormattedNumberAlloc(self.runtime.allocator, label_expanded);
                if (std.fmt.parseFloat(f64, label)) |_| {
                    if (numericStringEqual(number, label))
                        return self.expandTrimmedParserArgument(raw_form[eq + 1 ..], params, host_title, depth + 1);
                    continue;
                } else |_| {}
            }
            try forms.append(self.runtime.allocator, raw_form);
        }

        if (forms.items.len == 0) return "";
        if (forms.items.len == 1)
            return self.expandTrimmedParserArgument(forms.items[0], params, host_title, depth + 1);

        const parsed = std.fmt.parseFloat(f64, number) catch 0;
        const singular = std.math.isFinite(parsed) and @abs(parsed) == 1;
        return self.expandTrimmedParserArgument(forms.items[if (singular) 0 else 1], params, host_title, depth + 1);
    }

    fn expandSwitch(self: *Expander, key_raw: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const key = std.mem.trim(u8, try self.expandWikitext(key_raw, params, host_title, depth + 1), " \t\r\n");
        var pending = false;
        var fallback: ?[]const u8 = null;
        var trailing: ?[]const u8 = null;
        for (args, 0..) |raw_case, index| {
            if (preprocess.findTopDelimiter(raw_case, '=')) |eq| {
                const label_raw = std.mem.trim(u8, raw_case[0..eq], " \t\r\n");
                const value_raw = raw_case[eq + 1 ..];
                if (std.ascii.eqlIgnoreCase(label_raw, "#default")) {
                    fallback = value_raw;
                    if (pending) return self.expandTrimmedParserArgument(value_raw, params, host_title, depth + 1);
                    continue;
                }
                const label = std.mem.trim(u8, try self.expandWikitext(label_raw, params, host_title, depth + 1), " \t\r\n");
                if (pending or std.mem.eql(u8, key, label)) return self.expandTrimmedParserArgument(value_raw, params, host_title, depth + 1);
                pending = false;
            } else {
                if (index + 1 == args.len) {
                    trailing = raw_case;
                    continue;
                }
                const label = std.mem.trim(u8, try self.expandWikitext(raw_case, params, host_title, depth + 1), " \t\r\n");
                if (std.mem.eql(u8, key, label)) pending = true;
            }
        }
        if (fallback) |value| return self.expandTrimmedParserArgument(value, params, host_title, depth + 1);
        if (trailing) |value| return self.expandTrimmedParserArgument(value, params, host_title, depth + 1);
        return "";
    }

    fn expandIfExist(self: *Expander, raw_title: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        var title = std.mem.trim(u8, try self.expandWikitext(raw_title, params, host_title, depth + 1), " \t\r\n");
        if (title.len != 0 and title[0] == ':') title = std.mem.trim(u8, title[1..], " \t\r\n");
        if (std.mem.indexOfScalar(u8, title, '#')) |hash| title = title[0..hash];
        const exists = title.len != 0 and try hostPageExists(self, title);
        const chosen = if (exists) (if (args.len > 0) args[0] else "") else (if (args.len > 1) args[1] else "");
        return self.expandTrimmedParserArgument(chosen, params, host_title, depth + 1);
    }

    fn parserError(self: *Expander, label: []const u8, err: anyerror) ![]const u8 {
        return std.fmt.allocPrint(self.runtime.allocator, "<strong class=\"error\">{s}: {s}</strong>", .{ label, @errorName(err) });
    }

    fn exprError(self: *Expander, err: anyerror) ![]const u8 {
        return self.parserError("Expression error", err);
    }

    fn utf8Count(source: []const u8) !usize {
        var pos: usize = 0;
        var count: usize = 0;
        while (pos < source.len) : (count += 1) {
            const n = std.unicode.utf8ByteSequenceLength(source[pos]) catch return error.InvalidUtf8;
            if (pos + n > source.len) return error.InvalidUtf8;
            _ = std.unicode.utf8Decode(source[pos .. pos + n]) catch return error.InvalidUtf8;
            pos += n;
        }
        return count;
    }

    fn utf8Offset(source: []const u8, target: usize) !usize {
        var pos: usize = 0;
        var index: usize = 0;
        while (index < target and pos < source.len) : (index += 1) {
            const n = std.unicode.utf8ByteSequenceLength(source[pos]) catch return error.InvalidUtf8;
            if (pos + n > source.len) return error.InvalidUtf8;
            _ = std.unicode.utf8Decode(source[pos .. pos + n]) catch return error.InvalidUtf8;
            pos += n;
        }
        return pos;
    }

    fn expandFormatDate(self: *Expander, raw_date: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const date = try self.expandWikitext(raw_date, params, host_title, depth + 1);
        const style: ?[]const u8 = if (args.len == 0)
            null
        else
            try self.expandWikitext(args[0], params, host_title, depth + 1);
        if (args.len > 1) {
            for (args[1..]) |extra|
                _ = try self.expandWikitext(extra, params, host_title, depth + 1);
        }
        return self.formattedDateSpan(date, style);
    }

    fn expandTimeParser(self: *Expander, raw_format: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const format = try self.expandWikitext(raw_format, params, host_title, depth + 1);
        const timestamp_text: ?[]const u8 = if (args.len == 0)
            null
        else
            try self.expandWikitext(args[0], params, host_title, depth + 1);
        if (args.len > 1) {
            const option = std.mem.trim(u8, try self.expandWikitext(args[1], params, host_title, depth + 1), " \t\r\n");
            if (option.len != 0) return error.UnsupportedTimeOption;
        }
        const timestamp = language_lib.parseTimestampText(self.runtime, timestamp_text) catch |err|
            return self.parserError("Time error", err);
        return language_lib.formatDateAlloc(self.runtime.allocator, timestamp, format) catch |err|
            return self.parserError("Time error", err);
    }

    fn expandLenParser(self: *Expander, raw_source: []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const expanded = try self.expandWikitext(raw_source, params, host_title, depth + 1);
        const source = try text_lib.killMarkersAlloc(self.runtime.allocator, expanded);
        const count = try utf8Count(source);
        return std.fmt.allocPrint(self.runtime.allocator, "{d}", .{count});
    }

    fn expandSubParser(self: *Expander, raw_source: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const source = try self.expandWikitext(raw_source, params, host_title, depth + 1);
        const total: i64 = @intCast(try utf8Count(source));
        const start_raw: i64 = if (args.len == 0)
            0
        else blk: {
            const text = std.mem.trim(u8, try self.expandWikitext(args[0], params, host_title, depth + 1), " \t\r\n");
            break :blk std.fmt.parseInt(i64, text, 10) catch return error.InvalidStringIndex;
        };
        var start: i64 = if (start_raw < 0)
            (if (start_raw < -total) 0 else total + start_raw)
        else
            @min(start_raw, total);
        start = @max(@as(i64, 0), start);
        var end = total;
        if (args.len > 1) {
            const text = std.mem.trim(u8, try self.expandWikitext(args[1], params, host_title, depth + 1), " \t\r\n");
            const length = std.fmt.parseInt(i64, text, 10) catch return error.InvalidStringLength;
            if (length >= 0)
                end = @min(total, std.math.add(i64, start, length) catch total)
            else
                end = if (length < -total) 0 else total + length;
        }
        end = std.math.clamp(end, 0, total);
        if (end <= start) return "";
        const begin_byte = try utf8Offset(source, @intCast(start));
        const end_byte = try utf8Offset(source, @intCast(end));
        return source[begin_byte..end_byte];
    }

    fn expandIfError(self: *Expander, raw_test: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const tested = std.mem.trim(u8, try self.expandWikitext(raw_test, params, host_title, depth + 1), " \t\r\n");
        const failed = std.mem.indexOf(u8, tested, "class=\"error\"") != null;
        if (failed)
            return self.expandTrimmedParserArgument(if (args.len > 0) args[0] else "", params, host_title, depth + 1);
        if (args.len > 1) return self.expandTrimmedParserArgument(args[1], params, host_title, depth + 1);
        return tested;
    }

    fn expandFormatNum(self: *Expander, raw_value: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const value = std.mem.trim(u8, try self.expandWikitext(raw_value, params, host_title, depth + 1), " \t\r\n");
        const option = if (args.len == 0)
            ""
        else
            std.mem.trim(u8, try self.expandWikitext(args[0], params, host_title, depth + 1), " \t\r\n");
        if (args.len > 1) return error.UnsupportedFormatNumOption;
        if (option.len == 0) return language_lib.formatNumberAlloc(self.runtime.allocator, value);
        if (std.ascii.eqlIgnoreCase(option, "R")) return language_lib.parseFormattedNumberAlloc(self.runtime.allocator, value);
        if (std.ascii.eqlIgnoreCase(option, "NOSEP")) return language_lib.formatNumberNoSeparatorsAlloc(self.runtime.allocator, value);
        return error.UnsupportedFormatNumOption;
    }

    fn expandAnchorEncode(self: *Expander, raw_value: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        if (args.len != 0) return error.UnsupportedAnchorEncodeArgument;
        const value = try self.expandWikitext(raw_value, params, host_title, depth + 1);
        return uri_lib.anchorEncodeAlloc(self.runtime.allocator, value);
    }

    fn expandTitleParts(self: *Expander, raw_title: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        if (args.len > 2) return error.UnsupportedTitlePartsArgument;
        const title = try self.expandWikitext(raw_title, params, host_title, depth + 1);
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(self.runtime.allocator);
        var it = std.mem.splitScalar(u8, title, '/');
        while (it.next()) |part| try parts.append(self.runtime.allocator, part);

        const count: i64 = if (args.len == 0) 0 else blk: {
            const text = std.mem.trim(u8, try self.expandWikitext(args[0], params, host_title, depth + 1), " \t\r\n");
            break :blk if (text.len == 0) 0 else std.fmt.parseInt(i64, text, 10) catch return error.InvalidTitlePartsCount;
        };
        const first: i64 = if (args.len < 2) 1 else blk: {
            const text = std.mem.trim(u8, try self.expandWikitext(args[1], params, host_title, depth + 1), " \t\r\n");
            break :blk if (text.len == 0) 1 else std.fmt.parseInt(i64, text, 10) catch return error.InvalidTitlePartsOffset;
        };
        const total: i64 = @intCast(parts.items.len);
        const start = if (first > 0) first - 1 else if (first < 0) total + first else 0;
        if (start < 0 or start >= total) return "";
        const end = if (count > 0)
            @min(total, std.math.add(i64, start, count) catch total)
        else if (count < 0)
            @max(start, total + count)
        else
            total;
        if (end <= start) return "";
        return std.mem.join(self.runtime.allocator, "/", parts.items[@intCast(start)..@intCast(end)]);
    }

    fn expandExprParser(self: *Expander, raw: []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const expanded = std.mem.trim(u8, try self.expandWikitext(raw, params, host_title, depth + 1), " \t\r\n");
        if (expanded.len == 0) return "";
        const value = parser_expr.eval(self.runtime.allocator, expanded) catch |err| return self.exprError(err);
        return parser_expr.format(self.runtime.allocator, value) catch |err| return self.exprError(err);
    }

    fn expandIfExpr(self: *Expander, raw: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const expanded = std.mem.trim(u8, try self.expandWikitext(raw, params, host_title, depth + 1), " \t\r\n");
        if (expanded.len == 0)
            return self.expandTrimmedParserArgument(if (args.len > 1) args[1] else "", params, host_title, depth + 1);
        const value = parser_expr.eval(self.runtime.allocator, expanded) catch |err| return self.exprError(err);
        const chosen = if (value != 0) (if (args.len > 0) args[0] else "") else (if (args.len > 1) args[1] else "");
        return self.expandTrimmedParserArgument(chosen, params, host_title, depth + 1);
    }

    fn appendRepeatedPad(out: *std.ArrayList(u8), a: std.mem.Allocator, pad: []const u8, count: usize) !void {
        if (count == 0 or pad.len == 0) return;
        var remaining = count;
        while (remaining != 0) {
            var index: usize = 0;
            while (index < pad.len and remaining != 0) : (remaining -= 1) {
                const len = std.unicode.utf8ByteSequenceLength(pad[index]) catch return error.InvalidUtf8;
                if (index + len > pad.len) return error.InvalidUtf8;
                try out.appendSlice(a, pad[index .. index + len]);
                index += len;
            }
        }
    }

    fn expandPadParser(self: *Expander, raw: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize, left: bool) anyerror![]const u8 {
        const source = try self.expandWikitext(raw, params, host_title, depth + 1);
        const target_raw = if (args.len != 0)
            std.mem.trim(u8, try self.expandWikitext(args[0], params, host_title, depth + 1), " \t\r\n")
        else
            "0";
        const target = std.fmt.parseInt(usize, target_raw, 10) catch return source;
        const source_len = std.unicode.utf8CountCodepoints(source) catch return error.InvalidUtf8;
        if (target <= source_len) return source;
        const pad = if (args.len > 1) try self.expandWikitext(args[1], params, host_title, depth + 1) else "0";
        if (pad.len == 0) return source;
        _ = std.unicode.utf8CountCodepoints(pad) catch return error.InvalidUtf8;
        const need = target - source_len;
        var out: std.ArrayList(u8) = .empty;
        if (left) {
            try appendRepeatedPad(&out, self.runtime.allocator, pad, need);
            try out.appendSlice(self.runtime.allocator, source);
        } else {
            try out.appendSlice(self.runtime.allocator, source);
            try appendRepeatedPad(&out, self.runtime.allocator, pad, need);
        }
        return out.toOwnedSlice(self.runtime.allocator);
    }

    fn expandUrlParser(self: *Expander, raw: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize, kind: uri_lib.WikiUrlKind, escaped: bool) anyerror![]const u8 {
        const title = std.mem.trim(u8, try self.expandWikitext(raw, params, host_title, depth + 1), " \t\r\n");
        const query: ?[]const u8 = if (args.len == 0) null else try self.expandWikitext(args[0], params, host_title, depth + 1);
        return uri_lib.buildWikiUrlRawQuery(self.runtime.allocator, title, query, kind, escaped, null);
    }

    fn expandUrlencodeParser(self: *Expander, raw: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const source = try self.expandWikitext(raw, params, host_title, depth + 1);
        try self.ensureScribunto();
        const mw = self.runtime.getGlobal(self.mw_slot);
        const uri = try self.runtime.getIndex(mw, .{ .string = "uri" });
        const encode = try self.runtime.getIndex(uri, .{ .string = "encode" });
        var call_args: [2]Value = undefined;
        call_args[0] = .{ .string = source };
        var count: usize = 1;
        if (args.len != 0) {
            const mode = std.mem.trim(u8, try self.expandWikitext(args[0], params, host_title, depth + 1), " \t\r\n");
            if (std.ascii.eqlIgnoreCase(mode, "PATH") or std.ascii.eqlIgnoreCase(mode, "WIKI")) {
                call_args[1] = .{ .string = mode };
                count = 2;
            } else if (std.ascii.eqlIgnoreCase(mode, "QUERY") or std.ascii.eqlIgnoreCase(mode, "PARAM")) {
                call_args[1] = .{ .string = "QUERY" };
                count = 2;
            }
            // MediaWiki's urlencode parser function treats empty and unknown
            // modes as QUERY; Scribunto mw.uri.encode rejects unknown modes.
        }
        const result = try self.runtime.callValue(encode, call_args[0..count]);
        defer rt.freeResults(result);
        if (result.len == 0 or result[0] != .string) return error.StringExpected;
        return result[0].string;
    }

    fn copyArgsTable(runtime: *rt.Context, source: *rt.Table) !*rt.Table {
        const out = try runtime.newTable();
        var it = source.iterator();
        while (it.next()) |entry| try out.rawSet(runtime.allocator, entry.key_ptr.*, entry.value_ptr.*);
        return out;
    }

    fn callSymbol(self: *Expander, raw: []const u8, kind: CallSymbolKind) anyerror!?CallSymbol {
        const resolve = self.provider.resolve_call_symbol orelse return null;
        return resolve(self.provider.ctx, self.runtime, raw, kind);
    }

    const InvokeOutcome = union(enum) {
        generated: []const u8,
        error_markup: []const u8,
    };

    fn clearInvokeFailure(runtime: *rt.Context) void {
        runtime.last_error = .nil;
        runtime.clearAotErrorName();
    }

    fn invokeFailureDetail(runtime: *const rt.Context, err: anyerror) []const u8 {
        if (runtime.last_error == .string) return runtime.last_error.string;
        return runtime.aotErrorName() orelse @errorName(err);
    }

    fn isInvalidTitleInvokeFailure(detail: []const u8) bool {
        return std.mem.indexOf(u8, detail, "Invalid page title") != null;
    }

    fn repairEscapedAnglesAlloc(a: std.mem.Allocator, raw: []const u8) !?[]const u8 {
        if (std.mem.indexOf(u8, raw, "&lt;") == null or std.mem.indexOf(u8, raw, "&gt;") == null)
            return null;
        var out: std.ArrayList(u8) = .empty;
        var pos: usize = 0;
        while (pos < raw.len) {
            if (std.mem.startsWith(u8, raw[pos..], "&lt;")) {
                try out.append(a, '<');
                pos += 4;
            } else if (std.mem.startsWith(u8, raw[pos..], "&gt;")) {
                try out.append(a, '>');
                pos += 4;
            } else {
                try out.append(a, raw[pos]);
                pos += 1;
            }
        }
        return @as(?[]const u8, try out.toOwnedSlice(a));
    }

    fn repairedInvokeArgs(self: *Expander, args: *rt.Table) !?*rt.Table {
        var changed = false;
        const repaired = try self.runtime.newTable();
        var it = args.iterator();
        while (it.next()) |entry| {
            var value = entry.value_ptr.*;
            if (value == .string) if (try repairEscapedAnglesAlloc(self.runtime.allocator, value.string)) |text| {
                value = .{ .string = text };
                changed = true;
            };
            try repaired.rawSet(self.runtime.allocator, entry.key_ptr.*, value);
        }
        return if (changed) repaired else null;
    }

    fn appendHtmlTextEscaped(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
        for (text) |byte| switch (byte) {
            '&' => try out.appendSlice(a, "&amp;"),
            '<' => try out.appendSlice(a, "&lt;"),
            '>' => try out.appendSlice(a, "&gt;"),
            else => try out.append(a, byte),
        };
    }

    fn scribuntoErrorMarkup(self: *Expander, module_name: []const u8, detail: []const u8) ![]const u8 {
        const a = self.runtime.allocator;
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, "<strong class=\"error\"><span class=\"scribunto-error\">Lua error in ");
        try appendHtmlTextEscaped(&out, a, module_name);
        try out.appendSlice(a, ": ");
        try appendHtmlTextEscaped(&out, a, detail);
        try out.appendSlice(a, "</span></strong>");
        return out.toOwnedSlice(a);
    }

    fn invokeWithRecovery(
        self: *Expander,
        module_id: ?u32,
        module_name: []const u8,
        function_name: []const u8,
        invoke_args: *rt.Table,
        existing_parent: ?Value,
        parent_title: ?[]const u8,
        parent_args: ?*rt.Table,
    ) anyerror!InvokeOutcome {
        const generated = self.invokeFresh(module_id, module_name, function_name, invoke_args, existing_parent, parent_title, parent_args) catch |err| {
            if (err != error.AotCallFailed) return err;
            const first_detail = try self.runtime.allocator.dupe(u8, invokeFailureDetail(self.runtime, err));
            clearInvokeFailure(self.runtime);
            if (isInvalidTitleInvokeFailure(first_detail)) {
                const repaired_invoke_args = try self.repairedInvokeArgs(invoke_args);
                const repaired_parent_args: ?*rt.Table = if (parent_args) |source|
                    try self.repairedInvokeArgs(source)
                else
                    null;
                if (repaired_invoke_args != null or repaired_parent_args != null) {
                    const retry_invoke_args = repaired_invoke_args orelse invoke_args;
                    var retry_parent_args = parent_args;
                    if (repaired_parent_args) |table| retry_parent_args = table;
                    const retried = self.invokeFresh(module_id, module_name, function_name, retry_invoke_args, existing_parent, parent_title, retry_parent_args) catch |retry_err| {
                        if (retry_err != error.AotCallFailed) return retry_err;
                        const retry_detail = try self.runtime.allocator.dupe(u8, invokeFailureDetail(self.runtime, retry_err));
                        clearInvokeFailure(self.runtime);
                        return .{ .error_markup = try self.scribuntoErrorMarkup(module_name, retry_detail) };
                    };
                    return .{ .generated = retried };
                }
            }
            return .{ .error_markup = try self.scribuntoErrorMarkup(module_name, first_detail) };
        };
        return .{ .generated = generated };
    }

    fn invokeFresh(
        self: *Expander,
        module_id: ?u32,
        module_name: []const u8,
        function_name: []const u8,
        invoke_args: *rt.Table,
        existing_parent: ?Value,
        parent_title: ?[]const u8,
        parent_args: ?*rt.Table,
    ) anyerror![]const u8 {
        const install = self.install_scribunto orelse return error.MissingScribuntoInstaller;
        const page_a = self.page_allocator orelse self.runtime.allocator;
        const outer_runtime = self.runtime;

        var invoke_arena = std.heap.ArenaAllocator.init(page_a);
        defer invoke_arena.deinit();
        var child = try outer_runtime.forkProgram(invoke_arena.allocator());
        defer child.deinit();
        const global_shape = if (outer_runtime.global_table) |global| global.shape else null;
        try rt.bindGlobalTable(&child, global_shape, self.env_slot);
        if (!try child.bootstrapProgram()) try stdlib.install(&child);
        try install(&self.scribunto_state, self.scribunto_shared, page_a, &child, self.env_slot, self.string_slot, self.mw_slot);

        const saved_runtime = self.runtime;
        self.runtime = &child;
        defer self.runtime = saved_runtime;

        const copied_invoke_args = try copyArgsTable(&child, invoke_args);
        const parent: ?Value = if (existing_parent) |frame|
            frame
        else if (parent_title) |title| blk: {
            const source_args = parent_args orelse return error.MissingInvokeParentArgs;
            const copied_parent_args = try copyArgsTable(&child, source_args);
            break :blk try frame_lib.makeFrameFromTable(&child, title, copied_parent_args, null);
        } else null;
        const frame = try frame_lib.makeFrameFromTable(&child, module_name, copied_invoke_args, parent);
        const result = if (module_id) |id|
            frame_lib.invokeModuleId(&child, id, module_name, function_name, frame) catch |err| {
                try outer_runtime.adoptFailure(&child);
                return err;
            }
        else
            frame_lib.invoke(&child, module_name, function_name, frame) catch |err| {
                try outer_runtime.adoptFailure(&child);
                return err;
            };
        defer rt.freeResults(result);
        const text = if (result.len == 0) "" else try self.valueToWikitext(result[0]);
        return page_a.dupe(u8, text);
    }

    fn expandInvoke(self: *Expander, module_expr: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const module_symbol = try self.callSymbol(module_expr, .module);
        const module_raw = if (module_symbol) |symbol|
            symbol.text
        else
            try self.expandWikitext(module_expr, params, host_title, depth + 1);
        const module_trimmed = std.mem.trim(u8, module_raw, " \t\r\n");
        var module_buffer: [4096]u8 = undefined;
        const module_name = if (module_trimmed.len >= 7 and std.ascii.eqlIgnoreCase(module_trimmed[0..7], "Module:"))
            module_trimmed
        else
            std.fmt.bufPrint(&module_buffer, "Module:{s}", .{module_trimmed}) catch return error.ModuleNameTooLong;
        const function_symbol = if (args.len != 0) try self.callSymbol(args[0], .function) else null;
        const function_name = if (function_symbol) |symbol|
            symbol.text
        else if (args.len != 0)
            std.mem.trim(u8, try self.expandWikitext(args[0], params, host_title, depth + 1), " \t\r\n")
        else
            "main";

        const runtime = self.runtime;
        const invoke_args = try self.buildExpandedArgs(if (args.len > 0) args[1..] else &.{}, params, host_title, depth + 1);
        try self.materializeLazyTemplateArgs(params);
        _ = runtime;
        const outcome = try self.invokeWithRecovery(
            if (module_symbol) |symbol| symbol.module_id else null,
            module_name,
            function_name,
            invoke_args,
            null,
            host_title,
            params,
        );
        return switch (outcome) {
            .generated => |generated| self.expandWikitext(generated, params, host_title, depth + 1),
            .error_markup => |markup| markup,
        };
    }

    fn expandTagParser(self: *Expander, raw_tag: []const u8, raw_args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const tag = std.mem.trim(u8, try self.expandWikitext(raw_tag, params, host_title, depth + 1), " \t\r\n");
        const canonical = canonicalExtensionTag(tag) orelse return error.UnsupportedExtensionTag;
        const content: ?Value = if (raw_args.len == 0)
            .{ .string = "" }
        else
            .{ .string = try self.expandWikitext(raw_args[0], params, host_title, depth + 1) };
        var attrs: ?*rt.Table = null;
        if (raw_args.len > 1) {
            const table = try self.runtime.newTable();
            for (raw_args[1..]) |raw| {
                const eq = preprocess.findTopDelimiter(raw, '=') orelse continue;
                const key = std.mem.trim(u8, try self.expandWikitext(raw[0..eq], params, host_title, depth + 1), " \t\r\n");
                if (key.len == 0) continue;
                const value = try self.expandWikitext(raw[eq + 1 ..], params, host_title, depth + 1);
                try table.rawSet(self.runtime.allocator, .{ .string = key }, .{ .string = value });
            }
            attrs = table;
        }
        return self.serializeExtension(canonical, content, attrs);
    }

    fn expandParserHead(
        self: *Expander,
        head: []const u8,
        raw_args: []const []const u8,
        params: *rt.Table,
        host_title: []const u8,
        depth: usize,
    ) anyerror!?[]const u8 {
        if (try self.magicWord(head)) |value| return value;

        if (preprocess.findTopDelimiter(head, ':')) |colon| {
            const name = std.mem.trim(u8, head[0..colon], " \t\r\n");
            const first = head[colon + 1 ..];
            if (isRevisionMagicName(name)) {
                const page = try self.expandWikitext(first, params, host_title, depth + 1);
                return (try self.revisionMagic(name, page)) orelse unreachable;
            }
            if (isTitleMagicName(name)) {
                const page = try self.expandWikitext(first, params, host_title, depth + 1);
                return (try self.titleMagic(name, page)) orelse unreachable;
            }
            if (std.ascii.eqlIgnoreCase(name, "DISPLAYTITLE")) {
                const value = try self.expandWikitext(first, params, host_title, depth + 1);
                return try self.recordDisplayTitle(value);
            }
            if (std.ascii.eqlIgnoreCase(name, "DEFAULTSORT")) return "";
            if (std.ascii.eqlIgnoreCase(name, "ns")) {
                const raw_ns = std.mem.trim(u8, try self.expandWikitext(first, params, host_title, depth + 1), " \t\r\n");
                const spec = if (std.fmt.parseInt(i32, raw_ns, 10)) |id|
                    namespace_lib.byId(id)
                else |_|
                    namespace_lib.byName(raw_ns);
                return (spec orelse return error.InvalidNamespace).name;
            }
            if (std.ascii.eqlIgnoreCase(name, "uc")) return try self.expandCaseParser(first, params, host_title, depth + 1, true, false);
            if (std.ascii.eqlIgnoreCase(name, "lc")) return try self.expandCaseParser(first, params, host_title, depth + 1, false, false);
            if (std.ascii.eqlIgnoreCase(name, "ucfirst")) return try self.expandCaseParser(first, params, host_title, depth + 1, true, true);
            if (std.ascii.eqlIgnoreCase(name, "lcfirst")) return try self.expandCaseParser(first, params, host_title, depth + 1, false, true);
            if (std.ascii.eqlIgnoreCase(name, "formatnum")) return try self.expandFormatNum(first, raw_args, params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "plural")) return try self.expandPlural(first, raw_args, params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "anchorencode")) return try self.expandAnchorEncode(first, raw_args, params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "fullurl")) return try self.expandUrlParser(first, raw_args, params, host_title, depth + 1, .full, false);
            if (std.ascii.eqlIgnoreCase(name, "fullurle")) return try self.expandUrlParser(first, raw_args, params, host_title, depth + 1, .full, true);
            if (std.ascii.eqlIgnoreCase(name, "localurl")) return try self.expandUrlParser(first, raw_args, params, host_title, depth + 1, .local, false);
            if (std.ascii.eqlIgnoreCase(name, "canonicalurl")) return try self.expandUrlParser(first, raw_args, params, host_title, depth + 1, .canonical, false);
            if (std.ascii.eqlIgnoreCase(name, "urlencode")) return try self.expandUrlencodeParser(first, raw_args, params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#special")) {
                if (raw_args.len != 0) return error.UnsupportedParserFunction;
                const special = std.mem.trim(u8, try self.expandWikitext(first, params, host_title, depth + 1), " \t\r\n");
                if (special.len == 0) return "Special:";
                return @as(?[]const u8, try std.fmt.allocPrint(self.runtime.allocator, "Special:{s}", .{special}));
            }
            if (std.ascii.eqlIgnoreCase(name, "padleft")) return try self.expandPadParser(first, raw_args, params, host_title, depth + 1, true);
            if (std.ascii.eqlIgnoreCase(name, "padright")) return try self.expandPadParser(first, raw_args, params, host_title, depth + 1, false);
            if (std.ascii.eqlIgnoreCase(name, "#formatdate") or std.ascii.eqlIgnoreCase(name, "#dateformat"))
                return try self.expandFormatDate(first, raw_args, params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#time")) return try self.expandTimeParser(first, raw_args, params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#len")) return try self.expandLenParser(first, params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#sub")) return try self.expandSubParser(first, raw_args, params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#titleparts")) return try self.expandTitleParts(first, raw_args, params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#iferror")) return try self.expandIfError(first, raw_args, params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#invoke")) return try self.expandInvoke(first, raw_args, params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#categorytree"))
                return try self.expandCategoryTreeParser(first, raw_args, params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#if")) {
                const condition = try self.expandWikitext(first, params, host_title, depth + 1);
                const chosen = if (std.mem.trim(u8, condition, " \t\r\n").len != 0)
                    (if (raw_args.len > 0) raw_args[0] else "")
                else
                    (if (raw_args.len > 1) raw_args[1] else "");
                return try self.expandTrimmedParserArgument(chosen, params, host_title, depth + 1);
            }
            if (std.ascii.eqlIgnoreCase(name, "#ifeq")) return try self.expandIfEq(first, raw_args, params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#ifexist")) return try self.expandIfExist(first, raw_args, params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#switch")) return try self.expandSwitch(first, raw_args, params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#expr")) return try self.expandExprParser(first, params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#ifexpr")) return try self.expandIfExpr(first, raw_args, params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#tag")) return try self.expandTagParser(first, raw_args, params, host_title, depth + 1);
        }
        return null;
    }

    fn stripSubstPrefix(raw: []const u8) []const u8 {
        const head = std.mem.trim(u8, raw, " \t\r\n");
        if (head.len >= 10 and std.ascii.eqlIgnoreCase(head[0..10], "safesubst:"))
            return std.mem.trim(u8, head[10..], " \t\r\n");
        if (head.len >= 6 and std.ascii.eqlIgnoreCase(head[0..6], "subst:"))
            return std.mem.trim(u8, head[6..], " \t\r\n");
        return head;
    }

    fn invalidTransclusionTitle(raw: []const u8) bool {
        for (raw) |byte| switch (byte) {
            0...31, 127, '[', ']', '{', '}', '|', '<', '>' => return true,
            else => {},
        };
        return false;
    }

    fn invalidTransclusionNeedsProtection(raw: []const u8) bool {
        for (raw) |byte| switch (byte) {
            0...31, 127, '[', ']', '<', '>' => return true,
            else => {},
        };
        return false;
    }

    fn expandConstruct(self: *Expander, content: []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const lazy_base = self.lazy_template_args.items.len;
        defer self.lazy_template_args.items.len = lazy_base;
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(self.runtime.allocator);
        try preprocess.splitWikitextTop(self.runtime.allocator, content, '|', &parts);
        if (parts.items.len == 0) return error.MalformedWikitext;
        var raw_head = stripSubstPrefix(parts.items[0]);
        if (raw_head.len == 0)
            return std.fmt.allocPrint(self.runtime.allocator, "<nowiki>{{{{{s}}}}}</nowiki>", .{content});
        if (try self.expandParserHead(raw_head, parts.items[1..], params, host_title, depth)) |value| return value;
        if (raw_head[0] == '#')
            return std.fmt.allocPrint(self.runtime.allocator, "<nowiki>{{{{{s}}}}}</nowiki>", .{content});
        switch (try self.classifyInterwikiTransclusion(raw_head)) {
            .normal => {},
            .current_wiki => |local_name| raw_head = local_name,
            .literal => return std.fmt.allocPrint(
                self.runtime.allocator,
                "<nowiki>{{{{{s}}}}}</nowiki>",
                .{content},
            ),
            .external => return error.ExternalInterwikiTransclusionUnsupported,
        }
        if (try self.callSymbol(raw_head, .template)) |symbol| {
            const args = try self.buildTemplateArgs(parts.items[1..], params, host_title, depth + 1);
            return self.expandTemplateBySymbol(symbol, args, host_title, depth + 1);
        }
        const title = stripSubstPrefix(try self.expandWikitext(raw_head, params, host_title, depth + 1));
        if (title.len != 0 and !std.mem.eql(u8, title, raw_head)) {
            if (try self.expandParserHead(title, parts.items[1..], params, host_title, depth)) |value| return value;
        }
        if (title.len != 0 and title[0] == '#')
            return std.fmt.allocPrint(self.runtime.allocator, "<nowiki>{{{{{s}}}}}</nowiki>", .{content});
        if (invalidTransclusionTitle(title)) {
            if (invalidTransclusionNeedsProtection(title))
                return std.fmt.allocPrint(self.runtime.allocator, "<nowiki>{{{{{s}}}}}</nowiki>", .{content});
            return std.fmt.allocPrint(self.runtime.allocator, "{{{{{s}}}}}", .{content});
        }
        const args = try self.buildTemplateArgs(parts.items[1..], params, host_title, depth + 1);
        return self.expandTemplateByName(title, args, host_title, depth + 1, .link);
    }

    fn scalarText(self: *Expander, value: Value) ![]const u8 {
        return switch (value) {
            .nil => "",
            .string => |text| text,
            .number => |number| rt.numberToString(self.runtime.allocator, number),
            .boolean => |boolean| if (boolean) "true" else "false",
            else => error.WikitextScalarExpected,
        };
    }

    fn appendAttrEscaped(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
        for (text) |byte| switch (byte) {
            '&' => try out.appendSlice(a, "&amp;"),
            '<' => try out.appendSlice(a, "&lt;"),
            '>' => try out.appendSlice(a, "&gt;"),
            '"' => try out.appendSlice(a, "&quot;"),
            else => try out.append(a, byte),
        };
    }

    fn serializeExtension(self: *Expander, name: []const u8, content: ?Value, attrs: ?*rt.Table) ![]const u8 {
        const a = self.runtime.allocator;
        var out: std.ArrayList(u8) = .empty;
        try out.append(a, '<');
        try out.appendSlice(a, name);
        if (attrs) |table| {
            var keys: std.ArrayList([]const u8) = .empty;
            defer keys.deinit(a);
            var it = table.iterator();
            while (it.next()) |entry| if (entry.key_ptr.* == .string and entry.value_ptr.* != .nil) try keys.append(a, entry.key_ptr.string);
            std.mem.sort([]const u8, keys.items, {}, struct {
                fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
                    return std.mem.order(u8, lhs, rhs) == .lt;
                }
            }.less);
            for (keys.items) |key| {
                try out.append(a, ' ');
                try out.appendSlice(a, key);
                try out.appendSlice(a, "=\"");
                try appendAttrEscaped(&out, a, try self.scalarText(table.rawGet(.{ .string = key }).?));
                try out.append(a, '"');
            }
        }
        if (content) |value| {
            try out.append(a, '>');
            try out.appendSlice(a, try self.scalarText(value));
            try out.appendSlice(a, "</");
            try out.appendSlice(a, name);
            try out.append(a, '>');
        } else {
            try out.appendSlice(a, "/>");
        }
        return out.toOwnedSlice(a);
    }

    fn hostFramePreprocess(raw: ?*anyopaque, a: std.mem.Allocator, source: []const u8, title: []const u8, args: *rt.Table) anyerror![]const u8 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const stripped = try preprocess.stripDecodedComments(a, source);
        defer a.free(stripped);
        if (stripped.len >= 2 and stripped[0] == '=' and stripped[stripped.len - 1] == '=' and
            std.mem.indexOf(u8, stripped, nowiki_marker_prefix) != null)
        {
            const number = self.page_heading_count + self.fake_heading_count;
            self.fake_heading_count += 1;
            return std.fmt.allocPrint(a, "\x7f'\"`UNIQ--h-{d}--QINU`\"'\x7f", .{number});
        }
        return self.expandWikitext(stripped, args, title, 0);
    }

    fn hostFrameExpandTemplate(raw: ?*anyopaque, _: std.mem.Allocator, title: []const u8, args: *rt.Table) anyerror![]const u8 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        return self.expandTemplateByName(title, args, null, 0, .lua_error);
    }

    fn hostFrameExtensionTag(raw: ?*anyopaque, a: std.mem.Allocator, name: []const u8, content: ?Value, attrs: ?*rt.Table) anyerror![]const u8 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        if (std.ascii.eqlIgnoreCase(name, "nowiki")) {
            const text = if (content) |value| if (value == .string) value.string else "" else "";
            const id = self.strip_counter;
            self.strip_counter +%= 1;
            const page_a = self.page_allocator orelse return error.MissingPageAllocator;
            const stored = try page_a.dupe(u8, text);
            try self.strip_values.put(page_a, id, stored);
            return makeNowikiMarker(a, id);
        }
        const canonical = canonicalExtensionTag(name) orelse return error.UnsupportedExtensionTag;
        return self.serializeExtension(canonical, content, attrs);
    }

    fn hostTextUnstripNoWiki(raw: ?*anyopaque, a: std.mem.Allocator, source: []const u8) anyerror![]const u8 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
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
            if (self.strip_values.get(id)) |text|
                try out.appendSlice(a, text)
            else
                try out.appendSlice(a, source[at..marker_end]);
            pos = marker_end;
        }
        try out.appendSlice(a, source[pos..]);
        return out.toOwnedSlice(a);
    }

    fn formattedDateSpan(self: *Expander, raw: []const u8, style_raw: ?[]const u8) ![]const u8 {
        return dateformat_lib.format(self.runtime.allocator, raw, style_raw);
    }

    fn frameParserTagAttrs(self: *Expander, args: *rt.Table, positional_start: usize) !?*rt.Table {
        const attrs = try self.runtime.newTable();
        var any = false;
        var it = args.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* != .string or entry.value_ptr.* == .nil) continue;
            try attrs.rawSet(self.runtime.allocator, entry.key_ptr.*, entry.value_ptr.*);
            any = true;
        }
        var index = positional_start;
        while (args.rawGet(.{ .number = @floatFromInt(index) })) |value| : (index += 1) {
            const text = try self.scalarText(value);
            const eq = std.mem.indexOfScalar(u8, text, '=') orelse return error.UnsupportedExtensionAttributeArgument;
            const key = std.mem.trim(u8, text[0..eq], " \t\r\n");
            if (key.len == 0) return error.UnsupportedExtensionAttributeArgument;
            const attr_value = std.mem.trim(u8, text[eq + 1 ..], " \t\r\n");
            try attrs.rawSet(self.runtime.allocator, .{ .string = key }, .{ .string = attr_value });
            any = true;
        }
        return if (any) attrs else null;
    }

    fn frameParserTag(self: *Expander, raw: ?*anyopaque, a: std.mem.Allocator, name: []const u8, args: *rt.Table) ![]const u8 {
        const plain = std.ascii.eqlIgnoreCase(name, "#tag");
        const prefixed = std.ascii.startsWithIgnoreCase(name, "#tag:");
        if (!plain and !prefixed) return error.UnsupportedParserFunction;
        const tag: []const u8 = if (plain) blk: {
            const value = args.rawGet(.{ .number = 1 }) orelse return error.StringExpected;
            if (value != .string) return error.StringExpected;
            break :blk std.mem.trim(u8, value.string, " \t\r\n");
        } else std.mem.trim(u8, name[5..], " \t\r\n");
        if (tag.len == 0) return error.UnsupportedExtensionTag;
        const content_index: usize = if (plain) 2 else 1;
        const attr_start: usize = content_index + 1;
        const content_text = if (args.rawGet(.{ .number = @floatFromInt(content_index) })) |value| try self.scalarText(value) else "";
        const attrs = try self.frameParserTagAttrs(args, attr_start);
        return hostFrameExtensionTag(raw, a, tag, .{ .string = content_text }, attrs);
    }

    fn frameParserInvoke(self: *Expander, args: *rt.Table) ![]const u8 {
        const module_value = args.rawGet(.{ .number = 1 }) orelse return error.ModuleNameExpected;
        const module_raw = std.mem.trim(u8, try self.scalarText(module_value), " \t\r\n");
        if (module_raw.len == 0) return error.ModuleNameExpected;
        const module_name = if (module_raw.len >= 7 and std.ascii.eqlIgnoreCase(module_raw[0..7], "Module:"))
            module_raw
        else
            try std.fmt.allocPrint(self.runtime.allocator, "Module:{s}", .{module_raw});
        const function_name = if (args.rawGet(.{ .number = 2 })) |value|
            std.mem.trim(u8, try self.scalarText(value), " \t\r\n")
        else
            "main";

        const invoke_args = try self.runtime.newTable();
        var it = args.iterator();
        while (it.next()) |entry| switch (entry.key_ptr.*) {
            .string => try invoke_args.rawSet(self.runtime.allocator, entry.key_ptr.*, entry.value_ptr.*),
            .number => |index| if (std.math.isFinite(index) and index >= 3 and index == @trunc(index))
                try invoke_args.rawSet(self.runtime.allocator, .{ .number = index - 2 }, entry.value_ptr.*),
            else => {},
        };
        const parent: ?Value = if (self.runtime.current_frame) |frame| .{ .table = frame } else null;
        return switch (try self.invokeWithRecovery(null, module_name, function_name, invoke_args, parent, null, null)) {
            .generated => |generated| generated,
            .error_markup => |markup| markup,
        };
    }

    fn categoryTreeArg(args: *rt.Table, key: []const u8) ?[]const u8 {
        const value = args.rawGet(.{ .string = key }) orelse return null;
        return if (value == .string) value.string else null;
    }

    fn categoryTreeValue(raw: ?[]const u8) ?[]const u8 {
        var value = std.mem.trim(u8, raw orelse return null, " \t\r\n");
        if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\'')))
            value = std.mem.trim(u8, value[1 .. value.len - 1], " \t\r\n");
        return if (value.len == 0) null else value;
    }

    fn categoryTreeClass(raw: ?[]const u8) ?[]const u8 {
        var value = std.mem.trim(u8, raw orelse return null, " \t\r\n");
        if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\'')))
            value = std.mem.trim(u8, value[1 .. value.len - 1], " \t\r\n");
        if (value.len == 0) return null;
        for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == ' ')) return null;
        return value;
    }

    fn categoryTreeRootCount(mode: []const u8, stats: Provider.CategoryStats) ?u32 {
        if (std.ascii.eqlIgnoreCase(mode, "all")) return stats.all;
        // CategoryTree pages mode includes subcategories, unlike pagesInCategory.
        if (std.ascii.eqlIgnoreCase(mode, "pages")) return stats.all -| stats.files;
        if (std.ascii.eqlIgnoreCase(mode, "categories")) return stats.subcats;
        return null;
    }

    fn missingCategoryTree(
        self: *Expander,
        display: []const u8,
        mode: []const u8,
        mode_explicit: bool,
        hideprefix: []const u8,
        showcount: []const u8,
        namespaces: ?[]const u8,
        class_name: ?[]const u8,
    ) ![]const u8 {
        const a = self.runtime.allocator;
        const effective_mode = if (namespaces != null)
            "pages"
        else if (mode_explicit)
            mode
        else
            "categories";
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, "<div class=\"");
        if (class_name) |name| {
            try out.appendSlice(a, name);
            try out.append(a, ' ');
        }
        try out.appendSlice(a, "CategoryTreeTag\" data-ct-options=\"{&quot;mode&quot;:&quot;");
        try out.appendSlice(a, effective_mode);
        try out.appendSlice(a, "&quot;,&quot;hideprefix&quot;:&quot;");
        try out.appendSlice(a, hideprefix);
        try out.appendSlice(a, "&quot;,&quot;showcount&quot;:");
        try out.appendSlice(a, if (std.ascii.eqlIgnoreCase(showcount, "on")) "true" else "false");
        try out.appendSlice(a, ",&quot;namespaces&quot;:");
        try out.appendSlice(a, if (namespaces != null) "[0]" else "false");
        try out.appendSlice(a, ",&quot;notranslations&quot;:false}\"><span class=\"CategoryTreeNotice\">Category <i>");
        try appendAttrEscaped(&out, a, display);
        try out.appendSlice(a, "</i> not found</span></div>");
        return out.toOwnedSlice(a);
    }

    fn expandCategoryTree(self: *Expander, args: *rt.Table) ![]const u8 {
        const first = args.rawGet(.{ .number = 1 }) orelse return error.StringExpected;
        if (first != .string) return error.StringExpected;
        const raw_category = std.mem.trim(u8, first.string, " \t\r\n");
        if (raw_category.len == 0) return "";
        errdefer |err| if (err == error.UnsupportedCategoryTreeOptions) {
            self.runtime.last_error = .{ .string = std.fmt.allocPrint(
                self.runtime.allocator,
                "Unsupported CategoryTree options for {s}: mode={s} type={s} depth={s} namespaces={s} hideprefix={s} hideroot={s} showcount={s} class={s} style={s}",
                .{
                    raw_category,
                    categoryTreeArg(args, "mode") orelse "(default)",
                    categoryTreeArg(args, "type") orelse "(default)",
                    categoryTreeArg(args, "depth") orelse "(default)",
                    categoryTreeArg(args, "namespaces") orelse "(default)",
                    categoryTreeArg(args, "hideprefix") orelse "(default)",
                    categoryTreeArg(args, "hideroot") orelse "(default)",
                    categoryTreeArg(args, "showcount") orelse "(default)",
                    categoryTreeArg(args, "class") orelse "(default)",
                    categoryTreeArg(args, "style") orelse "(default)",
                },
            ) catch "Unsupported CategoryTree options" };
        };

        const category = try self.runtime.allocator.dupe(u8, raw_category);
        for (category) |*byte| {
            if (byte.* == ' ') byte.* = '_';
        }

        const mode_arg = categoryTreeArg(args, "mode");
        const type_arg = categoryTreeArg(args, "type");
        if (mode_arg != null and type_arg != null and !std.ascii.eqlIgnoreCase(mode_arg.?, type_arg.?))
            return error.UnsupportedCategoryTreeOptions;
        const namespaces = categoryTreeValue(categoryTreeArg(args, "namespaces"));
        // MediaWiki defaults to subcategories. A main-namespace filter forces pages mode.
        const mode = if (namespaces != null and std.mem.eql(u8, namespaces.?, "-"))
            "pages"
        else
            mode_arg orelse type_arg orelse "categories";
        const depth = categoryTreeArg(args, "depth") orelse "1";
        const hideprefix = categoryTreeArg(args, "hideprefix") orelse "categories";
        const hideroot = categoryTreeArg(args, "hideroot") orelse "off";
        const showcount = categoryTreeArg(args, "showcount") orelse "off";
        const class_name = categoryTreeClass(categoryTreeArg(args, "class"));
        if ((!std.ascii.eqlIgnoreCase(hideprefix, "always") and
            !std.ascii.eqlIgnoreCase(hideprefix, "categories")) or
            !std.ascii.eqlIgnoreCase(hideroot, "off") or
            (!std.ascii.eqlIgnoreCase(showcount, "on") and !std.ascii.eqlIgnoreCase(showcount, "off")) or
            (categoryTreeArg(args, "class") != null and class_name == null))
            return error.UnsupportedCategoryTreeOptions;

        const display = try self.runtime.allocator.dupe(u8, category);
        for (display) |*byte| {
            if (byte.* == '_') byte.* = ' ';
        }

        // CategoryTree tests the category page's existence, not its member count.
        const category_title = try std.fmt.allocPrint(self.runtime.allocator, "Category:{s}", .{display});
        defer self.runtime.allocator.free(category_title);
        if (!try self.provider.exists(self.provider.ctx, category_title))
            return self.missingCategoryTree(display, mode, mode_arg != null or type_arg != null, hideprefix, showcount, namespaces, class_name);

        if (std.mem.eql(u8, depth, "0")) {
            if (namespaces) |value| if (!std.mem.eql(u8, value, "-")) return error.UnsupportedCategoryTreeOptions;
            const stats_get = self.provider.category_stats orelse return error.NotImplemented;
            const stats = (try stats_get(self.provider.ctx, category)) orelse
                Provider.CategoryStats{ .all = 0, .subcats = 0, .files = 0 };
            const count = categoryTreeRootCount(mode, stats) orelse return error.UnsupportedCategoryTreeOptions;
            const a = self.runtime.allocator;
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(a, "<div class=\"");
            if (class_name) |name| {
                try out.appendSlice(a, name);
                try out.append(a, ' ');
            }
            try out.appendSlice(a, "CategoryTreeTag\"><div class=\"CategoryTreeSection\"><div class=\"CategoryTreeItem\"><span class=\"");
            try out.appendSlice(a, if (count == 0) "CategoryTreeEmptyBullet" else "CategoryTreeBullet");
            try out.appendSlice(a, "\">►</span> [[:Category:");
            try out.appendSlice(a, display);
            try out.append(a, '|');
            try out.appendSlice(a, display);
            try out.appendSlice(a, "]] ");
            if (std.ascii.eqlIgnoreCase(showcount, "on")) {
                try out.appendSlice(a, "<span class=\"CategoryTreeCount\">(");
                const count_text = try std.fmt.allocPrint(a, "{d}", .{count});
                defer a.free(count_text);
                try out.appendSlice(a, count_text);
                try out.appendSlice(a, ")</span>");
            }
            try out.appendSlice(a, "</div><div class=\"CategoryTreeChildren\" style=\"display:none\"></div></div></div>");
            return out.toOwnedSlice(a);
        }

        if (!std.ascii.eqlIgnoreCase(mode, "pages") or
            !std.mem.eql(u8, depth, "1") or
            (namespaces != null and !std.mem.eql(u8, namespaces.?, "-")))
            return error.UnsupportedCategoryTreeOptions;

        const style = categoryTreeArg(args, "style");
        if (style) |value| {
            const prefix = "counter-reset: pagesleftover ";
            if (!std.mem.startsWith(u8, value, prefix) or value.len == prefix.len)
                return error.UnsupportedCategoryTreeOptions;
            _ = std.fmt.parseInt(u64, value[prefix.len..], 10) catch return error.UnsupportedCategoryTreeOptions;
        }
        const data_pages_in_cat = categoryTreeArg(args, "data-pages-in-cat");
        const data_pages_left_over = categoryTreeArg(args, "data-pages-left-over");
        if (data_pages_in_cat) |value| _ = std.fmt.parseInt(u64, value, 10) catch return error.UnsupportedCategoryTreeOptions;
        if (data_pages_left_over) |value| _ = std.fmt.parseInt(u64, value, 10) catch return error.UnsupportedCategoryTreeOptions;

        const get = self.provider.category_tree orelse return error.NotImplemented;
        const members = try get(self.provider.ctx, self.runtime.allocator, category, if (namespaces == null) .pages else .main);
        defer self.runtime.allocator.free(members);

        var page_count: usize = members.len;
        if (self.provider.category_stats) |stats_get| {
            if (try stats_get(self.provider.ctx, category)) |stats|
                page_count = stats.all -| stats.files;
        }

        var out: std.ArrayList(u8) = .empty;
        const a = self.runtime.allocator;
        try out.appendSlice(a, "<div class=\"");
        if (class_name) |name| {
            try out.appendSlice(a, name);
            try out.append(a, ' ');
        }
        try out.appendSlice(a, "CategoryTreeTag\"");
        if (data_pages_in_cat) |value| {
            try out.appendSlice(a, " data-pages-in-cat=\"");
            try out.appendSlice(a, value);
            try out.append(a, '"');
        }
        if (data_pages_left_over) |value| {
            try out.appendSlice(a, " data-pages-left-over=\"");
            try out.appendSlice(a, value);
            try out.append(a, '"');
        }
        if (style) |value| {
            try out.appendSlice(a, " style=\"");
            try out.appendSlice(a, value);
            try out.append(a, '"');
        }
        try out.appendSlice(a, "><div class=\"CategoryTreeSection\"><div class=\"CategoryTreeItem\"><span class=\"CategoryTreeBullet\">►</span> [[:Category:");
        try out.appendSlice(a, display);
        try out.append(a, '|');
        try out.appendSlice(a, display);
        try out.appendSlice(a, "]]");
        if (std.ascii.eqlIgnoreCase(showcount, "on")) {
            try out.appendSlice(a, " <span class=\"CategoryTreeCount\">(");
            const count_text = try std.fmt.allocPrint(a, "{d}", .{page_count});
            defer a.free(count_text);
            try out.appendSlice(a, count_text);
            try out.appendSlice(a, ")</span>");
        }
        try out.appendSlice(a, "</div><div class=\"CategoryTreeChildren\" style=\"display:block\">");
        // MediaWiki applies its SQL limit before placing subcategories ahead of pages.
        for ([_]bool{ true, false }) |categories| {
            for (members) |title| {
                const is_category = std.mem.startsWith(u8, title, "Category:");
                if (is_category != categories) continue;
                var child_count: ?u32 = null;
                if (is_category) {
                    if (self.provider.category_stats) |stats_get| {
                        const child_key = try a.dupe(u8, title["Category:".len..]);
                        defer a.free(child_key);
                        for (child_key) |*byte| if (byte.* == ' ') {
                            byte.* = '_';
                        };
                        const child_stats = (try stats_get(self.provider.ctx, child_key)) orelse
                            Provider.CategoryStats{ .all = 0, .subcats = 0, .files = 0 };
                        child_count = categoryTreeRootCount(mode, child_stats);
                    }
                }
                try out.appendSlice(a, "<div class=\"CategoryTreeSection\"><div class=\"CategoryTreeItem\"><span class=\"");
                try out.appendSlice(a, if (is_category)
                    (if (child_count == 0) "CategoryTreeEmptyBullet" else "CategoryTreeBullet")
                else
                    "CategoryTreePageBullet");
                try out.appendSlice(a, "\">");
                if (is_category) try out.appendSlice(a, "►");
                try out.appendSlice(a, "</span> [[");
                // Explicit leading colon prevents category/file membership syntax.
                if (is_category or std.mem.startsWith(u8, title, "File:")) try out.append(a, ':');
                try out.appendSlice(a, title);
                if (is_category or std.ascii.eqlIgnoreCase(hideprefix, "always")) {
                    const member_namespace = namespace_lib.ofTitle(title);
                    if (member_namespace.id != 0) {
                        try out.append(a, '|');
                        try out.appendSlice(a, member_namespace.text);
                    }
                }
                try out.appendSlice(a, "]]");
                if (std.ascii.eqlIgnoreCase(showcount, "on")) {
                    if (child_count) |count| {
                        const count_text = try std.fmt.allocPrint(a, " <span class=\"CategoryTreeCount\">({d})</span>", .{count});
                        defer a.free(count_text);
                        try out.appendSlice(a, count_text);
                    }
                }
                try out.appendSlice(a, "</div><div class=\"CategoryTreeChildren\" style=\"display:none\"></div></div>");
            }
        }
        try out.appendSlice(a, "</div></div></div>");
        return out.toOwnedSlice(a);
    }

    fn expandCategoryTreeParser(
        self: *Expander,
        raw_category: []const u8,
        raw_args: []const []const u8,
        params: *rt.Table,
        host_title: []const u8,
        depth: usize,
    ) ![]const u8 {
        const args = try self.runtime.newTable();
        try args.rawSet(
            self.runtime.allocator,
            .{ .number = 1 },
            .{ .string = try self.expandWikitext(raw_category, params, host_title, depth + 1) },
        );
        var positional: usize = 2;
        for (raw_args) |raw| {
            if (preprocess.findTopDelimiter(raw, '=')) |eq| {
                const key = std.mem.trim(
                    u8,
                    try self.expandWikitext(raw[0..eq], params, host_title, depth + 1),
                    " \t\r\n",
                );
                if (key.len == 0) continue;
                const value = try self.expandWikitext(raw[eq + 1 ..], params, host_title, depth + 1);
                try args.rawSet(self.runtime.allocator, .{ .string = key }, .{ .string = value });
            } else {
                const value = try self.expandWikitext(raw, params, host_title, depth + 1);
                try args.rawSet(
                    self.runtime.allocator,
                    .{ .number = @floatFromInt(positional) },
                    .{ .string = value },
                );
                positional += 1;
            }
        }
        return self.expandCategoryTree(args);
    }

    fn hostFrameParserFunction(raw: ?*anyopaque, a: std.mem.Allocator, name: []const u8, args: *rt.Table) anyerror![]const u8 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const first = args.rawGet(.{ .number = 1 });
        const second = args.rawGet(.{ .number = 2 });
        if (isRevisionMagicName(name)) {
            const page: ?[]const u8 = if (first) |value| switch (value) {
                .nil => null,
                .string => |text| text,
                else => return error.StringExpected,
            } else null;
            return (try self.revisionMagic(name, page)) orelse unreachable;
        }
        if (std.ascii.eqlIgnoreCase(name, "#invoke")) return self.frameParserInvoke(args);
        if (std.ascii.eqlIgnoreCase(name, "#categorytree")) return self.expandCategoryTree(args);
        if (std.ascii.eqlIgnoreCase(name, "#tag") or std.ascii.startsWithIgnoreCase(name, "#tag:")) return self.frameParserTag(raw, a, name, args);
        if (std.ascii.eqlIgnoreCase(name, "DISPLAYTITLE")) {
            if (first == null or first.? != .string) return error.StringExpected;
            return self.recordDisplayTitle(first.?.string);
        }
        if (std.ascii.eqlIgnoreCase(name, "DEFAULTSORT")) return "";
        if (std.ascii.eqlIgnoreCase(name, "#formatdate") or std.ascii.eqlIgnoreCase(name, "#dateformat")) {
            if (first == null or first.? != .string) return error.StringExpected;
            const style: ?[]const u8 = if (second) |value| switch (value) {
                .nil => null,
                .string => |text| text,
                else => return error.StringExpected,
            } else null;
            return self.formattedDateSpan(first.?.string, style);
        }
        if (std.ascii.eqlIgnoreCase(name, "#time")) {
            if (first == null or first.? != .string) return error.StringExpected;
            const source: ?[]const u8 = if (second) |value| switch (value) {
                .nil => null,
                .string => |text| text,
                else => return error.StringExpected,
            } else null;
            const timestamp = language_lib.parseTimestampText(self.runtime, source) catch |err|
                return self.parserError("Time error", err);
            return language_lib.formatDateAlloc(self.runtime.allocator, timestamp, first.?.string) catch |err|
                return self.parserError("Time error", err);
        }
        return error.UnsupportedParserFunction;
    }
};

fn installTestHost(runtime: *rt.Context, string_slot: u32, mw_slot: u32) !void {
    const mw = try runtime.newNativeNamespace(.mw);
    const ustring = try runtime.newNativeNamespace(.ustring);
    const string = runtime.getGlobal(string_slot);
    if (string != .table) return error.MissingStringLibrary;
    var it = string.table.iterator();
    while (it.next()) |entry| try ustring.rawSet(runtime.allocator, entry.key_ptr.*, entry.value_ptr.*);
    const case_mapper = try ustring_lib.install(runtime, ustring);
    try mw.rawSet(runtime.allocator, .{ .string = "ustring" }, .{ .table = ustring });
    try text_lib.install(runtime, mw);
    try uri_lib.install(runtime, mw);
    try language_lib.install(runtime, mw, case_mapper);
    try runtime.setGlobal(mw_slot, .{ .table = mw });
}

fn installTestInvoke(
    _: *?*anyopaque,
    _: ?*anyopaque,
    _: std.mem.Allocator,
    runtime: *rt.Context,
    _: u32,
    string_slot: u32,
    mw_slot: u32,
) !void {
    try installTestHost(runtime, string_slot, mw_slot);
}

const ScribuntoInstallProbe = struct {
    var calls = std.atomic.Value(usize).init(0);

    fn install(
        _: *?*anyopaque,
        _: ?*anyopaque,
        _: std.mem.Allocator,
        runtime: *rt.Context,
        _: u32,
        string_slot: u32,
        mw_slot: u32,
    ) !void {
        _ = calls.fetchAdd(1, .monotonic);
        try installTestHost(runtime, string_slot, mw_slot);
    }
};

const TestProvider = struct {
    const category_tree_members = [_][]const u8{ "alpha", "beta" };
    const interwiki_rows = [_]Provider.InterwikiRow{
        .{ .prefix = "w", .url = "https://example.test/$1", .is_local = true, .is_current_wiki = false, .is_protocol_relative = false, .is_transcludable = false },
        .{ .prefix = "self", .url = "https://local.test/$1", .is_local = true, .is_current_wiki = true, .is_protocol_relative = false, .is_transcludable = false },
        .{ .prefix = "remote", .url = "https://remote.test/$1", .is_local = true, .is_current_wiki = false, .is_protocol_relative = false, .is_transcludable = true },
    };

    fn get(_: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
        if (std.mem.eql(u8, title, "Template:Hello")) return "Hi {{{1|friend}}} {{#if:{{{2|}}}|Y|N}}";
        if (std.mem.eql(u8, title, "Template:Only")) return "A<noinclude>X</noinclude>B<includeonly>C</includeonly>D";
        if (std.mem.eql(u8, title, "Template:Lazy")) return "used={{{used}}}";
        if (std.mem.eql(u8, title, "Template:LazyForward")) return "{{Lazy|used={{{1}}}|unused={{{2}}}}}";
        if (std.mem.eql(u8, title, "Template:Space Name")) return "space-template";
        if (std.mem.eql(u8, title, "Wiktionary:Sandbox/Child")) return "relative-project-child";
        if (std.mem.eql(u8, title, "Template:/Child")) return "literal-template-slash-child";
        if (std.mem.eql(u8, title, "Template:Parent")) return "{{/Child}}";
        if (std.mem.eql(u8, title, "Template:RepairParent")) return "{{#invoke:Test|repair_parent}}";
        if (std.mem.eql(u8, title, "Template:Loop")) return "{{Loop}}";
        if (std.mem.eql(u8, title, "Template:Parent/Child")) return "relative-template-child";
        if (std.mem.eql(u8, title, "Main page")) return "main-transclusion";
        if (std.mem.eql(u8, title, "Wiktionary:Sandbox")) return "project-transclusion";
        return null;
    }
    fn exists(_: ?*anyopaque, title: []const u8) !bool {
        return std.mem.eql(u8, title, "Exists") or std.mem.eql(u8, title, "Wiktionary:Sandbox") or
            std.mem.eql(u8, title, "Category:English terms prefixed with un-") or
            std.mem.eql(u8, title, "Category:Empty category");
    }
    fn pageMetadata(_: ?*anyopaque, title: []const u8) !?Provider.PageMetadata {
        if (std.mem.eql(u8, title, "Page") or std.mem.eql(u8, title, "Appendix:Page/Sub"))
            return .{ .page_id = 42, .revision_id = 420, .revision_timestamp = "2024-03-04T05:06:07Z", .revision_user = "Test editor", .content_model = "wikitext" };
        if (std.mem.eql(u8, title, "Other page"))
            return .{ .page_id = 99, .revision_id = 990, .revision_timestamp = "2025-06-07T08:09:10Z", .revision_user = "Other editor", .content_model = "wikitext" };
        return null;
    }
    fn resolveCallSymbol(_: ?*anyopaque, _: *rt.Context, raw: []const u8, kind: CallSymbolKind) !?CallSymbol {
        const value = std.mem.trim(u8, raw, " \t\r\n");
        return switch (kind) {
            .template => if (std.mem.eql(u8, value, "@template") or std.mem.eql(u8, value, "PAGENAME")) .{ .id = 3, .text = "Hello" } else null,
            .module => if (std.mem.eql(u8, value, "@module")) .{ .id = 1, .text = "Test", .module_id = 0 } else null,
            .function => if (std.mem.eql(u8, value, "@function")) .{ .id = 2, .text = "run" } else null,
        };
    }
    fn getTemplateSymbol(_: ?*anyopaque, _: std.mem.Allocator, id: usize) !?[]const u8 {
        return if (id == 3) "Hi {{{1|friend}}} {{#if:{{{2|}}}|Y|N}}" else null;
    }
    fn interwikiMap(_: ?*anyopaque) ![]const Provider.InterwikiRow {
        return &interwiki_rows;
    }
    fn categoryTree(_: ?*anyopaque, a: std.mem.Allocator, db_key: []const u8, scope: Provider.CategoryTreeScope) ![]const []const u8 {
        if (!std.mem.eql(u8, db_key, "English_terms_prefixed_with_un-"))
            return error.CategoryTreeSnapshotMissing;
        return a.dupe([]const u8, if (scope == .main) &category_tree_members else &.{ "alpha", "Talk:beta", "Category:Child" });
    }
    fn categoryStats(_: ?*anyopaque, db_key: []const u8) !?Provider.CategoryStats {
        if (!std.mem.eql(u8, db_key, "English_terms_prefixed_with_un-")) return null;
        return .{ .all = 4, .subcats = 1, .files = 0 };
    }
};

const TestModule = struct {
    fn lookup(_: ?*const anyopaque, raw_name: []const u8) ?u32 {
        return if (std.mem.eql(u8, raw_name, "Module:Test")) 0 else null;
    }
    fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
        return if (id == 0) "Module:Test" else null;
    }
    fn root(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        const exports = try ctx.newTable();
        try exports.rawSet(ctx.allocator, .{ .string = "run" }, try ctx.makeFunctionKnown(1, run, &.{}));
        try exports.rawSet(ctx.allocator, .{ .string = "fail" }, try ctx.makeFunctionKnown(2, fail, &.{}));
        try exports.rawSet(ctx.allocator, .{ .string = "random" }, try ctx.makeFunctionKnown(3, random, &.{}));
        const state = try ctx.allocator.create(rt.Cell);
        state.* = .{ .value = .{ .number = 0 } };
        try exports.rawSet(ctx.allocator, .{ .string = "stateful" }, try ctx.makeFunctionKnown(4, stateful, &.{state}));
        try exports.rawSet(ctx.allocator, .{ .string = "nested" }, try ctx.makeFunctionKnown(5, nested, &.{}));
        try exports.rawSet(ctx.allocator, .{ .string = "repair" }, try ctx.makeFunctionKnown(6, repair, &.{}));
        try exports.rawSet(ctx.allocator, .{ .string = "repair_parent" }, try ctx.makeFunctionKnown(7, repairParent, &.{}));
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .table = exports };
        return out;
    }
    fn run(ctx: *rt.Context, _: rt.Captures, args: []const Value) ![]const Value {
        if (args.len == 0 or args[0] != .table) return error.FrameExpected;
        const frame_args = try ctx.getIndex(args[0], .{ .string = "args" });
        const value = try ctx.getIndex(frame_args, .{ .string = "x" });
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = value;
        return out;
    }
    fn fail(_: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        return error.NotCallable;
    }
    fn random(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        const math = ctx.getGlobal(19); // Stable globals ABI: math.
        if (math != .table) return error.MissingMathLibrary;
        const call = try ctx.getIndex(math, .{ .string = "random" });
        return ctx.callValue(call, &.{.{ .number = 10 }});
    }
    fn stateful(_: *rt.Context, captures: rt.Captures, _: []const Value) ![]const Value {
        const state = try captures.cell(0);
        const next = switch (state.value) {
            .number => |number| number + 1,
            else => 1,
        };
        state.value = .{ .number = next };
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .number = next };
        return out;
    }
    fn nested(_: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .string = "<ref>{{Hello|R|1}}</ref>" };
        return out;
    }
    fn repair(ctx: *rt.Context, _: rt.Captures, args: []const Value) ![]const Value {
        if (args.len == 0 or args[0] != .table) return error.FrameExpected;
        const frame_args = try ctx.getIndex(args[0], .{ .string = "args" });
        const value = try ctx.getIndex(frame_args, .{ .string = "x" });
        if (value != .string) return error.StringExpected;
        if (std.mem.indexOf(u8, value.string, "&lt;") != null) {
            ctx.last_error = .{ .string = try ctx.allocator.dupe(u8, "Invalid page title \"Reconstruction:Probe/term&lt;t:gloss&gt;\" encountered.") };
            return error.LuaRaised;
        }
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .string = "repaired" };
        return out;
    }
    fn repairParent(ctx: *rt.Context, _: rt.Captures, args: []const Value) ![]const Value {
        if (args.len == 0 or args[0] != .table) return error.FrameExpected;
        const get_parent = try ctx.getIndex(args[0], .{ .string = "getParent" });
        const parent_result = try ctx.callValue(get_parent, &.{args[0]});
        defer rt.freeResults(parent_result);
        if (parent_result.len == 0 or parent_result[0] != .table) return error.FrameExpected;
        const parent_args = try ctx.getIndex(parent_result[0], .{ .string = "args" });
        const value = try ctx.getIndex(parent_args, .{ .string = "x" });
        if (value != .string) return error.StringExpected;
        if (std.mem.indexOf(u8, value.string, "&lt;") != null) {
            ctx.last_error = .{ .string = try ctx.allocator.dupe(u8, "Invalid page title \"Reconstruction:Probe/term&lt;t:gloss&gt;\" encountered.") };
            return error.LuaRaised;
        }
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .string = "parent repaired" };
        return out;
    }
};

test "native AOT wikitext expands templates parser functions and invoke" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 24, 1);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{ rt.stabilize(TestModule.root), rt.stabilize(TestModule.run), rt.stabilize(TestModule.fail), rt.stabilize(TestModule.random), rt.stabilize(TestModule.stateful), rt.stabilize(TestModule.nested), rt.stabilize(TestModule.repair), rt.stabilize(TestModule.repairParent) };
    runtime.module_root_entries = &functions;
    runtime.configureModules(null, TestModule.lookup, TestModule.name);
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);

    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists }, .install_scribunto = installTestInvoke };
    expander.provider.category_tree = TestProvider.categoryTree;
    expander.provider.category_stats = TestProvider.categoryStats;
    const source = "{{Hello|Bob|1}}|{{Only}}|{{Space  Name}}|{{Space___Name}}|{{:Main_page}}|{{WT:Sandbox}}|{{T:Hello|Z|1}}|{{#ifeq:a|a|yes|no}}|{{#switch:x|y=no|x=yes|#default=d}}|{{#expr:2+3*4}}|{{#ifexist:Exists|E|N}}|{{#ifexist:WT:Sandbox|W|N}}|{{uc:hé}}|{{padleft:é|3|ø}}|{{CURRENTYEAR}}|{{#tag:ref|body|name=n}}|{{#tag:math|x+y}}|{{#tag:poem|one\ntwo}}|{{#invoke:Test|run|x=ok}}";
    expander.provider.page_metadata = TestProvider.pageMetadata;
    const current_magic = try expander.expandFragment("Appendix:Page/Sub", "{{CURRENTDAYNAME}}|{{CURRENTWEEK}}|{{CURRENTMONTHNAMEGEN}}|{{PAGEID}}|{{REVISIONID}}|{{REVISIONTIMESTAMP}}|{{REVISIONYEAR}}-{{REVISIONMONTH}}-{{REVISIONDAY}}|{{REVISIONUSER}}", 1_670_803_200);
    try std.testing.expectEqualStrings("Monday|50|December|42|420|20240304050607|2024-03-4|Test editor", current_magic);
    const site_magic = try expander.expandFragment("Page", "{{SERVER}}|{{SERVERNAME}}", 1_670_803_200);
    try std.testing.expectEqualStrings("//en.wiktionary.org|en.wiktionary.org", site_magic);
    const urlencode_param = try expander.expandFragment("Page", "{{urlencode:flundra 1°|PARAM}}", 1_670_803_200);
    try std.testing.expectEqualStrings("flundra+1%C2%B0", urlencode_param);
    const urlencode_unknown = try expander.expandFragment("Page", "{{urlencode:a b/c*|not-a-mode}}", 1_670_803_200);
    try std.testing.expectEqualStrings("a+b%2Fc%2A", urlencode_unknown);
    const urlencode_path = try expander.expandFragment("Page", "{{urlencode:a b/c*|PATH}}", 1_670_803_200);
    try std.testing.expectEqualStrings("a%20b%2Fc%2A", urlencode_path);
    const inert_hash_urlencode = try expander.expandFragment("Page", "{{#urlencode:जलाना|PATH}}", 1_670_803_200);
    try std.testing.expectEqualStrings("<nowiki>{{#urlencode:जलाना|PATH}}</nowiki>", inert_hash_urlencode);
    const inert_empty_template = try expander.expandFragment("Page", "{{|yue|洛陽}}", 1_670_803_200);
    try std.testing.expectEqualStrings("<nowiki>{{|yue|洛陽}}</nowiki>", inert_empty_template);
    const lazy_unused = try expander.expandFragment("Caller page", "{{Lazy|used={{PAGENAME}}|unused={{User:Definitely missing page}}}}", 1_670_803_200);
    try std.testing.expectEqualStrings("used=Caller page", lazy_unused);
    const lazy_forwarded = try expander.expandFragment("Caller page", "{{LazyForward|value|{{User:Definitely missing page}}}}", 1_670_803_200);
    try std.testing.expectEqualStrings("used=value", lazy_forwarded);
    const lazy_then_next = try expander.expandFragment(
        "Caller page",
        "{{Lazy|used=ok|unused={{User:Definitely missing page}}}}{{Hello|Bob|1}}",
        1_670_803_200,
    );
    try std.testing.expectEqualStrings("used=okHi Bob Y", lazy_then_next);
    try std.testing.expectEqual(@as(usize, 0), expander.lazy_template_args.items.len);
    try std.testing.expectEqualStrings(
        "used=[[:User:Definitely missing page]]",
        try expander.expandFragment("Caller page", "{{Lazy|used={{User:Definitely missing page}}}}", 1_670_803_200),
    );
    const missing_template = try expander.expandFragment("Page", "{{Definitely missing template xyzzy 12345|x=y}}", 1_670_803_200);
    try std.testing.expectEqualStrings("[[:Template:Definitely missing template xyzzy 12345]]", missing_template);
    for ([_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "{{User:Definitely missing page}}", .expected = "[[:User:Definitely missing page]]" },
        .{ .source = "{{:Definitely missing article}}", .expected = "[[:Definitely missing article]]" },
        .{ .source = "{{Category:Definitely missing category}}", .expected = "[[:Category:Definitely missing category]]" },
        .{ .source = "{{Talk:Definitely_missing_page}}", .expected = "[[:Talk:Definitely missing page]]" },
    }) |case| {
        try std.testing.expectEqualStrings(case.expected, try expander.expandFragment("Page", case.source, 1_670_803_200));
    }
    const special_page = try expander.expandFragment("Page", "{{#special:MovePage}}|{{#special:AllPages/Foo bar}}", 1_670_803_200);
    try std.testing.expectEqualStrings("Special:MovePage|Special:AllPages/Foo bar", special_page);
    const category_tree = try expander.expandFragment(
        "Page",
        "{{#categorytree:English terms prefixed with un-|type=pages|depth=1|namespaces=-|hideprefix=always|hideroot=off|showcount=on}}",
        1_670_803_200,
    );
    try std.testing.expect(std.mem.indexOf(u8, category_tree, "[[:Category:English terms prefixed with un-|English terms prefixed with un-]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, category_tree, "(4)") != null);
    try std.testing.expect(std.mem.indexOf(u8, category_tree, "[[alpha]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, category_tree, "[[beta]]") != null);
    const category_tree_pages = try expander.expandFragment(
        "Page",
        "{{#categorytree:English terms prefixed with un-|mode=pages|showcount=on}}",
        1_670_803_200,
    );
    try std.testing.expect(std.mem.indexOf(u8, category_tree_pages, "(4)") != null);
    try std.testing.expect(std.mem.indexOf(u8, category_tree_pages, "[[Talk:beta]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, category_tree_pages, "[[:Category:Child|Child]] <span class=\"CategoryTreeCount\">(0)</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, category_tree_pages, "[[:Category:Child|Child]]").? < std.mem.indexOf(u8, category_tree_pages, "[[alpha]]").?);
    const category_tree_default = try expander.expandFragment(
        "Page",
        "{{#categorytree:English terms prefixed with un-|depth=0|showcount=on}}",
        1_670_803_200,
    );
    try std.testing.expect(std.mem.indexOf(u8, category_tree_default, "(1)") != null);
    const category_tree_root = try expander.expandFragment(
        "Page",
        "{{#categorytree:English terms prefixed with un-|mode=all|depth=0|class=\"columns-bg\"|hideprefix=always|showcount=on}}",
        1_670_803_200,
    );
    const category_tree_root_quoted_namespace = try expander.expandFragment(
        "Page",
        "{{#categorytree:English terms prefixed with un-|namespaces=\"-\"|depth=0|class=\"derivedterms\"}}",
        1_670_803_200,
    );
    const category_tree_missing = try expander.expandFragment(
        "Page",
        "{{#categorytree:Definitely missing category xyzzy 12345|namespaces=\"-\"|depth=0|class=\"derivedterms\"}}",
        1_670_803_200,
    );
    const category_tree_empty = try expander.expandFragment(
        "Page",
        "{{#categorytree:Empty category|mode=pages|depth=0|showcount=on}}",
        1_670_803_200,
    );
    try std.testing.expect(std.mem.indexOf(u8, category_tree_empty, "CategoryTreeEmptyBullet") != null);
    try std.testing.expect(std.mem.indexOf(u8, category_tree_empty, "(0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, category_tree_empty, "not found") == null);
    const category_tree_missing_pages = try expander.expandFragment(
        "Page",
        "{{#categorytree:Definitely missing category xyzzy 12345|mode=pages}}",
        1_670_803_200,
    );
    try std.testing.expect(std.mem.indexOf(u8, category_tree_missing_pages, "CategoryTreeNotice") != null);
    try std.testing.expect(std.mem.indexOf(u8, category_tree_missing_pages, "not found") != null);
    try std.testing.expectEqualStrings(
        "<div class=\"derivedterms CategoryTreeTag\" data-ct-options=\"{&quot;mode&quot;:&quot;pages&quot;,&quot;hideprefix&quot;:&quot;categories&quot;,&quot;showcount&quot;:false,&quot;namespaces&quot;:[0],&quot;notranslations&quot;:false}\"><span class=\"CategoryTreeNotice\">Category <i>Definitely missing category xyzzy 12345</i> not found</span></div>",
        category_tree_missing,
    );
    try std.testing.expect(std.mem.indexOf(u8, category_tree_root_quoted_namespace, "class=\"derivedterms CategoryTreeTag\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, category_tree_root, "class=\"columns-bg CategoryTreeTag\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, category_tree_root, "[[:Category:English terms prefixed with un-|English terms prefixed with un-]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, category_tree_root, "<span class=\"CategoryTreeCount\">(4)</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, category_tree_root, "style=\"display:none\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, category_tree_root, "[[alpha]]") == null);
    const category_tree_prefixsee = try expander.expandFragment(
        "Page",
        "{{#categorytree:English terms prefixed with un-|type=pages|depth=1|class=\"columns-bg term-list Latn\"|style=counter-reset: pagesleftover 0|namespaces=-|data-pages-in-cat=3|data-pages-left-over=0}}",
        1_670_803_200,
    );
    try std.testing.expect(std.mem.indexOf(u8, category_tree_prefixsee, "class=\"columns-bg term-list Latn CategoryTreeTag\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, category_tree_prefixsee, "data-pages-in-cat=\"3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, category_tree_prefixsee, "data-pages-left-over=\"0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, category_tree_prefixsee, "style=\"counter-reset: pagesleftover 0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, category_tree_prefixsee, "CategoryTreeCount") == null);
    try std.testing.expect(std.mem.indexOf(u8, category_tree_prefixsee, "[[alpha]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, category_tree_prefixsee, "[[beta]]") != null);
    const dynamic_page_list = try expander.expandFragment(
        "Page",
        "{{#tag:DynamicPageList|category=Tea room\ncount=100\nmode=none\norder=ascending}}",
        1_670_803_200,
    );
    try std.testing.expectEqualStrings(
        "<dynamicpagelist>category=Tea room\ncount=100\nmode=none\norder=ascending</dynamicpagelist>",
        dynamic_page_list,
    );
    const other_magic = try expander.expandFragment("Page", "{{PAGEID:Other_page}}|{{REVISIONID:Other page}}|{{REVISIONTIMESTAMP:Other page}}|{{REVISIONUSER:Other_page}}|{{PAGEID:Missing page}}", 1_670_803_200);
    try std.testing.expectEqualStrings("99|990|20250607080910|Other editor|", other_magic);
    const got = try expander.expandFragment("Appendix:Page/Sub", source, 1_670_803_200);
    try std.testing.expectEqualStrings("Hi Bob Y|ABCD|space-template|space-template|main-transclusion|project-transclusion|Hi Z Y|yes|yes|14|E|W|HÉ|øøé|2022|<ref name=\"n\">body</ref>|<math>x+y</math>|<poem>one\ntwo</poem>|ok", got);
    const random_top_level = try expander.expandFragment("Page", "{{#invoke:Test|random}}|{{#invoke:Test|random}}", 1_670_803_200);
    try std.testing.expectEqualStrings("9|9", random_top_level);
    const isolated_module_state = try expander.expandFragment("Page", "{{#invoke:Test|stateful}}|{{#invoke:Test|stateful}}", 1_670_803_200);
    try std.testing.expectEqualStrings("1|1", isolated_module_state);
    const nested_invoke_wikitext = try expander.expandFragment("Page", "{{#invoke:Test|nested}}", 1_670_803_200);
    try std.testing.expectEqualStrings("<ref>Hi R Y</ref>", nested_invoke_wikitext);

    const display_body = try expander.expandFragment("Page", "{{DISPLAYTITLE:''Page''}}body", 1_670_803_200);
    try std.testing.expectEqualStrings("body", display_body);
    try std.testing.expectEqualStrings("''Page''", expander.display_title.?);
    const display_override = try expander.expandFragment("Page", "{{DISPLAYTITLE:''Page''}}{{DISPLAYTITLE:<b>Page</b>}}", 1_670_803_200);
    try std.testing.expect(std.mem.indexOf(u8, display_override, "Display title overrides earlier display title") != null);
    try std.testing.expectEqualStrings("<b>Page</b>", expander.display_title.?);

    expander.beginPage("Page", "source", 1_670_803_200);
    const caller_args = try runtime.newTable();
    const caller = try frame_lib.makeFrameFromTable(&runtime, "Module:Caller", caller_args, null);
    runtime.current_frame = caller.table;
    defer runtime.current_frame = null;
    const parser = try runtime.getIndex(caller, .{ .string = "callParserFunction" });
    const invoke_args = try runtime.newTable();
    try invoke_args.rawSet(runtime.allocator, .{ .number = 1 }, .{ .string = "Test" });
    try invoke_args.rawSet(runtime.allocator, .{ .number = 2 }, .{ .string = "run" });
    try invoke_args.rawSet(runtime.allocator, .{ .string = "x" }, .{ .string = "frame-parser" });
    const invoke_spec = try runtime.newTable();
    try invoke_spec.rawSet(runtime.allocator, .{ .string = "name" }, .{ .string = "#invoke" });
    try invoke_spec.rawSet(runtime.allocator, .{ .string = "args" }, .{ .table = invoke_args });
    const frame_invoked = try runtime.callValue(parser, &.{ caller, .{ .table = invoke_spec } });
    defer rt.freeResults(frame_invoked);
    try std.testing.expectEqualStrings("frame-parser", frame_invoked[0].string);
    runtime.current_frame = null;

    const protected = try expander.expandFragment("Page", "<nowiki>{{Hello|Bob|1}}</nowiki>|{{Hello|A|}}", 1_670_803_200);
    try std.testing.expectEqualStrings("<nowiki>{{Hello|Bob|1}}</nowiki>|Hi A N", protected);
    expander.provider.interwiki_map = TestProvider.interwikiMap;
    const inert_interwiki = try expander.expandFragment("Page", "{{w:Numa Pompilius|King Numa}}", 1_670_803_200);
    try std.testing.expectEqualStrings("<nowiki>{{w:Numa Pompilius|King Numa}}</nowiki>", inert_interwiki);
    const relative_project = try expander.expandFragment("Wiktionary:Sandbox", "{{/Child}}", 1_670_803_200);
    try std.testing.expectEqualStrings("relative-project-child", relative_project);
    const relative_main = try expander.expandFragment("Page", "{{/Child}}", 1_670_803_200);
    try std.testing.expectEqualStrings("literal-template-slash-child", relative_main);
    const relative_nested = try expander.expandFragment("Page", "{{Parent}}", 1_670_803_200);
    try std.testing.expectEqualStrings("relative-template-child", relative_nested);
    const local_interwiki = try expander.expandFragment("Page", "{{self:Hello|A|1}}", 1_670_803_200);
    try std.testing.expectEqualStrings("Hi A Y", local_interwiki);
    try std.testing.expectError(
        error.ExternalInterwikiTransclusionUnsupported,
        expander.expandFragment("Page", "{{remote:Thing}}", 1_670_803_200),
    );
    const extension_bodies = try expander.expandFragment(
        "Page",
        "<math>{{Hello|M|1}}</math>|<syntaxhighlight>{{Hello|S|1}}</syntaxhighlight>|<ref>{{Hello|R|1}}</ref>|<poem>{{Hello|P|1}}</poem>",
        1_670_803_200,
    );
    try std.testing.expectEqualStrings(
        "<math>{{Hello|M|1}}</math>|<syntaxhighlight>{{Hello|S|1}}</syntaxhighlight>|<ref>Hi R Y</ref>|<poem>Hi P Y</poem>",
        extension_bodies,
    );
    try std.testing.expect(runtime.current_frame == null);
    var symbolic_expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists, .resolve_call_symbol = TestProvider.resolveCallSymbol, .get_template_symbol = TestProvider.getTemplateSymbol }, .install_scribunto = installTestInvoke };
    const symbolic = try symbolic_expander.expandFragment("Page", "{{PAGENAME}}|{{@template|Bob|1}}|{{#invoke:@module|@function|x=symbolic}}", 1_670_803_200);
    try std.testing.expectEqualStrings("Page|Hi Bob Y|symbolic", symbolic);
    const repaired_invoke = try expander.expandFragment("Page", "{{#invoke:Test|repair|x=term&lt;t:gloss&gt;}}", 1_670_803_200);
    try std.testing.expectEqualStrings("repaired", repaired_invoke);
    const repaired_parent = try expander.expandFragment("Page", "{{RepairParent|x=term&lt;t:gloss&gt;}}", 1_670_803_200);
    try std.testing.expectEqualStrings("parent repaired", repaired_parent);
    const failed_invoke = try expander.expandFragment("Page", "{{#invoke:Test|fail}}", 1_670_803_200);
    try std.testing.expect(std.mem.indexOf(u8, failed_invoke, "class=\"scribunto-error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed_invoke, "Lua error in Module:Test: NotCallable") != null);
    try std.testing.expect(runtime.aotErrorName() == null);
    try std.testing.expect(runtime.last_error == .nil);
}

test "bundle title magic words resolve subject talk and parameterized namespaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 24);
    defer runtime.deinit();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists } };
    const source = "{{PAGENAME}}|{{FULLPAGENAME}}|{{NAMESPACE}}|{{NAMESPACENUMBER}}|{{BASEPAGENAME}}|{{ROOTPAGENAME}}|{{SUBPAGENAME}}|{{SUBJECTSPACE}}|{{TALKSPACE}}|{{SUBJECTPAGENAME}}|{{TALKPAGENAME}}|{{SUBJECTSPACE:Wiktionary talk:Foo}}|{{TALKSPACE:WT:Foo}}|{{TALKPAGENAME:Template:Foo}}|{{SUBJECTPAGENAME:Template talk:Foo}}";
    const got = try expander.expandFragment("Appendix:Page/Sub", source, 1_670_803_200);
    try std.testing.expectEqualStrings("Page/Sub|Appendix:Page/Sub|Appendix|100|Page|Page|Sub|Appendix|Appendix talk|Appendix:Page/Sub|Appendix talk:Page/Sub|Wiktionary|Wiktionary talk|Template talk:Foo|Template:Foo", got);
    const slash_semantics = try expander.expandFragment("foo/bar", "{{PAGENAME}}|{{BASEPAGENAME}}|{{ROOTPAGENAME}}|{{SUBPAGENAME}}|{{BASEPAGENAME:Template:foo/bar}}|{{BASEPAGENAME:Category:foo/bar}}", 1_670_803_200);
    try std.testing.expectEqualStrings("foo/bar|foo/bar|foo/bar|foo/bar|foo|foo/bar", slash_semantics);
    const escaped = try expander.expandFragment(
        "Appendix:A B/é?x",
        "{{PAGENAMEE}}|{{FULLPAGENAMEE}}|{{NAMESPACEE}}|{{BASEPAGENAMEE}}|{{ROOTPAGENAMEE}}|{{SUBPAGENAMEE}}|{{SUBJECTSPACEE}}|{{TALKSPACEE}}|{{SUBJECTPAGENAMEE}}|{{TALKPAGENAMEE}}|{{ARTICLESPACEE}}|{{ARTICLEPAGENAMEE}}",
        1_670_803_200,
    );
    try std.testing.expectEqualStrings("A_B/%C3%A9%3Fx|Appendix:A_B/%C3%A9%3Fx|Appendix|A_B|A_B|%C3%A9%3Fx|Appendix|Appendix_talk|Appendix:A_B/%C3%A9%3Fx|Appendix_talk:A_B/%C3%A9%3Fx|Appendix|Appendix:A_B/%C3%A9%3Fx", escaped);
}

test "bundle parser functions cover corpus time date sub and iferror forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 24);
    defer runtime.deinit();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists, .page_metadata = TestProvider.pageMetadata } };
    const source = "{{#time:Y M d|2013-3-31 +8 days}}|{{#time:/Y/F|2025-9}}|{{#formatdate:2010-01-02|dmy}}|{{#dateformat:January 2|dmy}}|{{#formatdate:2-Jan-2010|dmy}}|{{#len:é猫}}|{{#sub:αβγ|-1}}|{{#sub:αβγ|0|-1}}|{{#iferror:{{#expr:bogus}}|ERR|OK}}|{{#iferror:plain|ERR|OK}}|{{#ifeq:01|1|NUM|BAD}}|{{#ifeq:+1.0|1|FLOAT|BAD}}|{{#ifeq:01x|1|BAD|TEXT}}|{{#ifeq:9007199254740993|9007199254740992|BAD|BIG}}|{{formatnum:11000}}|{{FORMATNUM:-1234567.89}}|{{formatnum:1,234.50|R}}|{{formatnum:1234.50|NOSEP}}|{{anchorencode:[[foo|A B]] <b>x</b>&nbsp;C}}|{{anchorencode:a%20b}}|{{ucfirst:ßeta}}|{{ucfirst:ǰfoo}}|{{lcfirst:Éclair}}|{{ns:0}}/{{ns:4}}/{{ns:Project}}/{{ns:MOD}}";
    const got = try expander.expandFragment("Page", source, 1_670_803_200);
    try std.testing.expectEqualStrings("2013 Apr 08|/2025/September|<span class=\"mw-formatted-date\" title=\"2010-01-02\">2 January 2010</span>|<span class=\"mw-formatted-date\" title=\"01-02\">2 January</span>|2-Jan-2010|2|γ|αβ|ERR|OK|NUM|FLOAT|TEXT|BIG|11,000|−1,234,567.89|1234.50|1234.50|A_B_x_C|a%2520b|ßeta|J̌foo|éclair|/Wiktionary/Wiktionary/Module", got);
    const plural = try expander.expandFragment(
        "Page",
        "{{PLURAL:0|one|many}}|{{PLURAL:1|one|many}}|{{plural:2|one|many}}|{{PLURAL:-1|one|many}}|{{PLURAL:1.0|one|many}}|{{PLURAL:1,000|one|many}}|{{PLURAL:bogus|one|many}}|{{PLURAL:10|10=ten|one|many}}|{{PLURAL:2|0=zero|1=one|many}}|{{PLURAL:1|only}}|{{PLURAL:1|ok|{{Missing}}}}",
        1_670_803_200,
    );
    try std.testing.expectEqualStrings("many|one|many|one|one|many|many|ten|many|only|ok", plural);
    const empty_expr = try expander.expandFragment("Page", "{{#expr:}}|{{#expr:   }}|{{#ifexpr:|YES|NO}}|{{#ifexpr:   |YES|NO}}", 1_670_803_200);
    try std.testing.expectEqualStrings("||NO|NO", empty_expr);
    const trimmed = try expander.expandFragment(
        "Page",
        "{{#if:1| X | Y }}|{{#ifeq:a|a| X | Y }}|{{#ifexist:Exists| X | Y }}|{{#ifexpr:1| X | Y }}|{{#iferror:plain| X | Y }}|{{#switch:x|x= X |#default= Y }}|https://{{#if:1|\n  example.test\n|\n  invalid.test\n}}|{{#if:1| <!--comment--> X |Y}}",
        1_670_803_200,
    );
    try std.testing.expectEqualStrings("X|X|X|X|Y|X|https://example.test|X", trimmed);
    const grouped_switch = try expander.expandFragment(
        "Page",
        "{{#switch:V|L|W = 2014|P|X = p. 2011}}|{{#switch:W|L|W = 2014|P|X = p. 2011}}|{{#switch:L|L|W = 2014|P|X = p. 2011}}",
        1_670_803_200,
    );
    try std.testing.expectEqualStrings("|2014|2014", grouped_switch);
    const lazy_dynamic_switch = try expander.expandFragment(
        "Page",
        "{{#switch:|f|m|n|c|s|p|mf|nm=&nbsp;{{{{{5}}}|x}}}}",
        1_670_803_200,
    );
    try std.testing.expectEqualStrings("", lazy_dynamic_switch);
    const dynamic_template_name = try expander.expandFragment("Page", "{{{{{name|Hello}}}|Bob}}", 1_670_803_200);
    try std.testing.expectEqualStrings("Hi Bob N", dynamic_template_name);
    const dynamic_parser_head = try expander.expandFragment("Page", "{{{{{name|ucfirst}}}:man}}", 1_670_803_200);
    try std.testing.expectEqualStrings("Man", dynamic_parser_head);
    const dynamic_safesubst_parser = try expander.expandFragment("Page", "{{{{{|safesubst:}}}ucfirst:man}}", 1_670_803_200);
    try std.testing.expectEqualStrings("Man", dynamic_safesubst_parser);
    const malformed_parameter_like = try expander.expandFragment("Page", "A{{{1}|}}B", 1_670_803_200);
    try std.testing.expectEqualStrings("A{{{1}|}}B", malformed_parameter_like);
    const invalid_template_title = try expander.expandFragment("Page", "{{tetřev<m.an.nompli:ové> hlušec<m.an>}}", 1_670_803_200);
    try std.testing.expectEqualStrings("<nowiki>{{tetřev<m.an.nompli:ové> hlušec<m.an>}}</nowiki>", invalid_template_title);
    const malformed_switch = try expander.expandFragment("Page", "{{#switch:{{{1}|}}|=|-=|BAD|#default=Y}}", 1_670_803_200);
    try std.testing.expectEqualStrings("Y", malformed_switch);
    try std.testing.expectError(error.InvalidNamespace, expander.expandFragment("Page", "{{ns:not-a-namespace}}", 1_670_803_200));

    expander.beginPage("Page", "source", 1_670_803_200);
    const frame_args = try runtime.newTable();
    const frame = try frame_lib.makeFrameFromTable(&runtime, "Template:Host", frame_args, null);
    const parser = try runtime.getIndex(frame, .{ .string = "callParserFunction" });
    const dated = try runtime.callValue(parser, &.{ frame, .{ .string = "#time" }, .{ .string = "Y-m-d" }, .{ .string = "2023-4-2 +8 days" } });
    defer rt.freeResults(dated);
    try std.testing.expectEqualStrings("2023-04-10", dated[0].string);
}

test "bundle titleparts matches MediaWiki segment slicing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 24);
    defer runtime.deinit();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists } };
    const got = try expander.expandFragment("Page", "{{#titleparts:A/B/C|1}}|{{#titleparts:A/B/C|1|2}}|{{#titleparts:A/B/C|2|1}}|{{#titleparts:A/B/C|-1}}|{{#titleparts:A/B/C|1|-1}}|{{#titleparts:A/B/C|0|2}}|{{#titleparts:A/B/C|2|-2}}|{{#titleparts:A//C|3|1}}", 1_670_803_200);
    try std.testing.expectEqualStrings("A|B|A/B|A/B|C|B/C|B/C|A//C", got);
}

test "missing bundle interwiki metadata fails explicitly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 24);
    defer runtime.deinit();
    var expander = Expander{
        .runtime = &runtime,
        .env_slot = 0,
        .string_slot = 18,
        .mw_slot = 23,
        .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists },
    };
    try std.testing.expectError(error.NotImplemented, Expander.hostSiteInterwikiMap(&expander));
}

test "parser nesting budget is independent from template recursion budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 24);
    defer runtime.deinit();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var expander = Expander{
        .runtime = &runtime,
        .env_slot = 0,
        .string_slot = 18,
        .mw_slot = 23,
        .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists },
        .install_scribunto = installTestInvoke,
    };

    var nested: std.ArrayList(u8) = .empty;
    defer nested.deinit(std.testing.allocator);
    for (0..60) |_| try nested.appendSlice(std.testing.allocator, "{{#if:1|");
    try nested.appendSlice(std.testing.allocator, "ok");
    for (0..60) |_| try nested.appendSlice(std.testing.allocator, "}}");
    try std.testing.expectEqualStrings("ok", try expander.expandFragment("Page", nested.items, 1_670_803_200));

    try std.testing.expectError(error.TemplateDepth, expander.expandFragment("Page", "{{Loop}}", 1_670_803_200));
}

test "plain pages defer Scribunto installation until mw is required" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 24);
    defer runtime.deinit();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    ScribuntoInstallProbe.calls.store(0, .monotonic);
    var expander = Expander{
        .runtime = &runtime,
        .env_slot = 0,
        .string_slot = 18,
        .mw_slot = 23,
        .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists },
        .install_scribunto = ScribuntoInstallProbe.install,
    };

    try std.testing.expectEqualStrings("plain", try expander.expandFragment("Page", "plain", 1_670_803_200));
    try std.testing.expectEqual(@as(usize, 0), ScribuntoInstallProbe.calls.load(.monotonic));
    try std.testing.expectEqualStrings("HÉ", try expander.expandFragment("Page", "{{uc:hé}}", 1_670_803_200));
    try std.testing.expectEqual(@as(usize, 1), ScribuntoInstallProbe.calls.load(.monotonic));
}

test "native AOT page boundary resets shared Scribunto state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 24);
    defer runtime.deinit();
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists } };
    var marker: u8 = 0;
    expander.scribunto_state = @ptrCast(&marker);
    expander.beginPage("Page", "source", 1_670_803_200);
    try std.testing.expect(expander.scribunto_state == null);
}

test "native AOT frame callbacks recurse through the same page expander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 24);
    defer runtime.deinit();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists } };
    expander.beginPage("Page", "source", 1_670_803_200);
    const frame_args = try runtime.newTable();
    try frame_args.rawSet(runtime.allocator, .{ .string = "x" }, .{ .string = "Z" });
    const frame = try frame_lib.makeFrameFromTable(&runtime, "Template:Host", frame_args, null);
    const preprocess_fn = try runtime.getIndex(frame, .{ .string = "preprocess" });
    const pre = try runtime.callValue(preprocess_fn, &.{ frame, .{ .string = "{{{x}}}-{{Hello|A|}}" } });
    defer rt.freeResults(pre);
    try std.testing.expectEqualStrings("Z-Hi A N", pre[0].string);
    const protected_pre = try runtime.callValue(preprocess_fn, &.{ frame, .{ .string = "<nowiki>{{Hello|A|1}}</nowiki>|{{Hello|B|}}" } });
    defer rt.freeResults(protected_pre);
    try std.testing.expectEqualStrings("<nowiki>{{Hello|A|1}}</nowiki>|Hi B N", protected_pre[0].string);
    const commented_pre = try runtime.callValue(preprocess_fn, &.{ frame, .{ .string = "A<!-- {{Hello|X|1}} -->B{{Hello|C|}}" } });
    defer rt.freeResults(commented_pre);
    try std.testing.expectEqualStrings("ABHi C N", commented_pre[0].string);
    const parser = try runtime.getIndex(frame, .{ .string = "callParserFunction" });
    expander.provider.page_metadata = TestProvider.pageMetadata;
    const revision_user = try runtime.callValue(parser, &.{ frame, .{ .string = "REVISIONUSER" }, .{ .string = "Other_page" } });
    defer rt.freeResults(revision_user);
    try std.testing.expectEqualStrings("Other editor", revision_user[0].string);
    const date = try runtime.callValue(parser, &.{ frame, .{ .string = "#formatdate" }, .{ .string = "2022-12-12" }, .{ .string = " dmy " } });
    defer rt.freeResults(date);
    try std.testing.expectEqualStrings("<span class=\"mw-formatted-date\" title=\"2022-12-12\">12 December 2022</span>", date[0].string);
    const invalid_date = try runtime.callValue(parser, &.{ frame, .{ .string = "#dateformat" }, .{ .string = "12-December-2022" }, .{ .string = "dmy" } });
    defer rt.freeResults(invalid_date);
    try std.testing.expectEqualStrings("12-December-2022", invalid_date[0].string);

    const syntax_args = try runtime.newTable();
    try syntax_args.rawSet(runtime.allocator, .{ .number = 1 }, .{ .string = "x" });
    try syntax_args.rawSet(runtime.allocator, .{ .string = "lang" }, .{ .string = "text" });
    const syntax_spec = try runtime.newTable();
    try syntax_spec.rawSet(runtime.allocator, .{ .string = "name" }, .{ .string = "#tag:syntaxhighlight" });
    try syntax_spec.rawSet(runtime.allocator, .{ .string = "args" }, .{ .table = syntax_args });
    const syntax = try runtime.callValue(parser, &.{ frame, .{ .table = syntax_spec } });
    defer rt.freeResults(syntax);
    try std.testing.expectEqualStrings("<syntaxhighlight lang=\"text\">x</syntaxhighlight>", syntax[0].string);

    const ref_args = try runtime.newTable();
    try ref_args.rawSet(runtime.allocator, .{ .number = 1 }, .{ .string = "ref" });
    try ref_args.rawSet(runtime.allocator, .{ .number = 2 }, .{ .string = "body" });
    try ref_args.rawSet(runtime.allocator, .{ .number = 3 }, .{ .string = "name=n" });
    const ref_spec = try runtime.newTable();
    try ref_spec.rawSet(runtime.allocator, .{ .string = "name" }, .{ .string = "#tag" });
    try ref_spec.rawSet(runtime.allocator, .{ .string = "args" }, .{ .table = ref_args });
    const ref = try runtime.callValue(parser, &.{ frame, .{ .table = ref_spec } });
    defer rt.freeResults(ref);
    try std.testing.expectEqualStrings("<ref name=\"n\">body</ref>", ref[0].string);
}

test "native AOT nowiki strip markers share page host state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 24);
    defer runtime.deinit();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists } };

    const page = try expander.expandFragment("Page", "=Heading=\nplain", 1_670_803_200);
    try std.testing.expectEqualStrings("=Heading=\nplain", page);
    try std.testing.expectEqual(@as(usize, 1), expander.page_heading_count);

    const frame_args = try runtime.newTable();
    const frame = try frame_lib.makeFrameFromTable(&runtime, "Module:Probe", frame_args, null);
    const extension_tag = try runtime.getIndex(frame, .{ .string = "extensionTag" });
    const marker = try runtime.callValue(extension_tag, &.{ frame, .{ .string = "nowiki" }, .{ .string = "HEADING\x011" } });
    defer rt.freeResults(marker);
    try std.testing.expectEqualStrings("\x7f'\"`UNIQ--nowiki-00000000-QINU`\"'\x7f", marker[0].string);

    const preprocess_fn = try runtime.getIndex(frame, .{ .string = "preprocess" });
    const heading_source = try std.fmt.allocPrint(arena.allocator(), "={s}=", .{marker[0].string});
    const heading = try runtime.callValue(preprocess_fn, &.{ frame, .{ .string = heading_source } });
    defer rt.freeResults(heading);
    try std.testing.expectEqualStrings("\x7f'\"`UNIQ--h-1--QINU`\"'\x7f", heading[0].string);

    const mw = runtime.getGlobal(23);
    const text = try runtime.getIndex(mw, .{ .string = "text" });
    const unstrip_no_wiki = try runtime.getIndex(text, .{ .string = "unstripNoWiki" });
    const restored_no_wiki = try runtime.callValue(unstrip_no_wiki, &.{marker[0]});
    defer rt.freeResults(restored_no_wiki);
    try std.testing.expectEqualStrings("HEADING\x011", restored_no_wiki[0].string);
    const unstrip = try runtime.getIndex(text, .{ .string = "unstrip" });
    const restored = try runtime.callValue(unstrip, &.{marker[0]});
    defer rt.freeResults(restored);
    try std.testing.expectEqualStrings("HEADING\x011", restored[0].string);
    try std.testing.expectError(error.AotCallFailed, runtime.callValue(unstrip, &.{.{ .string = "x\x7fy" }}));
    try std.testing.expectEqualStrings("NotImplemented", runtime.aotErrorName().?);
    runtime.clearAotErrorName();
}
