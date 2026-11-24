const std = @import("std");
const dependency = @import("missing_dependency");
const string_origin = @import("string_origin.zig");
// Provenance allocations must remain operational even through Lua pcall/frame
// APIs. Preserve the exact original error set and latch before returning it.
fn originResult(result: anytype) @TypeOf(result) {
    return result catch |err| {
        rt.string_origins.noteFailure(err);
        return err;
    };
}
const shared_xml_decode = @import("shared_xml_decode");
const LocalBumpArena = rt.LocalBumpArena;
const work_stats = rt.work_stats;
const rt = @import("zig_runtime");
const host_api = @import("host.zig");
const frame_lib = @import("frame.zig");
const invoke_reuse_stats = @import("invoke_reuse_stats.zig");
const InvokeReuseStats = invoke_reuse_stats.Stats;
const namespace_lib = @import("namespaces.zig");
const preprocess = @import("lua_wikitext_preprocess");
const parser_expr = @import("lua_wikitext_expression");
const language_lib = @import("language.zig");
const plural_rules = @import("plural_rules.zig");
const dateformat_lib = @import("dateformat.zig");
const uri_lib = @import("uri.zig");
const ustring_lib = @import("ustring.zig");
const text_lib = @import("text.zig");
const title_lib = @import("title.zig");
const message_lib = @import("mw_basics.zig");
const stdlib = @import("zig_stdlib");
const Value = rt.Value;

const nowiki_marker_prefix = "\x7f'\"`UNIQ--nowiki-";
const nowiki_marker_suffix = "-QINU`\"'\x7f";

const hiero_marker_prefix = "\x7f'\"`UNIQ--hiero-";
const isbn_marker_prefix = "\x7f'\"`UNIQ--isbn-";
const generated_link = dependency.generated_link;
const StripValue = struct {
    kind: enum { nowiki, hiero, isbn },
    text: []const u8,
};

fn makeNowikiMarker(a: std.mem.Allocator, id: u32) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}{X:0>8}{s}", .{ nowiki_marker_prefix, id, nowiki_marker_suffix });
}

// CoreParserFunctions::tagObj trims expanded #tag values, then removes
// syntactic outer quotes. Nonempty mixed quote pairs are accepted upstream.
// frame:extensionTag supplies literal API values and must not use this adapter.
fn parserTagAttributeValue(raw: []const u8) []const u8 {
    const value = std.mem.trim(u8, raw, " \t\n\r\x00\x0b");
    if (value.len < 2) return value;
    const first = value[0];
    const last = value[value.len - 1];
    const quoted = (first == '"' or first == '\'') and (last == '"' or last == '\'');
    if (quoted and (value.len > 2 or first == last)) return value[1 .. value.len - 1];
    return value;
}

fn canonicalExtensionTag(raw: []const u8) ?[]const u8 {
    inline for (&.{
        "nowiki",  "pre",      "gallery",      "indicator",       "ref",             "references", "templatestyles",
        "math",    "ce",       "chem",         "score",           "syntaxhighlight", "source",     "timeline",
        "hiero",   "poem",     "categorytree", "charinsert",      "graph",           "mapframe",   "maplink",
        "section", "inputbox", "imagemap",     "dynamicpagelist", "phonos",
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
    pub const DateNumbering = host_api.DateNumbering;
    pub const LanguageNameRow = host_api.LanguageNameRow;
    pub const LanguageNameScope = host_api.LanguageNameScope;
    pub const LanguageDirection = host_api.LanguageDirection;
    pub const normalizeInterfaceMessageKeyAlloc = host_api.normalizeInterfaceMessageKeyAlloc;
    pub const FileMetadata = host_api.FileMetadata;
    pub const InterwikiRow = host_api.InterwikiRow;
    pub const WikibaseEntityText = host_api.WikibaseEntityText;
    pub const WikibaseEntity = host_api.WikibaseEntity;
    pub const WikibaseTerm = host_api.WikibaseTerm;
    pub const WikibaseEntityTerms = host_api.WikibaseEntityTerms;
    pub const SymbolKind = CallSymbolKind;
    pub const Symbol = CallSymbol;
    pub const PageMetadata = host_api.PageMetadata;
    pub const CurrentPage = host_api.CurrentPage;
    // Formatting follows the root parser's target language, never the PAGESIZE
    // operand or a transcluded template title. Unknown contexts remain unknown.
    pub const PageSizeFormatContext = struct {
        title: []const u8 = "",
        source: []const u8 = "",
        current: ?CurrentPage = null,
        normal_no_target: bool = false,
        interface_message: ?bool = null,
        target_language_override: ?[]const u8 = null,
        variant_override: ?[]const u8 = null,
    };
    pub const RedirectTarget = host_api.RedirectTarget;
    pub const TransclusionBody = struct {
        text: []const u8,
        title: []const u8,
        borrowed: bool,
    };
    ctx: ?*anyopaque = null,
    get: *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!?[]const u8,
    get_transclusion: ?*const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!?[]const u8 = null,
    get_transclusion_body: ?*const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!?TransclusionBody = null,
    redirect_target: ?*const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!?[]const u8 = null,
    page_metadata: ?*const fn (?*anyopaque, []const u8) anyerror!?PageMetadata = null,
    stable_page_reads: bool = false,
    // Dump providers own the full revision, even when this expansion contains
    // only a redirect's remaining content. Generic source-only hosts opt out.
    authoritative_page_source: bool = false,
    exists: *const fn (?*anyopaque, []const u8) anyerror!bool,
    external_data: ?*const fn (?*anyopaque, []const u8) anyerror!?ExternalData = null,
    category_stats: ?*const fn (?*anyopaque, []const u8) anyerror!?CategoryStats = null,
    category_statistics_formatted: ?*const fn (?*anyopaque, u32) anyerror!?[]const u8 = null,
    interface_message: ?*const fn (?*anyopaque, std.mem.Allocator, []const u8, []const u8) anyerror!?InterfaceMessage = null,
    file_metadata: ?*const fn (?*anyopaque, []const u8) anyerror!FileMetadata = null,
    file_path: ?*const fn (?*anyopaque, []const u8, []const u8) anyerror![]const u8 = null,
    page_size: ?*const fn (?*anyopaque, []const u8) anyerror!u64 = null,
    page_size_formatted: ?*const fn (?*anyopaque, std.mem.Allocator, u64, PageSizeFormatContext) anyerror![]const u8 = null,
    category_tree: ?*const fn (?*anyopaque, std.mem.Allocator, []const u8, CategoryTreeScope) anyerror![]const []const u8 = null,
    /// Optional scoped variant. All returned data belongs to the supplied call arena.
    category_tree_scoped: ?*const fn (?*anyopaque, std.mem.Allocator, []const u8, CategoryTreeScope) anyerror![]const []const u8 = null,
    site_server: ?[]const u8 = null,
    // pages, articles, files, edits, users, activeUsers, admins; exact Lua integers.
    site_statistics: ?[7]u53 = null,
    // Exact ordinary-format observations for these same pinned raw counts.
    site_statistics_formatted: ?[7][]const u8 = null,
    site_script: ?[]const u8 = null,
    site_article_path: ?[]const u8 = null,
    language_conversion_enabled: ?bool = null,
    interwiki_map: ?*const fn (?*anyopaque) anyerror![]const InterwikiRow = null,
    stable_interwiki_map: bool = false,
    wikibase_sitelink: ?*const fn (?*anyopaque, []const u8, []const u8) anyerror!?[]const u8 = null,
    wikibase_entity_text: ?*const fn (?*anyopaque, []const u8) anyerror!WikibaseEntityText = null,
    wikibase_entity: ?host_api.WikibaseEntityFn = null,
    wikibase_page_entity_id: ?host_api.WikibasePageEntityIdFn = null,
    wikibase_entity_terms: ?host_api.WikibaseEntityTermsFn = null,
    date_numbering: ?host_api.DateNumberingFn = null,
    language_fallbacks: ?host_api.LanguageFallbacksFn = null,
    language_names: ?host_api.LanguageNamesFn = null,
    language_name: ?host_api.LanguageNameFn = null,
    language_direction: ?host_api.LanguageDirectionFn = null,
    language_known_tag: ?*const fn (?*anyopaque, []const u8) anyerror!bool = null,
    language_supported: ?host_api.LanguageSupportedFn = null,
    // When present, the edition snapshot is authoritative, including nonmatches.
    resolve_title_magic: ?*const fn (?*anyopaque, []const u8, rt.namespace_registry.magic_words.Form) anyerror!?[]const u8 = null,
    raw_suffix_profile: bool = false,
    resolve_parser_function: ?*const fn (?*anyopaque, []const u8) anyerror!?[]const u8 = null,
    resolve_call_symbol: ?*const fn (?*anyopaque, *rt.Context, []const u8, CallSymbolKind) anyerror!?CallSymbol = null,
    get_template_symbol: ?*const fn (?*anyopaque, std.mem.Allocator, usize) anyerror!?[]const u8 = null,
};

const LazyTemplateArgs = struct {
    target: *rt.Table,
    raw_values: *rt.Table,
    named_numeric_keys: []const f64,
    caller_params: *rt.Table,
    caller_title: []const u8,
    caller_transclusion_frame: ?*const Expander.TransclusionFrame,
    depth: usize,
};

const poem_prefix = "\x7fWDPOEM:";
const max_poem_metadata_bytes = 16 * 1024 * 1024;
const PoemItem = struct {
    token: []const u8,
    kind: enum { br, space, indent, scope, literal },
    depth: ?u8 = null,
    tag: ?[]const u8 = null,
    body: ?[]const u8 = null,
    generated_links: []const generated_link.WireRange = &.{},
    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("token"); try jw.write(self.token);
        try jw.objectField("kind"); try jw.write(self.kind);
        if (self.depth) |value| { try jw.objectField("depth"); try jw.write(value); }
        if (self.tag) |value| { try jw.objectField("tag"); try jw.write(value); }
        if (self.body) |value| { try jw.objectField("body"); try jw.write(value); }
        if (self.generated_links.len != 0) { try jw.objectField("generated_links"); try jw.write(self.generated_links); }
        try jw.endObject();
    }
};
const PoemMetadata = struct {
    schema: []const u8 = "wikidict.poem-phase.v1",
    handled: bool = true,
    output_sha256: []const u8,
    display_title_sha256: []const u8,
    items: []const PoemItem,
    output_links: []const generated_link.WireRange = &.{},
    display_title_links: []const generated_link.WireRange = &.{},
    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        inline for (.{ "schema", "handled", "output_sha256", "display_title_sha256", "items" }) |name| {
            try jw.objectField(name); try jw.write(@field(self, name));
        }
        if (std.mem.eql(u8, self.schema, "wikidict.presentation-phase.v2")) {
            try jw.objectField("output_links"); try jw.write(self.output_links);
            try jw.objectField("display_title_links"); try jw.write(self.display_title_links);
        }
        try jw.endObject();
    }
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
    page_runtime: ?*rt.Context = null,
    hot_translation_runtime: ?*rt.Context = null,
    hot_translation_active: bool = false,
    page_invoke_runtime: ?*rt.Context = null,
    page_invoke_active: bool = false,
    page_template_eligible: []bool = &.{},
    page_template_rejected: []bool = &.{},
    base_template_eligible: []bool = &.{},
    base_template_rejected: []bool = &.{},
    invoke_reuse: ?*InvokeReuseStats = null,
    script_cpu_budget: rt.execution_budget.Budget = .{},
    host: host_api.Host = .{},
    current_source: ?[]const u8 = null,
    normal_page_format_context: bool = false,
    page_allocator: ?std.mem.Allocator = null,
    page_heading_count: usize = 0,
    fake_heading_count: usize = 0,
    display_title: ?[]const u8 = null,
    unsupported_parser_function: bool = false,
    poem_metadata: ?[]const u8 = null,
    missing_dependency_metadata: ?[]const u8 = null,
    dependency_page: dependency.Page = .{},
    dependency_display_title: dependency.Text = .{ .bytes = "" },
    dependency_arguments: std.ArrayList(DependencyArgument) = .empty,
    origin_ledger: ?*string_origin.Ledger = null,
    dependency_argument_bytes: usize = 0,
    dependency_native_arguments_disabled: bool = false,
    poem_handled_empty: bool = false,
    poem_items: std.ArrayList(PoemItem) = .empty,
    output_links: std.ArrayList(generated_link.WireRange) = .empty,
    display_title_links: std.ArrayList(generated_link.WireRange) = .empty,
    generated_link_counter: usize = 0,
    poem_literal_bytes: usize = 0,
    poem_argument_depth: usize = 0,
    poem_hook_depth: usize = 0,
    strip_counter: u32 = 0,
    strip_values: std.AutoHashMapUnmanaged(u32, StripValue) = .empty,
    page_line: std.ArrayList(u8) = .empty,
    max_depth: usize = 512,
    max_template_depth: usize = 128,
    template_depth: usize = 0,
    lazy_template_args: std.ArrayList(LazyTemplateArgs) = .empty,
    transclusion_frame: ?*const TransclusionFrame = null,
    usage_recovery: ?*UsageRecovery = null,
    const DependencyArgument = struct { target: *rt.Table, key: Value, cached_bytes: []const u8, value: dependency.Text };
    const UsageRecovery = struct {
        args: *rt.Table,
        exact_wrapper: bool = false,
        missing_display: bool = false,
    };

    pub fn attach(self: *Expander) void {
        self.host.ctx = self;
        self.host.page_exists = hostPageExists;
        self.host.page_content = hostPageContent;
        self.host.page_redirect = hostPageRedirect;
        self.host.page_id = hostPageId;
        self.host.page_content_model = hostPageContentModel;
        self.host.stable_page_reads = self.provider.stable_page_reads;
        self.host.frame_preprocess = hostFramePreprocess;
        self.host.frame_expand_template = hostFrameExpandTemplate;
        self.host.frame_extension_tag = hostFrameExtensionTag;
        self.host.frame_parser_function = hostFrameParserFunction;
        self.host.text_unstrip_no_wiki = hostTextUnstripNoWiki;
        self.host.external_data = hostExternalData;
        self.host.category_stats = hostCategoryStats;
        self.host.interface_message = if (self.provider.interface_message != null) hostInterfaceMessage else null;
        self.host.file_metadata = hostFileMetadata;
        self.host.site_server = self.provider.site_server;
        self.host.site_statistics = self.provider.site_statistics;
        self.host.site_script = self.provider.site_script;
        self.host.site_article_path = self.provider.site_article_path;
        self.host.site_interwiki_map = hostSiteInterwikiMap;
        self.host.stable_site_interwiki_map = self.provider.stable_interwiki_map;
        self.host.wikibase_sitelink = if (self.provider.wikibase_sitelink != null) hostWikibaseSitelink else null;
        self.host.wikibase_entity_text = if (self.provider.wikibase_entity_text != null) hostWikibaseEntityText else null;
        self.host.wikibase_entity = if (self.provider.wikibase_entity != null) hostWikibaseEntity else null;
        self.host.wikibase_page_entity_id = if (self.provider.wikibase_page_entity_id != null) hostWikibasePageEntityId else null;
        self.host.wikibase_entity_terms = if (self.provider.wikibase_entity_terms != null) hostWikibaseEntityTerms else null;
        self.host.date_numbering = if (self.provider.date_numbering != null) hostDateNumbering else null;
        self.host.language_fallbacks = if (self.provider.language_fallbacks != null) hostLanguageFallbacks else null;
        self.host.language_names = if (self.provider.language_names != null) hostLanguageNames else null;
        self.host.language_name = if (self.provider.language_name != null) hostLanguageName else null;
        self.host.language_direction = if (self.provider.language_direction != null) hostLanguageDirection else null;
        self.host.language_known_tag = hostLanguageKnownTag;
        self.host.language_supported = if (self.provider.language_supported != null) hostLanguageSupported else null;
        host_api.set(self.runtime, &self.host);
    }

    pub fn beginPage(self: *Expander, title: []const u8, source: []const u8, now_unix: ?i64) void {
        self.script_cpu_budget.reset();
        self.releasePageModuleTemplates();
        self.host.current_title = title;
        self.host.current_page = null;
        self.host.page_identity_failure = null;
        self.host.now_unix = now_unix;
        self.current_source = source;
        self.normal_page_format_context = false;
        self.page_allocator = self.runtime.allocator;
        self.page_runtime = self.runtime;
        self.scribunto_state = null;
        self.hot_translation_runtime = null;
        self.hot_translation_active = false;
        self.page_invoke_runtime = null;
        self.page_invoke_active = false;
        self.page_heading_count = 0;
        self.fake_heading_count = 0;
        self.display_title = null;
        self.unsupported_parser_function = false;
        self.poem_metadata = null;
        self.missing_dependency_metadata = null;
        self.dependency_page = .{};
        self.dependency_display_title = .{ .bytes = "" };
        self.dependency_arguments = .empty;
        self.origin_ledger = null;
        self.dependency_argument_bytes = 0;
        self.dependency_native_arguments_disabled = false;
        self.poem_handled_empty = false;
        self.poem_items = .empty;
        self.output_links = .empty;
        self.display_title_links = .empty;
        self.generated_link_counter = 0;
        self.poem_literal_bytes = 0;
        self.poem_argument_depth = 0;
        self.poem_hook_depth = 0;
        self.strip_counter = 0;
        self.strip_values = .empty;
        self.page_line = .empty;
        self.template_depth = 0;
        self.lazy_template_args = .empty;
        self.transclusion_frame = null;
        self.attach();
    }

    fn releasePageModuleTemplates(self: *Expander) void {
        if (self.page_template_eligible.len == 0 and
            self.page_template_rejected.len == 0)
            return;
        const a = self.page_allocator orelse self.runtime.allocator;
        self.runtime.module_template_eligible = self.base_template_eligible;
        self.runtime.module_template_rejected = self.base_template_rejected;
        if (self.page_template_eligible.len != 0)
            a.free(self.page_template_eligible);
        if (self.page_template_rejected.len != 0)
            a.free(self.page_template_rejected);
        self.page_template_eligible = &.{};
        self.page_template_rejected = &.{};
        self.base_template_eligible = &.{};
        self.base_template_rejected = &.{};
    }

    fn ensurePageModuleTemplates(self: *Expander) !void {
        if (self.page_template_eligible.len != 0) return;
        try self.ensureScribunto();
        const a = self.page_allocator orelse self.runtime.allocator;
        self.base_template_eligible = self.runtime.module_template_eligible;
        self.base_template_rejected = self.runtime.module_template_rejected;
        if (self.runtime.module_count == 0) return;
        self.page_template_eligible = if (self.base_template_eligible.len ==
            self.runtime.module_count)
            try a.dupe(bool, self.base_template_eligible)
        else blk: {
            if (self.base_template_eligible.len != 0)
                return error.BadModuleTemplateLayout;
            const values = try a.alloc(bool, self.runtime.module_count);
            @memset(values, false);
            break :blk values;
        };
        errdefer {
            a.free(self.page_template_eligible);
            self.page_template_eligible = &.{};
        }
        self.page_template_rejected = if (self.base_template_rejected.len ==
            self.runtime.module_count)
            try a.dupe(bool, self.base_template_rejected)
        else blk: {
            if (self.base_template_rejected.len != 0)
                return error.BadModuleTemplateLayout;
            const values = try a.alloc(bool, self.runtime.module_count);
            @memset(values, false);
            break :blk values;
        };
        self.runtime.module_template_eligible = self.page_template_eligible;
        self.runtime.module_template_rejected = self.page_template_rejected;
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
        self.dependency_display_title = dependency.Text.transformed(self.display_title.?);
        if (previous) |old| if (!std.mem.eql(u8, old, value))
            return "<span class=\"error\"><strong>Warning:</strong> Display title overrides earlier display title.</span>";
        return "";
    }

    fn hostPageContent(raw: ?*anyopaque, a: std.mem.Allocator, title: []const u8) anyerror!?[]const u8 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const canonical = try namespace_lib.canonicalizeTitle(a, self.runtime, title);
        if (std.mem.eql(u8, canonical, self.host.current_title) and
            (self.host.current_page == null or namespace_lib.ofTitle(self.runtime, canonical).id == self.host.current_page.?.namespace)) {
            if (self.provider.authoritative_page_source) return self.provider.get(self.provider.ctx, a, canonical);
            if (self.current_source) |source| return source;
        }
        return self.provider.get(self.provider.ctx, a, canonical);
    }

    fn hostPageRedirect(raw: ?*anyopaque, title: []const u8) anyerror!?[]const u8 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const get = self.provider.redirect_target orelse return null;
        const canonical = try namespace_lib.canonicalizeTitle(self.runtime.allocator, self.runtime, title);
        return get(self.provider.ctx, self.runtime.allocator, canonical);
    }

    fn hostPageId(raw: ?*anyopaque, title: []const u8) anyerror!?u64 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const get = self.provider.page_metadata orelse return null;
        const canonical = try namespace_lib.canonicalizeTitle(self.runtime.allocator, self.runtime, title);
        const metadata = (try get(self.provider.ctx, canonical)) orelse return null;
        return metadata.page_id;
    }

    fn hostPageContentModel(raw: ?*anyopaque, title: []const u8) anyerror!?[]const u8 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const get = self.provider.page_metadata orelse return null;
        const canonical = try namespace_lib.canonicalizeTitle(self.runtime.allocator, self.runtime, title);
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
        const get = self.provider.file_metadata orelse {
            work_stats.logLine("warning: file metadata missing: title={s}\n", .{title});
            return error.FileMetadataSnapshotMissing;
        };
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

    fn hostLanguageSupported(raw: ?*anyopaque, code: []const u8) anyerror!bool {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const get = self.provider.language_supported orelse return error.LanguageSupportSnapshotMissing;
        return get(self.provider.ctx, code);
    }

    fn hostLanguageKnownTag(raw: ?*anyopaque, code: []const u8) anyerror!bool {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const get = self.provider.language_known_tag orelse return error.NotImplemented;
        return get(self.provider.ctx, code);
    }

    fn hostWikibasePageEntityId(raw: ?*anyopaque, title: []const u8) anyerror!?[]const u8 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        return (self.provider.wikibase_page_entity_id orelse return error.WikibasePageLinkSnapshotMissing)(self.provider.ctx, title);
    }

    fn hostWikibaseEntity(raw: ?*anyopaque, entity_id: []const u8) anyerror!host_api.WikibaseEntity {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        return (self.provider.wikibase_entity orelse return error.NotImplemented)(self.provider.ctx, entity_id);
    }

    fn hostWikibaseEntityTerms(raw: ?*anyopaque, entity_id: []const u8) anyerror!host_api.WikibaseEntityTerms {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        return (self.provider.wikibase_entity_terms orelse return error.NotImplemented)(self.provider.ctx, entity_id);
    }

    fn hostDateNumbering(raw: ?*anyopaque, code: []const u8) anyerror!host_api.DateNumbering {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        return (self.provider.date_numbering orelse return error.DateNumberingSnapshotMissing)(self.provider.ctx, code);
    }

    fn hostLanguageNames(raw: ?*anyopaque, display: ?[]const u8, scope: host_api.LanguageNameScope) anyerror![]const host_api.LanguageNameRow {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        return (self.provider.language_names orelse return error.LanguageNameSnapshotMissing)(self.provider.ctx, display, scope);
    }
    fn hostLanguageName(raw: ?*anyopaque, code: []const u8, display: ?[]const u8) anyerror![]const u8 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        return (self.provider.language_name orelse return error.LanguageNameSnapshotMissing)(self.provider.ctx, code, display);
    }
    fn hostLanguageDirection(raw: ?*anyopaque, code: []const u8) anyerror!host_api.LanguageDirection {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        return (self.provider.language_direction orelse return error.LanguageDirectionSnapshotMissing)(self.provider.ctx, code);
    }

    fn hostLanguageFallbacks(raw: ?*anyopaque, code: []const u8) anyerror![]const []const u8 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        return (self.provider.language_fallbacks orelse return error.NotImplemented)(self.provider.ctx, code);
    }

    fn hostPageExists(raw: ?*anyopaque, title: []const u8) anyerror!bool {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const canonical = namespace_lib.canonicalizeTitle(self.runtime.allocator, self.runtime, title) catch |err| switch (err) {
            error.InvalidPageTitle => return false,
            else => return err,
        };
        const parsed = namespace_lib.ofTitle(self.runtime, canonical);
        const spec = namespace_lib.byId(self.runtime, parsed.id) orelse return error.NamespaceRegistryRequired;
        // ParserFunctions checks Title::newFromText before any existence lookup.
        // Invalid title bodies cannot require a captured page or file result.
        if (!title_lib.validTitleBody(self.runtime, spec, parsed.text)) return false;
        if (std.mem.eql(u8, canonical, self.host.current_title) and self.current_source != null and
            (self.host.current_page == null or parsed.id == self.host.current_page.?.namespace)) return true;
        if (try self.provider.exists(self.provider.ctx, canonical)) return true;
        if (namespace_lib.ofTitle(self.runtime, canonical).id == 828) {
            _ = self.runtime.resolveModule(canonical) catch return false;
            return true;
        }
        return false;
    }

    pub fn expandFragment(self: *Expander, title: []const u8, source: []const u8, now_unix: ?i64) anyerror![]const u8 {
        return self.expandStoredFragment(title, source, now_unix, null);
    }

    pub fn expandStoredFragment(self: *Expander, title: []const u8, source: []const u8, now_unix: ?i64, current: ?host_api.CurrentPage) anyerror![]const u8 {
        self.beginPage(title, source, now_unix);
        self.host.current_page = current;
        // This entry point has no target-language/variant override or interface
        // parser mode. {{int:}} expands Message::plain in this same root parser.
        self.normal_page_format_context = current != null;
        defer self.releasePageModuleTemplates();
        if (work_stats.current()) |work| work.comment_bytes +|= source.len;
        const comments_start = work_stats.cpuNow();
        const stripped = try preprocess.directDecodedForParsingAlloc(self.runtime.allocator, source);
        if (work_stats.current()) |work| work.comments_ns +|= work_stats.elapsed(comments_start);
        defer self.runtime.allocator.free(stripped);
        const params = try self.runtime.newTable();
        var output_text = try self.expandPageWikitextTracked(stripped, params, title);
        if (self.host.page_identity_failure) |failure| {
            self.runtime.allocator.free(output_text.bytes);
            return failure;
        }
        // Native evaluation has finished. Escape only exact source-literal
        // curly ranges before any final normalizer can discard copy metadata.
        const evaluated_output = output_text.bytes;
        output_text = try dependency.escapeLiteralCurly(self.runtime.allocator, output_text);
        if (output_text.bytes.ptr != evaluated_output.ptr) self.runtime.allocator.free(evaluated_output);
        if (self.display_title) |display| {
            var tracked_title = self.dependency_display_title;
            if (tracked_title.bytes.ptr != display.ptr or tracked_title.bytes.len != display.len)
                tracked_title = dependency.Text.transformed(display);
            tracked_title = try dependency.escapeLiteralCurly(self.runtime.allocator, tracked_title);
            self.display_title = tracked_title.bytes;
            self.dependency_display_title = tracked_title;
        }
        var output = output_text.bytes;
        errdefer self.runtime.allocator.free(output);
        if (std.mem.indexOf(u8, output, "<!--") != null) {
            if (work_stats.current()) |work| work.comment_bytes +|= output.len;
            const start = work_stats.cpuNow();
            const normalized = try preprocess.stripExpandedCommentsTracked(self.runtime.allocator, output_text);
            self.runtime.allocator.free(output);
            output_text = normalized;
            output = normalized.bytes;
            if (work_stats.current()) |work| work.comments_ns +|= work_stats.elapsed(start);
        }
        const restored_hiero = try self.restoreHieroMarkers(self.runtime.allocator, output);
        if (restored_hiero.ptr != output.ptr) self.runtime.allocator.free(output);
        if (restored_hiero.ptr != output.ptr or restored_hiero.len != output.len) output_text = dependency.Text.transformed(restored_hiero);
        output = restored_hiero;
        const finalized_nowiki = try self.finalizeNowikiMarkers(self.runtime.allocator, output);
        if (finalized_nowiki.ptr != output.ptr) self.runtime.allocator.free(output);
        if (finalized_nowiki.ptr != output.ptr or finalized_nowiki.len != output.len) output_text = dependency.Text.transformed(finalized_nowiki);
        output = finalized_nowiki;
        if (self.display_title) |display| {
            const general = try self.restoreHieroMarkers(self.runtime.allocator, display);
            self.display_title = try self.finalizeNowikiMarkers(self.runtime.allocator, general);
        }
        const normalized = try self.normalizeUnknownPoemAlloc(output);
        if (normalized.ptr != output.ptr) self.runtime.allocator.free(output);
        if (normalized.ptr != output.ptr or normalized.len != output.len) output_text = dependency.Text.transformed(normalized);
        output = normalized;
        if (self.display_title) |display| self.display_title = try self.normalizeUnknownPoemAlloc(display);
        const linked = try self.restoreIsbnMarkers(self.runtime.allocator, output, &self.output_links);
        if (linked.ptr != output.ptr) self.runtime.allocator.free(output);
        if (linked.ptr != output.ptr or linked.len != output.len) output_text = dependency.Text.transformed(linked);
        output = linked;
        if (self.display_title) |display| self.display_title = try self.restoreIsbnMarkers(self.runtime.allocator, display, &self.display_title_links);
        try self.finishPoemMetadata(output);
        // The existing normalization helpers return the original slice when
        // they make no edit. An edited result conservatively loses its ranges.
        const final_title = self.display_title orelse "";
        var title_text = self.dependency_display_title;
        if (title_text.bytes.ptr != final_title.ptr or title_text.bytes.len != final_title.len)
            title_text = dependency.Text.transformed(final_title);
        if (self.dependency_page.occurrences.items.len != 0) {
            output_text.unknown = output_text.unknown or self.dependency_page.metadata_unknown;
            // Protocol max_frame_bytes is a payload ceiling: its outer four
            // length bytes are excluded. Header10 + optional Poem length4 +
            // missing phase length4 remain included. Never alter visible bytes.
            const max_frame_bytes: usize = 32 * 1024 * 1024;
            const poem_bytes = if (self.poem_metadata) |bytes| 4 +| bytes.len else 0;
            const occupied = 10 +| output.len +| final_title.len +| poem_bytes +| 4;
            const available = max_frame_bytes -| occupied;
            const encoded = try dependency.encodeBudgeted(self.page_allocator orelse self.runtime.allocator, output_text, title_text, self.dependency_page.occurrences.items, available);
            self.missing_dependency_metadata = encoded.metadata;
            if (encoded.limited or self.dependency_page.metadata_unknown)
                work_stats.logLine("warning: missing dependency provenance capacity: page={s} source-bytes={d} title-bytes={d} occurrence-count={d} phase={s} semantic-completeness=unknown\n", .{ title[0..@min(title.len, 256)], output.len, final_title.len, self.dependency_page.occurrences.items.len, if (encoded.metadata != null) @as([]const u8, "bounded") else "absent" });
        }
        return output;
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

    // Parser::braceSubstitution (T2529) makes block-leading template,
    // parser-function and variable results start a new line. Preprocessor_Hash
    // determines lineStart from the source invocation, not previous output.
    // Triple-brace parameter substitutions deliberately do not use this rule.
    fn implicitBlockNewline(source: []const u8, open: usize, value: []const u8) bool {
        if (value.len == 0 or (open != 0 and source[open - 1] == '\n')) return false;
        return std.mem.indexOfScalar(u8, ":;#*", value[0]) != null or std.mem.startsWith(u8, value, "{|");
    }

    fn expandPageWikitext(self: *Expander, text: []const u8, params: *rt.Table, host_title: []const u8) anyerror![]const u8 {
        return (try self.expandPageWikitextTracked(text, params, host_title)).bytes;
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
        const registry = self.runtime.namespace_catalog orelse return error.NamespaceRegistryRequired;
        if (self.host.current_page) |current| if (host_title) |host_value| {
            const name = std.mem.trim(u8, raw, " \t\r\n");
            if (std.mem.startsWith(u8, name, "/") and std.mem.eql(u8, host_value, self.host.current_title) and
                registry.ofTitle(host_value).id != current.namespace)
            {
                const spec = try registry.storedPageSpec(host_value, current.namespace);
                if (spec.has_subpages) return error.NamespaceTitleCollision;
                return registry.normalizeTransclusion(self.runtime.allocator, raw, null);
            }
        };
        return registry.normalizeTransclusion(self.runtime.allocator, raw, host_title);
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
        if (prefix.len == 0 or namespace_lib.byName(self.runtime, prefix) != null) return .normal;
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

    fn isUsageRecoveryWrapper(text: []const u8) bool {
        var body = std.mem.trimStart(u8, text, " \t\r\n");
        // Excluded documentation leaves inert edge nodes in parsing bodies.
        // Interior nodes remain barriers and cannot synthesize the wrapper.
        while (preprocess.parsingBoundaryEnd(body, 0)) |end|
            body = std.mem.trimStart(u8, body[end..], " \t\r\n");
        const wrapper = "{{#invoke:usex|display|short=1}}";
        if (!std.mem.startsWith(u8, body, wrapper)) return false;
        body = std.mem.trimStart(u8, body[wrapper.len..], " \t\r\n");
        while (preprocess.parsingBoundaryEnd(body, 0)) |end|
            body = std.mem.trimStart(u8, body[end..], " \t\r\n");
        return body.len == 0;
    }

    // Ordinary template frames participate in the same LST loopCheck ancestry.
    // The parser title remains unchanged; only child-frame title/args are replaced.
    fn expandTransclusionText(self: *Expander, title: []const u8, text: []const u8, args: *rt.Table, depth: usize) anyerror![]const u8 {
        const frame: TransclusionFrame = .{ .title = title, .parent = self.transclusion_frame };
        self.transclusion_frame = &frame;
        defer self.transclusion_frame = frame.parent;
        if (self.usage_recovery) |recovery| {
            if (recovery.args == args and isUsageRecoveryWrapper(text))
                recovery.exact_wrapper = true;
        }
        return self.expandWikitext(text, args, title, depth);
    }

    fn templateLoopWarning(self: *Expander, requested_title: []const u8, resolved_title: []const u8) anyerror!?[]const u8 {
        // Parser::braceSubstitution checks the resolved redirect target, but
        // substitutes the requested canonical title into the localized warning.
        var ancestor = self.transclusion_frame;
        while (ancestor) |frame| {
            if (std.mem.eql(u8, frame.title, resolved_title)) {
                const warning = try message_lib.interfaceMessagePlain(self.runtime, "parser-template-loop-warning", &.{.{ .string = requested_title }});
                rt.work_stats.logLine("warning: ordinary template loop: requested={s} resolved={s}\n", .{ requested_title[0..@min(requested_title.len, 256)], resolved_title[0..@min(resolved_title.len, 256)] });
                return try std.fmt.allocPrint(self.runtime.allocator, "<span class=\"error\">{s}</span>", .{warning});
            }
            ancestor = frame.parent;
        }
        return null;
    }

    fn expandTemplateSource(self: *Expander, title: []const u8, raw: []const u8, args: *rt.Table, depth: usize) anyerror![]const u8 {
        if (work_stats.current()) |work| {
            work.template_preprocess_calls +|= 1;
            work.template_preprocess_bytes +|= raw.len;
        }
        const preprocess_start = work_stats.cpuNow();
        const body = try preprocess.transcludeDecodedForParsingAlloc(self.runtime.allocator, raw);
        if (work_stats.current()) |work| work.template_preprocess_ns +|= work_stats.elapsed(preprocess_start);
        defer self.runtime.allocator.free(body);
        return self.expandTransclusionText(title, body, args, depth + 1);
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
            if (try self.templateLoopWarning(title, body.title)) |warning| return warning;
            return self.expandTransclusionText(body.title, body.text, args, depth + 1);
        }
        const raw = if (self.provider.get_transclusion) |get|
            (try get(self.provider.ctx, self.runtime.allocator, title)) orelse
                return self.missingTemplateResult(raw_name, title, missing)
        else
            (try hostPageContent(self, self.runtime.allocator, title)) orelse
                return self.missingTemplateResult(raw_name, title, missing);
        if (try self.templateLoopWarning(title, title)) |warning| return warning;
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
            if (try self.templateLoopWarning(title, body.title)) |warning| return warning;
            return self.expandTransclusionText(body.title, body.text, args, depth + 1);
        };
        const raw = if (self.provider.get_template_symbol) |get|
            (try get(self.provider.ctx, self.runtime.allocator, symbol.id)) orelse return self.missingTemplateMarkup(title)
        else if (self.provider.get_transclusion) |get|
            (try get(self.provider.ctx, self.runtime.allocator, title)) orelse return self.missingTemplateMarkup(title)
        else
            (try hostPageContent(self, self.runtime.allocator, title)) orelse return self.missingTemplateMarkup(title);
        if (try self.templateLoopWarning(title, title)) |warning| return warning;
        return self.expandTemplateSource(title, raw, args, depth);
    }

    fn poemToken(self: *Expander, kind: @FieldType(PoemItem, "kind"), indent: u8, digest: *const [64]u8) anyerror![]const u8 {
        if (self.poem_items.items.len >= 100000) return error.InvalidPoemMetadata;
        const a = self.page_allocator orelse self.runtime.allocator;
        const token = try std.fmt.allocPrint(a, "{s}{d}:{s}\x7f", .{ poem_prefix, self.poem_items.items.len, digest });
        if (token.len > 128) return error.InvalidPoemMetadata;
        try self.poem_items.append(a, .{ .token = token, .kind = kind, .depth = if (kind == .indent) indent else null });
        return token;
    }
    fn poemLiteral(self: *Expander, tag: []const u8, original_body: []const u8) anyerror![]const u8 {
        const a = self.page_allocator orelse self.runtime.allocator;
        const original_counter = self.generated_link_counter;
        const original_items = self.poem_items.items.len;
        errdefer { self.generated_link_counter = original_counter; self.poem_items.shrinkRetainingCapacity(original_items); }
        var links: std.ArrayList(generated_link.WireRange) = .empty;
        // Explicit source text remains inert even when it spells a private token.
        const body = if (std.mem.eql(u8, tag, "text")) original_body else try self.restoreIsbnMarkers(a, original_body, &links);
        if (!std.unicode.utf8ValidateSlice(body)) return error.InvalidPoemMetadata;
        if (body.len > max_poem_metadata_bytes -| self.poem_literal_bytes) return error.FrameTooLarge;
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(body, &hash, .{});
        const digest = std.fmt.bytesToHex(hash, .lower);
        const token = try self.poemToken(.literal, 0, &digest);
        const item = &self.poem_items.items[self.poem_items.items.len - 1];
        item.tag = try a.dupe(u8, tag);
        item.body = try a.dupe(u8, body);
        item.generated_links = try links.toOwnedSlice(a);
        self.poem_literal_bytes += body.len;
        return token;
    }
    fn nativePoemItemLen(self: *const Expander, value: []const u8) ?usize {
        if (!std.mem.startsWith(u8, value, poem_prefix)) return null;
        var at = poem_prefix.len;
        const first = at;
        var index: usize = 0;
        while (at < value.len and std.ascii.isDigit(value[at])) : (at += 1) {
            if (at - first >= 6) return null;
            index = index * 10 + value[at] - '0';
        }
        if (at == first or (at - first > 1 and value[first] == '0') or at >= value.len or value[at] != ':') return null;
        if (index >= self.poem_items.items.len) return null;
        const token = self.poem_items.items[index].token;
        return if (std.mem.startsWith(u8, value, token)) token.len else null;
    }
    fn poemProjection(self: *Expander, input: []const u8) anyerror![]const u8 {
        if (std.mem.count(u8, input, "\n") > 50000) return error.InvalidPoemMetadata;
        const a = self.page_allocator orelse self.runtime.allocator;
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(input, &hash, .{});
        const digest = std.fmt.bytesToHex(hash, .lower);
        var colon: std.ArrayList(u8) = .empty;
        var pos: usize = 0;
        while (pos < input.len) {
            const end = std.mem.indexOfScalarPos(u8, input, pos, '\n') orelse input.len;
            const line = input[pos..end];
            var count: usize = 0;
            while (count < line.len and line[count] == ':') : (count += 1) {}
            if (count != 0 and count < line.len) {
                try colon.appendSlice(a, try self.poemToken(.indent, @intCast(@min(count, 32)), &digest));
                try colon.appendSlice(a, try std.fmt.allocPrint(a, "<span class=\"mw-poem-indented\" style=\"display: inline-block; margin-inline-start: {d}em;\">", .{count}));
                try colon.appendSlice(a, line[count..]);
                try colon.appendSlice(a, "</span>");
            } else try colon.appendSlice(a, line);
            if (end < input.len) try colon.append(a, '\n');
            pos = if (end < input.len) end + 1 else end;
        }
        var transformed: []const u8 = colon.items;
        if (std.mem.startsWith(u8, transformed, "\n")) transformed = transformed[1..];
        if (std.mem.endsWith(u8, transformed, "\n")) transformed = transformed[0 .. transformed.len - 1];
        var out: std.ArrayList(u8) = .empty;
        pos = 0;
        while (pos < transformed.len) {
            const end = std.mem.indexOfScalarPos(u8, transformed, pos, '\n') orelse transformed.len;
            const line = transformed[pos..end];
            var spaces: usize = 0;
            while (spaces < line.len and line[spaces] == ' ') : (spaces += 1) {}
            for (0..spaces) |_| try out.appendSlice(a, "&#160;");
            try out.appendSlice(a, line[spaces..]);
            if (end < transformed.len) {
                try out.appendSlice(a, try self.poemToken(if (std.mem.eql(u8, line, "----")) .space else .br, 0, &digest));
                try out.append(a, '\n');
            }
            pos = if (end < transformed.len) end + 1 else end;
        }
        return out.toOwnedSlice(a);
    }
    fn poemJsonStringSize(value: []const u8) usize {
        var n: usize = 2;
        for (value) |byte| n +|= if (byte < 0x20) @as(usize, 6) else if (byte == '"' or byte == '\\') @as(usize, 2) else 1;
        return n;
    }
    fn poemLooking(value: []const u8) bool {
        var cursor: usize = 0;
        while (std.mem.indexOfScalarPos(u8, value, cursor, '<')) |lt| {
            cursor = lt + 1;
            if (cursor < value.len and value[cursor] == '/') cursor += 1;
            if (value.len - cursor < 4 or !std.ascii.eqlIgnoreCase(value[cursor..][0..4], "poem")) continue;
            if (value.len == cursor + 4 or value[cursor + 4] == '>' or value[cursor + 4] == '/' or std.ascii.isWhitespace(value[cursor + 4])) return true;
        }
        return false;
    }
    // The hook result itself is a general strip item (Parser3974-4057),
    // so authentic prepared markup lives only in the registered table here.
    // Any remaining raw Poem tag is sanitizer-unknown text, not a new hook.
    // Protect existing literal regions and escape only its '<', once.
    fn normalizeUnknownPoemAlloc(self: *Expander, value: []const u8) anyerror![]const u8 {
        if (!poemLooking(value)) return value;
        const a = self.page_allocator orelse self.runtime.allocator;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        var pos: usize = 0;
        var copied: usize = 0;
        var opaque_scan: preprocess.OpaqueParserScan = .{};
        while (std.mem.indexOfScalarPos(u8, value, pos, '<')) |open| {
            pos = open + 1;
            var name = pos;
            if (name < value.len and value[name] == '/') name += 1;
            if (value.len - name >= 4 and std.ascii.eqlIgnoreCase(value[name..][0..4], "poem")) {
                const end = name + 4;
                if (end == value.len or value[end] == '>' or value[end] == '/' or std.ascii.isWhitespace(value[end])) {
                    try out.appendSlice(a, value[copied..open]);
                    try out.appendSlice(a, "&lt;");
                    copied = open + 1;
                    self.poem_handled_empty = true;
                    continue;
                }
            }
            // Ref bodies remain active recursive parser content. Literal
            // extension bodies retain their authored angles and whitespace.
            var end_name = name;
            while (end_name < value.len and std.ascii.isAlphanumeric(value[end_name])) : (end_name += 1) {}
            const tag = value[name..end_name];
            if (!std.ascii.eqlIgnoreCase(tag, "ref") and !std.ascii.eqlIgnoreCase(tag, "references"))
                if (opaque_scan.end(value, open)) |end| {
                    pos = end;
                };
        }
        if (copied == 0) return value;
        try out.appendSlice(a, value[copied..]);
        return out.toOwnedSlice(a);
    }
    fn finishPoemMetadata(self: *Expander, output: []const u8) anyerror!void {
        const title = self.display_title orelse "";
        self.poem_metadata = null;
        if (self.poem_items.items.len == 0 and self.output_links.items.len == 0 and self.display_title_links.items.len == 0 and !self.poem_handled_empty and !poemLooking(output) and !poemLooking(title)) return;
        if (self.poem_items.items.len > 100000 or self.poem_literal_bytes > max_poem_metadata_bytes) return error.InvalidPoemMetadata;
        // An upper bound including every emitted key/separator and exact string
        // escaping is checked before JSON allocation, then actual bytes checked.
        var bound: usize = 512;
        for (self.poem_items.items) |item| {
            bound +|= 96 + poemJsonStringSize(item.token);
            if (item.tag) |tag| bound +|= poemJsonStringSize(tag);
            if (item.body) |body| bound +|= poemJsonStringSize(body);
            for (item.generated_links) |link| bound +|= 160 + poemJsonStringSize(link.value.token) + poemJsonStringSize(link.value.argument) + poemJsonStringSize(link.value.target) + poemJsonStringSize(link.value.label);
            if (bound > max_poem_metadata_bytes) return error.FrameTooLarge;
        }
        for ([_][]const generated_link.WireRange{ self.output_links.items, self.display_title_links.items }) |links| for (links) |link| {
            bound +|= 160 + poemJsonStringSize(link.value.token) + poemJsonStringSize(link.value.argument) + poemJsonStringSize(link.value.target) + poemJsonStringSize(link.value.label);
            if (bound > max_poem_metadata_bytes) return error.FrameTooLarge;
        };
        var output_hash: [32]u8 = undefined;
        var title_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(output, &output_hash, .{});
        std.crypto.hash.sha2.Sha256.hash(title, &title_hash, .{});
        const output_hex = std.fmt.bytesToHex(output_hash, .lower);
        const title_hex = std.fmt.bytesToHex(title_hash, .lower);
        const metadata: PoemMetadata = .{ .schema = if (self.generated_link_counter != 0) "wikidict.presentation-phase.v2" else "wikidict.poem-phase.v1", .output_sha256 = &output_hex, .display_title_sha256 = &title_hex, .items = self.poem_items.items, .output_links = self.output_links.items, .display_title_links = self.display_title_links.items };
        const bytes = try std.json.Stringify.valueAlloc(self.page_allocator orelse self.runtime.allocator, metadata, .{ .emit_null_optional_fields = false });
        if (bytes.len == 0 or bytes.len > max_poem_metadata_bytes) return error.FrameTooLarge;
        self.poem_metadata = bytes;
    }

    // Source-node literals are copied here; expanded return strings bypass this
    // extension scan. Internal projected tokens are trusted only by the exact
    // recursive parse that created them, never by another template source.
    fn appendPoemLiteral(self: *Expander, out: *std.ArrayList(u8), text: []const u8, prepared: bool) anyerror!void {
        const a = self.runtime.allocator;
        if (self.poem_argument_depth == 0 and std.mem.indexOf(u8, text, poem_prefix) == null and std.mem.indexOf(u8, text, isbn_marker_prefix) == null and std.mem.indexOf(u8, text, generated_link.prefix) == null)
            return preprocess.appendParsingText(a, out, text);
        var no_more_close: [4]bool = @splat(false);
        var no_more_gt = false;
        var pos: usize = 0;
        var copied: usize = 0;
        while (pos < text.len) {
            const private_prefix: ?[]const u8 = if (std.mem.startsWith(u8, text[pos..], isbn_marker_prefix)) isbn_marker_prefix else if (std.mem.startsWith(u8, text[pos..], generated_link.prefix)) generated_link.prefix else null;
            if (private_prefix) |prefix_value| {
                if (prepared and std.mem.eql(u8, prefix_value, isbn_marker_prefix)) if (self.ownedStripMarker(text, pos, isbn_marker_prefix, .isbn)) |marker| { pos = marker.end; continue; };
                try preprocess.appendParsingText(a, out, text[copied..pos]);
                try out.appendSlice(a, try self.poemLiteral("text", prefix_value));
                pos += prefix_value.len;
                copied = pos;
                continue;
            }
            if (std.mem.startsWith(u8, text[pos..], poem_prefix)) {
                if (prepared) if (self.nativePoemItemLen(text[pos..])) |len| {
                    pos += len;
                    continue;
                };
                try preprocess.appendParsingText(a, out, text[copied..pos]);
                const end = pos + poem_prefix.len;
                try out.appendSlice(a, try self.poemLiteral("text", text[pos..end]));
                pos = end;
                copied = pos;
                continue;
            }
            if (self.poem_argument_depth != 0 and text[pos] == '<') {
                const before = pos;
                for ([_][]const u8{ "nowiki", "pre", "source", "syntaxhighlight" }, 0..) |name, slot| {
                    if (text.len - pos > name.len + 1 and std.ascii.eqlIgnoreCase(text[pos + 1 ..][0..name.len], name)) {
                        const after = pos + 1 + name.len;
                        if (text[after] != '>' and !std.ascii.isWhitespace(text[after]) and !(text[after] == '/' and after + 1 < text.len and text[after + 1] == '>')) continue;
                        if (no_more_gt) continue;
                        const open_end = if (std.mem.indexOfScalarPos(u8, text, after, '>')) |end| end + 1 else blk: {
                            no_more_gt = true;
                            break :blk @as(usize, 0);
                        };
                        if (open_end == 0) continue;
                        const self_close = text[open_end - 2] == '/';
                        var inner_end = open_end;
                        var region_end = open_end;
                        if (!self_close) {
                            if (no_more_close[slot]) continue;
                            var search = open_end;
                            var found = false;
                            while (std.mem.indexOfScalarPos(u8, text, search, '<')) |lt| {
                                search = lt + 1;
                                if (text.len - lt < name.len + 3 or text[lt + 1] != '/' or !std.ascii.eqlIgnoreCase(text[lt + 2 ..][0..name.len], name)) continue;
                                var end = lt + 2 + name.len;
                                while (end < text.len and std.ascii.isWhitespace(text[end])) : (end += 1) {}
                                if (end == text.len or text[end] != '>') continue;
                                inner_end = lt;
                                region_end = end + 1;
                                found = true;
                                break;
                            }
                            if (!found) {
                                no_more_close[slot] = true;
                                continue;
                            }
                        }
                        try preprocess.appendParsingText(a, out, text[copied..pos]);
                        // Sanitize authored prefix collisions inside this literal
                        // body without recapturing its markup or losing prior
                        // generated BR items inserted by the outer raw hook.
                        var body: std.ArrayList(u8) = .empty;
                        const argument_depth = self.poem_argument_depth;
                        self.poem_argument_depth = 0;
                        defer self.poem_argument_depth = argument_depth;
                        try self.appendPoemLiteral(&body, if (self_close) "" else text[open_end..inner_end], prepared);
                        try out.appendSlice(a, try self.poemLiteral(name, body.items));
                        pos = region_end;
                        copied = pos;
                        break;
                    }
                }
                if (pos != before) continue;
            }
            pos += 1;
        }
        try preprocess.appendParsingText(a, out, text[copied..]);
    }
    fn appendPoemLiteralTracked(self: *Expander, out: *dependency.Builder, text: []const u8, prepared: bool, protect_literal_curly: bool, literal_state: *preprocess.ParsingLiteralState) anyerror!void {
        const a = self.runtime.allocator;
        if (self.poem_argument_depth == 0 and std.mem.indexOf(u8, text, poem_prefix) == null and std.mem.indexOf(u8, text, isbn_marker_prefix) == null and std.mem.indexOf(u8, text, generated_link.prefix) == null)
            return preprocess.appendParsingTextTrackedState(a, out, text, protect_literal_curly, literal_state);
        var no_more_close: [4]bool = @splat(false);
        var no_more_gt = false;
        var pos: usize = 0;
        var copied: usize = 0;
        while (pos < text.len) {
            const private_prefix: ?[]const u8 = if (std.mem.startsWith(u8, text[pos..], isbn_marker_prefix)) isbn_marker_prefix else if (std.mem.startsWith(u8, text[pos..], generated_link.prefix)) generated_link.prefix else null;
            if (private_prefix) |prefix_value| {
                if (prepared and std.mem.eql(u8, prefix_value, isbn_marker_prefix)) if (self.ownedStripMarker(text, pos, isbn_marker_prefix, .isbn)) |marker| { pos = marker.end; continue; };
                try preprocess.appendParsingTextTrackedState(a, out, text[copied..pos], protect_literal_curly, literal_state);
                try out.append(a, dependency.Text.untracked(try self.poemLiteral("text", prefix_value)));
                literal_state.after_boundary = false;
                literal_state.last_source_byte = null;
                pos += prefix_value.len;
                copied = pos;
                continue;
            }
            if (std.mem.startsWith(u8, text[pos..], poem_prefix)) {
                if (prepared) if (self.nativePoemItemLen(text[pos..])) |len| {
                    pos += len;
                    continue;
                };
                try preprocess.appendParsingTextTrackedState(a, out, text[copied..pos], protect_literal_curly, literal_state);
                const end = pos + poem_prefix.len;
                try out.append(a, dependency.Text.untracked(try self.poemLiteral("text", text[pos..end])));
                literal_state.after_boundary = false;
                literal_state.last_source_byte = null;
                pos = end;
                copied = pos;
                continue;
            }
            if (self.poem_argument_depth != 0 and text[pos] == '<') {
                const before = pos;
                for ([_][]const u8{ "nowiki", "pre", "source", "syntaxhighlight" }, 0..) |name, slot| {
                    if (text.len - pos > name.len + 1 and std.ascii.eqlIgnoreCase(text[pos + 1 ..][0..name.len], name)) {
                        const after = pos + 1 + name.len;
                        if (text[after] != '>' and !std.ascii.isWhitespace(text[after]) and !(text[after] == '/' and after + 1 < text.len and text[after + 1] == '>')) continue;
                        if (no_more_gt) continue;
                        const open_end = if (std.mem.indexOfScalarPos(u8, text, after, '>')) |end| end + 1 else blk: {
                            no_more_gt = true;
                            break :blk @as(usize, 0);
                        };
                        if (open_end == 0) continue;
                        const self_close = text[open_end - 2] == '/';
                        var inner_end = open_end;
                        var region_end = open_end;
                        if (!self_close) {
                            if (no_more_close[slot]) continue;
                            var search = open_end;
                            var found = false;
                            while (std.mem.indexOfScalarPos(u8, text, search, '<')) |lt| {
                                search = lt + 1;
                                if (text.len - lt < name.len + 3 or text[lt + 1] != '/' or !std.ascii.eqlIgnoreCase(text[lt + 2 ..][0..name.len], name)) continue;
                                var end = lt + 2 + name.len;
                                while (end < text.len and std.ascii.isWhitespace(text[end])) : (end += 1) {}
                                if (end == text.len or text[end] != '>') continue;
                                inner_end = lt;
                                region_end = end + 1;
                                found = true;
                                break;
                            }
                            if (!found) {
                                no_more_close[slot] = true;
                                continue;
                            }
                        }
                        try preprocess.appendParsingTextTrackedState(a, out, text[copied..pos], protect_literal_curly, literal_state);
                        // Sanitize authored prefix collisions inside this literal
                        // body without recapturing its markup or losing prior
                        // generated BR items inserted by the outer raw hook.
                        var body: std.ArrayList(u8) = .empty;
                        const argument_depth = self.poem_argument_depth;
                        self.poem_argument_depth = 0;
                        defer self.poem_argument_depth = argument_depth;
                        try self.appendPoemLiteral(&body, if (self_close) "" else text[open_end..inner_end], prepared);
                        try out.append(a, dependency.Text.untracked(try self.poemLiteral(name, body.items)));
                        literal_state.after_boundary = false;
                        literal_state.last_source_byte = null;
                        pos = region_end;
                        copied = pos;
                        break;
                    }
                }
                if (pos != before) continue;
            }
            pos += 1;
        }
        try preprocess.appendParsingTextTrackedState(a, out, text[copied..], protect_literal_curly, literal_state);
    }
    // Raw source cannot confer instruction provenance by spelling a token
    // registered by an earlier extension. Only an outer projection or an
    // already-expanded #tag value may carry actual registered items through.
    fn poemSourceItemsAlloc(self: *Expander, source: []const u8, trusted_items: bool) anyerror![]const u8 {
        if (std.mem.indexOf(u8, source, poem_prefix) == null) return source;
        const a = self.runtime.allocator;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, source, pos, poem_prefix)) |found| {
            try out.appendSlice(a, source[pos..found]);
            if (trusted_items) if (self.nativePoemItemLen(source[found..])) |len| {
                try out.appendSlice(a, source[found .. found + len]);
                pos = found + len;
                continue;
            };
            // Carry only the reserved prefix. The remaining authored bytes,
            // including any LF/leading colon, retain raw-hook phase semantics.
            try out.appendSlice(a, try self.poemLiteral("text", poem_prefix));
            pos = found + poem_prefix.len;
        }
        try out.appendSlice(a, source[pos..]);
        return out.toOwnedSlice(a);
    }
    fn expandPoemNode(self: *Expander, source: []const u8, region: preprocess.PoemRegion, params: *rt.Table, title: []const u8, depth: usize, trusted_items: bool) anyerror![]const u8 {
        const opening = if (region.self_closing) try std.fmt.allocPrint(self.runtime.allocator, "{s}>", .{source[region.open .. region.opening_end - 2]}) else source[region.open..region.opening_end];
        return self.expandPoemPrepared(opening, if (region.self_closing) "" else source[region.opening_end..region.inner_end], "</poem>", params, title, depth, trusted_items);
    }
    fn expandPoemValue(self: *Expander, body: []const u8, attrs: ?*rt.Table, params: *rt.Table, title: []const u8, depth: usize) anyerror![]const u8 {
        const serialized = try self.serializeExtension("poem", .{ .string = "" }, attrs);
        const opening_end = std.mem.indexOfScalar(u8, serialized, '>') orelse return error.InvalidPoemMetadata;
        return self.expandPoemPrepared(serialized[0 .. opening_end + 1], body, "</poem>", params, title, depth, true);
    }
    fn expandPoemPrepared(self: *Expander, opening: []const u8, body: []const u8, closing: []const u8, params: *rt.Table, title: []const u8, depth: usize, trusted_items: bool) anyerror![]const u8 {
        if (depth > self.max_depth or self.poem_hook_depth >= self.max_depth) return error.TemplateDepth;
        self.poem_hook_depth += 1;
        defer self.poem_hook_depth -= 1;
        const source = try self.poemSourceItemsAlloc(body, trusted_items);
        const projected = try self.poemProjection(source);
        const stripped = try preprocess.stripDecodedCommentsForParsingPreservingPoem(self.runtime.allocator, projected);
        self.poem_argument_depth += 1;
        defer self.poem_argument_depth -= 1;
        const expanded = try self.expandWikitextMode(stripped, params, title, depth + 1, true, true);
        const comments = if (std.mem.indexOf(u8, expanded, "<!--") == null) expanded else try preprocess.stripExpandedComments(self.runtime.allocator, expanded);
        const normalized = try self.normalizeUnknownPoemAlloc(comments);
        // The hook trims its half-parsed result before the outer block pass.
        // Keep PHP trim's exact default byte set; NBSP and form feed survive.
        // Registered protected bodies and generated breaks remain opaque items.
        const finished = std.mem.trim(u8, normalized, " \t\r\n\x00\x0b");
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(body, &hash, .{});
        const digest = std.fmt.bytesToHex(hash, .lower);
        const scope = try self.poemToken(.scope, 0, &digest);
        const prepared = try std.fmt.allocPrint(self.runtime.allocator, "{s}{s}{s}{s}", .{ scope, opening, finished, closing });
        return self.poemLiteral("poem", prepared);
    }

    fn expandWikitext(self: *Expander, text: []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        return self.expandWikitextMode(text, params, host_title, depth, true, false);
    }
    fn expandWikitextMode(self: *Expander, text: []const u8, params: *rt.Table, host_title: []const u8, depth: usize, allow_poem: bool, prepared: bool) anyerror![]const u8 {
        return (try self.expandWikitextModeTracked(text, params, host_title, depth, allow_poem, prepared, null)).bytes;
    }

    const code_example_open = "<code>{&#123;";
    const code_example_close = "}}</code>";
    const code_example_boundary = "<noinclude/>";

    fn trimCodeExampleBoundaries(text: []const u8) []const u8 {
        var value = std.mem.trimStart(u8, text, " \t\r\n");
        while (std.mem.startsWith(u8, value, code_example_boundary))
            value = std.mem.trimStart(u8, value[code_example_boundary.len..], " \t\r\n");
        return value;
    }

    // Only a complete authored code wrapper in this transclusion's own source
    // can own the two braces. Empty preprocessing boundaries do not own tags.
    fn transcludedCodeExampleClose(source: []const u8) ?usize {
        // This inline source proof scans at most one small transclusion.
        if (source.len > 4096) return null;
        const visible = trimCodeExampleBoundaries(source);
        if (!std.mem.startsWith(u8, visible, code_example_open)) return null;
        var next = source.len - visible.len + code_example_open.len;
        while (std.mem.indexOfScalarPos(u8, source, next, '<')) |tag| {
            if (std.mem.startsWith(u8, source[tag..], code_example_boundary)) {
                next = tag + code_example_boundary.len;
                continue;
            }
            if (tag < 2 or !std.mem.startsWith(u8, source[tag - 2 ..], code_example_close) or
                trimCodeExampleBoundaries(source[tag - 2 + code_example_close.len ..]).len != 0) return null;
            return tag - 2;
        }
        return null;
    }

    fn markTranscludedCodeExampleClose(a: std.mem.Allocator, out: *dependency.Builder) !void {
        if (out.lost_missing_range) return;
        const bytes = out.bytes.items;
        const code = std.mem.trim(u8, bytes, " \t\r\n");
        if (code.len <= code_example_open.len + code_example_close.len + 4 or
            !std.mem.startsWith(u8, code, code_example_open) or !std.mem.endsWith(u8, code, code_example_close)) return;
        const link = code[code_example_open.len .. code.len - code_example_close.len];
        if (!std.mem.startsWith(u8, link, "[[") or !std.mem.endsWith(u8, link, "]]")) return;
        const body = link[2 .. link.len - 2];
        if (std.mem.indexOfAny(u8, body, "[]{}<>&'\"\r\n") != null) return;
        const separator = std.mem.indexOfScalar(u8, body, '|') orelse body.len;
        if (std.mem.trim(u8, body[0..separator], " \t").len == 0) return;
        const at = @intFromPtr(code.ptr) - @intFromPtr(bytes.ptr);
        for (out.ranges.items) |range| if (range.start < at + code.len and range.end > at) return;
        for (out.generated_links.items) |range| if (range.start < at + code.len and range.end > at) return;
        const close = at + code.len - code_example_close.len;
        try out.markLiteralCurly(a, close, close + 2);
    }

    fn expandWikitextModeTracked(self: *Expander, text: []const u8, params: *rt.Table, host_title: []const u8, depth: usize, allow_poem: bool, prepared: bool, code_close: ?usize) anyerror!dependency.Text {
        if (depth > self.max_depth) return error.TemplateDepth;
        if (work_stats.current()) |work| {
            work.scan_calls +|= 1;
            work.scan_bytes +|= text.len;
        }
        var out: dependency.Builder = .{};
        errdefer out.deinit(self.runtime.allocator);
        var pos: usize = 0;
        var expansion_scan: preprocess.ExpansionScan = .{ .conversion_enabled = self.provider.language_conversion_enabled orelse false };
        const protect_literal_curly = preprocess.hasParsingBoundary(text);
        var literal_state: preprocess.ParsingLiteralState = .{};
        while (expansion_scan.next(text, pos, allow_poem)) |node| {
            const open = switch (node) {
                .construct => |v| v.open,
                .poem => |v| v.open,
            };
            try self.appendPoemLiteralTracked(&out, text[pos..open], prepared, protect_literal_curly, &literal_state);
            literal_state.after_boundary = false;
            literal_state.last_source_byte = null;
            if (work_stats.current()) |work| work.constructs +|= 1;
            switch (node) {
                .poem => |region| {
                    try out.append(self.runtime.allocator, dependency.Text.transformed(try self.expandPoemNode(text, region, params, host_title, depth + 1, prepared)));
                    pos = region.end;
                },
                .construct => |construct| {
                    const expanded = switch (construct.kind) {
                        .parameter => try self.expandParameterTracked(text[construct.open + 3 .. construct.close], params, host_title, depth + 1),
                        .template => try self.expandConstructTracked(text[construct.open + 2 .. construct.close], params, host_title, depth + 1),
                    };
                    if (construct.kind == .template and implicitBlockNewline(text, construct.open, expanded.bytes)) try out.append(self.runtime.allocator, dependency.Text.untracked("\n"));
                    try out.append(self.runtime.allocator, expanded);
                    pos = construct.close + if (construct.kind == .parameter) @as(usize, 3) else 2;
                    if (construct.kind == .parameter) {
                        var remaining = try preprocess.parameterLiteralCloseCount(self.runtime.allocator, text[construct.open + 3 .. construct.close]);
                        const trailing = pos;
                        while (remaining != 0 and pos < text.len and text[pos] == '}') : (remaining -= 1) pos += 1;
                        if (pos != trailing) try out.appendLiteralCurly(self.runtime.allocator, text[trailing..pos]);
                    }
                },
            }
        }
        try self.appendPoemLiteralTracked(&out, text[pos..], prepared, protect_literal_curly, &literal_state);
        // The closer must sit in this ordinary, copied suffix. A close consumed
        // by an active template construct cannot supply literal authority.
        if (code_close) |close| if (close >= pos) try markTranscludedCodeExampleClose(self.runtime.allocator, &out);
        var result = try out.finish(self.runtime.allocator);
        if (rt.string_origins.enabled()) if (self.origin_ledger) |origins| {
            const input = try originResult(origins.read(text));
            if (input.unknown or input.lost_missing_range or input.ranges.len != 0) {
                result.unknown = true;
                result.lost_missing_range = result.lost_missing_range or input.lost_missing_range or input.ranges.len != 0;
            }
            try originResult(origins.remember(@intFromPtr(self.runtime), result));
        };
        return result;
    }

    fn expandWikitextTracked(self: *Expander, text: []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror!dependency.Text {
        return self.expandWikitextModeTracked(text, params, host_title, depth, true, false, null);
    }
    fn trimDependency(self: *Expander, value: dependency.Text, characters: []const u8) !dependency.Text {
        const trimmed = std.mem.trim(u8, value.bytes, characters);
        if (value.ranges.len == 0 and value.literal_curly_ranges.len == 0) return .{ .bytes = trimmed, .unknown = value.unknown };
        const left = value.bytes.len - std.mem.trimStart(u8, value.bytes, characters).len;
        return dependency.slice(self.page_allocator orelse self.runtime.allocator, value, left, left + trimmed.len);
    }
    fn invalidateNativeDependencyArguments(self: *Expander) void {
        // Once any Lua caller can observe/mutate argument tables, never infer
        // provenance from their later values, even when the bytes are equal.
        self.dependency_native_arguments_disabled = true;
        self.dependency_arguments.items.len = 0;
    }
    fn nativeDependencyArgument(self: *Expander, params: *rt.Table, key: Value) ?dependency.Text {
        if (self.dependency_native_arguments_disabled) return null;
        for (self.dependency_arguments.items, 0..) |item, i| {
            if (item.target != params or !rt.rawEqual(item.key, key)) continue;
            // This is the exact value installed by our native lazy expansion,
            // not a value recovered by string equality after table mutation.
            const current = params.rawGet(key);
            if (current == null or current.? != .string or
                current.?.string.ptr != item.cached_bytes.ptr or current.?.string.len != item.cached_bytes.len or
                !std.mem.eql(u8, current.?.string, item.value.bytes))
            {
                _ = self.dependency_arguments.orderedRemove(i);
                return null;
            }
            return item.value;
        }
        return null;
    }
    fn rememberDependencyArgument(self: *Expander, params: *rt.Table, key: Value, value: dependency.Text) !void {
        if (self.dependency_native_arguments_disabled) return;
        // A source marker without mapped links has no copy contract.
        if (value.generated_source != null and value.generated_links.len == 0) return;
        const cached = params.rawGet(key) orelse return;
        if (cached != .string or cached.string.ptr != value.bytes.ptr or cached.string.len != value.bytes.len) return;
        // Keep known native values too: a second parameter read must not lose
        // provenance merely because the first read memoized its bytes. All
        // snapshots are page-owned and Lua exposure still invalidates them.
        const cost = @sizeOf(DependencyArgument) +| value.bytes.len +|
            (if (key == .string) key.string.len else @as(usize, 0)) +|
            value.ranges.len *| @sizeOf(dependency.Range) +|
            value.literal_curly_ranges.len *| @sizeOf(dependency.LiteralRange) +|
            value.generated_links.len *| @sizeOf(generated_link.Range);
        if (cost > dependency.max_metadata_bytes -| self.dependency_argument_bytes or
            self.dependency_arguments.items.len >= dependency.max_metadata_bytes / @sizeOf(DependencyArgument))
        {
            self.invalidateNativeDependencyArguments();
            self.dependency_page.metadata_unknown = true;
            return;
        }
        for (self.dependency_arguments.items, 0..) |item, i| {
            if (item.target == params and rt.rawEqual(item.key, key)) {
                _ = self.dependency_arguments.orderedRemove(i);
                break;
            }
        }
        const a = self.page_allocator orelse self.runtime.allocator;
        const owned_key: Value = if (key == .string) .{ .string = try a.dupe(u8, key.string) } else key;
        try self.dependency_arguments.append(a, .{ .target = params, .key = owned_key, .cached_bytes = value.bytes, .value = try dependency.duplicate(a, value) });
        self.dependency_argument_bytes += cost;
    }

    // A source-list label can transclude a trailing newline. Its caller's inline
    // separator then starts a new paragraph, but it was never an authored list
    // prefix. Preserve that provenance before flattening the two source nodes.
    fn callerBulletLabelColon(text: []const u8, open: usize, close: usize, value: []const u8) bool {
        if (open == 0 or text[open - 1] != '*' or (open > 1 and text[open - 2] != '\n') or
            !std.mem.startsWith(u8, text[close..], ": {{") or
            !std.mem.endsWith(u8, value, "\n") or value.len < 2 or
            std.mem.indexOfAny(u8, value[0 .. value.len - 1], "\r\n") != null) return false;
        const name = text[open + 2 .. close - 2];
        return name.len != 0 and std.mem.indexOfAny(u8, name, "|:#{}<>[]\r\n") == null;
    }

    fn expandPageWikitextTracked(self: *Expander, text: []const u8, params: *rt.Table, host_title: []const u8) anyerror!dependency.Text {
        if (work_stats.current()) |work| {
            work.scan_calls +|= 1;
            work.scan_bytes +|= text.len;
        }
        var out: dependency.Builder = .{};
        errdefer out.deinit(self.runtime.allocator);
        var pos: usize = 0;
        var expansion_scan: preprocess.ExpansionScan = .{ .conversion_enabled = self.provider.language_conversion_enabled orelse false };
        const protect_literal_curly = preprocess.hasParsingBoundary(text);
        var literal_state: preprocess.ParsingLiteralState = .{};
        while (expansion_scan.next(text, pos, true)) |node| {
            if (work_stats.current()) |work| work.constructs +|= 1;
            const open = switch (node) {
                .construct => |v| v.open,
                .poem => |v| v.open,
            };
            const literal = text[pos..open];
            try self.observePageOutput(literal);
            const literal_output_start = out.bytes.items.len;
            try self.appendPoemLiteralTracked(&out, literal, false, protect_literal_curly, &literal_state);
            if (self.poem_argument_depth == 0)
                try preprocess.markRootSingletonLiteralCurly(self.runtime.allocator, &out, text, pos, open, literal_output_start);
            literal_state.after_boundary = false;
            literal_state.last_source_byte = null;
            var template = false;
            const expanded = switch (node) {
                .poem => |region| blk: {
                    pos = region.end;
                    break :blk dependency.Text.transformed(try self.expandPoemNode(text, region, params, host_title, 1, false));
                },
                .construct => |construct| switch (construct.kind) {
                    .parameter => blk: {
                        pos = construct.close + 3;
                        break :blk try self.expandParameterTracked(text[construct.open + 3 .. construct.close], params, host_title, 1);
                    },
                    .template => blk: {
                        pos = construct.close + 2;
                        template = true;
                        break :blk try self.expandConstructTracked(text[construct.open + 2 .. construct.close], params, host_title, 1);
                    },
                },
            };
            if (template and implicitBlockNewline(text, open, expanded.bytes)) {
                try self.observePageOutput("\n");
                try out.append(self.runtime.allocator, dependency.Text.untracked("\n"));
            }
            try self.observePageOutput(expanded.bytes);
            try out.append(self.runtime.allocator, expanded);
            if (template and !expanded.unknown and callerBulletLabelColon(text, open, pos, expanded.bytes)) {
                try self.observePageOutput(":");
                try out.append(self.runtime.allocator, dependency.Text.untracked("&#58;"));
                pos += 1;
            }
            if (node == .construct and node.construct.kind == .parameter) {
                var remaining = try preprocess.parameterLiteralCloseCount(self.runtime.allocator, text[node.construct.open + 3 .. node.construct.close]);
                const trailing = pos;
                while (remaining != 0 and pos < text.len and text[pos] == '}') : (remaining -= 1) pos += 1;
                if (pos != trailing) {
                    try self.observePageOutput(text[trailing..pos]);
                    try out.appendLiteralCurly(self.runtime.allocator, text[trailing..pos]);
                }
            }
        }
        try self.observePageOutput(text[pos..]);
        const tail_output_start = out.bytes.items.len;
        try self.appendPoemLiteralTracked(&out, text[pos..], false, protect_literal_curly, &literal_state);
        if (self.poem_argument_depth == 0)
            try preprocess.markRootSingletonLiteralCurly(self.runtime.allocator, &out, text, pos, text.len, tail_output_start);
        return out.finish(self.runtime.allocator);
    }

    fn expandTransclusionTextTracked(self: *Expander, title: []const u8, text: []const u8, args: *rt.Table, depth: usize) anyerror!dependency.Text {
        const frame: TransclusionFrame = .{ .title = title, .parent = self.transclusion_frame };
        self.transclusion_frame = &frame;
        defer self.transclusion_frame = frame.parent;
        if (self.usage_recovery) |recovery| {
            if (recovery.args == args and isUsageRecoveryWrapper(text))
                recovery.exact_wrapper = true;
        }
        return self.expandWikitextModeTracked(text, args, title, depth, true, false, transcludedCodeExampleClose(text));
    }

    fn expandTemplateSourceTracked(self: *Expander, title: []const u8, raw: []const u8, args: *rt.Table, depth: usize) anyerror!dependency.Text {
        if (work_stats.current()) |work| {
            work.template_preprocess_calls +|= 1;
            work.template_preprocess_bytes +|= raw.len;
        }
        const preprocess_start = work_stats.cpuNow();
        const body = try preprocess.transcludeDecodedForParsingAlloc(self.runtime.allocator, raw);
        if (work_stats.current()) |work| work.template_preprocess_ns +|= work_stats.elapsed(preprocess_start);
        defer self.runtime.allocator.free(body);
        return self.expandTransclusionTextTracked(title, body, args, depth + 1);
    }

    fn expandTemplateByNameTracked(self: *Expander, raw_name: []const u8, args: *rt.Table, host_title: ?[]const u8, depth: usize, missing: MissingTemplate) anyerror!dependency.Text {
        if (depth > self.max_depth) return error.TemplateDepth;
        if (self.template_depth >= self.max_template_depth) return error.TemplateDepth;
        self.template_depth += 1;
        defer self.template_depth -= 1;
        const title = try self.normalizeTransclusionName(raw_name, host_title);
        if (self.provider.get_transclusion_body) |get| {
            const body = (try get(self.provider.ctx, self.runtime.allocator, title)) orelse
                return self.missingTemplateResultTracked(raw_name, title, missing);
            defer if (!body.borrowed) self.runtime.allocator.free(body.text);
            if (try self.templateLoopWarning(title, body.title)) |warning| return dependency.Text.untracked(warning);
            return self.expandTransclusionTextTracked(body.title, body.text, args, depth + 1);
        }
        const raw = if (self.provider.get_transclusion) |get|
            (try get(self.provider.ctx, self.runtime.allocator, title)) orelse
                return self.missingTemplateResultTracked(raw_name, title, missing)
        else
            (try hostPageContent(self, self.runtime.allocator, title)) orelse
                return self.missingTemplateResultTracked(raw_name, title, missing);
        if (try self.templateLoopWarning(title, title)) |warning| return dependency.Text.untracked(warning);
        return self.expandTemplateSourceTracked(title, raw, args, depth);
    }

    fn expandTemplateBySymbolTracked(self: *Expander, symbol: CallSymbol, args: *rt.Table, host_title: ?[]const u8, depth: usize) anyerror!dependency.Text {
        if (depth > self.max_depth) return error.TemplateDepth;
        if (self.template_depth >= self.max_template_depth) return error.TemplateDepth;
        self.template_depth += 1;
        defer self.template_depth -= 1;
        const title = try self.normalizeTransclusionName(symbol.text, host_title);
        if (self.provider.get_template_symbol == null) if (self.provider.get_transclusion_body) |get| {
            const body = (try get(self.provider.ctx, self.runtime.allocator, title)) orelse return self.missingTemplateMarkupTracked(title);
            defer if (!body.borrowed) self.runtime.allocator.free(body.text);
            if (try self.templateLoopWarning(title, body.title)) |warning| return dependency.Text.untracked(warning);
            return self.expandTransclusionTextTracked(body.title, body.text, args, depth + 1);
        };
        const raw = if (self.provider.get_template_symbol) |get|
            (try get(self.provider.ctx, self.runtime.allocator, symbol.id)) orelse return self.missingTemplateMarkupTracked(title)
        else if (self.provider.get_transclusion) |get|
            (try get(self.provider.ctx, self.runtime.allocator, title)) orelse return self.missingTemplateMarkupTracked(title)
        else
            (try hostPageContent(self, self.runtime.allocator, title)) orelse return self.missingTemplateMarkupTracked(title);
        if (try self.templateLoopWarning(title, title)) |warning| return dependency.Text.untracked(warning);
        return self.expandTemplateSourceTracked(title, raw, args, depth);
    }

    fn expandTemplateWithUsageRecoveryTracked(self: *Expander, name: []const u8, symbol: ?CallSymbol, args: *rt.Table, raw_args: []const []const u8, host_title: []const u8, depth: usize) anyerror!dependency.Text {
        // Unrelated corpus templates keep their original normalization path:
        // the prefilter borrows bytes and allocates nothing.
        const candidate = if (symbol) |value| value.text else name;
        const colon = std.mem.lastIndexOfScalar(u8, candidate, ':');
        const basename = std.mem.trim(u8, candidate[if (colon) |at| at + 1 else 0..], " \t\r\n");
        if (!std.mem.eql(u8, basename, "ux") and !std.mem.eql(u8, basename, "usex")) {
            return if (symbol) |value|
                self.expandTemplateBySymbolTracked(value, args, host_title, depth)
            else
                self.expandTemplateByNameTracked(name, args, host_title, depth, .link);
        }
        const title = try self.normalizeTransclusionName(name, host_title);
        const resolved = self.runtime.namespace_catalog.?.ofTitle(title);
        const eligible = resolved.id == 10 and (std.mem.eql(u8, resolved.text, "ux") or std.mem.eql(u8, resolved.text, "usex"));
        var recovery: UsageRecovery = .{ .args = args };
        const previous = self.usage_recovery;
        if (eligible) self.usage_recovery = &recovery;
        defer self.usage_recovery = previous;
        const expanded = if (symbol) |value|
            try self.expandTemplateBySymbolTracked(value, args, host_title, depth)
        else
            try self.expandTemplateByNameTracked(name, args, host_title, depth, .link);
        if (!eligible or !recovery.exact_wrapper or !recovery.missing_display) return expanded;
        const recovered = (try self.usageSemanticHtml(args, raw_args)) orelse return expanded;
        work_stats.logLine("warning: native usage content recovery: article={s} template={s} module=usex export=display failure=InvokeFunctionMissing diagnostic=build-log recovery=recovered\n", .{ host_title[0..@min(host_title.len, 256)], title[0..@min(title.len, 256)] });
        return dependency.Text.transformed(recovered);
    }

    fn missingTemplateMarkupTracked(self: *Expander, title: []const u8) !dependency.Text {
        const bytes = try self.missingTemplateMarkup(title);
        return self.dependency_page.missing(self.page_allocator orelse self.runtime.allocator, title, bytes);
    }
    fn missingTemplateResultTracked(self: *Expander, raw_name: []const u8, title: []const u8, mode: MissingTemplate) !dependency.Text {
        if (mode == .link) return self.missingTemplateMarkupTracked(title);
        return dependency.Text.transformed(try self.missingTemplateResult(raw_name, title, mode));
    }

    fn resolveLazyTemplateArgTracked(self: *Expander, params: *rt.Table, key: Value) anyerror!?dependency.Text {
        const lazy = self.lazyTemplateArgsFor(params) orelse return null;
        const raw = lazy.raw_values.rawGet(key) orelse return null;
        if (raw != .string) return error.StringExpected;
        // PPTemplateFrame expands argument nodes in its parent frame. A nested
        // invocation supplied by the caller is not recursion by this callee.
        const callee_frame = self.transclusion_frame;
        self.transclusion_frame = lazy.caller_transclusion_frame;
        defer self.transclusion_frame = callee_frame;
        const expanded_raw = try self.expandWikitextTracked(raw.string, lazy.caller_params, lazy.caller_title, lazy.depth + 1);
        const trim_value = key == .string or
            (key == .number and std.mem.indexOfScalar(f64, lazy.named_numeric_keys, key.number) != null);
        const expanded = if (trim_value)
            try self.trimDependency(expanded_raw, " \t\r\n\x00\x0b")
        else
            expanded_raw;
        try params.rawSet(self.runtime.allocator, key, .{ .string = expanded.bytes });
        try self.rememberDependencyArgument(params, key, expanded);
        try self.rememberStringOrigin(expanded);
        return expanded;
    }

    fn expandParameterTracked(self: *Expander, inside: []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror!dependency.Text {
        const split = preprocess.splitParameterWithConversion(inside, self.provider.language_conversion_enabled orelse false);
        const expanded_key = try self.expandWikitext(split.key, params, host_title, depth + 1);
        const key_text = std.mem.trim(u8, expanded_key, " \t\r\n");
        const key: Value = if (std.fmt.parseInt(i64, key_text, 10)) |number|
            .{ .number = @floatFromInt(number) }
        else |_|
            .{ .string = key_text };
        if (params.rawGet(key)) |value| {
            if (self.nativeDependencyArgument(params, key)) |native| return native;
            const bytes = try self.valueToWikitext(value);
            if (value == .string) if (self.origin_ledger) |origins| return originResult(origins.read(bytes));
            return dependency.Text.transformed(bytes);
        }
        if (try self.resolveLazyTemplateArgTracked(params, key)) |value| return value;
        if (split.default) |fallback| return self.expandWikitextTracked(fallback, params, host_title, depth + 1);
        return dependency.Text.untracked(try std.fmt.allocPrint(self.runtime.allocator, "{{{{{{{s}}}}}}}", .{inside}));
    }

    fn parserFunctionLookupName(self: *Expander, raw_name: []const u8) ![]const u8 {
        if (!preprocess.hasParsingBoundary(raw_name)) return raw_name;
        var plain: std.ArrayList(u8) = .empty;
        errdefer plain.deinit(self.runtime.allocator);
        try preprocess.appendParsingText(self.runtime.allocator, &plain, raw_name);
        return plain.toOwnedSlice(self.runtime.allocator);
    }

    fn originLedger(self: *Expander) !*string_origin.Ledger {
        if (self.origin_ledger) |value| return value;
        const a = self.page_allocator orelse self.runtime.allocator;
        const value = try originResult(a.create(string_origin.Ledger));
        value.* = string_origin.Ledger.init(a, string_origin.nextEpoch());
        self.origin_ledger = value;
        return value;
    }
    fn rememberStringOrigin(self: *Expander, value: dependency.Text) !void {
        if (self.origin_ledger) |origins| try originResult(origins.remember(@intFromPtr(self.runtime), value));
    }
    fn expandInvokeTracked(self: *Expander, module: []const u8, args: []const []const u8, params: *rt.Table, title: []const u8, depth: usize) !dependency.Text {
        const origins = try self.originLedger();
        const bytes = try self.expandInvoke(module, args, params, title, depth);
        return originResult(origins.read(bytes));
    }
    fn expandParserHeadTracked(self: *Expander, head: []const u8, raw_args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror!?dependency.Text {
        if (try self.expandVariableHeadTracked(head, raw_args)) |value| return value;
        return self.expandFunctionHeadTracked(head, raw_args, params, host_title, depth);
    }

    fn expandVariableHeadTracked(self: *Expander, head: []const u8, raw_args: []const []const u8) anyerror!?dependency.Text {
        if (raw_args.len == 0) {
            if (try self.resolveTitleMagic(head, .variable)) |name| {
                if (try self.statisticsMagic(name, "")) |value| return dependency.Text.transformed(value);
                // No argument is expanded here: native title variables read only
                // the fixed current-page/title and namespace context. They cannot
                // introduce a missing expansion dependency. Argument-bearing
                // parser functions and Lua results retain transformed provenance.
                return dependency.Text.untracked((try self.titleMagic(name, null)) orelse unreachable);
            }
        }
        if (try self.magicWord(head)) |value| return dependency.Text.transformed(value);
        return null;
    }

    fn expandFunctionHeadTracked(self: *Expander, head: []const u8, raw_args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror!?dependency.Text {
        if (preprocess.findTopParserColonWithConversion(head, self.provider.language_conversion_enabled orelse false)) |colon| {
            const raw_name = std.mem.trim(u8, head[0..colon.index], " \t\r\n");
            if (try self.resolveParserFunction(try self.parserFunctionLookupName(raw_name))) |name| {
                const first = head[colon.index + colon.len ..];
                if (std.ascii.eqlIgnoreCase(name, "#invoke"))
                    return try self.expandInvokeTracked(first, raw_args, params, host_title, depth + 1);
                if (std.ascii.eqlIgnoreCase(name, "localurl"))
                    return try self.expandUrlParserTracked(first, raw_args, params, host_title, depth + 1, .local, false);
                if (std.ascii.eqlIgnoreCase(name, "#tag"))
                    return try self.expandTagParserTracked(first, raw_args, params, host_title, depth + 1);
                if (std.ascii.eqlIgnoreCase(name, "#if")) {
                    const condition = try self.expandWikitext(first, params, host_title, depth + 1);
                    const chosen = if (std.mem.trim(u8, condition, " \t\r\n").len != 0)
                        (if (raw_args.len > 0) raw_args[0] else "")
                    else
                        (if (raw_args.len > 1) raw_args[1] else "");
                    return try self.trimDependency(try self.expandWikitextTracked(chosen, params, host_title, depth + 2), " \t\r\n");
                }
                if (std.ascii.eqlIgnoreCase(name, "#ifeq")) {
                    const lhs = std.mem.trim(u8, try self.expandWikitext(first, params, host_title, depth + 2), " \t\r\n");
                    const rhs = if (raw_args.len != 0) std.mem.trim(u8, try self.expandWikitext(raw_args[0], params, host_title, depth + 2), " \t\r\n") else "";
                    const chosen = if (ifEqEqual(lhs, rhs)) (if (raw_args.len > 1) raw_args[1] else "") else (if (raw_args.len > 2) raw_args[2] else "");
                    return try self.trimDependency(try self.expandWikitextTracked(chosen, params, host_title, depth + 3), " \t\r\n");
                }
                if (std.ascii.eqlIgnoreCase(name, "DISPLAYTITLE")) {
                    const value = try self.expandWikitextTracked(first, params, host_title, depth + 1);
                    const warning = try self.recordDisplayTitle(value.bytes);
                    self.dependency_display_title = .{ .bytes = self.display_title.?, .ranges = try (self.page_allocator orelse self.runtime.allocator).dupe(dependency.Range, value.ranges), .literal_curly_ranges = try (self.page_allocator orelse self.runtime.allocator).dupe(dependency.LiteralRange, value.literal_curly_ranges), .unknown = value.unknown };
                    return dependency.Text.untracked(warning);
                }
            }
        }
        // All other parser/Lua transformations retain their existing bytes.
        // They cannot acquire output provenance through equality with an input.
        if (try self.expandFunctionHead(head, raw_args, params, host_title, depth)) |value|
            return dependency.Text.transformed(value);
        return null;
    }

    fn expandConstructTracked(self: *Expander, content: []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror!dependency.Text {
        const lazy_base = self.lazy_template_args.items.len;
        defer self.lazy_template_args.items.len = lazy_base;
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(self.runtime.allocator);
        try preprocess.splitWikitextTopWithConversion(self.runtime.allocator, content, '|', &parts, self.provider.language_conversion_enabled orelse false);
        if (parts.items.len == 0) return error.MalformedWikitext;
        var raw_head = stripSubstPrefix(parts.items[0]);
        if (raw_head.len == 0)
            return dependency.Text.untracked(try std.fmt.allocPrint(self.runtime.allocator, "<nowiki>{{{{{s}}}}}</nowiki>", .{content}));
        if ((try self.rawTransclusionTarget(raw_head)) != null) {
            const expanded_raw = try self.expandWikitext(raw_head, params, host_title, depth + 1);
            if (try self.expandVariableHeadTracked(expanded_raw, parts.items[1..])) |value| return value;
            return self.expandRawConstruct(true, content, expanded_raw, parts.items[1..], params, host_title, depth);
        }
        if (try self.expandParserHeadTracked(raw_head, parts.items[1..], params, host_title, depth)) |value| return value;
        if (raw_head[0] == '#') {
            self.unsupported_parser_function = true;
            // Unknown calls remain literal, but MediaWiki expands their child
            // nodes. Valid parser functions already returned above, preserving
            // lazy branch selection. Protect only the recovered outer braces.
            const expanded_head = try self.expandWikitext(raw_head, params, host_title, depth + 1);
            return dependency.Text.transformed(try self.emptyComputedTransclusion(expanded_head, parts.items[1..], params, host_title, depth, true));
        }
        switch (try self.classifyInterwikiTransclusion(raw_head)) {
            .normal => {},
            .current_wiki => |local_name| raw_head = local_name,
            .literal => return dependency.Text.untracked(try std.fmt.allocPrint(
                self.runtime.allocator,
                "<nowiki>{{{{{s}}}}}</nowiki>",
                .{content},
            )),
            .external => return error.ExternalInterwikiTransclusionUnsupported,
        }
        if (try self.callSymbol(raw_head, .template)) |symbol| {
            const args = try self.buildTemplateArgs(parts.items[1..], params, host_title, depth + 1);
            return self.expandTemplateWithUsageRecoveryTracked(raw_head, symbol, args, parts.items[1..], host_title, depth + 1);
        }
        const expanded_head = try self.expandWikitext(raw_head, params, host_title, depth + 1);
        const title = stripSubstPrefix(expanded_head);
        if (title.len == 0)
            return dependency.Text.transformed(try self.emptyComputedTransclusion(expanded_head, parts.items[1..], params, host_title, depth, false));
        if (title.len != 0 and !std.mem.eql(u8, title, raw_head)) {
            if ((try self.rawTransclusionTarget(title)) != null) {
                if (try self.expandVariableHeadTracked(title, parts.items[1..])) |value| return value;
                return self.expandRawConstruct(true, content, title, parts.items[1..], params, host_title, depth);
            }
            if (try self.expandParserHeadTracked(title, parts.items[1..], params, host_title, depth)) |value| return value;
        }
        if (title.len != 0 and title[0] == '#') {
            self.unsupported_parser_function = true;
            return dependency.Text.transformed(try self.emptyComputedTransclusion(expanded_head, parts.items[1..], params, host_title, depth, true));
        }
        if (invalidTransclusionTitle(title)) {
            if (invalidTransclusionNeedsProtection(title) or literalComputedColonTitleWithConversion(content, title, parts.items.len, self.provider.language_conversion_enabled orelse false))
                return dependency.Text.untracked(try std.fmt.allocPrint(self.runtime.allocator, "<nowiki>{{{{{s}}}}}</nowiki>", .{content}));
            return dependency.Text.untracked(try std.fmt.allocPrint(self.runtime.allocator, "{{{{{s}}}}}", .{content}));
        }
        const args = try self.buildTemplateArgs(parts.items[1..], params, host_title, depth + 1);
        return self.expandTemplateWithUsageRecoveryTracked(title, null, args, parts.items[1..], host_title, depth + 1);
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
        return if (try self.resolveLazyTemplateArgTracked(params, key)) |value| value.bytes else null;
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
        const split = preprocess.splitParameterWithConversion(inside, self.provider.language_conversion_enabled orelse false);
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
        const page_a = self.page_allocator orelse self.runtime.allocator;
        var named_numeric_keys: std.ArrayList(f64) = .empty;
        defer named_numeric_keys.deinit(page_a);
        var positional: i64 = 1;
        for (raw_args) |raw| {
            if (preprocess.findTopDelimiterWithConversion(raw, '=', self.provider.language_conversion_enabled orelse false)) |eq| {
                const key_expanded = try self.expandWikitext(raw[0..eq], caller_params, host_title, depth + 1);
                const key_text = std.mem.trim(u8, key_expanded, " \t\r\n");
                if (key_text.len == 0) continue;
                const key: Value = if (std.fmt.parseInt(i64, key_text, 10)) |number|
                    .{ .number = @floatFromInt(number) }
                else |_|
                    .{ .string = key_text };
                try raw_values.rawSet(self.runtime.allocator, key, .{ .string = raw[eq + 1 ..] });
                // String keys are inherently named; only numeric keys need provenance.
                if (key == .number and std.mem.indexOfScalar(f64, named_numeric_keys.items, key.number) == null)
                    try named_numeric_keys.append(page_a, key.number);
            } else {
                if (std.mem.indexOfScalar(f64, named_numeric_keys.items, @floatFromInt(positional))) |index|
                    _ = named_numeric_keys.swapRemove(index);
                try raw_values.rawSet(
                    self.runtime.allocator,
                    .{ .number = @floatFromInt(positional) },
                    .{ .string = raw },
                );
                positional += 1;
            }
        }
        try self.lazy_template_args.append(page_a, .{
            .target = out,
            .raw_values = raw_values,
            .named_numeric_keys = try named_numeric_keys.toOwnedSlice(page_a),
            .caller_params = caller_params,
            .caller_title = host_title,
            .caller_transclusion_frame = self.transclusion_frame,
            .depth = depth,
        });
        return out;
    }

    fn buildExpandedArgs(self: *Expander, raw_args: []const []const u8, caller_params: *rt.Table, host_title: []const u8, depth: usize) anyerror!*rt.Table {
        const out = try self.runtime.newTable();
        var positional: i64 = 1;
        for (raw_args) |raw| {
            if (preprocess.findTopDelimiterWithConversion(raw, '=', self.provider.language_conversion_enabled orelse false)) |eq| {
                const key_origin = try self.expandWikitextTracked(raw[0..eq], caller_params, host_title, depth + 1);
                const key_expanded = key_origin.bytes;
                try self.rememberStringOrigin(try originResult(self.trimDependency(key_origin, " \t\r\n")));
                const key_text = std.mem.trim(u8, key_expanded, " \t\r\n");
                if (key_text.len == 0) continue;
                const key: Value = if (std.fmt.parseInt(i64, key_text, 10)) |number|
                    .{ .number = @floatFromInt(number) }
                else |_|
                    .{ .string = key_text };
                // PPTemplateFrame_Hash trims named arguments after expansion.
                const origin = try originResult(self.trimDependency(try self.expandWikitextTracked(raw[eq + 1 ..], caller_params, host_title, depth + 1), " \t\r\n\x00\x0b"));
                try self.rememberStringOrigin(origin);
                const value = origin.bytes;
                try out.rawSet(self.runtime.allocator, key, .{ .string = value });
            } else {
                const origin = try self.expandWikitextTracked(raw, caller_params, host_title, depth + 1);
                try self.rememberStringOrigin(origin);
                const value = origin.bytes;
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

    fn resolveTitleMagic(self: *Expander, raw: []const u8, form: rt.namespace_registry.magic_words.Form) !?[]const u8 {
        if (self.provider.resolve_title_magic) |resolve| return resolve(self.provider.ctx, raw, form);
        return if (isTitleMagicName(raw)) raw else null;
    }

    fn resolveParserFunction(self: *Expander, raw: []const u8) !?[]const u8 {
        if (self.provider.resolve_parser_function) |resolve| {
            if (try resolve(self.provider.ctx, raw)) |canonical| return canonical;
            // Retain the supported frame.callParserFunction("#tag:ref", args)
            // spelling while applying the same captured alias to its head.
            if (preprocess.findTopParserColonWithConversion(raw, self.provider.language_conversion_enabled orelse false)) |colon| {
                if (try resolve(self.provider.ctx, raw[0..colon.index])) |canonical| {
                    if (std.mem.eql(u8, canonical, "#tag"))
                        return try std.fmt.allocPrint(self.runtime.allocator, "#tag:{s}", .{raw[colon.index + colon.len ..]});
                }
            }
            // Revision variables are outside the captured function profile and
            // retain their existing implementation until that family is added.
            return if (isRevisionMagicName(raw)) raw else null;
        }
        return raw;
    }

    fn parserTitleMagic(self: *Expander, name: []const u8) !?[]const u8 {
        if (self.provider.resolve_parser_function != null)
            return if (isTitleMagicName(name)) name else null;
        // The shared alias provider may also contain non-title functions.
        const canonical = (try self.resolveTitleMagic(name, .parser_function)) orelse return null;
        return if (isTitleMagicName(canonical)) canonical else null;
    }

    fn categoryOption(self: *Expander, raw: []const u8) !?[]const u8 {
        const value = std.mem.trim(u8, raw, " \t\r\n");
        if (self.provider.resolve_title_magic) |resolve| return resolve(self.provider.ctx, value, .category_option);
        // Unconfigured unit callers retain the existing English-only fallback.
        inline for (.{ "all", "pages", "subcats", "files" }) |mode|
            if (std.ascii.eqlIgnoreCase(value, mode)) return "pagesincategory_" ++ mode;
        return null;
    }

    fn categoryRaw(self: *Expander, raw: []const u8) !bool {
        const value = std.mem.trim(u8, raw, " \t\r\n");
        if (self.provider.resolve_title_magic) |resolve| return (try resolve(self.provider.ctx, value, .raw_suffix)) != null;
        if (self.provider.raw_suffix_profile) return error.RawSuffixSnapshotMissing;
        return std.mem.eql(u8, value, "R");
    }

    // Use the installed ordinary title parser; parser functions must not invent
    // edition aliases or treat an external title as a missing local page.
    fn factTitle(self: *Expander, raw: []const u8, file: bool) anyerror!?[]const u8 {
        return try title_lib.parserFunctionTitle(self.runtime, raw, file);
    }

    fn filePathMagic(self: *Expander, raw_name: []const u8, first: []const u8, second: []const u8) anyerror![]const u8 {
        const title = (try self.factTitle(raw_name, true)) orelse return "";
        const nowiki_first = std.mem.eql(u8, first, "nowiki");
        const nowiki = nowiki_first or std.mem.eql(u8, second, "nowiki");
        const size_argument = if (nowiki_first) second else first;
        const resolve = self.provider.file_path orelse return error.FilePathSnapshotMissing;
        const url = try resolve(self.provider.ctx, title, size_argument);
        if (!nowiki or url.len == 0) return url;
        return hostFrameExtensionTag(self, self.runtime.allocator, "nowiki", .{ .string = url }, null);
    }

    fn pageSizeMagic(self: *Expander, raw_title: []const u8, raw_flag: []const u8) anyerror![]const u8 {
        const count: u64 = if (try self.factTitle(raw_title, false)) |title| blk: {
            const resolve = self.provider.page_size orelse return error.PageSizeSnapshotMissing;
            break :blk try resolve(self.provider.ctx, title);
        } else 0;
        if (try self.categoryRaw(raw_flag)) return std.fmt.allocPrint(self.runtime.allocator, "{d}", .{count});
        const format = self.provider.page_size_formatted orelse return error.PageSizeFormatSnapshotMissing;
        return try format(self.provider.ctx, self.page_allocator orelse self.runtime.allocator, count, .{
            .title = self.host.current_title,
            .source = self.current_source orelse "",
            .current = self.host.current_page,
            .normal_no_target = self.normal_page_format_context,
            .interface_message = if (self.normal_page_format_context) false else null,
        });
    }

    fn expandFilePageMagic(self: *Expander, name: []const u8, first: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const value = try self.expandTrimmedParserArgument(first, params, host_title, depth + 1);
        const arg1 = if (args.len > 0) try self.expandTrimmedParserArgument(args[0], params, host_title, depth + 1) else "";
        const arg2 = if (args.len > 1) try self.expandTrimmedParserArgument(args[1], params, host_title, depth + 1) else "";
        // Core ordinary callbacks eagerly expand ignored extra arguments too.
        if (args.len > 2) {
            for (args[2..]) |extra| {
                _ = try self.expandWikitext(extra, params, host_title, depth + 1);
            }
        }
        if (std.mem.eql(u8, name, "filepath")) return self.filePathMagic(value, arg1, arg2);
        return self.pageSizeMagic(value, arg1);
    }

    fn categoryCount(self: *Expander, name: []const u8, arg1: []const u8, arg2: []const u8) ![]const u8 {
        const get = self.provider.category_stats orelse return error.CategoryStatisticsSnapshotMissing;
        const first = try self.categoryOption(arg1);
        const second = try self.categoryOption(arg2);
        const raw_first = try self.categoryRaw(arg1);
        const raw_second = try self.categoryRaw(arg2);
        const option = (if (raw_first) second else first) orelse "pagesincategory_all";
        const mode = if (std.mem.eql(u8, option, "pagesincategory_pages")) "pages" else if (std.mem.eql(u8, option, "pagesincategory_subcats")) "subcats" else if (std.mem.eql(u8, option, "pagesincategory_files")) "files" else "all";
        const registry = self.runtime.namespace_catalog orelse return error.NamespaceRegistryRequired;
        const category_spec = registry.byId(14) orelse return error.UnknownNamespace;
        var count: u32 = 0;
        const title: ?[]u8 = registry.normalizeTitle(self.runtime.allocator, name, 14, .literal) catch |err| switch (err) {
            error.InvalidPageTitle => null,
            else => return err,
        };
        if (title) |canonical| {
            const text = registry.ofTitle(canonical).text;
            if (title_lib.validTitleBody(self.runtime, category_spec, text)) {
                const without_fragment = text[0 .. std.mem.indexOfScalar(u8, text, '#') orelse text.len];
                const key = try self.runtime.allocator.dupe(u8, without_fragment);
                for (key) |*byte| if (byte.* == ' ') {
                    byte.* = '_';
                };
                work_stats.noteCategory(key, mode);
                const stats = (try get(self.provider.ctx, key)) orelse Provider.CategoryStats{ .all = 0, .subcats = 0, .files = 0 };
                count = if (std.mem.eql(u8, mode, "pages")) stats.pages() else if (std.mem.eql(u8, mode, "subcats")) stats.subcats else if (std.mem.eql(u8, mode, "files")) stats.files else stats.all;
            }
        }
        if (raw_first or raw_second) return std.fmt.allocPrint(self.runtime.allocator, "{d}", .{count});
        const formatted = self.provider.category_statistics_formatted orelse return error.CategoryStatisticsFormatSnapshotMissing;
        return (try formatted(self.provider.ctx, count)) orelse error.CategoryStatisticsFormatSnapshotMissing;
    }

    fn namespacedPageAlloc(self: *Expander, spec: namespace_lib.Spec, text: []const u8) ![]const u8 {
        if (spec.id == 0) return text;
        return std.fmt.allocPrint(self.runtime.allocator, "{s}:{s}", .{ spec.name, text });
    }

    fn statisticsMagic(self: *Expander, name: []const u8, option: []const u8) !?[]const u8 {
        const index = rt.namespace_registry.magic_words.statisticsId(name) orelse return null;
        const captured = self.host.site_statistics orelse {
            self.runtime.last_error = .{ .string = try std.fmt.allocPrint(self.runtime.allocator, "Site statistics snapshot missing field={s}", .{name}) };
            return error.SiteInfoSnapshotMissing;
        };
        const raw = try std.fmt.allocPrint(self.runtime.allocator, "{d}", .{captured[index]});
        const trimmed_option = std.mem.trim(u8, option, " \t\r\n");
        // Exact R remains compatible with immutable older alias profiles.
        // Newer profiles add edition-local spellings with captured case rules.
        if ((!self.provider.raw_suffix_profile and std.mem.eql(u8, trimmed_option, "R")) or try self.categoryRaw(trimmed_option)) return raw;
        const formatted = self.provider.site_statistics_formatted orelse return error.SiteStatisticsFormatSnapshotMissing;
        return formatted[index];
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
        const implicit = raw_page == null or std.mem.trim(u8, raw_page.?, " \t\r\n").len == 0;
        const current = if (implicit) self.host.current_page else null;
        const canonical_with_fragment = if (current != null) requested else try namespace_lib.canonicalizeTitle(self.runtime.allocator, self.runtime, requested);
        const page = if (std.mem.indexOfScalar(u8, canonical_with_fragment, '#')) |hash|
            canonical_with_fragment[0..hash]
        else
            canonical_with_fragment;
        const ns = if (current) |identity| try namespace_lib.storedTitle(self.runtime, page, identity.namespace) else namespace_lib.ofTitle(self.runtime, page);
        const ns_spec = namespace_lib.byId(self.runtime, ns.id) orelse return error.InvalidNamespace;
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

            const subject = namespace_lib.subjectSpec(self.runtime, ns.id) orelse break :result "";
            if (std.ascii.eqlIgnoreCase(base_name, "SUBJECTSPACE") or std.ascii.eqlIgnoreCase(base_name, "ARTICLESPACE"))
                break :result subject.name;
            if (std.ascii.eqlIgnoreCase(base_name, "SUBJECTPAGENAME") or std.ascii.eqlIgnoreCase(base_name, "ARTICLEPAGENAME"))
                break :result try self.namespacedPageAlloc(subject, ns.text);
            const talk = namespace_lib.talkSpec(self.runtime, ns.id) orelse break :result "";
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
        if (raw_page == null or std.mem.trim(u8, raw_page.?, " \t\r\n").len == 0)
            if (self.host.current_page) |identity| return identity.metadata;
        const get = self.provider.page_metadata orelse return error.MissingPageMetadata;
        const requested = if (raw_page) |value| blk: {
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            break :blk if (trimmed.len == 0) self.host.current_title else trimmed;
        } else self.host.current_title;
        const canonical_with_fragment = try namespace_lib.canonicalizeTitle(self.runtime.allocator, self.runtime, requested);
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
        if (try self.revisionMagic(head, null)) |value| return value;
        if (std.mem.eql(u8, head, "!")) return "|";
        if (std.mem.eql(u8, head, "!!")) return "||";
        if (std.mem.eql(u8, head, "=")) return "=";
        if (std.ascii.eqlIgnoreCase(head, "SERVER")) return (try host_api.siteUrlConfig(self.runtime)).server;
        if (std.ascii.eqlIgnoreCase(head, "SERVERNAME")) return try uri_lib.configuredServerName(self.runtime);
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
        self.invalidateNativeDependencyArguments();
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
        self.invalidateNativeDependencyArguments();
        const language_result = try self.runtime.callValue(get_language, &.{});
        defer rt.freeResults(language_result);
        if (language_result.len == 0 or language_result[0] != .table) return error.TableExpected;
        const language = language_result[0];
        const callable = try self.runtime.getIndex(language, .{ .string = if (upper) "ucfirst" else "lcfirst" });
        self.invalidateNativeDependencyArguments();
        const result = try self.runtime.callValue(callable, &.{ language, .{ .string = text } });
        defer rt.freeResults(result);
        if (result.len == 0 or result[0] != .string) return error.StringExpected;
        return result[0].string;
    }

    // CoreParserFunctions::language at MediaWiki 0d3b507d19ae860ed8a1d22c73fa4bc5abf8dfcc:
    // empty code uses the parser target; empty display means autonym. A missing
    // captured profile remains an error, distinct from an unknown code in a
    // complete profile. Only the latter uses LanguageCode::bcp47 fallback.
    fn languageName(self: *Expander, raw_code: []const u8, raw_display: ?[]const u8) anyerror![]const u8 {
        const trimmed = std.mem.trim(u8, raw_code, " \t\r\n");
        const code = try std.ascii.allocLowerString(self.runtime.allocator, if (trimmed.len == 0)
            (self.runtime.namespace_catalog orelse return error.NamespaceRegistryRequired).content_language
        else
            trimmed);
        const display: ?[]const u8 = if (raw_display) |raw| blk: {
            const value = std.mem.trim(u8, raw, " \t\r\n");
            break :blk if (value.len == 0) null else try std.ascii.allocLowerString(self.runtime.allocator, value);
        } else null;
        const get = self.provider.language_name orelse {
            language_lib.languageNameMissing(code, display, "single");
            return error.LanguageNameSnapshotMissing;
        };
        const name = get(self.provider.ctx, code, display) catch |err| {
            if (err == error.LanguageNameSnapshotMissing) language_lib.languageNameMissing(code, display, "single");
            return err;
        };
        return if (name.len != 0) name else self.languageCodeBcp47(code);
    }

    // Exact deprecated/nonstandard maps and casing from retained LanguageCode.php
    // (17962f89468aa25369f126cc7a4edd8c074cb73497c8d4de77e8cbb04858d60d).
    fn languageCodeBcp47(self: *Expander, raw: []const u8) ![]const u8 {
        var code: []const u8 = raw;
        const deprecated = [_][2][]const u8{
            .{ "als", "gsw" },
            .{ "bat-smg", "sgs" },
            .{ "be-x-old", "be-tarask" },
            .{ "fiu-vro", "vro" },
            .{ "roa-rup", "rup" },
            .{ "zh-classical", "lzh" },
            .{ "zh-min-nan", "nan" },
            .{ "zh-yue", "yue" },
        };
        for (deprecated) |entry| if (std.mem.eql(u8, code, entry[0])) {
            code = entry[1];
            break;
        };
        const nonstandard = [_][2][]const u8{
            .{ "cbk-zam", "cbk" },
            .{ "de-formal", "de-x-formal" },
            .{ "eml", "egl" },
            .{ "en-rtl", "en-x-rtl" },
            .{ "es-formal", "es-x-formal" },
            .{ "hu-formal", "hu-x-formal" },
            .{ "map-bms", "jv-x-bms" },
            .{ "mo", "ro-Cyrl-MD" },
            .{ "nrm", "nrf" },
            .{ "nl-informal", "nl-x-informal" },
            .{ "roa-tara", "nap-x-tara" },
            .{ "simple", "en-simple" },
            .{ "sr-ec", "sr-Cyrl" },
            .{ "sr-el", "sr-Latn" },
            .{ "crh-ro", "crh-Latn-RO" },
            .{ "kk-cn", "kk-Arab-CN" },
            .{ "kk-tr", "kk-Latn-TR" },
            .{ "zh-cn", "zh-Hans-CN" },
            .{ "zh-sg", "zh-Hans-SG" },
            .{ "zh-my", "zh-Hans-MY" },
            .{ "zh-tw", "zh-Hant-TW" },
            .{ "zh-hk", "zh-Hant-HK" },
            .{ "zh-mo", "zh-Hant-MO" },
        };
        for (nonstandard) |entry| if (std.mem.eql(u8, code, entry[0])) {
            code = entry[1];
            break;
        };
        const out = try std.ascii.allocLowerString(self.runtime.allocator, code);
        var segments = std.mem.splitScalar(u8, out, '-');
        var index: usize = 0;
        var previous_private = false;
        while (segments.next()) |segment| : (index += 1) {
            const offset = @intFromPtr(segment.ptr) - @intFromPtr(out.ptr);
            const value = out[offset .. offset + segment.len];
            if (index != 0 and !previous_private) {
                if (value.len == 2) {
                    for (value) |*byte| byte.* = std.ascii.toUpper(byte.*);
                } else if (value.len == 4) {
                    value[0] = std.ascii.toUpper(value[0]);
                }
            }
            previous_private = std.ascii.eqlIgnoreCase(value, "x");
        }
        return out;
    }

    fn expandLanguageParser(self: *Expander, raw_code: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const code = try self.expandWikitext(raw_code, params, host_title, depth + 1);
        const display = if (args.len != 0) try self.expandWikitext(args[0], params, host_title, depth + 1) else null;
        return self.languageName(code, display);
    }

    fn expandCaseParser(self: *Expander, raw: []const u8, params: *rt.Table, host_title: []const u8, depth: usize, upper: bool, first_only: bool) anyerror![]const u8 {
        const expanded = try self.expandWikitext(raw, params, host_title, depth + 1);
        return if (first_only) self.contentLanguageFirstCase(expanded, upper) else self.unicodeCase(expanded, upper);
    }

    // MediaWiki numeric comparison accepts decimal numeric strings, not Zig literals.
    fn isDecimalNumericString(value: []const u8) bool {
        var pos: usize = 0;
        if (pos < value.len and (value[pos] == '+' or value[pos] == '-')) pos += 1;
        var digits: usize = 0;
        while (pos < value.len and std.ascii.isDigit(value[pos])) : (pos += 1) digits += 1;
        if (pos < value.len and value[pos] == '.') {
            pos += 1;
            while (pos < value.len and std.ascii.isDigit(value[pos])) : (pos += 1) digits += 1;
        }
        if (digits == 0) return false;
        if (pos < value.len and (value[pos] == 'e' or value[pos] == 'E')) {
            pos += 1;
            if (pos < value.len and (value[pos] == '+' or value[pos] == '-')) pos += 1;
            const exponent_start = pos;
            while (pos < value.len and std.ascii.isDigit(value[pos])) : (pos += 1) {}
            if (pos == exponent_start) return false;
        }
        return pos == value.len;
    }

    fn numericStringEqual(lhs: []const u8, rhs: []const u8) bool {
        if (!isDecimalNumericString(lhs) or !isDecimalNumericString(rhs)) return false;
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

    // PHP's float cast accepts a decimal prefix, unlike Zig parseFloat which
    // accepts underscores and hexadecimal floats. An incomplete exponent is
    // outside the prefix; a missing mantissa becomes the caller's zero.
    fn decimalNumberPrefix(value: []const u8) []const u8 {
        var pos: usize = 0;
        if (pos < value.len and (value[pos] == '+' or value[pos] == '-')) pos += 1;
        var digits: usize = 0;
        while (pos < value.len and std.ascii.isDigit(value[pos])) : (pos += 1) digits += 1;
        if (pos < value.len and value[pos] == '.') {
            pos += 1;
            while (pos < value.len and std.ascii.isDigit(value[pos])) : (pos += 1) digits += 1;
        }
        if (digits == 0) return "";
        const mantissa_end = pos;
        if (pos < value.len and (value[pos] == 'e' or value[pos] == 'E')) {
            pos += 1;
            if (pos < value.len and (value[pos] == '+' or value[pos] == '-')) pos += 1;
            const exponent_start = pos;
            while (pos < value.len and std.ascii.isDigit(value[pos])) : (pos += 1) {}
            if (pos == exponent_start) pos = mantissa_end;
        }
        return value[0..pos];
    }

    fn expandPlural(self: *Expander, number_raw: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const expanded_number = std.mem.trim(u8, try self.expandWikitext(number_raw, params, host_title, depth + 1), " \t\r\n");
        const number = try language_lib.parseFormattedNumberAlloc(self.runtime.allocator, expanded_number);

        // CoreParserFunctions coerces digit-only counts to PHP integers and all
        // other counts to floats before plural evaluation. Reuse the runtime's
        // PHP-compatible 14-digit formatting so 1.0 and -1 select English one.
        var digits_only = number.len != 0;
        for (number) |byte| digits_only = digits_only and std.ascii.isDigit(byte);
        const normalized = if (digits_only)
            try std.fmt.allocPrint(self.runtime.allocator, "{d}", .{std.fmt.parseInt(i64, number, 10) catch std.math.maxInt(i64)})
        else
            try rt.numberToString(self.runtime.allocator, std.fmt.parseFloat(f64, decimalNumberPrefix(number)) catch 0);
        defer self.runtime.allocator.free(normalized);

        var forms: std.ArrayList([]const u8) = .empty;
        defer forms.deinit(self.runtime.allocator);
        for (args) |raw_form| {
            if (preprocess.findTopDelimiterWithConversion(raw_form, '=', self.provider.language_conversion_enabled orelse false)) |eq| {
                const label_expanded = std.mem.trim(
                    u8,
                    try self.expandWikitext(raw_form[0..eq], params, host_title, depth + 1),
                    " \t\r\n",
                );
                // Deployed positional PLURAL marks a digit-suffixed label as
                // explicit and compares its text exactly with the coerced count.
                // Keep the existing top-level delimiter and lazy form boundary.
                const label = label_expanded;
                if (label.len != 0 and std.ascii.isDigit(label[label.len - 1])) {
                    if (std.mem.eql(u8, normalized, label))
                        return self.expandTrimmedParserArgument(raw_form[eq + 1 ..], params, host_title, depth + 1);
                    continue;
                }
            }
            try forms.append(self.runtime.allocator, raw_form);
        }

        if (forms.items.len == 0) return "";
        if (forms.items.len == 1)
            return self.expandTrimmedParserArgument(forms.items[0], params, host_title, depth + 1);

        var language = (self.runtime.namespace_catalog orelse return error.NamespaceRegistryMissing).content_language;
        if (!plural_rules.hasRules(language)) {
            // The snapshot stores MediaWiki STRICT fallbacks. Language's normal
            // plural lookup uses MESSAGES: preserve that order, then append en.
            // A missing captured row is an input error, never an empty chain.
            const get_fallbacks = self.provider.language_fallbacks orelse return error.LanguageFallbackSnapshotMissing;
            const fallbacks = try get_fallbacks(self.provider.ctx, language);
            language = "en";
            for (fallbacks) |fallback| {
                if (plural_rules.hasRules(fallback)) {
                    language = fallback;
                    break;
                }
            }
        }
        const rule_index = plural_rules.index(language, normalized).?;
        return self.expandTrimmedParserArgument(forms.items[@min(rule_index, forms.items.len - 1)], params, host_title, depth + 1);
    }

    fn expandSwitch(self: *Expander, key_raw: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const key = std.mem.trim(u8, try self.expandWikitext(key_raw, params, host_title, depth + 1), " \t\r\n");
        var pending_match = false;
        var pending_default = false;
        var fallback: ?[]const u8 = null;
        var trailing: ?[]const u8 = null;
        for (args, 0..) |raw_case, index| {
            if (preprocess.findTopDelimiterWithConversion(raw_case, '=', self.provider.language_conversion_enabled orelse false)) |eq| {
                const value_raw = raw_case[eq + 1 ..];
                // A matched bare case selects this result without evaluating its label.
                if (pending_match) return self.expandTrimmedParserArgument(value_raw, params, host_title, depth + 1);
                const label = std.mem.trim(u8, try self.expandWikitext(raw_case[0..eq], params, host_title, depth + 1), " \t\r\n");
                if (ifEqEqual(key, label)) return self.expandTrimmedParserArgument(value_raw, params, host_title, depth + 1);
                if (pending_default or std.ascii.eqlIgnoreCase(label, "#default")) {
                    fallback = value_raw;
                    pending_default = false;
                }
            } else {
                if (index + 1 == args.len) {
                    trailing = raw_case;
                    continue;
                }
                const label = std.mem.trim(u8, try self.expandWikitext(raw_case, params, host_title, depth + 1), " \t\r\n");
                if (ifEqEqual(key, label)) {
                    pending_match = true;
                } else if (std.ascii.eqlIgnoreCase(label, "#default")) {
                    pending_default = true;
                }
            }
        }
        if (trailing) |value| return self.expandTrimmedParserArgument(value, params, host_title, depth + 1);
        if (fallback) |value| return self.expandTrimmedParserArgument(value, params, host_title, depth + 1);
        return "";
    }

    fn expandIfExist(self: *Expander, raw_title: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const expanded = try self.expandWikitext(raw_title, params, host_title, depth + 1);
        const decoded = if (std.mem.indexOfScalar(u8, expanded, '&') != null)
            try shared_xml_decode.decodeSinglePassAlloc(self.runtime.allocator, expanded)
        else
            expanded;
        var title = std.mem.trim(u8, decoded, " \t\r\n");
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

    // These serializers may prove absence of missing dependencies only from
    // their actual consumed inputs. Escaping/reordering is not a range map.
    const NativeSerializationProvenance = struct {
        conversion_enabled: bool = false,
        known: bool = true,
        lost_missing_range: bool = false,

        fn include(self: *@This(), value: dependency.Text) void {
            self.lost_missing_range = self.lost_missing_range or value.lost_missing_range or value.ranges.len != 0;
            var scan: preprocess.ExpansionScan = .{ .conversion_enabled = self.conversion_enabled };
            self.known = self.known and !value.unknown and !value.lost_missing_range and
                value.ranges.len == 0 and value.literal_curly_ranges.len == 0 and
                value.generated_links.len == 0 and value.generated_source == null and
                scan.next(value.bytes, 0, false) == null;
        }

        fn finish(self: @This(), expander: *const Expander, bytes: []const u8) dependency.Text {
            return .{
                .bytes = bytes,
                .unknown = !self.known or expander.dependency_native_arguments_disabled or expander.dependency_page.metadata_unknown,
                .lost_missing_range = self.lost_missing_range,
            };
        }
    };

    fn expandUrlParser(self: *Expander, raw: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize, kind: uri_lib.WikiUrlKind, escaped: bool) anyerror![]const u8 {
        return (try self.expandUrlParserTracked(raw, args, params, host_title, depth, kind, escaped)).bytes;
    }

    fn expandUrlParserTracked(self: *Expander, raw: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize, kind: uri_lib.WikiUrlKind, escaped: bool) anyerror!dependency.Text {
        var provenance: NativeSerializationProvenance = .{ .known = kind == .local and !escaped, .conversion_enabled = self.provider.language_conversion_enabled orelse false };
        const expanded_title = try self.expandWikitextTracked(raw, params, host_title, depth + 1);
        provenance.include(expanded_title);
        const title = std.mem.trim(u8, expanded_title.bytes, " \t\r\n");
        const query: ?[]const u8 = if (args.len == 0) null else blk: {
            const expanded_query = try self.expandWikitextTracked(args[0], params, host_title, depth + 1);
            provenance.include(expanded_query);
            break :blk expanded_query.bytes;
        };
        // Do not turn an active missing parameter into a percent-encoded click
        // destination. Inspect only after protecting proven literal curly atoms;
        // authored percent escapes and protected/entity literals remain unchanged.
        const inspected_title = try dependency.escapeLiteralCurly(self.runtime.allocator, expanded_title);
        var title_scan: preprocess.ExpansionScan = .{ .conversion_enabled = self.provider.language_conversion_enabled orelse false };
        var title_pos: usize = 0;
        while (title_scan.next(inspected_title.bytes, title_pos, false)) |node| {
            switch (node) {
                .construct => |construct| {
                    if (construct.kind == .parameter) {
                        provenance.known = false;
                        return provenance.finish(self, title);
                    }
                    title_pos = construct.close + 2;
                },
                .poem => unreachable, // include_poem is false above.
            }
        }
        const bytes = try uri_lib.buildSiteWikiUrlRawQuery(self.runtime.allocator, title, query, kind, escaped, null, try host_api.siteUrlConfig(self.runtime));
        return provenance.finish(self, bytes);
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
        self.invalidateNativeDependencyArguments();
        const result = try self.runtime.callValue(encode, call_args[0..count]);
        defer rt.freeResults(result);
        if (result.len == 0 or result[0] != .string) return error.StringExpected;
        return result[0].string;
    }

    fn copyArgsTable(runtime: *rt.Context, source: *rt.Table, own_strings: bool) !*rt.Table {
        const out = try runtime.newTable();
        var it = source.iterator();
        while (it.next()) |entry| {
            const key: Value = if (own_strings and entry.key_ptr.* == .string)
                .{ .string = try runtime.ownString(entry.key_ptr.string) }
            else
                entry.key_ptr.*;
            const value: Value = if (own_strings and entry.value_ptr.* == .string)
                .{ .string = try runtime.ownString(entry.value_ptr.string) }
            else
                entry.value_ptr.*;
            try out.rawSet(runtime.allocator, key, value);
        }
        return out;
    }

    fn callSymbol(self: *Expander, raw: []const u8, kind: CallSymbolKind) anyerror!?CallSymbol {
        const resolve = self.provider.resolve_call_symbol orelse return null;
        return resolve(self.provider.ctx, self.runtime, raw, kind);
    }

    const InvokeOutcome = union(enum) {
        generated: []const u8,
        error_markup: []const u8,
        export_error: struct { failure: anyerror, markup: []const u8 },
    };

    fn clearInvokeFailure(runtime: *rt.Context) void {
        runtime.clearLuaError();
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

    fn scribuntoErrorMarkup(self: *Expander, module_name: ?[]const u8, detail: []const u8) ![]const u8 {
        const a = self.runtime.allocator;
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, "<strong class=\"error\"><span class=\"scribunto-error\">");
        if (module_name) |name| {
            try out.appendSlice(a, "Lua error in ");
            try appendHtmlTextEscaped(&out, a, name);
            try out.appendSlice(a, ": ");
        }
        try appendHtmlTextEscaped(&out, a, detail);
        try out.appendSlice(a, "</span></strong>");
        return out.toOwnedSlice(a);
    }

    // Scribunto Hooks::invokeHook validates the outer module before expanding
    // its function/arguments. This is not Lua require() recovery: dependencies
    // and pcall keep their existing errors and package.loaded semantics.
    fn missingInvokeModuleMarkup(self: *Expander, requested: []const u8) ![]const u8 {
        const plain = try message_lib.interfaceMessagePlain(self.runtime, "scribunto-common-nosuchmodule", &.{
            .{ .string = "(unknown code location)" }, .{ .string = requested },
        });
        return self.scribuntoErrorMarkup(null, plain);
    }
    fn preflightInvokeModule(self: *Expander, module_name: []const u8, requested: []const u8) !?[]const u8 {
        _ = self.runtime.resolveModule(module_name) catch |failure| switch (failure) {
            error.ModuleNotFound => return try self.missingInvokeModuleMarkup(requested),
            else => return failure,
        };
        return null;
    }

    fn invokeExportErrorMarkup(self: *Expander, failure: anyerror, module_name: []const u8, function_name: []const u8) !?[]const u8 {
        const detail = switch (failure) {
            error.InvokeModuleNotTable => try self.runtime.allocator.dupe(u8, "The module did not return an export table."),
            error.InvokeFunctionMissing => try std.fmt.allocPrint(self.runtime.allocator, "The function \"{s}\" does not exist.", .{function_name}),
            error.InvokeExportNotFunction => try std.fmt.allocPrint(self.runtime.allocator, "\"{s}\" is not a function.", .{function_name}),
            else => return null,
        };
        defer self.runtime.allocator.free(detail);
        return try self.scribuntoErrorMarkup(module_name, detail);
    }

    fn storedIdentityFailure(name: []const u8) ?anyerror {
        inline for ([_]anyerror{ error.UnsupportedStoredInterwikiNamespace, error.UnsupportedStoredLocalInterwiki, error.InvalidStoredRedirectTarget, error.NamespaceTitleCollision }) |failure|
            if (std.mem.eql(u8, name, @errorName(failure))) return failure;
        return null;
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
            if (err == error.LuaCpuLimit) return .{ .error_markup = try self.scriptTimeoutMarkup(module_name) };
            if (try self.invokeExportErrorMarkup(err, module_name, function_name)) |markup| {
                clearInvokeFailure(self.runtime);
                return .{ .export_error = .{ .failure = err, .markup = markup } };
            }
            if (err != error.AotCallFailed and err != error.LuaRaised) return err;
            // Operational failures retain their typed name across the native
            // AOT call envelope. Let the worker retire and retry the page.
            // Lua error("OutOfMemory") instead carries the name LuaRaised.
            if (self.runtime.aotErrorName()) |name| {
                if (std.mem.eql(u8, name, "OutOfMemory")) return error.OutOfMemory;
                if (std.mem.eql(u8, name, "LuaCpuClockUnavailable")) return error.LuaCpuClockUnavailable;
                if (storedIdentityFailure(name)) |failure| return failure;
            }
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
                        if (retry_err == error.LuaCpuLimit) return .{ .error_markup = try self.scriptTimeoutMarkup(module_name) };
                        if (try self.invokeExportErrorMarkup(retry_err, module_name, function_name)) |markup| {
                            clearInvokeFailure(self.runtime);
                            return .{ .export_error = .{ .failure = retry_err, .markup = markup } };
                        }
                        if (retry_err != error.AotCallFailed and retry_err != error.LuaRaised) return retry_err;
                        if (self.runtime.aotErrorName()) |name| {
                            if (std.mem.eql(u8, name, "OutOfMemory")) return error.OutOfMemory;
                            if (std.mem.eql(u8, name, "LuaCpuClockUnavailable")) return error.LuaCpuClockUnavailable;
                            if (storedIdentityFailure(name)) |failure| return failure;
                        }
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

    fn scriptTimeoutMarkup(self: *Expander, module_name: []const u8) ![]const u8 {
        clearInvokeFailure(self.runtime);
        const lookup = self.provider.interface_message orelse return error.InterfaceMessageSnapshotMissing;
        const language = self.runtime.namespace_catalog.?.content_language;
        const message = (try lookup(self.provider.ctx, self.runtime.allocator, language, "scribunto-common-timeout")) orelse return error.InterfaceMessageSnapshotMissing;
        // Captured upstream absence is a semantic limitation, not uncaptured input.
        const source = message.source orelse return error.UnsupportedScriptTimeoutMessage;
        return self.scribuntoErrorMarkup(module_name, source);
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
        try self.script_cpu_budget.checkState();
        if (work_stats.current()) |work| work.invoke_attempts +|= 1;
        var function_probe: invoke_reuse_stats.FunctionProbe = undefined;
        if (self.invoke_reuse) |stats| stats.beginFunction(&function_probe, module_id, module_name, function_name);
        defer if (self.invoke_reuse) |stats| stats.finishFunction(&function_probe);
        const invoke_start = work_stats.cpuNow();
        defer {
            if (work_stats.current()) |work| work.invoke_ns +|= work_stats.elapsed(invoke_start);
        }
        var completed = false;
        var host_probe: host_api.InvokeHostProbe = undefined;
        if (self.invoke_reuse != null) host_probe = .{};
        const ticket = if (self.invoke_reuse) |stats| stats.observe(
            module_id,
            module_name,
            function_name,
            invoke_args,
            existing_parent,
            parent_title,
            parent_args,
            if (work_stats.current()) |work| work.sampled else false,
        ) else null;
        defer if (self.invoke_reuse) |stats| stats.finish(ticket, completed, host_probe.observed);
        const install = self.install_scribunto orelse return error.MissingScribuntoInstaller;
        const page_a = self.page_allocator orelse self.runtime.allocator;
        const outer_runtime = self.runtime;
        try self.ensurePageModuleTemplates();

        const translation_show = std.mem.eql(u8, module_name, "Module:translations") and
            std.mem.eql(u8, function_name, "show");
        const reuse_translation = translation_show and !self.hot_translation_active and
            self.hot_translation_runtime != self.runtime;
        const reuse_page_runtime = !translation_show and
            !self.page_invoke_active and
            self.runtime == self.page_runtime and
            self.page_invoke_runtime != self.runtime;
        const retain_runtime = reuse_translation or reuse_page_runtime;
        // A fresh nested invoke can itself recurse. Pointer inequality alone
        // would re-enter the still-active cached child at the third level.
        if (reuse_page_runtime) self.page_invoke_active = true;
        defer if (reuse_page_runtime) {
            self.page_invoke_active = false;
        };
        if (reuse_translation) self.hot_translation_active = true;
        defer if (reuse_translation) {
            self.hot_translation_active = false;
        };
        var invoke_arena = LocalBumpArena.init(page_a);
        defer if (!retain_runtime) invoke_arena.deinit();
        var suspended_rollback: ?*rt.InvokeRollbackJournal = null;
        if (!reuse_page_runtime) suspended_rollback = rt.suspendInvokeRollback();
        defer if (!reuse_page_runtime) rt.resumeInvokeRollback(suspended_rollback);
        var stack_child: rt.Context = undefined;
        var child: *rt.Context = undefined;
        var owns_stack_child = false;
        if (retain_runtime) {
            // The specialized translations graph is deliberately page-lived;
            // general invoke rollback must neither reset nor overwrite it.
            const cache = if (reuse_translation) &self.hot_translation_runtime else &self.page_invoke_runtime;
            if (cache.*) |cached| {
                child = cached;
                child.clearLuaError();
                child.clearAotErrorName();
                child.current_frame = null;
            } else {
                const cached = try page_a.create(rt.Context);
                const template_runtime = self.page_runtime orelse outer_runtime;
                cached.* = try template_runtime.forkProgram(page_a);
                // Retained strings, cells and closure descriptors share the
                // context arena. Resizable tables keep their freeing allocator.
                cached.ownClonedStrings();
                cached.retain_invoke_cell_baselines = reuse_page_runtime;
                const global_shape = if (outer_runtime.global_table) |global| global.shape else null;
                try rt.bindGlobalTable(cached, global_shape, self.env_slot);
                if (!try cached.bootstrapProgram()) try stdlib.install(cached);
                try install(&self.scribunto_state, self.scribunto_shared, page_a, cached, self.env_slot, self.string_slot, self.mw_slot);
                cached.module_template_context = template_runtime;
                cached.module_template_eligible = self.page_template_eligible;
                cached.module_template_rejected = self.page_template_rejected;
                cached.module_template_page_scope = true;
                cache.* = cached;
                child = cached;
            }
        } else {
            stack_child = try outer_runtime.forkProgram(invoke_arena.allocator());
            owns_stack_child = true;
            stack_child.useContextAllocatorForStrings();
            const global_shape = if (outer_runtime.global_table) |global| global.shape else null;
            try rt.bindGlobalTable(&stack_child, global_shape, self.env_slot);
            if (!try stack_child.bootstrapProgram()) try stdlib.install(&stack_child);
            try install(&self.scribunto_state, self.scribunto_shared, page_a, &stack_child, self.env_slot, self.string_slot, self.mw_slot);
            // A nested #invoke is a fresh Scribunto invocation, not another
            // require in the caller's mutable module graph.
            stack_child.module_template_context = self.page_runtime orelse outer_runtime;
            stack_child.module_template_eligible = self.page_template_eligible;
            stack_child.module_template_rejected = self.page_template_rejected;
            stack_child.module_template_page_scope = true;
            child = &stack_child;
        }
        defer if (owns_stack_child) child.deinit();

        var rollback_journal: rt.InvokeRollbackJournal = undefined;
        var rollback_active = false;
        if (reuse_page_runtime) {
            rollback_journal = rt.InvokeRollbackJournal.init(page_a, child);
            rollback_journal.begin();
            rollback_active = true;
        }
        defer if (rollback_active) {
            rollback_journal.rollback(child);
        };

        const saved_runtime = self.runtime;
        self.runtime = child;
        defer self.runtime = saved_runtime;

        // A page-reused child can retain argument strings through memoized Lua
        // tables until rollback, so give it page-owned copies. Fresh nested
        // invoke children still borrow from their shorter-lived arena.
        var origin_observer: rt.string_origins.Observer = undefined;
        const saved_observer = if (self.origin_ledger) |origins| blk: {
            origin_observer = string_origin.observer(origins);
            break :blk rt.string_origins.enter(&origin_observer);
        } else null;
        defer if (self.origin_ledger != null) {
            if (owns_stack_child) rt.string_origins.retired(@intFromPtr(child));
            rt.string_origins.restore(saved_observer);
        };
        const copied_invoke_args = try copyArgsTable(child, invoke_args, retain_runtime);
        const parent: ?Value = if (existing_parent) |frame|
            frame
        else if (parent_title) |title| blk: {
            const source_args = parent_args orelse return error.MissingInvokeParentArgs;
            const copied_parent_args = try copyArgsTable(child, source_args, retain_runtime);
            break :blk try frame_lib.makeFrameFromTable(child, title, copied_parent_args, null);
        } else null;
        const frame = try frame_lib.makeFrameFromTable(child, module_name, copied_invoke_args, parent);
        if (self.invoke_reuse != null) host_api.beginInvokeHostProbe(&host_probe);
        defer if (self.invoke_reuse != null) host_api.endInvokeHostProbe(&host_probe);
        var cpu_scope = try self.script_cpu_budget.enter();
        const text = frame_lib.invokeText(child, module_id, module_name, function_name, frame) catch |err| {
            var quota_error: ?anyerror = null;
            cpu_scope.finish() catch |failure| {
                quota_error = failure;
            };
            try rt.string_origins.check();
            try outer_runtime.adoptFailure(child);
            // Resource exhaustion remains operational even if it coincides
            // with the script timer. Only the distinct quota gets markup.
            const failure_name = child.aotErrorName() orelse @errorName(err);
            if (err == error.OutOfMemory or std.mem.eql(u8, failure_name, "OutOfMemory")) return error.OutOfMemory;
            if (err == error.Timeout or std.mem.eql(u8, failure_name, "Timeout")) return error.Timeout;
            if (quota_error) |failure| return failure;
            return err;
        };
        try cpu_scope.finish();
        try rt.string_origins.check();
        // Scribunto's #invoke hook cleans the returned wikitext, not Lua's
        // internal byte strings. Reuse the immutable namespace NFC backend.
        const catalog = child.namespace_catalog orelse return error.MissingNamespaceCatalog;
        const owned = try ustring_lib.cleanInvokeTextAlloc(page_a, catalog, text);
        // NFC/control cleaning is mapped only when this identified operation
        // leaves bytes unchanged; all other transformations stay unknown.
        if (self.origin_ledger) |origins| try originResult(origins.copied(@intFromPtr(self), text, owned));
        completed = true;
        return owned;
    }

    fn expandInvoke(self: *Expander, module_expr: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        if (!self.dependency_native_arguments_disabled) if (self.origin_ledger) |origins| {
            for (self.dependency_arguments.items) |item| {
                const current = item.target.rawGet(item.key) orelse continue;
                if (current == .string and current.string.ptr == item.cached_bytes.ptr and current.string.len == item.cached_bytes.len and
                    std.mem.eql(u8, current.string, item.value.bytes)) try originResult(origins.remember(@intFromPtr(self.runtime), item.value));
            }
        };
        self.invalidateNativeDependencyArguments();
        if (work_stats.current()) |work| work.invokes +|= 1;
        const module_symbol = try self.callSymbol(module_expr, .module);
        const module_raw = if (module_symbol) |symbol|
            symbol.text
        else
            try self.expandWikitext(module_expr, params, host_title, depth + 1);
        const module_trimmed = std.mem.trim(u8, module_raw, " \t\r\n");
        const module_name = try self.runtime.namespace_catalog.?.normalizeTitle(self.runtime.allocator, module_trimmed, 828, .only_default);
        if (args.len != 0 and (if (module_symbol) |symbol| symbol.module_id == null else true))
            if (try self.preflightInvokeModule(module_name, module_trimmed)) |markup| return markup;
        const function_symbol = if (args.len != 0) try self.callSymbol(args[0], .function) else null;
        const function_name = if (function_symbol) |symbol|
            symbol.text
        else if (args.len != 0)
            std.mem.trim(u8, try self.expandWikitext(args[0], params, host_title, depth + 1), " \t\r\n")
        else
            "main";

        const runtime = self.runtime;
        // Lua frame arguments are eager here, before the new Lua CPU scope.
        // A surrounding unpaused Lua callback must still charge this work;
        // do not pause generic template parameter expansion.
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
            // Lua values may contain registered results from explicit frame
            // APIs. Preserve those items while returned tag text stays unhooked.
            .generated => |generated| blk: {
                var result = try self.expandWikitextModeTracked(generated, params, host_title, depth + 1, false, true, null);
                if (self.origin_ledger) |origins| {
                    const input = try originResult(origins.read(generated));
                    if (input.unknown or input.lost_missing_range or input.ranges.len != 0) {
                        result.unknown = true;
                        result.lost_missing_range = result.lost_missing_range or input.lost_missing_range or input.ranges.len != 0;
                    }
                    try originResult(origins.remember(@intFromPtr(self.runtime), result));
                }
                break :blk result.bytes;
            },
            .error_markup => |markup| markup,
            .export_error => |failure| blk: {
                if (self.usage_recovery) |recovery| {
                    const module = self.runtime.namespace_catalog.?.ofTitle(module_name);
                    if (failure.failure == error.InvokeFunctionMissing and recovery.args == params and
                        recovery.exact_wrapper and module.id == 828 and std.mem.eql(u8, module.text, "usex") and
                        std.mem.eql(u8, function_name, "display")) recovery.missing_display = true;
                }
                break :blk failure.markup;
            },
        };
    }

    fn expandTagParser(self: *Expander, raw_tag: []const u8, raw_args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        return (try self.expandTagParserTracked(raw_tag, raw_args, params, host_title, depth)).bytes;
    }

    fn expandTagParserTracked(self: *Expander, raw_tag: []const u8, raw_args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror!dependency.Text {
        var provenance: NativeSerializationProvenance = .{
            .conversion_enabled = self.provider.language_conversion_enabled orelse false,
            .known = std.ascii.eqlIgnoreCase(std.mem.trim(u8, raw_tag, " \t\r\n\x00\x0b"), "references"),
        };
        const expanded_tag = try self.expandWikitextTracked(raw_tag, params, host_title, depth + 1);
        provenance.include(expanded_tag);
        const tag = std.mem.trim(u8, try text_lib.killMarkersAlloc(self.runtime.allocator, expanded_tag.bytes), " \t\r\n\x00\x0b");
        const canonical = canonicalExtensionTag(tag);
        const poem_argument = if (canonical) |name| std.mem.eql(u8, name, "poem") else false;
        if (poem_argument) self.poem_argument_depth += 1;
        defer {
            if (poem_argument) self.poem_argument_depth -= 1;
        }
        const content: ?Value = if (raw_args.len == 0)
            (if (canonical == null) null else .{ .string = "" })
        else blk: {
            const expanded_content = try self.expandWikitextTracked(raw_args[0], params, host_title, depth + 1);
            provenance.include(expanded_content);
            break :blk .{ .string = expanded_content.bytes };
        };
        var attrs: ?*rt.Table = null;
        if (raw_args.len > 1) {
            const table = try self.runtime.newTable();
            for (raw_args[1..]) |raw| {
                const eq = preprocess.findTopDelimiterWithConversion(raw, '=', self.provider.language_conversion_enabled orelse false) orelse continue;
                const expanded_key = try self.expandWikitextTracked(raw[0..eq], params, host_title, depth + 1);
                provenance.include(expanded_key);
                const key = std.mem.trim(u8, expanded_key.bytes, " \t\r\n");
                if (key.len == 0) continue;
                const expanded = try self.expandWikitextTracked(raw[eq + 1 ..], params, host_title, depth + 1);
                provenance.include(expanded);
                const value = parserTagAttributeValue(expanded.bytes);
                try table.rawSet(self.runtime.allocator, .{ .string = key }, .{ .string = value });
            }
            attrs = table;
        }
        if (poem_argument) return dependency.Text.transformed(try self.expandPoemValue(if (content) |value| try self.scalarText(value) else "", attrs, params, host_title, depth + 1));
        const bytes = if (canonical) |name| try self.serializeExtension(name, content, attrs) else try self.serializeOrdinaryTag(tag, content, attrs);
        return provenance.finish(self, bytes);
    }

    fn expandIntParser(
        self: *Expander,
        head: []const u8,
        first: []const u8,
        raw_args: []const []const u8,
        params: *rt.Table,
        host_title: []const u8,
        depth: usize,
    ) anyerror![]const u8 {
        // CoreParserFunctions::intFunction uses plain() with expanded, trimmed
        // parameters; noparse=false then expands the message in a child frame.
        const key = std.mem.trim(u8, try self.expandWikitext(first, params, host_title, depth + 1), " \t\r\n\x00\x0b");
        if (key.len == 0) return self.emptyComputedTransclusion(head, raw_args, params, host_title, depth, false);
        const values = try self.runtime.allocator.alloc(Value, raw_args.len);
        defer self.runtime.allocator.free(values);
        for (raw_args, values) |raw, *value| {
            value.* = .{ .string = std.mem.trim(u8, try self.expandWikitext(raw, params, host_title, depth + 1), " \t\r\n\x00\x0b") };
        }
        const plain = try message_lib.interfaceMessagePlain(self.runtime, key, values);
        const child_args = try self.buildTemplateArgs(raw_args, params, host_title, depth + 1);
        return self.expandWikitext(plain, child_args, host_title, depth + 1);
    }

    // LabeledSectionTransclusion::setupPfunc12 / pfuncIncludeObj, upstream
    // 090442c1117b712be1c08582712da802b9da46aa. Select preprocessor-level
    // source nodes before expansion: excluded templates cannot supply markers.
    const TransclusionFrame = struct { title: []const u8, parent: ?*const TransclusionFrame };
    const LstSection = struct { open: usize, attrs: []const u8, inner: []const u8, end: usize };

    fn lstLocalName(self: *Expander, key: []const u8) []const u8 {
        const lang = (self.runtime.namespace_catalog orelse return key).content_language;
        if (std.mem.eql(u8, lang, "de")) {
            if (std.mem.eql(u8, key, "section")) return "Abschnitt";
            return if (std.mem.eql(u8, key, "begin")) "Anfang" else "Ende";
        }
        if (std.mem.eql(u8, lang, "he")) {
            if (std.mem.eql(u8, key, "section")) return "קטע";
            return if (std.mem.eql(u8, key, "begin")) "התחלה" else "סוף";
        }
        if (std.mem.eql(u8, lang, "pt")) {
            if (std.mem.eql(u8, key, "section")) return "trecho";
            return if (std.mem.eql(u8, key, "begin")) "começo" else "fim";
        }
        return key;
    }

    fn lstSectionAt(self: *Expander, text: []const u8, open: usize) ?LstSection {
        if (text[open] != '<' or open + 1 >= text.len or text[open + 1] == '/') return null;
        var p = open + 1;
        const name_start = p;
        while (p < text.len and text[p] != '>' and text[p] != '/' and !std.ascii.isWhitespace(text[p])) : (p += 1) {}
        const name = text[name_start..p];
        if (!std.ascii.eqlIgnoreCase(name, "section") and !std.ascii.eqlIgnoreCase(name, self.lstLocalName("section"))) return null;
        const opening_end = preprocess.rawTagEnd(text, open) orelse return null;
        var attrs_end = opening_end - 1;
        while (attrs_end > p and std.ascii.isWhitespace(text[attrs_end - 1])) : (attrs_end -= 1) {}
        const self_closing = attrs_end > p and text[attrs_end - 1] == '/';
        if (self_closing) attrs_end -= 1;
        var end = opening_end;
        var inner: []const u8 = "";
        if (!self_closing) {
            var search = opening_end;
            while (std.mem.indexOfScalarPos(u8, text, search, '<')) |lt| {
                if (lt + name.len + 2 < text.len and text[lt + 1] == '/' and std.ascii.eqlIgnoreCase(text[lt + 2 .. lt + 2 + name.len], name)) {
                    const boundary = lt + 2 + name.len;
                    if (text[boundary] == '>' or std.ascii.isWhitespace(text[boundary])) {
                        end = preprocess.rawTagEnd(text, lt) orelse text.len;
                        inner = text[opening_end..lt];
                        break;
                    }
                }
                search = lt + 1;
            }
        }
        return .{ .open = open, .attrs = text[p..attrs_end], .inner = inner, .end = end };
    }

    fn nextLstSection(self: *Expander, text: []const u8, start: usize) ?LstSection {
        var p = start;
        var opaque_scan: preprocess.OpaqueParserScan = .{};
        while (p < text.len) {
            if (text[p] == '<') {
                if (self.lstSectionAt(text, p)) |section| return section;
                if (opaque_scan.end(text, p)) |end| {
                    p = end;
                    continue;
                }
            }
            if (p + 1 < text.len and text[p] == '{' and text[p + 1] == '{') {
                if (preprocess.findNextConstructOutsideLiteralTags(text, p)) |construct| {
                    if (construct.open == p) {
                        p = construct.close + @as(usize, if (construct.kind == .parameter) 3 else 2);
                        continue;
                    }
                }
            }
            p += 1;
        }
        return null;
    }

    fn lstAttributeMatches(self: *Expander, attrs: []const u8, kind: []const u8, label: []const u8) bool {
        var p: usize = 0;
        while (p < attrs.len) {
            while (p < attrs.len and std.ascii.isWhitespace(attrs[p])) : (p += 1) {}
            const start = p;
            while (p < attrs.len and !std.ascii.isWhitespace(attrs[p]) and attrs[p] != '=') : (p += 1) {}
            const name = attrs[start..p];
            while (p < attrs.len and std.ascii.isWhitespace(attrs[p])) : (p += 1) {}
            if (p == attrs.len or attrs[p] != '=') {
                if (p == start) p += 1;
                continue;
            }
            p += 1;
            while (p < attrs.len and std.ascii.isWhitespace(attrs[p])) : (p += 1) {}
            var value_start = p;
            var value_end = p;
            if (p < attrs.len and (attrs[p] == '\'' or attrs[p] == '"')) {
                const quote = attrs[p];
                p += 1;
                value_start = p;
                while (p < attrs.len and attrs[p] != quote) : (p += 1) {}
                if (p == attrs.len) return false;
                value_end = p;
                p += 1;
            } else {
                while (p < attrs.len and !std.ascii.isWhitespace(attrs[p])) : (p += 1) {}
                value_end = p;
            }
            if ((std.ascii.eqlIgnoreCase(name, kind) or std.ascii.eqlIgnoreCase(name, self.lstLocalName(kind))) and
                std.mem.eql(u8, attrs[value_start..value_end], label)) return true;
        }
        return false;
    }

    fn expandLstInclude(self: *Expander, page_expr: []const u8, raw_args: []const []const u8, caller: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        if (depth > self.max_depth or self.template_depth >= self.max_template_depth) return error.TemplateDepth;
        const a = self.runtime.allocator;
        const page = std.mem.trim(u8, try self.expandWikitext(page_expr, caller, host_title, depth + 1), " \t\r\n");
        if (page.len == 0 or invalidTransclusionTitle(page)) return "";
        const local_page = switch (try self.classifyInterwikiTransclusion(page)) {
            .normal => page,
            .current_wiki => |name| name,
            .literal, .external => return "",
        };
        const page_without_fragment = local_page[0..(std.mem.indexOfScalar(u8, local_page, '#') orelse local_page.len)];
        if (page_without_fragment.len == 0) return "";
        const title = namespace_lib.canonicalizeTitle(a, self.runtime, page_without_fragment) catch |err| switch (err) {
            error.InvalidPageTitle => return "",
            else => return err,
        };
        // Upstream checks the requested title against all caller frames BEFORE fetch.
        var ancestor = self.transclusion_frame;
        while (ancestor) |ancestor_frame| {
            if (std.mem.eql(u8, ancestor_frame.title, title)) {
                const warning = try message_lib.interfaceMessagePlain(self.runtime, "parser-template-loop-warning", &.{.{ .string = title }});
                return std.fmt.allocPrint(a, "<span class=\"error\">{s}</span>", .{warning});
            }
            ancestor = ancestor_frame.parent;
        }
        var body: []const u8 = undefined;
        var final_title = title;
        var release_body = false;
        if (self.provider.get_transclusion_body) |get| {
            const fetched = (try get(self.provider.ctx, a, title)) orelse return std.fmt.allocPrint(a, "[[{s}]]", .{title});
            body = fetched.text;
            final_title = fetched.title;
            release_body = !fetched.borrowed;
        } else {
            const raw = if (self.provider.get_transclusion) |get| try get(self.provider.ctx, a, title) else try hostPageContent(self, a, title);
            body = try preprocess.transcludeDecodedForParsingAlloc(a, raw orelse return std.fmt.allocPrint(a, "[[{s}]]", .{title}));
            release_body = true;
        }
        defer if (release_body) a.free(body);
        // Arguments expand in the caller before entering a fresh target frame.
        const begin = if (raw_args.len == 0) "" else std.mem.trim(u8, try self.expandWikitext(raw_args[0], caller, host_title, depth + 1), " \t\r\n");
        const end = if (raw_args.len < 2) begin else std.mem.trim(u8, try self.expandWikitext(raw_args[1], caller, host_title, depth + 1), " \t\r\n");
        const frame: TransclusionFrame = .{ .title = final_title, .parent = self.transclusion_frame };
        self.transclusion_frame = &frame;
        defer self.transclusion_frame = frame.parent;
        self.template_depth += 1;
        defer self.template_depth -= 1;
        const args = try self.runtime.newTable();
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        var active = raw_args.len == 0 or begin.len == 0;
        var pos: usize = 0;
        while (self.nextLstSection(body, pos)) |section| {
            if (active) try out.appendSlice(a, try self.expandWikitext(body[pos..section.open], args, final_title, depth + 1));
            const attrs = try self.expandWikitext(section.attrs, args, final_title, depth + 1);
            if (!active and self.lstAttributeMatches(attrs, "begin", begin)) active = true;
            if (active and raw_args.len != 0 and self.lstAttributeMatches(attrs, "end", end)) {
                active = false;
                if (begin.len == 0) return out.toOwnedSlice(a);
            } else if (active and raw_args.len != 0) {
                // Selected-region traversal expands section inner source. The no-label
                // whole-page path instead uses the noop hook and drops paired inner.
                try out.appendSlice(a, try self.expandWikitext(section.inner, args, final_title, depth + 1));
            }
            pos = section.end;
        }
        if (active) try out.appendSlice(a, try self.expandWikitext(body[pos..], args, final_title, depth + 1));
        return out.toOwnedSlice(a);
    }

    fn expandParserHead(
        self: *Expander,
        head: []const u8,
        raw_args: []const []const u8,
        params: *rt.Table,
        host_title: []const u8,
        depth: usize,
    ) anyerror!?[]const u8 {
        if (try self.expandVariableHead(head, raw_args)) |value| return value;
        return self.expandFunctionHead(head, raw_args, params, host_title, depth);
    }

    fn expandVariableHead(self: *Expander, head: []const u8, raw_args: []const []const u8) anyerror!?[]const u8 {
        // Variables without a colon only take precedence over templates when
        // no pipe arguments were supplied (Parser::braceSubstitution).
        if (raw_args.len == 0) {
            if (try self.resolveTitleMagic(head, .variable)) |name| {
                if (try self.statisticsMagic(name, "")) |value| return value;
                return (try self.titleMagic(name, null)) orelse unreachable;
            }
        }
        if (try self.magicWord(head)) |value| return value;

        return null;
    }

    fn expandFunctionHead(
        self: *Expander,
        head: []const u8,
        raw_args: []const []const u8,
        params: *rt.Table,
        host_title: []const u8,
        depth: usize,
    ) anyerror!?[]const u8 {
        if (preprocess.findTopParserColonWithConversion(head, self.provider.language_conversion_enabled orelse false)) |colon| {
            const raw_name = std.mem.trim(u8, head[0..colon.index], " \t\r\n");
            const name = (try self.resolveParserFunction(try self.parserFunctionLookupName(raw_name))) orelse return null;
            const first = head[colon.index + colon.len ..];
            if (self.provider.resolve_parser_function != null and (std.mem.eql(u8, name, "filepath") or std.mem.eql(u8, name, "pagesize")))
                return try self.expandFilePageMagic(name, first, raw_args, params, host_title, depth);
            if (self.provider.resolve_parser_function != null and rt.namespace_registry.magic_words.statisticsId(name) != null) {
                const option = try self.expandWikitext(first, params, host_title, depth + 1);
                return (try self.statisticsMagic(name, option)) orelse unreachable;
            }
            if (std.ascii.eqlIgnoreCase(name, "pagesincategory")) {
                const category = try self.expandWikitext(first, params, host_title, depth + 1);
                const arg1 = if (raw_args.len > 0) try self.expandWikitext(raw_args[0], params, host_title, depth + 1) else "";
                const arg2 = if (raw_args.len > 1) try self.expandWikitext(raw_args[1], params, host_title, depth + 1) else "";
                // Parser::callParserFunction expands every ordinary argument;
                // the PHP callback uses only its first three values.
                if (raw_args.len > 2) for (raw_args[2..]) |extra| {
                    _ = try self.expandWikitext(extra, params, host_title, depth + 1);
                };
                return try self.categoryCount(category, arg1, arg2);
            }
            if (isRevisionMagicName(name)) {
                const page = try self.expandWikitext(first, params, host_title, depth + 1);
                return (try self.revisionMagic(name, page)) orelse unreachable;
            }
            if (try self.parserTitleMagic(name)) |canonical| {
                const page = try self.expandWikitext(first, params, host_title, depth + 1);
                return (try self.titleMagic(canonical, page)) orelse unreachable;
            }
            if (std.ascii.eqlIgnoreCase(name, "DISPLAYTITLE")) {
                const value = try self.expandWikitext(first, params, host_title, depth + 1);
                return try self.recordDisplayTitle(value);
            }
            if (std.ascii.eqlIgnoreCase(name, "DEFAULTSORT")) return "";
            if ((self.provider.resolve_parser_function != null and std.mem.eql(u8, name, "isbn")) or (self.provider.resolve_parser_function == null and std.mem.eql(u8, name, "#isbn"))) {
                const argument = std.mem.trim(u8, try self.expandWikitext(first, params, host_title, depth + 1), " \t\r\n\x00\x0b");
                // Ordinary parser callbacks eagerly expand extra arguments even
                // when the callback only consumes its first argument.
                for (raw_args) |extra| _ = try self.expandWikitext(extra, params, host_title, depth + 1);
                return self.isbnStrip(argument);
            }
            if (std.ascii.eqlIgnoreCase(name, "int")) return try self.expandIntParser(head, first, raw_args, params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "ns")) {
                const raw_ns = std.mem.trim(u8, try self.expandWikitext(first, params, host_title, depth + 1), " \t\r\n");
                const spec = if (std.fmt.parseInt(i32, raw_ns, 10)) |id|
                    namespace_lib.byId(self.runtime, id)
                else |_|
                    namespace_lib.byName(self.runtime, raw_ns);
                return (spec orelse return error.InvalidNamespace).name;
            }
            if (std.ascii.eqlIgnoreCase(name, "uc")) return try self.expandCaseParser(first, params, host_title, depth + 1, true, false);
            if (std.ascii.eqlIgnoreCase(name, "lc")) return try self.expandCaseParser(first, params, host_title, depth + 1, false, false);
            if (std.ascii.eqlIgnoreCase(name, "ucfirst")) return try self.expandCaseParser(first, params, host_title, depth + 1, true, true);
            if (std.ascii.eqlIgnoreCase(name, "lcfirst")) return try self.expandCaseParser(first, params, host_title, depth + 1, false, true);
            if (std.ascii.eqlIgnoreCase(name, "formatnum")) return try self.expandFormatNum(first, raw_args, params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "plural")) return try self.expandPlural(first, raw_args, params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "language")) return try self.expandLanguageParser(first, raw_args, params, host_title, depth + 1);
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
            if (std.ascii.eqlIgnoreCase(name, "#lst") or (self.provider.resolve_parser_function == null and std.ascii.eqlIgnoreCase(name, "#section"))) return try self.expandLstInclude(first, raw_args, params, host_title, depth + 1);
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

    // Parser::braceSubstitution removes one captured RAW prefix after variables
    // and before function/title dispatch. A raw name is not a bare variable.
    // The modifier neither supplies missing pages nor permits remote fetching.
    fn rawTransclusionTarget(self: *Expander, head: []const u8) !?[]const u8 {
        const colon = preprocess.findTopParserColonWithConversion(head, self.provider.language_conversion_enabled orelse false) orelse return null;
        const prefix = head[0 .. colon.index + colon.len];
        if (self.provider.resolve_title_magic) |resolve| {
            const id = (try resolve(self.provider.ctx, prefix, .transclusion_modifier)) orelse return null;
            if (!std.mem.eql(u8, id, "raw")) return null;
        } else if (!std.ascii.eqlIgnoreCase(prefix, "raw:")) return null;
        return head[colon.index + colon.len ..];
    }

    fn expandRawConstruct(self: *Expander, comptime tracked: bool, content: []const u8, expanded_head: []const u8, raw_args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror!(if (tracked) dependency.Text else []const u8) {
        const raw_target = (try self.rawTransclusionTarget(expanded_head)) orelse return error.RawTransclusionPrefixChanged;
        const target = std.mem.trim(u8, raw_target, " \t\r\n");
        // This is deliberately a single prefix removal: raw:raw:Name names the
        // template raw:Name, and raw:Template:raw:Name retains the same title.
        if (tracked) {
            if (try self.expandFunctionHeadTracked(target, raw_args, params, host_title, depth)) |value| return value;
        } else {
            if (try self.expandFunctionHead(target, raw_args, params, host_title, depth)) |value| return value;
        }
        if (target.len == 0 or target[0] == '#') {
            const unknown_function = target.len != 0;
            if (unknown_function) self.unsupported_parser_function = true;
            const value = try self.emptyComputedTransclusion(expanded_head, raw_args, params, host_title, depth, unknown_function);
            return if (tracked) dependency.Text.transformed(value) else value;
        }
        if (invalidTransclusionTitle(target)) {
            const value = if (invalidTransclusionNeedsProtection(target) or literalComputedColonTitleWithConversion(content, target, raw_args.len + 1, self.provider.language_conversion_enabled orelse false))
                try std.fmt.allocPrint(self.runtime.allocator, "<nowiki>{{{{{s}}}}}</nowiki>", .{content})
            else
                try std.fmt.allocPrint(self.runtime.allocator, "{{{{{s}}}}}", .{content});
            return if (tracked) dependency.Text.untracked(value) else value;
        }
        const local = switch (try self.classifyInterwikiTransclusion(target)) {
            .normal => target,
            .current_wiki => |name| name,
            .literal => {
                const value = try std.fmt.allocPrint(self.runtime.allocator, "<nowiki>{{{{{s}}}}}</nowiki>", .{content});
                return if (tracked) dependency.Text.untracked(value) else value;
            },
            .external => return error.ExternalInterwikiTransclusionUnsupported,
        };
        const args = try self.buildTemplateArgs(raw_args, params, host_title, depth + 1);
        return if (tracked)
            self.expandTemplateWithUsageRecoveryTracked(local, null, args, raw_args, host_title, depth + 1)
        else
            self.expandTemplateWithUsageRecovery(local, null, args, raw_args, host_title, depth + 1);
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

    // This is called only after both actual parser-function dispatch attempts
    // failed and title validation rejected the expanded name. A plain name
    // containing only defaultless parameters has no child markup to suppress.
    // Keep the unchanged invocation literal; renderer-side colon text alone
    // cannot prove that dispatch outcome.
    fn literalComputedColonTitle(content: []const u8, title: []const u8, part_count: usize) bool {
        return literalComputedColonTitleWithConversion(content, title, part_count, false);
    }

    fn literalComputedColonTitleWithConversion(content: []const u8, title: []const u8, part_count: usize, conversion_enabled: bool) bool {
        if (part_count != 1 or !std.mem.eql(u8, content, title) or
            !std.unicode.utf8ValidateSlice(title)) return false;
        const colon = preprocess.findTopParserColonWithConversion(title, conversion_enabled) orelse return false;
        if (colon.index == 0 or std.mem.indexOfAny(u8, title[0..colon.index], "{}") != null) return false;
        var at: usize = 0;
        var parameters: usize = 0;
        while (at < title.len) {
            if (std.mem.startsWith(u8, title[at..], "{{{")) {
                if (at <= colon.index) return false;
                const end = std.mem.indexOfPos(u8, title, at + 3, "}}}") orelse return false;
                const name = title[at + 3 .. end];
                if (name.len == 0) return false;
                for (name) |byte| if (byte < 0x80 and !std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
                parameters += 1;
                at = end + 3;
                continue;
            }
            if (std.mem.startsWith(u8, title[at..], "：")) { at += "：".len; continue; }
            const byte = title[at];
            if (byte < 0x80 and !std.ascii.isAlphanumeric(byte) and
                std.mem.indexOfScalar(u8, "_- /():", byte) == null) return false;
            at += 1;
        }
        return parameters != 0;
    }

    fn invalidTransclusionNeedsProtection(raw: []const u8) bool {
        for (raw) |byte| switch (byte) {
            0...31, 127, '[', ']', '<', '>' => return true,
            else => {},
        };
        return false;
    }

    fn emptyComputedTransclusion(self: *Expander, expanded_head: []const u8, raw_args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize, entity_braces: bool) anyerror![]const u8 {
        // Parser::braceSubstitution recovers the expanded title and argument
        // nodes when no valid title exists. Protect only the literal braces so
        // links and other markup in the expanded arguments retain their meaning.
        // Unknown-function synthetic braces use entities: generated HTML tags
        // inside an external URL would become the URL/label separator.
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.runtime.allocator);
        try out.appendSlice(self.runtime.allocator, if (entity_braces) "&#123;&#123;" else "<nowiki>{{</nowiki>");
        try out.appendSlice(self.runtime.allocator, expanded_head);
        for (raw_args) |raw| {
            try out.append(self.runtime.allocator, '|');
            try out.appendSlice(self.runtime.allocator, try self.expandWikitext(raw, params, host_title, depth + 1));
        }
        try out.appendSlice(self.runtime.allocator, if (entity_braces) "&#125;&#125;" else "<nowiki>}}</nowiki>");
        return out.toOwnedSlice(self.runtime.allocator);
    }

    fn expandConstruct(self: *Expander, content: []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const lazy_base = self.lazy_template_args.items.len;
        defer self.lazy_template_args.items.len = lazy_base;
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(self.runtime.allocator);
        try preprocess.splitWikitextTopWithConversion(self.runtime.allocator, content, '|', &parts, self.provider.language_conversion_enabled orelse false);
        if (parts.items.len == 0) return error.MalformedWikitext;
        var raw_head = stripSubstPrefix(parts.items[0]);
        if (raw_head.len == 0)
            return std.fmt.allocPrint(self.runtime.allocator, "<nowiki>{{{{{s}}}}}</nowiki>", .{content});
        if ((try self.rawTransclusionTarget(raw_head)) != null) {
            const expanded_raw = try self.expandWikitext(raw_head, params, host_title, depth + 1);
            if (try self.expandVariableHead(expanded_raw, parts.items[1..])) |value| return value;
            return self.expandRawConstruct(false, content, expanded_raw, parts.items[1..], params, host_title, depth);
        }
        if (try self.expandParserHead(raw_head, parts.items[1..], params, host_title, depth)) |value| return value;
        if (raw_head[0] == '#') {
            self.unsupported_parser_function = true;
            // Unknown calls remain literal, but MediaWiki expands their child
            // nodes. Valid parser functions already returned above, preserving
            // lazy branch selection. Protect only the recovered outer braces.
            const expanded_head = try self.expandWikitext(raw_head, params, host_title, depth + 1);
            return self.emptyComputedTransclusion(expanded_head, parts.items[1..], params, host_title, depth, true);
        }
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
            return self.expandTemplateWithUsageRecovery(raw_head, symbol, args, parts.items[1..], host_title, depth + 1);
        }
        const expanded_head = try self.expandWikitext(raw_head, params, host_title, depth + 1);
        const title = stripSubstPrefix(expanded_head);
        if (title.len == 0)
            return self.emptyComputedTransclusion(expanded_head, parts.items[1..], params, host_title, depth, false);
        if (title.len != 0 and !std.mem.eql(u8, title, raw_head)) {
            if ((try self.rawTransclusionTarget(title)) != null) {
                if (try self.expandVariableHead(title, parts.items[1..])) |value| return value;
                return self.expandRawConstruct(false, content, title, parts.items[1..], params, host_title, depth);
            }
            if (try self.expandParserHead(title, parts.items[1..], params, host_title, depth)) |value| return value;
        }
        if (title.len != 0 and title[0] == '#') {
            self.unsupported_parser_function = true;
            return self.emptyComputedTransclusion(expanded_head, parts.items[1..], params, host_title, depth, true);
        }
        if (invalidTransclusionTitle(title)) {
            if (invalidTransclusionNeedsProtection(title) or literalComputedColonTitleWithConversion(content, title, parts.items.len, self.provider.language_conversion_enabled orelse false))
                return std.fmt.allocPrint(self.runtime.allocator, "<nowiki>{{{{{s}}}}}</nowiki>", .{content});
            return std.fmt.allocPrint(self.runtime.allocator, "{{{{{s}}}}}", .{content});
        }
        const args = try self.buildTemplateArgs(parts.items[1..], params, host_title, depth + 1);
        return self.expandTemplateWithUsageRecovery(title, null, args, parts.items[1..], host_title, depth + 1);
    }

    // Only the independently captured ux wrapper and a typed missing export
    // can enter this path. The original visible diagnostic is deliberately kept:
    // this restores supported example content, not successful Lua execution.
    fn expandTemplateWithUsageRecovery(self: *Expander, name: []const u8, symbol: ?CallSymbol, args: *rt.Table, raw_args: []const []const u8, host_title: []const u8, depth: usize) anyerror![]const u8 {
        // Unrelated corpus templates keep their original normalization path:
        // the prefilter borrows bytes and allocates nothing.
        const candidate = if (symbol) |value| value.text else name;
        const colon = std.mem.lastIndexOfScalar(u8, candidate, ':');
        const basename = std.mem.trim(u8, candidate[if (colon) |at| at + 1 else 0..], " \t\r\n");
        if (!std.mem.eql(u8, basename, "ux") and !std.mem.eql(u8, basename, "usex")) {
            return if (symbol) |value|
                self.expandTemplateBySymbol(value, args, host_title, depth)
            else
                self.expandTemplateByName(name, args, host_title, depth, .link);
        }
        const title = try self.normalizeTransclusionName(name, host_title);
        const resolved = self.runtime.namespace_catalog.?.ofTitle(title);
        const eligible = resolved.id == 10 and (std.mem.eql(u8, resolved.text, "ux") or std.mem.eql(u8, resolved.text, "usex"));
        var recovery: UsageRecovery = .{ .args = args };
        const previous = self.usage_recovery;
        if (eligible) self.usage_recovery = &recovery;
        defer self.usage_recovery = previous;
        const expanded = if (symbol) |value|
            try self.expandTemplateBySymbol(value, args, host_title, depth)
        else
            try self.expandTemplateByName(name, args, host_title, depth, .link);
        if (!eligible or !recovery.exact_wrapper or !recovery.missing_display) return expanded;
        const recovered = (try self.usageSemanticHtml(args, raw_args)) orelse return expanded;
        work_stats.logLine("warning: native usage content recovery: article={s} template={s} module=usex export=display failure=InvokeFunctionMissing diagnostic=build-log recovery=recovered\n", .{ host_title[0..@min(host_title.len, 256)], title[0..@min(title.len, 256)] });
        return recovered;
    }

    fn usageSemanticHtml(self: *Expander, args: *rt.Table, raw_args: []const []const u8) anyerror!?[]const u8 {
        const a = self.runtime.allocator;
        var positional: i64 = 1;
        // Validate the original ordered argument roster, including overwritten
        // unsupported keys. Values are the already materialized last winners.
        for (raw_args) |raw| {
            const eq = preprocess.findTopDelimiterWithConversion(raw, '=', self.provider.language_conversion_enabled orelse false);
            const key_text = if (eq) |at| std.mem.trim(u8, raw[0..at], " \t\r\n") else "";
            var key: Value = undefined;
            if (eq != null) {
                if (std.fmt.parseInt(i64, key_text, 10)) |number| {
                    if (number < 1 or number > 3) return null;
                    key = .{ .number = @floatFromInt(number) };
                } else |_| {
                    var supported = false;
                    inline for (.{ "q", "qq", "translation", "t", "tr" }) |field|
                        if (std.mem.eql(u8, key_text, field)) {
                            supported = true;
                        };
                    if (!supported) return null;
                    key = .{ .string = key_text };
                }
            } else {
                if (positional > 3) return null;
                key = .{ .number = @floatFromInt(positional) };
                positional += 1;
            }
            const value = args.rawGet(key) orelse return null;
            if (value != .string) return error.StringExpected;
            // A still-unexpanded template is not repaired by this boundary.
            if (std.mem.indexOf(u8, value.string, "{{") != null or std.mem.indexOf(u8, value.string, "}}") != null) return null;
        }
        const language_value = args.rawGet(.{ .number = 1 }) orelse return null;
        const example_value = args.rawGet(.{ .number = 2 }) orelse return null;
        if (language_value != .string or example_value != .string) return error.StringExpected;
        if (language_value.string.len == 0 or example_value.string.len == 0) return null;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        const q = try usageArgument(args, .{ .string = "q" });
        if (q.len != 0) {
            try out.appendSlice(a, "<span class=\"label-content\">(");
            try out.appendSlice(a, q);
            try out.appendSlice(a, ")</span> ");
        }
        // Expanded argument bytes are content, never re-parsed as template
        // delimiters. The ordinary HTML compiler owns nested tables and links.
        try out.appendSlice(a, "<i class=\"e-example\" lang=\"");
        try appendAttrEscaped(&out, a, language_value.string);
        try out.appendSlice(a, "\">");
        try out.appendSlice(a, example_value.string);
        try out.appendSlice(a, "</i>");
        try appendUsageLabel(&out, a, try usageArgument(args, .{ .string = "qq" }));
        var translation = try usageArgument(args, .{ .string = "translation" });
        if (translation.len == 0) translation = try usageArgument(args, .{ .string = "t" });
        if (translation.len == 0) translation = try usageArgument(args, .{ .number = 3 });
        if (translation.len != 0) {
            try out.appendSlice(a, "<br/>");
            try out.appendSlice(a, translation);
        }
        try appendUsageLabel(&out, a, try usageArgument(args, .{ .string = "tr" }));
        return try out.toOwnedSlice(a);
    }

    fn usageArgument(args: *rt.Table, key: Value) ![]const u8 {
        const value = args.rawGet(key) orelse return "";
        if (value != .string) return error.StringExpected;
        return value.string;
    }

    fn appendUsageLabel(out: *std.ArrayList(u8), a: std.mem.Allocator, value: []const u8) !void {
        if (value.len == 0) return;
        try out.appendSlice(a, " <span class=\"label-content\">(");
        try out.appendSlice(a, value);
        try out.appendSlice(a, ")</span>");
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

    fn phonosAttr(self: *Expander, attrs: ?*rt.Table, key: []const u8) ![]const u8 {
        const table = attrs orelse return "";
        return self.scalarText(table.rawGet(.{ .string = key }) orelse return "");
    }

    // MediaWiki Phonos renders an error button whose detailed diagnostic is a
    // client-side popup. The dictionary retains its real localized accessible
    // error label, source label, error class and exact diagnostic key/file.
    // It does not fabricate upload-navigation URLs or English error prose.
    fn phonosError(self: *Expander, label: []const u8, language: []const u8, key: []const u8, file: []const u8) ![]const u8 {
        const a = self.runtime.allocator;
        const aria = try message_lib.interfaceMessagePlain(self.runtime, "phonos-aria-error", &.{});
        rt.work_stats.logLine("warning: phonos error: key={s} file={s}\n", .{ key, file });
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, "<span class=\"ext-phonos ext-phonos-error ");
        try appendAttrEscaped(&out, a, key);
        try out.appendSlice(a, "\" lang=\"");
        try appendAttrEscaped(&out, a, language);
        try out.appendSlice(a, "\" data-phonos-error=\"");
        try appendAttrEscaped(&out, a, key);
        try out.appendSlice(a, "\" data-phonos-file-argument=\"");
        try appendAttrEscaped(&out, a, file);
        try out.appendSlice(a, "\">");
        try out.appendSlice(a, label);
        if (label.len != 0) try out.appendSlice(a, " ");
        try appendAttrEscaped(&out, a, aria);
        try out.appendSlice(a, "</span>");
        return out.toOwnedSlice(a);
    }

    fn renderPhonos(self: *Expander, content: ?Value, attrs: ?*rt.Table) ![]const u8 {
        const a = self.runtime.allocator;
        const registry = self.runtime.namespace_catalog orelse return error.NamespaceRegistryRequired;
        const language_arg = try self.phonosAttr(attrs, "lang");
        const language = if (attrs != null and attrs.?.rawGet(.{ .string = "lang" }) != null)
            language_arg
        else
            registry.content_language;
        const file = try self.phonosAttr(attrs, "file");
        const ipa = try self.phonosAttr(attrs, "ipa");
        const wikibase = try self.phonosAttr(attrs, "wikibase");
        // The label attribute is explicitly ignored upstream; inner content wins
        // over IPA, while file takes priority over a Wikibase argument.
        const inner = if (content) |value| try self.scalarText(value) else "";
        const label = if (inner.len != 0 and !std.mem.eql(u8, inner, "0")) std.mem.trim(u8, inner, " \t\r\n") else ipa;
        const has_file = file.len != 0 and !std.mem.eql(u8, file, "0");
        const has_ipa = ipa.len != 0 and !std.mem.eql(u8, ipa, "0");
        const has_wikibase = wikibase.len != 0 and !std.mem.eql(u8, wikibase, "0");
        if (!has_ipa and !has_file and !has_wikibase)
            return self.phonosError(label, language, "phonos-param-error", "");
        if (ipa.len > 300) return self.phonosError(label, language, "phonos-ipa-too-long", file);
        if (!has_file) {
            if (has_wikibase) return error.PhonosWikibaseUnsupported;
            return error.PhonosIpaGenerationUnsupported;
        }
        const file_spec = registry.byId(6) orelse return error.NamespaceRegistryRequired;
        const validation_title = registry.normalizeTitle(a, file, 6, .literal) catch |err| switch (err) {
            error.InvalidPageTitle => return self.phonosError(label, language, "phonos-invalid-title", file),
            else => return err,
        };
        const title_body = registry.ofTitle(validation_title).text;
        if (!title_lib.validTitleBody(self.runtime, file_spec, title_body))
            return self.phonosError(label, language, "phonos-invalid-title", file);
        // findFile accepts the edition's File aliases, whereas makeTitleSafe
        // validates the supplied name in NS_FILE without stripping its prefix.
        const title = try registry.normalizeTitle(a, file, 6, .only_default);
        const get = self.provider.file_metadata orelse {
            rt.work_stats.logLine("warning: phonos file metadata snapshot unavailable: title={s}\n", .{title});
            return error.FileMetadataSnapshotMissing;
        };
        const metadata = try get(self.provider.ctx, title);
        if (!metadata.exists) return self.phonosError(label, language, "phonos-file-not-found", file);
        const media_type = metadata.media_type orelse return error.FileMetadataMediaTypeMissing;
        if (media_type != .AUDIO) return self.phonosError(label, language, "phonos-file-not-audio", file);
        const canonical = metadata.canonical_title orelse return error.FileMetadataCanonicalTitleMissing;
        const canonical_spec = registry.ofTitle(canonical);
        if (canonical_spec.id != 6 or !title_lib.validTitleBody(self.runtime, file_spec, canonical_spec.text))
            return error.InvalidFileMetadataTitle;
        const aria = try message_lib.interfaceMessagePlain(self.runtime, "phonos-player-aria-description", &.{});
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, "<span class=\"ext-phonos ext-phonos-PhonosButton\" lang=\"");
        try appendAttrEscaped(&out, a, language);
        try out.appendSlice(a, "\" data-phonos-audio=\"");
        try appendAttrEscaped(&out, a, canonical_spec.text);
        try out.appendSlice(a, "\">");
        if (label.len != 0) try out.appendSlice(a, label) else try appendAttrEscaped(&out, a, aria);
        try out.appendSlice(a, "</span>");
        return out.toOwnedSlice(a);
    }

    // CoreParserFunctions::tagObj emits an ordinary tag when no extension hook
    // owns its name. Keep this path distinct from registered extension effects.
    fn serializeOrdinaryTag(self: *Expander, raw_name: []const u8, content: ?Value, attrs: ?*rt.Table) ![]const u8 {
        const raw = std.mem.trim(u8, try text_lib.killMarkersAlloc(self.runtime.allocator, raw_name), " \t\r\n\x00\x0b");
        if (raw.len == 0 or !std.ascii.isAlphabetic(raw[0]) or canonicalExtensionTag(raw) != null) return error.UnsupportedExtensionTag;
        for (raw[1..]) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != ':' and ch != '-' and ch != '_') return error.UnsupportedExtensionTag;
        const name = try self.runtime.allocator.dupe(u8, raw);
        for (name) |*ch| ch.* = std.ascii.toLower(ch.*);
        return self.serializeTagElement(name, content, attrs, true);
    }

    fn serializeExtension(self: *Expander, name: []const u8, content: ?Value, attrs: ?*rt.Table) ![]const u8 {
        if (std.mem.eql(u8, name, "phonos")) return self.renderPhonos(content, attrs);
        return self.serializeTagElement(name, content, attrs, false);
    }

    fn serializeTagElement(self: *Expander, name: []const u8, content: ?Value, attrs: ?*rt.Table, ordinary: bool) ![]const u8 {
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
                if (ordinary) {
                    // The core ordinary-tag fallback escapes attribute names too.
                    for (key) |ch| {
                        if (ch == '\'') try out.appendSlice(a, "&#039;") else try appendAttrEscaped(&out, a, &.{ch});
                    }
                } else try out.appendSlice(a, key);
                try out.appendSlice(a, "=\"");
                const value = try self.scalarText(table.rawGet(.{ .string = key }).?);
                try appendAttrEscaped(&out, a, if (ordinary) try text_lib.killMarkersAlloc(a, value) else value);
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

    // Parser::extensionSubstitution returns a general strip marker to Lua.
    // Keep this registered hook result opaque across later display-text escaping;
    // authored entity spellings remain part of its original raw payload.
    fn stripPreprocessedHiero(self: *Expander, a: std.mem.Allocator, source: []const u8) ![]const u8 {
        var scan: preprocess.OpaqueParserScan = .{};
        var out: std.ArrayList(u8) = .empty;
        var pos: usize = 0;
        var copied: usize = 0;
        var changed = false;
        while (std.mem.indexOfScalarPos(u8, source, pos, '<')) |open| {
            pos = open + 1;
            const end = scan.end(source, open) orelse continue;
            pos = end;
            const tail = source[open..];
            if (tail.len < 7 or !std.ascii.eqlIgnoreCase(tail[0..6], "<hiero") or
                !(tail[6] == '>' or tail[6] == '/' or std.ascii.isWhitespace(tail[6]))) continue;
            const opening_end = preprocess.decodedTagEnd(source, open) orelse continue;
            if (end <= opening_end) continue; // Unmatched and self-closing roots retain their existing path.
            const page_a = self.page_allocator orelse return error.MissingPageAllocator;
            const id = self.strip_counter;
            self.strip_counter +%= 1;
            const stored = try page_a.dupe(u8, source[open..end]);
            try self.strip_values.put(page_a, id, .{ .kind = .hiero, .text = stored });
            try out.appendSlice(a, source[copied..open]);
            try out.appendSlice(a, try std.fmt.allocPrint(a, "{s}{X:0>8}{s}", .{ hiero_marker_prefix, id, nowiki_marker_suffix }));
            copied = end;
            changed = true;
        }
        if (!changed) return source;
        try out.appendSlice(a, source[copied..]);
        return out.toOwnedSlice(a);
    }

    // Only an existing page-owned value of the exact marker kind can be
    // restored. Authored spellings and another kind's shared id are not values.
    fn ownedStripMarker(self: *const Expander, source: []const u8, at: usize, prefix: []const u8, kind: @FieldType(StripValue, "kind")) ?struct { end: usize, text: []const u8 } {
        const length = prefix.len + 8 + nowiki_marker_suffix.len;
        if (at > source.len or source.len - at < length or !std.mem.startsWith(u8, source[at..], prefix)) return null;
        const id_start = at + prefix.len;
        const suffix_at = id_start + 8;
        if (!std.mem.startsWith(u8, source[suffix_at..], nowiki_marker_suffix)) return null;
        const id = std.fmt.parseInt(u32, source[id_start..suffix_at], 16) catch return null;
        const value = self.strip_values.get(id) orelse return null;
        if (value.kind != kind) return null;
        return .{ .end = at + length, .text = value.text };
    }

    // Final producer restoration is distinct from mw.text.unstrip: the latter
    // removes general markers, while this route restores only this page's kind.
    fn restoreHieroMarkers(self: *Expander, a: std.mem.Allocator, source: []const u8) ![]const u8 {
        if (std.mem.indexOf(u8, source, hiero_marker_prefix) == null) return source;
        var out: std.ArrayList(u8) = .empty;
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, source, pos, hiero_marker_prefix)) |at| {
            try out.appendSlice(a, source[pos..at]);
            if (self.ownedStripMarker(source, at, hiero_marker_prefix, .hiero)) |marker| {
                try out.appendSlice(a, marker.text);
                pos = marker.end;
            } else {
                try out.append(a, source[at]);
                pos = at + 1;
            }
        }
        try out.appendSlice(a, source[pos..]);
        return out.toOwnedSlice(a);
    }

    // CoreTagHooks permits prior general strip results through nowiki. Keep
    // every other byte in the existing authenticated protected-literal route,
    // including wiki delimiters, closing tags, entities and source whitespace.
    fn finalNowikiBody(self: *Expander, a: std.mem.Allocator, body: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var search: usize = 0;
        var copied: usize = 0;
        while (true) {
            const hiero_at = std.mem.indexOfPos(u8, body, search, hiero_marker_prefix);
            const isbn_at = std.mem.indexOfPos(u8, body, search, isbn_marker_prefix);
            const at = if (hiero_at) |h| if (isbn_at) |i| @min(h, i) else h else isbn_at orelse break;
            search = at + 1;
            const is_isbn = std.mem.startsWith(u8, body[at..], isbn_marker_prefix);
            const marker = if (is_isbn) self.ownedStripMarker(body, at, isbn_marker_prefix, .isbn) orelse continue else self.ownedStripMarker(body, at, hiero_marker_prefix, .hiero) orelse continue;
            if (at > copied) try out.appendSlice(a, try self.poemLiteral("nowiki", body[copied..at]));
            // This is the final general phase, not a recursive scan of payloads.
            try out.appendSlice(a, if (is_isbn) body[at..marker.end] else marker.text);
            search = marker.end;
            copied = marker.end;
        }
        if (copied < body.len) try out.appendSlice(a, try self.poemLiteral("nowiki", body[copied..]));
        return out.toOwnedSlice(a);
    }

    fn finalizeNowikiMarkers(self: *Expander, a: std.mem.Allocator, source: []const u8) ![]const u8 {
        if (std.mem.indexOf(u8, source, nowiki_marker_prefix) == null) return source;
        var out: std.ArrayList(u8) = .empty;
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, source, pos, nowiki_marker_prefix)) |at| {
            try out.appendSlice(a, source[pos..at]);
            if (self.ownedStripMarker(source, at, nowiki_marker_prefix, .nowiki)) |marker| {
                // Owned markers finalize even inside returned pre/code markup;
                // the renderer supplies its actual inherited whitespace/style.
                try out.appendSlice(a, try self.finalNowikiBody(a, marker.text));
                pos = marker.end;
            } else {
                try out.append(a, source[at]);
                pos = at + 1;
            }
        }
        try out.appendSlice(a, source[pos..]);
        return out.toOwnedSlice(a);
    }

    fn hostFramePreprocess(raw: ?*anyopaque, a: std.mem.Allocator, source: []const u8, title: []const u8, args: *rt.Table) anyerror![]const u8 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        self.invalidateNativeDependencyArguments();
        const stripped = try preprocess.stripDecodedCommentsForParsingPreservingPoem(a, source);
        defer a.free(stripped);
        defer if (self.origin_ledger) |origins| origins.retireInterval(stripped);
        if (self.origin_ledger) |origins| try originResult(origins.copied(@intFromPtr(self.runtime), source, stripped));
        if (stripped.len >= 2 and stripped[0] == '=' and stripped[stripped.len - 1] == '=' and
            std.mem.indexOf(u8, stripped, nowiki_marker_prefix) != null)
        {
            const number = self.page_heading_count + self.fake_heading_count;
            self.fake_heading_count += 1;
            return std.fmt.allocPrint(a, "\x7f'\"`UNIQ--h-{d}--QINU`\"'\x7f", .{number});
        }
        const expanded = try self.expandWikitext(stripped, args, title, 0);
        return self.stripPreprocessedHiero(a, expanded);
    }

    fn hostFrameExpandTemplate(raw: ?*anyopaque, _: std.mem.Allocator, title: []const u8, args: *rt.Table) anyerror![]const u8 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        self.invalidateNativeDependencyArguments();
        return self.expandTemplateByName(title, args, null, 0, .lua_error);
    }

    fn hostFrameExtensionTag(raw: ?*anyopaque, a: std.mem.Allocator, name: []const u8, content: ?Value, attrs: ?*rt.Table) anyerror![]const u8 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        self.invalidateNativeDependencyArguments();
        const tag = std.mem.trim(u8, try text_lib.killMarkersAlloc(a, name), " \t\r\n\x00\x0b");
        if (std.ascii.eqlIgnoreCase(tag, "poem")) {
            const params = try self.runtime.newTable();
            return self.expandPoemValue(if (content) |value| try self.scalarText(value) else "", attrs, params, self.host.current_title, self.poem_hook_depth + 1);
        }
        if (std.ascii.eqlIgnoreCase(tag, "nowiki")) {
            if (self.poem_argument_depth != 0) return self.poemLiteral("nowiki", if (content) |value| try self.scalarText(value) else "");
            const text = if (content) |value| if (value == .string) value.string else "" else "";
            const id = self.strip_counter;
            self.strip_counter +%= 1;
            const page_a = self.page_allocator orelse return error.MissingPageAllocator;
            const stored = try page_a.dupe(u8, text);
            try self.strip_values.put(page_a, id, .{ .kind = .nowiki, .text = stored });
            return makeNowikiMarker(a, id);
        }
        if (canonicalExtensionTag(tag)) |canonical| return self.serializeExtension(canonical, content, attrs);
        // Scribunto extensionTag inserts an empty content argument even for nil.
        return self.serializeOrdinaryTag(tag, content orelse .{ .string = "" }, attrs);
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
            if (self.strip_values.get(id)) |value| {
                try out.appendSlice(a, if (value.kind == .nowiki) value.text else source[at..marker_end]);
            } else try out.appendSlice(a, source[at..marker_end]);
            pos = marker_end;
        }
        try out.appendSlice(a, source[pos..]);
        return out.toOwnedSlice(a);
    }

    // CoreParserFunctions::isbn returns isHTML. Keep that result in the existing
    // page-owned general strip state, never interpolate argument bytes as wiki.
    fn isbnStrip(self: *Expander, argument: []const u8) anyerror!?[]const u8 {
        const page_a = self.page_allocator orelse self.runtime.allocator;
        const normalized = (try generated_link.normalizeAlloc(page_a, argument)) orelse return null;
        if (!generated_link.matches(normalized)) return null; // MediaWiki found=false.
        // A lexical match can still fail TitleValue construction. Preserve that
        // callback failure before creating any owned strip value.
        if (!generated_link.validTargetArgument(normalized)) return error.InvalidIsbnTitleTarget;
        if (self.strip_values.count() >= generated_link.max_links or self.strip_counter == std.math.maxInt(u32)) return error.FrameTooLarge;
        const id = self.strip_counter;
        self.strip_counter += 1;
        errdefer { self.strip_counter = id; _ = self.strip_values.remove(id); }
        try self.strip_values.put(page_a, id, .{ .kind = .isbn, .text = normalized });
        return try std.fmt.allocPrint(self.runtime.allocator, "{s}{X:0>8}{s}", .{ isbn_marker_prefix, id, nowiki_marker_suffix });
    }

    // The last producer edit records exact offsets while copying actual owned
    // markers. An equal authored WDGLINK spelling is never a generated range.
    fn restoreIsbnMarkers(self: *Expander, a: std.mem.Allocator, source: []const u8, links: *std.ArrayList(generated_link.WireRange)) anyerror![]const u8 {
        if (std.mem.indexOf(u8, source, isbn_marker_prefix) == null) return source;
        const page_a = self.page_allocator orelse self.runtime.allocator;
        const original_links = links.items.len;
        const original_counter = self.generated_link_counter;
        errdefer { links.shrinkRetainingCapacity(original_links); self.generated_link_counter = original_counter; }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, source, pos, isbn_marker_prefix)) |at| {
            try out.appendSlice(a, source[pos..at]);
            const marker = self.ownedStripMarker(source, at, isbn_marker_prefix, .isbn) orelse {
                try out.append(a, source[at]);
                pos = at + 1;
                continue;
            };
            const id = self.generated_link_counter;
            if (id >= generated_link.max_links or out.items.len > std.math.maxInt(u32)) return error.FrameTooLarge;
            const target = try generated_link.targetAlloc(page_a, marker.text);
            const label = try std.fmt.allocPrint(page_a, "ISBN {s}", .{marker.text});
            const token = try generated_link.tokenAlloc(page_a, id, marker.text, target, label);
            const start = out.items.len;
            try out.appendSlice(a, token);
            if (out.items.len > std.math.maxInt(u32)) return error.FrameTooLarge;
            try links.append(page_a, .{ .start = @intCast(start), .end = @intCast(out.items.len), .value = .{ .token = token, .argument = marker.text, .target = target, .label = label } });
            self.generated_link_counter += 1;
            pos = marker.end;
        }
        try out.appendSlice(a, source[pos..]);
        return try out.toOwnedSlice(a);
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
            const value = parserTagAttributeValue(try self.scalarText(entry.value_ptr.*));
            try attrs.rawSet(self.runtime.allocator, entry.key_ptr.*, .{ .string = value });
            any = true;
        }
        var index = positional_start;
        while (args.rawGet(.{ .number = @floatFromInt(index) })) |value| : (index += 1) {
            const text = try self.scalarText(value);
            const eq = std.mem.indexOfScalar(u8, text, '=') orelse return error.UnsupportedExtensionAttributeArgument;
            const key = std.mem.trim(u8, text[0..eq], " \t\r\n");
            if (key.len == 0) return error.UnsupportedExtensionAttributeArgument;
            const attr_value = parserTagAttributeValue(text[eq + 1 ..]);
            try attrs.rawSet(self.runtime.allocator, .{ .string = key }, .{ .string = attr_value });
            any = true;
        }
        return if (any) attrs else null;
    }

    fn frameParserTag(self: *Expander, raw: ?*anyopaque, a: std.mem.Allocator, name: []const u8, args: *rt.Table) ![]const u8 {
        const plain = std.ascii.eqlIgnoreCase(name, "#tag");
        const prefixed = std.ascii.startsWithIgnoreCase(name, "#tag:");
        if (!plain and !prefixed) return error.UnsupportedParserFunction;
        const raw_tag: []const u8 = if (plain) blk: {
            const value = args.rawGet(.{ .number = 1 }) orelse return error.StringExpected;
            if (value != .string) return error.StringExpected;
            break :blk std.mem.trim(u8, value.string, " \t\r\n");
        } else std.mem.trim(u8, name[5..], " \t\r\n");
        const tag = std.mem.trim(u8, try text_lib.killMarkersAlloc(a, raw_tag), " \t\r\n\x00\x0b");
        if (tag.len == 0) return error.UnsupportedExtensionTag;
        const content_index: usize = if (plain) 2 else 1;
        const attr_start: usize = content_index + 1;
        const content_text = if (args.rawGet(.{ .number = @floatFromInt(content_index) })) |value| try self.scalarText(value) else "";
        const attrs = try self.frameParserTagAttrs(args, attr_start);
        if (canonicalExtensionTag(tag) == null) {
            const content: ?Value = if (args.rawGet(.{ .number = @floatFromInt(content_index) }) != null) .{ .string = content_text } else null;
            return self.serializeOrdinaryTag(tag, content, attrs);
        }
        return hostFrameExtensionTag(raw, a, tag, .{ .string = content_text }, attrs);
    }

    fn frameParserInvoke(self: *Expander, args: *rt.Table) ![]const u8 {
        const module_value = args.rawGet(.{ .number = 1 }) orelse return error.ModuleNameExpected;
        const module_raw = std.mem.trim(u8, try self.scalarText(module_value), " \t\r\n");
        if (module_raw.len == 0) return error.ModuleNameExpected;
        const module_name = try self.runtime.namespace_catalog.?.normalizeTitle(self.runtime.allocator, module_raw, 828, .only_default);
        if (args.rawGet(.{ .number = 2 }) != null)
            if (try self.preflightInvokeModule(module_name, module_raw)) |markup| return markup;
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
            .export_error => |failure| failure.markup,
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

    fn categoryTreeNamespaces(self: *Expander, raw: ?[]const u8) ![]const i32 {
        const a = self.runtime.allocator;
        var ids: std.ArrayList(i32) = .empty;
        errdefer ids.deinit(a);
        // CategoryTree OptionManager splits namespace names on these separators.
        var tokens = std.mem.tokenizeAny(u8, raw orelse return &.{}, " \t\r\n\x0b\x0c#:|");
        while (tokens.next()) |token| {
            const id: i32 = if (std.mem.eql(u8, token, "-") or std.mem.eql(u8, token, "_") or
                std.mem.eql(u8, token, "*") or std.ascii.eqlIgnoreCase(token, "main"))
                0
            else blk: {
                // PHP is_numeric also accepts decimal/exponent strings. Do not
                // interpret non-decimal forms such as 0x10 or NaN as IDs.
                var decimal = false;
                var decimal_syntax = true;
                for (token) |c| {
                    if (std.ascii.isDigit(c)) decimal = true else if (c != '+' and c != '-' and c != '.' and c != 'e' and c != 'E') {
                        decimal_syntax = false;
                    }
                }
                if (decimal and decimal_syntax) {
                    if (std.fmt.parseInt(i32, token, 10)) |number| break :blk number else |_| {}
                    if (std.fmt.parseFloat(f64, token)) |number| {
                        if (!std.math.isFinite(number) or number < -2147483648.0 or number >= 2147483648.0)
                            return error.UnsupportedCategoryTreeOptions;
                        break :blk @intFromFloat(number);
                    } else |_| {}
                }
                // Unknown names are ignored by the official extension; an
                // entirely unknown list means no namespace filter.
                const spec = namespace_lib.byName(self.runtime, token) orelse continue;
                break :blk spec.id;
            };
            try ids.append(a, id);
        }
        std.mem.sort(i32, ids.items, {}, std.sort.asc(i32));
        return ids.toOwnedSlice(a);
    }

    fn categoryTreeClass(raw: ?[]const u8) ?[]const u8 {
        var value = std.mem.trim(u8, raw orelse return null, " \t\r\n");
        if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\'')))
            value = std.mem.trim(u8, value[1 .. value.len - 1], " \t\r\n");
        if (value.len == 0) return null;
        return value;
    }

    fn categoryTreeMode(raw: []const u8) []const u8 {
        // OptionManager::decodeMode trims names, resolves aliases and legacy
        // numeric modes, and defaults unknown values to categories.
        const mode = std.mem.trim(u8, raw, " \t\r\n\x00\x0b");
        if (std.ascii.eqlIgnoreCase(mode, "pages")) return "pages";
        if (std.ascii.eqlIgnoreCase(mode, "all")) return "all";
        if (std.ascii.eqlIgnoreCase(mode, "parents") or
            std.ascii.eqlIgnoreCase(mode, "super") or
            std.ascii.eqlIgnoreCase(mode, "inverse")) return "parents";
        const number = std.mem.trim(u8, mode, " \t\r\n\x0b\x0c");
        if (number.len == 0) return "categories";
        for (number) |byte| {
            if (!std.ascii.isDigit(byte) and byte != '+' and byte != '-' and
                byte != '.' and byte != 'e' and byte != 'E') return "categories";
        }
        const numeric = std.fmt.parseFloat(f64, number) catch return "categories";
        // Only these bounded, nonnegative legacy values can change the mode.
        if (!std.math.isFinite(numeric) or numeric < 0 or numeric >= 101) return "categories";
        return switch (@as(i32, @intFromFloat(numeric))) {
            10 => "pages",
            20 => "all",
            100 => "parents",
            else => "categories",
        };
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
        namespace_ids: []const i32,
        class_name: ?[]const u8,
    ) ![]const u8 {
        const a = self.runtime.allocator;
        const effective_mode = if (namespace_ids.len != 0)
            mode
        else if (mode_explicit)
            mode
        else
            "categories";
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, "<div class=\"");
        if (class_name) |name| {
            try appendAttrEscaped(&out, a, name);
            try out.append(a, ' ');
        }
        try out.appendSlice(a, "CategoryTreeTag\" data-ct-options=\"{&quot;mode&quot;:&quot;");
        try out.appendSlice(a, effective_mode);
        try out.appendSlice(a, "&quot;,&quot;hideprefix&quot;:&quot;");
        try out.appendSlice(a, hideprefix);
        try out.appendSlice(a, "&quot;,&quot;showcount&quot;:");
        try out.appendSlice(a, if (std.ascii.eqlIgnoreCase(showcount, "on")) "true" else "false");
        try out.appendSlice(a, ",&quot;namespaces&quot;:");
        if (namespace_ids.len == 0) {
            try out.appendSlice(a, "false");
        } else {
            try out.append(a, '[');
            for (namespace_ids, 0..) |id, i| {
                if (i != 0) try out.append(a, ',');
                const value = try std.fmt.allocPrint(a, "{d}", .{id});
                defer a.free(value);
                try out.appendSlice(a, value);
            }
            try out.append(a, ']');
        }
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
        return self.expandCategoryTreeOptions(args, raw_category) catch |err| {
            if (err == error.UnsupportedCategoryTreeOptions) {
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
            }
            return err;
        };
    }

    fn expandCategoryTreeOptions(self: *Expander, args: *rt.Table, raw_category: []const u8) ![]const u8 {
        const category = try self.runtime.allocator.dupe(u8, raw_category);
        for (category) |*byte| {
            if (byte.* == ' ') byte.* = '_';
        }

        const mode_arg = categoryTreeArg(args, "mode");
        const type_arg = categoryTreeArg(args, "type");
        if (mode_arg != null and type_arg != null and !std.ascii.eqlIgnoreCase(mode_arg.?, type_arg.?))
            return error.UnsupportedCategoryTreeOptions;
        // Parent traversal ignores namespace filters in the extension. It is
        // unsupported here and must not be converted into forward page mode.
        const requested_mode = categoryTreeMode(mode_arg orelse type_arg orelse "categories");
        if (std.mem.eql(u8, requested_mode, "parents"))
            return error.UnsupportedCategoryTreeOptions;
        const namespace_ids = try self.categoryTreeNamespaces(categoryTreeValue(categoryTreeArg(args, "namespaces")));
        defer self.runtime.allocator.free(namespace_ids);
        var main_only = namespace_ids.len != 0;
        for (namespace_ids) |id| if (id != 0) {
            main_only = false;
        };
        // The extension adjusts mode after resolving the complete namespace list.
        const mode = if (namespace_ids.len == 0)
            requested_mode
        else if (namespace_ids.len == 1 and namespace_ids[0] == 14)
            "categories"
        else if (std.mem.indexOfScalar(i32, namespace_ids, 6) != null)
            "all"
        else
            "pages";
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
        const category_title = try self.runtime.namespace_catalog.?.normalizeTitle(self.runtime.allocator, display, 14, .literal);
        defer self.runtime.allocator.free(category_title);
        if (!try self.provider.exists(self.provider.ctx, category_title))
            return self.missingCategoryTree(display, mode, mode_arg != null or type_arg != null, hideprefix, showcount, namespace_ids, class_name);

        if (std.mem.eql(u8, depth, "0")) {
            // Collapsed-root counts are independent of child namespace filters.
            const stats_get = self.provider.category_stats orelse return error.NotImplemented;
            const stats = (try stats_get(self.provider.ctx, category)) orelse
                Provider.CategoryStats{ .all = 0, .subcats = 0, .files = 0 };
            const count = categoryTreeRootCount(mode, stats) orelse return error.UnsupportedCategoryTreeOptions;
            const a = self.runtime.allocator;
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(a, "<div class=\"");
            if (class_name) |name| {
                try appendAttrEscaped(&out, a, name);
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

        if (!std.ascii.eqlIgnoreCase(mode, "pages")) return error.UnsupportedCategoryTreeOptions;
        const deeper = !std.mem.eql(u8, depth, "1");
        if (deeper) {
            if (depth.len == 0 or depth[0] == '0') return error.UnsupportedCategoryTreeOptions;
            for (depth) |digit| if (!std.ascii.isDigit(digit)) return error.UnsupportedCategoryTreeOptions;
            _ = std.fmt.parseInt(u32, depth, 10) catch return error.UnsupportedCategoryTreeOptions;
        }

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

        const get = self.provider.category_tree_scoped orelse self.provider.category_tree orelse return error.NotImplemented;
        var member_arena = std.heap.ArenaAllocator.init(self.runtime.allocator);
        defer member_arena.deinit();
        const scoped = self.provider.category_tree_scoped != null;
        const members = try get(self.provider.ctx, if (scoped) member_arena.allocator() else self.runtime.allocator, category, if (main_only) .main else .pages);
        defer if (!scoped) self.runtime.allocator.free(members);

        var page_count: usize = members.len;
        var complete_members = members.len < 200;
        var complete_leaf = false;
        if (self.provider.category_stats) |stats_get| {
            if (try stats_get(self.provider.ctx, category)) |stats| {
                page_count = stats.all -| stats.files;
                if (page_count == members.len) {
                    complete_members = true;
                    complete_leaf = stats.files <= stats.all and stats.subcats == 0;
                }
            }
        }
        // Further depth cannot expand a complete list of ordinary page leaves.
        // Both independently derived inputs must agree before reusing the depth-one path.
        if (deeper) {
            if (!complete_leaf) return error.UnsupportedCategoryTreeOptions;
            for (members) |title| if (namespace_lib.ofTitle(self.runtime, title).id == 14)
                return error.UnsupportedCategoryTreeOptions;
        }
        if (namespace_ids.len != 0 and !main_only and !complete_members) {
            // Captured pages are capped before filtering, but MediaWiki filters
            // in SQL before its limit. A discarded row could hide a later match.
            for (members) |title| {
                const id = namespace_lib.ofTitle(self.runtime, title).id;
                if (std.mem.indexOfScalar(i32, namespace_ids, id) == null)
                    return error.CategoryTreeSnapshotIncomplete;
            }
        }

        var out: std.ArrayList(u8) = .empty;
        const a = self.runtime.allocator;
        try out.appendSlice(a, "<div class=\"");
        if (class_name) |name| {
            try appendAttrEscaped(&out, a, name);
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
                const member_namespace = namespace_lib.ofTitle(self.runtime, title);
                if (namespace_ids.len != 0 and std.mem.indexOfScalar(i32, namespace_ids, member_namespace.id) == null)
                    continue;
                const is_category = member_namespace.id == 14;
                if (is_category != categories) continue;
                var child_count: ?u32 = null;
                if (is_category) {
                    if (self.provider.category_stats) |stats_get| {
                        const child_key = try a.dupe(u8, member_namespace.text);
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
                if (is_category or member_namespace.id == 6) try out.append(a, ':');
                try out.appendSlice(a, title);
                if (is_category or std.ascii.eqlIgnoreCase(hideprefix, "always")) {
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
            if (preprocess.findTopDelimiterWithConversion(raw, '=', self.provider.language_conversion_enabled orelse false)) |eq| {
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

    fn hostFrameParserFunction(raw: ?*anyopaque, a: std.mem.Allocator, raw_name: []const u8, args: *rt.Table) anyerror![]const u8 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        self.invalidateNativeDependencyArguments();
        if (std.mem.indexOfScalar(u8, raw_name, 58)) |colon| {
            const head = raw_name[0..colon];
            if (try self.resolveParserFunction(head)) |canonical| {
                if ((self.provider.resolve_parser_function != null and std.mem.eql(u8, canonical, "isbn")) or
                    (self.provider.resolve_parser_function == null and std.mem.eql(u8, canonical, "#isbn")))
                    return (try self.isbnStrip(std.mem.trim(u8, raw_name[colon + 1..], " \t\r\n\x00\x0b"))) orelse error.UnsupportedParserFunction;
            }
        }
        const name = (try self.resolveParserFunction(raw_name)) orelse return error.UnsupportedParserFunction;
        const first = args.rawGet(.{ .number = 1 });
        const second = args.rawGet(.{ .number = 2 });
        if (self.provider.resolve_parser_function != null and (std.mem.eql(u8, name, "filepath") or std.mem.eql(u8, name, "pagesize"))) {
            const a1 = if (first) |value| (if (value == .nil) "" else std.mem.trim(u8, try self.scalarText(value), " \t\r\n")) else "";
            const a2 = if (second) |value| (if (value == .nil) "" else std.mem.trim(u8, try self.scalarText(value), " \t\r\n")) else "";
            const a3 = if (args.rawGet(.{ .number = 3 })) |value| (if (value == .nil) "" else std.mem.trim(u8, try self.scalarText(value), " \t\r\n")) else "";
            return if (std.mem.eql(u8, name, "filepath")) self.filePathMagic(a1, a2, a3) else self.pageSizeMagic(a1, a2);
        }
        if ((self.provider.resolve_parser_function != null and std.mem.eql(u8, name, "isbn")) or (self.provider.resolve_parser_function == null and std.mem.eql(u8, name, "#isbn"))) {
            const argument = if (first) |value| try self.scalarText(value) else "";
            return (try self.isbnStrip(std.mem.trim(u8, argument, " \t\r\n\x00\x0b"))) orelse error.UnsupportedParserFunction;
        }
        if (self.provider.resolve_parser_function != null and rt.namespace_registry.magic_words.statisticsId(name) != null) {
            const option: []const u8 = if (first) |value| switch (value) {
                .nil => "",
                .string => |text| text,
                else => return error.StringExpected,
            } else "";
            return (try self.statisticsMagic(name, option)) orelse unreachable;
        }
        if (std.ascii.eqlIgnoreCase(name, "pagesincategory")) {
            const third = args.rawGet(.{ .number = 3 });
            const category = if (first) |value| switch (value) {
                .nil => "",
                .string => |text| text,
                else => return error.StringExpected,
            } else "";
            const arg1 = if (second) |value| switch (value) {
                .nil => "",
                .string => |text| text,
                else => return error.StringExpected,
            } else "";
            const arg2 = if (third) |value| switch (value) {
                .nil => "",
                .string => |text| text,
                else => return error.StringExpected,
            } else "";
            return self.categoryCount(category, arg1, arg2);
        }
        if (try self.parserTitleMagic(name)) |canonical| {
            const page: ?[]const u8 = if (first) |value| switch (value) {
                .nil => null,
                .string => |text| text,
                else => return error.StringExpected,
            } else null;
            return (try self.titleMagic(canonical, page)) orelse unreachable;
        }
        if (isRevisionMagicName(name)) {
            const page: ?[]const u8 = if (first) |value| switch (value) {
                .nil => null,
                .string => |text| text,
                else => return error.StringExpected,
            } else null;
            return (try self.revisionMagic(name, page)) orelse unreachable;
        }
        if (std.ascii.eqlIgnoreCase(name, "language")) {
            const code: []const u8 = if (first) |value| switch (value) {
                .nil => "",
                .string => |text| text,
                else => return error.StringExpected,
            } else "";
            const display: ?[]const u8 = if (second) |value| switch (value) {
                .nil => null,
                .string => |text| text,
                else => return error.StringExpected,
            } else null;
            return self.languageName(code, display);
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
    try installTestHostWithTitle(runtime, string_slot, mw_slot, false);
}

fn installTestHostWithTitle(runtime: *rt.Context, string_slot: u32, mw_slot: u32, comptime with_title: bool) !void {
    const mw = try runtime.newNativeNamespace(.mw);
    const ustring = try runtime.newNativeNamespace(.ustring);
    const string = runtime.getGlobal(string_slot);
    if (string != .table) return error.MissingStringLibrary;
    var it = string.table.iterator();
    while (it.next()) |entry| try ustring.rawSet(runtime.allocator, entry.key_ptr.*, entry.value_ptr.*);
    const case_mapper = try ustring_lib.install(runtime, ustring);
    try mw.rawSet(runtime.allocator, .{ .string = "ustring" }, .{ .table = ustring });
    try text_lib.install(runtime, mw);
    if (with_title) try title_lib.install(runtime, mw, case_mapper);
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
        if (std.mem.eql(u8, title, "Template:PoemLateSpaces")) return "  B  ";
        if (std.mem.eql(u8, title, "Template:PoemLateTrimBytes")) return " \t\r\n\x00\x0bB \t\r\n\x00\x0b";
        if (std.mem.eql(u8, title, "Template:PoemLateKeepBytes")) return "\x0c\xc2\xa0B\xc2\xa0\x0c";
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
    var multi_tail_evaluations: usize = 0;
    var root_calls: usize = 0;

    fn lookup(_: ?*const anyopaque, raw_name: []const u8) ?u32 {
        return if (std.mem.eql(u8, raw_name, "Module:Test")) 0 else null;
    }
    fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
        return if (id == 0) "Module:Test" else null;
    }
    fn root(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        root_calls += 1;
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
        try exports.rawSet(ctx.allocator, .{ .string = "multi" }, try ctx.makeFunction(8, rt.stabilizeBuffered(multi), &.{}));
        try exports.rawSet(ctx.allocator, .{ .string = "empty" }, try ctx.makeFunction(9, rt.stabilizeBuffered(empty), &.{}));
        try exports.rawSet(ctx.allocator, .{ .string = "nil_return" }, try ctx.makeFunction(10, rt.stabilizeBuffered(nilReturn), &.{}));
        try exports.rawSet(ctx.allocator, .{ .string = "number" }, try ctx.makeFunction(11, rt.stabilizeBuffered(numericReturn), &.{}));
        try exports.rawSet(ctx.allocator, .{ .string = "nested_owned" }, try ctx.makeFunctionKnown(12, nestedOwned, &.{}));
        try exports.rawSet(ctx.allocator, .{ .string = "oom" }, try ctx.makeFunctionKnown(13, oom, &.{}));
        try exports.rawSet(ctx.allocator, .{ .string = "repair_oom" }, try ctx.makeFunctionKnown(14, repairOom, &.{}));
        try exports.rawSet(ctx.allocator, .{ .string = "lua_oom" }, try ctx.makeFunctionKnown(15, luaOom, &.{}));
        try exports.rawSet(ctx.allocator, .{ .string = "object" }, try ctx.makeFunctionKnown(16, objectReturn, &.{}));
        try exports.rawSet(ctx.allocator, .{ .string = "generated_comments" }, try ctx.makeFunctionKnown(17, generatedComments, &.{}));
        try exports.rawSet(ctx.allocator, .{ .string = "generated_unclosed" }, try ctx.makeFunctionKnown(18, generatedUnclosed, &.{}));
        try exports.rawSet(ctx.allocator, .{ .string = "generated_hiero" }, try ctx.makeFunctionKnown(19, generatedHiero, &.{}));
        try exports.rawSet(ctx.allocator, .{ .string = "value" }, .{ .number = 17 });
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
    fn generatedHiero(ctx: *rt.Context, _: rt.Captures, args: []const Value) ![]const Value {
        const frame_args = try ctx.getIndex(args[0], .{ .string = "args" });
        const raw = try ctx.getIndex(frame_args, .{ .number = 1 });
        const source = if (raw == .string) raw.string else "<hiero>D35:t*y-nDs-f</hiero>";
        const call = try ctx.getIndex(args[0], .{ .string = "preprocess" });
        const expanded = try ctx.callValue(call, &.{ args[0], .{ .string = source } });
        defer rt.freeResults(expanded);
        var out: std.ArrayList(u8) = .empty;
        // Module:languages rev92737865 escape_risky_characters, after its
        // temporary formatting substitutions. General marker bytes are intact.
        for (expanded[0].string) |ch| {
            if (std.mem.indexOfScalar(u8, "!#%&*+/:;<=>?@[\\]_{|}", ch) != null)
                try out.appendSlice(ctx.allocator, try std.fmt.allocPrint(ctx.allocator, "&#{d};", .{ch}))
            else
                try out.append(ctx.allocator, ch);
        }
        const values = try std.heap.smp_allocator.alloc(Value, 1);
        values[0] = .{ .string = try out.toOwnedSlice(ctx.allocator) };
        return values;
    }
    fn generatedComments(_: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .string = "Generated A__NOEDIT<!--generated-->SECTION__B\nISBN 97803<!--generated-->06406157\n__T<!--generated-->OC__\nISBN 97803__TOC__06406157\n<!--generated-only-->\nTail\n<no<!--x-->wiki>__NOEDITSECTION__[[B]]</nowiki>\nA<!<!--inner-->--outer-->B" };
        return out;
    }
    fn generatedUnclosed(_: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .string = "Unclosed <!--tail __NOEDITSECTION__ [[B]] ISBN 9780306406157" };
        return out;
    }
    fn fail(_: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        return error.NotCallable;
    }
    fn oom(_: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        return error.OutOfMemory;
    }
    fn repairOom(ctx: *rt.Context, _: rt.Captures, args: []const Value) ![]const Value {
        if (args.len == 0 or args[0] != .table) return error.FrameExpected;
        const frame_args = try ctx.getIndex(args[0], .{ .string = "args" });
        const value = try ctx.getIndex(frame_args, .{ .string = "x" });
        if (value != .string) return error.StringExpected;
        if (std.mem.indexOf(u8, value.string, "&lt;") != null) {
            ctx.setLuaError(.{ .string = "Invalid page title \"Reconstruction:Probe/term&lt;t:gloss&gt;\" encountered." });
            return error.LuaRaised;
        }
        return error.OutOfMemory;
    }
    fn luaOom(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        ctx.setLuaError(.{ .string = "OutOfMemory" });
        return error.LuaRaised;
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
    fn nestedOwned(ctx: *rt.Context, _: rt.Captures, args: []const Value) ![]const Value {
        const live = try ctx.allocator.alloc(u8, 80_000);
        @memset(live, 0x39);
        const before = try ctx.concatValues(&.{ .{ .string = "outer-" }, .{ .string = "before" } });
        const preprocess_fn = try ctx.getIndex(args[0], .{ .string = "preprocess" });
        const nested_result = try ctx.callValue(preprocess_fn, &.{ args[0], .{ .string = "{{#invoke:Test|run|x=inner}}" } });
        defer rt.freeResults(nested_result);
        if (nested_result.len != 1) return error.ExpectedNestedResult;
        for (live) |byte| if (byte != 0x39) return error.OuterInvokeMemoryChanged;
        const joined = try ctx.concatValues(&.{ before, .{ .string = ":" }, nested_result[0], .{ .string = ":outer-after" } });
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = joined;
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
    fn multi(_: *rt.Context, _: rt.Captures, _: []const Value, buffer: ?[]Value) ![]const Value {
        if (buffer != null) return error.ExpectedUnboundedResult;
        const out = try rt.returnBuffer(buffer, 2);
        rt.storeReturn(out, 0, .{ .string = "first" });
        multi_tail_evaluations += 1;
        rt.storeReturn(out, 1, .{ .string = "second" });
        return out;
    }
    fn empty(_: *rt.Context, _: rt.Captures, _: []const Value, buffer: ?[]Value) ![]const Value {
        return try rt.returnBuffer(buffer, 0);
    }
    fn nilReturn(_: *rt.Context, _: rt.Captures, _: []const Value, buffer: ?[]Value) ![]const Value {
        const out = try rt.returnBuffer(buffer, 1);
        rt.storeReturn(out, 0, .nil);
        return out;
    }
    fn numericReturn(_: *rt.Context, _: rt.Captures, _: []const Value, buffer: ?[]Value) ![]const Value {
        const out = try rt.returnBuffer(buffer, 1);
        rt.storeReturn(out, 0, .{ .number = 12 });
        return out;
    }
    fn objectReturn(ctx: *rt.Context, _: rt.Captures, args: []const Value) ![]const Value {
        const object = try ctx.newTable();
        const frame_args = try ctx.getIndex(args[0], .{ .string = "args" });
        try object.rawSet(ctx.allocator, .{ .string = "frame" }, args[0]);
        try object.rawSet(ctx.allocator, .{ .string = "mode" }, try ctx.getIndex(frame_args, .{ .string = "mode" }));
        const mt = try ctx.newTable();
        try mt.rawSet(ctx.allocator, .{ .string = "__tostring" }, try ctx.newNative(null, objectString));
        object.metatable = mt;
        return std.heap.smp_allocator.dupe(Value, &.{.{ .table = object }});
    }
    fn objectString(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
        const frame = args[0].table.rawGet(.{ .string = "frame" }).?;
        if (ctx.current_frame != frame.table) return error.InvokeFrameNotActive;
        if (host_api.getForInvokeBookkeeping(ctx).?.invoke_depth != 0) return error.InvokeDepthNotRestored;
        const mode = args[0].table.rawGet(.{ .string = "mode" }) orelse .nil;
        if (mode == .string) {
            if (std.mem.eql(u8, mode.string, "oom")) return error.OutOfMemory;
            if (std.mem.eql(u8, mode.string, "timeout")) return error.Timeout;
            if (std.mem.eql(u8, mode.string, "fail")) {
                ctx.setLuaError(.{ .string = "object conversion failure" });
                return error.LuaRaised;
            }
            if (std.mem.eql(u8, mode.string, "invalid"))
                return std.heap.smp_allocator.dupe(Value, &.{.{ .number = 7 }});
        }
        return std.heap.smp_allocator.dupe(Value, &.{.{ .string = "object text" }});
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

const TranslationReuseProbe = struct {
    var active_context: ?*rt.Context = null;

    fn lookup(_: ?*const anyopaque, raw_name: []const u8) ?u32 {
        if (std.mem.eql(u8, raw_name, "Module:translations")) return 0;
        return if (std.mem.eql(u8, raw_name, "Module:Ordinary")) 1 else null;
    }

    fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
        return switch (id) {
            0 => "Module:translations",
            1 => "Module:Ordinary",
            else => null,
        };
    }

    fn root(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        const exports = try ctx.newTable();
        const state = try ctx.allocator.create(rt.Cell);
        state.* = .{ .value = .{ .number = 0 } };
        try exports.rawSet(ctx.allocator, .{ .string = "show" }, try ctx.makeFunctionKnown(1, show, &.{state}));
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .table = exports };
        return out;
    }

    fn show(ctx: *rt.Context, captures: rt.Captures, args: []const Value) ![]const Value {
        if (args.len == 0 or args[0] != .table) return error.FrameExpected;
        const frame_args = try ctx.getIndex(args[0], .{ .string = "args" });
        const mode = try ctx.getIndex(frame_args, .{ .string = "mode" });
        if (mode != .string) return error.StringExpected;
        if (std.mem.eql(u8, mode.string, "stateful")) {
            const state = try captures.cell(0);
            state.value.number += 1;
            const out = try std.heap.smp_allocator.alloc(Value, 1);
            out[0] = state.value;
            return out;
        }
        if (std.mem.eql(u8, mode.string, "named-failure")) {
            ctx.last_error = .{ .string = try ctx.allocator.dupe(u8, "first failure") };
            return error.LuaRaised;
        }
        if (std.mem.eql(u8, mode.string, "generic-failure")) return error.NotImplemented;
        if (std.mem.eql(u8, mode.string, "inner")) {
            const out = try std.heap.smp_allocator.alloc(Value, 1);
            out[0] = .{ .string = if (active_context == ctx) "reused" else "fresh" };
            return out;
        }
        if (std.mem.eql(u8, mode.string, "middle")) {
            const preprocess_fn = try ctx.getIndex(args[0], .{ .string = "preprocess" });
            return ctx.callValue(preprocess_fn, &.{ args[0], .{ .string = "{{#invoke:translations|show|mode=inner}}" } });
        }
        if (std.mem.eql(u8, mode.string, "outer")) {
            active_context = ctx;
            defer active_context = null;
            const preprocess_fn = try ctx.getIndex(args[0], .{ .string = "preprocess" });
            const nested = try ctx.callValue(preprocess_fn, &.{ args[0], .{ .string = "{{#invoke:translations|show|mode=middle}}" } });
            defer rt.freeResults(nested);
            if (nested.len != 1 or nested[0] != .string) return error.ExpectedNestedResult;
            const out = try std.heap.smp_allocator.alloc(Value, 1);
            out[0] = .{ .string = try ctx.allocator.dupe(u8, nested[0].string) };
            return out;
        }
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .string = "ok" };
        return out;
    }
};

test "reused invoke args own caller strings" {
    var page_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer page_arena.deinit();
    var runtime = try rt.Context.initProgram(page_arena.allocator(), 0, 0);
    defer runtime.deinit();

    var caller_arena = LocalBumpArena.init(std.testing.allocator);
    const caller_a = caller_arena.allocator();
    var caller = try rt.Context.initProgram(caller_a, 0, 0);
    const source = try caller.newTable();
    const source_key = try caller_a.dupe(u8, "memo-key");
    const source_value = try caller_a.dupe(u8, "memo-value");
    try source.rawSet(caller_a, .{ .string = source_key }, .{ .string = source_value });

    const copied = try Expander.copyArgsTable(&runtime, source, true);
    var copied_it = copied.iterator();
    const copied_entry = copied_it.next() orelse return error.TestUnexpectedResult;
    try std.testing.expect(copied_entry.key_ptr.* == .string);
    try std.testing.expect(copied_entry.value_ptr.* == .string);
    try std.testing.expect(@intFromPtr(copied_entry.key_ptr.string.ptr) != @intFromPtr(source_key.ptr));
    try std.testing.expect(@intFromPtr(copied_entry.value_ptr.string.ptr) != @intFromPtr(source_value.ptr));

    caller.deinit();
    caller_arena.deinit();

    const retained = copied.rawGet(.{ .string = "memo-key" }) orelse return error.TestUnexpectedResult;
    try std.testing.expect(retained == .string);
    try std.testing.expectEqualStrings("memo-value", retained.string);
}

test "translations show page cache resets failures and avoids reentrant reuse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 24, 2);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{ rt.stabilize(TranslationReuseProbe.root), rt.stabilize(TranslationReuseProbe.root) };
    runtime.module_root_entries = &functions;
    runtime.configureModules(null, TranslationReuseProbe.lookup, TranslationReuseProbe.name);
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);

    var expander = Expander{
        .runtime = &runtime,
        .env_slot = 0,
        .string_slot = 18,
        .mw_slot = 23,
        .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists },
        .install_scribunto = installTestInvoke,
    };
    const failures = try expander.expandFragment(
        "Page",
        "{{#invoke:translations|show|mode=named-failure}}|{{#invoke:translations|show|mode=generic-failure}}",
        1_670_803_200,
    );
    try std.testing.expect(std.mem.indexOf(u8, failures, "first failure") != null);
    try std.testing.expect(std.mem.indexOf(u8, failures, "NotImplemented") != null);
    try std.testing.expect(expander.hot_translation_runtime != null);

    const nested = try expander.expandFragment(
        "Page",
        "{{#invoke:translations|show|mode=outer}}",
        1_670_803_200,
    );
    try std.testing.expectEqualStrings("fresh", nested);
    try std.testing.expect(expander.hot_translation_runtime != null);
    expander.beginPage("Other page", "", 1_670_803_200);
    try std.testing.expect(expander.hot_translation_runtime == null);

    // General invoke rollback must not replace the existing translations
    // page cache or discard its retained module graph after every call.
    const repeated = try expander.expandFragment(
        "Page",
        "{{#invoke:translations|show|mode=stateful}}|{{#invoke:translations|show|mode=stateful}}",
        1_670_803_200,
    );
    try std.testing.expectEqualStrings("1|2", repeated);
    const next_page = try expander.expandFragment(
        "Next page",
        "{{#invoke:translations|show|mode=stateful}}",
        1_670_803_200,
    );
    try std.testing.expectEqualStrings("1", next_page);

    const mixed = try expander.expandFragment(
        "Mixed page",
        "{{#invoke:Ordinary|show|mode=outer}}|{{#invoke:translations|show|mode=stateful}}|" ++
            "{{#invoke:Ordinary|show|mode=stateful}}|{{#invoke:translations|show|mode=stateful}}|" ++
            "{{#invoke:Ordinary|show|mode=stateful}}",
        1_670_803_200,
    );
    try std.testing.expectEqualStrings("fresh|1|1|2|1", mixed);
    try std.testing.expect(expander.hot_translation_runtime != expander.page_invoke_runtime);
    try std.testing.expect(expander.hot_translation_runtime.?.module_template_context == &runtime);
    try std.testing.expect(!expander.hot_translation_active and !expander.page_invoke_active);
}

test "ifexist rejects invalid title bodies before provider lookup" {
    const Source = struct {
        calls: usize = 0,
        expected: []const u8 = "",
        fail: bool = false,

        fn exists(raw: ?*anyopaque, title: []const u8) !bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            try std.testing.expectEqualStrings(self.expected, title);
            if (self.fail) return error.FileMetadataSnapshotMissing;
            return true;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var registry = try rt.namespace_registry.Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tbnwiktionary\n# dump-date\t20261001\n# content-language\tbn\n" ++
        "-2\tমিডিয়া\tMedia\tcase-sensitive\t0\t0\t0\t\tcompile_only\tinput\n" ++
        "-1\tবিশেষ\tSpecial\tcase-sensitive\t0\t0\t0\t\tcompile_only\tinput\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tentries\n" ++
        "6\tচিত্র\tFile\tcase-sensitive\t0\t0\t0\t\tcompile_only\tinput\n" ++
        "10\tটেমপ্লেট\tTemplate\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n" ++
        "14\tবিষয়শ্রেণী\tCategory\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\n");
    defer registry.deinit();
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    runtime.namespace_catalog = &registry;
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var source: Source = .{};
    var expander = Expander{
        .runtime = &runtime,
        .env_slot = 0,
        .string_slot = 18,
        .mw_slot = 23,
        .provider = .{ .ctx = &source, .get = TestProvider.get, .exists = Source.exists },
    };

    var ascii: [256]u8 = undefined;
    @memset(&ascii, 'a');
    var unicode: [255]u8 = undefined;
    for (0..85) |i| @memcpy(unicode[i * 3 ..][0..3], "অ");
    var special: [513]u8 = undefined;
    @memset(&special, 's');
    const Case = struct { input: []const u8, expected: ?[]const u8 };
    const cases = [_]Case{
        .{ .input = try std.fmt.allocPrint(a, "Media:{s}", .{ascii[0..255]}), .expected = try std.fmt.allocPrint(a, "মিডিয়া:{s}", .{ascii[0..255]}) },
        .{ .input = try std.fmt.allocPrint(a, "Media:{s}", .{&ascii}), .expected = null },
        .{ .input = try std.fmt.allocPrint(a, "File:{s}", .{&unicode}), .expected = try std.fmt.allocPrint(a, "চিত্র:{s}", .{&unicode}) },
        .{ .input = try std.fmt.allocPrint(a, "মিডিয়া:{s}a", .{&unicode}), .expected = null },
        .{ .input = try std.fmt.allocPrint(a, "  :Media:__{s}__#ignored", .{ascii[0..255]}), .expected = try std.fmt.allocPrint(a, "মিডিয়া:{s}", .{ascii[0..255]}) },
        .{ .input = try std.fmt.allocPrint(a, "Special:{s}", .{special[0..512]}), .expected = try std.fmt.allocPrint(a, "বিশেষ:{s}", .{special[0..512]}) },
        .{ .input = try std.fmt.allocPrint(a, "Special:{s}", .{&special}), .expected = null },
        .{ .input = "Media:Foo&amp;Bar.ogg", .expected = "মিডিয়া:Foo&Bar.ogg" },
        .{ .input = "Media&#58;Foo.ogg", .expected = "মিডিয়া:Foo.ogg" },
        .{ .input = "Media:Foo&amp;amp;Bar.ogg", .expected = null },
        .{ .input = "Media:", .expected = null },
        .{ .input = "Media:bad%20name.ogg", .expected = null },
        .{ .input = "Media:bad/../name.ogg", .expected = null },
        .{ .input = "Media:bad~~~name.ogg", .expected = null },
    };
    for (cases) |case| {
        source.calls = 0;
        source.expected = case.expected orelse "";
        const text = try std.fmt.allocPrint(a, "{{{{#ifexist:{s}|yes|no}}}}", .{case.input});
        const got = try expander.expandFragment("Entry", text, 1_670_803_200);
        try std.testing.expectEqualStrings(if (case.expected != null) "yes" else "no", got);
        try std.testing.expectEqual(@as(usize, if (case.expected != null) 1 else 0), source.calls);
    }

    // A valid boundary title must still request its provider and propagate an
    // uncaptured file failure. Invalid syntax is not a missing-file waiver.
    source.calls = 0;
    source.expected = cases[0].expected.?;
    source.fail = true;
    const missing = try std.fmt.allocPrint(a, "{{{{#ifexist:{s}|yes|no}}}}", .{cases[0].input});
    try std.testing.expectError(error.FileMetadataSnapshotMissing, expander.expandFragment("Entry", missing, 1_670_803_200));
    try std.testing.expectEqual(@as(usize, 1), source.calls);
}

test "ifexist Bengali finite filename constructors reject overlong names without metadata" {
    const Source = struct {
        calls: usize = 0,

        fn exists(raw: ?*anyopaque, _: []const u8) !bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return error.FileMetadataSnapshotMissing;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var source: Source = .{};
    var expander = Expander{
        .runtime = &runtime,
        .env_slot = 0,
        .string_slot = 18,
        .mw_slot = 23,
        .provider = .{ .ctx = &source, .get = TestProvider.get, .exists = Source.exists },
    };
    const page = "তিন নাড়ায় সুপারি সোনা, তিন নাড়ায় নারকেল টেনা, তিন নাড়ায় শ্রীফল বেল, তিন নাড়ায় গেরস্থ গেল";
    const names = [_][]const u8{
        "LL-Q9610 (ben)-Titodutta-" ++ page ++ ".wav",
        "LL-Q9610 (ben)-Aishik Rehman-" ++ page ++ ".wav",
        "bn-" ++ page ++ ".ogg",
    };
    for (names) |name| {
        const text = try std.fmt.allocPrint(a, "{{{{#ifexist:Media:{s}|{{{{#ifexist:Media:Uncaptured.ogg|bad|bad}}}}|absent}}}}", .{name});
        try std.testing.expectEqualStrings("absent", try expander.expandFragment(page, text, 1_670_803_200));
    }
    try std.testing.expectEqual(@as(usize, 0), source.calls);
}

test "native AOT wikitext expands templates parser functions and invoke" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 24, 1);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{ rt.stabilize(TestModule.root), rt.stabilize(TestModule.run), rt.stabilize(TestModule.fail), rt.stabilize(TestModule.random), rt.stabilize(TestModule.stateful), rt.stabilize(TestModule.nested), rt.stabilize(TestModule.repair), rt.stabilize(TestModule.repairParent), rt.stabilizeBuffered(TestModule.multi), rt.stabilizeBuffered(TestModule.empty), rt.stabilizeBuffered(TestModule.nilReturn), rt.stabilizeBuffered(TestModule.numericReturn) };
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
    expander.provider.site_server = "//en.wiktionary.org";
    expander.provider.site_script = "/w/index.php";
    expander.provider.site_article_path = "/wiki/$1";
    const site_magic = try expander.expandFragment("Page", "{{SERVER}}|{{SERVERNAME}}", 1_670_803_200);
    try std.testing.expectEqualStrings("//en.wiktionary.org|en.wiktionary.org", site_magic);
    const urlencode_param = try expander.expandFragment("Page", "{{urlencode:flundra 1°|PARAM}}", 1_670_803_200);
    try std.testing.expectEqualStrings("flundra+1%C2%B0", urlencode_param);
    const urlencode_unknown = try expander.expandFragment("Page", "{{urlencode:a b/c*|not-a-mode}}", 1_670_803_200);
    try std.testing.expectEqualStrings("a+b%2Fc%2A", urlencode_unknown);
    const urlencode_path = try expander.expandFragment("Page", "{{urlencode:a b/c*|PATH}}", 1_670_803_200);
    try std.testing.expectEqualStrings("a%20b%2Fc%2A", urlencode_path);
    const inert_hash_urlencode = try expander.expandFragment("Page", "{{#urlencode:जलाना|PATH}}", 1_670_803_200);
    try std.testing.expectEqualStrings("&#123;&#123;#urlencode:जलाना|PATH&#125;&#125;", inert_hash_urlencode);
    const inert_empty_template = try expander.expandFragment("Page", "{{|yue|洛陽}}", 1_670_803_200);
    try std.testing.expectEqualStrings("<nowiki>{{|yue|洛陽}}</nowiki>", inert_empty_template);
    // Afrikaans Sjabloon:S computes this empty name when woordklank receives
    // taal=nl but forwards its optional t parameter without a value.
    const computed_empty_template = try expander.expandFragment("Page", "{{{{{1|}}}|no=1}}", 1_670_803_200);
    try std.testing.expectEqualStrings("<nowiki>{{</nowiki>|no=1<nowiki>}}</nowiki>", computed_empty_template);
    const computed_empty_args = try expander.expandFragment("Page", "{{{{#if:|unused}}| [[Example]] |key={{#expr:2+3}}}}", 1_670_803_200);
    try std.testing.expectEqualStrings("<nowiki>{{</nowiki>| [[Example]] |key=5<nowiki>}}</nowiki>", computed_empty_args);
    const computed_empty_no_args = try expander.expandFragment("Page", "{{{{{1|}}}}}", 1_670_803_200);
    try std.testing.expectEqualStrings("<nowiki>{{</nowiki><nowiki>}}</nowiki>", computed_empty_no_args);
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
    // Poem is general strip output: exact authenticated items, not raw tag text.
    try std.testing.expectEqual(@as(usize, 3), expander.poem_items.items.len);
    const poem_br = expander.poem_items.items[0];
    const poem_scope = expander.poem_items.items[1];
    const poem_literal = expander.poem_items.items[2];
    try std.testing.expect(poem_br.kind == .br and poem_scope.kind == .scope and poem_literal.kind == .literal);
    try std.testing.expectEqualStrings("poem", poem_literal.tag.?);
    var poem_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("one\ntwo", &poem_hash, .{});
    const poem_hex = std.fmt.bytesToHex(poem_hash, .lower);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(runtime.allocator, "{s}0:{s}\x7f", .{ poem_prefix, poem_hex }), poem_br.token);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(runtime.allocator, "{s}1:{s}\x7f", .{ poem_prefix, poem_hex }), poem_scope.token);
    const expected_poem_body = try std.fmt.allocPrint(runtime.allocator, "{s}<poem>one{s}\ntwo</poem>", .{ poem_scope.token, poem_br.token });
    try std.testing.expectEqualStrings(expected_poem_body, poem_literal.body.?);
    std.crypto.hash.sha2.Sha256.hash(expected_poem_body, &poem_hash, .{});
    const literal_hex = std.fmt.bytesToHex(poem_hash, .lower);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(runtime.allocator, "{s}2:{s}\x7f", .{ poem_prefix, literal_hex }), poem_literal.token);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(runtime.allocator, "Hi Bob Y|ABCD|space-template|space-template|main-transclusion|project-transclusion|Hi Z Y|yes|yes|14|E|W|HÉ|øøé|2022|<ref name=\"n\">body</ref>|<math>x+y</math>|{s}|ok", .{poem_literal.token}), got);
    var poem_metadata = try std.json.parseFromSlice(PoemMetadata, runtime.allocator, expander.poem_metadata.?, .{});
    defer poem_metadata.deinit();
    try std.testing.expectEqualStrings("wikidict.poem-phase.v1", poem_metadata.value.schema);
    try std.testing.expect(poem_metadata.value.handled);
    try std.testing.expectEqual(@as(usize, 3), poem_metadata.value.items.len);
    for (poem_metadata.value.items, expander.poem_items.items) |wire_item, retained_item| {
        try std.testing.expect(wire_item.kind == retained_item.kind);
        try std.testing.expectEqualStrings(retained_item.token, wire_item.token);
    }
    try std.testing.expectEqualStrings(expected_poem_body, poem_metadata.value.items[2].body.?);
    std.crypto.hash.sha2.Sha256.hash(got, &poem_hash, .{});
    const output_hex = std.fmt.bytesToHex(poem_hash, .lower);
    try std.testing.expectEqualStrings(&output_hex, poem_metadata.value.output_sha256);
    try std.testing.expect(expander.display_title == null);
    std.crypto.hash.sha2.Sha256.hash("", &poem_hash, .{});
    const title_hex = std.fmt.bytesToHex(poem_hash, .lower);
    try std.testing.expectEqualStrings(&title_hex, poem_metadata.value.display_title_sha256);
    TestModule.multi_tail_evaluations = 0;
    const bounded_invoke = try expander.expandFragment("Page", "{{#invoke:Test|multi}}|{{#invoke:Test|empty}}|{{#invoke:Test|nil_return}}|{{#invoke:Test|number}}", 1_670_803_200);
    try std.testing.expectEqualStrings("firstsecond|||12", bounded_invoke);
    try std.testing.expectEqual(@as(usize, 1), TestModule.multi_tail_evaluations);
    const object_invoke = try expander.expandFragment("Page", "{{#invoke:Test|object}}|{{#iferror:{{#invoke:Test|object|mode=fail}}|caught|wrong}}|{{#iferror:{{#invoke:Test|object|mode=invalid}}|invalid|wrong}}", 1_670_803_200);
    try std.testing.expectEqualStrings("object text|caught|invalid", object_invoke);
    try std.testing.expectError(error.Timeout, expander.expandFragment("Page", "{{#invoke:Test|object|mode=timeout}}", 1_670_803_200));

    const random_top_level = try expander.expandFragment("Page", "{{#invoke:Test|random}}|{{#invoke:Test|random}}", 1_670_803_200);
    try std.testing.expectEqualStrings("9|9", random_top_level);
    const roots_before_isolated = TestModule.root_calls;
    const isolated_module_state = try expander.expandFragment("Page", "{{#invoke:Test|stateful}}|{{#invoke:Test|stateful}}", 1_670_803_200);
    try std.testing.expectEqualStrings("1|1", isolated_module_state);
    try std.testing.expectEqual(
        roots_before_isolated + 1,
        TestModule.root_calls,
    );
    const roots_before_next_page = TestModule.root_calls;
    const isolated_next_page = try expander.expandFragment(
        "Other page",
        "{{#invoke:Test|stateful}}|{{#invoke:Test|stateful}}",
        1_670_803_200,
    );
    try std.testing.expectEqualStrings("1|1", isolated_next_page);
    try std.testing.expectEqual(
        roots_before_next_page + 1,
        TestModule.root_calls,
    );
    const nested_invoke_wikitext = try expander.expandFragment("Page", "{{#invoke:Test|nested}}", 1_670_803_200);
    try std.testing.expectEqualStrings("<ref>Hi R Y</ref>", nested_invoke_wikitext);

    const nested_owned = try expander.expandFragment("Page", "{{#invoke:Test|nested_owned}}|{{#invoke:Test|nested_owned}}", 1_670_803_200);
    try std.testing.expectEqualStrings("outer-before:inner:outer-after|outer-before:inner:outer-after", nested_owned);

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
    try std.testing.expect(std.mem.startsWith(u8, extension_bodies, "<math>{{Hello|M|1}}</math>|<syntaxhighlight>{{Hello|S|1}}</syntaxhighlight>|<ref>Hi R Y</ref>|"));
    try std.testing.expectEqual(@as(usize, 2), expander.poem_items.items.len);
    const template_scope = expander.poem_items.items[0];
    const template_poem = expander.poem_items.items[1];
    try std.testing.expect(template_scope.kind == .scope and template_poem.kind == .literal);
    try std.testing.expectEqualStrings("poem", template_poem.tag.?);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(runtime.allocator, "{s}<poem>Hi P Y</poem>", .{template_scope.token}), template_poem.body.?);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(runtime.allocator, "<math>{{{{Hello|M|1}}}}</math>|<syntaxhighlight>{{{{Hello|S|1}}}}</syntaxhighlight>|<ref>Hi R Y</ref>|{s}", .{template_poem.token}), extension_bodies);
    try std.testing.expect(expander.poem_metadata != null);
    // Ordinary templates expand after the raw Poem transforms. The hook's
    // late trim removes only boundary PHP whitespace before block parsing.
    for ([_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "<poem>{{PoemLateSpaces}}</poem>", .expected = "B" },
        .{ .source = "<poem>{{PoemLateTrimBytes}}</poem>", .expected = "B" },
        .{ .source = "<poem>{{PoemLateKeepBytes}}</poem>", .expected = "\x0c\xc2\xa0B\xc2\xa0\x0c" },
        .{ .source = "<poem>  B  </poem>", .expected = "&#160;&#160;B" },
    }) |case| {
        const result = try expander.expandFragment("Page", case.source, 1_670_803_200);
        try std.testing.expectEqual(@as(usize, 2), expander.poem_items.items.len);
        const scope_item = expander.poem_items.items[0];
        const literal_item = expander.poem_items.items[1];
        try std.testing.expect(scope_item.kind == .scope and literal_item.kind == .literal);
        try std.testing.expectEqualStrings("poem", literal_item.tag.?);
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(runtime.allocator, "{s}<poem>{s}</poem>", .{ scope_item.token, case.expected }), literal_item.body.?);
        try std.testing.expectEqualStrings(literal_item.token, result);
        try std.testing.expect(expander.poem_metadata != null);
    }
    const protected_trim = try expander.expandFragment("Page", "<poem><nowiki>  B  </nowiki></poem>", 1_670_803_200);
    try std.testing.expectEqual(@as(usize, 3), expander.poem_items.items.len);
    const protected_item = expander.poem_items.items[0];
    const protected_scope = expander.poem_items.items[1];
    const protected_poem = expander.poem_items.items[2];
    try std.testing.expect(protected_item.kind == .literal and protected_scope.kind == .scope and protected_poem.kind == .literal);
    try std.testing.expectEqualStrings("nowiki", protected_item.tag.?);
    try std.testing.expectEqualStrings("  B  ", protected_item.body.?);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(runtime.allocator, "{s}<poem>{s}</poem>", .{ protected_scope.token, protected_item.token }), protected_poem.body.?);
    try std.testing.expectEqualStrings(protected_poem.token, protected_trim);
    const trailing_break = try expander.expandFragment("Page", "<poem>A\n\n</poem>", 1_670_803_200);
    try std.testing.expectEqual(@as(usize, 3), expander.poem_items.items.len);
    const trailing_br = expander.poem_items.items[0];
    const trailing_scope = expander.poem_items.items[1];
    const trailing_poem = expander.poem_items.items[2];
    try std.testing.expect(trailing_br.kind == .br and trailing_scope.kind == .scope and trailing_poem.kind == .literal);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(runtime.allocator, "{s}<poem>A{s}</poem>", .{ trailing_scope.token, trailing_br.token }), trailing_poem.body.?);
    try std.testing.expectEqualStrings(trailing_poem.token, trailing_break);
    // The existing Lua fixture forwards its already-expanded argument. A real
    // registered extension result must not become an authored-prefix carrier
    // when the outer invoke processes that generated return value.
    const returned_poem = try expander.expandFragment("Page", "{{#invoke:Test|run|x={{#tag:poem|::[[B]]\nTail}}}}", 1_670_803_200);
    try std.testing.expectEqual(@as(usize, 4), expander.poem_items.items.len);
    const returned_indent = expander.poem_items.items[0];
    const returned_br = expander.poem_items.items[1];
    const returned_scope = expander.poem_items.items[2];
    const returned_literal = expander.poem_items.items[3];
    try std.testing.expect(returned_indent.kind == .indent and returned_indent.depth == 2 and returned_br.kind == .br and returned_scope.kind == .scope and returned_literal.kind == .literal);
    try std.testing.expectEqualStrings("poem", returned_literal.tag.?);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(runtime.allocator, "{s}<poem>{s}<span class=\"mw-poem-indented\" style=\"display: inline-block; margin-inline-start: 2em;\">[[B]]</span>{s}\nTail</poem>", .{ returned_scope.token, returned_indent.token, returned_br.token }), returned_literal.body.?);
    try std.testing.expectEqualStrings(returned_literal.token, returned_poem);
    try std.testing.expect(expander.poem_metadata != null);
    const collision_token = "\x7fWDPOEM:0:23519a43c66b4c342f25b32e09797ec5f3fc0be388cd8243fb3449afbdce4013\x7f";
    const collision_source = try std.fmt.allocPrint(runtime.allocator, "<poem>A\nB</poem><poem>{s}</poem>", .{collision_token});
    _ = try expander.expandFragment("Page", collision_source, 1_670_803_200);
    var authored_prefix_carried = false;
    var generated_break = false;
    for (expander.poem_items.items) |item| {
        if (item.kind == .literal and std.mem.eql(u8, item.tag orelse "", "text") and std.mem.eql(u8, item.body orelse "", poem_prefix)) authored_prefix_carried = true;
        if (item.kind == .br and std.mem.eql(u8, item.token, collision_token)) generated_break = true;
    }
    try std.testing.expect(authored_prefix_carried and generated_break);
    try std.testing.expect(expander.poem_metadata != null);
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

    const missing_export = try expander.expandFragment("Page", "A{{#invoke:Test|missing}}B{{#invoke:Test|run|x=OK}}", 1_670_803_200);
    try std.testing.expectEqualStrings("A<strong class=\"error\"><span class=\"scribunto-error\">Lua error in Module:Test: The function \"missing\" does not exist.</span></strong>BOK", missing_export);
    const nonfunction_export = try symbolic_expander.expandFragment("Page", "A{{#invoke:@module|value}}B{{#invoke:@module|@function|x=OK}}", 1_670_803_200);
    try std.testing.expectEqualStrings("A<strong class=\"error\"><span class=\"scribunto-error\">Lua error in Module:Test: \"value\" is not a function.</span></strong>BOK", nonfunction_export);
    const export_iferror = try symbolic_expander.expandFragment("Page", "{{#iferror:{{#invoke:@module|missing}}|MISSING|BAD}}|{{#iferror:{{#invoke:Test|value}}|NONFUNCTION|BAD}}|{{#iferror:{{#invoke:Test|run|x=OK}}|BAD|VALID}}", 1_670_803_200);
    try std.testing.expectEqualStrings("MISSING|NONFUNCTION|VALID", export_iferror);
    const escaped_export = try expander.expandFragment("Page", "{{#invoke:Test|<b>&}}", 1_670_803_200);
    try std.testing.expectEqualStrings("<strong class=\"error\"><span class=\"scribunto-error\">Lua error in Module:Test: The function \"&lt;b&gt;&amp;\" does not exist.</span></strong>", escaped_export);
    try std.testing.expect(runtime.current_frame == null and runtime.aotErrorName() == null and !runtime.last_error_present);
}

test "AOT invoke allocation failures propagate to the worker instead of rendering" {
    for ([_][]const u8{
        "A{{#invoke:Test|oom}}B",
        "{{#iferror:{{#invoke:Test|oom}}|caught|success}}",
        "A{{#invoke:Test|repair_oom|x=term&lt;t:gloss&gt;}}B",
        "{{#invoke:Test|lua_oom}}",
        "{{#invoke:Test|object|mode=oom}}",
    }) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var runtime = try rt.Context.initProgram(arena.allocator(), 24, 1);
        defer runtime.deinit();
        const functions = [_]rt.FunctionFn{rt.stabilize(TestModule.root)};
        runtime.module_root_entries = &functions;
        runtime.configureModules(null, TestModule.lookup, TestModule.name);
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
        if (std.mem.indexOf(u8, source, "lua_oom") != null) {
            const rendered = try expander.expandFragment("Page", source, 1_670_803_200);
            try std.testing.expect(std.mem.indexOf(u8, rendered, "Lua error in Module:Test: OutOfMemory") != null);
            try std.testing.expect(runtime.aotErrorName() == null);
        } else {
            try std.testing.expectError(error.OutOfMemory, expander.expandFragment("Page", source, 1_670_803_200));
            try std.testing.expectEqualStrings("OutOfMemory", runtime.aotErrorName().?);
        }
        try std.testing.expect(runtime.current_frame == null);
    }
}

test "invoke export recovery preserves unrelated runtime and host errors" {
    const Probe = struct {
        fn install(_: *?*anyopaque, shared: ?*anyopaque, _: std.mem.Allocator, _: *rt.Context, _: u32, _: u32, _: u32) anyerror!void {
            const failure: *const anyerror = @ptrCast(@alignCast(shared.?));
            return failure.*;
        }
    };
    for ([_]anyerror{ error.NotCallable, error.OutOfMemory, error.FileMetadataSnapshotMissing, error.IndexType, error.Timeout }) |expected_error| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var runtime = try rt.Context.initProgram(arena.allocator(), 24, 1);
        defer runtime.deinit();
        const functions = [_]rt.FunctionFn{rt.stabilize(TestModule.root)};
        runtime.module_root_entries = &functions;
        runtime.configureModules(null, TestModule.lookup, TestModule.name);
        try rt.bindGlobalTable(&runtime, null, 0);
        try stdlib.install(&runtime);
        var failure = expected_error;
        var expander = Expander{
            .runtime = &runtime,
            .env_slot = 0,
            .string_slot = 18,
            .mw_slot = 23,
            .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists },
            .install_scribunto = Probe.install,
            .scribunto_shared = &failure,
        };
        try std.testing.expectError(expected_error, expander.expandFragment("Page", "A{{#invoke:Test|run|x=OK}}B", 1_670_803_200));
        try std.testing.expect(runtime.current_frame == null);
    }
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

test "edition title magic prevents Arabic wrapper recursion without shadowing templates" {
    const aliases = rt.namespace_registry.magic_words;
    const Source = struct {
        words: *const aliases.Registry,
        wrapper_calls: usize = 0,

        fn resolve(ctx: ?*anyopaque, name: []const u8, form: aliases.Form) anyerror!?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            return self.words.resolve(name, form);
        }

        fn get(ctx: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (std.mem.eql(u8, title, "قالب:مرجع:المحيط"))
                return "[https://archive.org/details/Talab1.comar/page/{{#if:{{{1|{{{page|{{{صفحة|{{{الصفحة|}}}}}}}}}}}}|n{{{1|{{{page|{{{صفحة|{{{الصفحة|}}}}}}}}}}}}|}} \"{{اسم_الصفحة}}\"] في [[w:القاموس المحيط|القاموس المحيط]] تأليف [[w:الفيروزآبادي|الفيروزآبادي]]\n<noinclude>[[تصنيف:قوالب مراجع عربية|قاموس المحيط]]</noinclude>";
            if (std.mem.eql(u8, title, "قالب:اسم الصفحة")) {
                self.wrapper_calls += 1;
                return "WRAPPER {{اسم_الصفحة}}";
            }
            if (std.mem.eql(u8, title, "قالب:pagename")) return "lowercase-template";
            if (std.mem.eql(u8, title, "قالب:PAGENAME")) return "english-template";
            if (std.mem.eql(u8, title, "Template:اسم الصفحة")) return "ordinary-template";
            if (std.mem.eql(u8, title, "قالب:Loop")) return "{{Loop}}";
            return null;
        }

        fn exists(_: ?*anyopaque, _: []const u8) !bool {
            return true;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var arabic = try rt.namespace_registry.Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tentries\n" ++
        "10\tقالب\tTemplate\tcase-sensitive\t1\t0\t0\t\tcompile_only\tinput\n" ++
        "14\tتصنيف\tCategory\tcase-sensitive\t0\t0\t0\t\tcompile_only\tinput\n");
    defer arabic.deinit();
    var arabic_words = try aliases.Registry.init(a, aliases.header ++ "\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\npagename\t1\tPAGENAME\npagename\t1\tاسم_الصفحة\n", "arwiktionary", "20261001", "ar");
    defer arabic_words.deinit();
    var english_words = try aliases.Registry.init(a, aliases.header ++ "\n# wiki\tenwiktionary\n# dump-date\t20261001\n# content-language\ten\npagename\t1\tPAGENAME\npagename\t1\tCOLLISION\nbasepagename\t1\tCOLLISION\n", "enwiktionary", "20261001", "en");
    defer english_words.deinit();
    var source: Source = .{ .words = &arabic_words };
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    runtime.namespace_catalog = &arabic;
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .ctx = &source, .get = Source.get, .exists = Source.exists, .resolve_title_magic = Source.resolve } };
    try std.testing.expectEqualStrings("تَرِزَ|آخر", try expander.expandFragment("تَرِزَ", "{{اسم_الصفحة}}|{{اسم_الصفحة:قالب:آخر}}", 1_670_803_200));
    try std.testing.expectEqual(@as(usize, 0), source.wrapper_calls);
    const citation = try expander.expandFragment("تَرِزَ", "{{مرجع:المحيط}}", 1_670_803_200);
    try std.testing.expect(std.mem.indexOf(u8, citation, "\"تَرِزَ\"") != null);
    try std.testing.expectEqual(@as(usize, 0), source.wrapper_calls);
    try std.testing.expectEqualStrings("WRAPPER Page|WRAPPER Page|lowercase-template|english-template", try expander.expandFragment("Page", "{{اسم_الصفحة|x}}|{{اسم الصفحة}}|{{pagename}}|{{PAGENAME|x}}", 1_670_803_200));
    try std.testing.expectEqual(@as(usize, 2), source.wrapper_calls);
    const args = try runtime.newTable();
    try args.rawSet(a, .{ .number = 1 }, .{ .string = "قالب:آخر" });
    try std.testing.expectEqualStrings("آخر", try Expander.hostFrameParserFunction(&expander, a, "اسم_الصفحة", args));
    expander.provider.interface_message = ordinaryLoopTestMessage;
    const loop = try expander.expandFragment("Page", "{{Loop}}", 1_670_803_200);
    try std.testing.expect(std.mem.indexOf(u8, loop, "<span class=\"error\">Fixture loop: ") != null);
    try std.testing.expectEqual(@as(usize, 0), expander.template_depth);
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    source.words = &english_words;
    try std.testing.expectEqualStrings("ordinary-template", try expander.expandFragment("Page", "{{اسم_الصفحة}}", 1_670_803_200));
    try std.testing.expectEqualStrings("Parent/Child|Parent", try expander.expandFragment("Template:Parent/Child", "{{COLLISION}}|{{COLLISION:Template:Parent/Child}}", 1_670_803_200));
    try args.rawSet(a, .{ .number = 1 }, .{ .string = "Template:Parent/Child" });
    try std.testing.expectEqualStrings("Parent", try Expander.hostFrameParserFunction(&expander, a, "COLLISION", args));
}

test "captured parser aliases expand lazy wrappers and native frame invokes" {
    const aliases = rt.namespace_registry.magic_words;
    const Source = struct {
        words: *const aliases.Registry,
        fn resolve(raw: ?*anyopaque, name: []const u8, form: aliases.Form) !?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.words.resolve(name, form);
        }
        fn parser(raw: ?*anyopaque, name: []const u8) !?[]const u8 {
            return resolve(raw, name, .parser_function);
        }
        fn get(raw: ?*anyopaque, a: std.mem.Allocator, title: []const u8) !?[]const u8 {
            if (std.mem.eql(u8, title, "Template:Alias"))
                return "{{#لو:{{{1|}}}|{{#استدعاء:Test|run|x={{{1}}}}}|{{Loop}}}}";
            return TestProvider.get(raw, a, title);
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var words = try aliases.Registry.init(a, aliases.parser_header ++ "\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
        "pagename\t1\tPAGENAME\nnamespace\t1\t名前空間\nns\t0\t名前空間:\nns\t0\tنط：\n" ++
        "if\t0\tلو\ninvoke\t0\tاستدعاء\ntag\t0\tوسم\ndisplaytitle\t1\tDISPLAYTITLE\n", "arwiktionary", "20261001", "ar");
    defer words.deinit();
    var source: Source = .{ .words = &words };
    var runtime = try rt.Context.initProgram(a, 24, 1);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{ rt.stabilize(TestModule.root), rt.stabilize(TestModule.run), rt.stabilize(TestModule.fail), rt.stabilize(TestModule.random), rt.stabilize(TestModule.stateful), rt.stabilize(TestModule.nested), rt.stabilize(TestModule.repair), rt.stabilize(TestModule.repairParent), rt.stabilizeBuffered(TestModule.multi), rt.stabilizeBuffered(TestModule.empty), rt.stabilizeBuffered(TestModule.nilReturn), rt.stabilizeBuffered(TestModule.numericReturn) };
    runtime.module_root_entries = &functions;
    runtime.configureModules(null, TestModule.lookup, TestModule.name);
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{
        .ctx = &source,
        .get = Source.get,
        .exists = TestProvider.exists,
        .resolve_title_magic = Source.resolve,
        .resolve_parser_function = Source.parser,
    }, .install_scribunto = installTestInvoke };
    try std.testing.expectEqualStrings("OK|Y|Template|Template", try expander.expandFragment("Page", "{{Alias|OK}}|{{#لو：yes|Y|{{Loop}}}}|{{نط：10}}|{{名前空間:Template:Child}}", 1_670_803_200));
    const invoke_args = try runtime.newTable();
    try invoke_args.rawSet(a, .{ .number = 1 }, .{ .string = "Test" });
    try invoke_args.rawSet(a, .{ .number = 2 }, .{ .string = "run" });
    try invoke_args.rawSet(a, .{ .string = "x" }, .{ .string = "FRAME" });
    try std.testing.expectEqualStrings("FRAME", try Expander.hostFrameParserFunction(&expander, a, "#استدعاء", invoke_args));
    try std.testing.expectError(error.UnsupportedParserFunction, Expander.hostFrameParserFunction(&expander, a, "displaytitle", invoke_args));
    try std.testing.expectError(error.UnsupportedParserFunction, Expander.hostFrameParserFunction(&expander, a, "#invoke", invoke_args));
    var english = try aliases.Registry.init(a, aliases.parser_header ++ "\n# wiki\tenwiktionary\n# dump-date\t20261001\n# content-language\ten\nif\t0\tif\ninvoke\t0\tinvoke\n", "enwiktionary", "20261001", "en");
    defer english.deinit();
    source.words = &english;
    try std.testing.expectEqualStrings("&#123;&#123;#لو:yes|Y|N&#125;&#125;", try expander.expandFragment("Page", "{{#لو:yes|Y|N}}", 1_670_803_200));
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

    expander.provider.interface_message = ordinaryLoopTestMessage;
    const loop = try expander.expandFragment("Page", "{{Loop}}", 1_670_803_200);
    try std.testing.expect(std.mem.indexOf(u8, loop, "<span class=\"error\">Fixture loop: ") != null);
    try std.testing.expectEqual(@as(usize, 0), expander.template_depth);
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

    // Exercise both real producer entry points, beyond transclusion alone.
    const comment_cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "outside<!--hide--><nowiki>A<!--D-->B</nowiki>tail", .expected = "outside<nowiki>A<!--D-->B</nowiki>tail" },
        .{ .source = "<nowiki title='>'>A<!--D-->B</nowiki>", .expected = "<nowiki title='>'>A<!--D-->B</nowiki>" },
        .{ .source = "<nowiki><nowiki>A<!--D--></nowiki><!--hide-->tail", .expected = "<nowiki><nowiki>A<!--D--></nowiki>tail" },
        .{ .source = "<nowiki/><!--hide-->tail", .expected = "<nowiki/>tail" },
        .{ .source = "<nowiki / ><!--hide-->tail", .expected = "<nowiki / >tail" },
        .{ .source = "<nowiki>A<!--D-->B", .expected = "<nowiki>AB" },
        .{ .source = "<nowiki><!--hide-->{{#if:x|expanded|wrong}}", .expected = "<nowiki>expanded" },
        .{ .source = "<nowiki><!--literal-->{{#if:x|expanded|wrong}}</nowiki>", .expected = "<nowiki><!--literal-->{{#if:x|expanded|wrong}}</nowiki>" },
        .{ .source = "< nowiki>{{#if:x|expanded|wrong}}</nowiki>", .expected = "< nowiki>expanded</nowiki>" },
        .{ .source = "<nowiki>{{#if:x|hidden|wrong}}</nowiki extra>{{#if:x|alsohidden|wrong}}</nowiki>{{#if:x|expanded|wrong}}", .expected = "<nowiki>{{#if:x|hidden|wrong}}</nowiki extra>{{#if:x|alsohidden|wrong}}</nowiki>expanded" },
        .{ .source = "<ref>A<!--D-->B</ref>", .expected = "<ref>AB</ref>" },
        .{ .source = "<pre title='>'>A<!--D-->&lt;b&gt;&amp;lt;[[B]]</pre><!--hide-->tail", .expected = "<pre title='>'>A<!--D-->&lt;b&gt;&amp;lt;[[B]]</pre>tail" },
        .{ .source = "<nowiki><span title=\"</nowiki>\">[[B]]<!--hide-->&lt;i&gt;", .expected = "<nowiki><span title=\"</nowiki>\">[[B]]&lt;i&gt;" },
        .{ .source = "<pre><span title=\"</pre>\">[[B]]<!--hide-->&lt;i&gt;", .expected = "<pre><span title=\"</pre>\">[[B]]&lt;i&gt;" },
        .{ .source = "A<pre>B<!--hidden-->&lt;i&gt;[[C]]", .expected = "A<pre>B&lt;i&gt;[[C]]" },
        .{ .source = "__NOEDIT<!--ordinary-->SECTION__A", .expected = "__NOEDITSECTION__A" },
        .{ .source = "<source lang=\"text\"><!--__NOEDITSECTION__-->&#95;&#95;NOEDITSECTION&#95;&#95;</source><!--outside-->tail", .expected = "<source lang=\"text\"><!--__NOEDITSECTION__-->&#95;&#95;NOEDITSECTION&#95;&#95;</source>tail" },
        .{ .source = "<syntaxhighlight lang='text'>\n<!--__NOEDITSECTION__-->\n{{T}} &amp;\n</syntaxhighlight><!--outside-->tail", .expected = "<syntaxhighlight lang='text'>\n<!--__NOEDITSECTION__-->\n{{T}} &amp;\n</syntaxhighlight>tail" },
        .{ .source = "<source>A<!--ordinary-->B", .expected = "<source>AB" },
        .{ .source = "<syntaxhighlight>A<!--ordinary-->B", .expected = "<syntaxhighlight>AB" },
        .{ .source = "<source/><!--ordinary-->tail", .expected = "<source/>tail" },
    };
    for (comment_cases) |case| {
        try std.testing.expectEqualStrings(case.expected, try expander.expandFragment("Page", case.source, 1_670_803_200));
        const comment_frame_args = try runtime.newTable();
        const comment_frame = try frame_lib.makeFrameFromTable(&runtime, "Module:Probe", comment_frame_args, null);
        const comment_preprocess = try runtime.getIndex(comment_frame, .{ .string = "preprocess" });
        const comment_result = try runtime.callValue(comment_preprocess, &.{ comment_frame, .{ .string = case.source } });
        defer rt.freeResults(comment_result);
        try std.testing.expectEqualStrings(case.expected, comment_result[0].string);
    }
}

test "ordinary template arguments inside frame preprocess remain charged" {
    const Source = struct {
        var now: u64 = 0;
        fn clock() error{LuaCpuClockUnavailable}!u64 {
            return now;
        }
        fn get(_: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
            if (std.mem.eql(u8, title, "Template:Tick")) {
                now += 5;
                return "expanded";
            }
            return null;
        }
    };
    Source.now = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.init(a, 0);
    defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 0, .mw_slot = 0, .provider = .{ .get = Source.get, .get_transclusion = Source.get, .exists = TestProvider.exists } };
    const caller = try runtime.newTable();
    const args = try expander.buildTemplateArgs(&.{"{{Tick}}"}, caller, "Page", 0);
    var budget: rt.execution_budget.Budget = .{ .limit_ns = 100, .clock = Source.clock };
    var scope = try budget.enter();
    const got = try Expander.hostFramePreprocess(&expander, a, "{{{1}}}", "Template:T", args);
    try scope.finish();
    try std.testing.expectEqualStrings("expanded", got);
    try std.testing.expectEqual(@as(u64, 5), budget.used_ns);
}

test "named invoke and forwarded template values trim after expansion" {
    const Source = struct {
        fn get(raw: ?*anyopaque, a: std.mem.Allocator, title: []const u8) !?[]const u8 {
            if (std.mem.eql(u8, title, "Template:NamedInvoke"))
                return "{{#invoke:Test|run|x={{{1}}}}}";
            return TestProvider.get(raw, a, title);
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 24, 1);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{ rt.stabilize(TestModule.root), rt.stabilize(TestModule.run), rt.stabilize(TestModule.fail), rt.stabilize(TestModule.random), rt.stabilize(TestModule.stateful), rt.stabilize(TestModule.nested), rt.stabilize(TestModule.repair), rt.stabilize(TestModule.repairParent), rt.stabilizeBuffered(TestModule.multi), rt.stabilizeBuffered(TestModule.empty), rt.stabilizeBuffered(TestModule.nilReturn), rt.stabilizeBuffered(TestModule.numericReturn) };
    runtime.module_root_entries = &functions;
    runtime.configureModules(null, TestModule.lookup, TestModule.name);
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = Source.get, .exists = TestProvider.exists }, .install_scribunto = installTestInvoke };
    // The named #invoke value is the same forwarding shape as wikidata={{{1}}}.
    // The lazy named template value also trims, while the unnamed value stays padded.
    const got = try expander.expandFragment("Page", "{{NamedInvoke|L1486313 }}|{{LazyForward| L1486313 |{{Loop}}}}|{{Hello| L1486313 }}", 1_670_803_200);
    try std.testing.expectEqualStrings("L1486313|used=L1486313|Hi  L1486313  N", got);
}

test "argument post-expansion trim preserves unnamed values and last assignment provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.init(a, 0);
    defer runtime.deinit();
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 0, .mw_slot = 0, .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists } };
    const caller = try runtime.newTable();
    const padded = "\x00\x0b \tL1486313 \r\n\x00\x0b";
    try caller.rawSet(a, .{ .number = 1 }, .{ .string = padded });
    try caller.rawSet(a, .{ .number = 2 }, .{ .string = "\xc2\xa0inner\xc2\xa0" });
    const named_wins = [_][]const u8{ "{{{1}}}", "1={{{1}}}", "wikidata={{{1}}}", "unicode={{{2}}}" };
    const unnamed_wins = [_][]const u8{ "1={{{1}}}", "{{{1}}}", "wikidata={{{1}}}" };
    inline for (.{ false, true }) |lazy| {
        const named = if (lazy)
            try expander.buildTemplateArgs(&named_wins, caller, "Page", 0)
        else
            try expander.buildExpandedArgs(&named_wins, caller, "Page", 0);
        if (lazy) try expander.materializeLazyTemplateArgs(named);
        try std.testing.expectEqualStrings("L1486313", named.rawGet(.{ .number = 1 }).?.string);
        try std.testing.expectEqualStrings("L1486313", named.rawGet(.{ .string = "wikidata" }).?.string);
        try std.testing.expectEqualStrings("\xc2\xa0inner\xc2\xa0", named.rawGet(.{ .string = "unicode" }).?.string);
        const unnamed = if (lazy)
            try expander.buildTemplateArgs(&unnamed_wins, caller, "Page", 0)
        else
            try expander.buildExpandedArgs(&unnamed_wins, caller, "Page", 0);
        if (lazy) try expander.materializeLazyTemplateArgs(unnamed);
        try std.testing.expectEqualStrings(padded, unnamed.rawGet(.{ .number = 1 }).?.string);
        try std.testing.expectEqualStrings("L1486313", unnamed.rawGet(.{ .string = "wikidata" }).?.string);
        if (lazy) {
            try caller.rawSet(a, .{ .number = 1 }, .{ .string = "changed" });
            try std.testing.expectEqualStrings("L1486313", try expander.expandParameter("wikidata", named, "Page", 0));
            try caller.rawSet(a, .{ .number = 1 }, .{ .string = padded });
        }
    }
}

test "Phonos validates authoritative media and preserves label language and canonical file" {
    const Source = struct {
        fn file(_: ?*anyopaque, title: []const u8) !Provider.FileMetadata {
            if (std.mem.eql(u8, title, "File:Alias.ogg"))
                return .{ .exists = true, .media_type = .AUDIO, .canonical_title = "File:Actual audio.opus" };
            if (std.mem.eql(u8, title, "File:Video.ogg"))
                return .{ .exists = true, .media_type = .VIDEO, .canonical_title = title };
            if (std.mem.eql(u8, title, "File:Absent.ogg")) return .{ .exists = false };
            if (std.mem.eql(u8, title, "File:Legacy.ogg")) return .{ .exists = true };
            return error.FileMetadataSnapshotMissing;
        }
        fn message(_: ?*anyopaque, _: std.mem.Allocator, language: []const u8, key: []const u8) !?Provider.InterfaceMessage {
            try std.testing.expectEqualStrings("en", language);
            if (std.mem.eql(u8, key, "phonos-player-aria-description")) return .{ .source = "Play captured audio" };
            if (std.mem.eql(u8, key, "phonos-aria-error")) return .{ .source = "Captured unable to play audio" };
            return null;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 24);
    defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var expander = Expander{
        .runtime = &runtime,
        .env_slot = 0,
        .string_slot = 18,
        .mw_slot = 23,
        .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists, .file_metadata = Source.file, .interface_message = Source.message },
    };
    const good = try expander.expandFragment("Entry", "{{#tag:phonos|<span class=\"e-example\">Dengerin</span>|file=Alias.ogg|lang=id|wikibase=Q1|label=IGNORED}}", 1_670_803_200);
    try std.testing.expect(std.mem.indexOf(u8, good, "data-phonos-audio=\"Actual audio.opus\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, good, "lang=\"id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, good, "<span class=\"e-example\">Dengerin</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, good, "IGNORED") == null);
    const prefixed = try expander.expandFragment("Entry", "{{#tag:phonos|Prefix|file=Image:Alias.ogg}}", 1_670_803_200);
    try std.testing.expect(std.mem.indexOf(u8, prefixed, "data-phonos-audio=\"Actual audio.opus\"") != null);
    // The pinned CA audio templates use file="{{{1}}}" in #tag:phonos.
    const quoted_file = try expander.expandFragment("Entry", "{{#tag:phonos|CA label|file= \"{{#if:yes|Alias.ogg}}\" }}", 1_670_803_200);
    try std.testing.expect(std.mem.indexOf(u8, quoted_file, "data-phonos-audio=\"Actual audio.opus\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, quoted_file, "CA label") != null);
    const empty_label = try expander.expandFragment("Entry", "{{#tag:phonos||file=Alias.ogg}}", 1_670_803_200);
    try std.testing.expect(std.mem.indexOf(u8, empty_label, "Play captured audio") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty_label, "lang=\"en\"") != null);
    const invalid_cases = [_]struct { source: []const u8, key: []const u8 }{
        .{ .source = "{{#tag:phonos|Keep|file=Video.ogg}}", .key = "phonos-file-not-audio" },
        .{ .source = "{{#tag:phonos|Keep|file=Absent.ogg}}", .key = "phonos-file-not-found" },
        .{ .source = "{{#tag:phonos|Keep|file=[invalid]}}", .key = "phonos-invalid-title" },
        .{ .source = "{{#tag:phonos|Keep}}", .key = "phonos-param-error" },
        .{ .source = "{{#tag:phonos|Keep|file=0|ipa=0|wikibase=0}}", .key = "phonos-param-error" },
        .{ .source = "{{#tag:phonos|Keep|file=   }}", .key = "phonos-param-error" },
    };
    for (invalid_cases) |case| {
        const result = try expander.expandFragment("Entry", case.source, 1_670_803_200);
        try std.testing.expect(std.mem.indexOf(u8, result, case.key) != null);
        try std.testing.expect(std.mem.indexOf(u8, result, "Keep Captured unable to play audio") != null);
        try std.testing.expect(std.mem.indexOf(u8, result, "data-phonos-audio=") == null);
    }
    try std.testing.expectError(error.FileMetadataSnapshotMissing, expander.expandFragment("Entry", "{{#tag:phonos|Keep|file=Unknown.ogg}}", 1_670_803_200));
    try std.testing.expectError(error.FileMetadataMediaTypeMissing, expander.expandFragment("Entry", "{{#tag:phonos|Keep|file=Legacy.ogg}}", 1_670_803_200));
    try std.testing.expectError(error.PhonosWikibaseUnsupported, expander.expandFragment("Entry", "{{#tag:phonos|Keep|wikibase=Q1}}", 1_670_803_200));
    try std.testing.expectError(error.PhonosIpaGenerationUnsupported, expander.expandFragment("Entry", "{{#tag:phonos|Keep|ipa=a}}", 1_670_803_200));
    const long_ipa = try std.fmt.allocPrint(arena.allocator(), "{{{{#tag:phonos|Keep|file=Alias.ogg|ipa={s}}}}}", .{@as([301]u8, @splat('a'))});
    const too_long = try expander.expandFragment("Entry", long_ipa, 1_670_803_200);
    try std.testing.expect(std.mem.indexOf(u8, too_long, "phonos-ipa-too-long") != null);
    const attrs = try runtime.newTable();
    try attrs.rawSet(runtime.allocator, .{ .string = "file" }, .{ .string = "Alias.ogg" });
    const frame = try Expander.hostFrameExtensionTag(&expander, runtime.allocator, "phonos", .{ .string = "Frame" }, attrs);
    try std.testing.expect(std.mem.indexOf(u8, frame, "data-phonos-audio=\"Actual audio.opus\"") != null);
    expander.provider.file_metadata = null;
    try std.testing.expectError(error.FileMetadataSnapshotMissing, expander.expandFragment("Entry", "{{#tag:phonos|Keep|file=LL-Q9240 (ind)-Sofi Solihah-sistem.wav}}", 1_670_803_200));
}

test "implicit block newlines retain Belarusian legacy translation terms" {
    // Reduced from pinned table-top p2281/r8655, table-mid and table-bot
    // p2283/r6011 plus legacy p14036/r57611. table-top/mid end in "{|":
    // each following #if must start its nonempty list result on a new line.
    const Source = struct {
        fn get(_: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
            if (std.mem.eql(u8, title, "Template:Top"))
                return "{| border=\"0\" width=\"100%\"\n|-\n| valign=\"top\" width=\"48%\" |\n{|";
            if (std.mem.eql(u8, title, "Template:Mid"))
                return "|}\n| width=\"1%\" |\n| valign=\"top\" width=\"48%\" |\n{|";
            if (std.mem.eql(u8, title, "Template:Bot")) return "|}\n|}";
            if (std.mem.eql(u8, title, "Template:T")) return "[[{{{2}}}]]";
            if (std.mem.eql(u8, title, "Template:Legacy"))
                return "<div class=\"NavFrame\"><div class=\"NavContent\">\n" ++
                    "{{Top}}{{#if:{{{af|}}}|* af: {{{af}}}}}" ++
                    "{{#if:{{{ca|}}}|* ca: {{{ca}}}}}" ++
                    "{{#if:{{{chr|}}}|* chr: {{{chr}}}}}" ++
                    "{{#if:{{{da|}}}|* da: {{{da}}}}}" ++
                    "{{#if:{{{en|}}}|* en: {{{en}}}}}\n" ++
                    "{{Mid}}{{#if:{{{ru|}}}|* ru: {{{ru}}}}}\n{{Bot}}</div></div>";
            return null;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var expander = Expander{
        .runtime = &runtime,
        .env_slot = 0,
        .string_slot = 18,
        .mw_slot = 23,
        .provider = .{ .get = Source.get, .exists = TestProvider.exists },
    };
    const cases = [_]struct { title: []const u8, call: []const u8, expected: []const u8 }{
        .{ .title = "aduh", .call = "{{Legacy|ru=[[увы]], [[ах]]}}", .expected = "{|\n* ru: [[увы]], [[ах]]" },
        .{ .title = "АМАП", .call = "{{Legacy|ru=[[ОМОН]]}}", .expected = "{|\n* ru: [[ОМОН]]" },
        .{ .title = "Аўстралія", .call = "{{Legacy|af={{T|af|Australië}}|da={{T|da|Australien}}|en={{T|en|Australia}}}}", .expected = "{|\n* af: [[Australië]]\n* da: [[Australien]]\n* en: [[Australia]]" },
        .{ .title = "Беларусь", .call = "{{Legacy|ca={{T|ca|Bielorússia}}|chr={{T|chr|ᏇᎳᎷᏒ}}|da={{T|da|Hviderusland}}}}", .expected = "{|\n* ca: [[Bielorússia]]\n* chr: [[ᏇᎳᎷᏒ]]\n* da: [[Hviderusland]]" },
    };
    for (cases) |case| {
        const expanded = try expander.expandFragment(case.title, case.call, 1_670_803_200);
        try std.testing.expect(std.mem.indexOf(u8, expanded, case.expected) != null);
        try std.testing.expect(std.mem.indexOf(u8, expanded, "{|*") == null);
    }
    // Source-line state is independent of whether the previous result is empty.
    try std.testing.expectEqualStrings("x\n* item", try expander.expandFragment("Page", "x{{#if:1|* item}}", 1_670_803_200));
    try std.testing.expectEqualStrings("x\n* item", try expander.expandFragment("Page", "x\n{{#if:1|* item}}", 1_670_803_200));
    try std.testing.expectEqualStrings("\n* item", try expander.expandFragment("Page", "{{#if:1|* item}}", 1_670_803_200));
    try std.testing.expectEqualStrings("x* item", try expander.expandFragment("Page", "x{{{missing|* item}}}", 1_670_803_200));
    try std.testing.expectEqualStrings("x {| not a leading table", try expander.expandFragment("Page", "x{{{missing| {| not a leading table}}}", 1_670_803_200));
    const table_result = try expander.expandFragment("Page", "x{{Top}}", 1_670_803_200);
    try std.testing.expect(std.mem.startsWith(u8, table_result, "x\n{| border="));
    try std.testing.expectEqualStrings("x\n; term", try expander.expandFragment("Page", "x{{#if:1|; term}}", 1_670_803_200));
    try std.testing.expectEqualStrings("x\n: detail", try expander.expandFragment("Page", "x{{#if:1|: detail}}", 1_670_803_200));
    try std.testing.expectEqualStrings("x\n# ordered", try expander.expandFragment("Page", "x{{#if:1|# ordered}}", 1_670_803_200));
    try std.testing.expectEqualStrings("xordinary", try expander.expandFragment("Page", "x{{#if:1|ordinary}}", 1_670_803_200));
}

test "tag parser attribute syntax is separate from literal frame extension attributes" {
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
    };
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "{{#tag:ref|body|name=  \"n\"  }}", .expected = "<ref name=\"n\">body</ref>" },
        .{ .source = "{{#tag:ref|body|name='n'}}", .expected = "<ref name=\"n\">body</ref>" },
        .{ .source = "{{#tag:ref|body|name=\"n'}}", .expected = "<ref name=\"n\">body</ref>" },
        .{ .source = "{{#tag:ref|body|name=\"\"}}", .expected = "<ref name=\"\">body</ref>" },
        .{ .source = "{{#tag:ref|body|name=''}}", .expected = "<ref name=\"\">body</ref>" },
        .{ .source = "{{#tag:ref|body|name=\"'}}", .expected = "<ref name=\"&quot;'\">body</ref>" },
        .{ .source = "{{#tag:ref|body|name= \" n \" }}", .expected = "<ref name=\" n \">body</ref>" },
        .{ .source = "{{#tag:ref|body|name=\"n}}", .expected = "<ref name=\"&quot;n\">body</ref>" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.expected, try expander.expandFragment("Page", case.source, 1_670_803_200));
    // PHP trim removes NUL/vertical-tab, not form-feed or nonbreaking space.
    try std.testing.expectEqualStrings("n", parserTagAttributeValue("\x00\x0b\"n\"\x00\x0b"));
    try std.testing.expectEqualStrings("\x0c\"n\"\x0c", parserTagAttributeValue("\x0c\"n\"\x0c"));
    try std.testing.expectEqualStrings("\xc2\xa0\"n\"\xc2\xa0", parserTagAttributeValue("\xc2\xa0\"n\"\xc2\xa0"));

    expander.beginPage("Page", "source", 1_670_803_200);
    const named = try runtime.newTable();
    try named.rawSet(runtime.allocator, .{ .number = 1 }, .{ .string = "body" });
    try named.rawSet(runtime.allocator, .{ .string = "name" }, .{ .string = " \"n\" " });
    try std.testing.expectEqualStrings("<ref name=\"n\">body</ref>", try expander.frameParserTag(&expander, runtime.allocator, "#tag:ref", named));
    const positional = try runtime.newTable();
    try positional.rawSet(runtime.allocator, .{ .number = 1 }, .{ .string = "ref" });
    try positional.rawSet(runtime.allocator, .{ .number = 2 }, .{ .string = "body" });
    try positional.rawSet(runtime.allocator, .{ .number = 3 }, .{ .string = "name='n'" });
    try std.testing.expectEqualStrings("<ref name=\"n\">body</ref>", try expander.frameParserTag(&expander, runtime.allocator, "#tag", positional));

    const literal = try runtime.newTable();
    try literal.rawSet(runtime.allocator, .{ .string = "name" }, .{ .string = " \"n\" " });
    try std.testing.expectEqualStrings("<ref name=\" &quot;n&quot; \">body</ref>", try Expander.hostFrameExtensionTag(&expander, runtime.allocator, "ref", .{ .string = "body" }, literal));
}

test "attached captured site statistics satisfy the pinned BCL random same seed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    const mw = try runtime.newNativeNamespace(.mw);
    try message_lib.install(&runtime, mw);
    var expander = Expander{
        .runtime = &runtime,
        .env_slot = 0,
        .string_slot = 0,
        .mw_slot = 0,
        .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists, .stable_page_reads = true, .site_statistics = .{ 13332, 8530, 0, 60889, 1596, 14, 2 } },
    };
    expander.attach();
    const site = mw.rawGet(.{ .string = "site" }).?.table;
    const stats = site.rawGet(.{ .string = "stats" }).?;
    // Module:random p539/r39971 line269: views-or-0 + these seven counters.
    // The upstream SiteLibrary contract does not contain a views field.
    try std.testing.expect((try runtime.getIndex(stats, .{ .string = "views" })) == .nil);
    var seed: f64 = 0;
    inline for (.{ "pages", "articles", "files", "edits", "users", "activeUsers", "admins" }) |name|
        seed += (try runtime.getIndex(stats, .{ .string = name })).number;
    try std.testing.expectEqual(@as(f64, 84363), seed);
    try std.testing.expectEqual(@as(f64, 0), (try runtime.getIndex(stats, .{ .string = "files" })).number);
    expander.provider.site_statistics = null;
    expander.attach();
    try std.testing.expectError(error.AotCallFailed, runtime.getIndex(stats, .{ .string = "pages" }));
    try std.testing.expectEqualStrings("LuaRaised", runtime.aotErrorName().?);
    try std.testing.expectEqualStrings("Site statistics snapshot missing field=pages", runtime.last_error.string);
}

test "expander attachment preserves absent legacy Wikibase providers and exact missing keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    const mw = try runtime.newNativeNamespace(.mw);
    try message_lib.install(&runtime, mw);
    var expander = Expander{
        .runtime = &runtime,
        .env_slot = 0,
        .string_slot = 0,
        .mw_slot = 0,
        .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists, .stable_page_reads = true },
    };
    expander.attach();
    try std.testing.expect(expander.host.wikibase_sitelink == null);
    try std.testing.expect(expander.host.wikibase_entity_text == null);
    const wikibase = mw.rawGet(.{ .string = "wikibase" }).?.table;
    inline for (.{ "sitelink", "getSitelink" }) |name| {
        runtime.clearAotErrorName();
        const callable = try runtime.getIndex(.{ .table = wikibase }, .{ .string = name });
        try std.testing.expectError(error.AotCallFailed, runtime.callValue(callable, &.{
            .{ .string = "Q34057" }, .{ .string = "enwiki" },
        }));
        try std.testing.expectEqualStrings("LuaRaised", runtime.aotErrorName().?);
        try std.testing.expectEqualStrings("Wikibase sitelink snapshot missing entity=Q34057 site=enwiki", runtime.last_error.string);
    }
    inline for (.{ "getLabel", "getDescription" }) |name| {
        runtime.clearAotErrorName();
        const callable = try runtime.getIndex(.{ .table = wikibase }, .{ .string = name });
        try std.testing.expectError(error.AotCallFailed, runtime.callValue(callable, &.{.{ .string = "Q34057" }}));
        try std.testing.expectEqualStrings("LuaRaised", runtime.aotErrorName().?);
        try std.testing.expectEqualStrings("Wikibase entity-text snapshot missing entity=Q34057", runtime.last_error.string);
    }

    const Probe = struct {
        fn sitelink(raw: ?*anyopaque, _: []const u8, _: []const u8) anyerror!?[]const u8 {
            const fail: *bool = @ptrCast(@alignCast(raw.?));
            if (fail.*) return error.OutOfMemory;
            return null; // Explicit captured negative remains distinct from absent provider.
        }
        fn text(raw: ?*anyopaque, _: []const u8) anyerror!host_api.WikibaseEntityText {
            const fail: *bool = @ptrCast(@alignCast(raw.?));
            if (fail.*) return error.AccessDenied;
            return .{ .label = "captured", .description = null };
        }
    };
    var fail = false;
    expander.provider.ctx = &fail;
    expander.provider.wikibase_sitelink = Probe.sitelink;
    expander.provider.wikibase_entity_text = Probe.text;
    expander.attach();
    const link = expander.host.wikibase_sitelink.?;
    const text = expander.host.wikibase_entity_text.?;
    try std.testing.expect((try link(expander.host.ctx, "Q34057", "enwiki")) == null);
    try std.testing.expectEqualStrings("captured", (try text(expander.host.ctx, "Q34057")).label.?);
    fail = true;
    try std.testing.expectError(error.OutOfMemory, link(expander.host.ctx, "Q34057", "enwiki"));
    try std.testing.expectError(error.AccessDenied, text(expander.host.ctx, "Q34057"));
    expander.provider.wikibase_sitelink = null;
    expander.provider.wikibase_entity_text = null;
    expander.attach();
    try std.testing.expect(expander.host.wikibase_sitelink == null and expander.host.wikibase_entity_text == null);
}

test "date numbering attachment forwards captured identity errors and provider removal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    var expander = Expander{
        .runtime = &runtime,
        .env_slot = 0,
        .string_slot = 0,
        .mw_slot = 0,
        .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists, .stable_page_reads = true },
    };
    expander.attach();
    try std.testing.expect(expander.host.date_numbering == null);
    const Probe = struct {
        fn numbering(raw: ?*anyopaque, code: []const u8) anyerror!host_api.DateNumbering {
            const calls: *usize = @ptrCast(@alignCast(raw.?));
            calls.* += 1;
            if (std.mem.eql(u8, code, "unsupported")) return error.DateNumberingUnsupported;
            if (!std.mem.eql(u8, code, "bn")) return error.DateNumberingSnapshotMissing;
            return .{ .digits = .{ "০", "১", "২", "৩", "৪", "৫", "৬", "৭", "৮", "৯" }, .timezone = "Asia/Dhaka" };
        }
    };
    var calls: usize = 0;
    expander.provider.ctx = &calls;
    expander.provider.date_numbering = Probe.numbering;
    expander.attach();
    const lookup = expander.host.date_numbering.?;
    const profile = try lookup(expander.host.ctx, "bn");
    try std.testing.expectEqualStrings("০", profile.digits[0]);
    try std.testing.expectEqualStrings("Asia/Dhaka", profile.timezone);
    try std.testing.expectError(error.DateNumberingUnsupported, lookup(expander.host.ctx, "unsupported"));
    try std.testing.expectError(error.DateNumberingSnapshotMissing, lookup(expander.host.ctx, "en"));
    try std.testing.expectEqual(@as(usize, 3), calls);
    expander.provider.date_numbering = null;
    expander.attach();
    try std.testing.expect(expander.host.date_numbering == null);
    try std.testing.expectError(error.DateNumberingSnapshotMissing, lookup(expander.host.ctx, "bn"));
}

test "expired script message distinguishes captured values from missing snapshot input" {
    const State = enum { value, empty, missing, absent, failure };
    const Messages = struct {
        state: State = .value,
        fn lookup(raw: ?*anyopaque, _: std.mem.Allocator, language: []const u8, key: []const u8) anyerror!?Provider.InterfaceMessage {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try std.testing.expectEqualStrings("en", language);
            try std.testing.expectEqualStrings("scribunto-common-timeout", key);
            return switch (self.state) {
                .value => .{ .source = "captured <limit> & detail" },
                .empty => .{ .source = "" },
                .missing => .{ .source = null },
                .absent => null,
                .failure => error.InterfaceMessageSnapshotMissing,
            };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    var messages: Messages = .{};
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .ctx = &messages, .get = TestProvider.get, .exists = TestProvider.exists, .interface_message = Messages.lookup } };
    const invoke_args = try runtime.newTable();
    // Exercise the real invoke recovery branch without spending ten seconds of CPU.
    expander.script_cpu_budget.expired = true;
    const text = try expander.invokeWithRecovery(null, "Module:Probe", "run", invoke_args, null, null, null);
    try std.testing.expectEqualStrings("<strong class=\"error\"><span class=\"scribunto-error\">Lua error in Module:Probe: captured &lt;limit&gt; &amp; detail</span></strong>", text.error_markup);
    messages.state = .empty;
    const empty = try expander.invokeWithRecovery(null, "Module:Probe", "run", invoke_args, null, null, null);
    try std.testing.expectEqualStrings("<strong class=\"error\"><span class=\"scribunto-error\">Lua error in Module:Probe: </span></strong>", empty.error_markup);
    messages.state = .missing;
    try std.testing.expectError(error.UnsupportedScriptTimeoutMessage, expander.invokeWithRecovery(null, "Module:Probe", "run", invoke_args, null, null, null));
    for ([_]State{ .absent, .failure }) |state| {
        messages.state = state;
        try std.testing.expectError(error.InterfaceMessageSnapshotMissing, expander.invokeWithRecovery(null, "Module:Probe", "run", invoke_args, null, null, null));
    }
    expander.provider.interface_message = null;
    try std.testing.expectError(error.InterfaceMessageSnapshotMissing, expander.invokeWithRecovery(null, "Module:Probe", "run", invoke_args, null, null, null));
}

test "int parser uses captured aliases and messages with child-frame expansion" {
    const aliases = rt.namespace_registry.magic_words;
    const Source = struct {
        words: *const aliases.Registry,
        fn parser(raw: ?*anyopaque, name: []const u8) !?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.words.resolve(name, .parser_function);
        }
        fn get(_: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
            if (std.mem.eql(u8, title, "MediaWiki:Local")) return "local $1";
            return null;
        }
        fn exists(_: ?*anyopaque, _: []const u8) !bool {
            return false;
        }
        fn message(_: ?*anyopaque, _: std.mem.Allocator, language: []const u8, key: []const u8) !?Provider.InterfaceMessage {
            try std.testing.expectEqualStrings("bg", language);
            if (std.mem.eql(u8, key, "lang")) return .{ .source = "bg" };
            if (std.mem.eql(u8, key, "format")) return .{ .source = "$1/$2|{{{1|none}}}|{{{x|none}}}" };
            if (std.mem.eql(u8, key, "nested")) return .{ .source = "{{#if:1|expanded|wrong}}" };
            if (std.mem.eql(u8, key, "known-absent")) return .{ .source = null };
            if (std.mem.eql(u8, key, "known-empty")) return .{ .source = "" };
            return null;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var catalog = try rt.namespace_registry.Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tbgwiktionary\n# dump-date\t20261001\n# content-language\tbg\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tentries\n" ++
        "8\tMediaWiki\tMediaWiki\tcase-sensitive\t0\t0\t0\t\tcompile_only\tinput\n" ++
        "10\tШаблон\tTemplate\tcase-sensitive\t1\t0\t0\t\tcompile_only\tinput\n" ++
        "14\tКатегория\tCategory\tcase-sensitive\t0\t0\t0\t\tcompile_only\tinput\n");
    defer catalog.deinit();
    var words = try aliases.Registry.init(a, aliases.parser_header ++
        "\n# wiki\tbgwiktionary\n# dump-date\t20261001\n# content-language\tbg\n" ++
        "int\t0\tINT:\nint\t0\tВЪТР:\nif\t0\tif\n", "bgwiktionary", "20261001", "bg");
    defer words.deinit();
    var source: Source = .{ .words = &words };
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    runtime.namespace_catalog = &catalog;
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .ctx = &source, .get = Source.get, .exists = Source.exists, .resolve_parser_function = Source.parser, .interface_message = Source.message } };
    try std.testing.expectEqualStrings("bg|bg", try expander.expandFragment("natuurlijks", "{{int:lang}}|{{вътр:lang}}", 1_670_803_200));
    try std.testing.expectEqualStrings("hi/x=there| hi |there", try expander.expandFragment("Page", "{{int:format| hi | x=there }}", 1_670_803_200));
    try std.testing.expectEqualStrings("expanded", try expander.expandFragment("Page", "{{int:nested}}", 1_670_803_200));
    try std.testing.expectEqualStrings("local value", try expander.expandFragment("Page", "{{int:local|value}}", 1_670_803_200));
    try std.testing.expectEqualStrings("⧼known-absent⧽", try expander.expandFragment("Page", "{{int:known-absent}}", 1_670_803_200));
    try std.testing.expectEqualStrings("AB", try expander.expandFragment("Page", "A{{int:known-empty}}B", 1_670_803_200));
    try std.testing.expectError(error.InterfaceMessageSnapshotMissing, expander.expandFragment("Page", "{{int:uncaptured}}", 1_670_803_200));
    try std.testing.expectEqualStrings("<nowiki>{{</nowiki>int:<nowiki>}}</nowiki>", try expander.expandFragment("Page", "{{int:}}", 1_670_803_200));
}

// A native test module reproduces the captured legal string.sub call using the
// actual mw.ustring.sub API. It is not an alternate parser or heading cleanup.
const LanguageParserTestModule = struct {
    fn lookup(_: ?*const anyopaque, raw_name: []const u8) ?u32 {
        return if (std.mem.eql(u8, raw_name, "Module:string")) 0 else null;
    }
    fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
        return if (id == 0) "Module:string" else null;
    }
    fn root(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        const exports = try ctx.newTable();
        try exports.rawSet(ctx.allocator, .{ .string = "sub" }, try ctx.makeFunctionKnown(1, sub, &.{}));
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .table = exports };
        return out;
    }
    fn sub(ctx: *rt.Context, _: rt.Captures, values: []const Value) ![]const Value {
        if (values.len == 0 or values[0] != .table) return error.FrameExpected;
        const args = try ctx.getIndex(values[0], .{ .string = "args" });
        const source = try ctx.getIndex(args, .{ .number = 1 });
        const first = try ctx.getIndex(args, .{ .number = 2 });
        if (source != .string or first != .string) return error.StringExpected;
        const index = try std.fmt.parseFloat(f64, first.string);
        const mw = ctx.getGlobal(23);
        const ustring = try ctx.getIndex(mw, .{ .string = "ustring" });
        const callable = try ctx.getIndex(ustring, .{ .string = "sub" });
        return ctx.callValue(callable, &.{ source, .{ .number = index } });
    }
};

const LanguageParserTestSource = struct {
    words: *const rt.namespace_registry.magic_words.Registry,
    fn parser(raw: ?*anyopaque, alias: []const u8) !?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        return self.words.resolve(alias, .parser_function);
    }
    fn get(_: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
        // Frozen Template:ل revision1072084 (4f04b777), and the include-only
        // body of Template:اللغة revision1048305 (e45750b7).
        if (std.mem.eql(u8, title, "Template:ل"))
            return "== {{اللغة|{{#invoke:string|sub|{{#language:{{{1|}}}|ar}}|3}}}} ==";
        if (std.mem.eql(u8, title, "Template:اللغة"))
            return "{{{1}}}<includeonly>[[تصنيف:{{{1}}}]]</includeonly><noinclude>{{توثيق}}[[تصنيف:قوالب تصنيفات علمية]]\n</noinclude>";
        if (std.mem.eql(u8, title, "Template:Code")) return " EN ";
        if (std.mem.eql(u8, title, "Template:Display")) return " AR ";
        if (std.mem.eql(u8, title, "Template:NestedLanguage")) return "{{#language:{{{1|}}}|{{{2|}}}}}";
        return null;
    }
    fn languageName(_: ?*anyopaque, code: []const u8, display: ?[]const u8) ![]const u8 {
        if (std.mem.eql(u8, code, "oom")) return error.OutOfMemory;
        if (std.mem.eql(u8, code, "denied")) return error.AccessDenied;
        if (display) |shown| {
            if (std.mem.eql(u8, shown, "ar")) {
                if (std.mem.eql(u8, code, "en")) return "الإنجليزية";
                if (std.mem.eql(u8, code, "ar")) return "العربية";
            } else if (std.mem.eql(u8, shown, "fr")) {
                if (std.mem.eql(u8, code, "en")) return "anglais";
            } else return error.LanguageNameSnapshotMissing;
        } else {
            if (std.mem.eql(u8, code, "en")) return "English";
            if (std.mem.eql(u8, code, "ar")) return "العربية";
            if (std.mem.eql(u8, code, "de")) return "Deutsch";
        }
        return "";
    }
};

// Includes nested parameter expansion, actual captured hash aliases, and a
// Unicode substring from the complete language name rather than a literal
// fallback wrapper. The fixtures are scoped test data, not production names.
test "language parser expands defaults autonyms nested arguments and the frozen Arabic template chain" {
    const aliases = rt.namespace_registry.magic_words;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var words = try aliases.Registry.init(a, aliases.parser_header ++ "\n# wiki\tenwiktionary\n# dump-date\t20261001\n# content-language\ten\n" ++
        "language\t0\t#لغة\nlanguage\t0\t#LANGUAGE\ninvoke\t0\tinvoke\n", "enwiktionary", "20261001", "en");
    defer words.deinit();
    var source: LanguageParserTestSource = .{ .words = &words };
    var runtime = try rt.Context.initProgram(a, 24, 1);
    defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    const functions = [_]rt.FunctionFn{ rt.stabilize(LanguageParserTestModule.root), rt.stabilize(LanguageParserTestModule.sub) };
    runtime.module_root_entries = &functions;
    runtime.configureModules(null, LanguageParserTestModule.lookup, LanguageParserTestModule.name);
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .ctx = &source, .get = LanguageParserTestSource.get, .exists = TestProvider.exists, .language_name = LanguageParserTestSource.languageName, .resolve_parser_function = LanguageParserTestSource.parser }, .install_scribunto = installTestInvoke };
    const cases = [_][2][]const u8{
        .{ "{{#language:}}", "English" },
        .{ "{{#language: |ar}}", "الإنجليزية" },
        .{ "{{#language:de}}", "Deutsch" },
        .{ "{{#language:ar|}}", "العربية" },
        .{ "{{#لغة: EN | FR }}", "anglais" },
        .{ "{{#language:{{Code}}|{{Display}}}}", "الإنجليزية" },
        .{ "{{NestedLanguage|EN|AR}}", "الإنجليزية" },
        .{ "{{#language:ZZ-latn-us-x-FOO}}", "zz-Latn-US-x-foo" },
        .{ "{{#language:ALS}}", "gsw" },
        .{ "{{#language:ZH-cn}}", "zh-Hans-CN" },
        .{ "{{#language:EN-rtl}}", "en-x-rtl" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case[1], try expander.expandFragment("Page", case[0], 1_670_803_200));
    const chain = try expander.expandFragment("-ability", "{{ل|en}}\n# suffix definition\n", 1_670_803_200);
    try std.testing.expectEqualStrings("== إنجليزية[[تصنيف:إنجليزية]] ==\n# suffix definition\n", chain);
    try std.testing.expect(std.mem.indexOf(u8, chain, "nowiki") == null);
    try std.testing.expect(std.mem.indexOf(u8, chain, "{{{") == null);
    const args = try runtime.newTable();
    try args.rawSet(a, .{ .number = 1 }, .{ .string = " EN " });
    try args.rawSet(a, .{ .number = 2 }, .{ .string = " AR " });
    try std.testing.expectEqualStrings("الإنجليزية", try Expander.hostFrameParserFunction(&expander, a, "#لغة", args));
    try args.rawSet(a, .{ .number = 1 }, .{ .string = "" });
    try args.rawSet(a, .{ .number = 2 }, .{ .string = "" });
    try std.testing.expectEqualStrings("English", try Expander.hostFrameParserFunction(&expander, a, "#language", args));
}

test "language parser preserves authoritative nonmatches and missing profile operational errors" {
    const aliases = rt.namespace_registry.magic_words;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var words = try aliases.Registry.init(a, aliases.parser_header ++ "\n# wiki\tenwiktionary\n# dump-date\t20261001\n# content-language\ten\nlanguage\t0\t#LANGUAGE\n", "enwiktionary", "20261001", "en");
    defer words.deinit();
    var source: LanguageParserTestSource = .{ .words = &words };
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .ctx = &source, .get = LanguageParserTestSource.get, .exists = TestProvider.exists, .language_name = LanguageParserTestSource.languageName, .resolve_parser_function = LanguageParserTestSource.parser } };
    try std.testing.expectEqualStrings("&#123;&#123;#لغة:en&#125;&#125;", try expander.expandFragment("Page", "{{#لغة:en}}", 1_670_803_200));
    try std.testing.expectError(error.LanguageNameSnapshotMissing, expander.expandFragment("Page", "{{#language:en|missing}}", 1_670_803_200));
    try std.testing.expectError(error.LanguageNameSnapshotMissing, expander.expandFragment("Page", "{{#language:en|-}}", 1_670_803_200));
    try std.testing.expectError(error.OutOfMemory, expander.expandFragment("Page", "{{#language:oom|ar}}", 1_670_803_200));
    try std.testing.expectError(error.AccessDenied, expander.expandFragment("Page", "{{#language:denied|ar}}", 1_670_803_200));
    expander.provider.language_name = null;
    try std.testing.expectError(error.LanguageNameSnapshotMissing, expander.expandFragment("Page", "{{#language:en}}", 1_670_803_200));
}

test "unsupported parser diagnostics preserve literals and reset per page" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 24, 2);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{ rt.stabilize(TranslationReuseProbe.root), rt.stabilize(TranslationReuseProbe.root) };
    runtime.module_root_entries = &functions;
    runtime.configureModules(null, TranslationReuseProbe.lookup, TranslationReuseProbe.name);
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);

    var expander = Expander{
        .runtime = &runtime,
        .env_slot = 0,
        .string_slot = 18,
        .mw_slot = 23,
        .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists },
        .install_scribunto = installTestInvoke,
    };
    const unsupported = try expander.expandFragment("Page", "before {{#unsupported_probe:x}} after", 1_670_803_200);
    try std.testing.expectEqualStrings("before &#123;&#123;#unsupported_probe:x&#125;&#125; after", unsupported);
    try std.testing.expect(expander.unsupported_parser_function);
    _ = try expander.expandFragment("Next", "<nowiki>{{#unsupported_probe:x}}</nowiki>", 1_670_803_200);
    try std.testing.expect(!expander.unsupported_parser_function);
    const computed_source = "{{{{#if:x|#unsupported_probe}}:x}}";
    const computed = try expander.expandFragment("Computed", computed_source, 1_670_803_200);
    try std.testing.expectEqualStrings("&#123;&#123;\n#unsupported_probe:x&#125;&#125;", computed);
    try std.testing.expect(expander.unsupported_parser_function);
    _ = try expander.expandFragment("Protected pre", "<pre>{{#unsupported_probe:x}}</pre>", 1_670_803_200);
    try std.testing.expect(!expander.unsupported_parser_function);
    try std.testing.expectEqualStrings("yes", try expander.expandFragment("Known", "{{#if:x|yes|no}}", 1_670_803_200));
    try std.testing.expect(!expander.unsupported_parser_function);
}

test "labelled section inclusion expands captured Arabic self toc regions with authoritative aliases" {
    const aliases = rt.namespace_registry.magic_words;
    const Source = struct {
        words: ?*const aliases.Registry = null,
        title: []const u8 = "",
        text: []const u8 = "",
        fn get(raw: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return if (std.mem.eql(u8, title, self.title)) self.text else null;
        }
        fn parser(raw: ?*anyopaque, name: []const u8) !?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return (self.words orelse return null).resolve(name, .parser_function);
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var source: Source = .{};
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .ctx = &source, .get = Source.get, .exists = TestProvider.exists } };
    // Exact source-backed toc slices: a1 rev1136637 (516 B), a2 rev1136638 (521 B).
    // Surrounding excluded text is a controlled fixture; neither source toc contains recursion.
    const Fixture = struct { title: []const u8, region: []const u8 };
    const fixtures = [_]Fixture{
        .{ .title = "فهرس:إنجليزية/a1", .region = "\n<div style=\"width:100%;clear:both;border-top:1px solid #AAAAAA;border-bottom:1px solid #AAAAAA\">\n[[فهرس:إنجليزية/a1#globalWrapper|↑]] [[#a|a]] [[#aa|aa]] [[#ab|ab]] [[#ac|ac]] [[#ad|ad]] [[#ae|ae]] [[#af|af]] [[#ag|ag]] [[#ah|ah]] [[#ai|ai]] [[#aj|aj]] [[#ak|ak]] [[#al|al]] [[#am|am]] [[../a2#an|an]] [[../a2#ao|ao]] [[../a2#ap|ap]] [[../a2#aq|aq]] [[../a2#ar|ar]] [[../a2#as|as]] [[../a2#at|at]] [[../a2#au|au]] [[../a2#av|av]] [[../a2#aw|aw]] [[../a2#ax|ax]] [[../a2#ay|ay]] [[../a2#az|az]] </div>\n" },
        .{ .title = "فهرس:إنجليزية/a2", .region = "\n<div style=\"width:100%;clear:both;border-top:1px solid #AAAAAA;border-bottom:1px solid #AAAAAA\">\n[[فهرس:إنجليزية/a2#globalWrapper|↑]] [[../a1#a|a]] [[../a1#aa|aa]] [[../a1#ab|ab]] [[../a1#ac|ac]] [[../a1#ad|ad]] [[../a1#ae|ae]] [[../a1#af|af]] [[../a1#ag|ag]] [[../a1#ah|ah]] [[../a1#ai|ai]] [[../a1#aj|aj]] [[../a1#ak|ak]] [[../a1#al|al]] [[../a1#am|am]] [[#an|an]] [[#ao|ao]] [[#ap|ap]] [[#aq|aq]] [[#ar|ar]] [[#as|as]] [[#at|at]] [[#au|au]] [[#av|av]] [[#aw|aw]] [[#ax|ax]] [[#ay|ay]] [[#az|az]] </div>\n" },
    };
    for (fixtures) |fixture| {
        source.title = fixture.title;
        source.text = try std.fmt.allocPrint(a, "OUTSIDE{{{{Loop}}}}<section begin=\"toc\" />{s}<section end=\"toc\" />OUTSIDE", .{fixture.region});
        var calls: std.ArrayList(u8) = .empty;
        var expected: std.ArrayList(u8) = .empty;
        for (0..13) |_| {
            try calls.appendSlice(a, try std.fmt.allocPrint(a, "{{{{#section:{s}|toc}}}}", .{fixture.title}));
            try expected.appendSlice(a, fixture.region);
        }
        inline for (.{ false, true }) |authoritative| {
            expander.provider.authoritative_page_source = authoritative;
            expander.beginPage(fixture.title, if (authoritative) "PARTIAL CURRENT FRAGMENT" else source.text, 1_670_803_200);
            const args = try runtime.newTable();
            const actual = try expander.expandWikitext(calls.items, args, fixture.title, 0);
            try std.testing.expectEqualStrings(expected.items, actual);
            try std.testing.expect(!expander.unsupported_parser_function);
            try std.testing.expectEqual(@as(usize, 0), expander.template_depth);
        }
    }
    // The unchanged baseline reaches the public source-backed inclusion assertion above.
    // The candidate then also exercises the real strict captured alias registry.
    var words = try aliases.Registry.init(a, aliases.parser_header ++ "\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\nlst\t0\tlst\nlst\t0\tsection\n", "arwiktionary", "20261001", "ar");
    defer words.deinit();
    source.words = &words;
    expander.provider.resolve_parser_function = Source.parser;
    const captured = try expander.expandFragment(source.title, try std.fmt.allocPrint(a, "{{{{#SeCtIoN:{s}|toc}}}}", .{source.title}), 1_670_803_200);
    try std.testing.expectEqualStrings(fixtures[1].region, captured);
    try std.testing.expect(!expander.unsupported_parser_function);
    // Captured aliases remain authoritative; unsupported sibling functions stay literal/diagnosed.
    const unsupported = try expander.expandFragment("Page", "{{#lstx:Missing|toc}}", 1_670_803_200);
    try std.testing.expect(std.mem.indexOf(u8, unsupported, "#lstx") != null);
    try std.testing.expect(expander.unsupported_parser_function);
}

test "labelled section inclusion preserves upstream ranges protected nodes target frames redirects and cycles" {
    const Source = struct {
        fn get(_: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
            if (std.mem.eql(u8, title, "Sections")) return "before<section begin='a'/>A<section end='a'/>between<section begin=\"b\"/>B<section end=\"b\"/>after<section begin=a/>C<section end=a/>";
            if (std.mem.eql(u8, title, "Protected")) return "<!--<section begin=x/>COMMENT<section end=x/>--><nowiki><section begin=x/>NOWIKI<section end=x/></nowiki><pre><section begin=x/>PRE<section end=x/></pre><ref><section begin=x/>REF<section end=x/></ref>{{Unused|<section begin=x/>ARG<section end=x/>}}<section other='>' BEGIN = 'x' extra=ok/>REAL<section END=x/>";
            if (std.mem.eql(u8, title, "Target")) return "<section begin=x/>{{PAGENAME}}:{{{1|default}}}<section end=x/>";
            if (std.mem.eql(u8, title, "Paired")) return "before<section begin=x>HIDDEN</section>after";
            if (std.mem.eql(u8, title, "Template:A")) return "<section begin=x/>{{#lst:Template:A|x}}<section end=x/>";
            if (std.mem.eql(u8, title, "Template:Forward")) return "{{#lst:Target|x}}";
            if (std.mem.eql(u8, title, "Template:Parent")) return "<section begin=x/>{{/Child}}<section end=x/>|{{#lst:Alias|x}}";
            if (std.mem.eql(u8, title, "Template:Parent/Child")) return "FRAME_CHILD";
            if (std.mem.eql(u8, title, "Cycle")) return "<section begin=x/>{{#lst:Cycle|x}}<section end=x/>";
            if (std.mem.eql(u8, title, "Local")) return "<Abschnitt Anfang=x/>LOCAL<Abschnitt Ende=x/>";
            return null;
        }
        // Controlled captured-message fixture; production keeps its strict snapshot API.
        fn message(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, key: []const u8) !?Provider.InterfaceMessage {
            if (std.mem.eql(u8, key, "parser-template-loop-warning")) return .{ .source = "Fixture loop warning: $1" };
            return null;
        }
        fn body(raw: ?*anyopaque, a: std.mem.Allocator, title: []const u8) !?Provider.TransclusionBody {
            if (std.mem.eql(u8, title, "Alias"))
                return .{ .text = (try get(raw, a, "Template:Parent")).?, .title = "Template:Parent", .borrowed = true };
            return .{ .text = (try get(raw, a, title)) orelse return null, .title = title, .borrowed = true };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = Source.get, .exists = TestProvider.exists, .interface_message = Source.message } };
    const Case = struct { call: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .call = "{{#lst:Sections|a}}", .expected = "AC" },
        .{ .call = "{{#section:Sections|a|b}}", .expected = "AbetweenBC" },
        .{ .call = "{{#lst:Sections||b}}", .expected = "beforeAbetweenB" },
        .{ .call = "{{#lst:Sections|b|}}", .expected = "BafterC" },
        .{ .call = "{{#lst:Sections}}", .expected = "beforeAbetweenBafterC" },
        .{ .call = "{{#lst:Sections|absent}}", .expected = "" },
        .{ .call = "{{#lst:Paired}}", .expected = "beforeafter" },
        .{ .call = "{{#lst:Paired|x}}", .expected = "HIDDENafter" },
        .{ .call = "{{#lst:Missing|a}}", .expected = "[[Missing]]" },
        .{ .call = "{{#lst:|a}}", .expected = "" },
        .{ .call = "{{#lst:Protected|x}}", .expected = "REAL" },
        .{ .call = "{{#lst:Target|x}}", .expected = "Caller:default" },
        .{ .call = "{{#lst:Sections|a}}{{#lst:Sections|a}}", .expected = "ACAC" },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.expected, try expander.expandFragment("Caller", case.call, 1_670_803_200));
        try std.testing.expect(!expander.unsupported_parser_function);
        try std.testing.expectEqual(@as(usize, 0), expander.template_depth);
    }
    // PAGENAME uses the unchanged parser title, while target-frame relative templates
    // use final_title. CoreParserFunctions::makeTitle / pagename, wmf1.47 lines809/920.
    try std.testing.expectEqualStrings("Caller:default", try expander.expandFragment("Caller", "{{Forward|CALLER ARG MUST NOT LEAK}}", 1_670_803_200));
    expander.provider.get_transclusion_body = Source.body;
    try std.testing.expectEqualStrings("FRAME_CHILD", try expander.expandFragment("Caller", "{{#lst:Alias|x}}", 1_670_803_200));
    // Requested Alias is allowed even when its fetched final title equals an ancestor.
    // The selected region excludes the recursive outside invocation.
    try std.testing.expectEqualStrings("<section begin=x/>FRAME_CHILD<section end=x/>|FRAME_CHILD", try expander.expandFragment("Caller", "{{Parent}}", 1_670_803_200));
    expander.provider.get_transclusion_body = null;
    const cycle = try expander.expandFragment("Caller", "{{#lst:Cycle|x}}", 1_670_803_200);
    try std.testing.expect(std.mem.indexOf(u8, cycle, "<span class=\"error\">") != null);
    const ordinary_cycle = try expander.expandFragment("Caller", "{{A}}", 1_670_803_200);
    try std.testing.expect(std.mem.indexOf(u8, ordinary_cycle, "<span class=\"error\">") != null);
    try std.testing.expectEqual(@as(usize, 0), expander.template_depth);
    try std.testing.expectEqualStrings("AC", try expander.expandFragment("Caller", "{{#lst:Sections|a}}", 1_670_803_200));
    expander.max_depth = 3;
    try std.testing.expectError(error.TemplateDepth, expander.expandFragment("Caller", "{{Forward}}", 1_670_803_200));
    try std.testing.expectEqual(@as(usize, 0), expander.template_depth);
    expander.max_depth = 512;
    try std.testing.expectEqualStrings("AC", try expander.expandFragment("Caller", "{{#lst:Sections|a}}", 1_670_803_200));
    var german = try rt.namespace_registry.Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tdewiktionary\n# dump-date\t20261001\n# content-language\tde\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tentries\n" ++
        "10\tVorlage\tTemplate\tcase-sensitive\t1\t0\t0\t\tcompile_only\tinput\n" ++
        "14\tKategorie\tCategory\tcase-sensitive\t0\t0\t0\t\tcompile_only\tinput\n");
    defer german.deinit();
    runtime.namespace_catalog = &german;
    try std.testing.expectEqualStrings("LOCAL", try expander.expandFragment("Caller", "{{#lst:Local|x}}", 1_670_803_200));
}

test "unknown parser oracle expands children while preserving unsupported invocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 24, 2);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{ rt.stabilize(TranslationReuseProbe.root), rt.stabilize(TranslationReuseProbe.root) };
    runtime.module_root_entries = &functions;
    runtime.configureModules(null, TranslationReuseProbe.lookup, TranslationReuseProbe.name);
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);

    var expander = Expander{
        .runtime = &runtime,
        .env_slot = 0,
        .string_slot = 18,
        .mw_slot = 23,
        .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists },
        .install_scribunto = installTestInvoke,
    };

    const child = try expander.expandFragment("शारदा", "{{#unsupported_probe:{{PAGENAME}}|x={{uc:cat}}}}", 1_670_803_200);
    try std.testing.expectEqualStrings("&#123;&#123;#unsupported_probe:शारदा|x=CAT&#125;&#125;", child);
    try std.testing.expect(expander.unsupported_parser_function);
    const fallback = try expander.expandFragment("शारदा", "{{#urlencode:{{{1|{{PAGENAME}}}}}}}", 1_670_803_200);
    try std.testing.expectEqualStrings("&#123;&#123;#urlencode:शारदा&#125;&#125;", fallback);
    try std.testing.expect(expander.unsupported_parser_function);
    const markup = try expander.expandFragment("शारदा", "{{#unsupported_probe:<b>bold</b>|[[cat|label]]}}", 1_670_803_200);
    try std.testing.expectEqualStrings("&#123;&#123;#unsupported_probe:<b>bold</b>|[[cat|label]]&#125;&#125;", markup);
    try std.testing.expect(expander.unsupported_parser_function);
}

test "unknown parser oracle preserves protected source and valid lazy branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 24, 2);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{ rt.stabilize(TranslationReuseProbe.root), rt.stabilize(TranslationReuseProbe.root) };
    runtime.module_root_entries = &functions;
    runtime.configureModules(null, TranslationReuseProbe.lookup, TranslationReuseProbe.name);
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);

    var expander = Expander{
        .runtime = &runtime,
        .env_slot = 0,
        .string_slot = 18,
        .mw_slot = 23,
        .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists },
        .install_scribunto = installTestInvoke,
    };

    const protected = try expander.expandFragment("शारदा", "<nowiki>{{#unsupported_probe:{{PAGENAME}}}}</nowiki>", 1_670_803_200);
    try std.testing.expectEqualStrings("<nowiki>{{#unsupported_probe:{{PAGENAME}}}}</nowiki>", protected);
    try std.testing.expect(!expander.unsupported_parser_function);
    const lazy = try expander.expandFragment("शारदा", "{{#if:x|yes|{{#unsupported_probe:{{#expr:1/0}}}}}}", 1_670_803_200);
    try std.testing.expectEqualStrings("yes", lazy);
    try std.testing.expect(!expander.unsupported_parser_function);
    const known = try expander.expandFragment("शारदा", "{{urlencode:{{PAGENAME}}}}", 1_670_803_200);
    try std.testing.expectEqualStrings("%E0%A4%B6%E0%A4%BE%E0%A4%B0%E0%A4%A6%E0%A4%BE", known);
    try std.testing.expect(!expander.unsupported_parser_function);
}

test "unknown parser braces preserve external URL boundary after child expansion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 24, 2);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{ rt.stabilize(TranslationReuseProbe.root), rt.stabilize(TranslationReuseProbe.root) };
    runtime.module_root_entries = &functions;
    runtime.configureModules(null, TranslationReuseProbe.lookup, TranslationReuseProbe.name);
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);

    var expander = Expander{
        .runtime = &runtime,
        .env_slot = 0,
        .string_slot = 18,
        .mw_slot = 23,
        .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists },
        .install_scribunto = installTestInvoke,
    };

    const linked = try expander.expandFragment("शारदा", "[https://hindwidictionary.com/search?keyword={{#urlencode:{{PAGENAME}}}} शारदा]", 1_670_803_200);
    try std.testing.expectEqualStrings("[https://hindwidictionary.com/search?keyword=&#123;&#123;#urlencode:शारदा&#125;&#125; शारदा]", linked);
    try std.testing.expect(expander.unsupported_parser_function);
    const spaces = try expander.expandFragment("Page", "[https://example.test/?q={{#urlencode:alpha beta}} label]", 1_670_803_200);
    try std.testing.expectEqualStrings("[https://example.test/?q=&#123;&#123;#urlencode:alpha beta&#125;&#125; label]", spaces);
    try std.testing.expect(expander.unsupported_parser_function);
    const pipes = try expander.expandFragment("Page", "{{#unknown:alpha|beta}}", 1_670_803_200);
    try std.testing.expectEqualStrings("&#123;&#123;#unknown:alpha|beta&#125;&#125;", pipes);
    try std.testing.expect(expander.unsupported_parser_function);
    const html = try expander.expandFragment("Page", "{{#unknown:''alpha''}}", 1_670_803_200);
    try std.testing.expectEqualStrings("&#123;&#123;#unknown:''alpha''&#125;&#125;", html);
    try std.testing.expect(expander.unsupported_parser_function);
    const protected = try expander.expandFragment("Page", "<nowiki>{{#urlencode:x}}</nowiki>", 1_670_803_200);
    try std.testing.expectEqualStrings("<nowiki>{{#urlencode:x}}</nowiki>", protected);
    try std.testing.expect(!expander.unsupported_parser_function);
    const valid = try expander.expandFragment("Page", "[https://example.test/?q={{urlencode:a b}} label]", 1_670_803_200);
    try std.testing.expectEqualStrings("[https://example.test/?q=a+b label]", valid);
    try std.testing.expect(!expander.unsupported_parser_function);
}

const CopticInclusionBoundaryFixture = struct {
    fn get(_: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
        if (std.mem.eql(u8, title, "Template:BoundaryBrokenA")) return "{{BoundaryProbe|earlier=]<noinclude/>] [<noinclude/>[prefix|fut=ⲛⲁ}}";
        if (std.mem.eql(u8, title, "Template:BoundaryBrokenL")) return "{{BoundaryProbe|earlier=[<noinclude/>[one]<noinclude/>] [<noinclude/>[tail|fut=ⲛⲁ}}";
        if (std.mem.eql(u8, title, "Template:BoundarySah")) return "{{BoundaryProbe|earlier=prefix|fut=ⲛⲁ}}";
        if (std.mem.eql(u8, title, "Template:BoundaryBalanced")) return "{{BoundaryProbe|earlier=[[word|label]]|fut=ⲛⲁ}}";
        if (std.mem.eql(u8, title, "Template:BoundaryNested")) return "{{BoundaryProbe|earlier={{BoundaryInner|x}}|fut=ⲛⲁ}}";
        if (std.mem.eql(u8, title, "Template:BoundaryProtected")) return "{{BoundaryProbe|earlier=<nowiki>[<noinclude/>[literal</nowiki>|fut=ⲛⲁ}}";
        if (std.mem.eql(u8, title, "Template:BoundaryEmptyNode")) return "{{BoundaryProbe|earlier=A<noinclude/>B|fut=ⲛⲁ}}";
        if (std.mem.eql(u8, title, "Template:BoundaryProbe")) return "fut={{{fut|MISSING}}};earlier={{{earlier|}}}";
        if (std.mem.eql(u8, title, "Template:BoundaryInner")) return "nested {{{1}}}";
        return null;
    }
    fn exists(_: ?*anyopaque, title: []const u8) !bool {
        return (try get(null, std.testing.allocator, title)) != null;
    }
    // Mirrors Provider.transclusionBody preprocessing and borrowed-body delivery.
    fn body(_: ?*anyopaque, a: std.mem.Allocator, title: []const u8) !?Provider.TransclusionBody {
        const raw = (try get(null, a, title)) orelse return null;
        const text = if (@hasDecl(preprocess, "transcludeDecodedForParsingAlloc"))
            try preprocess.transcludeDecodedForParsingAlloc(a, raw)
        else
            try preprocess.transcludeDecodedAlloc(a, raw);
        return .{ .text = text, .title = title, .borrowed = true };
    }
    fn checkMode(source: []const u8, expected: []const u8, borrowed: bool) !void {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var runtime = try rt.Context.initProgram(arena.allocator(), 24, 1);
        defer runtime.deinit();
        try rt.bindGlobalTable(&runtime, null, 0);
        try stdlib.install(&runtime);
        try installTestHost(&runtime, 18, 23);
        var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = get, .exists = exists }, .install_scribunto = installTestInvoke };
        if (borrowed) expander.provider.get_transclusion_body = body;
        const actual = try expander.expandFragment("Coptic boundary fixture", source, 1_670_803_200);
        try std.testing.expectEqualStrings(expected, actual);
        try std.testing.expect(!expander.unsupported_parser_function);
    }
    fn check(source: []const u8, expected: []const u8) !void {
        try checkMode(source, expected, false);
        try checkMode(source, expected, true);
    }
};

test "Coptic inclusion boundaries preserve later future argument" {
    try CopticInclusionBoundaryFixture.check("{{BoundaryBrokenA}}", "fut=ⲛⲁ;earlier=]] [[prefix");
    try CopticInclusionBoundaryFixture.check("{{BoundaryBrokenL}}", "fut=ⲛⲁ;earlier=[[one]] [[tail");
}

test "Coptic inclusion boundaries retain balanced nested and literal controls" {
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "{{BoundarySah}}", .expected = "fut=ⲛⲁ;earlier=prefix" },
        .{ .source = "{{BoundaryBalanced}}", .expected = "fut=ⲛⲁ;earlier=[[word|label]]" },
        .{ .source = "{{BoundaryNested}}", .expected = "fut=ⲛⲁ;earlier=nested x" },
        .{ .source = "{{BoundaryProtected}}", .expected = "fut=ⲛⲁ;earlier=<nowiki>[<noinclude/>[literal</nowiki>" },
        .{ .source = "{{BoundaryEmptyNode}}", .expected = "fut=ⲛⲁ;earlier=AB" },
    };
    for (cases) |case| try CopticInclusionBoundaryFixture.check(case.source, case.expected);
}

// Official en.wiktionary API parse: parser-switch-audit01/official-response.json
// SHA256 2d033c95e5f12b699d8ab8a4e26acfbcf9447c29fda1f665dbfecfc080ca5555.
const NumericSwitchFixture = struct {
    fn forbiddenGet(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!?[]const u8 {
        return error.UnchosenSwitchBranchFetched;
    }
    fn forbiddenExists(_: ?*anyopaque, _: []const u8) anyerror!bool {
        return error.UnchosenSwitchExistenceChecked;
    }
    fn check(source: []const u8, expected: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var runtime = try rt.Context.initProgram(arena.allocator(), 24, 1);
        defer runtime.deinit();
        try rt.bindGlobalTable(&runtime, null, 0);
        try stdlib.install(&runtime);
        try installTestHost(&runtime, 18, 23);
        var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = forbiddenGet, .exists = forbiddenExists }, .install_scribunto = installTestInvoke };
        try std.testing.expectEqualStrings(expected, try expander.expandFragment("Page", source, 1_670_803_200));
    }
};

test "switch numeric named cases match the parser equality policy" {
    try NumericSwitchFixture.check("{{#switch:01|1=matched|#default=unmatched}}", "matched");
    try NumericSwitchFixture.check("{{#switch:+1.0|1=matched|#default=unmatched}}", "matched");
    try NumericSwitchFixture.check("{{#switch:9007199254740993|9007199254740992=wrong|#default=distinct}}", "distinct");
}

test "switch numeric fallthrough retains literal and case-sensitive controls" {
    try NumericSwitchFixture.check("{{#switch:01|1|2=fallthrough|#default=unmatched}}", "fallthrough");
    try NumericSwitchFixture.check("{{#switch:+1.0|1|2=fallthrough|#default=unmatched}}", "fallthrough");
    try NumericSwitchFixture.check("{{#switch:01x|1=bad|#default=literal-control}}", "literal-control");
    try NumericSwitchFixture.check("{{#switch:A|a=bad|#default=case-control}}", "case-control");
}

test "switch numeric matches keep unselected branches lazy and defaults exact" {
    try NumericSwitchFixture.check("{{#switch:01|1= matched |2={{MissingBranch}}|#default={{MissingDefault}}}}", "matched");
    try NumericSwitchFixture.check("{{#switch:01|1|2=fallthrough|#default={{MissingDefault}}}}", "fallthrough");
    try NumericSwitchFixture.check("{{#switch:01x|1={{MissingBranch}}|#default= default }}", "default");
    try NumericSwitchFixture.check("{{#switch:01x|1={{MissingBranch}}| trailing }}", "trailing");
}

test "switch bare default falls through to the next named result" {
    // Formula:la-declinatio selects this shape when its optional modus is absent.
    try NumericSwitchFixture.check("{{#switch:{{{modus|}}}|en={{MissingEnglishTable}}|#default|eu=tabula}}", "tabula");
    try NumericSwitchFixture.check("{{#switch:other|#default|unused|eu=tabula|later={{MissingBranch}}}}", "tabula");
    try NumericSwitchFixture.check("{{#switch:match|#default|eu={{MissingDefault}}|match=selected}}", "selected");
    try NumericSwitchFixture.check("{{#switch:#default|#default=first|#default={{MissingLaterDefault}}}}", "first");
    try NumericSwitchFixture.check("{{#switch:other|{{#if:1|#default}}=expanded-default}}", "expanded-default");
    try NumericSwitchFixture.check("{{#switch:other|#default|eu=first|#default|us=last}}", "last");
}

test "switch matched fallthrough does not expand the result label" {
    try NumericSwitchFixture.check("{{#switch:match|match|{{MissingLabel}}=selected|#default={{MissingDefault}}}}", "selected");
    try NumericSwitchFixture.check("{{#switch:01|1|{{MissingLabel}}=numeric-selected}}", "numeric-selected");
    try NumericSwitchFixture.check("{{#switch:match|#default|match|{{MissingLabel}}=selected}}", "selected");
}

test "switch final bare argument takes precedence over an earlier default" {
    try NumericSwitchFixture.check("{{#switch:other|#default={{MissingDefault}}| final }}", "final");
    try NumericSwitchFixture.check("{{#switch:other|#default|eu={{MissingDefault}}| final }}", "final");
    try NumericSwitchFixture.check("{{#switch:other|#default={{MissingDefault}}|}}", "");
    try NumericSwitchFixture.check("{{#switch:match|match=selected|{{MissingTrailing}}}}", "selected");
}

// Official Arabic oracle response02 SHA256 ee526543ecfce7e41a3142c56a68ee7aad9a00a083abe7b4dd3a40c80cd4b0bb.
test "parser numeric equality rejects nondecimal Zig literals" {
    try NumericSwitchFixture.check("{{#ifeq:1_0|10|bad|literal}}", "literal");
    try NumericSwitchFixture.check("{{#switch:1_0|10=bad|#default=literal}}", "literal");
    try NumericSwitchFixture.check("{{#switch:1_0|10|20=bad|#default=literal}}", "literal");
    try NumericSwitchFixture.check("{{#ifeq:0x1p0|1|bad|literal}}", "literal");
    try NumericSwitchFixture.check("{{#switch:0x1p0|1=bad|#default=literal}}", "literal");
    try NumericSwitchFixture.check("{{#ifeq:+1.0e1|10|matched|bad}}", "matched");
    try NumericSwitchFixture.check("{{#switch:+1.0e1|10=matched|#default=bad}}", "matched");
    try NumericSwitchFixture.check("{{#ifeq:1_0|1_0|literal-equal|bad}}", "literal-equal");
}

test "decimal numeric grammar requires mantissa and complete exponent" {
    for ([_][]const u8{ "0", "01", "+1.0e1", "-.5", "1.", "1E-2" }) |value| try std.testing.expect(Expander.isDecimalNumericString(value));
    for ([_][]const u8{ "", "+", ".", "1e", "1e+", "1_0", "0x1p0", "nan", "inf", "1 0" }) |value| try std.testing.expect(!Expander.isDecimalNumericString(value));
}

// Captured official responses: Arabic six categories ee526543, short clamp43e58e13,
// Japanese fallback9f12c7eb, English normalization0a567dcc and positional18f7ecc9.
const PositionalPluralFixture = struct {
    const State = struct { fallback_calls: usize = 0 };
    fn get(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!?[]const u8 {
        return error.SelectedPluralProviderFetched;
    }
    fn forbiddenExists(_: ?*anyopaque, _: []const u8) anyerror!bool {
        return error.UnexpectedPluralExistenceChecked;
    }
    fn fallbacks(raw: ?*anyopaque, code: []const u8) anyerror![]const []const u8 {
        const state: *State = @ptrCast(@alignCast(raw.?));
        state.fallback_calls += 1;
        if (std.mem.eql(u8, code, "ja")) return &.{}; // Actual captured STRICT row; ALL appends English.
        return error.UnexpectedPluralFallback;
    }
    fn check(language: []const u8, source: []const u8, expected: ?[]const u8, expected_fallback_calls: usize) !void {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const registry_text = try std.mem.concat(a, u8, &.{
            "# wikidict-namespace-registry-v1\n# wiki\t",        language,                                                                   "wiktionary\n# dump-date\t20261001\n# content-language\t",                  language, "\n",
            "0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tentries\n", "10\tTemplate\tTemplate\tcase-sensitive\t1\t0\t0\t\tcompile_only\tinput\n", "14\tCategory\tCategory\tcase-sensitive\t0\t0\t0\t\tcompile_only\tinput\n",
        });
        var catalog = try rt.namespace_registry.Registry.init(a, registry_text);
        defer catalog.deinit();
        var runtime = try rt.Context.initProgram(a, 24, 1);
        defer runtime.deinit();
        try rt.bindGlobalTable(&runtime, null, 0);
        try stdlib.install(&runtime);
        try installTestHost(&runtime, 18, 23);
        runtime.namespace_catalog = &catalog;
        var state: State = .{};
        var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .ctx = &state, .get = get, .exists = forbiddenExists, .language_fallbacks = fallbacks }, .install_scribunto = installTestInvoke };
        if (expected) |text| {
            try std.testing.expectEqualStrings(text, try expander.expandFragment("Page", source, 1_670_803_200));
        } else {
            try std.testing.expectError(error.SelectedPluralProviderFetched, expander.expandFragment("Page", source, 1_670_803_200));
        }
        try std.testing.expectEqual(expected_fallback_calls, state.fallback_calls);
    }
};

test "plural uses content language Arabic positional six categories" {
    try PositionalPluralFixture.check("ar", "{{PLURAL:0|zero|one|two|few|many|other}} / {{PLURAL:1|zero|one|two|few|many|other}} / {{PLURAL:2|zero|one|two|few|many|other}} / {{PLURAL:3|zero|one|two|few|many|other}} / {{PLURAL:11|zero|one|two|few|many|other}} / {{PLURAL:100|zero|one|two|few|many|other}}", "zero / one / two / few / many / other", 0);
}

test "plural Arabic short positional lists clamp to final supplied form" {
    const numbers = [_][]const u8{ "0", "1", "2", "3", "11", "100" };
    for (2..6) |form_count| {
        for (numbers, 0..) |number, category| {
            const forms: []const u8 = switch (form_count) {
                2 => "|F0|F1",
                3 => "|F0|F1|F2",
                4 => "|F0|F1|F2|F3",
                5 => "|F0|F1|F2|F3|F4",
                else => unreachable,
            };
            const source = try std.fmt.allocPrint(std.testing.allocator, "{{{{PLURAL:{s}{s}}}}}", .{ number, forms });
            defer std.testing.allocator.free(source);
            const expected = try std.fmt.allocPrint(std.testing.allocator, "F{d}", .{@min(category, form_count - 1)});
            defer std.testing.allocator.free(expected);
            try PositionalPluralFixture.check("ar", source, expected, 0);
        }
    }
}

test "plural Japanese captured empty strict fallback reaches English rules" {
    try PositionalPluralFixture.check("ja", "{{PLURAL:0|FIRST|SECOND}}", "SECOND", 1);
    try PositionalPluralFixture.check("ja", "{{PLURAL:1|FIRST|SECOND}}", "FIRST", 1);
    try PositionalPluralFixture.check("ja", "{{PLURAL:2|FIRST|SECOND}}", "SECOND", 1);
    try PositionalPluralFixture.check("ja", "{{PLURAL:1.5|FIRST|SECOND}}", "SECOND", 1);
}

test "plural English normalization explicit numbers and positional literals" {
    try PositionalPluralFixture.check("en", "{{PLURAL:1.0|ONE|OTHER}} / {{PLURAL:-1|ONE|OTHER}} / {{PLURAL:1.5|ONE|OTHER}} / {{PLURAL:01|1=EXPLICIT|ONE|OTHER}} / {{PLURAL:2|one=ONE|other=OTHER}}", "ONE / ONE / OTHER / EXPLICIT / other=OTHER", 0);
}

test "plural expands only selected positional or explicit form" {
    try PositionalPluralFixture.check("ar", "{{PLURAL:3|{{Unchosen}}|{{Unchosen}}|{{Unchosen}}|FEW|{{Unchosen}}|{{Unchosen}}}}", "FEW", 0);
    try PositionalPluralFixture.check("en", "{{PLURAL:01|1=EXPLICIT|{{Unchosen}}|{{Unchosen}}}}", "EXPLICIT", 0);
    try PositionalPluralFixture.check("en", "{{PLURAL:2|{{Unchosen}}|{{Selected}}}}", null, 0);
}

test "plural count casting uses decimal prefix rather than Zig numeric syntax" {
    try PositionalPluralFixture.check("en", "{{PLURAL:1_0|ONE|OTHER}} / {{PLURAL:0x1p0|ONE|OTHER}} / {{PLURAL:+1.0e1|ONE|OTHER}}", "ONE / OTHER / OTHER", 0);
}

// Official exact-label response174 B SHA78e928eb44f844dd7561964fa87e918990193bd5154624a054b5f1565cc27ca5.
test "plural explicit forms use exact normalized count labels" {
    try PositionalPluralFixture.check("en", "{{PLURAL:1|01=EXPLICIT|ONE|OTHER}} / {{PLURAL:1|+1=EXPLICIT|ONE|OTHER}} / {{PLURAL:1|1.0=EXPLICIT|ONE|OTHER}} / {{PLURAL:1|1e0=EXPLICIT|ONE|OTHER}} / {{PLURAL:1|abc1=EXPLICIT|ONE|OTHER}}", "ONE / ONE / ONE / ONE / ONE", 0);
}

test "expanded authored behavior prefixes reach presentation without early stripping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 24);
    defer runtime.deinit();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists } };
    try std.testing.expectEqualStrings("__NOEDITSECTION__==English==\n__NOEDITSECTION__===Noun===\n__NOEDITSECTION__# [[cat|lexical sense]]\n", try expander.expandFragment("entry", "<!--hidden-->__NOEDITSECTION__==English==\n__NOEDITSECTION__===Noun===\n__NOEDITSECTION__# [[cat|lexical sense]]\n", 1_670_803_200));
}

const CategoryTreeNamespaceFixture = struct {
    const registry_text = "# wikidict-namespace-registry-v1\n# wiki\tenwiktionary\n# dump-date\t20261001\n# content-language\ten\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tentries\n" ++
        "1\tTalk\tTalk\tcase-sensitive\t0\t0\t0\t\tcompile_only\tinput\n" ++
        "4\tWiktionary\tProject\tcase-sensitive\t1\t0\t0\t\tcompile_only\tinput\tWT\n" ++
        "6\tFile\tFile\tcase-sensitive\t0\t0\t0\t\tcompile_only\tinput\tImage\n" ++
        "10\tTemplate\tTemplate\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\tT\n" ++
        "14\tCategory\tCategory\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\n" ++
        "118\tRekonstruktion\tReconstruction\tcase-sensitive\t1\t0\t0\t\treconstruction\tverified_edition_feature\tReko\n";
    members: []const []const u8 = &.{ "main", "Reconstruction:Proto-Test/term", "Talk:excluded", "Wiktionary:entry" },
    count: ?u32 = null,
    subcats: u32 = 0,
    present: bool = true,

    fn exists(raw: ?*anyopaque, _: []const u8) !bool {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        return self.present;
    }
    fn tree(raw: ?*anyopaque, a: std.mem.Allocator, _: []const u8, scope: Provider.CategoryTreeScope) ![]const []const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        return a.dupe([]const u8, if (scope == .main) &.{"main"} else self.members);
    }
    fn stats(raw: ?*anyopaque, _: []const u8) !?Provider.CategoryStats {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        return if (self.count) |count| .{ .all = count, .files = 0, .subcats = self.subcats } else null;
    }
};

test "CategoryTree deeper page traversal requires a complete verified leaf" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var registry = try rt.namespace_registry.Registry.init(a, CategoryTreeNamespaceFixture.registry_text);
    defer registry.deinit();
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    runtime.namespace_catalog = &registry;
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var source: CategoryTreeNamespaceFixture = .{};
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{
        .ctx = &source,
        .get = TestProvider.get,
        .exists = CategoryTreeNamespaceFixture.exists,
        .category_tree = CategoryTreeNamespaceFixture.tree,
        .category_stats = CategoryTreeNamespaceFixture.stats,
    } };
    source.members = &.{ "diunggah", "mengunggah" };
    source.count = 2;
    const one = "{{#categorytree:Turunan kata unggah|depth=1|namespaces=0 14}}";
    const three = "{{#categorytree:Turunan kata unggah|depth=3|namespaces=0 14}}";
    const result = try expander.expandFragment("unggah", three, 0);
    try std.testing.expectEqualStrings(try expander.expandFragment("unggah", one, 0), result);
    try std.testing.expect(std.mem.indexOf(u8, result, "[[diunggah]]").? < std.mem.indexOf(u8, result, "[[mengunggah]]").?);
    source.count = null;
    try std.testing.expectError(error.UnsupportedCategoryTreeOptions, expander.expandFragment("unggah", three, 0));
    source.count = 3;
    try std.testing.expectError(error.UnsupportedCategoryTreeOptions, expander.expandFragment("unggah", three, 0));
    source.count = 2;
    source.subcats = 1;
    try std.testing.expectError(error.UnsupportedCategoryTreeOptions, expander.expandFragment("unggah", three, 0));
    source.subcats = 0;
    source.members = &.{ "diunggah", "Category:Child" };
    try std.testing.expectError(error.UnsupportedCategoryTreeOptions, expander.expandFragment("unggah", three, 0));
}

test "CategoryTree namespace filters retain qualified titles and resolve aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var registry = try rt.namespace_registry.Registry.init(a, CategoryTreeNamespaceFixture.registry_text);
    defer registry.deinit();
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    runtime.namespace_catalog = &registry;
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var source: CategoryTreeNamespaceFixture = .{};
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{
        .ctx = &source,
        .get = TestProvider.get,
        .exists = CategoryTreeNamespaceFixture.exists,
        .category_tree = CategoryTreeNamespaceFixture.tree,
        .category_stats = CategoryTreeNamespaceFixture.stats,
    } };
    const page = "Reconstruction:Proto-Test/source";
    const input = "{{#categorytree:Probe|type=pages|depth=1|class=\"columns-bg term-list\"|style=counter-reset: pagesleftover 0|namespaces=- Reconstruction}}";
    const actual = try expander.expandFragment(page, input, 1_670_803_200);
    try std.testing.expect(std.mem.indexOf(u8, actual, "[[main]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "[[Reconstruction:Proto-Test/term]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "Talk:excluded") == null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "Wiktionary:entry") == null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "Unsupported") == null);
    for ([_][]const u8{ "- reko", "MAIN Rekonstruktion", "0 118", "*#Reconstruction:Unknown", "0 1.18e2" }) |filter| {
        const text = try std.fmt.allocPrint(a, "{{{{#categorytree:Probe|type=pages|depth=1|class=\"columns-bg term-list\"|style=counter-reset: pagesleftover 0|namespaces={s}}}}}", .{filter});
        try std.testing.expectEqualStrings(actual, try expander.expandFragment(page, text, 1_670_803_200));
    }
    const multiple = try expander.expandFragment(page, "{{#categorytree:Probe|namespaces=- Reconstruction WT}}", 1_670_803_200);
    try std.testing.expect(std.mem.indexOf(u8, multiple, "[[Wiktionary:entry]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, multiple, "Talk:excluded") == null);
    const main = try expander.expandFragment(page, "{{#categorytree:Probe|namespaces=-}}", 1_670_803_200);
    try std.testing.expect(std.mem.indexOf(u8, main, "[[main]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, main, "Reconstruction:Proto-Test/term") == null);
    try std.testing.expectEqualStrings(main, try expander.expandFragment(page, "{{#categorytree:Probe|namespaces=_ * MAIN 0}}", 1_670_803_200));
    const unfiltered = try expander.expandFragment(page, "{{#categorytree:Probe|type=pages}}", 1_670_803_200);
    for ([_][]const u8{ "Unknown", "1_18", "118_", "0x76" }) |unknown| {
        const text = try std.fmt.allocPrint(a, "{{{{#categorytree:Probe|type=pages|namespaces={s}}}}}", .{unknown});
        try std.testing.expectEqualStrings(unfiltered, try expander.expandFragment(page, text, 1_670_803_200));
    }
    for ([_]bool{ true, false }) |present| {
        source.present = present;
        for ([_][]const u8{ "parents", "super", "inverse", "PaReNtS", " parents ", "\tSuPeR\r\n", "100", "1e2", "100.9", " +100.5 ", ".100e3" }) |inverse| {
            for ([_][]const u8{ "mode", "type" }) |key| {
                for ([_][]const u8{ "-", "- Reconstruction", "Unknown" }) |filter| {
                    const text = try std.fmt.allocPrint(a, "{{{{#categorytree:Probe|{s}={s}|namespaces={s}}}}}", .{ key, inverse, filter });
                    try std.testing.expectError(error.UnsupportedCategoryTreeOptions, expander.expandFragment(page, text, 1_670_803_200));
                }
            }
        }
    }
    source.present = true;
    for ([_][]const u8{ " pages ", "10", "1e1", "10.9" }) |forward| {
        const text = try std.fmt.allocPrint(a, "{{{{#categorytree:Probe|type={s}}}}}", .{forward});
        try std.testing.expectEqualStrings(unfiltered, try expander.expandFragment(page, text, 1_670_803_200));
    }
    // Unknown modes default to categories; a valid namespace filter then
    // selects forward pages mode, just as the captured extension does.
    for ([_][]const u8{ "Unknown", "1_00", "0x64", "sub", "0", "default" }) |unknown_mode| {
        const text = try std.fmt.allocPrint(a, "{{{{#categorytree:Probe|type={s}|namespaces=-}}}}", .{unknown_mode});
        try std.testing.expectEqualStrings(main, try expander.expandFragment(page, text, 1_670_803_200));
    }
    source.present = false;
    const missing = try expander.expandFragment(page, "{{#categorytree:Probe|type=pages|namespaces=Reko -}}", 1_670_803_200);
    try std.testing.expect(std.mem.indexOf(u8, missing, "&quot;namespaces&quot;:[0,118]") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing, "not found") != null);
}

test "CategoryTree namespace filtering refuses truncated capture ambiguity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var registry = try rt.namespace_registry.Registry.init(a, CategoryTreeNamespaceFixture.registry_text);
    defer registry.deinit();
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    runtime.namespace_catalog = &registry;
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var members: [200][]const u8 = undefined;
    for (&members) |*title| title.* = "Talk:excluded";
    members[0] = "Reconstruction:Proto-Test/term";
    var source: CategoryTreeNamespaceFixture = .{ .members = &members, .count = 201 };
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{
        .ctx = &source,
        .get = TestProvider.get,
        .exists = CategoryTreeNamespaceFixture.exists,
        .category_tree = CategoryTreeNamespaceFixture.tree,
        .category_stats = CategoryTreeNamespaceFixture.stats,
    } };
    const input = "{{#categorytree:Probe|type=pages|namespaces=- Reconstruction}}";
    try std.testing.expectError(error.CategoryTreeSnapshotIncomplete, expander.expandFragment("Page", input, 1_670_803_200));
    source.count = null;
    try std.testing.expectError(error.CategoryTreeSnapshotIncomplete, expander.expandFragment("Page", input, 1_670_803_200));
    source.count = 200;
    const complete = try expander.expandFragment("Page", input, 1_670_803_200);
    try std.testing.expect(std.mem.indexOf(u8, complete, "[[Reconstruction:Proto-Test/term]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete, "Talk:excluded") == null);
    source.count = 201;
    // All first 200 rows match, so the official post-filter limit is satisfied.
    for (&members) |*title| title.* = "Reconstruction:Proto-Test/term";
    _ = try expander.expandFragment("Page", input, 1_670_803_200);
    // The separately captured main scope retains its previous 200-row contract.
    _ = try expander.expandFragment("Page", "{{#categorytree:Probe|namespaces=-}}", 1_670_803_200);
    _ = try expander.expandFragment("Page", "{{#categorytree:Probe|type=pages}}", 1_670_803_200);
}

test "native AOT generated comments normalize after invoke while authored literals stay protected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 24, 1);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{rt.stabilize(TestModule.root)};
    runtime.module_root_entries = &functions;
    runtime.configureModules(null, TestModule.lookup, TestModule.name);
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists }, .install_scribunto = installTestInvoke };
    // Module output contains comments absent from the authored invocation input.
    const source = "Authored A__NOEDIT<!--authored-->SECTION__B\n\n{{#invoke:Test|generated_comments}}\n\n<nowiki>__NOEDIT<!--literal-->SECTION__ ISBN 97803<!--literal-->06406157</nowiki>\n\n<pre>__NOEDIT<!--literal-->SECTION__ ISBN 97803<!--literal-->06406157</pre>\n\n<source>__NOEDIT<!--literal-->SECTION__ ISBN 97803<!--literal-->06406157</source>\n\n<syntaxhighlight>__NOEDIT<!--literal-->SECTION__ ISBN 97803<!--literal-->06406157</syntaxhighlight>\n\n<code>Ordinary A<!--ordinary-->B __NOEDITSECTION__</code>\n\n&#95;&#95;NOEDITSECTION__\n\n{{#invoke:Test|generated_unclosed}}";
    const expected = "Authored A__NOEDITSECTION__B\n\nGenerated A__NOEDITSECTION__B\nISBN 9780306406157\n__TOC__\nISBN 97803__TOC__06406157\nTail\n&lt;nowiki>__NOEDITSECTION__[[B]]</nowiki>\nAB\n\n<nowiki>__NOEDIT<!--literal-->SECTION__ ISBN 97803<!--literal-->06406157</nowiki>\n\n<pre>__NOEDIT<!--literal-->SECTION__ ISBN 97803<!--literal-->06406157</pre>\n\n<source>__NOEDIT<!--literal-->SECTION__ ISBN 97803<!--literal-->06406157</source>\n\n<syntaxhighlight>__NOEDIT<!--literal-->SECTION__ ISBN 97803<!--literal-->06406157</syntaxhighlight>\n\n<code>Ordinary AB __NOEDITSECTION__</code>\n\n&#95;&#95;NOEDITSECTION__\n\nUnclosed &lt;!--tail __NOEDITSECTION__ [[B]] ISBN 9780306406157";
    try std.testing.expectEqualStrings(expected, try expander.expandFragment("Page", source, 1_670_803_200));
    // Normalization does not decode entity-authored pseudo-comments or recurse
    // into newly generated template syntax.
    try std.testing.expectEqualStrings("&lt;!--literal--&gt;__NOEDITSECTION__", try expander.expandFragment("Page", "&lt;!--literal--&gt;__NOEDITSECTION__", 1_670_803_200));
}

test "native AOT unmatched extension openers expand later templates while matched bodies stay literal" {
    const Source = struct {
        fn get(_: ?*anyopaque, a: std.mem.Allocator, title: []const u8) !?[]const u8 {
            if (std.mem.eql(u8, title, "Template:FrenchAfterMissing")) return "==French==\n# [[fr]]";
            return TestProvider.get(null, a, title);
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = Source.get, .exists = TestProvider.exists } };
    for ([_][]const u8{ "math", "pre", "source", "syntaxhighlight", "nowiki" }) |name| {
        const input = try std.fmt.allocPrint(a, "==English==\n# [[en]]\n<{s}>\n{{{{FrenchAfterMissing}}}}", .{name});
        const expected = try std.fmt.allocPrint(a, "==English==\n# [[en]]\n<{s}>\n==French==\n# [[fr]]", .{name});
        try std.testing.expectEqualStrings(expected, try expander.expandFragment("Page", input, 1_670_803_200));
        const paired = try std.fmt.allocPrint(a, "<{s}>{{{{FrenchAfterMissing}}}}</{s}>", .{ name, name });
        try std.testing.expectEqualStrings(paired, try expander.expandFragment("Page", paired, 1_670_803_200));
        const spaced_pair = try std.fmt.allocPrint(a, "<{s} / >{{{{FrenchAfterMissing}}}}</{s}>", .{ name, name });
        try std.testing.expectEqualStrings(spaced_pair, try expander.expandFragment("Page", spaced_pair, 1_670_803_200));
    }
    for ([_][]const u8{ "math", "ref", "gallery", "nowiki" }) |name| {
        const attributes = try std.fmt.allocPrint(a, "<{s} data='{{{{Hello|ATTR|1}}}}'>\n{{{{FrenchAfterMissing}}}}", .{name});
        const expected = try std.fmt.allocPrint(a, "<{s} data='{{{{Hello|ATTR|1}}}}'>\n==French==\n# [[fr]]", .{name});
        try std.testing.expectEqualStrings(expected, try expander.expandFragment("Page", attributes, 1_670_803_200));
    }
    try std.testing.expectEqualStrings("<ref>==French==\n# [[fr]]</ref>", try expander.expandFragment("Page", "<ref>{{FrenchAfterMissing}}</ref>", 1_670_803_200));
    var alternating: std.ArrayList(u8) = .empty;
    var expected: std.ArrayList(u8) = .empty;
    for (0..512) |_| {
        try alternating.appendSlice(a, "<math>{{Hello|x|1}}");
        try expected.appendSlice(a, "<math>Hi x Y");
    }
    try std.testing.expectEqualStrings(expected.items, try expander.expandFragment("Page", alternating.items, 1_670_803_200));
    var roots: std.ArrayList(u8) = .empty;
    var roots_expected: std.ArrayList(u8) = .empty;
    for (0..512) |_| {
        try roots.appendSlice(a, "{{Hello|<math>x|1}}");
        try roots_expected.appendSlice(a, "Hi <math>x Y");
    }
    try std.testing.expectEqualStrings(roots_expected.items, try expander.expandFragment("Page", roots.items, 1_670_803_200));
    var failed_roots: std.ArrayList(u8) = .empty;
    for (0..512) |_| try failed_roots.appendSlice(a, "{{broken <math>tail ");
    try std.testing.expectEqualStrings(failed_roots.items, try expander.expandFragment("Page", failed_roots.items, 1_670_803_200));
}

test "native preprocessed Hiero stays protected across archived display escaping and final title restoration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.initProgram(a, 24, 1);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{rt.stabilize(TestModule.root)};
    runtime.module_root_entries = &functions;
    runtime.configureModules(null, TestModule.lookup, TestModule.name);
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists }, .install_scribunto = installTestInvoke };
    const raw = "<hiero>D35:t*y-nDs-f</hiero>";
    try std.testing.expectEqualStrings("before " ++ raw ++ " [[cat|after]]", try expander.expandFragment("jwtj.f", "before {{#invoke:Test|generated_hiero}} [[cat|after]]", 1791731560));
    try std.testing.expect(!expander.unsupported_parser_function);
    // Authored references remain raw bytes; this producer boundary does not
    // reinterpret them as MdC separators or perform an extra entity pass.
    const encoded = "<hiero>D35&#58;t&#42;y-nDs-f</hiero>";
    try std.testing.expectEqualStrings(encoded, try expander.expandFragment("Page", "{{#invoke:Test|generated_hiero|" ++ encoded ++ "}}", 1791731560));
    const doubled = "<hiero>D35&amp;#58;t&amp;#42;y-nDs-f</hiero>";
    try std.testing.expectEqualStrings(doubled, try expander.expandFragment("Page", "{{#invoke:Test|generated_hiero|" ++ doubled ++ "}}", 1791731560));
    try std.testing.expectEqualStrings(encoded, try expander.expandFragment("Page", encoded, 1791731560));
    try std.testing.expectEqualStrings("", try expander.expandFragment("Page", "{{DISPLAYTITLE:{{#invoke:Test|generated_hiero}}}}", 1791731560));
    try std.testing.expectEqualStrings(raw, expander.display_title.?);
    // Existing direct #tag and frame API serialization are not broadened.
    try std.testing.expectEqualStrings(raw, try expander.expandFragment("Page", "{{#tag:hiero|D35:t*y-nDs-f}}", 1791731560));
    const literal_api = try Expander.hostFrameExtensionTag(&expander, a, "hiero", .{ .string = "D35:t*y-nDs-f" }, null);
    try std.testing.expectEqualStrings(raw, literal_api);
}

test "Hiero general markers retain kind ownership protected domains and single restoration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists } };
    expander.beginPage("Page", "", 1791731560);
    const protected = "<nowiki><hiero>D35:t*y-nDs-f</hiero></nowiki><pre><hiero>D35:t*y-nDs-f</hiero></pre>";
    try std.testing.expectEqualStrings(protected, try expander.stripPreprocessedHiero(a, protected));
    for ([_][]const u8{ "<hiero>D35:t*y-nDs-f", "<hiero/>", "<hieroish>D35:t*y-nDs-f</hieroish>" }) |literal|
        try std.testing.expectEqualStrings(literal, try expander.stripPreprocessedHiero(a, literal));
    try std.testing.expect(expander.strip_values.count() == 0);
    const raw = "<hiero>D35:t*y-nDs-f</hiero>";
    const marker = try expander.stripPreprocessedHiero(a, raw);
    try std.testing.expect(std.mem.startsWith(u8, marker, hiero_marker_prefix));
    try std.testing.expectEqualStrings(raw, try expander.restoreHieroMarkers(a, marker));
    const mw = runtime.getGlobal(23);
    const text = try runtime.getIndex(mw, .{ .string = "text" });
    const no_wiki = try runtime.getIndex(text, .{ .string = "unstripNoWiki" });
    const untouched = try runtime.callValue(no_wiki, &.{.{ .string = marker }});
    defer rt.freeResults(untouched);
    try std.testing.expectEqualStrings(marker, untouched[0].string);
    for ([_][]const u8{ "unstrip", "killMarkers" }) |name| {
        const call = try runtime.getIndex(text, .{ .string = name });
        const killed = try runtime.callValue(call, &.{.{ .string = marker }});
        defer rt.freeResults(killed);
        try std.testing.expectEqualStrings("", killed[0].string);
    }
    const nowiki = try Expander.hostFrameExtensionTag(&expander, a, "nowiki", .{ .string = "literal" }, null);
    const wrong_general = try std.fmt.allocPrint(a, "{s}{X:0>8}{s}", .{ hiero_marker_prefix, @as(u32, 1), nowiki_marker_suffix });
    try std.testing.expectEqualStrings(wrong_general, try expander.restoreHieroMarkers(a, wrong_general));
    const wrong_nowiki = try makeNowikiMarker(a, 0);
    try std.testing.expectEqualStrings(wrong_nowiki, try Expander.hostTextUnstripNoWiki(&expander, a, wrong_nowiki));
    try std.testing.expectEqualStrings("literal", try Expander.hostTextUnstripNoWiki(&expander, a, nowiki));
    const unknown = try std.fmt.allocPrint(a, "{s}FFFFFFFF{s}", .{ hiero_marker_prefix, nowiki_marker_suffix });
    try std.testing.expectEqualStrings(unknown, try expander.restoreHieroMarkers(a, unknown));
    const nested_source = try std.fmt.allocPrint(a, "<hiero>{s}</hiero>", .{marker});
    const nested_marker = try expander.stripPreprocessedHiero(a, nested_source);
    try std.testing.expectEqualStrings(nested_source, try expander.restoreHieroMarkers(a, nested_marker));
    expander.beginPage("Next", "", 1791731560);
    try std.testing.expect(expander.strip_values.count() == 0);
    try std.testing.expectEqualStrings(marker, try expander.restoreHieroMarkers(a, marker));
}

const NowikiReturnProbe = struct {
    fn lookup(_: ?*const anyopaque, module_name: []const u8) ?u32 {
        return if (std.mem.eql(u8, module_name, "Module:NowikiReturnProbe")) 0 else null;
    }
    fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
        return if (id == 0) "Module:NowikiReturnProbe" else null;
    }
    fn root(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        const exports = try ctx.newTable();
        try exports.rawSet(ctx.allocator, .{ .string = "show" }, try ctx.makeFunctionKnown(1, show, &.{}));
        const values = try std.heap.smp_allocator.alloc(Value, 1);
        values[0] = .{ .table = exports };
        return values;
    }
    const literal = "[[cat|hidden]] {{#if:x|must-stay-literal|bad}} </nowiki> __NOTOC__ A&amp;B&#58;&amp;#58;\nC";
    fn show(ctx: *rt.Context, _: rt.Captures, args: []const Value) ![]const Value {
        const params = try ctx.getIndex(args[0], .{ .string = "args" });
        const mode = try ctx.getIndex(params, .{ .number = 1 });
        if (mode != .string) return error.StringExpected;
        var body: []const u8 = literal;
        if (!std.mem.eql(u8, mode.string, "plain")) {
            const call = try ctx.getIndex(args[0], .{ .string = "preprocess" });
            const general = try ctx.callValue(call, &.{ args[0], .{ .string = "<hiero>D35:t*y-nDs-f</hiero>" } });
            defer rt.freeResults(general);
            body = if (std.mem.eql(u8, mode.string, "unstrip"))
                try std.fmt.allocPrint(ctx.allocator, "left {s} right", .{general[0].string})
            else
                try std.mem.concat(ctx.allocator, u8, &.{ "left&#58;&amp;#58;\n", general[0].string, " right [[hidden]] {{#if:x|literal|bad}} </nowiki>" });
        }
        const tag = try ctx.getIndex(args[0], .{ .string = "extensionTag" });
        const wrapped = try ctx.callValue(tag, &.{ args[0], .{ .string = "nowiki" }, .{ .string = body } });
        defer rt.freeResults(wrapped);
        var returned = wrapped[0];
        if (std.mem.eql(u8, mode.string, "unstrip")) {
            const text = try ctx.getIndex(ctx.getGlobal(23), .{ .string = "text" });
            const call = try ctx.getIndex(text, .{ .string = "unstripNoWiki" });
            const result = try ctx.callValue(call, &.{returned});
            defer rt.freeResults(result);
            returned = .{ .string = try ctx.allocator.dupe(u8, result[0].string) };
        }
        const values = try std.heap.smp_allocator.alloc(Value, 1);
        values[0] = .{ .string = try ctx.allocator.dupe(u8, returned.string) };
        return values;
    }
};

test "direct nowiki API returns finalize protected text and prior general hook results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.initProgram(a, 24, 1);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{rt.stabilize(NowikiReturnProbe.root)};
    runtime.module_root_entries = &functions;
    runtime.configureModules(null, NowikiReturnProbe.lookup, NowikiReturnProbe.name);
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists }, .install_scribunto = installTestInvoke };
    // Existing explicit API control works without requiring final nowiki unstrip.
    const explicit = try expander.expandFragment("Page", "{{#invoke:NowikiReturnProbe|show|unstrip}}", 1791731560);
    try std.testing.expectEqualStrings("left <hiero>D35:t*y-nDs-f</hiero> right", explicit);
    for ([_][]const u8{ "plain", "wrapped" }) |mode| {
        const source = try std.mem.concat(a, u8, &.{ "{{#invoke:NowikiReturnProbe|show|", mode, "}}" });
        const expanded = try expander.expandFragment("Page", source, 1791731560);
        errdefer std.debug.print("nowiki finalization mode {s}: {s}\n", .{ mode, expanded });
        try std.testing.expect(std.mem.indexOf(u8, expanded, nowiki_marker_prefix) == null);
        try std.testing.expect(std.mem.indexOf(u8, expanded, hiero_marker_prefix) == null);
        try std.testing.expect(expander.poem_metadata != null);
        const metadata = try std.json.parseFromSlice(std.json.Value, a, expander.poem_metadata.?, .{});
        defer metadata.deinit();
        const items = metadata.value.object.get("items").?.array.items;
        if (std.mem.eql(u8, mode, "plain")) {
            try std.testing.expectEqual(@as(usize, 1), items.len);
            try std.testing.expectEqualStrings("nowiki", items[0].object.get("tag").?.string);
            try std.testing.expectEqualStrings(NowikiReturnProbe.literal, items[0].object.get("body").?.string);
            try std.testing.expect(std.mem.indexOf(u8, expanded, "[[cat|hidden]]") == null);
        } else {
            try std.testing.expectEqual(@as(usize, 2), items.len);
            try std.testing.expectEqualStrings("left&#58;&amp;#58;\n", items[0].object.get("body").?.string);
            try std.testing.expectEqualStrings(" right [[hidden]] {{#if:x|literal|bad}} </nowiki>", items[1].object.get("body").?.string);
            try std.testing.expect(std.mem.indexOf(u8, expanded, "<hiero>D35:t*y-nDs-f</hiero>") != null);
        }
        try std.testing.expect(!expander.unsupported_parser_function);
    }
}

test "captured statistics aliases format all seven counters and preserve raw zero" {
    const aliases = rt.namespace_registry.magic_words;
    const Source = struct {
        words: *const aliases.Registry,
        fn resolve(raw: ?*anyopaque, name: []const u8, form: aliases.Form) !?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.words.resolve(name, form);
        }
        fn parser(raw: ?*anyopaque, name: []const u8) !?[]const u8 {
            return resolve(raw, name, .parser_function);
        }
        fn get(_: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
            if (std.mem.eql(u8, title, "Template:NUMBEROFARTICLES")) return "ordinary-template";
            return null;
        }
        fn exists(_: ?*anyopaque, _: []const u8) !bool {
            return true;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var words = try aliases.Registry.init(a, aliases.parser_header ++ "\n# wiki\tabwiktionary\n# dump-date\t20261001\n# content-language\tab\n" ++
        "numberofpages\t1\tNUMBEROFPAGES\nnumberofarticles\t1\tNUMBEROFARTICLES\nnumberofarticles\t1\tКОЛИЧЕСТВО_СТАТЕЙ\n" ++
        "numberoffiles\t1\tNUMBEROFFILES\nnumberofedits\t1\tNUMBEROFEDITS\nnumberofusers\t1\tNUMBEROFUSERS\n" ++
        "numberofactiveusers\t1\tNUMBEROFACTIVEUSERS\nnumberofadmins\t1\tNUMBEROFADMINS\n", "abwiktionary", "20261001", "ab");
    defer words.deinit();
    var source: Source = .{ .words = &words };
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .ctx = &source, .get = Source.get, .exists = Source.exists, .resolve_title_magic = Source.resolve, .resolve_parser_function = Source.parser, .site_statistics = .{ 248, 0, 1234, 8985, 651, 0, 1 }, .site_statistics_formatted = .{ "248", "0", "1,234", "8,985", "651", "0", "1" } } };
    try std.testing.expectEqualStrings("248|0|0|1,234|8,985|651|0|1", try expander.expandFragment("Notice", "{{NUMBEROFPAGES}}|{{NUMBEROFARTICLES}}|{{КОЛИЧЕСТВО_СТАТЕЙ}}|{{NUMBEROFFILES}}|{{NUMBEROFEDITS}}|{{NUMBEROFUSERS}}|{{NUMBEROFACTIVEUSERS}}|{{NUMBEROFADMINS}}", 1_670_803_200));
    try std.testing.expectEqualStrings("1234|0|ordinary-template", try expander.expandFragment("Notice", "{{NUMBEROFFILES:R}}|{{КОЛИЧЕСТВО_СТАТЕЙ: R }}|{{NUMBEROFARTICLES|x}}", 1_670_803_200));
    const args = try runtime.newTable();
    try args.rawSet(a, .{ .number = 1 }, .{ .string = "R" });
    try std.testing.expectEqualStrings("1234", try Expander.hostFrameParserFunction(&expander, a, "NUMBEROFFILES", args));
    try std.testing.expect((words.resolve("numberofarticles", .variable)) == null);
    expander.provider.site_statistics_formatted = .{ "248", "0", "۱٬۲۳۴", "8.985", "651", "0", "1" };
    try std.testing.expectEqualStrings("۱٬۲۳۴|8.985|1234", try expander.expandFragment("Notice", "{{NUMBEROFFILES}}|{{NUMBEROFEDITS}}|{{NUMBEROFFILES:R}}", 1_670_803_200));
    expander.provider.site_statistics_formatted = null;
    try std.testing.expectError(error.SiteStatisticsFormatSnapshotMissing, expander.expandFragment("Notice", "{{NUMBEROFFILES}}", 1_670_803_200));
    try std.testing.expectEqualStrings("1234", try expander.expandFragment("Notice", "{{NUMBEROFFILES:R}}", 1_670_803_200));
    expander.provider.site_statistics = null;
    try std.testing.expectError(error.SiteInfoSnapshotMissing, expander.expandFragment("Notice", "{{NUMBEROFARTICLES}}", 1_670_803_200));
    try std.testing.expectEqualStrings("Site statistics snapshot missing field=numberofarticles", runtime.last_error.string);
    // The old profile assertions above still exercise exact R without any
    // rawsuffix rows. Add captured Arabic token spellings in a separate profile.
    var raw_words = try aliases.Registry.init(a, aliases.parser_header ++ "\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
        "numberoffiles\t1\tNUMBEROFFILES\nrawsuffix\t1\tأر\nrawsuffix\t1\tآر\nrawsuffix\t1\tR\n", "arwiktionary", "20261001", "ar");
    defer raw_words.deinit();
    source.words = &raw_words;
    expander.provider.raw_suffix_profile = true;
    expander.provider.site_statistics = .{ 248, 0, 1234, 8985, 651, 0, 1 };
    expander.provider.site_statistics_formatted = .{ "248", "0", "1٬234", "8٬985", "651", "0", "1" };
    try std.testing.expectEqualStrings("1234|1234|1234|1٬234|1٬234", try expander.expandFragment("Notice", "{{NUMBEROFFILES:أر}}|{{NUMBEROFFILES: آر }}|{{NUMBEROFFILES:R}}|{{NUMBEROFFILES:r}}|{{NUMBEROFFILES:unknown}}", 1_670_803_200));
    try args.rawSet(a, .{ .number = 1 }, .{ .string = "آر" });
    try std.testing.expectEqualStrings("1234", try Expander.hostFrameParserFunction(&expander, a, "NUMBEROFFILES", args));
    try args.rawSet(a, .{ .number = 1 }, .{ .string = "r" });
    try std.testing.expectEqualStrings("1٬234", try Expander.hostFrameParserFunction(&expander, a, "NUMBEROFFILES", args));
    var lower_words = try aliases.Registry.init(a, aliases.parser_header ++ "\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
        "numberoffiles\t1\tNUMBEROFFILES\nrawsuffix\t1\tr\n", "arwiktionary", "20261001", "ar");
    defer lower_words.deinit();
    source.words = &lower_words;
    try std.testing.expectEqualStrings("1٬234|1234", try expander.expandFragment("Notice", "{{NUMBEROFFILES:R}}|{{NUMBEROFFILES:r}}", 1_670_803_200));
    expander.provider.resolve_title_magic = null;
    try std.testing.expectError(error.RawSuffixSnapshotMissing, expander.expandFragment("Notice", "{{NUMBEROFFILES:R}}", 1_670_803_200));
}

fn ordinaryLoopTestMessage(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, key: []const u8) !?Provider.InterfaceMessage {
    if (std.mem.eql(u8, key, "parser-template-loop-warning")) return .{ .source = "Fixture loop: $1" };
    return null;
}

const OrdinaryLoopRegression = struct {
    const aliases = rt.namespace_registry.magic_words;
    words: ?*const aliases.Registry = null,
    message_available: bool = true,
    pagename_reads: usize = 0,
    loop_warnings: usize = 0,
    fn resolve(raw: ?*anyopaque, name: []const u8, form: aliases.Form) !?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        return (self.words orelse return null).resolve(name, form);
    }
    fn message(raw: ?*anyopaque, _: std.mem.Allocator, _: []const u8, key: []const u8) !?Provider.InterfaceMessage {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        if (!self.message_available) return null;
        if (std.mem.eql(u8, key, "parser-template-loop-warning")) {
            self.loop_warnings += 1;
            return .{ .source = "حلقة قالب: $1" };
        }
        return null;
    }
    fn get(raw: ?*anyopaque, a: std.mem.Allocator, title: []const u8) !?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        if (std.mem.eql(u8, title, "Template:Loop")) return "before{{Loop}}after";
        if (std.mem.eql(u8, title, "Template:Final")) return "pre{{Alias}}post";
        if (std.mem.eql(u8, title, "Template:A")) return "a{{B}}z";
        if (std.mem.eql(u8, title, "Template:B")) return "b{{A}}y";
        if (std.mem.eql(u8, title, "Template:Echo")) return "{{{1|EMPTY}}}";
        if (std.mem.eql(u8, title, "Template:Named")) return "{{{x|EMPTY}}}";
        if (std.mem.eql(u8, title, "Template:Unused")) return "SAFE";
        if (std.mem.startsWith(u8, title, "Template:Depth")) {
            const n = try std.fmt.parseInt(usize, title[14..], 10);
            return if (n < 12) try std.fmt.allocPrint(a, "{{{{Depth{d}}}}}", .{n + 1}) else "END";
        }
        if (std.mem.eql(u8, title, "قالب:اسم الصفحة")) {
            self.pagename_reads += 1;
            // Exact captured page162072/revision751114,165 decoded bytes.
            return "{{#if:{{{1|}}}|{{اسم_الصفحة:{{{1|}}}}}|{{اسم_الصفحة}}}}<includeonly>[[{{اسم الصفحة}}]]</includeonly><noinclude>\n{{توثيق}}</noinclude>";
        }
        // Actual en-noun ordinary-template tail; only the unrelated Lua head
        // call is replaced with a controlled marker, not claimed as executed.
        if (std.mem.eql(u8, title, "قالب:en-noun")) return "ENHEAD<!--\n\n-->{{#switch:{{namespace}}-{{pagename}}|-{{{1}}}|-{{{2}}}=[[تصنيف:english invariant nouns]]}}<!--\n\n-->{{#if:{{{sg|}}}|[[تصنيف:headword-line template with deprecated head parameter]]}}<!--\n-->{{#if:{{{sort|}}}|[[تصنيف:codecat's test category]]}}<!--\n\n-->{{#ifeq:{{{2|}}}|-|[[تصنيف:codecat's test category]]}}<!--\n-->{{#ifeq:{{{3|}}}|-|[[تصنيف:codecat's test category]]}}<!--\n-->{{#ifeq:{{{4|}}}|-|[[تصنيف:codecat's test category]]}}<!--\n\n--><noinclude>{{documentation}}</noinclude>";
        if (std.mem.eql(u8, title, "قالب:namespace")) return "";
        if (std.mem.eql(u8, title, "قالب:fi-noun"))
            // Exact captured page162227/revision949259,270 decoded bytes.
            return "{{head|fi|{{#ifeq:{{{proper|}}}|true|proper nouns|nouns}}|head={{{head|{{{sg|{{pagename}}}}}}}}|sort={{{sort|}}}<!--\n-->|g={{#if:{{{plonly|}}}|p}}|cat2={{#if:{{{plonly|}}}|pluralia tantum}}}}<noinclude>{{documentation}}[[تصنيف:finnish headword-line templates|noun]]";
        // Controlled consumer for the actual fi-noun lazy head default. The
        // captured Lua/module head implementation is outside this native fixture.
        if (std.mem.eql(u8, title, "قالب:head")) return "HEAD={{{head|NONE}}}";
        return null;
    }
    fn body(raw: ?*anyopaque, a: std.mem.Allocator, title: []const u8) !?Provider.TransclusionBody {
        const final = if (std.mem.eql(u8, title, "Template:Alias")) "Template:Final" else if (std.mem.eql(u8, title, "قالب:pagename")) "قالب:اسم الصفحة" else title;
        const text = (try get(raw, a, final)) orelse return null;
        return .{ .text = try preprocess.transcludeDecodedForParsingAlloc(a, text), .title = final, .borrowed = false };
    }
    fn symbol(_: ?*anyopaque, _: *rt.Context, name: []const u8, kind: CallSymbolKind) !?CallSymbol {
        return if (kind == .template and std.mem.eql(u8, name, "SymbolLoop")) .{ .id = 99, .text = "Loop" } else null;
    }
    fn symbolBody(_: ?*anyopaque, _: std.mem.Allocator, id: usize) !?[]const u8 {
        return if (id == 99) "before{{SymbolLoop}}after" else null;
    }
};

test "ordinary template cycles emit localized warnings in place and unwind for siblings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var source: OrdinaryLoopRegression = .{};
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .ctx = &source, .get = OrdinaryLoopRegression.get, .exists = TestProvider.exists, .interface_message = OrdinaryLoopRegression.message } };
    const loop = "before<span class=\"error\">حلقة قالب: Template:Loop</span>after";
    const expected = try std.fmt.allocPrint(a, "{s}|{s}\n# RETAINED DEFINITION", .{ loop, loop });
    try std.testing.expectEqualStrings(expected, try expander.expandFragment("Page", "{{Loop}}|{{Loop}}\n# RETAINED DEFINITION", 1_670_803_200));
    try std.testing.expectEqualStrings("ab<span class=\"error\">حلقة قالب: Template:A</span>yz", try expander.expandFragment("Page", "{{A}}", 1_670_803_200));
    try std.testing.expectEqual(@as(usize, 0), expander.template_depth);
    try std.testing.expect(expander.transclusion_frame == null);
    expander.provider.resolve_call_symbol = OrdinaryLoopRegression.symbol;
    expander.provider.get_template_symbol = OrdinaryLoopRegression.symbolBody;
    try std.testing.expectEqualStrings(loop, try expander.expandFragment("Page", "{{SymbolLoop}}", 1_670_803_200));
    source.message_available = false;
    try std.testing.expectError(error.InterfaceMessageSnapshotMissing, expander.expandFragment("Page", "{{Loop}}", 1_670_803_200));
    try std.testing.expectEqual(@as(usize, 0), expander.template_depth);
    try std.testing.expect(expander.transclusion_frame == null);
    source.message_available = true;
    try std.testing.expectEqualStrings("OK", try expander.expandFragment("Page", "{{Echo|OK}}", 1_670_803_200));
}

test "ordinary redirected template cycles check final title and retain requested warning title" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var source: OrdinaryLoopRegression = .{};
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .ctx = &source, .get = OrdinaryLoopRegression.get, .exists = TestProvider.exists, .get_transclusion_body = OrdinaryLoopRegression.body, .interface_message = OrdinaryLoopRegression.message } };
    const one = "pre<span class=\"error\">حلقة قالب: Template:Alias</span>post";
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}|{s}|TAIL", .{ one, one }), try expander.expandFragment("Page", "{{Alias}}|{{Alias}}|TAIL", 1_670_803_200));
    try std.testing.expect(expander.transclusion_frame == null);
    try std.testing.expectEqual(@as(usize, 0), expander.template_depth);
}

test "ordinary lazy arguments expand in caller ancestry without weakening physical depth limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var source: OrdinaryLoopRegression = .{};
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .ctx = &source, .get = OrdinaryLoopRegression.get, .exists = TestProvider.exists, .interface_message = OrdinaryLoopRegression.message } };
    try std.testing.expectEqualStrings("  ok  |trim|SAFE|end", try expander.expandFragment("Page", "{{Echo|{{Echo|  ok  }}}}|{{Named|x=  {{Named|x=trim}}  }}|{{Unused|{{Loop}}}}|{{Echo|end}}", 1_670_803_200));
    expander.max_template_depth = 3;
    try std.testing.expectError(error.TemplateDepth, expander.expandFragment("Page", "{{Depth0}}", 1_670_803_200));
    try std.testing.expectEqual(@as(usize, 0), expander.template_depth);
    try std.testing.expect(expander.transclusion_frame == null);
    try std.testing.expectEqual(@as(usize, 0), expander.lazy_template_args.items.len);
    expander.max_template_depth = 128;
    try std.testing.expectEqualStrings("after-error", try expander.expandFragment("Page", "{{Echo|after-error}}", 1_670_803_200));
}

test "captured Arabic pagename self loop preserves magic distinction lazy fi defaults and following definitions" {
    const aliases = rt.namespace_registry.magic_words;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var namespaces = try rt.namespace_registry.Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n10\tقالب\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n14\tتصنيف\tCategory\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    var words = try aliases.Registry.init(a, aliases.header ++ "\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\npagename\t1\tاسم_الصفحة\npagename\t1\tPAGENAME\n", "arwiktionary", "20261001", "ar");
    defer words.deinit();
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    runtime.namespace_catalog = &namespaces;
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var source: OrdinaryLoopRegression = .{ .words = &words };
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .ctx = &source, .get = OrdinaryLoopRegression.get, .exists = TestProvider.exists, .get_transclusion_body = OrdinaryLoopRegression.body, .resolve_title_magic = OrdinaryLoopRegression.resolve, .interface_message = OrdinaryLoopRegression.message } };
    const wrapper = "word[[<span class=\"error\">حلقة قالب: قالب:اسم الصفحة</span>]]";
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "word|{s}\n# RETAINED DEFINITION", .{wrapper}), try expander.expandFragment("word", "{{اسم_الصفحة}}|{{pagename}}\n# RETAINED DEFINITION", 1_670_803_200));
    source.loop_warnings = 0;
    try std.testing.expectEqualStrings("ENHEAD\n# EN DEFINITION", try expander.expandFragment("word", "{{en-noun}}\n# EN DEFINITION", 1_670_803_200));
    try std.testing.expectEqual(@as(usize, 1), source.loop_warnings);
    source.pagename_reads = 0;
    try std.testing.expectEqualStrings("HEAD=explicit\n# FI DEFINITION", try expander.expandFragment("word", "{{fi-noun|head=explicit}}\n# FI DEFINITION", 1_670_803_200));
    try std.testing.expectEqual(@as(usize, 0), source.pagename_reads);
    const fi_expected = try std.fmt.allocPrint(a, "HEAD={s}\n# FI DEFINITION", .{wrapper});
    try std.testing.expectEqualStrings(fi_expected, try expander.expandFragment("word", "{{fi-noun}}\n# FI DEFINITION", 1_670_803_200));
    try std.testing.expectEqual(@as(usize, 0), expander.template_depth);
    try std.testing.expect(expander.transclusion_frame == null);
}

const UsageRecoveryTest = struct {
    fn lookup(_: ?*const anyopaque, module_name: []const u8) ?u32 {
        return if (std.mem.eql(u8, module_name, "Module:usex")) 0 else null;
    }
    fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
        return if (id == 0) "Module:usex" else null;
    }
    fn root(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        const exports = try ctx.newTable(); // Exact failure class: no display export.
        return std.heap.smp_allocator.dupe(Value, &.{.{ .table = exports }});
    }
    fn get(ctx: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
        if (std.mem.eql(u8, title, "Template:ux") or std.mem.eql(u8, title, "Template:usex") or std.mem.eql(u8, title, "Template:Other"))
            return "{{#invoke:usex|display|short=1}}<noinclude>{{documentation}}</noinclude>";
        if (std.mem.eql(u8, title, "Template:Counter")) {
            const reads: *usize = @ptrCast(@alignCast(ctx.?));
            reads.* += 1;
            return "[[counted|Counted]]";
        }
        // Exact captured child page157504/revision583504, not a stubbed success.
        if (std.mem.eql(u8, title, "Template:خط/عربي")) return "<span class=\"script-arabic\">{{{2|{{{1|العربية}}}}}}</span><noinclude>{{توثيق}}</noinclude>";
        // Exact captured quotation page212527/revision988290.
        if (std.mem.eql(u8, title, "Template:اقتباس 2")) return "{| style=\"margin:auto; border-collapse:collapse; border-style:none; background-color:{{{bgcolor|transparent}}}; {{\n#if: {{{bgcolor|}}}\n  | border: 1px solid #AAAAAA;\n}}\" class=\"cquote\"\n| width=\"20\" valign=\"top\" style=\"color:#B2B7F2;font-size:{{#switch:{{{size|{{{2|{{{quotewidth|{{{width|20px}}}}}}}}}}}}\n|10px=20px\n|30px=60px\n|40px=80px\n|50px=100px\n|60px=120px\n|#default=35px}};font-family:'Times New Roman',serif;font-weight:bold;text-align:left;padding:10px 10px;\" | ”\n| class=\"citationTemplate\" valign=\"top\" style=\"padding:4px 10px;font-size:115%\" | {{خط/عربي|{{{1|اكتب النص هنا بدون علامات الاقتباس.}}}}}\n| width=\"20\" valign=\"bottom\" style=\"color:#B2B7F2;font-size:{{#switch:{{{size|{{{2|{{{quotewidth|{{{width|20px}}}}}}}}}}}}\n|10px=20px\n|30px=60px\n|40px=80px\n|50px=100px\n|60px=120px\n|#default=36px}};font-family:'Times New Roman',serif;font-weight:bold;text-align:right;padding:10px 10px;\" | “\n|-\n{{#if:{{{4|}}}{{{5|}}}|\n{{!}} colspan=\"3\" style=\"padding-right: 4%\" {{!}} {{#if:{{{4|<noinclude>Origin</noinclude>}}}|<p style=\"font-size:smaller;text-align: right\"><cite style=\"font-style:normal;\">—{{{4}}}{{#if:{{{5|<noinclude>Source</noinclude>}}}|, {{{5}}}}}</cite></p>}}\n}}\n|}<noinclude>\n[[تصنيف:قوالب]]\n</noinclude>";
        return null;
    }
    fn exists(_: ?*anyopaque, title: []const u8) !bool {
        // Existence must not fetch content or increment the Counter fixture.
        inline for (.{ "Template:ux", "Template:usex", "Template:Other", "Template:Counter", "Template:خط/عربي", "Template:اقتباس 2" }) |known| {
            if (std.mem.eql(u8, title, known)) return true;
        }
        return false;
    }
    fn setup(runtime: *rt.Context, reads: *usize) !Expander {
        const functions = struct {
            const entries = [_]rt.FunctionFn{rt.stabilize(root)};
        };
        runtime.module_root_entries = &functions.entries;
        runtime.configureModules(null, lookup, name);
        try rt.bindGlobalTable(runtime, null, 0);
        try stdlib.install(runtime);
        return .{ .runtime = runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .ctx = reads, .get = get, .exists = exists }, .install_scribunto = installTestInvoke };
    }
};

test "typed missing usage export preserves six captured examples including nested quotation table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 24, 1);
    defer runtime.deinit();
    var reads: usize = 0;
    var expander = try UsageRecoveryTest.setup(&runtime, &reads);
    for ([_][]const u8{
        "{{#invoke:usex|display|short=1}}",
        "{{#invoke:usex|display|short=1}}<noinclude/>",
        " \n<noinclude/> <noinclude/>{{#invoke:usex|display|short=1}} <noinclude/>\t<noinclude/>\n",
        "<NoInclude/>{{#invoke:usex|display|short=1}}<noinclude />",
        "<noinclude attr=x/>{{#invoke:usex|display|short=1}}<NOINCLUDE attr='x'/>",
    }) |body| try std.testing.expect(Expander.isUsageRecoveryWrapper(body));
    for ([_][]const u8{
        "<noinclude/>",
        "{<noinclude/>{#invoke:usex|display|short=1}}",
        "{{#invoke:usex|display|short=<noinclude/>1}}",
        "{{#invoke:usex|display|short=<NoInclude attr=x/>1}}",
        "{{#invoke:usex|display|short=1}}<noinclude/>extra",
        "extra<noinclude/>{{#invoke:usex|display|short=1}}",
        "{{#invoke:other|display|short=1}}<noinclude/>",
        "{{#invoke:usex|other|short=1}}<noinclude/>",
        "{{#invoke:usex|display|short=2}}<noinclude/>",
        "{{#invoke:usex|display|short=1|extra=1}}<noinclude/>",
        "{{#invoke:usex|display|short=1}}<noinclude>extra</noinclude>",
        "{{#invoke:usex|display|short=1}}<noinclude/ >",
        "{{#invoke:usex|display|short=1}}</noinclude>",
    }) |body| try std.testing.expect(!Expander.isUsageRecoveryWrapper(body));
    const cases = [_]struct { source: []const u8, expected: []const u8, recovered: bool = true }{
        .{ .source = "{{ux|en|Their '''encounter''' was a matter of chance.}}", .expected = "Their '''encounter''' was a matter of chance.", .recovered = true },
        .{ .source = "{{ux|de|Gibt es einen '''Zusammenhang''' zwischen Freiheit und Wohlstand| هل هناك '''علاقة''' بين الحرية والرفاه}}", .expected = "هل هناك '''علاقة''' بين الحرية والرفاه", .recovered = true },
        .{ .source = "{{ux|en|'''incite''' people to violence\n{{اقتباس 2|حرِّض الناس على العنف}}}}", .expected = "حرِّض الناس على العنف", .recovered = true },
        .{ .source = "{{ux|en|'''Lemme''' go!}}", .expected = "'''Lemme''' go!", .recovered = true },
        .{ .source = "{{ux|en|Hey, '''lemme''' see that bag. What’s in there?}}", .expected = "What’s in there?", .recovered = true },
        .{ .source = "{{ux|en|'''Gimme''' the ball.}}", .expected = "'''Gimme''' the ball.", .recovered = true },
    };
    for (cases) |case| {
        const expanded = try expander.expandFragment("Actual usage example", case.source, 1_670_803_200);
        try std.testing.expect((std.mem.indexOf(u8, expanded, "<i class=\"e-example\"") != null) == case.recovered);
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, expanded, "Lua error in Module:usex: The function \"display\" does not exist."));
        if (case.recovered) try std.testing.expect(std.mem.indexOf(u8, expanded, case.expected) != null);
        if (std.mem.indexOf(u8, case.source, "incite") != null) {
            try std.testing.expect(std.mem.indexOf(u8, expanded, "{|") != null and std.mem.indexOf(u8, expanded, "|}") != null);
            try std.testing.expect(std.mem.indexOf(u8, expanded, "<span class=\"script-arabic\">حرِّض الناس على العنف</span>") != null);
            try std.testing.expect(std.mem.indexOf(u8, expanded, "{{") == null);
        }
        try std.testing.expect(expander.usage_recovery == null and runtime.current_frame == null);
    }
}

test "typed usage recovery preserves last wins links and single expansion while declining unsupported args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 24, 1);
    defer runtime.deinit();
    var reads: usize = 0;
    var expander = try UsageRecoveryTest.setup(&runtime, &reads);
    const once = try expander.expandFragment("Page", "{{ux|en|{{Counter}}|translation=Translated|tr=tr|q=old|q=[[rare|rare]]|qq=[[regional|regional]]}}", 1_670_803_200);
    try std.testing.expectEqual(@as(usize, 1), reads);
    try std.testing.expect(std.mem.indexOf(u8, once, "[[counted|Counted]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, once, "q=old") == null);
    try std.testing.expect(std.mem.indexOf(u8, once, "([[rare|rare]])</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, once, "([[regional|regional]])</span>") != null);
    reads = 0;
    const overwritten = try expander.expandFragment("Page", "{{ux|en|2={{Counter}}|2=[[last|Last]]|q=old|q=|qq=old|qq=}}", 1_670_803_200);
    try std.testing.expectEqual(@as(usize, 0), reads);
    try std.testing.expect(std.mem.indexOf(u8, overwritten, "<i class=\"e-example\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, overwritten, "[[last|Last]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, overwritten, "q=old") == null);
    for ([_][]const u8{
        "{{ux|en|Example|4=extra}}",  "{{ux|en|Example|unknown=extra}}",
        "{{ux|en|Example|unknown=}}", "{{ux|en|Example|sc=Latn}}",
        "{{Other|en|Example}}",       "{{#invoke:usex|display|short=1}}",
    }) |source| {
        const declined = try expander.expandFragment("Page", source, 1_670_803_200);
        try std.testing.expect(std.mem.indexOf(u8, declined, "<i class=\"e-example\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, declined, "Lua error in Module:usex:") != null);
    }
}

test "parser URLs and server magic use captured edition metadata without English fallback" {
    const Purge = struct {
        fn get(_: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
            // Verbatim captured AR template page161412 revision753650.
            if (std.mem.eql(u8, title, "Template:إفراغ الكاش")) return "<span class=\"noprint plainlinks purgelink\">[{{fullurl:{{{page|{{FULLPAGENAME}}}}}|action=purge}} <span title=\"إفراغ كاش الصفحة\">{{{1|إفراغ الكاش}}}</span>]</span><noinclude>\n[[تصنيف:قوالب|{{اسم_الصفحة}}]]\n</noinclude>";
            return null;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 24);
    defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = Purge.get, .exists = TestProvider.exists } };
    const cases = [_]struct { server: []const u8, name: []const u8 }{
        .{ .server = "//ar.wiktionary.org", .name = "ar.wiktionary.org" },
        .{ .server = "//en.wiktionary.org", .name = "en.wiktionary.org" },
        .{ .server = "https://captured.example", .name = "captured.example" },
    };
    for (cases) |case| {
        expander.provider.site_server = case.server;
        expander.provider.site_script = "/w/index.php";
        expander.provider.site_article_path = "/wiki/$1";
        const magic = try expander.expandFragment("Page", "{{SERVER}}|{{SERVERNAME}}", 1_670_803_200);
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(arena.allocator(), "{s}|{s}", .{ case.server, case.name }), magic);
        const full = try expander.expandFragment("Page", "{{fullurl:A B#Frag|action=edit&section=0}}", 1_670_803_200);
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(arena.allocator(), "{s}/w/index.php?title=A_B&action=edit&section=0#Frag", .{case.server}), full);
        const purge = try expander.expandFragment("بوابة:النحو والإعراب", "{{إفراغ الكاش|حدّث محتوى الصفحة}}", 1_670_803_200);
        const actual_action = try std.fmt.allocPrint(arena.allocator(), "[{s}/w/index.php?title=%D8%A8%D9%88%D8%A7%D8%A8%D8%A9:%D8%A7%D9%84%D9%86%D8%AD%D9%88_%D9%88%D8%A7%D9%84%D8%A5%D8%B9%D8%B1%D8%A7%D8%A8&action=purge ", .{case.server});
        try std.testing.expect(std.mem.indexOf(u8, purge, actual_action) != null);
        try std.testing.expect(std.mem.indexOf(u8, purge, "حدّث محتوى الصفحة</span>") != null);
    }
    expander.provider.site_server = "https://captured.example";
    expander.provider.site_script = "/custom/run.php";
    expander.provider.site_article_path = "/view/$1/end?lang=x";
    try std.testing.expectEqualStrings("/view/A_B/end?lang=x#Frag", try expander.expandFragment("Page", "{{localurl:A B#Frag}}", 1_670_803_200));
    try std.testing.expectEqualStrings("/custom/run.php?title=A_B&action=edit&section=0", try expander.expandFragment("Page", "{{localurl:A B|action=edit&section=0}}", 1_670_803_200));
    try std.testing.expectEqualStrings("https://captured.example/view/A_B/end?lang=x#Frag", try expander.expandFragment("Page", "{{canonicalurl:A B#Frag}}", 1_670_803_200));
    try std.testing.expectEqualStrings("https://captured.example/custom/run.php?title=A_B&amp;action=edit&amp;section=0", try expander.expandFragment("Page", "{{fullurle:A B|action=edit&section=0}}", 1_670_803_200));
    expander.provider.site_server = null;
    for ([_][]const u8{ "{{SERVER}}", "{{SERVERNAME}}", "{{fullurl:A}}", "{{localurl:A}}" }) |input|
        try std.testing.expectError(error.SiteInfoSnapshotMissing, expander.expandFragment("Page", input, 1_670_803_200));
}

test "category count parser uses captured aliases counts title scope and exact formatting" {
    const aliases = rt.namespace_registry.magic_words;
    const Source = struct {
        words: *const aliases.Registry,
        last_key: []const u8 = "",
        fail: bool = false,
        ignored_reads: usize = 0,
        fn get(raw: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (std.mem.eql(u8, title, "Template:Ignored")) self.ignored_reads += 1;
            return "ordinary-template";
        }
        fn exists(_: ?*anyopaque, _: []const u8) !bool {
            return false;
        }
        fn resolve(raw: ?*anyopaque, value: []const u8, form: aliases.Form) !?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.words.resolve(value, form);
        }
        fn parser(raw: ?*anyopaque, value: []const u8) !?[]const u8 {
            return resolve(raw, value, .parser_function);
        }
        fn stats(raw: ?*anyopaque, key: []const u8) !?Provider.CategoryStats {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.fail) return error.TestCategoryReadFailure;
            self.last_key = key;
            if (std.mem.eql(u8, key, "صفحات_للحذف_السريع")) return .{ .all = 3428, .subcats = 3389, .files = 0 };
            if (std.mem.eql(u8, key, "English_nouns")) return .{ .all = 25, .subcats = 3, .files = 2 };
            return null;
        }
        fn formatted(_: ?*anyopaque, count: u32) !?[]const u8 {
            return switch (count) {
                3428 => "3٬428",
                3389 => "3٬389",
                39 => "39",
                0 => "0",
                else => null,
            };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var words = try aliases.Registry.init(a, aliases.parser_header ++ "\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
        "pagesincategory\t1\tPAGESINCATEGORY\npagesincategory\t1\tPAGESINCAT\npagesincategory\t1\tصفحات_في_التصنيف\n" ++
        "pagesincategory_all\t0\tall\npagesincategory_all\t0\tكل\npagesincategory_pages\t0\tpages\npagesincategory_pages\t0\tصفحات\n" ++
        "pagesincategory_subcats\t0\tsubcats\npagesincategory_subcats\t0\tتصنيفات_فرعية\npagesincategory_files\t0\tfiles\n" ++
        "rawsuffix\t1\tR\nrawsuffix\t1\tآر\npagesincategory_pages\t1\tBOTH\nrawsuffix\t1\tBOTH\n", "arwiktionary", "20261001", "ar");
    defer words.deinit();
    var source: Source = .{ .words = &words };
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .ctx = &source, .get = Source.get, .exists = Source.exists, .resolve_title_magic = Source.resolve, .resolve_parser_function = Source.parser, .category_stats = Source.stats, .category_statistics_formatted = Source.formatted } };
    // Exact dated AR category row: all3428/subcats3389/files0 => pages39.
    try std.testing.expectEqualStrings("3٬428|39|3٬389|0|3428|3389|3428", try expander.expandFragment("Notice", "{{PAGESINCATEGORY:صفحات للحذف السريع}}|{{صفحات_في_التصنيف:صفحات للحذف السريع|صفحات}}|" ++
        "{{PAGESINCAT:صفحات للحذف السريع|تصنيفات_فرعية}}|{{PAGESINCATEGORY:صفحات للحذف السريع|FILES}}|" ++
        "{{PAGESINCATEGORY:صفحات للحذف السريع|R}}|{{PAGESINCATEGORY:صفحات للحذف السريع|آر|SUBCATS}}|" ++
        "{{PAGESINCATEGORY:صفحات للحذف السريع|unknown|R}}", 1_670_803_200));
    try std.testing.expectEqualStrings("25|20|2|0|0|ordinary-template", try expander.expandFragment("Notice", "{{PAGESINCATEGORY:English__nouns#section|R}}|{{PAGESINCAT:English nouns|pages|R}}|" ++
        "{{PAGESINCAT:English nouns|R|files}}|{{PAGESINCATEGORY:Category:English nouns|R}}|" ++
        "{{PAGESINCATEGORY:[invalid]|R}}|{{pagesincategory:English nouns|R}}", 1_670_803_200));
    // The captured English Category namespace is case-sensitive.
    try std.testing.expectEqualStrings("0", try expander.expandFragment("Notice", "{{PAGESINCATEGORY:english__nouns#section|R}}", 1_670_803_200));
    try std.testing.expectEqualStrings("0", try expander.expandFragment("Notice", "{{PAGESINCATEGORY:Missing category}}", 1_670_803_200));
    try std.testing.expectEqualStrings("3389|3428", try expander.expandFragment("Notice", "{{PAGESINCATEGORY:صفحات للحذف السريع|BOTH|subcats}}|{{PAGESINCATEGORY:صفحات للحذف السريع|R|all|{{Ignored}}}}", 1_670_803_200));
    try std.testing.expectEqual(@as(usize, 1), source.ignored_reads);
    const args = try runtime.newTable();
    try args.rawSet(a, .{ .number = 1 }, .{ .string = "صفحات للحذف السريع" });
    try args.rawSet(a, .{ .number = 2 }, .{ .string = "subcats" });
    try args.rawSet(a, .{ .number = 3 }, .{ .string = "R" });
    try std.testing.expectEqualStrings("3389", try Expander.hostFrameParserFunction(&expander, a, "PAGESINCATEGORY", args));
    try args.rawSet(a, .{ .number = 5 }, .{ .string = "{{Ignored}}" });
    try std.testing.expectEqualStrings("3389", try Expander.hostFrameParserFunction(&expander, a, "PAGESINCATEGORY", args));
    try std.testing.expectEqual(@as(usize, 1), source.ignored_reads);
    try std.testing.expectError(error.CategoryStatisticsFormatSnapshotMissing, expander.expandFragment("Notice", "{{PAGESINCATEGORY:English nouns}}", 1_670_803_200));
    expander.provider.category_statistics_formatted = null;
    try std.testing.expectError(error.CategoryStatisticsFormatSnapshotMissing, expander.expandFragment("Notice", "{{PAGESINCATEGORY:صفحات للحذف السريع}}", 1_670_803_200));
    try std.testing.expectEqualStrings("3428", try expander.expandFragment("Notice", "{{PAGESINCATEGORY:صفحات للحذف السريع|R}}", 1_670_803_200));
    source.fail = true;
    try std.testing.expectError(error.TestCategoryReadFailure, expander.expandFragment("Notice", "{{PAGESINCATEGORY:صفحات للحذف السريع|R}}", 1_670_803_200));
    expander.provider.category_stats = null;
    try std.testing.expectError(error.CategoryStatisticsSnapshotMissing, expander.expandFragment("Notice", "{{PAGESINCATEGORY:Missing|R}}", 1_670_803_200));
}

test "CategoryTree collapsed roots retain Appendix filters and authored class text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const insertion = std.mem.indexOf(u8, CategoryTreeNamespaceFixture.registry_text, "118\tRekonstruktion\t").?;
    const registry_text = try std.mem.concat(a, u8, &.{
        CategoryTreeNamespaceFixture.registry_text[0..insertion],
        "100\tAppendix\tAppendix\tcase-sensitive\t1\t0\t0\t\tsupplemental\tverified_edition_feature\n",
        CategoryTreeNamespaceFixture.registry_text[insertion..],
    });
    var registry = try rt.namespace_registry.Registry.init(a, registry_text);
    defer registry.deinit();
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    runtime.namespace_catalog = &registry;
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var source: CategoryTreeNamespaceFixture = .{ .count = 3 };
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{
        .ctx = &source,
        .get = TestProvider.get,
        .exists = CategoryTreeNamespaceFixture.exists,
        .category_tree = CategoryTreeNamespaceFixture.tree,
        .category_stats = CategoryTreeNamespaceFixture.stats,
    } };
    const filtered = try expander.expandFragment("Appendix:Hebrew patterns/test", "{{#categorytree:Probe|depth=0|namespaces=\"Appendix -\"|class=\"derivedterms\"|showcount=on}}", 1_670_803_200);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "CategoryTreeCount\">(3)") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "display:none") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "[[main]]") == null);
    const authored_class = try expander.expandFragment("Appendix:Hebrew patterns/test", "{{#categorytree:Probe|depth=0|namespaces=\"Appendix -\"|class=\"derivedterms<nowiki/> Hebr\"}}", 1_670_803_200);
    try std.testing.expect(std.mem.indexOf(u8, authored_class, "derivedterms&lt;nowiki/&gt; Hebr CategoryTreeTag") != null);
    try std.testing.expect(std.mem.indexOf(u8, authored_class, "[[:Category:Probe|Probe]]") != null);
}

const MissingDependencyRegression = struct {
    fn get(_: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
        if (std.mem.eql(u8, title, "Template:Outer")) return "{{Inner|{{{value}}}}}";
        if (std.mem.eql(u8, title, "Template:Inner")) return "{{#if:yes|{{{1}}}|unused}}|{{#ifeq:1|1|{{{1}}}|unused}}";
        if (std.mem.eql(u8, title, "Template:Term")) return "<span class='mention-Latn'>[[{{{1}}}#{{language|{{{lang}}}}}|{{{1}}}]]</span>";
        return null;
    }
};
test "authored transcluded code template example keeps closing braces through dependency phase" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    const Fixture = struct {
        fn get(_: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
            if (std.mem.eql(u8, title, "Template:Example")) return "<includeonly><code>{&#123;<!-- name -->{{#if:{{{1|}}}|[[Template:{{{1}}}|{{{1}}}]]|[[Template:Other]]}}<!-- tail -->}}</code></includeonly><noinclude>outside</noinclude>";
            if (std.mem.eql(u8, title, "Template:OrphanClose")) return "<code>[[Template:Kept|Kept]]}}</code>";
            if (std.mem.eql(u8, title, "Template:ActiveClose")) return "<code>{&#123;{{Label}}</code>";
            if (std.mem.eql(u8, title, "Template:Label")) return "[[Template:Kept|Kept]]";
            if (std.mem.eql(u8, title, "Template:ForgedClose")) return "<code>{&#123;{{ReturnedBraces}}</code>";
            if (std.mem.eql(u8, title, "Template:ReturnedBraces")) return "[[Template:Kept|Kept]]}}";
            return null;
        }
    };
    var expander: Expander = .{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23,
        .provider = .{ .get = Fixture.get, .exists = TestProvider.exists } };
    const output = try expander.expandFragment("Page", "{{Example|Kept}}|{{Missing}}|{{OrphanClose}}|{{ActiveClose}}|{{ForgedClose}}", null);
    try std.testing.expectEqualStrings("<code>{&#123;[[Template:Kept|Kept]]&#125;&#125;</code>|[[:Template:Missing]]|<code>[[Template:Kept|Kept]]}}</code>|<code>{&#123;[[Template:Kept|Kept]]</code>|<code>{&#123;[[Template:Kept|Kept]]}}</code>", output);
    var phase = try dependency.decode(a, expander.missing_dependency_metadata.?, output, "");
    defer phase.deinit();
    try std.testing.expectEqual(@as(usize, 1), phase.output().ranges.len);
    const range = phase.output().ranges[0];
    try std.testing.expectEqualStrings("[[:Template:Missing]]", output[range.start..range.end]);
}

test "transcluded code brace proof refuses foreign tags malformed source and lost or local dependency ranges" {
    const a = std.testing.allocator;
    const source = "<noinclude/><code>{&#123;<!-- replaced -->[[Template:Kept|Kept]]}}</code><noinclude/>";
    const prepared = try preprocess.transcludeDecodedForParsingAlloc(a, source);
    defer a.free(prepared);
    const close = Expander.transcludedCodeExampleClose(prepared).?;
    try std.testing.expectEqualStrings("}}", prepared[close..close + 2]);
    for ([_][]const u8{
        "<nowiki><code>{&#123;[[Target]]}}</code></nowiki>",
        "<code>[[Target]]}}</code>",
        "<code>{&#123;[[Target]]}}",
        "<code>{&#123;<code>[[Target]]}}</code>}}</code>",
        "<code>{&#123;[[Target]]}}</code> outside",
        "<noinclude/><code>{&#123;[[Target]]}}</code><noinclude />",
        "<noinclude/><code>{&#123;<noinclude>[[Target]]</noinclude>}}</code>",
    }) |candidate| try std.testing.expect(Expander.transcludedCodeExampleClose(candidate) == null);
    const literal = "<code>{&#123;[[Template:Kept|Kept]]}}</code>";
    var out: dependency.Builder = .{};
    defer out.deinit(a);
    try out.append(a, .{ .bytes = literal, .unknown = true, .lost_missing_range = true });
    try Expander.markTranscludedCodeExampleClose(a, &out);
    try std.testing.expectEqual(@as(usize, 0), out.literal_curly_ranges.items.len);
    out.lost_missing_range = false;
    const start: u32 = @intCast(std.mem.indexOf(u8, literal, "[[").?);
    try out.ranges.append(a, .{ .start = start, .end = start + 2, .occurrence = 1 });
    try Expander.markTranscludedCodeExampleClose(a, &out);
    try std.testing.expectEqual(@as(usize, 0), out.literal_curly_ranges.items.len);
    out.ranges.clearRetainingCapacity();
    try Expander.markTranscludedCodeExampleClose(a, &out);
    try std.testing.expectEqual(@as(usize, 1), out.literal_curly_ranges.items.len);
    try std.testing.expect(out.unknown);
    var nested: dependency.Builder = .{};
    defer nested.deinit(a);
    try nested.append(a, .{ .bytes = "<code>{&#123;[[Template:Kept|[[Nested]]]]}}</code>" });
    try Expander.markTranscludedCodeExampleClose(a, &nested);
    try std.testing.expectEqual(@as(usize, 0), nested.literal_curly_ranges.items.len);
}

test "native missing dependency provenance preserves copied arguments and distinguishes authored bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = MissingDependencyRegression.get, .exists = TestProvider.exists } };
    const output = try expander.expandFragment("Page", "[[:Template:Missing]]|{{Outer|value= {{Missing}} }}", null);
    try std.testing.expectEqualStrings("[[:Template:Missing]]|[[:Template:Missing]]|[[:Template:Missing]]", output);
    var phase = try dependency.decode(a, expander.missing_dependency_metadata.?, output, "");
    defer phase.deinit();
    try std.testing.expectEqual(@as(usize, 1), phase.occurrences().len);
    try std.testing.expectEqual(@as(usize, 2), phase.output().ranges.len);
    try std.testing.expectEqual(@as(u32, 22), phase.output().ranges[0].start);
    try std.testing.expectEqual(phase.output().ranges[0].occurrence, phase.output().ranges[1].occurrence);
    const term = try expander.expandFragment("Page", "{{Term|beran|lang=ang}}", null);
    try std.testing.expectEqualStrings("<span class='mention-Latn'>[[beran#[[:Template:language]]|beran]]</span>", term);
    var term_phase = try dependency.decode(a, expander.missing_dependency_metadata.?, term, "");
    defer term_phase.deinit();
    try std.testing.expectEqual(@as(usize, 1), term_phase.output().ranges.len);
    try std.testing.expectEqualStrings("Template:language", term_phase.occurrences()[0].title);
    _ = try expander.expandFragment("Next", "[[:Template:Missing]]", null);
    try std.testing.expect(expander.missing_dependency_metadata == null);
    try std.testing.expectEqual(@as(usize, 0), expander.dependency_page.occurrences.items.len);
}
test "native missing dependency title overrides and Lua argument exposure do not infer origin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = MissingDependencyRegression.get, .exists = TestProvider.exists } };
    const output = try expander.expandFragment("Page", "{{DISPLAYTITLE:{{Missing}}}}{{DISPLAYTITLE:Final}}BODY", null);
    var phase = try dependency.decode(a, expander.missing_dependency_metadata.?, output, expander.display_title.?);
    defer phase.deinit();
    try std.testing.expectEqualStrings("Final", expander.display_title.?);
    try std.testing.expectEqual(@as(usize, 0), phase.displayTitle().ranges.len);
    const params = try runtime.newTable();
    const key: Value = .{ .string = "value" };
    const generated = try expander.missingTemplateMarkupTracked("Template:Missing");
    try params.rawSet(a, key, .{ .string = generated.bytes });
    try expander.rememberDependencyArgument(params, key, generated);
    try std.testing.expect(expander.nativeDependencyArgument(params, key) != null);
    expander.invalidateNativeDependencyArguments();
    // A byte-identical return/mutable table cannot regain origin after exposure.
    const returned = try expander.expandParameterTracked("value", params, "Page", 0);
    try std.testing.expectEqualStrings(generated.bytes, returned.bytes);
    try std.testing.expect(returned.unknown and returned.ranges.len == 0);
}

const LiteralCurlyBoundaryFixture = struct {
    fn get(_: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
        if (std.mem.eql(u8, title, "Template:LabelWithNewline")) return "[[şəkil:Flag of Kyrgyzstan.svg|22px]] qırğızca\n<noinclude>[[Kateqoriya:Dil kodları]]</noinclude>";
        if (std.mem.eql(u8, title, "Template:LabelTranslation")) return "<span lang=\"{{{1}}}\" xml:lang=\"{{{1}}}\">[[{{{2}}}|{{{3|{{{2}}}}}}]]</span> [[:{{{1}}}:{{{3|{{{2}}}}}}|<sup>({{{1}}})</sup>]]<noinclude>\n\n== Yazılması ==\n\n<nowiki>{{çevir | dil kodu | dil kodu yazılan dildəki söz }}</nowiki>\n\n\n== Nümunə ==\n\n*<nowiki>{{ çevir | en | black }}</nowiki>  şəklinde yazdığımız zaman  {{çevir|en|black}}  şəklinde görürsünüz\n\n\n\n\n</noinclude><noinclude>[[Kateqoriya:Şablonlar]]</noinclude>";
        if (std.mem.eql(u8, title, "Template:LabelWithoutNewline")) return "label";
        if (std.mem.eql(u8, title, "Template:LiteralPaired")) return "{{{missing|{<noinclude>x</noinclude>{uc:cat}}}}}";
        if (std.mem.eql(u8, title, "Template:EmitOpen")) return "{";
        if (std.mem.eql(u8, title, "Template:LiteralGeneratedLeft")) return "{{EmitOpen}}<noinclude/>{uc:cat}}";
        if (std.mem.eql(u8, title, "Template:LiteralSelectedNested")) return "<onlyinclude>{</onlyinclude><onlyinclude>{uc:{{uc:cat}}}}</onlyinclude>";
        if (std.mem.eql(u8, title, "Template:LiteralSelected")) return "<onlyinclude>{</onlyinclude><onlyinclude>{uc:cat}}</onlyinclude>";
        if (std.mem.eql(u8, title, "Template:LiteralPairedLazy")) return "{{{missing|{<noinclude/>{uc:{{#expr:1/0}}}}}}}";
        if (std.mem.eql(u8, title, "Template:LiteralIncluded")) return "{{{missing|{<includeonly></includeonly>{uc:cat}}}}}";
        if (std.mem.eql(u8, title, "Template:LiteralComment")) return "{{{missing|{<!--x-->{uc:cat}}}}}";
        if (std.mem.eql(u8, title, "Template:LiteralEmpty")) return "{{{missing|{<noinclude/>{uc:cat}}}}}";
        if (std.mem.eql(u8, title, "Template:LiteralNested")) return "{{{missing|{{uc:cat}}}}}";
        if (std.mem.eql(u8, title, "Template:LiteralChild")) return "{{{missing|{<noinclude>x</noinclude>{uc:cat}}}}} [[cat|label]]";
        if (std.mem.eql(u8, title, "Template:LiteralProtected")) return "<nowiki>{<noinclude/>{uc:cat}}</nowiki>";
        return null;
    }
    fn exists(_: ?*anyopaque, title: []const u8) !bool {
        return (try get(null, std.testing.allocator, title)) != null;
    }
    fn body(_: ?*anyopaque, a: std.mem.Allocator, title: []const u8) !?Provider.TransclusionBody {
        const raw = (try get(null, a, title)) orelse return null;
        return .{ .text = try preprocess.transcludeDecodedForParsingAlloc(a, raw), .title = title, .borrowed = true };
    }
    fn check(source: []const u8, expected: []const u8) !void {
        for ([_]bool{ false, true }) |borrowed| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var runtime = try rt.Context.initProgram(arena.allocator(), 24, 1);
            defer runtime.deinit();
            try rt.bindGlobalTable(&runtime, null, 0);
            try stdlib.install(&runtime);
            try installTestHost(&runtime, 18, 23);
            var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = get, .exists = exists }, .install_scribunto = installTestInvoke };
            if (borrowed) expander.provider.get_transclusion_body = body;
            const actual = try expander.expandFragment("Literal boundary fixture", source, 1_670_803_200);
            try std.testing.expectEqualStrings(expected, actual);
            try std.testing.expect(!expander.unsupported_parser_function);
        }
    }
};

test "inclusion and comment node boundaries preserve literal default braces through expansion" {
    const literal = "&#123;&#123;uc:cat&#125;&#125;";
    try LiteralCurlyBoundaryFixture.check("{{LiteralPaired}}", literal);
    try LiteralCurlyBoundaryFixture.check("{{LiteralComment}}", literal);
    try LiteralCurlyBoundaryFixture.check("{{LiteralIncluded}}", literal);
    try LiteralCurlyBoundaryFixture.check("{{LiteralSelected}}", literal);
    try LiteralCurlyBoundaryFixture.check("{{LiteralSelectedNested}}", "&#123;&#123;uc:CAT&#125;&#125;");
    try LiteralCurlyBoundaryFixture.check("{{LiteralEmpty}}", literal);
    try LiteralCurlyBoundaryFixture.check("{{{missing|{<!--x-->{uc:cat}}}}}", literal);
    try LiteralCurlyBoundaryFixture.check("{{LiteralChild}}", literal ++ " [[cat|label]]");
    try LiteralCurlyBoundaryFixture.check("{{LiteralNested}}", "CAT");
    try LiteralCurlyBoundaryFixture.check("{{LiteralProtected}}", "<nowiki>{<noinclude/>{uc:cat}}</nowiki>");
    try LiteralCurlyBoundaryFixture.check("{{LiteralGeneratedLeft}}", "{{uc:cat}}");
}

test "direct inclusion retains protected text and cannot join authored or generated braces" {
    try LiteralCurlyBoundaryFixture.check("{{<includeonly>subst:</includeonly>PAGENAME}}", "Literal boundary fixture");
    try LiteralCurlyBoundaryFixture.check("{<includeonly>gone</includeonly>{uc:cat}}", "&#123;&#123;uc:cat&#125;&#125;");
    try LiteralCurlyBoundaryFixture.check("{<includeonly/>{uc:cat}}", "&#123;&#123;uc:cat&#125;&#125;");
    try LiteralCurlyBoundaryFixture.check("{<noinclude></noinclude>{uc:cat}}", "&#123;&#123;uc:cat&#125;&#125;");
    try LiteralCurlyBoundaryFixture.check("{<onlyinclude></onlyinclude>{uc:cat}}", "&#123;&#123;uc:cat&#125;&#125;");
    try LiteralCurlyBoundaryFixture.check("{{EmitOpen}}<includeonly>gone</includeonly>{uc:cat}}", "{{uc:cat}}");
    try LiteralCurlyBoundaryFixture.check("<nowiki>{{<includeonly>subst:</includeonly>PAGENAME}}</nowiki>", "<nowiki>{{<includeonly>subst:</includeonly>PAGENAME}}</nowiki>");
    try LiteralCurlyBoundaryFixture.check("<pre>{{<includeonly>subst:</includeonly>PAGENAME}}</pre>", "<pre>{{<includeonly>subst:</includeonly>PAGENAME}}</pre>");
    try LiteralCurlyBoundaryFixture.check("<!--<includeonly>-->A<noinclude>{{uc:cat}}</noinclude><onlyinclude>B</onlyinclude>C", "ACATBC");
}

test "direct inclusion mode preserves MediaWiki first-close missing-end and raw-delimiter rules" {
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "A<includeonly>B</includeonly>C", .expected = "AC" },
        .{ .source = "A<includeonly>B", .expected = "A" },
        .{ .source = "A<INCLUDEONLY>B", .expected = "A<INCLUDEONLY>B" },
        .{ .source = "A<INCLUDEONLY x=1>B</includeonly >C", .expected = "AC" },
        .{ .source = "A<includeonly>B<includeonly>C</includeonly>D</includeonly>E", .expected = "AD</includeonly>E" },
        .{ .source = "A</includeonly>B", .expected = "A</includeonly>B" },
        .{ .source = "A<includeonly/>B", .expected = "AB" },
        .{ .source = "A<includeonly / >B", .expected = "A" },
        .{ .source = "A<includeonly/ >B", .expected = "A<includeonly/ >B" },
        .{ .source = "A<includeonlyX>B</includeonlyX>C", .expected = "A<includeonlyX>B</includeonlyX>C" },
        .{ .source = "A<noinclude x=\">\">B</noinclude>C", .expected = "A\">BC" },
        .{ .source = "A<onlyinclude>B</onlyinclude>C", .expected = "ABC" },
        .{ .source = "A<ONLYINCLUDE>B</ONLYINCLUDE>C", .expected = "ABC" },
        .{ .source = "<nowiki><includeonly>X</includeonly><!--Y--></nowiki>", .expected = "<nowiki><includeonly>X</includeonly><!--Y--></nowiki>" },
        .{ .source = "<source><includeonly>X</includeonly></source>", .expected = "<source><includeonly>X</includeonly></source>" },
        .{ .source = "<ref><includeonly>X</includeonly></ref>", .expected = "<ref><includeonly>X</includeonly></ref>" },
        .{ .source = "A<!--<includeonly>B-->C", .expected = "AC" },
        .{ .source = "A<!--<onlyinclude>B</onlyinclude>-->C", .expected = "AC" },
    };
    for (cases) |case| {
        const prepared = try preprocess.directDecodedForParsingAlloc(std.testing.allocator, case.source);
        defer std.testing.allocator.free(prepared);
        var visible: std.ArrayList(u8) = .empty;
        defer visible.deinit(std.testing.allocator);
        try preprocess.appendParsingText(std.testing.allocator, &visible, prepared);
        try std.testing.expectEqualStrings(case.expected, visible.items);
    }
    const source = "A<noinclude>D</noinclude><includeonly>T</includeonly><onlyinclude>O</onlyinclude>Z";
    const transcluded = try preprocess.transcludeDecodedAlloc(std.testing.allocator, source);
    defer std.testing.allocator.free(transcluded);
    try std.testing.expectEqualStrings("O", transcluded);
    const direct = try preprocess.directDecodedForParsingAlloc(std.testing.allocator, source);
    defer std.testing.allocator.free(direct);
    var visible: std.ArrayList(u8) = .empty;
    defer visible.deinit(std.testing.allocator);
    try preprocess.appendParsingText(std.testing.allocator, &visible, direct);
    try std.testing.expectEqualStrings("ADOZ", visible.items);
}

const FaroeseDirectInclusionFixture = struct {
    const Row = struct { title: []const u8, page_id: u64, revision_id: u64, text: []const u8, redirect: ?[]const u8 };
    const Corpus = struct { pages: []const Row, templates: []const Row };
    const aliases = rt.namespace_registry.magic_words;
    corpus: Corpus,
    words: *const aliases.Registry,

    fn row(self: *const @This(), title: []const u8) ?Row {
        for (self.corpus.templates) |item| if (std.mem.eql(u8, title, item.title)) return item;
        return null;
    }
    fn get(ctx: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        return if (self.row(title)) |item| item.text else null;
    }
    fn exists(ctx: ?*anyopaque, title: []const u8) !bool {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        return self.row(title) != null;
    }
    fn body(ctx: ?*anyopaque, a: std.mem.Allocator, title: []const u8) !?Provider.TransclusionBody {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        var item = self.row(title) orelse return null;
        for (0..16) |_| {
            if (item.redirect) |target| {
                item = self.row(target) orelse return error.FixtureRedirectMissing;
            } else {
                return .{ .text = try preprocess.transcludeDecodedForParsingAlloc(a, item.text), .title = item.title, .borrowed = false };
            }
        }
        return error.FixtureRedirectCycle;
    }
    fn resolve(ctx: ?*anyopaque, name: []const u8, form: aliases.Form) !?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        return self.words.resolve(name, form);
    }
    fn parser(ctx: ?*anyopaque, name: []const u8) !?[]const u8 {
        return resolve(ctx, name, .parser_function);
    }
};

test "Faroese complete heimur and kambur direct pages expand inclusion-wrapped PAGENAME through ordinary providers" {
    const F = FaroeseDirectInclusionFixture;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const corpus = try std.json.parseFromSlice(F.Corpus, a, @embedFile("testdata/fo-direct-inclusion/pages-and-templates.json"), .{});
    defer corpus.deinit();
    try std.testing.expectEqual(@as(usize, 398), corpus.value.templates.len);
    try std.testing.expectEqual(@as(usize, 2), corpus.value.pages.len);
    var ns = try rt.namespace_registry.Registry.init(a, @embedFile("testdata/fo-direct-inclusion/namespace-registry.tsv"));
    defer ns.deinit();
    var words = try F.aliases.Registry.init(a, @embedFile("testdata/fo-direct-inclusion/magic-words.tsv"), "fowiktionary", "20261001", "fo");
    defer words.deinit();
    var provider: F = .{ .corpus = corpus.value, .words = &words };
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    runtime.namespace_catalog = &ns;
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var expander: Expander = .{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{
        .ctx = &provider, .get = F.get, .exists = F.exists, .get_transclusion_body = F.body,
        .resolve_title_magic = F.resolve, .resolve_parser_function = F.parser,
    }, .install_scribunto = installTestInvoke };
    for (corpus.value.pages) |page| {
        const current: host_api.CurrentPage = .{ .namespace = 0, .metadata = .{
            .page_id = page.page_id, .revision_id = page.revision_id, .revision_timestamp = "", .revision_user = "", .content_model = "wikitext",
        } };
        const actual = try expander.expandStoredFragment(page.title, page.text, 1_670_803_200, current);
        const actual_metadata = if (expander.missing_dependency_metadata) |metadata| try a.dupe(u8, metadata) else null;
        try std.testing.expect(std.mem.indexOf(u8, actual, "{{<includeonly>subst:</includeonly>PAGENAME}}") == null);
        try std.testing.expect(std.mem.indexOf(u8, actual, try std.fmt.allocPrint(a, "'''{s}'''", .{page.title})) != null);
        try std.testing.expect(std.mem.indexOf(u8, actual, try std.fmt.allocPrint(a, "leitord={s}&button_leita=&action=1&pageno=0 {s}", .{page.title, page.title})) != null);
        // Independent ordinary magic-word path: no manual title or output text
        // is substituted, and every other original page/provider byte remains.
        const reference_source = try std.mem.replaceOwned(u8, a, page.text, "{{<includeonly>subst:</includeonly>PAGENAME}}", "{{PAGENAME}}");
        const expected = try expander.expandStoredFragment(page.title, reference_source, 1_670_803_200, current);
        try std.testing.expectEqualStrings(expected, actual);
        try std.testing.expectEqual(actual_metadata != null, expander.missing_dependency_metadata != null);
        if (actual_metadata) |metadata| {
            var actual_phase = try dependency.decode(a, metadata, actual, "");
            defer actual_phase.deinit();
            var expected_phase = try dependency.decode(a, expander.missing_dependency_metadata.?, expected, "");
            defer expected_phase.deinit();
            try std.testing.expectEqualDeep(expected_phase.output(), actual_phase.output());
            try std.testing.expectEqualDeep(expected_phase.occurrences(), actual_phase.occurrences());
        }
        if (std.mem.eql(u8, page.title, "heimur")) {
            try std.testing.expect(std.mem.indexOf(u8, actual, "[[:Fyrimynd:..]]") != null);
            try std.testing.expect(actual_metadata != null);
        }
    }
}

test "direct inclusion removal preserves a later missing dependency without evaluating excluded source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var expander: Expander = .{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = LiteralCurlyBoundaryFixture.get, .exists = LiteralCurlyBoundaryFixture.exists } };
    const actual = try expander.expandFragment("heimur", "{{<includeonly>{{HiddenMissing}}</includeonly>PAGENAME}}|{{Missing}}", 1_670_803_200);
    try std.testing.expectEqualStrings("heimur|[[:Template:Missing]]", actual);
    var phase = try dependency.decode(a, expander.missing_dependency_metadata.?, actual, "");
    defer phase.deinit();
    try std.testing.expect(!phase.output().unknown);
    try std.testing.expectEqual(@as(usize, 1), phase.occurrences().len);
    try std.testing.expectEqualStrings("Template:Missing", phase.occurrences()[0].title);
    try std.testing.expectEqualDeep(@as([]const dependency.Range, &.{.{ .start = 7, .end = @intCast(actual.len), .occurrence = 1 }}), phase.output().ranges);
}

test "literal default provenance preserves native intermediate values and chosen arguments" {
    try LiteralCurlyBoundaryFixture.check("{{#len:{{LiteralPaired}}}}", "10");
    try LiteralCurlyBoundaryFixture.check("{{#len:{{LiteralComment}}}}", "10");
    try LiteralCurlyBoundaryFixture.check("{{LiteralPaired|missing=[[cat|label]]}}", "[[cat|label]]&#125;&#125;");
    try LiteralCurlyBoundaryFixture.check("{{LiteralPaired|missing={{uc:dog}}}}", "DOG&#125;&#125;");
    try LiteralCurlyBoundaryFixture.check("{{LiteralPairedLazy|missing=provided}}", "provided&#125;&#125;");
    try LiteralCurlyBoundaryFixture.check("A<!--x-->B {{{absent}}}", "AB {{{absent}}}");
    try LiteralCurlyBoundaryFixture.check("A<!--x-->B {{Missing}}", "AB [[:Template:Missing]]");
    try LiteralCurlyBoundaryFixture.check("{{#i<!--x-->f:x|yes|no}}", "yes");
    try LiteralCurlyBoundaryFixture.check("safe<!--x--> body }} {{uc:cat}}", "safe body }} CAT");
    try LiteralCurlyBoundaryFixture.check("safe<!--x--> body {{broken", "safe body {{broken");
    try LiteralCurlyBoundaryFixture.check("safe<!--x--> body {|\n| cell\n|}", "safe body {|\n| cell\n|}");
}

test "URL parser missing title parameters do not become encoded action destinations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 24);
    defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists, .site_server = "//ar.wiktionary.org", .site_script = "/w/index.php", .site_article_path = "/wiki/$1" } };
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "{{fullurl:{{{2}}}|action=edit}}", .expected = "{{{2}}}" },
        .{ .source = "{{fullurle:{{{2}}}|action=edit}}", .expected = "{{{2}}}" },
        .{ .source = "{{localurl:Prefix {{{2}}}|action=edit}}", .expected = "Prefix {{{2}}}" },
        .{ .source = "{{fullurl:{{{2|Known title}}}|action=edit}}", .expected = "//ar.wiktionary.org/w/index.php?title=Known_title&action=edit" },
        .{ .source = "{{fullurl:%7B%7B%7B2%7D%7D%7D|action=edit}}", .expected = "//ar.wiktionary.org/w/index.php?title=%257B%257B%257B2%257D%257D%257D&action=edit" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.expected, try expander.expandFragment("Page", case.source, 1_670_803_200));
    for ([_][]const u8{
        "{{fullurl:<nowiki>{{{2}}}</nowiki>|action=edit}}",
        "{{fullurl:&#123;&#123;&#123;2&#125;&#125;&#125;|action=edit}}",
    }) |literal_source| {
        const literal_url = try expander.expandFragment("Page", literal_source, 1_670_803_200);
        try std.testing.expect(std.mem.startsWith(u8, literal_url, "//ar.wiktionary.org/w/index.php?title="));
    }
}

test "non table invoke renders a specific error while preserving surrounding page text" {
    const P = struct {
        fn lookup(_: ?*const anyopaque, raw_name: []const u8) ?u32 {
            if (std.mem.eql(u8, raw_name, "Module:Test")) return 0;
            if (std.mem.eql(u8, raw_name, "Module:Healthy")) return 1;
            return null;
        }
        fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
            return switch (id) { 0 => "Module:Test", 1 => "Module:Healthy", else => null };
        }
    };
    for ([_]rt.FunctionFn{ rt.stabilizeBuffered(TestModule.empty), rt.stabilizeBuffered(TestModule.numericReturn) }) |root| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var runtime = try rt.Context.initProgram(arena.allocator(), 24, 2);
        defer runtime.deinit();
        const functions = [_]rt.FunctionFn{ root, rt.stabilize(TestModule.root) };
        runtime.module_root_entries = &functions;
        runtime.configureModules(null, P.lookup, P.name);
        try rt.bindGlobalTable(&runtime, null, 0);
        try stdlib.install(&runtime);
        var expander = Expander{
            .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23,
            .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists, .resolve_call_symbol = TestProvider.resolveCallSymbol },
            .install_scribunto = installTestInvoke,
        };
        for ([_][]const u8{ "Test", "@module" }) |module| {
            const source = try std.fmt.allocPrint(runtime.allocator, "A{{{{#invoke:{s}|show}}}}B\n# definition\nConstituency\n{{{{#invoke:Healthy|run|x=OK}}}}", .{module});
            const expanded = try expander.expandFragment("Page", source, 1_791_731_560);
            try std.testing.expectEqualStrings("A<strong class=\"error\"><span class=\"scribunto-error\">Lua error in Module:Test: The module did not return an export table.</span></strong>B\n# definition\nConstituency\nOK", expanded);
            try std.testing.expect(runtime.current_frame == null and runtime.aotErrorName() == null and !runtime.last_error_present);
        }
        const caught = try expander.expandFragment("Page", "A{{#iferror:{{#invoke:Test|show}}|caught|BAD}}B{{#iferror:{{#invoke:@module|show}}|caught|BAD}}C", 1_791_731_560);
        try std.testing.expectEqualStrings("AcaughtBcaughtC", caught);
        try std.testing.expect(runtime.current_frame == null and runtime.aotErrorName() == null and !runtime.last_error_present);
    }
}


test "stored current-page magic and metadata distinguish explicit titles and reset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 24, 1);
    defer runtime.deinit();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23,
        .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists, .page_metadata = TestProvider.pageMetadata } };
    const title = "Event:Stored page";
    const current: host_api.CurrentPage = .{ .namespace = 0, .metadata = .{
        .page_id = 8451, .revision_id = 32521, .revision_timestamp = "2026-01-01T00:00:00Z", .revision_user = "Stored editor", .content_model = "wikitext",
    } };
    const output = try expander.expandStoredFragment(title,
        "{{NAMESPACENUMBER}}|{{PAGENAME}}|{{PAGEID}}|{{REVISIONID}}|{{NAMESPACENUMBER:Event:Stored page}}|{{PAGENAME:Event:Stored page}}", 1_670_803_200, current);
    try std.testing.expectEqualStrings("0|Event:Stored page|8451|32521|1728|Stored page", output);
    try std.testing.expectEqualStrings("Template:/Child", try expander.normalizeTransclusionName("/Child", title));
    try std.testing.expectEqualStrings("<unsupportedstoredpagereset>x</unsupportedstoredpagereset>", try expander.expandStoredFragment(title, "{{#tag:UnsupportedStoredPageReset|x}}", 1_670_803_200, current));
    // Context.initProgram supplies the test catalog used by Event and Appendix
    // above. Remove it only for the intentional exceptional-page reset probe.
    const catalog = runtime.namespace_catalog orelse return error.TestUnexpectedResult;
    {
        runtime.namespace_catalog = null;
        defer runtime.namespace_catalog = catalog;
        try std.testing.expectError(error.NamespaceRegistryRequired, expander.expandStoredFragment(title, "{{#tag:phonos|x}}", 1_670_803_200, current));
    }
    try std.testing.expect(runtime.namespace_catalog == catalog);
    try std.testing.expectEqualStrings("100|42", try expander.expandFragment("Appendix:Page/Sub", "{{NAMESPACENUMBER}}|{{PAGEID}}", 1_670_803_200));
    try std.testing.expect(expander.host.current_page == null);
}


test "stored redirect identity errors cross invoke envelopes without semantic fallback" {
    const Probe = struct {
        const Mode = enum { direct, repaired, lua, pcall, xpcall, nested, lua_pcall, lua_xpcall };
        var failure: anyerror = error.InvalidStoredRedirectTarget;
        var mode: Mode = .direct;
        var nested_started: bool = false;
        fn root(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
            const exports = try ctx.newTable();
            try exports.rawSet(ctx.allocator, .{ .string = "run" }, try ctx.makeFunctionKnown(1, run, &.{}));
            return value(.{ .table = exports });
        }
        fn value(item: Value) ![]const Value {
            const result = try std.heap.smp_allocator.alloc(Value, 1);
            result[0] = item;
            return result;
        }
        fn fail(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
            if (mode == .lua or mode == .lua_pcall or mode == .lua_xpcall) {
                ctx.setLuaError(.{ .string = @errorName(failure) });
                return error.LuaRaised;
            }
            host_api.recordPageIdentityFailure(ctx, failure);
            return failure;
        }
        fn handler(_: *rt.Context, _: rt.Captures, args: []const Value) ![]const Value {
            return value(args[0]);
        }
        fn run(ctx: *rt.Context, _: rt.Captures, args: []const Value) ![]const Value {
            if (mode == .repaired) {
                const frame_args = try ctx.getIndex(args[0], .{ .string = "args" });
                const x = try ctx.getIndex(frame_args, .{ .string = "x" });
                if (x == .string and std.mem.indexOf(u8, x.string, "&lt;") != null) {
                    ctx.setLuaError(.{ .string = "Invalid page title \"Reconstruction:Probe/term&lt;t:gloss&gt;\" encountered." });
                    return error.LuaRaised;
                }
            }
            if (mode == .nested and !nested_started) {
                nested_started = true;
                const preprocess_call = try ctx.getIndex(args[0], .{ .string = "preprocess" });
                const result = try ctx.callValue(preprocess_call, &.{ args[0], .{ .string = "{{#invoke:Test|run}}" } });
                defer rt.freeResults(result);
                try std.testing.expectEqualStrings("caught", result[0].string);
                return value(.{ .string = "nested completed" });
            }
            if (mode == .pcall or mode == .xpcall or mode == .nested or mode == .lua_pcall or mode == .lua_xpcall) {
                const is_xpcall = mode == .xpcall or mode == .lua_xpcall;
                const pcall_slot: u32 = 16; // Stable ABI slot; the fixture global table has no name mapping.
                const protected = if (is_xpcall)
                    try ctx.getIndex(.{ .table = ctx.global_table.? }, .{ .string = "xpcall" })
                else
                    ctx.getGlobal(pcall_slot);
                try std.testing.expect(protected == .callable);
                const callable = try ctx.makeFunctionKnown(2, fail, &.{});
                const handler_callable = try ctx.makeFunctionKnown(3, handler, &.{});
                const result = if (is_xpcall)
                    try ctx.callValue(protected, &.{ callable, handler_callable })
                else
                    try ctx.callValue(protected, &.{callable});
                defer rt.freeResults(result);
                try std.testing.expect(result.len >= 1 and result[0] == .boolean and !result[0].boolean);
                if (mode != .lua_pcall and mode != .lua_xpcall) {
                    host_api.recordPageIdentityFailure(ctx, error.InvalidStoredRedirectTarget);
                    try std.testing.expectEqual(failure, host_api.get(ctx).?.page_identity_failure.?);
                }
                return value(.{ .string = "caught" });
            }
            return fail(ctx, .{ .direct = &.{} }, args);
        }
    };
    for ([_]anyerror{ error.UnsupportedStoredInterwikiNamespace, error.UnsupportedStoredLocalInterwiki, error.InvalidStoredRedirectTarget, error.NamespaceTitleCollision }) |expected| {
        for ([_]Probe.Mode{ .direct, .repaired, .lua, .pcall, .xpcall, .nested, .lua_pcall, .lua_xpcall }) |mode| {
            errdefer std.debug.print("stored redirect identity case: expected={s} mode={s}\n", .{ @errorName(expected), @tagName(mode) });
            Probe.failure = expected;
            Probe.mode = mode;
            Probe.nested_started = false;
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var runtime = try rt.Context.initProgram(arena.allocator(), 24, 1);
            defer runtime.deinit();
            const functions = [_]rt.FunctionFn{rt.stabilize(Probe.root)};
            runtime.module_root_entries = &functions;
            runtime.configureModules(null, TestModule.lookup, TestModule.name);
            try rt.bindGlobalTable(&runtime, null, 0);
            try stdlib.install(&runtime);
            var expander = Expander{
                .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23,
                .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists },
                .install_scribunto = installTestInvoke,
            };
            const source = switch (mode) {
                .direct => "{{#iferror:{{#invoke:Test|run}}|caught|success}}",
                .repaired => "A{{#invoke:Test|run|x=term&lt;t:gloss&gt;}}B",
                else => "{{#invoke:Test|run}}",
            };
            if (mode == .lua or mode == .lua_pcall or mode == .lua_xpcall) {
                const rendered = try expander.expandFragment("Page", source, 1_670_803_200);
                if (mode == .lua) {
                    try std.testing.expect(std.mem.indexOf(u8, rendered, "Lua error in Module:Test:") != null);
                    try std.testing.expect(std.mem.indexOf(u8, rendered, @errorName(expected)) != null);
                } else try std.testing.expectEqualStrings("caught", rendered);
                try std.testing.expect(runtime.aotErrorName() == null and expander.host.page_identity_failure == null);
            } else {
                try std.testing.expectError(expected, expander.expandFragment("Page", source, 1_670_803_200));
                try std.testing.expectEqual(expected, expander.host.page_identity_failure.?);
                if (mode == .direct or mode == .repaired)
                    try std.testing.expectEqualStrings(@errorName(expected), runtime.aotErrorName().?);
            }
            try std.testing.expect(runtime.current_frame == null);
            try std.testing.expectEqualStrings("next page", try expander.expandFragment("Next", "next page", 1_670_803_200));
            try std.testing.expect(expander.host.page_identity_failure == null);
        }
    }
}

test "normal file metadata host bridge retains absent provider title and original error" {
    const linux = std.os.linux;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 0, 0);
    defer runtime.deinit();
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 0, .mw_slot = 0,
        .provider = .{ .ctx = null, .get = TestProvider.get, .exists = TestProvider.exists } };
    expander.attach();
    var fds: [2]linux.fd_t = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.DiagnosticTestPipeFailed;
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);
    const saved_raw = linux.dup(2);
    if (linux.errno(saved_raw) != .SUCCESS) return error.DiagnosticTestDupFailed;
    const saved: linux.fd_t = @intCast(saved_raw);
    defer _ = linux.close(saved);
    var redirected = false;
    defer if (redirected) { _ = linux.dup2(saved, 2); };
    if (linux.errno(linux.dup2(fds[1], 2)) != .SUCCESS) return error.DiagnosticTestDupFailed;
    redirected = true;
    const title = "קובץ:צליל & exact.ogg";
    try std.testing.expectError(error.FileMetadataSnapshotMissing, expander.host.file_metadata.?(expander.host.ctx, title));
    if (linux.errno(linux.dup2(saved, 2)) != .SUCCESS) return error.DiagnosticTestDupFailed;
    redirected = false;
    // One bounded synchronous diagnostic is already available; no EOF wait.
    var ready = [_]std.posix.pollfd{.{ .fd = fds[0], .events = std.posix.POLL.IN, .revents = 0 }};
    if (try std.posix.poll(&ready, 5_000) == 0) return error.DiagnosticTestTimeout;
    var buffer: [4096]u8 = undefined;
    const count = linux.read(fds[0], &buffer, buffer.len);
    if (linux.errno(count) != .SUCCESS) return error.DiagnosticTestReadFailed;
    const expected = try std.fmt.allocPrint(arena.allocator(), "pid={d} warning: file metadata missing: title={s}\n", .{ linux.getpid(), title });
    try std.testing.expectEqualStrings(expected, buffer[0..count]);
    try std.testing.expectError(error.MissingWikitextHost, Expander.hostFileMetadata(null, title));
}

test "normal file metadata host bridge preserves positive negative and provider errors" {
    const Probe = struct {
        calls: usize = 0,
        fn file(raw: ?*anyopaque, title: []const u8) !Provider.FileMetadata {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            if (std.mem.eql(u8, title, "File:Present.ogg")) return .{ .exists = true, .width = 42, .height = 24, .media_type = .AUDIO, .canonical_title = "File:Canonical.ogg" };
            if (std.mem.eql(u8, title, "File:Absent.ogg")) return .{ .exists = false };
            return error.FileMetadataSnapshotMissing;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 0, 0);
    defer runtime.deinit();
    var probe: Probe = .{};
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 0, .mw_slot = 0,
        .provider = .{ .ctx = &probe, .get = TestProvider.get, .exists = TestProvider.exists, .file_metadata = Probe.file } };
    expander.attach();
    const get = expander.host.file_metadata.?;
    const positive = try get(expander.host.ctx, "File:Present.ogg");
    try std.testing.expect(positive.exists);
    try std.testing.expectEqual(@as(u32, 42), positive.width);
    try std.testing.expectEqual(@as(u32, 24), positive.height);
    try std.testing.expect(positive.media_type.? == .AUDIO);
    try std.testing.expectEqualStrings("File:Canonical.ogg", positive.canonical_title.?);
    const negative = try get(expander.host.ctx, "File:Absent.ogg");
    try std.testing.expect(!negative.exists);
    try std.testing.expect(negative.media_type == null and negative.canonical_title == null);
    try std.testing.expectError(error.FileMetadataSnapshotMissing, get(expander.host.ctx, "File:Unknown.ogg"));
    try std.testing.expectEqual(@as(usize, 3), probe.calls);
}


test "direct module load LuaRaised uses invoke markup and iferror while require remains typed" {
    const Probe = struct {
        const diagnostic = "error loading module 'Module:Test': UnexpectedToken";
        fn loadError(_: ?*const anyopaque, id: u32) ?[]const u8 {
            return if (id == 0) diagnostic else null;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 24, 1);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{rt.stabilize(TestModule.root)};
    runtime.module_root_entries = &functions;
    runtime.configureModules(null, TestModule.lookup, TestModule.name);
    runtime.configureModuleLoadErrors(Probe.loadError);
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try std.testing.expectError(error.LuaRaised, runtime.requireByName("Module:Test"));
    runtime.clearLuaError();
    var expander = Expander{
        .runtime = &runtime,
        .env_slot = 0,
        .string_slot = 18,
        .mw_slot = 23,
        .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists },
        .install_scribunto = installTestInvoke,
    };
    const visible = try expander.expandFragment("Page", "A{{#invoke:Test|run}}B", 1_670_803_200);
    try std.testing.expect(std.mem.startsWith(u8, visible, "A") and std.mem.endsWith(u8, visible, "B"));
    try std.testing.expect(std.mem.indexOf(u8, visible, "scribunto-error") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "UnexpectedToken") != null);
    for (0..2) |_| {
        const caught = try expander.expandFragment("Page", "{{#iferror:{{#invoke:Test|run}}|CAUGHT|BAD}}", 1_670_803_200);
        try std.testing.expectEqualStrings("CAUGHT", caught);
        try std.testing.expect(runtime.current_frame == null and runtime.aotErrorName() == null and !runtime.last_error_present);
    }
}

const NestedInvokeIsolationProbe = struct {
    var dependency_roots: usize = 0;

    fn lookup(_: ?*const anyopaque, name: []const u8) ?u32 {
        if (std.mem.eql(u8, name, "Module:IsolationOuter")) return 0;
        if (std.mem.eql(u8, name, "Module:IsolationDependency")) return 1;
        return null;
    }
    fn moduleName(_: ?*const anyopaque, id: u32) ?[]const u8 {
        return switch (id) {
            0 => "Module:IsolationOuter",
            1 => "Module:IsolationDependency",
            else => null,
        };
    }
    fn dependency(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        dependency_roots += 1;
        const exports = try ctx.newTable();
        try exports.rawSet(ctx.allocator, .{ .string = "state" }, .{ .string = "pristine" });
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .table = exports };
        return out;
    }
    fn outer(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        const dep = try ctx.requireByName("Module:IsolationDependency");
        const state = try ctx.getIndex(dep, .{ .string = "state" });
        if (state != .string or !std.mem.eql(u8, state.string, "pristine"))
            return error.NestedInvokeInheritedCallerMutation;
        try dep.table.rawSet(ctx.allocator, .{ .string = "state" }, .{ .string = "mutated" });
        const exports = try ctx.newTable();
        try exports.rawSet(ctx.allocator, .{ .string = "run" }, try ctx.makeFunctionKnown(2, run, &.{}));
        try exports.rawSet(ctx.allocator, .{ .string = "inner" }, try ctx.makeFunctionKnown(3, inner, &.{}));
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .table = exports };
        return out;
    }
    fn inner(_: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .string = "nested pristine" };
        return out;
    }
    fn run(ctx: *rt.Context, _: rt.Captures, args: []const Value) ![]const Value {
        if (args.len != 1 or args[0] != .table) return error.FrameExpected;
        const before = try ctx.requireByName("Module:IsolationDependency");
        const parser = try ctx.getIndex(args[0], .{ .string = "callParserFunction" });
        const spec = try ctx.newTable();
        const parser_args = try ctx.newTable();
        try parser_args.rawSet(ctx.allocator, .{ .number = 1 }, .{ .string = "IsolationOuter" });
        try parser_args.rawSet(ctx.allocator, .{ .number = 2 }, .{ .string = "inner" });
        try spec.rawSet(ctx.allocator, .{ .string = "name" }, .{ .string = "#invoke" });
        try spec.rawSet(ctx.allocator, .{ .string = "args" }, .{ .table = parser_args });
        const nested = try ctx.callValue(parser, &.{ args[0], .{ .table = spec } });
        defer rt.freeResults(nested);
        if (nested.len != 1 or nested[0] != .string or !std.mem.eql(u8, nested[0].string, "nested pristine"))
            return error.NestedInvokeNotPristine;
        const after = try ctx.requireByName("Module:IsolationDependency");
        if (before != .table or after != .table or before.table != after.table)
            return error.CallerRequireIdentityChanged;
        const state = try ctx.getIndex(after, .{ .string = "state" });
        if (state != .string or !std.mem.eql(u8, state.string, "mutated"))
            return error.CallerMutationLost;
        // The page-local flags are live only inside the active invocation.
        if (ctx.module_template_rejected.len != 2 or ctx.module_template_rejected[1])
            return error.DependencyTemplateRejected;
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .string = "isolated nested; caller retained" };
        return out;
    }
};

test "nested frame parser invoke uses pristine page templates and retains caller require identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 24, 2);
    defer runtime.deinit();
    const roots = [_]rt.FunctionFn{ rt.stabilize(NestedInvokeIsolationProbe.outer), rt.stabilize(NestedInvokeIsolationProbe.dependency) };
    const function_modules = [_]u32{ 0, 1, 0, 0 };
    var eligible = [_]bool{ false, true };
    var rejected = [_]bool{ false, false };
    runtime.module_root_entries = &roots;
    runtime.function_module_ids = &function_modules;
    runtime.module_template_eligible = &eligible;
    runtime.module_template_rejected = &rejected;
    runtime.configureModules(null, NestedInvokeIsolationProbe.lookup, NestedInvokeIsolationProbe.moduleName);
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander = Expander{
        .runtime = &runtime,
        .env_slot = 0,
        .string_slot = 18,
        .mw_slot = 23,
        .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists },
        .install_scribunto = installTestInvoke,
    };
    NestedInvokeIsolationProbe.dependency_roots = 0;
    const text = try expander.expandFragment("Page", "{{#invoke:IsolationOuter|run}}", 1_670_803_200);
    try std.testing.expectEqualStrings("isolated nested; caller retained", text);
    // One root execution proves the nested call used an eligible promoted
    // dependency template rather than vacuously rerunning a fresh callback.
    try std.testing.expectEqual(@as(usize, 1), NestedInvokeIsolationProbe.dependency_roots);
    // expandFragment releases page-owned flags before returning and restores
    // the caller's template flags; inspect that live baseline after cleanup.
    try std.testing.expectEqual(@as(usize, 0), expander.page_template_rejected.len);
    try std.testing.expect(!runtime.module_template_rejected[1]);
}

test "invoke cleanup preserves the captured Orto byte API defect as valid rendered source" {
    // antikité p73940/r415175 invokes Modele:Orto p50674/r224673.
    // Its exact template body calls Ortografeyes.init. This focused module
    // excerpt uses the real Unicode-find and byte-sub/gsub APIs from the
    // authenticated module p50672/r431540 lines106-120, followed by the
    // link spelling from Riscrijhaedje p56446/r405607 lines378-390.
    const Case = struct {
        fn lookup(_: ?*const anyopaque, title: []const u8) ?u32 {
            return if (std.mem.eql(u8, title, "Module:Ortografeyes")) 0 else null;
        }
        fn moduleName(_: ?*const anyopaque, id: u32) ?[]const u8 {
            return if (id == 0) "Module:Ortografeyes" else null;
        }
        fn exists(_: ?*anyopaque, title: []const u8) !bool {
            return std.mem.eql(u8, title, "Template:Orto");
        }
        fn template(_: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
            return if (std.mem.eql(u8, title, "Template:Orto"))
                "<includeonly>{{#invoke:Ortografeyes|init}}</includeonly><noinclude>{{doc|lua=Ortografeyes}}<noinclude>"
            else
                null;
        }
        fn root(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
            const exports = try ctx.newTable();
            try exports.rawSet(ctx.allocator, .{ .string = "init" }, try ctx.makeFunctionKnown(1, run, &.{}));
            // Separate synthetic control: normalize only after returned Lua
            // strings are concatenated, never each internal byte value.
            try exports.rawSet(ctx.allocator, .{ .string = "nfd" }, try ctx.makeFunctionKnown(2, nfd, &.{}));
            const result = try std.heap.smp_allocator.alloc(Value, 1);
            result[0] = .{ .table = exports };
            return result;
        }
        fn nfd(_: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
            const result = try std.heap.smp_allocator.alloc(Value, 2);
            result[0] = .{ .string = "e" };
            result[1] = .{ .string = "\u{301}" };
            return result;
        }
        fn run(ctx: *rt.Context, _: rt.Captures, args: []const Value) ![]const Value {
            if (args.len != 1 or args[0] != .table) return error.FrameExpected;
            try std.testing.expect(ctx.current_frame == args[0].table);
            const get_parent = try ctx.getIndex(args[0], .{ .string = "getParent" });
            const parents = try ctx.callValue(get_parent, &.{args[0]});
            defer rt.freeResults(parents);
            try std.testing.expect(parents.len == 1 and parents[0] == .table);
            const parent_args = try ctx.getIndex(parents[0], .{ .string = "args" });
            const word = "antiquité (antikité)";
            const refs = try ctx.getIndex(parent_args, .{ .string = word });
            try std.testing.expect(refs == .string);
            try std.testing.expectEqualStrings("E1,E34", refs.string);
            const mw = ctx.getGlobal(23).table;
            const unicode = mw.rawGet(.{ .string = "ustring" }).?.table;
            const find = unicode.rawGet(.{ .string = "find" }).?;
            const found = try ctx.callValue(find, &.{ .{ .string = word }, .{ .string = " %([^%)][^%)]" } });
            defer rt.freeResults(found);
            try std.testing.expect(found.len >= 2 and found[0] == .number);
            try std.testing.expectEqual(@as(f64, 10), found[0].number);
            const strings = ctx.getGlobal(18).table;
            const sub = strings.rawGet(.{ .string = "sub" }).?;
            const prefix = try ctx.callValue(sub, &.{ .{ .string = word }, .{ .number = 1 }, .{ .number = found[0].number - 1 } });
            defer rt.freeResults(prefix);
            // Lua byte strings must remain byte strings inside the module.
            try std.testing.expectEqualSlices(u8, "antiquit\xc3", prefix[0].string);
            try std.testing.expect(!std.unicode.utf8ValidateSlice(prefix[0].string));
            const suffix = try ctx.callValue(sub, &.{ .{ .string = word }, .{ .number = found[0].number + 2 } });
            defer rt.freeResults(suffix);
            const strip = strings.rawGet(.{ .string = "gsub" }).?;
            const tail = try ctx.callValue(strip, &.{ suffix[0], .{ .string = "%)$" }, .{ .string = "" } });
            defer rt.freeResults(tail);
            try std.testing.expectEqualStrings("(antikité", tail[0].string);
            const text = try std.fmt.allocPrint(ctx.allocator, "[[{s}#Walon-Feller|{s}]] ( [[{s}#Walon-Feller|{s}]] )", .{
                prefix[0].string, prefix[0].string, tail[0].string, tail[0].string,
            });
            const result = try std.heap.smp_allocator.alloc(Value, 1);
            result[0] = .{ .string = text };
            return result;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 24, 1);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{ rt.stabilize(Case.root), rt.stabilize(Case.run), rt.stabilize(Case.nfd) };
    runtime.module_root_entries = &functions;
    runtime.configureModules(null, Case.lookup, Case.moduleName);
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23,
        .provider = .{ .get = Case.template, .exists = Case.exists }, .install_scribunto = installTestInvoke };
    const text = try expander.expandFragment("antikité", "{{Orto| antiquité (antikité) = E1,E34 }}", 1_670_803_200);
    try std.testing.expectEqualStrings("[[antiquit\u{fffd}#Walon-Feller|antiquit\u{fffd}]] ( [[(antikité#Walon-Feller|(antikité]] )", text);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text));
    // The source's defective spelling and opening parenthesis are not repaired.
    try std.testing.expect(std.mem.indexOf(u8, text, "[[antiquité#") == null);
    try std.testing.expectEqualStrings("é", try expander.expandFragment("NFC boundary control", "{{#invoke:Ortografeyes|nfd}}", 1_670_803_200));
}


test "time parser keeps source citation comparison numeric and relative dates clock bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 24);
    defer runtime.deinit();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists } };
    const source = "{{#time:YmdHis|- 30 days}}|{{#ifexpr:{{#time:YmdHis|- 30 days}}<=20150910192507|fabd23|c00}}|{{#time:j. n. Y H:i:s|20150910192507 +2 hours}}";
    try std.testing.expectEqualStrings("20260911151240|c00|10. 9. 2015 21:25:07", try expander.expandFragment("biola", source, 1_791_731_560));
    const young = "{{#ifexpr:{{#time:YmdHis|- 30 days}}<=20261010192507|fabd23|c00}}";
    try std.testing.expectEqualStrings("fabd23", try expander.expandFragment("biola", young, 1_791_731_560));
    try std.testing.expectEqualStrings("ERR|ERR", try expander.expandFragment("biola", "{{#iferror:{{#time:Y|bad +2 hours}}|ERR|BAD}}|{{#iferror:{{#expr:1+}}|ERR|BAD}}", 1_791_731_560));
    const args = try runtime.newTable();
    try args.rawSet(arena.allocator(), .{ .number = 1 }, .{ .string = "Y-m-d H:i:s" });
    try args.rawSet(arena.allocator(), .{ .number = 2 }, .{ .string = "20150910192507 +1 hours" });
    try std.testing.expectEqualStrings("2015-09-10 20:25:07", try Expander.hostFrameParserFunction(&expander, arena.allocator(), "#time", args));
}

test "retained Slovak citation attribute slice expands without fabricated error markup" {
    // Exact first sup slice of captured template p12661/r121670. The offset
    // provider selects each possible DateTime.getUtcOffset result; this test
    // does not claim to execute that Lua module or re-expand the whole page.
    const Source = struct {
        offset: []const u8,
        const citation = "&lrm;<sup dir=\"ltr\" class=\"Šablóna__Doplňte_zdroj\" style=\"border: 2px solid #{{#ifexpr:{{#time:YmdHis|- 30 days}}<={{{1<noinclude>|{{#time:YmdHis}}</noinclude>}}}|fabd23|c00}};\"><span title=\"Je potrebné doložiť zdroj predchádzajúceho tvrdenia alebo citácie. Označené {{#time:j. n. Y H:i:s|{{{1|}}} +{{CURRENTUTCOFFSET}} hours}} SE(L)Č.\">zdroj?</span></sup>";
        fn get(raw: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (std.mem.eql(u8, title, "Template:CitationShape")) return citation;
            if (std.mem.eql(u8, title, "Template:CURRENTUTCOFFSET")) return self.offset;
            return null;
        }
        fn exists(_: ?*anyopaque, title: []const u8) !bool {
            return std.mem.eql(u8, title, "Template:CitationShape") or std.mem.eql(u8, title, "Template:CURRENTUTCOFFSET");
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 24);
    defer runtime.deinit();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var source: Source = .{ .offset = "2" };
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .ctx = &source, .get = Source.get, .exists = Source.exists } };
    const expected_two = "&lrm;<sup dir=\"ltr\" class=\"Šablóna__Doplňte_zdroj\" style=\"border: 2px solid #c00;\"><span title=\"Je potrebné doložiť zdroj predchádzajúceho tvrdenia alebo citácie. Označené 10. 9. 2015 21:25:07 SE(L)Č.\">zdroj?</span></sup>";
    try std.testing.expectEqualStrings(expected_two, try expander.expandFragment("biola", "{{CitationShape|20150910192507}}", 1_791_731_560));
    source.offset = "1";
    const expected_one = "&lrm;<sup dir=\"ltr\" class=\"Šablóna__Doplňte_zdroj\" style=\"border: 2px solid #c00;\"><span title=\"Je potrebné doložiť zdroj predchádzajúceho tvrdenia alebo citácie. Označené 10. 9. 2015 20:25:07 SE(L)Č.\">zdroj?</span></sup>";
    try std.testing.expectEqualStrings(expected_one, try expander.expandFragment("biola", "{{CitationShape|20150910192507}}", 1_791_731_560));
}


test "wikitext host forwards exact supported language evidence and errors" {
    const Probe = struct {
        calls: usize = 0,
        fn get(raw: ?*anyopaque, code: []const u8) !bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            if (std.mem.eql(u8, code, "nl")) return true;
            if (std.mem.eql(u8, code, "fr")) return false;
            if (std.mem.eql(u8, code, "oom")) return error.OutOfMemory;
            return error.LanguageSupportSnapshotMissing;
        }
    };
    var runtime = try rt.Context.init(std.testing.allocator, 0);
    defer runtime.deinit();
    var probe: Probe = .{};
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{
        .ctx = &probe, .get = TestProvider.get, .exists = TestProvider.exists, .language_supported = Probe.get,
    } };
    expander.attach();
    const get = expander.host.language_supported orelse return error.TestUnexpectedResult;
    try std.testing.expect(try get(expander.host.ctx, "nl"));
    try std.testing.expect(!try get(expander.host.ctx, "fr"));
    try std.testing.expectError(error.LanguageSupportSnapshotMissing, get(expander.host.ctx, "zz"));
    try std.testing.expectError(error.OutOfMemory, get(expander.host.ctx, "oom"));
    try std.testing.expectEqual(@as(usize, 4), probe.calls);
    expander.provider.language_supported = null;
    expander.attach();
    try std.testing.expect(expander.host.language_supported == null);
}

test "ordinary tag parser fallback preserves names content attributes and registered extension effects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 24);
    defer runtime.deinit();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23,
        .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists } };
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "before {{#tag:SPAN|[[B]]&ensp;|class=movil|style=visibility:hidden;}} after", .expected = "before <span class=\"movil\" style=\"visibility:hidden;\">[[B]]&ensp;</span> after" },
        .{ .source = "{{#tag:DIV|body|title=\"a&b\"}}", .expected = "<div title=\"a&amp;b\">body</div>" },
        .{ .source = "{{#tag:No-Hook_Tag|body}}", .expected = "<no-hook_tag>body</no-hook_tag>" },
        .{ .source = "{{#tag:span}}", .expected = "<span/>" },
        .{ .source = "{{#tag:span|}}", .expected = "<span></span>" },
        .{ .source = "{{#tag:ref|note|name=n}}", .expected = "<ref name=\"n\">note</ref>" },
        .{ .source = "{{#tag:templatestyles||src=Módulo:flex/estilo.css}}", .expected = "<templatestyles src=\"Módulo:flex/estilo.css\"></templatestyles>" },
    };
    for (cases) |case| {
        errdefer std.debug.print("ordinary tag source={s}\n", .{case.source});
        try std.testing.expectEqualStrings(case.expected, try expander.expandFragment("Page", case.source, 1_791_731_560));
    }
    // Scope limits are explicit; malformed tag-name bytes are not a hook bypass.
    for ([_][]const u8{ "", "span onclick=x", "span><ref", "span/", "span\nother" }) |name|
        try std.testing.expectError(error.UnsupportedExtensionTag, expander.serializeOrdinaryTag(name, .{ .string = "body" }, null));
    // A registered name must never be sent through the ordinary serializer.
    try std.testing.expectError(error.UnsupportedExtensionTag, expander.serializeOrdinaryTag("nowiki", .{ .string = "body" }, null));
}

test "native frame ordinary span calls preserve literal values and exact flex label pattern" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 24);
    defer runtime.deinit();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23,
        .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists } };
    _ = try expander.expandFragment("Page", "seed", 1_791_731_560);
    const args = try runtime.newTable();
    const frame = try frame_lib.makeFrameFromTable(&runtime, "Module:Probe", args, null);
    const tag = try runtime.getIndex(frame, .{ .string = "extensionTag" });
    const attrs = try runtime.newTable();
    try attrs.rawSet(runtime.allocator, .{ .string = "class" }, .{ .string = "movil" });
    try attrs.rawSet(runtime.allocator, .{ .string = "style" }, .{ .string = "visibility:hidden;" });
    const before = expander.strip_counter;
    // This is the exact Módulo:flex renderizar_tabla call shape; the supplied
    // label is a representative API value, not invented full declension output.
    const result = try runtime.callValue(tag, &.{ frame, .{ .string = "span" }, .{ .string = "οὐσία&ensp;" }, .{ .table = attrs } });
    defer rt.freeResults(result);
    try std.testing.expectEqualStrings("<span class=\"movil\" style=\"visibility:hidden;\">οὐσία&ensp;</span>", result[0].string);
    try std.testing.expectEqual(before, expander.strip_counter);
    const empty = try runtime.callValue(tag, &.{ frame, .{ .string = "SPAN" }, .nil });
    defer rt.freeResults(empty);
    try std.testing.expectEqualStrings("<span></span>", empty[0].string);
    const quoted = try runtime.newTable();
    try quoted.rawSet(runtime.allocator, .{ .string = "title" }, .{ .string = " \"literal&\" " });
    const literal = try runtime.callValue(tag, &.{ frame, .{ .string = " SPAN " }, .{ .string = "{{#if:x|not preprocessed}}" }, .{ .table = quoted } });
    defer rt.freeResults(literal);
    try std.testing.expectEqualStrings("<span title=\" &quot;literal&amp;&quot; \">{{#if:x|not preprocessed}}</span>", literal[0].string);
    const strange = try runtime.newTable();
    try strange.rawSet(runtime.allocator, .{ .string = "bad&\"'" }, .{ .string = "<&\"'" });
    try std.testing.expectEqualStrings("<span bad&amp;&quot;&#039;=\"&lt;&amp;&quot;'\">body</span>", try Expander.hostFrameExtensionTag(&expander, runtime.allocator, "span", .{ .string = "body" }, strange));
    const named = try runtime.newTable();
    try named.rawSet(runtime.allocator, .{ .number = 1 }, .{ .string = "body" });
    try named.rawSet(runtime.allocator, .{ .string = "class" }, .{ .string = " \"movil\" " });
    try std.testing.expectEqualStrings("<span class=\"movil\">body</span>", try expander.frameParserTag(&expander, runtime.allocator, "#tag:span", named));
    const marker = try runtime.callValue(tag, &.{ frame, .{ .string = "nowiki" }, .{ .string = "[[literal]]" } });
    defer rt.freeResults(marker);
    try std.testing.expect(std.mem.startsWith(u8, marker[0].string, nowiki_marker_prefix));
    try std.testing.expectEqual(before + 1, expander.strip_counter);
    const marked = try runtime.newTable();
    try marked.rawSet(runtime.allocator, .{ .string = "title" }, .{ .string = try std.fmt.allocPrint(runtime.allocator, "before{s}after", .{marker[0].string}) });
    try std.testing.expectEqualStrings("<span title=\"beforeafter\">body</span>", try Expander.hostFrameExtensionTag(&expander, runtime.allocator, "span", .{ .string = "body" }, marked));
    const marked_ref = try std.fmt.allocPrint(runtime.allocator, "re{s}f", .{marker[0].string});
    try std.testing.expectEqualStrings("<ref>note</ref>", try Expander.hostFrameExtensionTag(&expander, runtime.allocator, marked_ref, .{ .string = "note" }, null));
}

test "native Cite raw attributes do not transclude while note bodies and surrounding templates do" {
    const Source = struct {
        attribute_calls: usize = 0,
        body_calls: usize = 0,
        fn get(raw: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (std.mem.eql(u8, title, "Template:DLCE1906")) {
                self.attribute_calls += 1;
                return null;
            }
            if (std.mem.eql(u8, title, "Template:Body")) {
                self.body_calls += 1;
                return "''book'' [[Target|entry]]";
            }
            if (std.mem.eql(u8, title, "Template:Fail")) return error.OutOfMemory;
            return null;
        }
        fn exists(raw: ?*anyopaque, title: []const u8) anyerror!bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (std.mem.eql(u8, title, "Template:DLCE1906")) {
                self.attribute_calls += 1;
                return false;
            }
            return std.mem.eql(u8, title, "Template:Body") or std.mem.eql(u8, title, "Template:Fail");
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var source: Source = .{};
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .ctx = &source, .get = Source.get, .exists = Source.exists } };
    const input = "before {{Body}}<ref name=\"dlce1906\"<{{DLCE1906|210}}>{{Body}}</ref> after {{Body}}<references/>";
    const expected = "before ''book'' [[Target|entry]]<ref name=\"dlce1906\"<{{DLCE1906|210}}>''book'' [[Target|entry]]</ref> after ''book'' [[Target|entry]]<references/>";
    try std.testing.expectEqualStrings(expected, try expander.expandFragment("Page", input, null));
    try std.testing.expectEqual(@as(usize, 0), source.attribute_calls);
    try std.testing.expect(source.body_calls != 0);
    try std.testing.expect(expander.missing_dependency_metadata == null);
    try std.testing.expectEqual(@as(usize, 0), expander.dependency_page.occurrences.items.len);
    for ([_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "<ref name='{{DLCE1906}}'>{{Body}}</ref>", .expected = "<ref name='{{DLCE1906}}'>''book'' [[Target|entry]]</ref>" },
        .{ .input = "<ref name='{{DLCE1906}}'/>{{Body}}", .expected = "<ref name='{{DLCE1906}}'/>''book'' [[Target|entry]]" },
        .{ .input = "<ref name='{{DLCE1906}}'>{{Body}}", .expected = "<ref name='{{DLCE1906}}'>''book'' [[Target|entry]]" },
        .{ .input = "<references group='{{DLCE1906}}'><ref name=n>{{Body}}</ref></references>", .expected = "<references group='{{DLCE1906}}'><ref name=n>''book'' [[Target|entry]]</ref></references>" },
        .{ .input = "<nowiki><ref name='{{DLCE1906}}'>{{Body}}</ref></nowiki>", .expected = "<nowiki><ref name='{{DLCE1906}}'>{{Body}}</ref></nowiki>" },
        .{ .input = "<math><ref>{{Body}}</ref></math>", .expected = "<math><ref>{{Body}}</ref></math>" },
    }) |case| {
        try std.testing.expectEqualStrings(case.expected, try expander.expandFragment("Page", case.input, null));
        try std.testing.expectEqual(@as(usize, 0), source.attribute_calls);
        try std.testing.expect(expander.missing_dependency_metadata == null);
    }
    // A real missing body call still produces exactly its ordinary diagnostic.
    const missing = try expander.expandFragment("Page", "<ref name=n>{{DLCE1906}}</ref>", null);
    try std.testing.expectEqualStrings("<ref name=n>[[:Template:DLCE1906]]</ref>", missing);
    var phase = try dependency.decode(a, expander.missing_dependency_metadata.?, missing, "");
    defer phase.deinit();
    try std.testing.expectEqual(@as(usize, 1), phase.occurrences().len);
    try std.testing.expectEqualStrings("Template:DLCE1906", phase.occurrences()[0].title);
    // Active-body allocator failure is never converted to a reference or text.
    try std.testing.expectError(error.OutOfMemory, expander.expandFragment("Page", "<ref name=n<bad>{{Fail}}</ref>", null));
}

test "captured ISBN alias drives normal tracked and untracked expansion with whole argument strip data" {
    const aliases = rt.namespace_registry.magic_words;
    const Source = struct {
        words: *const aliases.Registry,
        fn parser(raw: ?*anyopaque, name: []const u8) !?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.words.resolve(name, .parser_function);
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Exact retained DE isbn row: raw bdf56c039951...; other row is a test
    // callback used to prove eager evaluation of ignored ordinary arguments.
    var words = try aliases.Registry.init(a, aliases.parser_header ++ "\n# wiki\tdewiktionary\n# dump-date\t20261001\n# content-language\tde\nisbn\t1\t#isbn\ndisplaytitle\t1\tDISPLAYTITLE\n", "dewiktionary", "20261001", "de");
    defer words.deinit();
    var source: Source = .{ .words = &words };
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander: Expander = .{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .ctx = &source, .get = TestProvider.get, .exists = TestProvider.exists, .resolve_parser_function = Source.parser } };
    const cases = [_]struct { source: []const u8, argument: []const u8, target: []const u8 }{
        .{ .source = "{{#isbn:978-83-239-9999-7}}", .argument = "978-83-239-9999-7", .target = "Special:Booksources/9788323999997" },
        .{ .source = "{{#isbn:pre_x123456789x#tail[[A|B]]<b>C</b>\u{2028}end}}", .argument = "pre_x123456789x#tail[[A|B]]<b>C</b>\u{2028}end", .target = "Special:Booksources/pre X123456789X#tail[[A|B]]<b>C</b>\u{2028}end" },
        .{ .source = "{{#isbn: 123\t45&nbsp;6&#160;7&#xA0;8\u{2007}9x }}", .argument = "123 45 6 7 8 9x", .target = "Special:Booksources/123456789X" },
    };
    for (cases) |case| {
        const output = try expander.expandFragment("Page", case.source, 1_670_803_200);
        try std.testing.expect(!expander.unsupported_parser_function);
        try std.testing.expectEqual(@as(usize, 1), expander.output_links.items.len);
        const item = expander.output_links.items[0];
        try std.testing.expectEqual(@as(u32, 0), item.start);
        try std.testing.expectEqual(output.len, @as(usize, item.end));
        try std.testing.expectEqualStrings(item.value.token, output);
        try std.testing.expectEqualStrings(case.argument, item.value.argument);
        try std.testing.expectEqualStrings(case.target, item.value.target);
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "ISBN {s}", .{case.argument}), item.value.label);
        const metadata = expander.poem_metadata orelse return error.TestUnexpectedResult;
        const parsed = try std.json.parseFromSlice(PoemMetadata, a, metadata, .{});
        try std.testing.expectEqualStrings("wikidict.presentation-phase.v2", parsed.value.schema);
        try std.testing.expectEqualDeep(item.value, parsed.value.output_links[0].value);
        expander.beginPage("Page", case.source, 1_670_803_200);
        const params = try runtime.newTable();
        const intermediate = try expander.expandWikitext(case.source, params, "Page", 0);
        const untracked = try expander.restoreIsbnMarkers(a, intermediate, &expander.output_links);
        try expander.finishPoemMetadata(untracked);
        try std.testing.expectEqualStrings(output, untracked);
        try std.testing.expectEqualStrings(metadata, expander.poem_metadata.?);
    }
    _ = try expander.expandFragment("Page", "{{#isbn:9788323999997|{{DISPLAYTITLE:Page}}}}", 1_670_803_200);
    try std.testing.expectEqualStrings("Page", expander.display_title.?);
    try std.testing.expect(!expander.unsupported_parser_function);
    try std.testing.expectEqualStrings("&#123;&#123;#isbn:short&#125;&#125;", try expander.expandFragment("Page", "{{#isbn:short}}", 1_670_803_200));
    try std.testing.expect(expander.unsupported_parser_function);
    try std.testing.expectEqual(@as(usize, 0), expander.output_links.items.len);
    try std.testing.expect(words.resolve("#ISBN", .parser_function) == null);
    try std.testing.expect(words.resolve("isbn", .parser_function) == null);
    const literal = "<nowiki>{{#isbn:9788323999997}}</nowiki>";
    try std.testing.expectEqualStrings(literal, try expander.expandFragment("Page", literal, 1_670_803_200));
    try std.testing.expectEqual(@as(usize, 0), expander.output_links.items.len);
}

test "ISBN native frame general strip values retain page ownership and reset on the next page" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.init(a, 24);
    defer runtime.deinit();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander: Expander = .{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists } };
    expander.beginPage("Page", "", 1_670_803_200);
    const args = try runtime.newTable();
    try args.rawSet(a, .{ .number = 1 }, .{ .string = "9781234567890#tail[[A|B]]<b>C</b>\u{2028}end" });
    const marker = try Expander.hostFrameParserFunction(&expander, a, "#isbn", args);
    try std.testing.expect(std.mem.startsWith(u8, marker, isbn_marker_prefix));
    const inside_nowiki = try expander.finalNowikiBody(a, marker);
    try std.testing.expectEqualStrings(marker, inside_nowiki);
    const output = try expander.restoreIsbnMarkers(a, inside_nowiki, &expander.output_links);
    try expander.finishPoemMetadata(output);
    try std.testing.expectEqual(@as(usize, 1), expander.output_links.items.len);
    try std.testing.expectEqualStrings("Special:Booksources/9781234567890#tail[[A|B]]<b>C</b>\u{2028}end", expander.output_links.items[0].value.target);
    const colon_marker = try Expander.hostFrameParserFunction(&expander, a, "#isbn:9788323999997", try runtime.newTable());
    try std.testing.expect(std.mem.startsWith(u8, colon_marker, isbn_marker_prefix));
    try std.testing.expectError(error.UnsupportedParserFunction, Expander.hostFrameParserFunction(&expander, a, "#isbn\u{ff1a}9788323999997", try runtime.newTable()));
    const body_token = try expander.poemLiteral("poem", colon_marker);
    const body_item = expander.poem_items.items[expander.poem_items.items.len - 1];
    try std.testing.expectEqual(@as(usize, 1), body_item.generated_links.len);
    try std.testing.expectEqualStrings(body_item.generated_links[0].value.token, body_item.body.?);
    try std.testing.expect(std.mem.indexOf(u8, body_item.body.?, isbn_marker_prefix) == null);
    try expander.finishPoemMetadata(body_token);
    const body_metadata = try std.json.parseFromSlice(PoemMetadata, a, expander.poem_metadata.?, .{});
    try std.testing.expectEqualDeep(body_item.generated_links[0], body_metadata.value.items[0].generated_links[0]);
    try args.rawSet(a, .{ .number = 1 }, .{ .string = "invalid" });
    try std.testing.expectError(error.UnsupportedParserFunction, Expander.hostFrameParserFunction(&expander, a, "#isbn", args));
    for ([_][]const u8{ "9781234567890\nend", "9781234567890\rend", "9781234567890_" }) |argument| {
        try args.rawSet(a, .{ .number = 1 }, .{ .string = argument });
        try std.testing.expectError(error.InvalidIsbnTitleTarget, Expander.hostFrameParserFunction(&expander, a, "#isbn", args));
        const source = try std.fmt.allocPrint(a, "{{{{#isbn:{s}}}}}", .{argument});
        try std.testing.expectError(error.InvalidIsbnTitleTarget, expander.expandFragment("Invalid", source, 1_670_803_200));
        try std.testing.expectEqual(@as(usize, 0), expander.strip_values.count());
        try std.testing.expectEqual(@as(usize, 0), expander.output_links.items.len);
    }
    // Same-branch Scribunto LuaEngine915-917 raises a function-not-found error
    // for core found=false. Do not turn invalid input into an empty success.
    try std.testing.expectEqualStrings("next", try expander.expandFragment("Next", "next", 1_670_803_200));
    try std.testing.expectEqual(@as(usize, 0), expander.output_links.items.len);
    try std.testing.expectEqual(@as(usize, 0), expander.display_title_links.items.len);
    try std.testing.expectEqual(@as(usize, 0), expander.strip_values.count());
    try std.testing.expect(expander.poem_metadata == null);
    try std.testing.expect(expander.ownedStripMarker(marker, 0, isbn_marker_prefix, .isbn) == null);
    expander.strip_counter = std.math.maxInt(u32);
    try std.testing.expectError(error.FrameTooLarge, expander.isbnStrip("9788323999997"));
    try std.testing.expectEqual(std.math.maxInt(u32), expander.strip_counter);
    try std.testing.expectEqual(@as(usize, 0), expander.strip_values.count());
}


test "failed native dispatch preserves plain static colon computed title as literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.init(a, 24); defer runtime.deinit();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    const Source = struct {
        fn parser(_: ?*anyopaque, name: []const u8) anyerror!?[]const u8 {
            // Controlled explicit alias: callable heads must return before the
            // invalid-title recovery, even when their argument contains braces.
            return if (std.mem.eql(u8, name, "callable")) "#if" else null;
        }
    };
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23,
        .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists, .resolve_parser_function = Source.parser } };
    for ([_][]const u8{ "родств:eo:{{{родств-блок}}}", "name：scope:{{{missing}}}" }) |name| {
        const invocation = try std.fmt.allocPrint(a, "{{{{{s}}}}}", .{name});
        const expected = try std.fmt.allocPrint(a, "<nowiki>{s}</nowiki>", .{invocation});
        try std.testing.expectEqualStrings(expected, try expander.expandFragment("denaske", invocation, 1_791_731_560));
        try std.testing.expect(!expander.unsupported_parser_function);
        const params = try runtime.newTable();
        try std.testing.expectEqualStrings(expected, try expander.expandConstruct(name, params, "denaske", 0));
    }
    try std.testing.expectEqualStrings("yes", try expander.expandFragment("Page", "{{callable:{{{missing}}}|yes|no}}", 1_791_731_560));
    try std.testing.expectEqualStrings("{{plain_{{{missing}}}}}", try expander.expandFragment("Page", "{{plain_{{{missing}}}}}", 1_791_731_560));
    for ([_][]const u8{
        "{{{head}}}:{{{missing}}}", "name:{{{missing|default}}}", "name:{{{}}}",
        "name:{{{bad:name}}}", "name:{{{missing}}}[[Target]]", "name:{{{missing}}}<b>x</b>",
        "name:{{{missing}}}''x''", "name:{{{missing}}}|argument", "#unknown:{{{missing}}}",
        "name:{{{missing}}}\n", "name:\xff{{{missing}}}",
    }) |name| try std.testing.expect(!Expander.literalComputedColonTitle(name, name, 1));
    try std.testing.expect(!Expander.literalComputedColonTitle("name:{{{missing}}}", "name:resolved", 1));
    try std.testing.expect(!Expander.literalComputedColonTitle("name:{{{missing}}}", "name:{{{missing}}}", 2));
}

const FilePageMagicSource = struct {
    fn install(_: *?*anyopaque, _: ?*anyopaque, _: std.mem.Allocator, runtime: *rt.Context, _: u32, string_slot: u32, mw_slot: u32) !void {
        // These functions use the same ordinary title primitives as the normal host.
        try installTestHostWithTitle(runtime, string_slot, mw_slot, true);
    }
    words: *const rt.namespace_registry.magic_words.Registry,
    file_calls: usize = 0,
    page_calls: usize = 0,
    fn parser(raw: ?*anyopaque, name: []const u8) !?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        return self.words.resolve(name, .parser_function);
    }
    fn alias(raw: ?*anyopaque, name: []const u8, form: rt.namespace_registry.magic_words.Form) !?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        return self.words.resolve(name, form);
    }
    fn file(raw: ?*anyopaque, title: []const u8, size_argument: []const u8) ![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw.?)); self.file_calls += 1;
        if (std.mem.eql(u8, title, "File:Absent.svg") and size_argument.len == 0) return "";
        if (std.mem.eql(u8, title, "File:File:A.svg") and size_argument.len == 0) return "//media.example/literal-prefix.svg";
        if (!std.mem.eql(u8, title, "File:A.svg")) return error.FilePathSnapshotMissing;
        if (size_argument.len == 0) return "https://media.example/A.svg";
        if (std.mem.eql(u8, size_argument, "100")) return "//media.example/thumb/A.svg/100px-A.svg.png";
        return error.FilePathSnapshotMissing;
    }
    fn size(raw: ?*anyopaque, title: []const u8) !u64 {
        const self: *@This() = @ptrCast(@alignCast(raw.?)); self.page_calls += 1;
        if (std.mem.eql(u8, title, "Page")) return 1234;
        if (std.mem.eql(u8, title, "Other page")) return 7;
        if (std.mem.eql(u8, title, "Absent")) return 0;
        if (std.mem.eql(u8, title, "Denied")) return error.AccessDenied;
        return error.PageSizeSnapshotMissing;
    }
    fn formatted(_: ?*anyopaque, _: std.mem.Allocator, count: u64, _: Provider.PageSizeFormatContext) ![]const u8 {
        return switch (count) { 0 => "0", 1234 => "1\u{202f}234", else => error.PageSizeFormatSnapshotMissing };
    }
};

test "source scoped filepath and page size preserve captured facts aliases title context and real missing templates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const magic = rt.namespace_registry.magic_words;
    var words = try magic.Registry.init(a, magic.parser_header ++ "\n# wiki\tenwiktionary\n# dump-date\t20261001\n# content-language\ten\n" ++
        "filepath\t0\tFILEPATH:\nfilepath\t0\tELÉRÉSIÚT:\npagesize\t1\tPAGESIZE\npagesize\t1\tLAPMÉRET\nrawsuffix\t1\tR\npagename\t1\tPAGENAME\nifexpr\t0\tifexpr\n", "enwiktionary", "20261001", "en");
    defer words.deinit();
    var source: FilePageMagicSource = .{ .words = &words };
    var runtime = try rt.Context.initProgram(a, 24, 1); defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHostWithTitle(&runtime, 18, 23, true);
    var expander: Expander = .{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23,
        .provider = .{ .ctx = &source, .get = TestProvider.get, .exists = TestProvider.exists,
            .resolve_parser_function = FilePageMagicSource.parser, .resolve_title_magic = FilePageMagicSource.alias,
            .raw_suffix_profile = true, .file_path = FilePageMagicSource.file, .page_size = FilePageMagicSource.size,
            .page_size_formatted = FilePageMagicSource.formatted, .interwiki_map = TestProvider.interwikiMap }, .install_scribunto = FilePageMagicSource.install };
    const cases = [_][2][]const u8{
        .{ "{{filepath:A.svg}}", "https://media.example/A.svg" },
        .{ "{{elérésiút:A.svg}}", "https://media.example/A.svg" },
        .{ "{{filepath:File:A.svg}}", "//media.example/literal-prefix.svg" },
        .{ "{{filepath:A.svg|100}}", "//media.example/thumb/A.svg/100px-A.svg.png" },
        .{ "{{filepath:}}/{{filepath:Absent.svg}}", "/" },
        .{ "{{PAGESIZE:Page|R}}/{{LAPMÉRET:Other_page|R}}", "1234/7" },
        .{ "{{PAGESIZE:Page}}", "1\u{202f}234" },
        .{ "{{PAGESIZE:|R}}/{{PAGESIZE:Absent|R}}/{{PAGESIZE:w:Elsewhere|R}}", "0/0/0" },
        .{ "{{#ifexpr:{{PAGESIZE:{{PAGENAME}}|R}}<11|short|long}}", "long" },
    };
    for (cases) |item| {
        try std.testing.expectEqualStrings(item[1], try expander.expandFragment("Page", item[0], 1_670_803_200));
        try std.testing.expect(expander.missing_dependency_metadata == null);
        try std.testing.expect(!expander.unsupported_parser_function);
    }
    try std.testing.expectEqualStrings("7", try expander.expandFragment("Other page", "{{PAGESIZE:{{PAGENAME}}|R}}", 1_670_803_200));
    try std.testing.expectEqualStrings("1234", try expander.expandFragment("Page", "{{PAGESIZE:{{PAGENAME}}|R}}", 1_670_803_200));
    // Authored nowiki markup and an API strip return occupy different stages.
    // Compare filepath's finalized return with the ordinary API path, and
    // independently assert the complete protected payload and lack of actions.
    for ([_][2][]const u8{
        .{ "{{filepath:A.svg|nowiki}}", "https://media.example/A.svg" },
        .{ "{{filepath:A.svg|100|nowiki}}", "//media.example/thumb/A.svg/100px-A.svg.png" },
        .{ "{{filepath:A.svg|nowiki|100}}", "//media.example/thumb/A.svg/100px-A.svg.png" },
    }) |item| {
        const actual = try a.dupe(u8, try expander.expandFragment("Page", item[0], 1_670_803_200));
        const actual_phase = try a.dupe(u8, expander.poem_metadata orelse return error.TestExpectedEqual);
        const protected = try std.json.parseFromSlice(std.json.Value, a, actual_phase, .{});
        defer protected.deinit();
        const protected_items = protected.value.object.get("items").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), protected_items.len);
        try std.testing.expectEqualStrings("literal", protected_items[0].object.get("kind").?.string);
        try std.testing.expectEqualStrings("nowiki", protected_items[0].object.get("tag").?.string);
        try std.testing.expectEqualStrings(item[1], protected_items[0].object.get("body").?.string);
        try std.testing.expectEqualStrings(actual, protected_items[0].object.get("token").?.string);
        try std.testing.expect(protected_items[0].object.get("generated_links") == null);
        try std.testing.expect(protected.value.object.get("output_links") == null);
        try std.testing.expect(protected.value.object.get("display_title_links") == null);
        try std.testing.expect(!expander.unsupported_parser_function);
        try std.testing.expect(expander.missing_dependency_metadata == null);
        const authored = try std.mem.concat(a, u8, &.{ "<nowiki>", item[1], "</nowiki>" });
        try std.testing.expectEqualStrings(authored, try expander.expandFragment("Page", authored, 1_670_803_200));
        expander.beginPage("Page", "", 1_670_803_200);
        const api_return = try Expander.hostFrameExtensionTag(&expander, a, "nowiki", .{ .string = item[1] }, null);
        const expected = try expander.finalizeNowikiMarkers(a, api_return);
        try expander.finishPoemMetadata(expected);
        try std.testing.expectEqualStrings(expected, actual);
        try std.testing.expectEqualStrings(expander.poem_metadata orelse return error.TestExpectedEqual, actual_phase);
    }
    const args = try runtime.newTable();
    try args.rawSet(a, .{ .number = 1 }, .{ .string = "Other_page" });
    try args.rawSet(a, .{ .number = 2 }, .{ .string = "R" });
    try std.testing.expectEqualStrings("7", try Expander.hostFrameParserFunction(&expander, a, "PAGESIZE", args));
    const before = source.file_calls;
    try std.testing.expectEqualStrings("", try expander.expandFragment("Page", "{{filepath:[bad]}}", 1_670_803_200));
    try std.testing.expectEqual(before, source.file_calls);
    try std.testing.expectError(error.FilePathSnapshotMissing, expander.expandFragment("Page", "{{filepath:A.svg|100px}}", 1_670_803_200));
    try std.testing.expectError(error.PageSizeSnapshotMissing, expander.expandFragment("Page", "{{PAGESIZE:Unknown|R}}", 1_670_803_200));
    try std.testing.expectError(error.PageSizeFormatSnapshotMissing, expander.expandFragment("Page", "{{PAGESIZE:Other page}}", 1_670_803_200));
    try std.testing.expectError(error.AccessDenied, expander.expandFragment("Page", "{{PAGESIZE:Denied|R}}", 1_670_803_200));
    _ = try expander.expandFragment("Page", "{{filepath:A.svg}} {{PAGESIZE:Page|R}} {{nist}} {{Webarchive}}", 1_670_803_200);
    var phase = try std.json.parseFromSlice(std.json.Value, a, expander.missing_dependency_metadata.?, .{}); defer phase.deinit();
    const occurrences = phase.value.object.get("occurrences").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), occurrences.len);
    try std.testing.expectEqualStrings("Template:nist", occurrences[0].object.get("title").?.string);
    try std.testing.expectEqualStrings("Template:Webarchive", occurrences[1].object.get("title").?.string);
    try std.testing.expect(phase.value.object.get("output").?.object.get("unknown").?.bool);
    try std.testing.expectEqualStrings("", try expander.expandFragment("Page", "{{filepath:{{nist}}}}", 1_670_803_200));
    var consumed = try std.json.parseFromSlice(std.json.Value, a, expander.missing_dependency_metadata.?, .{}); defer consumed.deinit();
    try std.testing.expectEqual(@as(usize, 1), consumed.value.object.get("occurrences").?.array.items.len);
    try std.testing.expectEqualStrings("Template:nist", consumed.value.object.get("occurrences").?.array.items[0].object.get("title").?.string);
    try std.testing.expect(consumed.value.object.get("output").?.object.get("unknown").?.bool);
    expander.provider.file_path = null;
    try std.testing.expectError(error.FilePathSnapshotMissing, expander.expandFragment("Page", "{{filepath:A.svg}}", 1_670_803_200));
    expander.provider.page_size = null;
    try std.testing.expectError(error.PageSizeSnapshotMissing, expander.expandFragment("Page", "{{PAGESIZE:Page|R}}", 1_670_803_200));
    // Existing unconfigured callers must not acquire new function authority.
    expander.provider.resolve_parser_function = null;
    // A remaining general alias provider cannot route file/page facts through
    // the title-only fallback; ordinary title aliases remain supported.
    try std.testing.expectEqualStrings("Other page", try Expander.hostFrameParserFunction(&expander, a, "PAGENAME", args));
    const unconfigured_file_calls = source.file_calls;
    const unconfigured_page_calls = source.page_calls;
    try std.testing.expectError(error.UnsupportedParserFunction, Expander.hostFrameParserFunction(&expander, a, "filepath", args));
    try std.testing.expectError(error.UnsupportedParserFunction, Expander.hostFrameParserFunction(&expander, a, "PAGESIZE", args));
    _ = try expander.expandFragment("Page", "{{filepath:A.svg}}", 1_670_803_200);
    var unconfigured = try std.json.parseFromSlice(std.json.Value, a, expander.missing_dependency_metadata.?, .{}); defer unconfigured.deinit();
    try std.testing.expectEqualStrings("Template:filepath:A.svg", unconfigured.value.object.get("occurrences").?.array.items[0].object.get("title").?.string);
    _ = try expander.expandFragment("Page", "{{PAGESIZE:Page|R}}", 1_670_803_200);
    var unconfigured_size = try std.json.parseFromSlice(std.json.Value, a, expander.missing_dependency_metadata.?, .{}); defer unconfigured_size.deinit();
    try std.testing.expectEqualStrings("Template:PAGESIZE:Page", unconfigured_size.value.object.get("occurrences").?.array.items[0].object.get("title").?.string);
    try std.testing.expectEqual(unconfigured_file_calls, source.file_calls);
    try std.testing.expectEqual(unconfigured_page_calls, source.page_calls);
}

test "parser file and page facts remain independent of mutable Lua title exports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const magic = rt.namespace_registry.magic_words;
    var words = try magic.Registry.init(a, magic.parser_header ++ "\n# wiki\tenwiktionary\n# dump-date\t20261001\n# content-language\ten\n" ++
        "filepath\t0\tFILEPATH:\npagesize\t1\tPAGESIZE\nrawsuffix\t1\tR\npagename\t1\tPAGENAME\n", "enwiktionary", "20261001", "en");
    defer words.deinit();
    var source: FilePageMagicSource = .{ .words = &words };
    var runtime = try rt.Context.initProgram(a, 24, 1); defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHostWithTitle(&runtime, 18, 23, true);
    var expander: Expander = .{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23,
        .provider = .{ .ctx = &source, .get = TestProvider.get, .exists = TestProvider.exists,
            .resolve_parser_function = FilePageMagicSource.parser, .resolve_title_magic = FilePageMagicSource.alias,
            .raw_suffix_profile = true, .file_path = FilePageMagicSource.file, .page_size = FilePageMagicSource.size,
            .interwiki_map = TestProvider.interwikiMap }, .install_scribunto = FilePageMagicSource.install };
    const Poison = struct {
        fn call(raw: ?*anyopaque, _: *rt.Context, _: []const Value) ![]const Value {
            const count: *usize = @ptrCast(@alignCast(raw.?)); count.* += 1;
            return error.LuaTitleExportWasCalled;
        }
    };
    var poisoned_calls: usize = 0;
    const poisoned = try runtime.newNative(&poisoned_calls, Poison.call);
    const mw = runtime.getGlobal(23);
    const title_exports = try runtime.getIndex(mw, .{ .string = "title" });
    const ustring_exports = try runtime.getIndex(mw, .{ .string = "ustring" });
    try runtime.setIndex(title_exports, .{ .string = "new" }, poisoned);
    try runtime.setIndex(title_exports, .{ .string = "makeTitle" }, poisoned);
    try runtime.setIndex(ustring_exports, .{ .string = "toNFC" }, poisoned);
    const input = "{{filepath:A.svg}}/{{filepath:File:A.svg}}/{{PAGESIZE:P&#97;ge|R}}/{{PAGESIZE:Other_page|R}}/{{PAGESIZE:w:Elsewhere|R}}";
    const expected = "https://media.example/A.svg///media.example/literal-prefix.svg/1234/7/0";
    try std.testing.expectEqualStrings(expected, try expander.expandFragment("Page", input, 1_670_803_200));
    try runtime.setIndex(title_exports, .{ .string = "new" }, .nil);
    try runtime.setIndex(title_exports, .{ .string = "makeTitle" }, .nil);
    try std.testing.expectEqualStrings(expected, try expander.expandFragment("Page", input, 1_670_803_200));
    try runtime.setIndex(mw, .{ .string = "title" }, .{ .table = try runtime.newTable() });
    try std.testing.expectEqualStrings(expected, try expander.expandFragment("Page", input, 1_670_803_200));
    try runtime.setIndex(mw, .{ .string = "title" }, .nil);
    try std.testing.expectEqualStrings(expected, try expander.expandFragment("Page", input, 1_670_803_200));
    try runtime.setGlobal(23, .nil);
    try std.testing.expectEqualStrings(expected, try expander.expandFragment("Page", input, 1_670_803_200));
    try std.testing.expectEqual(@as(usize, 0), poisoned_calls);
    try std.testing.expectEqual(@as(usize, 10), source.file_calls);
    try std.testing.expectEqual(@as(usize, 10), source.page_calls);
    try std.testing.expect(!expander.unsupported_parser_function);
    try std.testing.expect(expander.missing_dependency_metadata == null);
    const before = source.file_calls;
    try std.testing.expectEqualStrings("", try expander.expandFragment("Page", "{{filepath:[bad]}}", 1_670_803_200));
    try std.testing.expectEqual(before, source.file_calls);
    try std.testing.expectError(error.FilePathSnapshotMissing, expander.expandFragment("Page", "{{filepath:Unknown.svg}}", 1_670_803_200));
    try std.testing.expectError(error.PageSizeSnapshotMissing, expander.expandFragment("Page", "{{PAGESIZE:Unknown|R}}", 1_670_803_200));
}


test "PAGESIZE formatting keeps stored root identity across templates and separates operand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const magic = rt.namespace_registry.magic_words;
    var words = try magic.Registry.init(a, magic.parser_header ++ "\n# wiki\tenwiktionary\n# dump-date\t20261001\n# content-language\ten\n" ++
        "pagesize\t1\tPAGESIZE\nrawsuffix\t1\tR\n", "enwiktionary", "20261001", "en");
    defer words.deinit();
    var source: FilePageMagicSource = .{ .words = &words };
    const Source = struct {
        fn get(_: ?*anyopaque, alloc: std.mem.Allocator, title: []const u8) !?[]const u8 {
            if (std.mem.eql(u8, title, "Template:Size")) return try alloc.dupe(u8, "{{PAGESIZE:Other page}}");
            return null;
        }
        fn formatted(_: ?*anyopaque, _: std.mem.Allocator, count: u64, host: Provider.PageSizeFormatContext) ![]const u8 {
            if (host.current == null or !host.normal_no_target or host.interface_message == null) return error.PageSizeFormatSnapshotMissing;
            try std.testing.expectEqualStrings("Host", host.title);
            try std.testing.expectEqualStrings("{{Size}}", host.source);
            try std.testing.expectEqual(@as(u64, 99), host.current.?.metadata.page_id);
            try std.testing.expectEqual(@as(u64, 991), host.current.?.metadata.revision_id);
            try std.testing.expect(!host.interface_message.?);
            try std.testing.expect(host.target_language_override == null and host.variant_override == null);
            try std.testing.expectEqual(@as(u64, 7), count);
            return "seven";
        }
    };
    var runtime = try rt.Context.initProgram(a, 24, 1); defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHostWithTitle(&runtime, 18, 23, true);
    var expander: Expander = .{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23,
        .provider = .{ .ctx = &source, .get = Source.get, .exists = TestProvider.exists,
            .resolve_parser_function = FilePageMagicSource.parser, .resolve_title_magic = FilePageMagicSource.alias,
            .raw_suffix_profile = true, .page_size = FilePageMagicSource.size,
            .page_size_formatted = Source.formatted }, .install_scribunto = FilePageMagicSource.install };
    const current: host_api.CurrentPage = .{ .namespace = 0, .metadata = .{
        .page_id = 99, .revision_id = 991, .revision_timestamp = "", .revision_user = "", .content_model = "wikitext",
    } };
    try std.testing.expectEqualStrings("seven", try expander.expandStoredFragment("Host", "{{Size}}", 1_670_803_200, current));
    try std.testing.expectError(error.PageSizeFormatSnapshotMissing, expander.expandFragment("Host", "{{PAGESIZE:Other page}}", 1_670_803_200));
    // Raw mode remains independent of formatting context and language metadata.
    try std.testing.expectEqualStrings("7", try expander.expandFragment("Host", "{{PAGESIZE:Other page|R}}", 1_670_803_200));
}

const NativeTitleDependencyFixture = struct {
    const aliases = rt.namespace_registry.magic_words;
    const retained_target = "===<span class=\"icone\">[[Image:Nuvola apps bookcase.svg|30px|link=Fanoroana:Etimôlôjia|Fiaviana ary tantaran'i « {{PAGENAME}} »]]</span>&nbsp;Etimôlôjia===<noinclude>\n\n[[Catégorie:Modèles de titres de sections|etym]]</noinclude>";
    const retained_heading = "===<span class=\"icone\">[[Image:Nuvola apps bookcase.svg|30px|link=Fanoroana:Etimôlôjia|Fiaviana ary tantaran'i « カㇺピ »]]</span>&nbsp;Etimôlôjia===";
    const namespace_bytes = "# wikidict-namespace-registry-v1\n# wiki\tmgwiktionary\n# dump-date\t20261001\n# content-language\tmg\n-2\tRakitra\tMedia\tcase-sensitive\t0\t0\t0\t\tcompile_only\tvirtual_namespace\tMédia\n-1\tManokana\tSpecial\tfirst-letter\t0\t0\t0\t\tcompile_only\tvirtual_namespace\n0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tdictionary_entries\n1\tDinika\tTalk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tDiscuter\n2\tMpikambana\tUser\tfirst-letter\t1\t0\t0\t\tcompile_only\tstandard_build_input\tUtilisateur\n3\tDinika amin'ny mpikambana\tUser talk\tfirst-letter\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tDiscussion Utilisateur\n4\tWiktionary\tProject\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\tWT\n5\tDinika amin'ny Wiktionary\tProject talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tDiscussion Wiktionary\tWiktionary talk\n6\tSary\tFile\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\tImage\n7\tDinika amin'ny sary\tFile talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tDiscussion Fichier\tDiscussion Image\tImage talk\n8\tMediaWiki\tMediaWiki\tfirst-letter\t1\t0\t0\t\tcompile_only\tstandard_build_input\n9\tDinika amin'ny MediaWiki\tMediaWiki talk\tfirst-letter\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tDiscussion MediaWiki\n10\tEndrika\tTemplate\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\tModèle\n11\tDinika amin'ny endrika\tTemplate talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tDiscussion Modèle\n12\tFanoroana\tHelp\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\tAide\tFanampiana\n13\tDinika amin'ny fanoroana\tHelp talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tDinika amin'ny fanampiana\tDiscussion Aide\n14\tSokajy\tCategory\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\tCatégorie\n15\tDinika amin'ny sokajy\tCategory talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tDiscussion Catégorie\n100\tRakibolana\tRakibolana\tcase-sensitive\t1\t0\t0\t\tsupplemental\tunclassified_subject_retained\n101\tDinika amin'ny rakibolana\tDinika amin'ny rakibolana\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n710\tTimedText\tTimedText\tcase-sensitive\t0\t0\t0\t\tcompile_only\tancillary_site_input\n711\tTimedText talk\tTimedText talk\tcase-sensitive\t0\t0\t0\t\tcompile_only\tdiscussion_namespace\n828\tModule\tModule\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n829\tDiscussion module\tModule talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n1728\tEvent\tEvent\tcase-sensitive\t1\t0\t0\t\tcompile_only\tancillary_site_input\n1729\tEvent talk\tEvent talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n";
    const magic_word_bytes = "# wikidict-magic-words-v2\n# wiki\tmgwiktionary\n# dump-date\t20261001\n# content-language\tmg\nanchorencode\t0\tANCHORENCODE\nanchorencode\t0\tENCODEANCRE\nbasepagename\t1\tANARAMPOTOPEJY\nbasepagename\t1\tANARANAFOTOPEJY\nbasepagename\t1\tBASEPAGENAME\nbasepagename\t1\tNOMBASEDEPAGE\nbasepagenamee\t1\tANARAMPOTOPEJYE\nbasepagenamee\t1\tANARANAFOTOPEJYE\nbasepagenamee\t1\tBASEPAGENAMEE\nbasepagenamee\t1\tNOMBASEDEPAGEX\ncanonicalurl\t0\tCANONICALURL:\ncanonicalurl\t0\tURLCANONIQUE:\ncategorytree\t0\tarbrecats\ncategorytree\t0\tarbrecatégories\ncategorytree\t0\tcategorytree\ncategorytree\t0\tkarazantsokajy\ndefaultsort\t1\tCLEDETRI:\ndefaultsort\t1\tCLEFDETRI:\ndefaultsort\t1\tDEFAULTCATEGORYSORT:\ndefaultsort\t1\tDEFAULTSORT:\ndefaultsort\t1\tDEFAULTSORTKEY:\ndisplaytitle\t1\tAFFICHERTITRE\ndisplaytitle\t1\tASEHOLOHATENY\ndisplaytitle\t1\tDISPLAYTITLE\nexpr\t0\texpr\nformatdate\t0\tdateformat\nformatdate\t0\tformatdate\nformatnum\t0\tFORMATNOMBRE\nformatnum\t0\tFORMATNUM\nfullpagename\t1\tANARAMPEJYFENO\nfullpagename\t1\tANARANAPEJYFENO\nfullpagename\t1\tFULLPAGENAME\nfullpagename\t1\tNOMPAGECOMPLET\nfullpagenamee\t1\tANARAMPEJYFENOX\nfullpagenamee\t1\tANARANAPEJYFENOX\nfullpagenamee\t1\tFULLPAGENAMEE\nfullpagenamee\t1\tNOMPAGECOMPLETX\nfullurl\t0\tFULLURL:\nfullurl\t0\tURLCOMPLETE:\nfullurl\t0\tURLREHETRA:\nfullurle\t0\tFULLURLE:\nfullurle\t0\tURLCOMPLETEX:\nfullurle\t0\tURLREHETRAX:\nif\t0\tif\nif\t0\traha\nif\t0\tsi\nifeq\t0\tifeq\nifeq\t0\trahamitovy\nifeq\t0\tsi=\niferror\t0\tiferror\niferror\t0\trahadiso\niferror\t0\tsierreur\nifexist\t0\tifexist\nifexist\t0\trahamisy\nifexist\t0\tsiexiste\nifexpr\t0\tifexpr\nifexpr\t0\trahamarina\nifexpr\t0\tsiexpr\nint\t0\tINT:\ninvoke\t0\tinvoke\ninvoke\t0\tinvoque\nlanguage\t0\t#LANGUAGE\nlanguage\t0\t#LANGUE\nlc\t0\tLC:\nlc\t0\tMINUS:\nlcfirst\t0\tINITMINUS:\nlcfirst\t0\tLCFIRST:\nlen\t0\tlen\nlen\t0\tnbcar\nlocalurl\t0\tLOCALURL:\nlocalurl\t0\tURLLOCALE:\nlst\t0\tlst\nlst\t0\tsection\nnamespace\t1\tANARANASEHATRA\nnamespace\t1\tANARANTSEHATRA\nnamespace\t1\tESPACENOMMAGE\nnamespace\t1\tNAMESPACE\nnamespacee\t1\tANARANASEHATRAX\nnamespacee\t1\tANARANTSEHATRAX\nnamespacee\t1\tESPACENOMMAGEX\nnamespacee\t1\tNAMESPACEE\nnamespacenumber\t1\tNAMESPACENUMBER\nnamespacenumber\t1\tNOMBREESPACENOMMAGE\nns\t0\tESPACEN:\nns\t0\tNS:\nnumberofactiveusers\t1\tISAMPIKAMBANAMANOVA\nnumberofactiveusers\t1\tNOMBREUTILISATEURSACTIFS\nnumberofactiveusers\t1\tNUMBEROFACTIVEUSERS\nnumberofadmins\t1\tNOMBREADMINS\nnumberofadmins\t1\tNUMBEROFADMINS\nnumberofarticles\t1\tISALAHATSORATRA\nnumberofarticles\t1\tNOMBREARTICLES\nnumberofarticles\t1\tNUMBEROFARTICLES\nnumberofedits\t1\tISAFANOVANA\nnumberofedits\t1\tNOMBREMODIFS\nnumberofedits\t1\tNUMBEROFEDITS\nnumberoffiles\t1\tISARAKITRA\nnumberoffiles\t1\tNOMBREFICHIERS\nnumberoffiles\t1\tNUMBEROFFILES\nnumberofpages\t1\tISAPEJY\nnumberofpages\t1\tNOMBREPAGES\nnumberofpages\t1\tNUMBEROFPAGES\nnumberofusers\t1\tISAMPIKAMBANA\nnumberofusers\t1\tNOMBREUTILISATEURS\nnumberofusers\t1\tNUMBEROFUSERS\npadleft\t0\tBOURRAGEGAUCHE\npadleft\t0\tBOURREGAUCHE\npadleft\t0\tPADLEFT\npadright\t0\tBOURRAGEDROITE\npadright\t0\tBOURREDROITE\npadright\t0\tPADRIGHT\npagename\t1\tANARAMPEJY\npagename\t1\tANARANAPEJY\npagename\t1\tNOMPAGE\npagename\t1\tPAGENAME\npagenamee\t1\tANARAMPEJYX\npagenamee\t1\tANARANAPEJYX\npagenamee\t1\tNOMPAGEX\npagenamee\t1\tPAGENAMEE\npagesincategory\t1\tPAGESDANSCAT\npagesincategory\t1\tPAGESINCAT\npagesincategory\t1\tPAGESINCATEGORY\npagesincategory_all\t0\tall\npagesincategory_all\t0\ttous\npagesincategory_files\t0\tfichiers\npagesincategory_files\t0\tfiles\npagesincategory_pages\t0\tpages\npagesincategory_subcats\t0\tsouscats\npagesincategory_subcats\t0\tsubcats\nplural\t0\tPLURAL:\nplural\t0\tPLURIEL:\nrawsuffix\t1\tB\nrawsuffix\t1\tBRUT\nrawsuffix\t1\tR\nrootpagename\t1\tNOMPAGERACINE\nrootpagename\t1\tROOTPAGENAME\nrootpagenamee\t1\tNOMPAGERACINEX\nrootpagenamee\t1\tROOTPAGENAMEE\nspecial\t0\tspecial\nspecial\t0\tspécial\nsub\t0\tstxt\nsub\t0\tsub\nsubjectpagename\t1\tARTICLEPAGENAME\nsubjectpagename\t1\tNOMPAGEARTICLE\nsubjectpagename\t1\tNOMPAGESUJET\nsubjectpagename\t1\tSUBJECTPAGENAME\nsubjectpagenamee\t1\tARTICLEPAGENAMEE\nsubjectpagenamee\t1\tNOMPAGEARTICLEX\nsubjectpagenamee\t1\tNOMPAGESUJETX\nsubjectpagenamee\t1\tSUBJECTPAGENAMEE\nsubjectspace\t1\tARTICLESPACE\nsubjectspace\t1\tESPACEARTICLE\nsubjectspace\t1\tESPACESUJET\nsubjectspace\t1\tSUBJECTSPACE\nsubjectspace\t1\tTOERANALAHATSORATRA\nsubjectspacee\t1\tARTICLESPACEE\nsubjectspacee\t1\tESPACEARTICLEX\nsubjectspacee\t1\tESPACESUJETX\nsubjectspacee\t1\tSUBJECTSPACEE\nsubjectspacee\t1\tTOERANNYLAHATSORATRA\nsubpagename\t1\tANARANAZANAPEJY\nsubpagename\t1\tANARANJANAPEJY\nsubpagename\t1\tNOMSOUSPAGE\nsubpagename\t1\tSUBPAGENAME\nsubpagenamee\t1\tANARANAZANAPEJYX\nsubpagenamee\t1\tANARANJANAPEJYX\nsubpagenamee\t1\tNOMSOUSPAGEX\nsubpagenamee\t1\tSUBPAGENAMEE\nswitch\t0\tselon\nswitch\t0\tswitch\ntag\t0\tbalise\ntag\t0\ttag\ntalkpagename\t1\tANARAMPEJINDRESAKA\ntalkpagename\t1\tANARANAPEJINDRESAKA\ntalkpagename\t1\tNOMPAGEDISCUSSION\ntalkpagename\t1\tTALKPAGENAME\ntalkpagenamee\t1\tNOMPAGEDISCUSSIONX\ntalkpagenamee\t1\tTALKPAGENAMEE\ntalkspace\t1\tDINIKA\ntalkspace\t1\tESPACEDISCUSSION\ntalkspace\t1\tPEJINDRESAKA\ntalkspace\t1\tPEJYRESAKA\ntalkspace\t1\tTALKSPACE\ntalkspacee\t1\tDINIKAX\ntalkspacee\t1\tESPACEDISCUSSIONX\ntalkspacee\t1\tPEJINDRESAKAX\ntalkspacee\t1\tPEJYRESAKAX\ntalkspacee\t1\tTALKSPACEE\ntime\t0\theure\ntime\t0\tlera\ntime\t0\ttime\ntitleparts\t0\tpartiestitre\ntitleparts\t0\ttitleparts\nuc\t0\tCAPIT:\nuc\t0\tMAJUS:\nuc\t0\tUC:\nucfirst\t0\tINITCAPIT:\nucfirst\t0\tINITMAJUS:\nucfirst\t0\tUCFIRST:\nurlencode\t0\tENCODEURL:\nurlencode\t0\tURLENCODE:\n";
    words: *const aliases.Registry,
    redirected_calls: usize = 0,

    fn resolve(ctx: ?*anyopaque, name: []const u8, form: aliases.Form) anyerror!?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        return self.words.resolve(name, form);
    }
    fn get(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) !?[]const u8 { return null; }
    fn exists(_: ?*anyopaque, title: []const u8) !bool {
        return std.mem.eql(u8, title, "Endrika:-etim-") or std.mem.eql(u8, title, "Endrika:-étym-");
    }
    fn body(ctx: ?*anyopaque, a: std.mem.Allocator, title: []const u8) !?Provider.TransclusionBody {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        if (std.mem.eql(u8, title, "Endrika:-etim-")) {
            self.redirected_calls += 1;
            // Provider owns redirect resolution and returns the actual target title.
            return .{ .title = "Endrika:-étym-", .text = try preprocess.transcludeDecodedForParsingAlloc(a, retained_target), .borrowed = false };
        }
        return null;
    }
};

test "native title provenance retains redirected etymology source and precise missing sibling coordinates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try rt.namespace_registry.Registry.init(a, NativeTitleDependencyFixture.namespace_bytes); defer ns.deinit();
    var words = try NativeTitleDependencyFixture.aliases.Registry.init(a, NativeTitleDependencyFixture.magic_word_bytes, "mgwiktionary", "20261001", "mg"); defer words.deinit();
    var provider: NativeTitleDependencyFixture = .{ .words = &words };
    var runtime = try rt.Context.init(a, 24); defer runtime.deinit(); runtime.namespace_catalog = &ns;
    try rt.bindGlobalTable(&runtime, null, 0); try stdlib.install(&runtime);
    var expander: Expander = .{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23,
        .provider = .{ .ctx = &provider, .get = NativeTitleDependencyFixture.get, .exists = NativeTitleDependencyFixture.exists,
            .get_transclusion_body = NativeTitleDependencyFixture.body, .resolve_title_magic = NativeTitleDependencyFixture.resolve } };
    const current: host_api.CurrentPage = .{ .namespace = 0, .metadata = .{
        .page_id = 11004933, .revision_id = 37709499, .revision_timestamp = "", .revision_user = "", .content_model = "wikitext",
    } };
    const source = "{{-etim-}}|{{ojp}}|{{ANARAMPEJY}}";
    const output = try expander.expandStoredFragment("カㇺピ", source, 1794198676, current);
    const expected = NativeTitleDependencyFixture.retained_heading ++ "|[[:Endrika:ojp]]|カㇺピ";
    try std.testing.expectEqualStrings(expected, output);
    try std.testing.expectEqual(@as(usize, 1), provider.redirected_calls);
    try std.testing.expect(!expander.unsupported_parser_function and expander.display_title == null);
    var phase = try dependency.decode(a, expander.missing_dependency_metadata.?, output, ""); defer phase.deinit();
    try std.testing.expect(!phase.output().unknown);
    try std.testing.expectEqual(@as(usize, 1), phase.occurrences().len);
    try std.testing.expectEqualStrings("Endrika:ojp", phase.occurrences()[0].title);
    const marker = "[[:Endrika:ojp]]";
    const start = NativeTitleDependencyFixture.retained_heading.len + 1;
    try std.testing.expectEqualDeep(@as([]const dependency.Range, &.{.{ .start = @intCast(start), .end = @intCast(start + marker.len), .occurrence = 1 }}), phase.output().ranges);
    try std.testing.expectEqualStrings(marker, output[phase.output().ranges[0].start..phase.output().ranges[0].end]);
    // A second page must derive its own native title, not reuse the prior value.
    const next = try expander.expandStoredFragment("Next page", "{{PAGENAME}}|{{ojp}}", 1794198676, current);
    try std.testing.expectEqualStrings("Next page|[[:Endrika:ojp]]", next);
    var next_phase = try dependency.decode(a, expander.missing_dependency_metadata.?, next, ""); defer next_phase.deinit();
    try std.testing.expect(!next_phase.output().unknown);
    try std.testing.expectEqual(@as(u32, "Next page|".len), next_phase.output().ranges[0].start);
}

test "native no argument title provenance follows fixed current identity and preserves ordinary title bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var runtime = try rt.Context.init(a, 24); defer runtime.deinit(); runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0); try stdlib.install(&runtime);
    var expander: Expander = .{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23,
        .provider = .{ .get = MissingDependencyRegression.get, .exists = TestProvider.exists } };
    const current: host_api.CurrentPage = .{ .namespace = 0, .metadata = .{
        .page_id = 42, .revision_id = 420, .revision_timestamp = "", .revision_user = "", .content_model = "wikitext",
    } };
    const body = "{{PAGENAME}}|{{FULLPAGENAME}}|{{NAMESPACENUMBER}}|{{PAGENAMEE}}|{{Missing}}";
    const output = try expander.expandStoredFragment("Template:A B", body, null, current);
    try std.testing.expectEqualStrings("Template:A B|Template:A B|0|Template:A_B|[[:Template:Missing]]", output);
    var phase = try dependency.decode(a, expander.missing_dependency_metadata.?, output, ""); defer phase.deinit();
    try std.testing.expect(!phase.output().unknown);
    try std.testing.expectEqual(@as(usize, 1), phase.output().ranges.len);
    try std.testing.expectEqualStrings("[[:Template:Missing]]", output[phase.output().ranges[0].start..phase.output().ranges[0].end]);
    const canonical = try expander.expandFragment("Template:A B", body, null);
    try std.testing.expectEqualStrings("A B|Template:A B|10|A_B|[[:Template:Missing]]", canonical);
    var canonical_phase = try dependency.decode(a, expander.missing_dependency_metadata.?, canonical, ""); defer canonical_phase.deinit();
    try std.testing.expect(!canonical_phase.output().unknown);
    try std.testing.expectEqual(@as(usize, 1), canonical_phase.occurrences().len);
}

test "native title provenance does not clean argument dependent transforms missing siblings or exposed values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var runtime = try rt.Context.init(a, 24); defer runtime.deinit(); runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0); try stdlib.install(&runtime);
    var expander: Expander = .{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23,
        .provider = .{ .get = MissingDependencyRegression.get, .exists = TestProvider.exists }, .install_scribunto = installTestInvoke };
    const cases = [_]struct { body: []const u8, prefix: []const u8, occurrences: usize }{
        .{ .body = "{{PAGENAME:Page}}", .prefix = "Page", .occurrences = 1 },
        .{ .body = "{{uc:Page}}", .prefix = "PAGE", .occurrences = 1 },
        .{ .body = "{{#if:yes|{{PAGENAME:Page}}|unused}}", .prefix = "Page", .occurrences = 1 },
        .{ .body = "{{uc:{{Missing}}}}", .prefix = "[[:TEMPLATE:MISSING]]", .occurrences = 2 },
    };
    for (cases) |case| {
        errdefer std.debug.print("native title provenance refused clean grant: {s}\n", .{case.body});
        const source = try std.fmt.allocPrint(a, "{{{{PAGENAME}}}}|{s}|{{{{MissingSibling}}}}", .{case.body});
        const output = try expander.expandFragment("Page", source, null);
        const expected = try std.fmt.allocPrint(a, "Page|{s}|[[:Template:MissingSibling]]", .{case.prefix});
        try std.testing.expectEqualStrings(expected, output);
        var phase = try dependency.decode(a, expander.missing_dependency_metadata.?, output, ""); defer phase.deinit();
        try std.testing.expect(phase.output().unknown);
        try std.testing.expectEqual(case.occurrences, phase.occurrences().len);
        try std.testing.expectEqual(@as(usize, 1), phase.output().ranges.len);
        const start = "Page|".len + case.prefix.len + 1;
        try std.testing.expectEqualDeep(@as(dependency.Range, .{ .start = @intCast(start), .end = @intCast(output.len), .occurrence = @intCast(case.occurrences) }), phase.output().ranges[0]);
        try std.testing.expectEqualStrings("Template:MissingSibling", phase.occurrences()[case.occurrences - 1].title);
    }
    // An identical value exposed to Lua cannot recover origin from this native fix.
    expander.beginPage("Page", "", null);
    const params = try runtime.newTable();
    const key: Value = .{ .number = 1 };
    const native = (try expander.expandParserHeadTracked("PAGENAME", &.{}, params, "Page", 0)).?;
    try std.testing.expectEqualStrings("Page", native.bytes);
    try std.testing.expect(!native.unknown);
    try params.rawSet(a, key, .{ .string = native.bytes });
    expander.invalidateNativeDependencyArguments();
    const exposed = try expander.expandParameterTracked("1", params, "Page", 0);
    try std.testing.expectEqualStrings(native.bytes, exposed.bytes);
    try std.testing.expect(exposed.unknown and exposed.ranges.len == 0);
}

const NativeSerializerDependencyFixture = struct {
    reads: [5]usize = @splat(0),
    skipped_reads: usize = 0,
    fn get(raw: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        const names = [_][]const u8{ "Template:UrlTitle", "Template:UrlQuery", "Template:RefContent", "Template:RefKey", "Template:RefValue" };
        const bodies = [_][]const u8{ "A B#Frag", "action=history&section=0", "Body [[Target|label]]", "group", "notes&more" };
        for (names, bodies, 0..) |name, body, i| if (std.mem.eql(u8, title, name)) {
            self.reads[i] += 1;
            return body;
        };
        if (std.mem.eql(u8, title, "Template:Ignored")) self.skipped_reads += 1;
        return null;
    }
    fn make(runtime: *rt.Context, source: *@This()) Expander {
        return .{ .runtime = runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23,
            .install_scribunto = installTestInvoke,
            .provider = .{ .ctx = source, .get = get, .exists = TestProvider.exists,
                .site_server = "https://captured.example", .site_script = "/custom/run.php", .site_article_path = "/view/$1/end" } };
    }
    fn phase(a: std.mem.Allocator, expander: *Expander, output: []const u8, unknown: bool, occurrences: usize) !void {
        var decoded = try dependency.decode(a, expander.missing_dependency_metadata orelse return error.MissingSerializerPhase, output, "");
        defer decoded.deinit();
        try std.testing.expectEqual(unknown, decoded.output().unknown);
        try std.testing.expectEqual(occurrences, decoded.occurrences().len);
        try std.testing.expectEqual(@as(usize, 1), decoded.output().ranges.len);
        const marker = "[[:Template:MissingSibling]]";
        try std.testing.expect(std.mem.endsWith(u8, output, marker));
        const range = decoded.output().ranges[0];
        try std.testing.expectEqual(@as(u32, @intCast(output.len - marker.len)), range.start);
        try std.testing.expectEqual(@as(u32, @intCast(output.len)), range.end);
        try std.testing.expectEqualStrings("Template:MissingSibling", decoded.occurrences()[range.occurrence - 1].title);
    }
};

test "native localurl known inputs retain site serialization single evaluation and precise missing sibling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var runtime = try rt.Context.init(a, 24); defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0); try stdlib.install(&runtime);
    var provider: NativeSerializerDependencyFixture = .{};
    var expander = NativeSerializerDependencyFixture.make(&runtime, &provider);
    const input = "{{localurl:{{UrlTitle}}|{{UrlQuery}}|{{Ignored}}}}|{{MissingSibling}}";
    const output = try expander.expandFragment("Concrete page", input, null);
    try std.testing.expectEqualStrings("/custom/run.php?title=A_B&action=history&section=0#Frag|[[:Template:MissingSibling]]", output);
    try NativeSerializerDependencyFixture.phase(a, &expander, output, false, 1);
    try std.testing.expectEqualDeep(@as([5]usize, .{ 1, 1, 0, 0, 0 }), provider.reads);
    try std.testing.expectEqual(@as(usize, 0), provider.skipped_reads);
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "{{localurl:A B#Frag}}", .expected = "/view/A_B/end#Frag" },
        .{ .input = "{{localurl:A B|}}", .expected = "/custom/run.php?title=A_B" },
        .{ .input = "{{localurl:{{PAGENAME}}|action=history}}", .expected = "/custom/run.php?title=%E3%82%AB%E3%87%BA%E3%83%94&action=history" },
    };
    for (cases) |case| {
        errdefer std.debug.print("known localurl case: {s}\n", .{case.input});
        const source = try std.fmt.allocPrint(a, "{s}|{{{{MissingSibling}}}}", .{case.input});
        const bytes = try expander.expandFragment("カㇺピ", source, null);
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}|[[:Template:MissingSibling]]", .{case.expected}), bytes);
        try NativeSerializerDependencyFixture.phase(a, &expander, bytes, false, 1);
    }
    expander.provider.site_server = null;
    try std.testing.expectError(error.SiteInfoSnapshotMissing, expander.expandFragment("Page", "{{localurl:A}}", null));
    expander.provider.site_server = "https://captured.example";
    expander.provider.site_article_path = "/missing-marker";
    try std.testing.expectError(error.InvalidSiteInfoSnapshot, expander.expandFragment("Page", "{{localurl:A}}", null));
}

test "native references known inputs retain exact serializer evaluation and missing sibling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var runtime = try rt.Context.init(a, 24); defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0); try stdlib.install(&runtime);
    var provider: NativeSerializerDependencyFixture = .{};
    var expander = NativeSerializerDependencyFixture.make(&runtime, &provider);
    const input = "{{#tag:references|{{RefContent}}|{{RefKey}}={{RefValue}}|responsive=1|={{Ignored}}}}|{{MissingSibling}}";
    const output = try expander.expandFragment("Page", input, null);
    try std.testing.expectEqualStrings("<references group=\"notes&amp;more\" responsive=\"1\">Body [[Target|label]]</references>|[[:Template:MissingSibling]]", output);
    try NativeSerializerDependencyFixture.phase(a, &expander, output, false, 1);
    try std.testing.expectEqualDeep(@as([5]usize, .{ 0, 0, 1, 1, 1 }), provider.reads);
    try std.testing.expectEqual(@as(usize, 0), provider.skipped_reads);
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        // The consumed invocation from retained p7560206/r29077355 reflist.
        .{ .input = "{{#tag:references|{{{refs|}}}|group={{{group|{{{1|}}}}}}|responsive={{#if:{{{1|}}}{{{width|}}}|0|1}}}}", .expected = "<references group=\"\" responsive=\"1\"></references>" },
        .{ .input = "{{#tag:references|text|z=\"a&b\"|group=old|group=new}}", .expected = "<references group=\"new\" z=\"a&amp;b\">text</references>" },
        .{ .input = "{{#tag:references}}", .expected = "<references></references>" },
    };
    for (cases) |case| {
        errdefer std.debug.print("known references case: {s}\n", .{case.input});
        const source = try std.fmt.allocPrint(a, "{s}|{{{{MissingSibling}}}}", .{case.input});
        const bytes = try expander.expandFragment("Page", source, null);
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}|[[:Template:MissingSibling]]", .{case.expected}), bytes);
        try NativeSerializerDependencyFixture.phase(a, &expander, bytes, false, 1);
    }
}

test "native serializers retain unknown missing protected and exposed input refusal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var runtime = try rt.Context.init(a, 24); defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0); try stdlib.install(&runtime);
    var provider: NativeSerializerDependencyFixture = .{};
    var expander = NativeSerializerDependencyFixture.make(&runtime, &provider);
    const cases = [_]struct { input: []const u8, occurrences: usize }{
        .{ .input = "{{localurl:{{uc:Page}}}}", .occurrences = 1 },
        .{ .input = "{{localurl:Page|{{uc:query}}}}", .occurrences = 1 },
        .{ .input = "{{localurl:{{Missing}}}}", .occurrences = 2 },
        .{ .input = "{{localurl:Page|{{Missing}}}}", .occurrences = 2 },
        .{ .input = "{{localurl:{{{Absent}}}}}", .occurrences = 1 },
        .{ .input = "{{localurl:Page|{{{Absent}}}}}", .occurrences = 1 },
        .{ .input = "{{#tag:references|{{uc:body}}}}", .occurrences = 1 },
        .{ .input = "{{#tag:references||{{uc:group}}=x}}", .occurrences = 1 },
        .{ .input = "{{#tag:references||group={{uc:value}}}}", .occurrences = 1 },
        .{ .input = "{{#tag:references|{{Missing}}}}", .occurrences = 2 },
        .{ .input = "{{#tag:references||{{Missing}}=x}}", .occurrences = 2 },
        .{ .input = "{{#tag:references||group={{Missing}}}}", .occurrences = 2 },
        .{ .input = "{{#tag:references|{{{Absent}}}}}", .occurrences = 1 },
        .{ .input = "{{#tag:ref|body}}", .occurrences = 1 },
        .{ .input = "{{#tag:{{#if:yes|references}}|body}}", .occurrences = 1 },
        .{ .input = "{{fullurl:Page}}", .occurrences = 1 },
    };
    for (cases) |case| {
        errdefer std.debug.print("serializer refusal case: {s}\n", .{case.input});
        const source = try std.fmt.allocPrint(a, "{s}|{{{{MissingSibling}}}}", .{case.input});
        const output = try expander.expandFragment("Page", source, null);
        try NativeSerializerDependencyFixture.phase(a, &expander, output, true, case.occurrences);
        // The normal byte-return entry must remain identical for each refusal.
        const params = try runtime.newTable();
        var parts: std.ArrayList([]const u8) = .empty;
        try preprocess.splitWikitextTop(a, case.input[2 .. case.input.len - 2], '|', &parts);
        const direct = (try expander.expandParserHead(parts.items[0], parts.items[1..], params, "Page", 1)) orelse return error.MissingSerializerResult;
        try std.testing.expectEqualStrings(direct, output[0 .. output.len - "|[[:Template:MissingSibling]]".len]);
    }
    expander.beginPage("Page", "", null);
    const params = try runtime.newTable();
    try params.rawSet(a, .{ .number = 1 }, .{ .string = "known-looking" });
    expander.invalidateNativeDependencyArguments();
    const exposed = (try expander.expandParserHeadTracked("localurl:{{{1}}}", &.{}, params, "Page", 0)).?;
    try std.testing.expect(exposed.unknown);
    try std.testing.expectEqualStrings("/view/known-looking/end", exposed.bytes);
    expander.beginPage("Page", "", null);
    const guarded = [_]dependency.Text{
        .{ .bytes = "X", .unknown = true },
        .{ .bytes = "X", .lost_missing_range = true },
        .{ .bytes = "X", .ranges = &.{.{ .start = 0, .end = 1, .occurrence = 1 }} },
        .{ .bytes = "X", .literal_curly_ranges = &.{.{ .start = 0, .end = 1 }} },
        .{ .bytes = "X", .generated_source = "X" },
        .{ .bytes = "{{{Absent}}}" },
    };
    for (guarded) |value| {
        var provenance: Expander.NativeSerializationProvenance = .{};
        provenance.include(value);
        const result = provenance.finish(&expander, "serialized");
        try std.testing.expect(result.unknown and result.ranges.len == 0);
        try std.testing.expectEqual(value.lost_missing_range or value.ranges.len != 0, result.lost_missing_range);
    }
    expander.dependency_page.metadata_unknown = true;
    const complete: Expander.NativeSerializationProvenance = .{};
    try std.testing.expect(complete.finish(&expander, "serialized").unknown);
}

const NativeArgumentCacheFixture = struct {
    const wikibolana = "* Ity pejy ity dia nadika avy amin'ny pejy [[:{{{1}}}:{{{2}}}|{{{2}}}]] tao amin'ny Wikibolana amin'ny teny {{{{{1}}}}}. ([http://{{{1|mg}}}.wiktionary.org/{{localurl:{{{2|{{PAGENAME}}}}}|action=history}} lisitry ny mpandray anjara])[[sokajy:Pejy avy any amin'ny wikibolana {{{{{1}}}}}]]";
    fn get(_: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
        if (std.mem.eql(u8, title, "Template:Wikibolana")) return wikibolana;
        if (std.mem.eql(u8, title, "Template:en")) return "anglisy";
        if (std.mem.eql(u8, title, "Template:Repeated")) return "{{{2}}}|{{{2}}}|{{localurl:{{{2}}}|action=history}}";
        if (std.mem.eql(u8, title, "Template:Forward")) return "{{Repeated|unused|2={{{value}}}}}";
        if (std.mem.eql(u8, title, "Template:Twice")) return "{{{1}}}|{{{1}}}";
        return null;
    }
    fn make(runtime: *rt.Context) Expander {
        return .{ .runtime = runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .install_scribunto = installTestInvoke,
            .provider = .{ .get = get, .exists = TestProvider.exists,
                .site_server = "https://captured.example", .site_script = "/custom/run.php", .site_article_path = "/view/$1/end" } };
    }
};

test "native memoized arguments preserve repeated forwarded title and retained wikibolana provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var runtime = try rt.Context.init(a, 24); defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0); try stdlib.install(&runtime);
    var expander = NativeArgumentCacheFixture.make(&runtime);
    const cases = [_]struct { title: []const u8, input: []const u8, expected: []const u8 }{
        .{ .title = "Page one", .input = "{{Repeated|unused|{{PAGENAME}}}}", .expected = "Page one|Page one|/custom/run.php?title=Page_one&action=history" },
        .{ .title = "Page two", .input = "{{Forward|value= {{PAGENAME}} }}", .expected = "Page two|Page two|/custom/run.php?title=Page_two&action=history" },
        .{ .title = "カㇺピ", .input = "{{Wikibolana|en|カㇺピ}}", .expected = "\n* Ity pejy ity dia nadika avy amin'ny pejy [[:en:カㇺピ|カㇺピ]] tao amin'ny Wikibolana amin'ny teny anglisy. ([http://en.wiktionary.org//custom/run.php?title=%E3%82%AB%E3%87%BA%E3%83%94&action=history lisitry ny mpandray anjara])[[sokajy:Pejy avy any amin'ny wikibolana anglisy]]" },
    };
    for (cases) |case| {
        errdefer std.debug.print("native cached argument case: {s}\n", .{case.input});
        const input = try std.fmt.allocPrint(a, "{s}|{{{{MissingSibling}}}}", .{case.input});
        const output = try expander.expandFragment(case.title, input, null);
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}|[[:Template:MissingSibling]]", .{case.expected}), output);
        try NativeSerializerDependencyFixture.phase(a, &expander, output, false, 1);
        try std.testing.expect(!expander.dependency_native_arguments_disabled);
        try std.testing.expect(expander.dependency_arguments.items.len != 0);
        try std.testing.expect(expander.dependency_argument_bytes <= dependency.max_metadata_bytes);
    }
}

test "native memoized arguments preserve missing ranges unknown transforms and table identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var runtime = try rt.Context.init(a, 24); defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0); try stdlib.install(&runtime);
    var expander = NativeArgumentCacheFixture.make(&runtime);
    const output = try expander.expandFragment("Page", "{{Twice|{{Missing}}}}|{{MissingSibling}}", null);
    try std.testing.expectEqualStrings("[[:Template:Missing]]|[[:Template:Missing]]|[[:Template:MissingSibling]]", output);
    var phase = try dependency.decode(a, expander.missing_dependency_metadata.?, output, ""); defer phase.deinit();
    try std.testing.expect(!phase.output().unknown);
    try std.testing.expectEqual(@as(usize, 2), phase.occurrences().len);
    const marker = "[[:Template:Missing]]";
    try std.testing.expectEqualDeep(@as([]const dependency.Range, &.{
        .{ .start = 0, .end = marker.len, .occurrence = 1 },
        .{ .start = marker.len + 1, .end = marker.len * 2 + 1, .occurrence = 1 },
        .{ .start = marker.len * 2 + 2, .end = @intCast(output.len), .occurrence = 2 },
    }), phase.output().ranges);
    const unknown = try expander.expandFragment("Page", "{{Twice|{{PAGENAME:Other}}}}|{{MissingSibling}}", null);
    try std.testing.expectEqualStrings("Other|Other|[[:Template:MissingSibling]]", unknown);
    try NativeSerializerDependencyFixture.phase(a, &expander, unknown, true, 1);
    expander.beginPage("Page", "", null);
    const params = try runtime.newTable();
    const foreign = try runtime.newTable();
    const key: Value = .{ .string = "named" };
    const native = dependency.Text{ .bytes = try a.dupe(u8, "known") };
    try params.rawSet(a, key, .{ .string = native.bytes });
    try foreign.rawSet(a, key, .{ .string = native.bytes });
    try expander.rememberDependencyArgument(params, key, native);
    try std.testing.expect(expander.nativeDependencyArgument(params, key) != null);
    try std.testing.expect(expander.nativeDependencyArgument(foreign, key) == null);
    try std.testing.expect(expander.nativeDependencyArgument(params, .{ .string = "other" }) == null);
    const lost = dependency.Text{ .bytes = try a.dupe(u8, "lost"), .unknown = true, .lost_missing_range = true };
    try params.rawSet(a, key, .{ .string = lost.bytes });
    try expander.rememberDependencyArgument(params, key, lost);
    const retained = expander.nativeDependencyArgument(params, key) orelse return error.MissingCachedProvenance;
    try std.testing.expect(retained.unknown and retained.lost_missing_range);
    try std.testing.expectEqualStrings("lost", retained.bytes);
    const unmapped = dependency.Text{ .bytes = try a.dupe(u8, "unmapped"), .generated_source = "unmapped" };
    try params.rawSet(a, key, .{ .string = unmapped.bytes });
    try expander.rememberDependencyArgument(params, key, unmapped);
    try std.testing.expect(expander.nativeDependencyArgument(params, key) == null);
    const refused = try expander.expandParameterTracked("named", params, "Page", 0);
    try std.testing.expect(refused.unknown);
    try std.testing.expectEqualStrings("unmapped", refused.bytes);
}

test "native memoized argument provenance refuses mutation Lua exposure page reuse and budget loss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var runtime = try rt.Context.init(a, 24); defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    try rt.bindGlobalTable(&runtime, null, 0); try stdlib.install(&runtime);
    var expander = NativeArgumentCacheFixture.make(&runtime);
    const key: Value = .{ .number = 1 };
    for (0..4) |kind| {
        expander.beginPage("Page", "", null);
        const params = try runtime.newTable();
        const bytes = try a.dupe(u8, "known");
        try params.rawSet(a, key, .{ .string = bytes });
        try expander.rememberDependencyArgument(params, key, dependency.Text.untracked(bytes));
        try std.testing.expect(expander.nativeDependencyArgument(params, key) != null);
        switch (kind) {
            0 => try params.rawSet(a, key, .{ .string = try a.dupe(u8, bytes) }), // Same bytes, different value identity.
            1 => bytes[0] = 'X', // Even a native mutable backing alias cannot borrow the snapshot.
            2 => try params.rawSet(a, key, .{ .number = 42 }),
            3 => try params.rawSet(a, key, .nil),
            else => unreachable,
        }
        try std.testing.expect(expander.nativeDependencyArgument(params, key) == null);
        // Restoring the original pointer after a detected mutation cannot revive its certificate.
        bytes[0] = 'k';
        try params.rawSet(a, key, .{ .string = bytes });
        const refused = try expander.expandParameterTracked("1", params, "Page", 0);
        try std.testing.expect(refused.unknown and refused.ranges.len == 0);
        try std.testing.expectEqualStrings("known", refused.bytes);
    }
    expander.beginPage("Page", "", null);
    const params = try runtime.newTable();
    const bytes = try a.dupe(u8, "known");
    try params.rawSet(a, key, .{ .string = bytes });
    try expander.rememberDependencyArgument(params, key, dependency.Text.untracked(bytes));
    expander.invalidateNativeDependencyArguments();
    try expander.rememberDependencyArgument(params, key, dependency.Text.untracked(bytes));
    const exposed = try expander.expandParameterTracked("1", params, "Page", 0);
    try std.testing.expect(exposed.unknown and expander.dependency_arguments.items.len == 0);
    expander.beginPage("Next", "", null);
    try std.testing.expectEqual(@as(usize, 0), expander.dependency_argument_bytes);
    try std.testing.expect(expander.nativeDependencyArgument(params, key) == null);
    const prior_page = try expander.expandParameterTracked("1", params, "Next", 0);
    try std.testing.expect(prior_page.unknown);
    // Use the real fixed ceiling without allocating a limit-sized fixture.
    expander.dependency_argument_bytes = dependency.max_metadata_bytes;
    try expander.rememberDependencyArgument(params, key, dependency.Text.untracked(bytes));
    try std.testing.expect(expander.dependency_native_arguments_disabled and expander.dependency_page.metadata_unknown);
    try std.testing.expect(expander.nativeDependencyArgument(params, key) == null);
    try std.testing.expectEqualStrings("known", (try expander.expandParameterTracked("1", params, "Next", 0)).bytes);
}

const RootSingletonLiteralFixture = struct {
    fn get(_: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
        if (std.mem.eql(u8, title, "Template:Head")) return "==English==\nword";
        if (std.mem.eql(u8, title, "Template:Tail")) return "next\n==Spanish==\n[https://example.test/word}}} dictionary]";
        if (std.mem.eql(u8, title, "Template:Known")) return "{{{1|known}}}";
        if (std.mem.eql(u8, title, "Template:Less")) return "<";
        if (std.mem.eql(u8, title, "Template:Comment")) return "{{Less}}!--";
        if (std.mem.eql(u8, title, "Template:Brace")) return "{";
        if (std.mem.eql(u8, title, "Template:Recreated")) return "{{Brace}}{{Brace}}t|ja|word}\n";
        if (std.mem.eql(u8, title, "Template:After")) return "-->{{Recreated}}";
        return null;
    }
    fn exists(_: ?*anyopaque, title: []const u8) !bool {
        return (try get(null, std.testing.allocator, title)) != null;
    }
    fn check(source: []const u8, expected: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
        var runtime = try rt.Context.initProgram(arena.allocator(), 24, 1); defer runtime.deinit();
        runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
        try rt.bindGlobalTable(&runtime, null, 0);
        try stdlib.install(&runtime);
        try installTestHost(&runtime, 18, 23);
        var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23,
            .provider = .{ .get = get, .exists = exists }, .install_scribunto = installTestInvoke };
        const actual = try expander.expandFragment("Page", source, 1_670_803_200);
        try std.testing.expectEqualStrings(expected, actual);
        try std.testing.expect(expander.missing_dependency_metadata == null);
        try std.testing.expectEqual(@as(usize, 0), expander.dependency_page.occurrences.items.len);
        try std.testing.expect(!expander.unsupported_parser_function);
    }
};

test "normal root expansion protects copied singleton template braces before generated URL closes with zero missing occurrences" {
    try RootSingletonLiteralFixture.check(
        "{{Head}}, {{t|ja|word|tr=[[target]], reading}\n*{{Tail}}",
        "==English==\nword, &#123;&#123;t|ja|word|tr=[[target]], reading&#125;\n*next\n==Spanish==\n[https://example.test/word}}} dictionary]",
    );
    try RootSingletonLiteralFixture.check(
        "{{Head}}, {{t|mi|iniana}\n*{{Tail}}",
        "==English==\nword, &#123;&#123;t|mi|iniana&#125;\n*next\n==Spanish==\n[https://example.test/word}}} dictionary]",
    );
}

test "normal root expansion does not transfer removed literal provenance to identical generated output" {
    // Comment delimiters are generated by child expansion, so the original
    // root literal is marked and then removed by the ordinary finalizer.
    // The equal child-created token must retain its own unmarked identity.
    try RootSingletonLiteralFixture.check("{{Comment}}{{t|ja|word}\n{{After}}", "{{t|ja|word}\n");
}

test "normal root expansion keeps matched multiline nested templates and protected source semantics" {
    try RootSingletonLiteralFixture.check("{{Known|before\n{{Known|nested}}\nafter}}", "before\nnested\nafter");
    try RootSingletonLiteralFixture.check("<nowiki>{{t|ja|word}\n</nowiki>{{Known}}", "<nowiki>{{t|ja|word}\n</nowiki>known");
    try RootSingletonLiteralFixture.check("<pre>{{t|ja|word}\n</pre>{{Known}}", "<pre>{{t|ja|word}\n</pre>known");
    try RootSingletonLiteralFixture.check("<!--{{t|ja|word}\n-->{{Known}}", "known");
    try RootSingletonLiteralFixture.check("[[target|{{Known}}]]", "[[target|known]]");
}


// Controlled source-emission bridge: the provider supplies complete retained
// prefix/suffix bytes, not the actual HU Lua program. The root literal event
// remains real; both complete pages must match the shared producer contract.
const HuSingletonCompleteProducerFixture = struct {
    prefix: []const u8,
    suffix: []const u8,
    fn get(raw: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
        const self: *const @This() = @ptrCast(@alignCast(raw orelse return null));
        if (std.mem.eql(u8, title, "Template:Head")) return self.prefix;
        if (std.mem.eql(u8, title, "Template:Tail")) return self.suffix;
        return null;
    }
    fn exists(raw: ?*anyopaque, title: []const u8) !bool {
        return (try get(raw, std.testing.allocator, title)) != null;
    }
};

test "complete HU source contract protects root literal event while retaining all generated later pages bytes" {
    const cases = [_]struct { title: []const u8, original: []const u8, expected: []const u8, literal: []const u8 }{
        .{ .title = "te", .original = @embedFile("testdata/hu-root-literal/te.expanded.wikitext"), .expected = @embedFile("testdata/hu-root-literal/te.prepared-expanded.wikitext"), .literal = "{{t|ja|貴方|tr=[[あなた]], anata}" },
        .{ .title = "motor", .original = @embedFile("testdata/hu-root-literal/motor.expanded.wikitext"), .expected = @embedFile("testdata/hu-root-literal/motor.prepared-expanded.wikitext"), .literal = "{{t|mi|iniana}" },
    };
    for (cases) |case| {
        errdefer std.debug.print("HU complete root emission page={s}\n", .{case.title});
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
        const a = arena.allocator();
        const at = std.mem.indexOf(u8, case.original, case.literal) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, case.original, "{{"));
        const after = at + case.literal.len;
        try std.testing.expect(case.original[after] == '\n');
        var fixture: HuSingletonCompleteProducerFixture = .{ .prefix = case.original[0..at], .suffix = case.original[after + 1 ..] };
        const input = try std.fmt.allocPrint(a, "{{{{Head}}}}{s}\n{{{{Tail}}}}", .{case.literal});
        var runtime = try rt.Context.initProgram(a, 24, 1); defer runtime.deinit();
        runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
        try rt.bindGlobalTable(&runtime, null, 0); try stdlib.install(&runtime); try installTestHost(&runtime, 18, 23);
        var expander: Expander = .{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23,
            .provider = .{ .ctx = &fixture, .get = HuSingletonCompleteProducerFixture.get, .exists = HuSingletonCompleteProducerFixture.exists }, .install_scribunto = installTestInvoke };
        const actual = try expander.expandFragment(case.title, input, 1_670_803_200);
        try std.testing.expectEqualStrings(case.expected, actual);
        try std.testing.expectEqual(case.original.len + 15, actual.len);
        try std.testing.expect(expander.missing_dependency_metadata == null and !expander.unsupported_parser_function);
        try std.testing.expectEqual(@as(usize, 0), expander.dependency_page.occurrences.items.len);
        const url = try std.fmt.allocPrint(a, "https://dle.rae.es/{s}{s}", .{ case.title, "}}}" });
        try std.testing.expect(std.mem.indexOf(u8, actual, url) != null);
    }
}

test "explicit empty invoke export differs from omitted function and retains errors" {
    const P = struct {
        fn lookup(_: ?*const anyopaque, raw_name: []const u8) ?u32 {
            const names = [_][]const u8{ "Module:Test", "Module:Missing", "Module:Value", "Module:Direct" };
            for (names, 0..) |candidate, i| if (std.mem.eql(u8, raw_name, candidate)) return @intCast(i);
            return null;
        }
        fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
            return switch (id) { 0 => "Module:Test", 1 => "Module:Missing", 2 => "Module:Value", 3 => "Module:Direct", else => null };
        }
        fn result(value: Value) ![]const Value {
            const out = try std.heap.smp_allocator.alloc(Value, 1);
            out[0] = value;
            return out;
        }
        fn mainExport(_: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
            return result(.{ .string = "main" });
        }
        fn root(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
            const exports = try ctx.newTable();
            try exports.rawSet(ctx.allocator, .{ .string = "" }, try ctx.makeFunction(1, rt.stabilize(TestModule.run), &.{}));
            try exports.rawSet(ctx.allocator, .{ .string = "main" }, try ctx.makeFunction(2, rt.stabilize(mainExport), &.{}));
            return result(.{ .table = exports });
        }
        fn missing(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
            return result(.{ .table = try ctx.newTable() });
        }
        fn invalidExport(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
            const exports = try ctx.newTable();
            try exports.rawSet(ctx.allocator, .{ .string = "" }, .{ .number = 17 });
            return result(.{ .table = exports });
        }
        fn direct(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
            return result(try ctx.makeFunction(2, rt.stabilize(mainExport), &.{}));
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 24, 4);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{ rt.stabilize(P.root), rt.stabilize(P.missing), rt.stabilize(P.invalidExport), rt.stabilize(P.direct) };
    runtime.module_root_entries = &functions;
    runtime.configureModules(null, P.lookup, P.name);
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    var expander = Expander{
        .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23,
        .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists, .resolve_call_symbol = TestProvider.resolveCallSymbol },
        .install_scribunto = installTestInvoke,
    };
    // VI's retained Unsubst template uses the explicit || spelling, whose
    // module exports p[''] = p.main. Missing arguments keep the prior main path.
    for ([_][]const u8{ "Test", "@module" }) |module_name| {
        const source = try std.fmt.allocPrint(runtime.allocator,
            "before{{{{#invoke:{s}||x={{{{#expr:2+3}}}}}}}}|{{{{#invoke:{s}| }}}}|{{{{#invoke:{s}}}}}after",
            .{ module_name, module_name, module_name });
        try std.testing.expectEqualStrings("before5||mainafter", try expander.expandFragment("Page", source, 1_794_174_780));
    }
    const args = try runtime.newTable();
    try args.rawSet(runtime.allocator, .{ .number = 1 }, .{ .string = "Test" });
    try args.rawSet(runtime.allocator, .{ .number = 2 }, .{ .string = "" });
    try args.rawSet(runtime.allocator, .{ .string = "x" }, .{ .string = "frame-empty" });
    try std.testing.expectEqualStrings("frame-empty", try expander.frameParserInvoke(args));
    try args.rawSet(runtime.allocator, .{ .number = 2 }, .nil);
    try std.testing.expectEqualStrings("main", try expander.frameParserInvoke(args));
    for ([_]struct { module_name: []const u8, detail: []const u8 }{
        .{ .module_name = "Missing", .detail = "The function \"\" does not exist." },
        .{ .module_name = "Value", .detail = "\"\" is not a function." },
        .{ .module_name = "Direct", .detail = "The module did not return an export table." },
    }) |case| {
        const source = try std.fmt.allocPrint(runtime.allocator, "A{{{{#invoke:{s}|}}}}B{{{{#invoke:Test}}}}", .{case.module_name});
        const expected = try std.fmt.allocPrint(runtime.allocator,
            "A<strong class=\"error\"><span class=\"scribunto-error\">Lua error in Module:{s}: {s}</span></strong>Bmain",
            .{ case.module_name, case.detail });
        try std.testing.expectEqualStrings(expected, try expander.expandFragment("Page", source, 1_794_174_780));
        try std.testing.expect(runtime.current_frame == null and runtime.aotErrorName() == null and !runtime.last_error_present);
    }
}


const StrictThenPnRollbackProbe = struct {
    fn lookup(_: ?*const anyopaque, raw_name: []const u8) ?u32 {
        if (std.mem.eql(u8, raw_name, "Module:StrictInstaller")) return 0;
        return if (std.mem.eql(u8, raw_name, "Module:PnShaped")) 1 else null;
    }
    fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
        return switch (id) { 0 => "Module:StrictInstaller", 1 => "Module:PnShaped", else => null };
    }
    fn result(value: Value) ![]const Value {
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = value;
        return out;
    }
    fn strictRoot(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        // Stable native ABI slot, as with env0/string18/mw23 in this
        // maintained root harness; lua_globals is private to zig_stdlib.
        const require = ctx.getGlobal(22);
        const strict = try ctx.callValue(require, &.{.{ .string = "strict" }});
        defer rt.freeResults(strict);
        if (strict.len != 1 or strict[0] != .boolean or !strict[0].boolean) return error.StrictNotInstalled;
        const exports = try ctx.newTable();
        try exports.rawSet(ctx.allocator, .{ .string = "run" }, try ctx.newNative(null, strictRun));
        try exports.rawSet(ctx.allocator, .{ .string = "fail" }, try ctx.newNative(null, strictFail));
        return result(.{ .table = exports });
    }
    fn strictRun(_: ?*anyopaque, ctx: *rt.Context, _: []const Value) ![]const Value {
        // Strict must remain active throughout this invocation, not merely
        // disappear early to make the following Pn-shaped root succeed.
        try std.testing.expectError(error.AotCallFailed, ctx.getIndex(.{ .table = ctx.global_table.? }, .{ .string = "frame" }));
        try std.testing.expectEqualStrings("variable 'frame' is not declared", ctx.last_error.string);
        try std.testing.expectEqualStrings("LuaRaised", ctx.aotErrorName().?);
        ctx.clearLuaError();
        ctx.clearAotErrorName();
        return result(.{ .string = "strict" });
    }
    fn strictFail(_: ?*anyopaque, ctx: *rt.Context, _: []const Value) ![]const Value {
        ctx.setLuaError(.{ .string = "strict invocation failed" });
        return error.LuaRaised;
    }
    fn pnRoot(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        // The actual retained Modulo:Pn reads frame at module scope before
        // pn(frame) exists. Arguments.getArgs accepts this ordinary nil.
        const frame = try ctx.getIndex(.{ .table = ctx.global_table.? }, .{ .string = "frame" });
        if (frame != .nil) return error.ExpectedUndeclaredNil;
        const exports = try ctx.newTable();
        try exports.rawSet(ctx.allocator, .{ .string = "run" }, try ctx.newNative(null, pnRun));
        return result(.{ .table = exports });
    }
    fn pnRun(_: ?*anyopaque, _: *rt.Context, _: []const Value) ![]const Value {
        return result(.{ .string = "" });
    }
};

test "ordinary reused invokes restore strict before a later Pn shaped module root on success and failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.initProgram(a, 24, 2);
    defer runtime.deinit();
    const roots = [_]rt.FunctionFn{ rt.stabilize(StrictThenPnRollbackProbe.strictRoot), rt.stabilize(StrictThenPnRollbackProbe.pnRoot) };
    runtime.module_root_entries = &roots;
    runtime.configureModules(null, StrictThenPnRollbackProbe.lookup, StrictThenPnRollbackProbe.name);
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23,
        .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists }, .install_scribunto = installTestInvoke };
    // One page expansion is essential: expandFragment begins a fresh page.
    // Both success and failure paths must restore the same cached child.
    const actual = try expander.expandFragment("R",
        "{{#invoke:StrictInstaller|run}}|{{#invoke:PnShaped|run}}|{{#invoke:StrictInstaller|run}}|{{#invoke:PnShaped|run}}|" ++
        "{{#invoke:StrictInstaller|fail}}|{{#invoke:PnShaped|run}}", 1_670_803_200);
    try std.testing.expect(std.mem.startsWith(u8, actual, "strict||strict||"));
    try std.testing.expect(std.mem.indexOf(u8, actual, "strict invocation failed") != null);
    try std.testing.expect(std.mem.endsWith(u8, actual, "|"));
    try std.testing.expect(std.mem.indexOf(u8, actual, "variable 'frame'") == null);
    const cached = expander.page_invoke_runtime orelse return error.TestUnexpectedResult;
    try std.testing.expect(cached.global_table.?.metatable == null);
    try std.testing.expect(!expander.page_invoke_active and runtime.global_table.?.metatable == null);
}

test "outer missing invoke uses selected message and preserves page while Lua require and pcall retain errors" {
    const P = struct {
        message: ?[]const u8 = "Erreur de script : le module « $2 » n’existe pas.",
        fn get(_: ?*anyopaque, allocator: std.mem.Allocator, title: []const u8) !?[]const u8 {
            if (std.mem.endsWith(u8, title, ":Tsiahy:nb:NAOB")) return try allocator.dupe(u8, "{{#invoke:R:nb:NAOB|main}}");
            if (std.mem.endsWith(u8, title, ":Explode")) return error.UnexpectedArgumentExpansion;
            return null;
        }
        fn exists(_: ?*anyopaque, _: []const u8) !bool { return false; }
        fn messages(raw: ?*anyopaque, _: std.mem.Allocator, language: []const u8, key: []const u8) !?Provider.InterfaceMessage {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try std.testing.expectEqualStrings("mg", language);
            try std.testing.expectEqualStrings("scribunto-common-nosuchmodule", key);
            return if (self.message) |message| .{ .source = message } else error.InterfaceMessageSnapshotMissing;
        }
        fn result(value: Value) ![]const Value {
            const out = try std.heap.smp_allocator.alloc(Value, 1); out[0] = value; return out;
        }
        fn root(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
            const exports = try ctx.newTable();
            try exports.rawSet(ctx.allocator, .{ .string = "main" }, try ctx.makeFunctionKnown(1, main, &.{}));
            try exports.rawSet(ctx.allocator, .{ .string = "internal" }, try ctx.makeFunctionKnown(2, internal, &.{}));
            try exports.rawSet(ctx.allocator, .{ .string = "protected" }, try ctx.makeFunctionKnown(3, protected, &.{}));
            return result(.{ .table = exports });
        }
        fn main(_: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value { return result(.{ .string = "OK" }); }
        fn internal(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
            return ctx.callValue(ctx.getGlobal(22), &.{.{ .string = "Module:AbsentDependency" }});
        }
        fn protected(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
            const values = try ctx.callValue(ctx.getGlobal(16), &.{
                ctx.getGlobal(22), .{ .string = "Module:AbsentDependency" },
            });
            defer rt.freeResults(values);
            try std.testing.expect(values.len >= 2 and values[0] == .boolean and !values[0].boolean);
            try std.testing.expectEqualStrings("ModuleNotFound", values[1].string);
            return result(.{ .string = "CAUGHT" });
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const allocator = arena.allocator();
    var catalog = try rt.namespace_registry.Registry.init(allocator,
        "# wikidict-namespace-registry-v1\n# wiki\tmgwiktionary\n# dump-date\t20261001\n# content-language\tmg\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tentries\n" ++
        "8\tMediaWiki\tMediaWiki\tcase-sensitive\t0\t0\t0\t\tcompile_only\tinput\n" ++
        "10\tEndrika\tTemplate\tcase-sensitive\t1\t0\t0\t\tcompile_only\tinput\n" ++
        "14\tSokajy\tCategory\tcase-sensitive\t0\t0\t0\t\tcompile_only\tinput\n" ++
        "828\tModule\tModule\tcase-sensitive\t1\t0\t0\t\tcompile_only\tinput\n");
    defer catalog.deinit();
    var runtime = try rt.Context.initProgram(allocator, 24, 1); defer runtime.deinit(); runtime.namespace_catalog = &catalog;
    const functions = [_]rt.FunctionFn{rt.stabilize(P.root)}; runtime.module_root_entries = &functions;
    runtime.configureModules(null, TestModule.lookup, TestModule.name);
    try rt.bindGlobalTable(&runtime, null, 0); try stdlib.install(&runtime);
    var source: P = .{};
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23,
        .provider = .{ .ctx = &source, .get = P.get, .exists = P.exists, .interface_message = P.messages }, .install_scribunto = installTestInvoke };
    const error_text = "<strong class=\"error\"><span class=\"scribunto-error\">Erreur de script : le module « R:nb:NAOB » n’existe pas.</span></strong>";
    const actual = try expander.expandFragment("MG preserved page", "BEFORE{{Tsiahy:nb:NAOB}}AFTER\n# [[kept]]\n{{#invoke:Test|main}}", 1_794_174_780);
    try std.testing.expectEqualStrings("BEFORE" ++ error_text ++ "AFTER\n# [[kept]]\nOK", actual);
    // Omitted-function behavior is a separate existing project limitation:
    // present modules retain default-main; missing modules keep their original
    // typed failure instead of acquiring the wrong nosuchmodule precedence.
    try std.testing.expectError(error.ModuleNotFound, expander.expandFragment("Page", "{{#invoke:R:nb:NAOB}}", 1_794_174_780));
    try std.testing.expectEqualStrings("OK", try expander.expandFragment("Page", "{{#invoke:Test}}", 1_794_174_780));
    // Missing module wins before expansion of function and value expressions.
    try std.testing.expectEqualStrings(error_text, try expander.expandFragment("Page",
        "{{#invoke: R:nb:NAOB |{{Explode}}|x={{Explode}}}}", 1_794_174_780));
    try std.testing.expectEqualStrings("CAUGHT|OK", try expander.expandFragment("Page",
        "{{#iferror:{{#invoke:R:nb:NAOB|main}}|CAUGHT|BAD}}|{{#invoke:Test|main}}", 1_794_174_780));
    const arguments = try runtime.newTable();
    try arguments.rawSet(allocator, .{ .number = 1 }, .{ .string = " R:nb:NAOB " });
    try arguments.rawSet(allocator, .{ .number = 2 }, .{ .string = "main" });
    expander.attach(); try std.testing.expectEqualStrings(error_text, try expander.frameParserInvoke(arguments));
    try arguments.rawSet(allocator, .{ .number = 2 }, .nil);
    try std.testing.expectError(error.ModuleNotFound, expander.frameParserInvoke(arguments));
    try arguments.rawSet(allocator, .{ .number = 1 }, .{ .string = "Test" });
    try std.testing.expectEqualStrings("OK", try expander.frameParserInvoke(arguments));
    const internal = try expander.expandFragment("Page", "A{{#invoke:Test|internal}}B{{#invoke:Test|protected}}C{{#invoke:Test|main}}", 1_794_174_780);
    try std.testing.expectEqualStrings("A<strong class=\"error\"><span class=\"scribunto-error\">Lua error in Module:Test: ModuleNotFound</span></strong>BCAUGHTCOK", internal);
    try std.testing.expectError(error.ModuleNotFound, runtime.requireByName("Module:AbsentDependency"));
    // Existing substitution is nonrecursive and the returned error is not
    // re-expanded as wikitext; message and operand HTML are text-escaped once.
    source.message = "$1|$2|{{Explode}}"; expander.attach();
    try std.testing.expectEqualStrings("<strong class=\"error\"><span class=\"scribunto-error\">(unknown code location)|&lt;b&gt;&amp;$2|{{Explode}}</span></strong>",
        try expander.missingInvokeModuleMarkup("<b>&$2"));
    source.message = null;
    try std.testing.expectError(error.InterfaceMessageSnapshotMissing, expander.expandFragment("Page", "{{#invoke:R:nb:NAOB|main}}", 1_794_174_780));
    try std.testing.expect(runtime.current_frame == null and runtime.aotErrorName() == null and !runtime.last_error_present);
}

test "native generated comment normalization retains later missing coordinates and Lua unknown refusal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.initProgram(a, 24, 1);
    defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    const functions = [_]rt.FunctionFn{rt.stabilize(TestModule.root)};
    runtime.module_root_entries = &functions;
    runtime.configureModules(null, TestModule.lookup, TestModule.name);
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists }, .install_scribunto = installTestInvoke };
    const generated = "Generated A__NOEDITSECTION__B\nISBN 9780306406157\n__TOC__\nISBN 97803__TOC__06406157\nTail\n&lt;nowiki>__NOEDITSECTION__[[B]]</nowiki>\nAB";
    const input = "{{#invoke:Test|generated_comments}}|{{Missing}}";
    const output = try expander.expandFragment("Page", input, 1_670_803_200);
    try std.testing.expectEqualStrings(generated ++ "|[[:Template:Missing]]", output);
    var phase = try dependency.decode(a, expander.missing_dependency_metadata.?, output, "");
    defer phase.deinit();
    try std.testing.expectEqual(@as(usize, 1), phase.occurrences().len);
    try std.testing.expectEqualStrings("Template:Missing", phase.occurrences()[0].title);
    try std.testing.expectEqual(@as(usize, 1), phase.output().ranges.len);
    try std.testing.expectEqual(@as(u32, generated.len + 1), phase.output().ranges[0].start);
    try std.testing.expectEqual(@as(u32, @intCast(output.len)), phase.output().ranges[0].end);
    try std.testing.expectEqual(@as(u32, 1), phase.output().ranges[0].occurrence);
    // A retained known sibling does not grant provenance to arbitrary Lua output.
    try std.testing.expect(phase.output().unknown);
}


test "retained Hindi invoke order keeps later missing range while explicit literal origins differ from legacy strings" {
    // Raw p1500036/r6013495, 199B/3ffa12cb. The real call order and
    // later missing name are retained; controlled Lua exports exercise the new
    // boundary, not an assertion that the real hi-IPA/audio/hi-verb are qualified.
    const P = struct {
        threadlocal var literal_contract = true;
        fn get(_: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
            for ([_][]const u8{ ":hi-IPA", ":audio", ":hi-verb" }) |suffix|
                if (std.mem.endsWith(u8, title, suffix)) return "{{#invoke:Test|main}}";
            return null;
        }
        fn exists(_: ?*anyopaque, _: []const u8) !bool { return false; }
        fn result(value: Value) ![]const Value {
            const values = try std.heap.smp_allocator.alloc(Value, 1); values[0] = value; return values;
        }
        fn root(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
            const exports = try ctx.newTable();
            try exports.rawSet(ctx.allocator, .{ .string = "main" }, try ctx.makeFunctionKnown(1, run, &.{}));
            return result(.{ .table = exports });
        }
        fn run(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
            const text = "Hindi<!---->";
            const format = "%s";
            // This is exactly the new emitter event. Returning a legacy string
            // with identical bytes does not acquire its authority.
            if (literal_contract) { rt.string_origins.literal(text); rt.string_origins.literal(format); }
            const copied = try ctx.ownString(text);
            const string = ctx.getGlobal(18);
            const sub = try ctx.getIndex(string, .{ .string = "sub" });
            const sliced = try ctx.callValue(sub, &.{ .{ .string = copied }, .{ .number = 1 }, .{ .number = -1 } });
            defer rt.freeResults(sliced);
            const joined = try ctx.concatValues(sliced);
            const formatter = try ctx.getIndex(string, .{ .string = "format" });
            return ctx.callValue(formatter, &.{ .{ .string = format }, joined });
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var runtime = try rt.Context.initProgram(a, 24, 1); defer runtime.deinit();
    const functions = [_]rt.FunctionFn{rt.stabilize(P.root)};
    runtime.module_root_entries = &functions; runtime.configureModules(null, TestModule.lookup, TestModule.name);
    try rt.bindGlobalTable(&runtime, null, 0); try stdlib.install(&runtime); try installTestHost(&runtime, 18, 23);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23,
        .provider = .{ .get = P.get, .exists = P.exists }, .install_scribunto = installTestInvoke };
    const source = "==印地語==\n\n===發音===\n* {{hi-IPA}}\n* {{audio|hi|LL-Q1568 (hin)-AryamanA-देखना.wav|音頻}}\n\n===動詞===\n{{hi-verb|t|ur=دیکھنا}}\n\n# [[看]]\n\n===拓展閲讀===\n* {{R:hi:Rajpal}}";
    var expected_output: ?[]const u8 = null;
    for ([_]bool{ true, false }) |literal_contract| {
        P.literal_contract = literal_contract;
        const output = try expander.expandFragment("देखना", source, 1_794_174_780);
        if (expected_output) |expected| try std.testing.expectEqualStrings(expected, output)
        else expected_output = try a.dupe(u8, output);
        try std.testing.expect(std.mem.indexOf(u8, output, "<!---->") == null);
        var phase = try dependency.decode(a, expander.missing_dependency_metadata orelse return error.MissingSerializerPhase, output, "");
        defer phase.deinit();
        try std.testing.expectEqual(@as(usize, 1), phase.occurrences().len);
        try std.testing.expectEqualStrings("Template:R:hi:Rajpal", phase.occurrences()[0].title);
        try std.testing.expectEqual(@as(usize, 1), phase.output().ranges.len);
        const marker = "[[:Template:R:hi:Rajpal]]";
        const start = std.mem.indexOf(u8, output, marker) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u32, @intCast(start)), phase.output().ranges[0].start);
        try std.testing.expectEqual(@as(u32, @intCast(start + marker.len)), phase.output().ranges[0].end);
        try std.testing.expectEqual(!literal_contract, phase.output().unknown);
    }
}


test "direct frame provenance allocation failures survive Lua pcall without changing healthy frame bytes" {
    const P = struct {
        const Mode = enum { preprocess, expand_template };
        threadlocal var mode: Mode = .preprocess;
        threadlocal var fail_metadata = false;
        threadlocal var caught = false;
        fn get(_: ?*anyopaque, a: std.mem.Allocator, title: []const u8) !?[]const u8 {
            return if (std.mem.endsWith(u8, title, ":OriginTarget")) try a.dupe(u8, "native frame body") else null;
        }
        fn exists(_: ?*anyopaque, _: []const u8) !bool { return false; }
        fn result(value: Value) ![]const Value {
            const values = try std.heap.smp_allocator.alloc(Value, 1); values[0] = value; return values;
        }
        fn root(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
            const exports = try ctx.newTable();
            try exports.rawSet(ctx.allocator, .{ .string = "main" }, try ctx.makeFunctionKnown(1, run, &.{}));
            return result(.{ .table = exports });
        }
        fn run(ctx: *rt.Context, _: rt.Captures, args: []const Value) ![]const Value {
            const source = "native frame body";
            const output = "AFTER";
            rt.string_origins.literal(source); rt.string_origins.literal(output);
            const expander: *Expander = @ptrCast(@alignCast(host_api.get(ctx).?.ctx.?));
            const origins = expander.origin_ledger orelse return error.MissingOriginLedger;
            const saved_allocator = origins.a;
            var failing = std.testing.FailingAllocator.init(saved_allocator, .{ .fail_index = 0 });
            const spec = try ctx.newTable();
            try spec.rawSet(ctx.allocator, .{ .string = "title" }, .{ .string = "OriginTarget" });
            const method = try ctx.getIndex(args[0], .{ .string = if (mode == .preprocess) "preprocess" else "expandTemplate" });
            if (fail_metadata) origins.a = failing.allocator();
            defer origins.a = saved_allocator;
            const protected = try ctx.callValue(ctx.getGlobal(16), &.{ method, args[0],
                if (mode == .preprocess) .{ .string = source } else .{ .table = spec } });
            defer rt.freeResults(protected);
            try std.testing.expect(protected.len >= 2 and protected[0] == .boolean);
            if (fail_metadata) {
                try std.testing.expect(!protected[0].boolean);
                try std.testing.expectEqualStrings("OutOfMemory", protected[1].string);
                caught = true;
            } else {
                try std.testing.expect(protected[0].boolean);
                try std.testing.expectEqualStrings(source, protected[1].string);
            }
            // No new literal/copy hook after the fault: only the direct frame
            // metadata operation can have latched it across this protected call.
            return result(.{ .string = output });
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var runtime = try rt.Context.initProgram(a, 24, 1); defer runtime.deinit();
    const functions = [_]rt.FunctionFn{rt.stabilize(P.root)};
    runtime.module_root_entries = &functions; runtime.configureModules(null, TestModule.lookup, TestModule.name);
    try rt.bindGlobalTable(&runtime, null, 0); try stdlib.install(&runtime); try installTestHost(&runtime, 18, 23);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23,
        .provider = .{ .get = P.get, .exists = P.exists }, .install_scribunto = installTestInvoke };
    for ([_]P.Mode{ .preprocess, .expand_template }) |mode| {
        P.mode = mode; P.caught = false; P.fail_metadata = false;
        try std.testing.expectEqualStrings("AFTER", try expander.expandFragment("Page", "{{#invoke:Test|main}}", null));
        try std.testing.expect(!P.caught);
        P.fail_metadata = true;
        try std.testing.expectError(error.OutOfMemory, expander.expandFragment("Page", "{{#invoke:Test|main}}", null));
        try std.testing.expect(P.caught);
    }
}

test "native conversion enabled argument splitting preserves selected KU title marker tracked and plain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 24, 1);
    defer runtime.deinit();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists, .language_conversion_enabled = true } };
    const content = "#if:yes|-{T|ku-latn:{{PAGENAME}};ku-arab:مال}-|no";
    const expected = "-{T|ku-latn:mal;ku-arab:مال}-";
    const params = try runtime.newTable();
    expander.beginPage("mal", content, 1_670_803_200);
    try std.testing.expectEqualStrings(expected, try expander.expandConstruct(content, params, "mal", 1));
    const tracked = try expander.expandConstructTracked(content, params, "mal", 1);
    try std.testing.expectEqualStrings(expected, tracked.bytes);
    try std.testing.expectEqualStrings(expected, try expander.expandFragment("mal", "{{#if:yes|-{T|ku-latn:{{PAGENAME}};ku-arab:مال}-|no}}", 1_670_803_200));
    // Global false and absent retain the ordinary non-conversion preprocessor.
    for ([_]?bool{ false, null }) |enabled| {
        expander.provider.language_conversion_enabled = enabled;
        try std.testing.expectEqualStrings("-{T", try expander.expandFragment("mal", "{{#if:yes|-{T|ku-latn:{{PAGENAME}};ku-arab:مال}-|no}}", 1_670_803_200));
    }
    expander.provider.language_conversion_enabled = true;
    try std.testing.expectEqualStrings("-{a}}b}-", try expander.expandFragment("mal", "{{#if:yes|-{a}}b}-|no}}", 1_670_803_200));
    try std.testing.expectEqualStrings("-{x|ok}-", try expander.expandFragment("mal", "{{#if:|{{Missing template}}|-{x|ok}-}}", 1_670_803_200));
}

test "native selected retained ku ar template keeps complete title conversion through if branch" {
    const Source = struct {
        // Exact decoded views from p61954/r6115015 and p1324977/r6058922.
        const ku_ar = "{{#if:{{{1|}}}{{{2|}}}<!--\n-->|{{ku-ar-bibîne<!-- \nku-latn:\n-->|{{g|ku|kurdî-erebî}}: {{g|ku|{{{1|}}}|{{{2|}}}|tr=-}}<!-- \nku-arab:\n-->|[[کوردی-لاتینی]]: {{PAGENAME}}<!-- \n-->}}<!-- \n-->-{T|ku-latn:{{PAGENAME}};ku-arab:{{{1|}}}}-<!--Sernavê sayfeyê bi ku-arab dibe parametreya 1\n-->|{{g|ku|kurdî-erebî}}<!--\n-->}}<noinclude>\n{{belgekirin}}\n</noinclude>";
        const choice = "-{ku-latn:{{{1}}};ku-arab:{{{2}}}}-<noinclude>{{belgekirin|naverok=tiştê di {{param|1}} de bi variant ku-latn tê xane, tiştê di {{param|2}} de bi variant ku-arab xuya dibe.}}</noinclude>";
        fn get(_: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
            if (std.ascii.eqlIgnoreCase(title, "Template:ku-ar")) return ku_ar;
            if (std.ascii.eqlIgnoreCase(title, "Template:ku-ar-bibîne")) return choice;
            // Isolated unrelated rendering wrapper; retained conversion bodies above are exact.
            if (std.ascii.eqlIgnoreCase(title, "Template:g")) return "{{{2|}}}";
            return null;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 24, 1);
    defer runtime.deinit();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = Source.get, .exists = TestProvider.exists, .language_conversion_enabled = true } };
    const output = try expander.expandFragment("mal", "{{ku-ar|مال}}", 1_670_803_200);
    try std.testing.expect(std.mem.indexOf(u8, output, "-{ku-latn:kurdî-erebî: مال;ku-arab:[[کوردی-لاتینی]]: mal}-") != null);
    try std.testing.expect(std.mem.endsWith(u8, output, "-{T|ku-latn:mal;ku-arab:مال}-"));
}


test "caller bullet label separator survives a newline contributed by the transclusion" {
    const label = "[[şəkil:Flag of Kyrgyzstan.svg|22px]] qırğızca\n";
    try LiteralCurlyBoundaryFixture.check("*{{LabelWithNewline}}: {{LabelTranslation|ky|}}", "*" ++ label ++ "&#58; <span lang=\"ky\" xml:lang=\"ky\">[[|]]</span> [[:ky:|<sup>(ky)</sup>]]");
    try LiteralCurlyBoundaryFixture.check("*{{LabelWithNewline}}: {{uc:k}}", "*" ++ label ++ "&#58; K");
    try LiteralCurlyBoundaryFixture.check("*{{LabelWithoutNewline}}: {{uc:k}}", "*label: K");
    try LiteralCurlyBoundaryFixture.check("*{{LabelWithNewline}}\n: {{uc:k}}", "*" ++ label ++ "\n: K");
    try LiteralCurlyBoundaryFixture.check(";term\n: {{uc:k}}", ";term\n: K");
    try LiteralCurlyBoundaryFixture.check("*{{LabelWithNewline}}:: {{uc:k}}", "*" ++ label ++ ":: K");
}

// MediaWiki Preprocessor has an unconditional [[...]] stack entry; only -{...}-
// depends on language conversion. The LT provider exercises a literal }} label.
test "ordinary brace scanning keeps link scope independent of language conversion" {
    const cases = [_]struct { source: []const u8, parameter: bool = false }{
        .{ .source = "{{#if:yes|[[Target|<nowiki>{{</nowiki>name}}]]|no}}" },
        .{ .source = "{{{value|[[Target|<nowiki>{{</nowiki>name}}]]}}}", .parameter = true },
        .{ .source = "{{#if:yes|[[Target|{{#if:yes|label}}}}]]|no}}" },
        .{ .source = "{{#if:yes|[[Target|label}}]][[Other|tail}}]]|no}}" },
        .{ .source = "{{#if:yes|[[Target|{{{name|label}}}}}]]|no}}" },
        .{ .source = "{{#if:yes|<nowiki>[[</nowiki>literal}}" },
        .{ .source = "{{#if:yes|<!-- [[ }} -->literal}}" },
    };
    for (cases) |case| {
        const width: usize = if (case.parameter) 3 else 2;
        const expected = case.source.len - width;
        const actual = if (case.parameter) preprocess.findParamEnd(case.source, 0) else preprocess.findTemplateEnd(case.source, 0);
        try std.testing.expectEqual(expected, actual orelse return error.TestUnexpectedResult);
        for ([_]bool{ false, true }) |enabled| {
            var scan: preprocess.ExpansionScan = .{ .conversion_enabled = enabled };
            const node = scan.next(case.source, 0, false) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(usize, 0), node.construct.open);
            try std.testing.expectEqual(expected, node.construct.close);
            try std.testing.expectEqual(if (case.parameter) preprocess.ConstructKind.parameter else .template, node.construct.kind);
        }
    }
    // Upstream leaves the enclosing construct unclosed when a real [[ never
    // closes. A lone [ and entity text are not that stack entry.
    for ([_][]const u8{
        "{{#if:yes|[[Target|label}}",
        "{{#if:yes|[[Target|label]}}",
        "{{{value|[[Target|label}}}",
        "{{#if:yes|[[Target|{{#if:yes|label}}}}",
    }) |source| {
        try std.testing.expect(preprocess.findTemplateEnd(source, 0) == null);
        try std.testing.expect(preprocess.findParamEnd(source, 0) == null);
    }
    const lone = "{{#if:yes|[Target|label}}";
    try std.testing.expectEqual(lone.len - 2, preprocess.findTemplateEnd(lone, 0).?);
    const entity = "{{#if:yes|&#91;&#91;Target|label}}";
    try std.testing.expectEqual(entity.len - 2, preprocess.findTemplateEnd(entity, 0).?);
    const adjacent = "{{#if:yes|[[Target|label}}]]}}}}";
    try std.testing.expectEqual(adjacent.len - 4, preprocess.findTemplateEnd(adjacent, 0).?);
    const conversion = "{{#if:yes|-{a}}b}-|no}}";
    try std.testing.expectEqual(std.mem.indexOf(u8, conversion, "}}b").?, preprocess.findTemplateEnd(conversion, 0).?);
    var enabled: preprocess.ExpansionScan = .{ .conversion_enabled = true };
    try std.testing.expectEqual(conversion.len - 2, enabled.next(conversion, 0, false).?.construct.close);
}

const LithuanianTranslationBraceSource = struct {
    words: *const rt.namespace_registry.magic_words.Registry,
    calls: usize = 0,
    fn fixture(title: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, title, "Šablonas:trans-top")) return @embedFile("testdata/lt-link-brace01/trans-top.wikitext");
        if (std.mem.eql(u8, title, "Šablonas:top")) return @embedFile("testdata/lt-link-brace01/top.wikitext");
        return null;
    }
    fn exists(_: ?*anyopaque, title: []const u8) !bool {
        return fixture(title) != null;
    }
    fn parser(raw: ?*anyopaque, name: []const u8) !?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        return self.words.resolve(name, .parser_function);
    }
    fn get(raw: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        return fixture(title);
    }
};

test "original Lithuanian translation header keeps literal closing braces inside its help link" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.initProgram(a, 24, 1);
    defer runtime.deinit();
    var ns = try rt.namespace_registry.Registry.init(a, @embedFile("testdata/lt-link-brace01/namespace-registry.tsv"));
    defer ns.deinit();
    runtime.namespace_catalog = &ns;
    var words = try rt.namespace_registry.magic_words.Registry.init(a, @embedFile("testdata/lt-link-brace01/magic-words.tsv"), "ltwiktionary", "20261001", "lt");
    defer words.deinit();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var source: LithuanianTranslationBraceSource = .{ .words = &words };
    var expander: Expander = .{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23,
        .provider = .{ .ctx = &source, .get = LithuanianTranslationBraceSource.get, .exists = LithuanianTranslationBraceSource.exists,
            .resolve_parser_function = LithuanianTranslationBraceSource.parser, .language_conversion_enabled = false } };
    const warning = "<div style=\"background-color: #f0fff0;\">\n:''Tolesni vertimai turi būti patikrinti ir įterpti pagal kategorijas į atitinkamą vertimų lentelę aukščiau. Jei atitinkamos lentelės nėra, ją sukurkite, nurodydami kategoriją, kuri paprastai sutampa su viena iš galimų žodžio reikšmių. Žr. [[Šablonas:top|<nowiki>{{</nowiki>trans-top}}]].\n''</div>";
    const head = "<div class=\"NavFrame\" style=\"clear:both;\"><div class=\"NavHead\" align=\"left\">&nbsp; ";
    const tail = "</div>\n<div class=\"NavContent\">\n{| border=\"0\" width=\"100%\" class=\"translations\"\n|-\n| bgcolor=\"#FFFFE0\" valign=\"top\" width=\"48%\" align=\"left\" |";
    // Exact original actual p5024/r1756862 transclusion. This is the complete
    // original provider, not a replacement template or a full article capture.
    const expected_empty = warning ++ head ++ "Vertimai, kuriuos reikia patikrinti ir sukategorizuoti" ++ tail;
    const actual = try expander.expandFragment("actual", "{{trans-top}}", 1_791_731_560);
    try std.testing.expectEqualStrings(expected_empty, actual);
    try std.testing.expect(!expander.unsupported_parser_function);
    try std.testing.expect(expander.missing_dependency_metadata == null);
    // Nonempty source parameter selects the other branch and must not leave
    // warning suffixes. It is a deliberate branch contrast, not the full
    // ambasada Kategorija dependency expansion.
    const named = try expander.expandFragment("ambasada", "{{trans-top|named}}", 1_791_731_560);
    try std.testing.expectEqualStrings(head ++ "[[ambasada]]:&nbsp;named" ++ tail, named);
    try std.testing.expect(!expander.unsupported_parser_function);
    try std.testing.expect(expander.missing_dependency_metadata == null);
    const old_top = try expander.expandFragment("actual", "{{top|named}}", 1_791_731_560);
    try std.testing.expectEqualStrings("<div class=\"NavFrame\" style=\"clear:both;\"><div class=\"NavHead\" align=\"left\">&nbsp; &nbsp; named" ++ tail, old_top);
    // Direct ordinary expansion retains one complete help link, nested values,
    // adjacent closers and conversion-disabled syntax without a second engine.
    try std.testing.expectEqualStrings("[[Target|<nowiki>{{</nowiki>name}}]]", try expander.expandFragment("actual", "{{#if:yes|[[Target|<nowiki>{{</nowiki>name}}]]|no}}", 1_791_731_560));
    try std.testing.expectEqualStrings("[[Target|actual}}]]", try expander.expandFragment("actual", "{{#if:yes|[[Target|{{PAGENAME}}}}]]|no}}", 1_791_731_560));
    try std.testing.expectEqualStrings("-{T", try expander.expandFragment("actual", "{{#if:yes|-{T|ku-latn:{{PAGENAME}};ku-arab:مال}-|no}}", 1_791_731_560));
}

const MalayalamRawTransclusionFixture = struct {
    const aliases = rt.namespace_registry.magic_words;
    templates: std.json.Value,
    words: *const aliases.Registry,
    reference_valid_names: bool = false,
    missing_lookups: std.ArrayList([]const u8) = .empty,

    fn get(raw: ?*anyopaque, a: std.mem.Allocator, title: []const u8) !?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        // Independent reference branch for the fixed safe-name calls in the
        // two retained-template cases. This is not a production provider grant.
        if (self.reference_valid_names and std.mem.eql(u8, title, "ഫലകം:isValidPageName")) return "valid";
        if (self.templates.object.get(title)) |row| return row.object.get("text").?.string;
        if (std.mem.eql(u8, title, "ഫലകം:PAGENAME")) return "template-pagename";
        if (std.mem.eql(u8, title, "ഫലകം:raw:Probe")) return "literal-raw-title";
        if (std.mem.eql(u8, title, "raw:Probe")) return "main-raw-title";
        if (std.mem.eql(u8, title, "ഫലകം:Probe")) return "{{{1|default}}}";
        try self.missing_lookups.append(a, try a.dupe(u8, title));
        return null;
    }
    fn exists(_: ?*anyopaque, _: []const u8) !bool { return false; }
    fn resolve(raw: ?*anyopaque, name: []const u8, form: aliases.Form) !?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        return self.words.resolve(name, form);
    }
    fn parser(raw: ?*anyopaque, name: []const u8) !?[]const u8 { return resolve(raw, name, .parser_function); }
    fn provider(self: *@This()) Provider {
        return .{ .ctx = self, .get = get, .exists = exists, .resolve_title_magic = resolve,
            .resolve_parser_function = parser, .interwiki_map = TestProvider.interwikiMap };
    }
    fn missing(expander: *Expander, a: std.mem.Allocator, output: []const u8, expected: []const u8) !void {
        var phase = try dependency.decode(a, expander.missing_dependency_metadata.?, output, "");
        defer phase.deinit();
        try std.testing.expectEqual(@as(usize, 1), phase.occurrences().len);
        try std.testing.expectEqualStrings(expected, phase.occurrences()[0].title);
    }
};

test "retained Malayalam A-battery and adjective expand through captured raw Special validation" {
    const F = MalayalamRawTransclusionFixture;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var ns = try rt.namespace_registry.Registry.init(a, @embedFile("testdata/ml-raw-transclusion/namespace-registry.tsv")); defer ns.deinit();
    var words = try F.aliases.Registry.init(a, @embedFile("testdata/ml-raw-transclusion/magic-words.tsv"), ns.wiki, ns.dump_date, ns.content_language); defer words.deinit();
    var before = try F.aliases.Registry.init(a, @embedFile("testdata/ml-raw-transclusion/magic-words-before.tsv"), ns.wiki, ns.dump_date, ns.content_language); defer before.deinit();
    var templates = try std.json.parseFromSlice(std.json.Value, a, @embedFile("testdata/ml-raw-transclusion/templates.json"), .{}); defer templates.deinit();
    var source: F = .{ .templates = templates.value, .words = &words };
    var runtime = try rt.Context.init(a, 24); defer runtime.deinit();
    runtime.namespace_catalog = &ns;
    try rt.bindGlobalTable(&runtime, null, 0); try stdlib.install(&runtime);
    var expander: Expander = .{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = source.provider(), .install_scribunto = installTestInvoke };
    const raw_page = @embedFile("testdata/ml-raw-transclusion/A-battery.wikitext");
    // Same original raw page + full original template bodies; old alias input
    // retains the actual erroneous unresolved parameter rather than hiding it.
    source.words = &before;
    const old = try a.dupe(u8, try expander.expandFragment("A-battery", raw_page, null));
    try std.testing.expect(std.mem.indexOf(u8, old, "{{{1}}}") != null);
    source.words = &words;
    const actual = try a.dupe(u8, try expander.expandFragment("A-battery", raw_page, null));
    try std.testing.expect(std.mem.indexOf(u8, actual, "{{{") == null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "[[A-batterys#ഇംഗ്ലീഷ്|A-batterys]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, " വൈദ്യുതിസംഭരണപേടക൦") != null);
    try std.testing.expect(std.mem.startsWith(u8, actual, "==ഇംഗ്ലീഷ്==\n===നാമം===\n"));
    source.reference_valid_names = true;
    const expected = try expander.expandFragment("A-battery", raw_page, null);
    try std.testing.expectEqualStrings(expected, actual);
    source.reference_valid_names = false;
    const adjective = try a.dupe(u8, try expander.expandFragment("bright", "{{en-adj}}", null));
    try std.testing.expect(std.mem.indexOf(u8, adjective, "more bright") != null);
    try std.testing.expect(std.mem.indexOf(u8, adjective, "most bright") != null);
    try std.testing.expect(std.mem.indexOf(u8, adjective, "{{{") == null);
    source.reference_valid_names = true;
    try std.testing.expectEqualStrings(try expander.expandFragment("bright", "{{en-adj}}", null), adjective);
    source.reference_valid_names = false;
    try std.testing.expectEqualStrings("valid|valid||", try expander.expandFragment("Page", "{{isValidPageName|word}}|{{isValidPageName|-1}}|{{isValidPageName|-}}|{{isValidPageName|[bad]}}", null));
}

test "raw transclusion keeps namespace invalid target missing and interwiki boundaries" {
    const F = MalayalamRawTransclusionFixture;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try rt.namespace_registry.Registry.init(a, @embedFile("testdata/ml-raw-transclusion/namespace-registry.tsv")); defer ns.deinit();
    var words = try F.aliases.Registry.init(a, @embedFile("testdata/ml-raw-transclusion/magic-words.tsv"), ns.wiki, ns.dump_date, ns.content_language); defer words.deinit();
    var templates = try std.json.parseFromSlice(std.json.Value, a, @embedFile("testdata/ml-raw-transclusion/templates.json"), .{}); defer templates.deinit();
    var source: F = .{ .templates = templates.value, .words = &words };
    var runtime = try rt.Context.init(a, 24); defer runtime.deinit(); runtime.namespace_catalog = &ns;
    try rt.bindGlobalTable(&runtime, null, 0); try stdlib.install(&runtime);
    var expander: Expander = .{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = source.provider(), .install_scribunto = installTestInvoke };
    try std.testing.expectEqualStrings("x|y|z|q|template-pagename|literal-raw-title|literal-raw-title|main-raw-title|Man", try expander.expandFragment("Page",
        "{{raw:Probe|x}}|{{അസംസ്കൃതം:Probe|y}}|{{RaW:Probe|z}}|{{{{{modifier|raw:}}}Probe|q}}|{{raw:PAGENAME}}|{{raw:raw:Probe}}|{{ഫലകം:raw:Probe}}|{{:raw:Probe}}|{{raw:ucfirst:man}}", null));
    var collision = try F.aliases.Registry.init(a, @embedFile("testdata/ml-raw-transclusion/magic-words.tsv") ++
        "pagename\t1\traw:PAGENAME\nucfirst\t0\traw:\n", ns.wiki, ns.dump_date, ns.content_language); defer collision.deinit();
    source.words = &collision;
    try std.testing.expectEqualStrings("Page|Page|template-pagename|PAYLOAD", try expander.expandFragment("Page",
        "{{raw:PAGENAME}}|{{raw:{{{target|PAGENAME}}}}}|{{raw:PAGENAME|ignored}}|{{raw:Probe|PAYLOAD}}", null));
    // Parser-function bodies use the untracked expansion path for the operand.
    try std.testing.expectEqualStrings("YES", try expander.expandFragment("Page", "{{#ifeq:{{raw:{{{target|PAGENAME}}}}}|Page|YES|NO}}", null));
    source.words = &words;
    const special = try expander.expandFragment("Page", "{{raw:പ്രത്യേകം:Whatlinkshere/word}}", null);
    try std.testing.expectEqualStrings("[[:പ്രത്യേകം:Whatlinkshere/word]]", special);
    // Special remains unavailable to the existing offline page provider. Keep
    // that attribution; recognizing RAW supplies no remote Special contents.
    try F.missing(&expander, a, special, "പ്രത്യേകം:Whatlinkshere/word");
    const missing = try expander.expandFragment("Page", "{{raw:Absent}}", null);
    try std.testing.expectEqualStrings("[[:ഫലകം:Absent]]", missing);
    try F.missing(&expander, a, missing, "ഫലകം:Absent");
    const before_invalid = source.missing_lookups.items.len;
    const invalid = try expander.expandFragment("Page", "{{raw:പ്രത്യേകം:Whatlinkshere/[bad]}}", null);
    try std.testing.expectEqualStrings("<nowiki>{{raw:പ്രത്യേകം:Whatlinkshere/[bad]}}</nowiki>", invalid);
    try std.testing.expectEqual(before_invalid, source.missing_lookups.items.len);
    try std.testing.expect(expander.missing_dependency_metadata == null);
    try std.testing.expectEqualStrings("<nowiki>{{</nowiki>raw:<nowiki>}}</nowiki>", try expander.expandFragment("Page", "{{raw:}}", null));
    const wrong = try expander.expandFragment("Page", "{{rawish:Absent}}", null);
    try F.missing(&expander, a, wrong, "ഫലകം:rawish:Absent");
    // Raw never enables external content retrieval. The existing map's exact
    // transcludable/nontranscludable contracts apply after modifier removal.
    try std.testing.expectError(error.ExternalInterwikiTransclusionUnsupported, expander.expandFragment("Page", "{{raw:remote:Page}}", null));
    try std.testing.expectEqualStrings("<nowiki>{{raw:w:Page}}</nowiki>", try expander.expandFragment("Page", "{{raw:w:Page}}", null));
    try std.testing.expectEqualStrings("LOCAL", try expander.expandFragment("Page", "{{raw:self:Probe|LOCAL}}", null));
    const args = try runtime.newTable();
    try std.testing.expectError(error.UnsupportedParserFunction, Expander.hostFrameParserFunction(&expander, a, "raw", args));
}

test "captured RAW aliases remain a separate bounded transclusion domain" {
    const Registry = rt.namespace_registry.magic_words.Registry;
    const parser_header = rt.namespace_registry.magic_words.parser_header;
    const base = parser_header ++ "\n# wiki\tmlwiktionary\n# dump-date\t20261001\n# content-language\tml\n";
    var registry = try Registry.init(std.testing.allocator, base ++
        "raw\t0\tഅസംസ്കൃതം:\nraw\t0\tRAW:\nraw\t1\tExact：\npagename\t1\tPAGENAME\nucfirst\t0\tRAW:\n", "mlwiktionary", "20261001", "ml");
    defer registry.deinit();
    try std.testing.expectEqualStrings("raw", registry.resolve("RaW:", .transclusion_modifier).?);
    try std.testing.expectEqualStrings("raw", registry.resolve("അസംസ്കൃതം:", .transclusion_modifier).?);
    try std.testing.expectEqualStrings("raw", registry.resolve("Exact：", .transclusion_modifier).?);
    try std.testing.expect(registry.resolve("exact：", .transclusion_modifier) == null);
    try std.testing.expect(registry.resolve("raw", .transclusion_modifier) == null);
    try std.testing.expect(registry.resolve("raw:", .variable) == null);
    try std.testing.expect(registry.resolve("raw:", .parser_function) == null);
    try std.testing.expectEqualStrings("ucfirst", registry.resolve("raw", .parser_function).?);
    try std.testing.expect(registry.resolve("അസംസ്കൃതം", .parser_function) == null);
    try std.testing.expect(registry.resolve("RAW:", .raw_suffix) == null);
    inline for (.{ "raw\t0\tRAW\n", "raw\t0\t:\n", "raw\t0\traw:extra:\n", "raw\t0\traw：extra:\n" }) |bad|
        try std.testing.expectError(error.InvalidMagicWordsSnapshot, Registry.init(std.testing.allocator, base ++ bad, "mlwiktionary", "20261001", "ml"));
}
