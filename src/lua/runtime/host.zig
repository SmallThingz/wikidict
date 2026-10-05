const std = @import("std");
const rt = @import("zig_runtime");

pub const PageExistsFn = *const fn (?*anyopaque, []const u8) anyerror!bool;
pub const PageContentFn = *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!?[]const u8;
pub const PageRedirectFn = *const fn (?*anyopaque, []const u8) anyerror!?[]const u8;
pub const PageIdFn = *const fn (?*anyopaque, []const u8) anyerror!?u64;
pub const PageContentModelFn = *const fn (?*anyopaque, []const u8) anyerror!?[]const u8;
pub const FramePreprocessFn = *const fn (?*anyopaque, std.mem.Allocator, []const u8, []const u8, *rt.Table) anyerror![]const u8;
pub const FrameExpandTemplateFn = *const fn (?*anyopaque, std.mem.Allocator, []const u8, *rt.Table) anyerror![]const u8;
pub const FrameExtensionTagFn = *const fn (?*anyopaque, std.mem.Allocator, []const u8, ?rt.Value, ?*rt.Table) anyerror![]const u8;
pub const FrameParserFunctionFn = *const fn (?*anyopaque, std.mem.Allocator, []const u8, *rt.Table) anyerror![]const u8;
pub const TextUnstripNoWikiFn = *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror![]const u8;

pub const ExternalData = struct {
    content_model: []const u8,
    source: []const u8,
};
pub const ExternalDataFn = *const fn (?*anyopaque, []const u8) anyerror!?ExternalData;

pub const CategoryStats = struct {
    all: u32,
    subcats: u32,
    files: u32,

    pub fn pages(self: CategoryStats) u32 {
        return self.all - self.subcats - self.files;
    }
};
pub const CategoryStatsFn = *const fn (?*anyopaque, []const u8) anyerror!?CategoryStats;

pub const InterfaceMessage = struct {
    source: ?[]const u8,
};
pub const InterfaceMessageFn = *const fn (?*anyopaque, std.mem.Allocator, []const u8, []const u8) anyerror!?InterfaceMessage;
pub fn normalizeInterfaceMessageKeyAlloc(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len == 0 or !std.unicode.utf8ValidateSlice(raw)) return error.InvalidInterfaceMessageKey;
    if (raw[0] >= 128) return error.UnsupportedInterfaceMessageKey;
    const key = try a.dupe(u8, raw);
    errdefer a.free(key);
    std.mem.replaceScalar(u8, key, ' ', '_');
    key[0] = std.ascii.toLower(key[0]);
    for (key) |c| if (c == '\t' or c == '\r' or c == '\n') return error.InvalidInterfaceMessageKey;
    return key;
}
pub const FileMetadata = struct {
    exists: bool,
    width: u32 = 0,
    height: u32 = 0,
};
pub const FileMetadataFn = *const fn (?*anyopaque, []const u8) anyerror!FileMetadata;

pub const InterwikiRow = struct {
    prefix: []const u8,
    url: []const u8,
    is_local: bool,
    is_current_wiki: bool,
    is_protocol_relative: bool,
    is_transcludable: bool,
};
pub const SiteInterwikiMapFn = *const fn (?*anyopaque) anyerror![]const InterwikiRow;
pub const WikibaseSitelinkFn = *const fn (?*anyopaque, []const u8, []const u8) anyerror!?[]const u8;
pub const WikibaseEntityText = struct {
    label: ?[]const u8,
    description: ?[]const u8,
};
pub const WikibaseEntityTextFn = *const fn (?*anyopaque, []const u8) anyerror!WikibaseEntityText;
pub const WikibaseEntity = struct {
    // Null is a captured missing entity; an uncaptured ID is an error.
    source: ?[]const u8,
};
pub const WikibaseEntityFn = *const fn (?*anyopaque, []const u8) anyerror!WikibaseEntity;
pub const WikibaseTerm = struct { value: []const u8, language: []const u8, source_language: ?[]const u8 = null };
pub const WikibaseEntityTerms = struct { label: ?WikibaseTerm, description: ?WikibaseTerm };
pub const WikibaseEntityTermsFn = *const fn (?*anyopaque, []const u8) anyerror!WikibaseEntityTerms;
pub const LanguageFallbacksFn = *const fn (?*anyopaque, []const u8) anyerror![]const []const u8;
pub const LanguageNameRow = struct { code: []const u8, name: []const u8 };
pub const LanguageNameScope = enum { all, mw, mwfile };
pub const LanguageDirection = enum { ltr, rtl };
pub const LanguageNamesFn = *const fn (?*anyopaque, ?[]const u8, LanguageNameScope) anyerror![]const LanguageNameRow;
pub const LanguageNameFn = *const fn (?*anyopaque, []const u8, ?[]const u8) anyerror![]const u8;
pub const LanguageDirectionFn = *const fn (?*anyopaque, []const u8) anyerror!LanguageDirection;
pub const LanguageKnownTagFn = *const fn (?*anyopaque, []const u8) anyerror!bool;

pub const Host = struct {
    ctx: ?*anyopaque = null,
    current_title: []const u8 = "",
    now_unix: ?i64 = null,
    invoke_depth: u32 = 0,
    page_exists: ?PageExistsFn = null,
    page_content: ?PageContentFn = null,
    page_redirect: ?PageRedirectFn = null,
    page_id: ?PageIdFn = null,
    page_content_model: ?PageContentModelFn = null,
    // The build provider pins these lookups for the lifetime of a page
    // expansion. They remain loadData effects across pages, but do not make an
    // exact same-page invocation result unstable.
    stable_page_reads: bool = false,
    frame_preprocess: ?FramePreprocessFn = null,
    frame_expand_template: ?FrameExpandTemplateFn = null,
    frame_extension_tag: ?FrameExtensionTagFn = null,
    frame_parser_function: ?FrameParserFunctionFn = null,
    text_unstrip_no_wiki: ?TextUnstripNoWikiFn = null,
    external_data: ?ExternalDataFn = null,
    category_stats: ?CategoryStatsFn = null,
    interface_message: ?InterfaceMessageFn = null,
    file_metadata: ?FileMetadataFn = null,
    // Exact captured site constant; owned by the immutable bundle provider.
    site_server: ?[]const u8 = null,
    site_interwiki_map: ?SiteInterwikiMapFn = null,
    // Only a native provider backed by one immutable snapshot may set this.
    stable_site_interwiki_map: bool = false,
    wikibase_sitelink: ?WikibaseSitelinkFn = null,
    wikibase_entity_text: ?WikibaseEntityTextFn = null,
    wikibase_entity: ?WikibaseEntityFn = null,
    wikibase_entity_terms: ?WikibaseEntityTermsFn = null,
    language_fallbacks: ?LanguageFallbacksFn = null,
    language_names: ?LanguageNamesFn = null,
    language_name: ?LanguageNameFn = null,
    language_direction: ?LanguageDirectionFn = null,
    language_known_tag: ?LanguageKnownTagFn = null,
};

// Library installation copies immutable corpus metadata before Lua observes it.
// Installation itself must not mark a loadData child as effectful: an unused
// host API is not a dependency. Provider ownership lasts through all contexts.
pub fn siteServerForInstall(runtime: *const rt.Context) ?[]const u8 {
    const host: *const Host = @ptrCast(@alignCast(runtime.host orelse return null));
    return host.site_server;
}

pub fn set(runtime: *rt.Context, host: ?*Host) void {
    runtime.setHost(if (host) |value| value else null);
}

pub const InvokeHostProbe = struct {
    observed: bool = false,
    previous: ?*@This() = null,
};

threadlocal var invoke_host_probe: ?*InvokeHostProbe = null;

pub fn beginInvokeHostProbe(probe: *InvokeHostProbe) void {
    probe.previous = invoke_host_probe;
    invoke_host_probe = probe;
}

pub fn endInvokeHostProbe(probe: *InvokeHostProbe) void {
    std.debug.assert(invoke_host_probe == probe);
    invoke_host_probe = probe.previous;
}

// enterInvoke needs the host to maintain invoke_depth and random state. This
// bookkeeping access is not evidence that Lua observed page-specific host data.
pub fn getForInvokeBookkeeping(runtime: *const rt.Context) ?*Host {
    rt.markLoadDataEffect();
    return @ptrCast(@alignCast(runtime.host orelse return null));
}

pub fn get(runtime: *const rt.Context) ?*Host {
    // A loadData result may be shared across pages only if its evaluation did
    // not observe the page host (including title, time, and provider data).
    var probe = invoke_host_probe;
    while (probe) |active| : (probe = active.previous) active.observed = true;
    if (runtime.page_stable_host_effects) {
        rt.markPageTemplateEffect();
        return @ptrCast(@alignCast(runtime.host orelse return null));
    }
    return getForInvokeBookkeeping(runtime);
}

pub fn getForStablePageRead(runtime: *const rt.Context) ?*Host {
    const host: *Host = @ptrCast(@alignCast(runtime.host orelse {
        rt.markLoadDataEffect();
        return null;
    }));
    if (!host.stable_page_reads) {
        var probe = invoke_host_probe;
        while (probe) |active| : (probe = active.previous) active.observed = true;
        rt.markLoadDataEffect();
    } else {
        // The dump-backed provider is immutable for the lifetime of a bundle
        // worker, so it is safe for one-time module-root construction even
        // though shared loadData remains deliberately more conservative.
        rt.markLoadDataOnlyEffect();
    }
    return host;
}

pub fn getForStableInterwikiMap(runtime: *const rt.Context) ?*Host {
    var probe = invoke_host_probe;
    while (probe) |active| : (probe = active.previous) active.observed = true;
    const host: *Host = @ptrCast(@alignCast(runtime.host orelse {
        rt.markLoadDataEffect();
        return null;
    }));
    if (!host.stable_site_interwiki_map) rt.markLoadDataEffect();
    return host;
}

test "invoke host probe excludes bookkeeping and propagates nested observations" {
    var runtime = try rt.Context.init(std.testing.allocator, 0);
    defer runtime.deinit();
    var host: Host = .{};
    set(&runtime, &host);

    var parent: InvokeHostProbe = .{};
    beginInvokeHostProbe(&parent);
    defer endInvokeHostProbe(&parent);
    try std.testing.expect(getForInvokeBookkeeping(&runtime) == &host);
    try std.testing.expect(!parent.observed);

    var child: InvokeHostProbe = .{};
    beginInvokeHostProbe(&child);
    try std.testing.expect(get(&runtime) == &host);
    endInvokeHostProbe(&child);
    try std.testing.expect(child.observed);
    try std.testing.expect(parent.observed);
}

test "mutable interwiki host remains page-sensitive and stable capability is explicit" {
    var runtime = try rt.Context.init(std.testing.allocator, 0);
    defer runtime.deinit();
    var host = Host{};
    set(&runtime, &host);
    var effect = false;
    const previous = rt.beginLoadDataEffectProbe(&effect);
    defer rt.endLoadDataEffectProbe(previous);
    _ = getForStableInterwikiMap(&runtime);
    try std.testing.expect(effect);
    effect = false;
    host.stable_site_interwiki_map = true;
    _ = getForStableInterwikiMap(&runtime);
    try std.testing.expect(!effect);
    _ = get(&runtime);
    try std.testing.expect(effect);
}

test "stable page reads stay loadData effects without invalidating same-page invoke reuse" {
    var runtime = try rt.Context.init(std.testing.allocator, 0);
    defer runtime.deinit();
    var host = Host{};
    set(&runtime, &host);

    var effect = false;
    const previous_effect = rt.beginLoadDataEffectProbe(&effect);
    defer rt.endLoadDataEffectProbe(previous_effect);
    var invoke: InvokeHostProbe = .{};
    beginInvokeHostProbe(&invoke);
    defer endInvokeHostProbe(&invoke);

    try std.testing.expect(getForStablePageRead(&runtime) == &host);
    try std.testing.expect(effect);
    try std.testing.expect(invoke.observed);

    effect = false;
    invoke.observed = false;
    host.stable_page_reads = true;
    try std.testing.expect(getForStablePageRead(&runtime) == &host);
    try std.testing.expect(effect);
    try std.testing.expect(!invoke.observed);
}
