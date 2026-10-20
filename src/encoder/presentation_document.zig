const std = @import("std");
const compiler = @import("presentation_compile.zig");
const semantic = @import("presentation_layout.zig");
const blobs = @import("blob_encoder");
const ir = blobs.document_ir;
const types = blobs.presentation_types;
const format = blobs.blob_format;
const codec = blobs.presentation_codec;
const A = std.mem.Allocator;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
fn unclosedFragmentTraceFromEnv() !bool {
    const raw = getenv("WIKIDICT_UNCLOSED_FRAGMENT_TRACE");
    return compiler.unclosedFragmentTraceEnabled(if (raw) |value| std.mem.span(value) else null);
}
// Expanded heading templates can leave spacing around decorative media.
// Consume the whole NBSP sequence, never individual UTF-8 continuation bytes.
fn trimHeading(raw: []const u8) []const u8 {
    var text = std.mem.trim(u8, raw, " \t\r\n");
    while (std.mem.startsWith(u8, text, "\u{a0}")) text = std.mem.trimStart(u8, text[2..], " \t\r\n");
    while (std.mem.endsWith(u8, text, "\u{a0}")) text = std.mem.trimEnd(u8, text[0 .. text.len - 2], " \t\r\n");
    return text;
}

const ImageRegistry = @import("namespace_registry").image_options.Registry;
const BehaviorRegistry = @import("namespace_registry").behavior_switches.Registry;
const NamespaceRegistry = @import("namespace_registry").Registry;
pub const Fallbacks = @import("presentation_fallback.zig").Report;
pub const ReferenceDefinitions = compiler.ReferenceDefinitions;
pub const PoemPhase = compiler.PoemPhase;
pub const FragmentPreContext = compiler.FragmentPreContext;
pub const FormattingAttributes = compiler.FormattingAttributes;
pub const QuoteSeed = compiler.QuoteSeed;
pub const QuoteContext = compiler.Context;
pub const bodyQuoteCutSeedsWithContextAlloc = compiler.bodyQuoteCutSeedsWithContextAlloc;
pub const linkQuoteCutSeedsWithContextAlloc = compiler.linkQuoteCutSeedsWithContextAlloc;
pub const bodyQuoteCutSeedsAlloc = compiler.bodyQuoteCutSeedsAlloc;
pub const linkQuoteCutSeedsAlloc = compiler.linkQuoteCutSeedsAlloc;
pub const SourceFragment = struct {
    source: []const u8,
    pre: FragmentPreContext = .{},
};

pub const ObservedPreScope = struct {
    opening_start: usize,
    body_start: usize,
    body_end: usize,
    resume_at: usize,
    matched: bool,
    kind: FragmentPreContext.Kind = .pre,
    formatting: compiler.SpanFlags = .{},
    attributes: FormattingAttributes = .{},
    target: []const u8 = "",
    link_quotes: ?compiler.LinkQuoteObservation = null,
    parent: ?usize = null,
    depth: usize = 1,
};
pub const PreparedBodySource = struct {
    source: []const u8,
    fallbacks: Fallbacks,
};
pub fn prepareBodySourceAlloc(a: A, title: []const u8, source: []const u8) !PreparedBodySource {
    var renderer: compiler.Renderer = .{ .a = a, .context = .{ .title = title, .unclosed_fragment_trace = try unclosedFragmentTraceFromEnv() } };
    const prepared = try renderer.prepareBodySource(source);
    return .{ .source = prepared, .fallbacks = renderer.fallbacks };
}
pub const PreObservation = struct {
    scopes: []const ObservedPreScope,
    refused_link_openings: []const usize = &.{},
    unclosed_formatting: bool,
};
pub fn observePreScopesAlloc(a: A, title: []const u8, source: []const u8, link_trail: ir.LinkTrail, namespace_catalog: ?*const NamespaceRegistry, behavior_switches: ?*const BehaviorRegistry, image_options: ?*const ImageRegistry, reference_context: ReferenceDefinitions, poem_phase: ?*const PoemPhase) !PreObservation {
    const Collector = struct {
        a: A,
        source: []const u8,
        renderer: ?*const compiler.Renderer = null,
        scopes: std.ArrayList(ObservedPreScope) = .empty,
        refused_link_openings: std.ArrayList(usize) = .empty,
        fn enter(raw: ?*anyopaque, domain: []const u8, origin: ?usize, opening_start: usize, body_start: usize, body_end: usize, resume_at: usize, matched: bool, kind: FragmentPreContext.Kind, formatting: compiler.SpanFlags, target: []const u8, attributes: FormattingAttributes) compiler.Error!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const base = origin orelse return;
            if (base > self.source.len or domain.len > self.source.len - base or
                domain.ptr != self.source[base..].ptr)
                return error.InvalidPreContext;
            if (kind == .refused_link) {
                if (opening_start > domain.len or domain.len - opening_start < 2 or
                    domain[opening_start] != '[' or domain[opening_start + 1] != '[' or
                    body_start != opening_start or body_end != opening_start or resume_at != opening_start or
                    matched or target.len != 0 or !std.meta.eql(formatting, compiler.SpanFlags{}))
                    return error.InvalidPreContext;
                try self.refused_link_openings.append(self.a, base + opening_start);
                return;
            }
            if (opening_start >= body_start or body_start > body_end or body_end > resume_at or resume_at > domain.len)
                return error.InvalidPreContext;
            const absolute_open = base + opening_start;
            var parent: ?usize = if (self.scopes.items.len == 0) null else self.scopes.items.len - 1;
            if (parent) |previous| if (self.scopes.items[previous].opening_start >= absolute_open) return error.InvalidPreContext;
            while (parent) |index| {
                const candidate = self.scopes.items[index];
                if (absolute_open >= candidate.body_start and base + resume_at <= candidate.body_end) break;
                parent = candidate.parent;
            }
            const depth = if (parent) |index| self.scopes.items[index].depth + 1 else 1;
            // This event is emitted before descending into its body. Bound the
            // stored ancestry by the actual renderer call depth, whose entry
            // already enforces the renderer max_depth limit.
            if (depth > self.renderer.?.body_depth) return error.InvalidPreContext;
            const link_quotes = if (kind == .link)
                self.renderer.?.link_quote_observation orelse return error.InvalidPreContext
            else
                null;
            const owned_target = try self.a.dupe(u8, target);
            errdefer self.a.free(owned_target);
            const owned_classes = try self.a.dupe(u8, attributes.classes);
            errdefer self.a.free(owned_classes);
            const owned_language = try self.a.dupe(u8, attributes.language);
            errdefer self.a.free(owned_language);
            const owned_direction = try self.a.dupe(u8, attributes.direction);
            errdefer self.a.free(owned_direction);
            const owned_explanation = try self.a.dupe(u8, attributes.explanation);
            errdefer self.a.free(owned_explanation);
            try self.scopes.append(self.a, .{
                .opening_start = absolute_open,
                .body_start = base + body_start,
                .body_end = base + body_end,
                .resume_at = base + resume_at,
                .matched = matched,
                .kind = kind,
                .formatting = formatting,
                .attributes = .{ .classes = owned_classes, .role = attributes.role, .relation_note = attributes.relation_note, .language = owned_language, .direction = owned_direction, .explanation = owned_explanation, .explanation_set = attributes.explanation_set },
                .target = owned_target,
                .link_quotes = link_quotes,
                .parent = parent,
                .depth = depth,
            });
        }
    };
    var collected: Collector = .{ .a = a, .source = source };
    errdefer {
        for (collected.scopes.items) |scope| {
            a.free(scope.target);
            a.free(scope.attributes.classes);
            a.free(scope.attributes.language);
            a.free(scope.attributes.direction);
            a.free(scope.attributes.explanation);
        }
        collected.scopes.deinit(a);
        collected.refused_link_openings.deinit(a);
    }
    // The probe's blocks, spans, references and media never escape this arena.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var renderer: compiler.Renderer = .{
        .a = arena.allocator(),
        .context = .{
            .title = title,
            .unclosed_fragment_trace = try unclosedFragmentTraceFromEnv(),
            .language = "English",
            .link_trail = link_trail,
            .namespace_catalog = namespace_catalog,
            .behavior_switches = behavior_switches,
            .image_options = image_options,
            .poem_phase = poem_phase,
        },
    };
    renderer.page_reference_definitions = reference_context.items;
    collected.renderer = &renderer;
    _ = try renderer.renderBodyWithPreObserver(source, .{ .ctx = &collected, .enter = Collector.enter });
    // A truncated probe cannot establish a complete page scope map.
    if (renderer.truncated or renderer.fallbacks.render_limit) return error.RenderLimit;
    std.mem.sort(usize, collected.refused_link_openings.items, {}, std.sort.asc(usize));
    var unique: usize = 0;
    for (collected.refused_link_openings.items) |opening| {
        if (unique == 0 or collected.refused_link_openings.items[unique - 1] != opening) {
            collected.refused_link_openings.items[unique] = opening;
            unique += 1;
        }
    }
    collected.refused_link_openings.items = collected.refused_link_openings.items[0..unique];
    const refused_link_openings = try collected.refused_link_openings.toOwnedSlice(a);
    errdefer a.free(refused_link_openings);
    return .{ .scopes = try collected.scopes.toOwnedSlice(a), .refused_link_openings = refused_link_openings, .unclosed_formatting = renderer.fallbacks.unclosed_formatting };
}

pub fn parsePoemPhaseAlloc(a: A, full_output: []const u8, display_title: ?[]const u8, metadata: ?[]const u8) !?*const PoemPhase {
    return compiler.parsePoemPhaseAlloc(a, full_output, display_title, metadata);
}
pub const referenceDefinitionsAlloc = compiler.referenceDefinitionsAlloc;
pub const mayHaveMultilineLinks = compiler.mayHaveMultilineLinks;
pub const mayHaveFormattingScopes = compiler.mayHaveFormattingScopes;
pub const preparePageTocSourceAlloc = compiler.preparePageTocSourceAlloc;
pub const preparePageExternalLinksAlloc = compiler.preparePageExternalLinksAlloc;

fn requireCompiledText(text: []const u8) !void {
    for ([_][]const u8{ "[[", "]]", "{{", "}}", "{|", "|}" }) |token| {
        if (std.mem.indexOf(u8, text, token) != null) {
            return error.UncompiledPresentation;
        }
    }
    var at: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, at, '<')) |start| {
        var name = start + 1;
        if (name < text.len and text[name] == '/') name += 1;
        if (name < text.len and std.ascii.isAlphabetic(text[name]) and std.mem.indexOfScalarPos(u8, text, name, '>') != null) {
            return error.UncompiledPresentation;
        }
        at = start + 1;
    }
    at = 0;
    while (std.mem.indexOfScalarPos(u8, text, at, '[')) |start| {
        if (start + 1 < text.len and text[start + 1] != '[' and ir.hasExternalProtocol(text[start + 1 ..]))
            return error.UncompiledPresentation;
        at = start + 1;
    }
}

fn requireCompiledSpans(a: A, spans: []const compiler.Span) !void {
    try requireCompiledText(try compiler.plainText(a, spans));
}

fn validateText(text: []const u8, report: ?*Fallbacks) !void {
    requireCompiledText(text) catch |err| {
        if (report) |fallback| {
            fallback.literal_markup = true;
        } else return err;
    };
}

fn validateSpans(a: A, spans: []const compiler.Span, report: ?*Fallbacks) !void {
    if (report == null) for (spans) |span| {
        if (span.kind == .template) return error.UncompiledTemplate;
    };
    if (report) |fallback| {
        // A missing template is a normal red link in MediaWiki. Never serialize
        // its argument body as a custom template instruction.
        for (@constCast(spans)) |*span| if (span.kind == .template) {
            span.kind = .link;
            span.target = try std.fmt.allocPrint(a, "Template:{s}", .{span.target});
            span.text = span.target;
            fallback.missing_template = true;
        };
    }
    // Check after template presentation conversion as well as ordinary actions.
    // Action targets have no protected-literal exemption; code=true is not provenance.
    for (spans) |span| {
        if ((span.kind == .external_link or span.kind == .link) and compiler.unresolvedActionTarget(span.target))
            return error.UncompiledTemplate;
    }
    var parsed: std.ArrayList(u8) = .empty;
    defer parsed.deinit(a);
    for (spans) |span| {
        if (span.provenance != .parsed) {
            try validateText(parsed.items, report);
            parsed.clearRetainingCapacity();
        } else if (span.kind == .line_break) try parsed.append(a, '\n') else try parsed.appendSlice(a, span.text);
    }
    try validateText(parsed.items, report);
}

pub const DisplayTitle = struct {
    source: []const u8,
    page_title: []const u8,
};

const WorkSection = struct {
    title_spans: []const compiler.Span = &.{},
    level: u8,
    title: []const u8,
    blocks: []const compiler.Block,
};
const Work = struct {
    sections: []const WorkSection,
    references: []const compiler.Reference,
    media: []const compiler.media_types.Media,
    media_caption_spans: []const []const compiler.Span,
    rendered_templates: usize,
    unresolved_templates: usize,
    fallbacks: Fallbacks,
};
const Builder = struct {
    title_spans: []const compiler.Span = &.{},
    a: A,
    renderer: *compiler.Renderer,
    sections: std.ArrayList(WorkSection) = .empty,
    title: []const u8,
    level: u8 = 2,
    started: bool = false,

    fn flush(self: *Builder, blocks: []const compiler.Block) !void {
        if (!self.started) return;
        try self.sections.append(self.a, .{
            .level = self.level,
            .title = self.title,
            .title_spans = self.title_spans,
            .blocks = blocks,
        });
    }

    fn render(self: *Builder, source: []const u8) !void {
        try self.consume(try self.renderer.renderBody(source));
    }

    fn renderFragments(self: *Builder, fragments: []const SourceFragment) !void {
        var rendered: std.ArrayList(compiler.Block) = .empty;
        defer rendered.deinit(self.a);
        for (fragments) |fragment| {
            try rendered.appendSlice(self.a, try self.renderer.renderBodyWithFragmentPre(fragment.source, fragment.pre));
        }
        try self.consume(try rendered.toOwnedSlice(self.a));
    }

    fn consume(self: *Builder, rendered: []const compiler.Block) !void {
        var section_start: usize = 0;
        for (rendered, 0..) |item, i| {
            if (item.kind == .heading) {
                try self.flush(rendered[section_start..i]);
                self.started = true;
                self.title_spans = item.spans;
                self.title = trimHeading(try compiler.plainText(self.a, item.spans));
                self.level = item.level;
                section_start = i + 1;
            } else {
                self.started = true;
            }
        }
        try self.flush(rendered[section_start..]);
    }
};
fn workAlloc(a: A, title: []const u8, language: []const u8, source: []const u8, link_trail: ir.LinkTrail, namespace_catalog: ?*const NamespaceRegistry, behavior_switches: ?*const BehaviorRegistry, image_options: ?*const ImageRegistry, reference_context: compiler.ReferenceDefinitions) !Work {
    return workAllocWithPoem(a, title, language, source, link_trail, namespace_catalog, behavior_switches, image_options, reference_context, null);
}
fn workAllocWithPoem(a: A, title: []const u8, language: []const u8, source: []const u8, link_trail: ir.LinkTrail, namespace_catalog: ?*const NamespaceRegistry, behavior_switches: ?*const BehaviorRegistry, image_options: ?*const ImageRegistry, reference_context: compiler.ReferenceDefinitions, poem_phase: ?*const PoemPhase) !Work {
    return workAllocWithPoemFragments(a, title, language, source, link_trail, namespace_catalog, behavior_switches, image_options, reference_context, poem_phase, &.{});
}
fn workAllocWithPoemFragments(a: A, title: []const u8, language: []const u8, source: []const u8, link_trail: ir.LinkTrail, namespace_catalog: ?*const NamespaceRegistry, behavior_switches: ?*const BehaviorRegistry, image_options: ?*const ImageRegistry, reference_context: compiler.ReferenceDefinitions, poem_phase: ?*const PoemPhase, fragments: []const SourceFragment) !Work {
    var renderer: compiler.Renderer = .{
        .a = a,
        .context = .{
            .title = title,
            .unclosed_fragment_trace = try unclosedFragmentTraceFromEnv(),
            .language = if (language.len == 0) "English" else language,
            .link_trail = link_trail,
            .namespace_catalog = namespace_catalog,
            .behavior_switches = behavior_switches,
            .image_options = image_options,
            .poem_phase = poem_phase,
        },
    };
    renderer.page_reference_definitions = reference_context.items;
    renderer.fallbacks.merge(reference_context.fallbacks);
    var builder: Builder = .{
        .a = a,
        .renderer = &renderer,
        .title = if (language.len == 0) title else language,
    };
    if (fragments.len == 0) try builder.render(source) else try builder.renderFragments(fragments);
    return .{
        .sections = try builder.sections.toOwnedSlice(a),
        .references = try renderer.finishReferences(),
        .media = try renderer.media.toOwnedSlice(a),
        .media_caption_spans = try renderer.media_caption_spans.toOwnedSlice(a),
        .rendered_templates = renderer.rendered_templates,
        .unresolved_templates = renderer.unresolved_templates,
        .fallbacks = renderer.fallbacks,
    };
}

fn displayTitleSpansAlloc(a: A, display: ?DisplayTitle, language: []const u8, link_trail: ir.LinkTrail, namespace_catalog: ?*const NamespaceRegistry, behavior_switches: ?*const BehaviorRegistry, image_options: ?*const ImageRegistry, fallbacks: ?*Fallbacks, poem_phase: ?*const PoemPhase) ![]const compiler.Span {
    const value = display orelse return &.{};
    if (value.source.len == 0) return &.{};
    var renderer: compiler.Renderer = .{
        .a = a,
        .context = .{
            .title = value.page_title,
            .language = if (language.len == 0) "English" else language,
            .link_trail = link_trail,
            .namespace_catalog = namespace_catalog,
            .behavior_switches = behavior_switches,
            .image_options = image_options,
            .poem_phase = poem_phase,
        },
    };
    const spans = renderer.parseSpans(value.source, .{ .role = .headword }) catch |err| {
        if (fallbacks) |report| switch (err) {
            error.RenderLimit => {
                report.render_limit = true;
                report.display_title_rejected = true;
                return &.{};
            },
            else => return err,
        } else return err;
    };
    if (fallbacks) |report| report.merge(renderer.fallbacks);
    if (renderer.rendered_templates != 0 or renderer.unresolved_templates != 0) {
        if (fallbacks) |report| {
            report.template_presentation = report.template_presentation or renderer.rendered_templates != 0;
            report.missing_template = report.missing_template or renderer.unresolved_templates != 0;
            report.display_title_rejected = true;
            return &.{};
        }
        return error.UncompiledTemplate;
    }
    for (spans) |span| if (span.kind != .text) {
        if (fallbacks) |report| report.display_title_rejected = true;
        return &.{};
    };
    const plain = try compiler.plainText(a, spans);
    if (!std.mem.eql(u8, plain, value.page_title)) {
        if (fallbacks) |report| report.display_title_rejected = true;
        return &.{};
    }
    return spans;
}

pub fn compileAlloc(
    a: A,
    title: []const u8,
    kind: format.BlobKind,
    language: ?[]const u8,
    language_code: []const u8,
    source: []const u8,
    display_title: ?DisplayTitle,
) ![]u8 {
    return compileReportedAlloc(a, title, kind, language, language_code, source, display_title, null);
}

// Explicit publication policy: MediaWiki renders malformed delimiters as
// literal text. This path records that decision; strict compiler callers keep
// rejecting it. Neither path places an executable template in the blob.
pub fn compileReportedAlloc(
    a: A,
    title: []const u8,
    kind: format.BlobKind,
    language: ?[]const u8,
    language_code: []const u8,
    source: []const u8,
    display_title: ?DisplayTitle,
    fallbacks: ?*Fallbacks,
) ![]u8 {
    return compileReportedWithLinkTrailAlloc(
        a,
        title,
        kind,
        language,
        language_code,
        source,
        display_title,
        .{},
        null,
        fallbacks,
    );
}

pub fn compileReportedWithLinkTrailAlloc(
    a: A,
    title: []const u8,
    kind: format.BlobKind,
    language: ?[]const u8,
    language_code: []const u8,
    source: []const u8,
    display_title: ?DisplayTitle,
    link_trail: ir.LinkTrail,
    namespace_catalog: ?*const NamespaceRegistry,
    fallbacks: ?*Fallbacks,
) ![]u8 {
    return compileReportedWithBehaviorAlloc(a, title, kind, language, language_code, source, display_title, link_trail, namespace_catalog, null, fallbacks);
}

pub fn compileReportedWithBehaviorAlloc(
    a: A,
    title: []const u8,
    kind: format.BlobKind,
    language: ?[]const u8,
    language_code: []const u8,
    source: []const u8,
    display_title: ?DisplayTitle,
    link_trail: ir.LinkTrail,
    namespace_catalog: ?*const NamespaceRegistry,
    behavior_switches: ?*const BehaviorRegistry,
    fallbacks: ?*Fallbacks,
) ![]u8 {
    return compileReportedWithOptionsAlloc(a, title, kind, language, language_code, source, display_title, link_trail, namespace_catalog, behavior_switches, null, fallbacks);
}

pub fn compileReportedWithOptionsAlloc(
    a: A,
    title: []const u8,
    kind: format.BlobKind,
    language: ?[]const u8,
    language_code: []const u8,
    source: []const u8,
    display_title: ?DisplayTitle,
    link_trail: ir.LinkTrail,
    namespace_catalog: ?*const NamespaceRegistry,
    behavior_switches: ?*const BehaviorRegistry,
    image_options: ?*const ImageRegistry,
    fallbacks: ?*Fallbacks,
) ![]u8 {
    return compileReportedWithOptionsAndPoemAlloc(a, title, kind, language, language_code, source, display_title, link_trail, namespace_catalog, behavior_switches, image_options, fallbacks, null);
}

pub fn compileReportedWithOptionsAndPoemAlloc(
    a: A,
    title: []const u8,
    kind: format.BlobKind,
    language: ?[]const u8,
    language_code: []const u8,
    source: []const u8,
    display_title: ?DisplayTitle,
    link_trail: ir.LinkTrail,
    namespace_catalog: ?*const NamespaceRegistry,
    behavior_switches: ?*const BehaviorRegistry,
    image_options: ?*const ImageRegistry,
    fallbacks: ?*Fallbacks,
    poem_phase: ?*const PoemPhase,
) ![]u8 {
    return compileReportedWithReferencesAndPoemAlloc(a, title, kind, language, language_code, source, display_title, link_trail, namespace_catalog, behavior_switches, image_options, .{}, fallbacks, poem_phase);
}

pub fn compileReportedWithReferencesAlloc(
    a: A,
    title: []const u8,
    kind: format.BlobKind,
    language: ?[]const u8,
    language_code: []const u8,
    source: []const u8,
    display_title: ?DisplayTitle,
    link_trail: ir.LinkTrail,
    namespace_catalog: ?*const NamespaceRegistry,
    behavior_switches: ?*const BehaviorRegistry,
    image_options: ?*const ImageRegistry,
    reference_context: compiler.ReferenceDefinitions,
    fallbacks: ?*Fallbacks,
) ![]u8 {
    return compileReportedWithReferencesAndPoemAlloc(a, title, kind, language, language_code, source, display_title, link_trail, namespace_catalog, behavior_switches, image_options, reference_context, fallbacks, null);
}

pub fn compileReportedWithReferencesAndPoemAlloc(
    a: A,
    title: []const u8,
    kind: format.BlobKind,
    language: ?[]const u8,
    language_code: []const u8,
    source: []const u8,
    display_title: ?DisplayTitle,
    link_trail: ir.LinkTrail,
    namespace_catalog: ?*const NamespaceRegistry,
    behavior_switches: ?*const BehaviorRegistry,
    image_options: ?*const ImageRegistry,
    reference_context: compiler.ReferenceDefinitions,
    fallbacks: ?*Fallbacks,
    poem_phase: ?*const PoemPhase,
) ![]u8 {
    return compileReportedWithReferencesAndPoemFragmentsAlloc(a, title, kind, language, language_code, source, display_title, link_trail, namespace_catalog, behavior_switches, image_options, reference_context, fallbacks, poem_phase, &.{});
}
// Probe ordinary rendered work while authored heading provenance is available.
// An authored heading has title_spans; Builder's default language label does
// not. Serialization retains the title/level but drops that distinction.
pub fn hasBodyContentWithReferencesAndPoemFragmentsAlloc(
    a: A,
    title: []const u8,
    language: []const u8,
    source: []const u8,
    link_trail: ir.LinkTrail,
    namespace_catalog: ?*const NamespaceRegistry,
    behavior_switches: ?*const BehaviorRegistry,
    image_options: ?*const ImageRegistry,
    reference_context: compiler.ReferenceDefinitions,
    poem_phase: ?*const PoemPhase,
    fragments: []const SourceFragment,
) !bool {
    const work = try workAllocWithPoemFragments(a, title, language, source, link_trail, namespace_catalog, behavior_switches, image_options, reference_context, poem_phase, fragments);
    // A capped probe cannot prove absence. Retain its source so the ordinary
    // final compile preserves and reports the existing render-limit diagnostic.
    if (work.fallbacks.render_limit) return true;
    const Has = struct {
        fn spans(values: []const compiler.Span) bool {
            for (values) |span| if (std.mem.trim(u8, span.text, " \t\r\n").len != 0 or span.target.len != 0) return true;
            return false;
        }
    };
    if (work.media.len != 0) return true;
    for (work.references) |reference| if (Has.spans(reference.spans)) return true;
    for (work.sections) |section| {
        if (Has.spans(section.title_spans)) return true;
        for (section.blocks) |block| {
            if (Has.spans(block.spans) or block.feature != null or block.kind == .rule) return true;
            if (block.table) |table| {
                if (Has.spans(table.caption)) return true;
                for (table.rows) |row| for (row.cells) |cell| if (Has.spans(cell.spans)) return true;
            }
        }
    }
    return false;
}

pub fn compileReportedWithReferencesAndPoemFragmentsAlloc(
    a: A,
    title: []const u8,
    kind: format.BlobKind,
    language: ?[]const u8,
    language_code: []const u8,
    source: []const u8,
    display_title: ?DisplayTitle,
    link_trail: ir.LinkTrail,
    namespace_catalog: ?*const NamespaceRegistry,
    behavior_switches: ?*const BehaviorRegistry,
    image_options: ?*const ImageRegistry,
    reference_context: compiler.ReferenceDefinitions,
    fallbacks: ?*Fallbacks,
    poem_phase: ?*const PoemPhase,
    fragments: []const SourceFragment,
) ![]u8 {
    const work = try workAllocWithPoemFragments(a, title, language orelse "", source, link_trail, namespace_catalog, behavior_switches, image_options, reference_context, poem_phase, fragments);
    if (fallbacks) |report| {
        report.merge(work.fallbacks);
        report.template_presentation = report.template_presentation or work.rendered_templates != 0;
        report.missing_template = report.missing_template or work.unresolved_templates != 0;
    } else if (work.rendered_templates != 0 or work.unresolved_templates != 0) return error.UncompiledTemplate;
    const display_spans = try displayTitleSpansAlloc(a, display_title, language orelse "", link_trail, namespace_catalog, behavior_switches, image_options, fallbacks, poem_phase);
    try validateSpans(a, display_spans, fallbacks);
    for (@constCast(work.sections)) |*section| {
        if (section.title_spans.len != 0) {
            try validateSpans(a, section.title_spans, fallbacks);
            section.title = trimHeading(try compiler.plainText(a, section.title_spans));
        } else try validateText(section.title, fallbacks);
        for (section.blocks) |block| {
            try validateSpans(a, block.spans, fallbacks);
            if (block.table) |table| {
                try validateSpans(a, table.caption, fallbacks);
                for (table.rows) |row| for (row.cells) |cell| try validateSpans(a, cell.spans, fallbacks);
            }
        }
    }
    for (work.references) |reference| try validateSpans(a, reference.spans, fallbacks);
    for (work.media_caption_spans, 0..) |caption_spans, index| {
        try validateSpans(a, caption_spans, fallbacks);
        @constCast(work.media)[index].caption = try compiler.plainText(a, caption_spans);
    }
    // DPR2 section titles remain stable plain labels for TOC/folding. A linked
    // title also retains its final validated spans in the first ordinary heading
    // block. Readers may use this exact companion for their existing header and
    // consume it only when they actually render those spans there.
    for (@constCast(work.sections)) |*section| {
        if (section.title.len == 0) continue;
        var navigable = false;
        var explained = false;
        for (section.title_spans) |span| {
            explained = explained or span.explanation.len != 0;
            if ((span.kind == .link or span.kind == .external_link) and span.target.len != 0 and span.text.len != 0) {
                navigable = true;
            }
        }
        if (navigable or explained) {
            const blocks = try a.alloc(compiler.Block, section.blocks.len + 1);
            blocks[0] = .{ .kind = .heading, .spans = section.title_spans, .level = section.level };
            @memcpy(blocks[1..], section.blocks);
            section.blocks = blocks;
        }
    }
    // Build semantic layout only after recovery has normalized all build-only
    // template spans and inserted the addressable heading companion. Existing
    // block indices therefore refer to the final serialized array, including 0.
    const synthetic_unclassified = kind == .language and language_code.len == 0 and
        std.mem.eql(u8, language orelse "", "Unclassified");
    const layout = if (synthetic_unclassified)
        try semantic.buildUnclassified(a, work.sections)
    else
        try semantic.build(a, work.sections);
    return codec.encodeBuildAlloc(a, display_spans, work.sections, layout, work.references, work.media);
}

test "shipped presentation accepts protected literal examples as compiled data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { source: []const u8, visible: []const u8 }{
        .{ .source = "<nowiki>{{w:Missing|label}}</nowiki>", .visible = "{{w:Missing|label}}" },
        .{ .source = "<pre>[[raw link]]</pre>", .visible = "[[raw link]]" },
        .{ .source = "<nowiki><span>raw</span></nowiki>", .visible = "<span>raw</span>" },
        .{ .source = "&#91;&#91;Episode 4&#93;&#93;", .visible = "[[Episode 4]]" },
    };
    for (cases) |case| {
        const encoded = try compileAlloc(a, "entry", .language, "English", "en", case.source, null);
        const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
        var text: std.ArrayList(u8) = .empty;
        for (decoded.entry.sections[0].blocks[0].spans) |span| try text.appendSlice(a, span.text);
        try std.testing.expectEqualStrings(case.visible, text.items);
    }
}

test "reported publication audits malformed external link syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "==English==\n===Noun===\n# A [https://example.test broken link.\n";
    try std.testing.expectError(error.UncompiledPresentation, compileAlloc(a, "entry", .language, "English", "en", source, null));

    var report: Fallbacks = .{};
    _ = try compileReportedAlloc(a, "entry", .language, "English", "en", source, null, &report);
    try std.testing.expect(report.literal_markup);
}

test "builder sections borrow contiguous rendered block slices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const work = try workAlloc(a, "page", "English", "preamble\n===First===\n# one\n===Second===\n===Third===\n# three\n", .{}, null, null, null, .{});
    try std.testing.expectEqual(@as(usize, 4), work.sections.len);
    try std.testing.expectEqualStrings("English", work.sections[0].title);
    try std.testing.expectEqual(@as(usize, 1), work.sections[0].blocks.len);
    try std.testing.expectEqualStrings("First", work.sections[1].title);
    try std.testing.expectEqual(@as(usize, 1), work.sections[1].blocks.len);
    try std.testing.expectEqualStrings("Second", work.sections[2].title);
    try std.testing.expectEqual(@as(usize, 0), work.sections[2].blocks.len);
    try std.testing.expectEqualStrings("Third", work.sections[3].title);
    try std.testing.expectEqual(@as(usize, 1), work.sections[3].blocks.len);
}

test "compiled presentation contains no executable template syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "==English==\n===Noun===\n# A [[cat|feline]].\n";
    const bytes = try compileAlloc(a, "cat", .language, "English", "en", source, null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "{{") == null);
    const parsed = try codec.decodeAlloc(a, bytes, "cat", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualStrings(types.schema, parsed.schema);
    try std.testing.expectEqualStrings("cat", parsed.entry.title);
    try std.testing.expectEqual(types.BlockKind.definition, parsed.entry.sections[1].blocks[0].kind);

    var registry = try NamespaceRegistry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tafwiktionary\n# dump-date\t20261001\n# content-language\taf\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tdictionary_entries\n" ++
        "6\tLêer\tFile\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\tImage\n" ++
        "10\tSjabloon\tTemplate\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\n" ++
        "14\tKategorie\tCategory\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\n");
    defer registry.deinit();
    // Expanded forms of the actual AF pronunciation, noun and definition templates.
    const heading_source = "==Engels==\n" ++
        "===[[Lêer:Nuvola apps edu languages.svg|30px]] [[uitspraak|Uitspraak]]===\n" ++
        "=== [[Lêer:Open book 01.svg|35px]] [[selfstandige naamwoord|Selfstandige naamwoord]] ===\n" ++
        "====&nbsp;&nbsp;&nbsp;[[Lêer:Crystal Clear app kedit.svg|25px]] [[betekenis|Betekenisse]]====\n" ++
        "# (anatomie) [[rugmurg|Rugmurg]]\n" ++
        "===[[Lêer:Icon.svg|alt=Speech]]&nbsp;===\n" ++
        "===[[Lêer:Icon.svg|alt=Speech|Caption]]===\n" ++
        "===[[:Lêer:Icon.svg]]===\n" ++
        "[[Lêer:Body.jpg|20px]]\n" ++
        "===\u{4e20}===\n" ++
        "===\u{feff}Literal\u{feff}===\n";
    var report: Fallbacks = .{};
    const heading_bytes = try compileReportedWithLinkTrailAlloc(a, "spinal cord", .language, "Engels", "en", heading_source, null, .{}, &registry, &report);
    const heading_page = try codec.decodeAlloc(a, heading_bytes, "spinal cord", .language, .{ .code = "en", .heading = "Engels" });
    const expected_titles = [_][]const u8{ "Engels", "Uitspraak", "Selfstandige naamwoord", "Betekenisse", "Speech", "Caption", "Lêer:Icon.svg", "\u{4e20}", "\u{feff}Literal\u{feff}" };
    try std.testing.expectEqual(expected_titles.len, heading_page.entry.sections.len);
    for (expected_titles, heading_page.entry.sections) |expected, section| try std.testing.expectEqualStrings(expected, section.title);
    const RichHeading = struct {
        fn check(allocator: A, section: anytype, target: []const u8) !void {
            try std.testing.expectEqual(@as(usize, 2), section.blocks.len);
            const companion = section.blocks[0];
            try std.testing.expectEqual(types.BlockKind.heading, companion.kind);
            try std.testing.expectEqual(section.level, companion.level);
            var label: std.ArrayList(u8) = .empty;
            defer label.deinit(allocator);
            var links: usize = 0;
            for (companion.spans) |span| {
                try label.appendSlice(allocator, span.text);
                try label.appendSlice(allocator, span.trail);
                if (span.kind == .link) {
                    links += 1;
                    try std.testing.expectEqualStrings(target, span.target);
                    try std.testing.expectEqualStrings(section.title, span.text);
                    try std.testing.expectEqualStrings("", span.trail);
                } else {
                    try std.testing.expect(span.kind == .text);
                    try std.testing.expectEqualStrings("", span.target);
                    try std.testing.expectEqualStrings("", trimHeading(span.text));
                }
            }
            try std.testing.expectEqual(@as(usize, 1), links);
            try std.testing.expectEqualStrings(section.title, trimHeading(label.items));
        }
    };
    try std.testing.expectEqual(@as(u8, 4), heading_page.entry.sections[3].level);
    try RichHeading.check(a, heading_page.entry.sections[3], "betekenis");
    try std.testing.expectEqual(types.BlockKind.definition, heading_page.entry.sections[3].blocks[1].kind);
    try std.testing.expectEqualStrings("(anatomie) ", heading_page.entry.sections[3].blocks[1].spans[0].text);
    try std.testing.expectEqualStrings("Rugmurg", heading_page.entry.sections[3].blocks[1].spans[1].text);
    try std.testing.expectEqualStrings("rugmurg", heading_page.entry.sections[3].blocks[1].spans[1].target);
    try std.testing.expectEqual(@as(u8, 3), heading_page.entry.sections[6].level);
    try RichHeading.check(a, heading_page.entry.sections[6], "Lêer:Icon.svg");
    try std.testing.expectEqualStrings("Body.jpg", heading_page.entry.sections[6].blocks[1].spans[0].text);
    try std.testing.expectEqual(@as(usize, 1), heading_page.entry.media.len);
    try std.testing.expectEqualStrings("Body.jpg", heading_page.entry.media[0].file);
    try std.testing.expectEqualStrings("Body.jpg", heading_page.entry.media[0].caption);
    try std.testing.expect(!report.any());
}

test "edition link trail survives compiled presentation encoding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const trail: ir.LinkTrail = .{
        .contains_fn = struct {
            fn contains(_: ?*const anyopaque, cp: u21) bool {
                return cp == 'ы';
            }
        }.contains,
    };
    const source = "==English==\n===Noun===\n# [[кот]]ыZ\n";
    const bytes = try compileReportedWithLinkTrailAlloc(
        a,
        "entry",
        .language,
        "English",
        "en",
        source,
        null,
        trail,
        null,
        null,
    );
    const parsed = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    const spans = parsed.entry.sections[1].blocks[0].spans;
    var linked_trail = false;
    for (spans) |span| {
        if (std.mem.eql(u8, span.text, "ы")) {
            linked_trail = span.kind == .link and std.mem.eql(u8, span.target, "кот");
        }
    }
    try std.testing.expect(linked_trail);
}

test "display titles compile to semantic spans after page-title validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "==English==\n===Noun===\n# A word.\n";
    const bytes = try compileAlloc(a, "cat", .language, "English", "en", source, .{
        .source = "<span class=\"Latn headword\" lang=\"en\" dir=\"ltr\"><i>cat</i></span>",
        .page_title = "cat",
    });
    const parsed = try codec.decodeAlloc(a, bytes, "cat", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqual(@as(usize, 1), parsed.entry.display_title.len);
    try std.testing.expectEqualStrings("cat", parsed.entry.display_title[0].text);
    try std.testing.expect(parsed.entry.display_title[0].italic);
    try std.testing.expectEqualStrings("Latn headword", parsed.entry.display_title[0].classes);
    try std.testing.expectEqualStrings("en", parsed.entry.display_title[0].language);
    try std.testing.expectEqualStrings("ltr", parsed.entry.display_title[0].direction);
    try std.testing.expectEqual(types.Role.headword, parsed.entry.display_title[0].role);

    const ignored = try compileAlloc(a, "cat", .language, "English", "en", source, .{
        .source = "<b>dog</b>",
        .page_title = "cat",
    });
    const ignored_parsed = try codec.decodeAlloc(a, ignored, "cat", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqual(@as(usize, 0), ignored_parsed.entry.display_title.len);

    const linked = try compileAlloc(a, "cat", .language, "English", "en", source, .{
        .source = "[[cat]]",
        .page_title = "cat",
    });
    const linked_parsed = try codec.decodeAlloc(a, linked, "cat", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqual(@as(usize, 0), linked_parsed.entry.display_title.len);
}

test "reported display title rejection falls back to canonical title" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "==English==\n===Noun===\n# A word.\n";

    try std.testing.expectError(error.UncompiledTemplate, compileAlloc(a, "cat", .language, "English", "en", source, .{
        .source = "{{MissingDisplayTitle}}",
        .page_title = "cat",
    }));

    var report: Fallbacks = .{};
    const bytes = try compileReportedAlloc(a, "cat", .language, "English", "en", source, .{
        .source = "{{MissingDisplayTitle}}",
        .page_title = "cat",
    }, &report);
    try std.testing.expect(report.display_title_rejected);
    try std.testing.expect(report.missing_template);
    const parsed = try codec.decodeAlloc(a, bytes, "cat", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqual(@as(usize, 0), parsed.entry.display_title.len);

    var linked_report: Fallbacks = .{};
    const linked = try compileReportedAlloc(a, "cat", .language, "English", "en", source, .{
        .source = "[[cat]]",
        .page_title = "cat",
    }, &linked_report);
    try std.testing.expect(linked_report.display_title_rejected);
    const linked_parsed = try codec.decodeAlloc(a, linked, "cat", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqual(@as(usize, 0), linked_parsed.entry.display_title.len);
}

test "unknown templates are rejected at bundle time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "==English==\n===Noun===\n# {{definitely-unknown-template|x}}\n";
    try std.testing.expectError(error.UncompiledTemplate, compileAlloc(a, "cat", .language, "English", "en", source, null));
}

test "known presentation templates cannot bypass bundle expansion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "==English==\n===Noun===\n# {{lb|en|rare}} A [[cat]].\n";
    try std.testing.expectError(error.UncompiledTemplate, compileAlloc(a, "cat", .language, "English", "en", source, null));
}

test "partially renderable unsupported citation templates still fail publication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "==English==\n===Noun===\n# {{RQ:Unknown Work|page=17|passage=The '''[[cat]]''' sleeps.}}\n";
    try std.testing.expectError(error.UncompiledTemplate, compileAlloc(a, "cat", .language, "English", "en", source, null));
}

test "template parse limits fail publication instead of preserving executable syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var source: std.ArrayList(u8) = .empty;
    try source.appendSlice(a, "==English==\n===Noun===\n# {{oversized");
    for (0..16_385) |_| try source.appendSlice(a, "|x");
    try source.appendSlice(a, "}} tail\n");
    try std.testing.expectError(error.UncompiledTemplate, compileAlloc(a, "cat", .language, "English", "en", source.items, null));
}

test "reported recovery matches MediaWiki literal and formatting fixtures" {
    // Live oracle: tools/check_mediawiki_recovery.py and its fixture file.
    const cases = [_][2][]const u8{
        .{ "A [[-", "A [[-" },
        .{ "B ]]word]]", "B ]]word]]" },
        .{ "C <small>x<small> y", "C x y" },
        .{ "D [[]] E", "D [[]] E" },
        .{ "|}\nAfter", "|} After" },
        .{ "{|\n* [[one]]\n|}", "one" },
        .{ "X <script>y</script> Z", "X <script>y</script> Z" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var report: Fallbacks = .{};
        const bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", case[0], null, &report);
        const parsed = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
        var text: std.ArrayList(u8) = .empty;
        for (parsed.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            try text.appendSlice(a, span.text);
        };
        try std.testing.expectEqualStrings(case[1], text.items);
        try std.testing.expect(report.any());
    }
}

test "missing template recovery emits a data-only red link without argument source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: Fallbacks = .{};
    const bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", "{{MissingFixture|secret_argument_body}}", null, &report);
    try std.testing.expect(report.missing_template);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "secret_argument_body") == null);
    const parsed = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualStrings("Template:MissingFixture", parsed.entry.sections[0].blocks[0].spans[0].text);
}

test "localized behavior registry reaches compiled presentation roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const behavior = @import("namespace_registry").behavior_switches;
    const raw = behavior.header ++ "\n# wiki\tjawiktionary\n# dump-date\t20261001\n# content-language\tja\n# namespace-registry-sha256\t0000000000000000000000000000000000000000000000000000000000000000\nnotoc\t0\t＿＿目次非表示＿＿\n";
    var registry = try behavior.Registry.init(a, raw, "jawiktionary", "20261001", "ja", @splat(0));
    defer registry.deinit();
    const encoded = try compileReportedWithBehaviorAlloc(a, "entry", .language, "English", "en", "# a＿＿目次非表示＿＿b", null, .{}, null, &registry, null);
    const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
    var text: std.ArrayList(u8) = .empty;
    for (decoded.entry.sections[0].blocks[0].spans) |span| try text.appendSlice(a, span.text);
    try std.testing.expectEqualStrings("ab", text.items);
}

test "literal provenance never authorizes malformed parsed suffixes or split delimiters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.UncompiledPresentation, compileAlloc(a, "entry", .language, "English", "en", "<nowiki>{{example}}</nowiki> [[broken", null));
    const spans = [_]compiler.Span{ .{ .text = "{" }, .{ .text = "{uncompiled}}", .flags = .{ .bold = true } } };
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &spans, null));
    var report: Fallbacks = .{};
    _ = try compileReportedAlloc(a, "entry", .language, "English", "en", "<nowiki>{{example}}</nowiki> [[broken", null, &report);
    try std.testing.expect(report.literal_markup);
    try std.testing.expectError(error.UncompiledTemplate, compileAlloc(a, "entry", .language, "English", "en", "<code>{{missing}}</code>", null));
}

test "literal provenance survives headings references table cells and media captions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "==<nowiki>{{heading}}</nowiki>==\n# definition<ref><nowiki>{{reference}}</nowiki></ref>\n<table><tr><td><nowiki>{{cell}}</nowiki></td></tr></table>\n[[File:test.png|<nowiki>{{caption}}</nowiki>]]";
    const encoded = try compileAlloc(a, "entry", .language, "English", "en", source, null);
    const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualStrings("{{heading}}", decoded.entry.sections[0].title);
    try std.testing.expectEqualStrings("{{reference}}", decoded.entry.references[0].spans[0].text);
    try std.testing.expectEqualStrings("{{caption}}", decoded.entry.media[0].caption);
}

test "literal provenance preserves structural templates line breaks and normalized captions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const template_spans = try a.dupe(compiler.Span, &.{.{ .kind = .template, .target = "Missing", .text = "stale argument", .provenance = .protected_literal }});
    try std.testing.expectError(error.UncompiledTemplate, validateSpans(a, template_spans, null));
    var report: Fallbacks = .{};
    try validateSpans(a, template_spans, &report);
    try std.testing.expectEqual(ir.InlineKind.link, template_spans[0].kind);
    try std.testing.expectEqualStrings("Template:Missing", template_spans[0].text);
    try std.testing.expect(report.missing_template);
    const breaks = [_]compiler.Span{ .{ .text = "{" }, .{ .kind = .line_break, .text = "" }, .{ .text = "{example}" } };
    try validateSpans(a, &breaks, null);
    var renderer: compiler.Renderer = .{ .a = a, .context = .{} };
    const source = "[[File:test.png|a<br>b {{Missing}}]]";
    const label_spans = try renderer.parseSpans(source, .{});
    try std.testing.expectEqualStrings("a\nb [unavailable template: Missing]", try compiler.plainText(a, label_spans));
    var caption_report: Fallbacks = .{};
    const encoded = try compileReportedAlloc(a, "entry", .language, "English", "en", source, null, &caption_report);
    const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualStrings("a\nb Template:Missing", decoded.entry.media[0].caption);
    try std.testing.expect(caption_report.missing_template);
}

test "localized image options reach serialized media captions without swallowing case-sensitive text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const images = @import("namespace_registry").image_options;
    const raw = images.header ++ "\n# wiki\tdewiktionary\n# dump-date\t20261001\n# content-language\tde\n# namespace-registry-sha256\t0000000000000000000000000000000000000000000000000000000000000000\n# behavior-switches-sha256\t1111111111111111111111111111111111111111111111111111111111111111\nimg_right\t1\t\"rechts\"\nimg_thumbnail\t1\t\"miniatur\"\nimg_thumbnail\t1\t\"thumb\"\nimg_alt\t1\t\"alternativtext=$1\"\nimg_width\t1\t\"$1px\"\n";
    var registry = try images.Registry.init(a, raw, "dewiktionary", "20261001", "de", @splat(0), @splat(0x11));
    defer registry.deinit();
    const cases = [_]struct { source: []const u8, caption: []const u8 }{
        .{ .source = "[[File:Example.jpg|miniatur|CaptionProbeAlpha|rechts]]", .caption = "CaptionProbeAlpha" },
        .{ .source = "[[File:Example.jpg|miniatur|CaptionProbeBeta|alternativtext=OnlyAltProbe]]", .caption = "CaptionProbeBeta" },
        .{ .source = "[[File:Example.jpg|thumb|THUMB]]", .caption = "THUMB" },
        .{ .source = "[[File:Example.jpg|caption|0px]]", .caption = "0px" },
    };
    for (cases) |case| {
        const encoded = try compileReportedWithOptionsAlloc(a, "entry", .language, "English", "en", case.source, null, .{}, null, null, &registry, null);
        const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
        try std.testing.expectEqual(@as(usize, 1), decoded.entry.media.len);
        try std.testing.expectEqualStrings(case.caption, decoded.entry.media[0].caption);
    }
}

test "image link options retain independent click action and media identity through DPR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { source: []const u8, kind: types.InlineKind, target: []const u8 }{
        .{ .source = "[[File:Example.png|''caption'']]", .kind = .link, .target = "File:Example.png" },
        .{ .source = "[[File:Example.png|link=|''caption'']]", .kind = .text, .target = "" },
        .{ .source = "[[File:Example.png|link=Target_page|''caption'']]", .kind = .link, .target = "Target page" },
        .{ .source = "[[File:Example.png|link=https://example.test/p?a=1&amp;b=2|''caption'']]", .kind = .external_link, .target = "https://example.test/p?a=1&b=2" },
        .{ .source = "[[File:Example.png|link=#Section|''caption'']]", .kind = .link, .target = "#Section" },
        .{ .source = "[[File:Example.png|link=[[Target]]|''caption'']]", .kind = .link, .target = "Target" },
        .{ .source = "[[File:Example.png|link=[[Target|Label]]|''caption'']]", .kind = .link, .target = "Label" },
        .{ .source = "[[File:Example.png|link=[[entry|Self label]]|''caption'']]", .kind = .link, .target = "Self label" },
        .{ .source = "[[File:Example.png|link=[[Target|<b>Label</b>]]|''caption'']]", .kind = .link, .target = "Label" },
        .{ .source = "[[File:Example.png|link=<b>Target</b>|''caption'']]", .kind = .link, .target = "Target" },
        .{ .source = "[[File:Example.png|link=<b></b>|''caption'']]", .kind = .text, .target = "" },
        .{ .source = "[[File:Example.png|link=<nowiki>[[Target]]</nowiki>|''caption'']]", .kind = .link, .target = "File:Example.png" },
        .{ .source = "[[File:Example.png|link=<b>A&amp;amp;B</b>|''caption'']]", .kind = .link, .target = "A&amp;B" },
        .{ .source = "[[File:Example.png|link=<b>https://example.test/?a=1&amp;amp;b=2</b>|''caption'']]", .kind = .external_link, .target = "https://example.test/?a=1&amp;b=2" },
        .{ .source = "[[File:Example.png|link=Target%20page|''caption'']]", .kind = .link, .target = "Target page" },
        .{ .source = "[[File:Example.png|link=https://example.test/Target%20page|''caption'']]", .kind = .external_link, .target = "https://example.test/Target%20page" },
        .{ .source = "<gallery>\nFile:Example.png|link=Target|''caption''\n</gallery>", .kind = .link, .target = "Target" },
        .{ .source = "==[[File:Example.png|link=Target|''caption'']]==", .kind = .link, .target = "Target" },
    };
    for (cases) |case| {
        const encoded = try compileAlloc(a, "entry", .language, "English", "en", case.source, null);
        const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
        try std.testing.expectEqual(@as(usize, 1), decoded.entry.media.len);
        try std.testing.expectEqualStrings("Example.png", decoded.entry.media[0].file);
        try std.testing.expectEqualStrings("caption", decoded.entry.media[0].caption);
        var found: usize = 0;
        for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            if (std.mem.eql(u8, span.text, "caption")) {
                try std.testing.expectEqual(case.kind, span.kind);
                try std.testing.expectEqualStrings(case.target, span.target);
                try std.testing.expect(span.italic);
                try std.testing.expect(std.mem.indexOf(u8, span.classes, "wikidict-media-file-") != null);
                found += 1;
            }
        };
        try std.testing.expect(found != 0);
    }
    // Caption-owned links remain their own actions even when the image is not linked.
    const nested = try compileAlloc(a, "entry", .language, "English", "en", "[[File:Example.png|link=|''caption'' and [[Other|nested]]]]", null);
    const decoded = try codec.decodeAlloc(a, nested, "entry", .language, .{ .code = "en", .heading = "English" });
    var caption = false;
    var own_link = false;
    for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        if (std.mem.eql(u8, span.text, "caption")) caption = span.kind == .text and span.target.len == 0 and span.italic;
        if (std.mem.eql(u8, span.text, "nested")) own_link = span.kind == .link and std.mem.eql(u8, span.target, "Other");
    };
    try std.testing.expect(caption and own_link);
    try std.testing.expectEqualStrings("Example.png", decoded.entry.media[0].file);
    try std.testing.expectEqualStrings("caption and nested", decoded.entry.media[0].caption);
}

test "image link option aliases and exact equals spelling use captured matcher" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const images = @import("namespace_registry").image_options;
    const raw = images.header ++ "\n# wiki\tdewiktionary\n# dump-date\t20261001\n# content-language\tde\n# namespace-registry-sha256\t0000000000000000000000000000000000000000000000000000000000000000\n# behavior-switches-sha256\t1111111111111111111111111111111111111111111111111111111111111111\nimg_link\t1\t\"verknüpfung=$1\"\nimg_link\t1\t\"link=$1\"\n";
    var registry = try images.Registry.init(a, raw, "dewiktionary", "20261001", "de", @splat(0), @splat(0x11));
    defer registry.deinit();
    const cases = [_]struct { source: []const u8, text: []const u8, target: []const u8 }{
        .{ .source = "[[File:Example.png|verknüpfung=Target|caption]]", .text = "caption", .target = "Target" },
        .{ .source = "[[File:Example.png|verknüpfung=|caption]]", .text = "caption", .target = "" },
        .{ .source = "[[File:Example.png|link =Target]]", .text = "link =Target", .target = "File:Example.png" },
    };
    for (cases) |case| {
        const encoded = try compileReportedWithOptionsAlloc(a, "entry", .language, "English", "en", case.source, null, .{}, null, null, &registry, null);
        const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
        var found = false;
        for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            if (std.mem.eql(u8, span.text, case.text)) {
                try std.testing.expectEqualStrings(case.target, span.target);
                try std.testing.expectEqual(if (case.target.len == 0) types.InlineKind.text else types.InlineKind.link, span.kind);
                found = true;
            }
        };
        try std.testing.expect(found);
        try std.testing.expectEqualStrings("Example.png", decoded.entry.media[0].file);
        try std.testing.expectEqualStrings(case.text, decoded.entry.media[0].caption);
    }
}

test "raw tag termination preserves semantic heading and protected literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Exact Plantía:-de- revision 309509 markup; source-instantiated, not
    // captured whole-page expansion. Live action=parse normalizes this tag.
    const markup = "<span style=\"color:#6b5a40;\"\">'''Alemán'''</span>";
    const work = try workAlloc(a, "asturisch", "alemán", "=" ++ markup ++ "=\n# [[asturianu|Asturianu]], d'[[Asturies]].\n", .{}, null, null, null, .{});
    try std.testing.expectEqual(@as(usize, 1), work.sections.len);
    try std.testing.expectEqualStrings("Alemán", work.sections[0].title);
    try std.testing.expectEqual(@as(u8, 1), work.sections[0].level);
    try std.testing.expect(work.sections[0].title_spans[0].flags.bold);
    try std.testing.expectEqualStrings("Asturianu, d'Asturies.", try compiler.plainText(a, work.sections[0].blocks[0].spans));
    var asturianu_links: usize = 0;
    var asturies_links: usize = 0;
    for (work.sections[0].blocks[0].spans) |span| {
        if (std.mem.eql(u8, span.target, "asturianu")) asturianu_links += 1;
        if (std.mem.eql(u8, span.target, "Asturies")) asturies_links += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), asturianu_links);
    try std.testing.expectEqual(@as(usize, 1), asturies_links);
    const protected = try workAlloc(a, "page", "alemán", "=<nowiki>" ++ markup ++ "</nowiki>=\n# retained\n", .{}, null, null, null, .{});
    try std.testing.expectEqualStrings(markup, protected.sections[0].title);
    const unclosed = try workAlloc(a, "page", "alemán", "=<span title=\"unterminated>Alemán=\n# retained\n", .{}, null, null, null, .{});
    try std.testing.expectEqualStrings("Alemán", unclosed.sections[0].title);
}

test "ruby strict compiled record preserves readable annotation and existing typed spans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "==Japanese==\n===Usage===\n" ++
        "日とは<ruby>実<rt>じつ</rt></ruby>である\n\n" ++
        "七月に<ruby>心宿<rt>なかごぼし</rt></ruby>が天頂を過ぎ\n\n" ++
        "月光を<ruby lang='ja'>[[看]]<rt>''[[み]]''</rt></ruby>る\n\n" ++
        "<ruby>字<rp>[</rp><rt>じ</rt><rp>]</rp></ruby>\n\n" ++
        "<nowiki><ruby>保護<rt>ほご</rt></ruby></nowiki>\n";
    const bytes = try compileAlloc(a, "Ruby source excerpts", .language, "Japanese", "ja", source, null);
    const parsed = try codec.decodeAlloc(a, bytes, "Ruby source excerpts", .language, .{ .code = "ja", .heading = "Japanese" });
    try std.testing.expectEqualStrings(types.schema, parsed.schema);
    var text: std.ArrayList(u8) = .empty;
    var reading_link = false;
    for (parsed.entry.sections) |section| for (section.blocks) |block| {
        for (block.spans) |span| {
            try text.appendSlice(a, span.text);
            if (std.mem.eql(u8, span.text, "み")) reading_link = span.kind == .link and std.mem.eql(u8, span.target, "み") and span.italic and std.mem.eql(u8, span.language, "ja");
        }
        try text.append(a, '\n');
    };
    for ([_][]const u8{ "日とは実（じつ）である", "七月に心宿（なかごぼし）が天頂を過ぎ", "月光を看（み）る", "字[じ]", "<ruby>保護<rt>ほご</rt></ruby>" }) |expected|
        try std.testing.expect(std.mem.indexOf(u8, text.items, expected) != null);
    try std.testing.expect(reading_link);
}

test "AM source malformed style preserves both pronunciations and typed hiragana through codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Exact revision 21290 style bytes; source-instantiated expanded list.
    const source = "==ጃፓንኛ==\n" ++
        "* [[IPA]]:[b<big style=\"color: #00008B;”>ɯ̟̃m</big>pʲit͡sɯ̟]\n**[[ሂራጋና]]፡[[ぶんぴつ]]\n" ++
        "* [[IPA]]:<small>(''[[casual]]'')</small>[b<big style=\"color: #00008B;”>ɯ̟̃m</big>pʲi]\n**[[ሂራጋና]]፡[[ぶんぴ]]\n" ++
        "===ስም===\n#[[እዠት]]\n";
    const bytes = try compileAlloc(a, "分泌", .language, "ጃፓንኛ", "ja", source, null);
    const decoded = try codec.decodeAlloc(a, bytes, "分泌", .language, .{ .code = "ja", .heading = "ጃፓንኛ" });
    var text: std.ArrayList(u8) = .empty;
    var first_reading: usize = 0;
    var second_reading: usize = 0;
    var casual: usize = 0;
    var definition: usize = 0;
    for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        try text.appendSlice(a, span.text);
        if (std.mem.eql(u8, span.target, "ぶんぴつ")) first_reading += 1;
        if (std.mem.eql(u8, span.target, "ぶんぴ")) second_reading += 1;
        if (std.mem.eql(u8, span.target, "casual")) casual += 1;
        if (std.mem.eql(u8, span.target, "እዠት")) {
            definition += 1;
            try std.testing.expect(block.kind == .definition);
        }
    };
    try std.testing.expect(std.mem.indexOf(u8, text.items, "pʲit͡sɯ̟]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "pʲi]") != null);
    try std.testing.expectEqual(@as(usize, 1), first_reading);
    try std.testing.expectEqual(@as(usize, 1), second_reading);
    try std.testing.expectEqual(@as(usize, 1), casual);
    try std.testing.expectEqual(@as(usize, 1), definition);
    const literal = "<big style=\"color: #00008B;”>protected</big>";
    const protected = try workAlloc(a, "literal", "ጃፓንኛ", "<nowiki>" ++ literal ++ "</nowiki>", .{}, null, null, null, .{});
    try std.testing.expectEqualStrings(literal, try compiler.plainText(a, protected.sections[0].blocks[0].spans));
}

test "external HTML-label boundary compiles the Arabic Navbar witness as data-only links" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Exact literal span in closed AR228 حُرّ, emitted by Navbar rev1008819.
    const target = "//en.wiktionary.org/w/index.php?title=%D9%82%D8%A7%D9%84%D8%A8:%D8%AD_%D8%B1_%D8%B1&action=edit";
    const witness = "[" ++ target ++ "<abbr title=\"عدل هذا القالب\">ت</abbr>]";
    for ([_][]const u8{ witness, "{|\n| " ++ witness ++ "\n|}\n" }) |source| {
        var report: Fallbacks = .{};
        const bytes = try compileReportedAlloc(a, "حُرّ", .language, "Unclassified", "", source, null, &report);
        const decoded = try codec.decodeAlloc(a, bytes, "حُرّ", .language, .{ .code = "", .heading = "Unclassified" });
        const block = decoded.entry.sections[0].blocks[0];
        const spans = if (block.table) |table| table.rows[0].cells[0].spans else block.spans;
        try std.testing.expectEqual(@as(usize, 1), spans.len);
        try std.testing.expectEqual(types.InlineKind.external_link, spans[0].kind);
        try std.testing.expectEqualStrings(target, spans[0].target);
        try std.testing.expectEqualStrings("ت", spans[0].text);
        try std.testing.expect(!report.any());
    }
    const protected_source = "<nowiki>" ++ witness ++ "</nowiki>";
    var protected_report: Fallbacks = .{};
    const protected_bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", protected_source, null, &protected_report);
    const protected = try codec.decodeAlloc(a, protected_bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    var protected_text: std.ArrayList(u8) = .empty;
    for (protected.entry.sections[0].blocks[0].spans) |span| {
        try std.testing.expect(span.kind != .external_link);
        try protected_text.appendSlice(a, span.text);
    }
    try std.testing.expectEqualStrings(witness, protected_text.items);
    try std.testing.expect(!protected_report.any());
    const attribute_source = "<span title=\"[https://example.test/x<abbr>hidden</abbr>]\">visible</span>";
    var attribute_report: Fallbacks = .{};
    const attribute_bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", attribute_source, null, &attribute_report);
    const attribute = try codec.decodeAlloc(a, attribute_bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    const spans = attribute.entry.sections[0].blocks[0].spans;
    // Adjacent plain-text chunks may differ across scanner entry paths. Preserve
    // the exact visible prefix/link/suffix boundary and navigation instead.
    var attribute_prefix: std.ArrayList(u8) = .empty;
    var attribute_suffix: std.ArrayList(u8) = .empty;
    var attribute_links: usize = 0;
    for (spans) |span| {
        try std.testing.expectEqualStrings("", span.trail);
        if (span.kind == .external_link) {
            try std.testing.expectEqual(@as(usize, 0), attribute_links);
            try std.testing.expectEqualStrings("https://example.test/x", span.target);
            try std.testing.expectEqualStrings("hidden", span.text);
            attribute_links += 1;
        } else {
            try std.testing.expectEqual(types.InlineKind.text, span.kind);
            if (attribute_links == 0) {
                try attribute_prefix.appendSlice(a, span.text);
            } else {
                try attribute_suffix.appendSlice(a, span.text);
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 1), attribute_links);
    try std.testing.expectEqualStrings("<span title=\"", attribute_prefix.items);
    try std.testing.expectEqualStrings("\">visible", attribute_suffix.items);
    try std.testing.expectEqualDeep(Fallbacks{ .literal_markup = true }, attribute_report);
}

test "page-body repeated TOC navigation survives ordinary DPR2 round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "__TOC__\n===Noun===\n# ISBN 97803__TOC__06406157\n";
    const encoded = try compileAlloc(a, "entry", .language, "English", "en", source, null);
    const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
    var links: usize = 0;
    for (decoded.entry.sections) |section| for (section.blocks) |block_value| for (block_value.spans) |span| {
        if (span.kind == .link and std.mem.eql(u8, span.target, "Special:BookSources/9780306406157")) links += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), links);
}

test "page-body unmatched pre TOC navigation survives ordinary DPR2 round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "__TOC__\n<pre><nowiki>__TOC__ [[hidden]]</nowiki> ISBN 97803__TOC__06406157";
    var report: Fallbacks = .{};
    const encoded = try compileReportedAlloc(a, "entry", .language, "English", "en", source, null, &report);
    const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
    var links: usize = 0;
    var visible: std.ArrayList(u8) = .empty;
    for (decoded.entry.sections) |section| for (section.blocks) |block_value| for (block_value.spans) |span| {
        try visible.appendSlice(a, span.text);
        if (span.kind == .link and std.mem.eql(u8, span.target, "Special:BookSources/9780306406157")) links += 1;
        try std.testing.expect(!(span.kind == .link and std.mem.eql(u8, span.target, "hidden")));
    };
    try std.testing.expectEqual(@as(usize, 1), links);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "__TOC__ [[hidden]]") != null);
    try std.testing.expect(report.unclosed_formatting);
}

test "post-expansion generated-comment fixture preserves control semantics and ISBN through DPR2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Exact normalized fixture asserted by the real native AOT invoke test.
    // This boundary consumes expanded source; it must not re-expand raw Lua output.
    const normalized = "Authored A__NOEDITSECTION__B\n\nGenerated A__NOEDITSECTION__B\nISBN 9780306406157\n__TOC__\nISBN 97803__TOC__06406157\nTail\n&lt;nowiki>__NOEDITSECTION__[[B]]</nowiki>\nAB\n\n<nowiki>__NOEDIT<!--literal-->SECTION__ ISBN 97803<!--literal-->06406157</nowiki>\n\n<pre>__NOEDIT<!--literal-->SECTION__ ISBN 97803<!--literal-->06406157</pre>\n\n<source>__NOEDIT<!--literal-->SECTION__ ISBN 97803<!--literal-->06406157</source>\n\n<syntaxhighlight>__NOEDIT<!--literal-->SECTION__ ISBN 97803<!--literal-->06406157</syntaxhighlight>\n\n<code>Ordinary AB __NOEDITSECTION__</code>\n\n&#95;&#95;NOEDITSECTION__\n\nUnclosed &lt;!--tail __NOEDITSECTION__ [[B]] ISBN 9780306406157";
    var report: Fallbacks = .{};
    // Production retains intentional visible markup with an explicit diagnostic.
    // The unmatched closing nowiki spelling must not weaken strict validation.
    const encoded = try compileReportedAlloc(a, "entry", .language, "English", "en", normalized, null, &report);
    try std.testing.expect(report.literal_markup);
    const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
    var visible: std.ArrayList(u8) = .empty;
    var isbn_links: usize = 0;
    for (decoded.entry.sections) |section| for (section.blocks) |block_value| for (block_value.spans) |span| {
        try visible.appendSlice(a, span.text);
        if (span.kind == .link and std.mem.eql(u8, span.target, "Special:BookSources/9780306406157")) isbn_links += 1;
    };
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "Authored AB") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "Generated AB") != null);
    try std.testing.expectEqual(@as(usize, 3), isbn_links);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, visible.items, "__NOEDIT<!--literal-->SECTION__"));
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "<nowiki>") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "</nowiki>") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "Unclosed <!--tail ") != null);
    var b_links: usize = 0;
    for (decoded.entry.sections) |section| for (section.blocks) |block_value| for (block_value.spans) |span| {
        if (span.kind == .link and std.mem.eql(u8, span.target, "B")) b_links += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), b_links);
    // Only the entity-authored spelling remains a visible complete control.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, visible.items, "__NOEDITSECTION__"));
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "Ordinary AB") != null);
}

test "poem lines metadata and protected strip breaks survive ordinary DPR2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "<poem>\n::[[cat]]\n\n<nowiki>A\n::[[B]]</nowiki>\n</poem>";
    var report: Fallbacks = .{};
    const bytes = try compileReportedAlloc(a, "Poem", .language, "English", "en", source, null, &report);
    const decoded = try codec.decodeAlloc(a, bytes, "Poem", .language, .{ .code = "en", .heading = "English" });
    errdefer {
        std.debug.print("\nPoem DPR2 lines fallbacks={any}\n", .{report});
        for (decoded.entry.sections, 0..) |section, section_i| for (section.blocks, 0..) |block, block_i| {
            std.debug.print("block[{d},{d}] kind={s}\n", .{ section_i, block_i, @tagName(block.kind) });
            for (block.spans, 0..) |span, span_i| std.debug.print("span[{d}] kind={s} text={s} target={s} classes={s} direction={s}\n", .{ span_i, @tagName(span.kind), span.text, span.target, span.classes, span.direction });
        };
        for (decoded.entry.references) |ref| {
            std.debug.print("reference name={s} group={s}\n", .{ ref.name, ref.group });
            for (ref.spans) |span| std.debug.print("reference span kind={s} text={s} target={s} classes={s}\n", .{ @tagName(span.kind), span.text, span.target, span.classes });
        }
        for (decoded.entry.media) |media| std.debug.print("media file={s} caption={s}\n", .{ media.file, media.caption });
    }
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x7fWDPOEM:") == null);
    var visible: std.ArrayList(u8) = .empty;
    var cat = false;
    var breaks: usize = 0;
    for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        try visible.appendSlice(a, span.text);
        if (span.kind == .line_break and std.mem.indexOf(u8, span.classes, "wikidict-poem") != null) breaks += 1;
        if (span.kind == .link and std.mem.eql(u8, span.target, "cat")) {
            cat = true;
            try std.testing.expect(std.mem.indexOf(u8, span.classes, "wikidict-poem-indent-2") != null);
        }
        try std.testing.expect(!(span.kind == .link and std.mem.eql(u8, span.target, "B")));
    };
    try std.testing.expect(cat);
    try std.testing.expect(breaks >= 3);
    // The raw colon regex wraps the line including </nowiki>; its generated
    // closing span lies after nowiki and is parsed, never protected literal text.
    try std.testing.expectEqualStrings("cat\n\nA\n<span class=\"mw-poem-indented\" style=\"display: inline-block; margin-inline-start: 2em;\">[[B]]", visible.items);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "wikidict-poem") == null);
}

test "poem strip items cannot ship in reference identities or media metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The raw handler inserts owned strip items even inside attributes and a
    // file link. Identity that cannot remain faithful is diagnosed, not guessed.
    const source = "<poem>start\n<ref name=\"named\nkey\" group=\"group\nkey\">note\n::[[B]]</ref>\n[[File:Tone.ogg|thumb|first\nsecond]]\n[[File:Plain.ogg|hidden timed caption]]\n[[File:bad\nname.ogg|readable caption]]</poem>";
    var report: Fallbacks = .{};
    const encoded = try compileReportedAlloc(a, "Poem metadata", .language, "English", "en", source, null, &report);
    const decoded = try codec.decodeAlloc(a, encoded, "Poem metadata", .language, .{ .code = "en", .heading = "English" });
    errdefer {
        std.debug.print("\nPoem DPR2 non-span fallbacks={any}\n", .{report});
        for (decoded.entry.sections, 0..) |section, section_i| for (section.blocks, 0..) |block, block_i| {
            std.debug.print("block[{d},{d}] kind={s}\n", .{ section_i, block_i, @tagName(block.kind) });
            for (block.spans, 0..) |span, span_i| std.debug.print("span[{d}] kind={s} text={s} target={s} classes={s} direction={s}\n", .{ span_i, @tagName(span.kind), span.text, span.target, span.classes, span.direction });
        };
        for (decoded.entry.references) |ref| {
            std.debug.print("reference name={s} group={s}\n", .{ ref.name, ref.group });
            for (ref.spans) |span| std.debug.print("reference span kind={s} text={s} target={s} classes={s}\n", .{ @tagName(span.kind), span.text, span.target, span.classes });
        }
        for (decoded.entry.media) |media| std.debug.print("media file={s} caption={s}\n", .{ media.file, media.caption });
    }
    try std.testing.expect(report.unsupported_element);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\x7fWDPOEM:") == null);
    try std.testing.expectEqual(@as(usize, 1), decoded.entry.references.len);
    const ref = decoded.entry.references[0];
    try std.testing.expect(std.mem.indexOf(u8, ref.name, "\x7fWDPOEM:") == null);
    try std.testing.expect(std.mem.indexOf(u8, ref.group, "\x7fWDPOEM:") == null);
    try std.testing.expect(std.mem.indexOf(u8, ref.name, "named") != null);
    try std.testing.expect(std.mem.indexOf(u8, ref.group, "group") != null);
    var note: std.ArrayList(u8) = .empty;
    var linked_b = false;
    for (ref.spans) |span| {
        try note.appendSlice(a, span.text);
        linked_b = linked_b or (span.kind == .link and std.mem.eql(u8, span.target, "B"));
        try std.testing.expect(std.mem.indexOf(u8, span.text, "\x7fWDPOEM:") == null);
        try std.testing.expect(std.mem.indexOf(u8, span.target, "\x7fWDPOEM:") == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, note.items, "note") != null);
    try std.testing.expect(linked_b);
    var tone = false;
    var unframed = false;
    for (decoded.entry.media) |media| {
        try std.testing.expect(std.mem.indexOf(u8, media.file, "\x7fWDPOEM:") == null);
        try std.testing.expect(std.mem.indexOf(u8, media.caption, "\x7fWDPOEM:") == null);
        try std.testing.expect(!std.mem.startsWith(u8, media.file, "bad"));
        if (std.mem.eql(u8, media.file, "Tone.ogg")) {
            tone = true;
            try std.testing.expectEqualStrings("first\nsecond", media.caption);
        }
        if (std.mem.eql(u8, media.file, "Plain.ogg")) {
            unframed = true;
            try std.testing.expectEqualStrings("Plain.ogg", media.caption);
        }
    }
    try std.testing.expect(tone and unframed);
    var visible: std.ArrayList(u8) = .empty;
    for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| try visible.appendSlice(a, span.text);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "readable caption") != null);
}

test "linked section heading companions retain labels and final organization indices through DPR2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "=== [[NounTargetA|Noun]] ===\n# first definition\n#: first example\n=== [[NounTargetB|Noun]] ===\n# second definition\n#: second example\n";
    const encoded = try compileAlloc(a, "entry", .language, "English", "en", source, null);
    const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqual(@as(usize, 2), decoded.entry.sections.len);
    try std.testing.expectEqual(@as(usize, 2), decoded.entry.organization.lexemes.len);
    for (decoded.entry.sections, decoded.entry.organization.lexemes, [_][]const u8{ "NounTargetA", "NounTargetB" }, 0..) |section, lexeme, target, i| {
        try std.testing.expectEqualStrings("Noun", section.title);
        try std.testing.expectEqual(@as(u8, 3), section.level);
        try std.testing.expectEqual(@as(usize, 3), section.blocks.len);
        const heading = section.blocks[0];
        try std.testing.expect(heading.kind == .heading);
        try std.testing.expectEqual(section.level, heading.level);
        try std.testing.expectEqual(@as(usize, 1), heading.spans.len);
        try std.testing.expect(heading.spans[0].kind == .link);
        try std.testing.expectEqualStrings("Noun", heading.spans[0].text);
        try std.testing.expectEqualStrings(target, heading.spans[0].target);
        try std.testing.expectEqual(i, lexeme.section);
        try std.testing.expectEqualSlices(usize, &.{0}, lexeme.introduction);
        try std.testing.expectEqual(@as(usize, 1), lexeme.definitions.len);
        try std.testing.expectEqual(@as(usize, 1), lexeme.definitions[0].block);
        try std.testing.expectEqualSlices(usize, &.{2}, lexeme.definitions[0].examples);
        try std.testing.expect(section.blocks[lexeme.definitions[0].block].kind == .definition);
        try std.testing.expect(section.blocks[lexeme.definitions[0].examples[0]].kind == .example);
        try std.testing.expectEqual(@as(usize, 0), lexeme.other_blocks.len);
        try std.testing.expectEqualStrings(if (i == 0) "first definition" else "second definition", section.blocks[1].spans[0].text);
        try std.testing.expectEqualStrings(if (i == 0) "first example" else "second example", section.blocks[2].spans[0].text);
    }
}

test "linked owner and edge-spaced heading companions preserve exact limited-trim labels through DPR2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { source: []const u8, label: []const u8, target: []const u8 }{
        .{ .source = "== [[EnglishTarget|English]] ==\nbody", .label = "English", .target = "EnglishTarget" },
        .{ .source = "== [[SpaceTarget|\u{a0} \tFrench \u{a0}]] ==\nbody", .label = "French", .target = "SpaceTarget" },
        .{ .source = "== [[BreakTarget|French<br>]] ==\nbody", .label = "French", .target = "BreakTarget" },
        .{ .source = "== [[WideTarget|\u{2003}French\u{2003}]] ==\nbody", .label = "\u{2003}French\u{2003}", .target = "WideTarget" },
    };
    for (cases) |case| {
        const encoded = try compileAlloc(a, "entry", .language, "English", "en", case.source, null);
        const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
        try std.testing.expectEqual(@as(usize, 1), decoded.entry.sections.len);
        const section = decoded.entry.sections[0];
        try std.testing.expectEqualStrings(case.label, section.title);
        try std.testing.expectEqual(@as(u8, 2), section.level);
        try std.testing.expect(section.blocks[0].kind == .heading);
        try std.testing.expectEqual(section.level, section.blocks[0].level);
        var text: std.ArrayList(u8) = .empty;
        var linked = false;
        for (section.blocks[0].spans) |span| {
            if (span.kind == .line_break) try text.append(a, '\n') else try text.appendSlice(a, span.text);
            try std.testing.expectEqualStrings("", span.trail);
            linked = linked or (span.kind == .link and std.mem.eql(u8, span.target, case.target));
        }
        try std.testing.expect(linked);
        try std.testing.expectEqualStrings(section.title, trimHeading(text.items));
        try std.testing.expectEqual(@as(usize, 2), section.blocks.len);
        try std.testing.expectEqualStrings("body", section.blocks[1].spans[0].text);
    }
}

test "unresolved action targets cannot cross reported compilation and DPR2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sources = [_]struct { input: []const u8, label: []const u8 }{
        .{ .input = "[https://dsal.uchicago.edu/cgi-bin/app/caturvedi_query.py?page=&#123;&#123;&#123;page=&#125;&#125;&#125; <b>page 741</b>]", .label = "page 741" },
        .{ .input = "[https://hindwidictionary.com/search?keyword=&#123;&#123;#urlencode:शारदा&#125;&#125; शारदा]", .label = "शारदा" },
        .{ .input = "[https://example.test/?q=&#123;&#123;missing&#125;&#125; <nowiki>{{literal}}</nowiki>]", .label = "{{literal}}" },
        .{ .input = "[https://example.test/?q=&#123;&#123;missing&#125;&#125; <code>&#123;&#123;literal&#125;&#125;</code>]", .label = "{{literal}}" },
    };
    for (sources) |item| {
        var report: Fallbacks = .{};
        const encoded = try compileReportedAlloc(a, "rejected target", .language, "Hindi", "hi", item.input, null, &report);
        const decoded = try codec.decodeAlloc(a, encoded, "rejected target", .language, .{ .code = "hi", .heading = "Hindi" });
        var visible: std.ArrayList(u8) = .empty;
        for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            try visible.appendSlice(a, span.text);
            try visible.appendSlice(a, span.trail);
            try std.testing.expect(span.kind != .link and span.kind != .external_link);
            try std.testing.expectEqualStrings("", span.target);
        };
        try std.testing.expectEqualStrings(item.label, visible.items);
        try std.testing.expect(report.rejected_external_target and !report.missing_template);
    }
    for ([_][]const u8{
        "https://example.test/?q=&#123;&#123;missing&#125;&#125;",
        "[https://example.test/?q=&#123;&#123;missing&#125;&#125;]",
    }) |source| {
        var report: Fallbacks = .{};
        try std.testing.expectError(error.UncompiledTemplate, compileReportedAlloc(a, "bare target", .language, "English", "en", source, null, &report));
        try std.testing.expectError(error.UncompiledTemplate, compileAlloc(a, "bare target", .language, "English", "en", source, null));
    }
    // A stale/raw action is never waived by reported mode or code styling.
    for ([_]ir.InlineKind{ .link, .external_link }) |kind| {
        var report: Fallbacks = .{};
        const spans = [_]compiler.Span{.{ .kind = kind, .text = "label", .target = "https://example.test/?q={{missing}}", .flags = .{ .code = true }, .provenance = .protected_literal }};
        try std.testing.expectError(error.UncompiledTemplate, validateSpans(a, &spans, &report));
        try std.testing.expectError(error.UncompiledTemplate, validateSpans(a, &spans, null));
    }
    var missing_report: Fallbacks = .{};
    const synthesized = try a.dupe(compiler.Span, &[_]compiler.Span{.{ .kind = .template, .text = "missing", .target = "{{nested}}" }});
    try std.testing.expectError(error.UncompiledTemplate, validateSpans(a, synthesized, &missing_report));
    // Existing ordinary literal diagnostics outside the rejected label do not
    // become page-wide hard errors merely because another action was refused.
    var outside_report: Fallbacks = .{ .rejected_external_target = true };
    const outside = [_]compiler.Span{.{ .kind = .text, .text = "[[literal outside", .provenance = .parsed }};
    try validateSpans(a, &outside, &outside_report);
    try std.testing.expect(outside_report.literal_markup);
    var unprotected_report: Fallbacks = .{};
    _ = try compileReportedAlloc(a, "unresolved label", .language, "English", "en", "[https://example.test/?q=&#123;&#123;missing&#125;&#125; {{missing-label}}]", null, &unprotected_report);
    try std.testing.expect(unprotected_report.missing_template);
}

test "AM glossary term headings retain bodies and actions without invented counter lexeme" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Exact source excerpts from AM page 1697/revision 18624, retaining the
    // preceding term and following term that establish the glossary boundary.
    const source = "[[computer glossary A|A]]\n[[computer glossary Z|Z]]\n==count== \t\n# ይቆጠር\nመቁጠር ወይንም ቁጥር\n\n==counter== \t\n# ቆጣሪ \t\n==country code== \t\n# የአገር ኮድ \t\n";
    const encoded = try compileAlloc(a, "computer glossary C", .language, "Unclassified", "", source, null);
    const decoded = try codec.decodeAlloc(a, encoded, "computer glossary C", .language, .{ .code = "", .heading = "Unclassified" });
    try std.testing.expectEqualStrings("Unclassified", decoded.entry.language.?);
    try std.testing.expectEqualStrings("", decoded.entry.language_code);
    try std.testing.expectEqual(@as(usize, 0), decoded.entry.organization.lexemes.len);
    try std.testing.expectEqual(@as(usize, 4), decoded.entry.sections.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, decoded.entry.organization.other_sections);
    for (decoded.entry.sections[1..], [_][]const u8{ "count", "counter", "country code" }) |section, title| {
        try std.testing.expectEqualStrings(title, section.title);
        try std.testing.expectEqual(@as(u8, 2), section.level);
        try std.testing.expect(section.blocks[0].kind == .definition);
    }
    try std.testing.expectEqualStrings("ይቆጠር", decoded.entry.sections[1].blocks[0].spans[0].text);
    try std.testing.expectEqualStrings("መቁጠር ወይንም ቁጥር", decoded.entry.sections[1].blocks[1].spans[0].text);
    try std.testing.expectEqualStrings("ቆጣሪ \t", decoded.entry.sections[2].blocks[0].spans[0].text);
    try std.testing.expectEqualStrings("የአገር ኮድ \t", decoded.entry.sections[3].blocks[0].spans[0].text);
    var actions: usize = 0;
    for (decoded.entry.sections[0].blocks[0].spans) |span| {
        if (span.kind != .link) continue;
        try std.testing.expectEqualStrings(if (actions == 0) "A" else "Z", span.text);
        try std.testing.expectEqualStrings(if (actions == 0) "computer glossary A" else "computer glossary Z", span.target);
        actions += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), actions);
}

test "explicit owner preserves direct L2 POS and nested Counter codec layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "==Counter==\n# One item.\n", "==English==\n===Counter===\n# One item.\n" }) |source| {
        const encoded = try compileAlloc(a, "item", .language, "English", "en", source, null);
        const decoded = try codec.decodeAlloc(a, encoded, "item", .language, .{ .code = "en", .heading = "English" });
        try std.testing.expectEqual(@as(usize, 1), decoded.entry.organization.lexemes.len);
        const lexeme = decoded.entry.organization.lexemes[0];
        try std.testing.expectEqualStrings("Counter", lexeme.kind);
        try std.testing.expectEqual(@as(usize, 1), lexeme.definitions.len);
        const block = decoded.entry.sections[lexeme.section].blocks[lexeme.definitions[0].block];
        try std.testing.expectEqualStrings("One item.", block.spans[0].text);
    }
}

test "reported usage examples preserve qualifier links placement and duplicate last wins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: Fallbacks = .{};
    const source = "{{ux|en|[[work|Work]]|translation=Translation|tr=wərk|q=discard-left|q=[[rare|rare]]|qq=discard-right|qq=[[regional|regional]]}}";
    const bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", source, null, &report);
    const parsed = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    var text: std.ArrayList(u8) = .empty;
    var left = false;
    var right = false;
    var example = false;
    var translation = false;
    for (parsed.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        try text.appendSlice(a, span.text);
        if (std.mem.eql(u8, span.text, "rare") or std.mem.eql(u8, span.text, "regional")) {
            try std.testing.expectEqual(types.Role.label, span.role);
            try std.testing.expect(!span.italic);
            try std.testing.expectEqual(types.InlineKind.link, span.kind);
            try std.testing.expectEqualStrings(span.text, span.target);
            if (std.mem.eql(u8, span.text, "rare")) left = true else right = true;
        }
        if (std.mem.eql(u8, span.text, "Work")) {
            example = true;
            try std.testing.expectEqual(types.Role.example, span.role);
            try std.testing.expect(span.italic);
            try std.testing.expectEqualStrings("en", span.language);
            try std.testing.expectEqualStrings("work", span.target);
        }
        if (std.mem.eql(u8, span.text, "Translation")) {
            translation = true;
            try std.testing.expect(!span.italic);
            try std.testing.expectEqual(types.Role.normal, span.role);
        }
    };
    try std.testing.expectEqualStrings("(rare) Work (regional)\nTranslation (wərk)", text.items);
    try std.testing.expect(left and right and example and translation);
    try std.testing.expect(report.template_presentation and !report.missing_template and !report.literal_markup);

    // An explicitly empty last qualifier removes its earlier value, as it does
    // in normal template arguments; plain examples keep their existing output.
    var empty_report: Fallbacks = .{};
    const empty_bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", "{{ux|en|Work|Translation|tr=wərk|q=obsolete|q=|qq=obsolete|qq=}}", null, &empty_report);
    const empty_parsed = try codec.decodeAlloc(a, empty_bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    var empty_text: std.ArrayList(u8) = .empty;
    for (empty_parsed.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| try empty_text.appendSlice(a, span.text);
    try std.testing.expectEqualStrings("Work\nTranslation (wərk)", empty_text.items);
    try std.testing.expect(empty_report.template_presentation and !empty_report.missing_template);
}

test "authored abbreviation explanations preserve compact text nested scope and actions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: Fallbacks = .{};
    const source = "<abbr title='outer &amp; inner'>ab<i>br</i><abbr>inherit</abbr><abbr title=''>clear</abbr><abbr title='different'>child</abbr>again</abbr> tail <code><abbr title='code explanation'>c</abbr></code> <nowiki><abbr title='literal'>raw</abbr></nowiki> <abbr title='uncertain'>?</abbr> <abbr title='feminine gender'>[[Appendix:Glossary#feminine|f]]</abbr> <abbr title='common gender'>c</abbr> <abbr title='masculine gender'>m</abbr> <abbr title='neuter gender'>n</abbr> <abbr title='&amp;lt;literal&amp;gt;'>x</abbr>";
    const bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", source, null, &report);
    try std.testing.expectEqualStrings(codec.explained_magic, bytes[0..4]);
    const parsed = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    var compact: std.ArrayList(u8) = .empty;
    var checks: usize = 0;
    for (parsed.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        try compact.appendSlice(a, span.text);
        if (std.mem.eql(u8, span.text, "ab") or std.mem.eql(u8, span.text, "br") or std.mem.eql(u8, span.text, "inherit") or std.mem.eql(u8, span.text, "again")) {
            try std.testing.expectEqualStrings("outer & inner", span.explanation);
            checks += 1;
        }
        if (std.mem.eql(u8, span.text, "clear")) {
            try std.testing.expectEqualStrings("", span.explanation);
            checks += 1;
        }
        if (std.mem.eql(u8, span.text, "child")) {
            try std.testing.expectEqualStrings("different", span.explanation);
            checks += 1;
        }
        if (std.mem.eql(u8, span.text, "c") and span.code) {
            try std.testing.expectEqualStrings("code explanation", span.explanation);
            try std.testing.expect(span.code);
            checks += 1;
        }
        if (std.mem.eql(u8, span.text, "?")) {
            try std.testing.expectEqualStrings("uncertain", span.explanation);
            checks += 1;
        }
        if (std.mem.eql(u8, span.text, "f")) {
            try std.testing.expectEqualStrings("feminine gender", span.explanation);
            try std.testing.expectEqualStrings("Appendix:Glossary#feminine", span.target);
            try std.testing.expect(span.kind == .link);
            checks += 1;
        }
        if (std.mem.eql(u8, span.text, "c") and !span.code) {
            try std.testing.expectEqualStrings("common gender", span.explanation);
            checks += 1;
        }
        if (std.mem.eql(u8, span.text, "m")) {
            try std.testing.expectEqualStrings("masculine gender", span.explanation);
            checks += 1;
        }
        if (std.mem.eql(u8, span.text, "n")) {
            try std.testing.expectEqualStrings("neuter gender", span.explanation);
            checks += 1;
        }
        if (std.mem.eql(u8, span.text, "x")) {
            try std.testing.expectEqualStrings("&lt;literal&gt;", span.explanation);
            checks += 1;
        }
        if (std.mem.indexOf(u8, span.text, " tail ") != null) try std.testing.expectEqualStrings("", span.explanation);
        if (std.mem.indexOf(u8, span.text, "<abbr title='literal'>") != null) {
            try std.testing.expectEqualStrings("", span.explanation);
            checks += 1;
        }
    };
    try std.testing.expectEqual(@as(usize, 14), checks);
    try std.testing.expectEqualStrings("abbrinheritclearchildagain tail c <abbr title='literal'>raw</abbr> ? f c m n x", compact.items);
    try std.testing.expect(!report.any());
}

test "abbreviation explanations survive rich headings display table captions cells and references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: Fallbacks = .{};
    const source = "==English==\n===<abbr title='heading'>Noun</abbr>===\n# A word.<ref name=r><abbr title='reference'>ref</abbr></ref>\n{|\n|+ <abbr title='caption'>C</abbr>\n|-\n| <abbr title='cell'>D</abbr>\n|}\n<ref name=r/>\n<references/>";
    const bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", source, .{ .source = "<abbr title='display'>entry</abbr>", .page_title = "entry" }, &report);
    const parsed = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualStrings("display", parsed.entry.display_title[0].explanation);
    var heading = false;
    var caption = false;
    var cell = false;
    for (parsed.entry.sections) |section| for (section.blocks) |block| {
        for (block.spans) |span| if (std.mem.eql(u8, span.explanation, "heading")) {
            heading = block.kind == .heading;
        };
        if (block.table) |table_value| {
            for (table_value.caption) |span| if (std.mem.eql(u8, span.explanation, "caption")) {
                caption = true;
            };
            for (table_value.rows) |row| for (row.cells) |cell_value| for (cell_value.spans) |span| if (std.mem.eql(u8, span.explanation, "cell")) {
                cell = true;
            };
        }
    };
    try std.testing.expect(heading and caption and cell);
    try std.testing.expectEqual(@as(usize, 1), parsed.entry.references.len);
    try std.testing.expectEqualStrings("reference", parsed.entry.references[0].spans[0].explanation);
    try std.testing.expect(!report.any());
}

test "abbreviation explanations cross structural and poem boundaries without reviving empty titles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][]const u8{
        "<abbr title='outer'><div>before\n{|\n| [[target|linked]] <abbr title=''>clear</abbr> after\n|}\n</div></abbr> tail",
        "<abbr title='outer'>before\n{|\n| [[target|linked]] <abbr title=''>clear</abbr> after\n|}\n</abbr> tail",
        "<abbr title='outer'><ol><li>before\n# [[target|linked]]\n<abbr title=''>clear</abbr> after</li></ol></abbr> tail",
        "<abbr title='outer'><poem>before\n<abbr title=''>clear</abbr>\n[[target|linked]] after</poem></abbr> tail",
    };
    for (cases) |source| {
        var report: Fallbacks = .{};
        const bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", source, null, &report);
        const parsed = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
        var before = false;
        var linked = false;
        var clear = false;
        var after = false;
        var tail = false;
        var observed: std.ArrayList(types.Span) = .empty;
        defer observed.deinit(a);
        for (parsed.entry.sections) |section| for (section.blocks) |block| {
            try observed.appendSlice(a, block.spans);
            if (block.table) |table| {
                try observed.appendSlice(a, table.caption);
                for (table.rows) |row| for (row.cells) |cell| try observed.appendSlice(a, cell.spans);
            }
        };
        for (observed.items) |span| {
            if (std.mem.indexOf(u8, span.text, "before") != null) {
                try std.testing.expectEqualStrings("outer", span.explanation);
                before = true;
            }
            if (std.mem.eql(u8, span.text, "linked")) {
                try std.testing.expectEqualStrings("outer", span.explanation);
                try std.testing.expectEqualStrings("target", span.target);
                linked = true;
            }
            if (std.mem.eql(u8, span.text, "clear")) {
                try std.testing.expectEqualStrings("", span.explanation);
                clear = true;
            }
            if (std.mem.indexOf(u8, span.text, "after") != null) {
                try std.testing.expectEqualStrings("outer", span.explanation);
                after = true;
            }
            if (std.mem.indexOf(u8, span.text, "tail") != null) {
                try std.testing.expectEqualStrings("", span.explanation);
                tail = true;
            }
        }
        try std.testing.expect(before and linked and clear and after and tail);
        try std.testing.expect(!report.unclosed_formatting and !report.missing_template);
    }
}

test "supported usage recovery content keeps example actions and visible Lua provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: Fallbacks = .{};
    const source = "{{ux|en|[[work|Work]]|translation=Translation|tr=wərk|q=[[rare|rare]]|qq=[[regional|regional]]}}<br/><strong class=\"error\"><span class=\"scribunto-error\">Lua error in Module:usex: The function &quot;display&quot; does not exist.</span></strong>";
    const bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", source, null, &report);
    const decoded = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    var text: std.ArrayList(u8) = .empty;
    var example = false;
    var labels: usize = 0;
    for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        try text.appendSlice(a, span.text);
        if (std.mem.eql(u8, span.text, "Work")) {
            example = true;
            try std.testing.expect(span.kind == .link and span.role == .example and span.italic);
            try std.testing.expectEqualStrings("work", span.target);
            try std.testing.expectEqualStrings("en", span.language);
        }
        if (std.mem.eql(u8, span.text, "rare") or std.mem.eql(u8, span.text, "regional")) {
            labels += 1;
            try std.testing.expect(span.kind == .link and span.role == .label and !span.italic);
            try std.testing.expectEqualStrings(span.text, span.target);
        }
    };
    try std.testing.expect(example and labels == 2);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "Translation") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "wərk") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "Lua error in Module:usex:") != null);
    try std.testing.expect(report.rendered_lua_error and report.template_presentation and !report.literal_markup);
}

test "ordinary example HTML preserves nested table cells actions and explicit language scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: Fallbacks = .{};
    const source = "<span class=\"label-content\">([[rare|rare]])</span> <i class=\"e-example\" lang=\"en\">'''incite''' people to violence\n{| class=\"cquote\"\n| ”\n| <span class=\"script-arabic\">حرِّض الناس على العنف</span> [[target|linked]] <span lang=\"ar\">[[عربي|عربي]]</span>\n| “\n|}\n</i> <span class=\"label-content\">([[regional|regional]])</span><br/>Translation <span class=\"label-content\">(tr)</span> tail";
    const bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", source, null, &report);
    const decoded = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    var text: std.ArrayList(u8) = .empty;
    var example = false;
    var arabic = false;
    var linked = false;
    var override = false;
    var labels: usize = 0;
    var after = false;
    var observed: std.ArrayList(types.Span) = .empty;
    defer observed.deinit(a);
    var actual_cells: usize = 0;
    for (decoded.entry.sections) |section| for (section.blocks) |block| {
        try observed.appendSlice(a, block.spans);
        if (block.table) |table| {
            try observed.appendSlice(a, table.caption);
            for (table.rows) |row| for (row.cells) |cell| {
                actual_cells += 1;
                try observed.appendSlice(a, cell.spans);
            };
        }
    };
    for (observed.items) |span| {
        try text.appendSlice(a, span.text);
        if (std.mem.eql(u8, span.text, "incite")) {
            example = true;
            try std.testing.expect(span.role == .example and span.italic and span.bold);
            try std.testing.expectEqualStrings("en", span.language);
        }
        if (std.mem.indexOf(u8, span.text, "حرِّض الناس على العنف") != null) {
            arabic = true;
            try std.testing.expect(span.role == .example and span.italic);
            // Captured script-arabic is a class, not an authored lang override.
            try std.testing.expectEqualStrings("en", span.language);
        }
        if (std.mem.eql(u8, span.text, "linked")) {
            linked = true;
            try std.testing.expect(span.kind == .link and span.role == .example and span.italic);
            try std.testing.expectEqualStrings("target", span.target);
            try std.testing.expectEqualStrings("en", span.language);
        }
        if (std.mem.eql(u8, span.text, "عربي")) {
            override = true;
            try std.testing.expect(span.kind == .link and span.role == .example and span.italic);
            try std.testing.expectEqualStrings("عربي", span.target);
            try std.testing.expectEqualStrings("ar", span.language);
        }
        if (std.mem.eql(u8, span.text, "rare") or std.mem.eql(u8, span.text, "regional")) {
            labels += 1;
            try std.testing.expect(span.kind == .link and span.role == .label and !span.italic);
            try std.testing.expectEqualStrings(span.text, span.target);
        }
        if (std.mem.indexOf(u8, span.text, "Translation") != null or std.mem.indexOf(u8, span.text, "tail") != null) {
            after = true;
            try std.testing.expect(span.role == .normal and !span.italic);
        }
    }
    try std.testing.expect(example and arabic and linked and override and after and labels == 2);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "”") != null and std.mem.indexOf(u8, text.items, "“") != null);
    try std.testing.expectEqual(@as(usize, 3), actual_cells);
    // Span-only consumers use the existing block-aware flattening route too.
    var inline_renderer: compiler.Renderer = .{ .a = a, .context = .{} };
    const inline_spans = try inline_renderer.parseSpans(source, .{});
    var inline_link = false;
    var inline_override = false;
    var inline_tail = false;
    for (inline_spans) |span| {
        if (std.mem.eql(u8, span.text, "linked")) {
            inline_link = true;
            try std.testing.expect(span.role == .example and span.flags.italic);
            try std.testing.expectEqualStrings("target", span.target);
            try std.testing.expectEqualStrings("en", span.language);
        }
        if (std.mem.eql(u8, span.text, "عربي")) {
            inline_override = true;
            try std.testing.expect(span.role == .example and span.flags.italic);
            try std.testing.expectEqualStrings("ar", span.language);
        }
        if (std.mem.indexOf(u8, span.text, "tail") != null) {
            inline_tail = true;
            try std.testing.expect(span.role == .normal and !span.flags.italic);
        }
    }
    try std.testing.expect(inline_link and inline_override and inline_tail);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "Lua error") == null);
    try std.testing.expect(!report.rendered_lua_error and !report.literal_markup and !report.malformed_table and !report.unclosed_formatting);
}

test "nonleading example scopes preserve wiki sense continuation and next sense numbering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: Fallbacks = .{};
    // Captured incite uses #: before ux; the materialized quotation is a real
    // wiki table. Qualifier links also keep a lexical prefix before the i scope.
    const input = "==English==\n===Verb===\n# [[first|First definition]]\n#: <span class=\"label-content\">([[rare|rare]])</span> <i class=\"e-example\" lang=\"en\">'''incite''' people to violence\n{| class=\"cquote\"\n| ” || <span class=\"script-arabic\">حرِّض الناس على العنف</span> [[target|linked]] <span lang=\"ar\">[[عربي|عربي]]</span> || “\n|}\n</i>\n# [[next|Next definition]]\n";
    const bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", input, null, &report);
    const decoded = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    var first = false;
    var baseline_language: []const u8 = "";
    var example = false;
    var qualifier = false;
    var next = false;
    var linked = false;
    var arabic = false;
    var override = false;
    var cells: usize = 0;
    for (decoded.entry.sections) |section| for (section.blocks) |block| {
        for (block.spans) |span| {
            if (span.kind == .link and std.mem.eql(u8, span.target, "first")) {
                first = true;
                baseline_language = span.language;
                try std.testing.expect(block.kind == .definition);
                try std.testing.expectEqualStrings("#", block.list_path);
                try std.testing.expectEqualStrings("1", block.number);
                try std.testing.expect(span.role == .normal and !span.italic);
            }
            if (std.mem.eql(u8, span.text, "incite")) {
                example = true;
                try std.testing.expectEqualStrings("#:", block.list_path);
                try std.testing.expect(span.role == .example and span.italic and span.bold);
                try std.testing.expectEqualStrings("en", span.language);
            }
            if (span.kind == .link and std.mem.eql(u8, span.target, "rare")) {
                qualifier = true;
                try std.testing.expectEqualStrings("#:", block.list_path);
                try std.testing.expect(span.role == .label and !span.italic);
            }
            if (span.kind == .link and std.mem.eql(u8, span.target, "next")) {
                next = true;
                try std.testing.expect(block.kind == .definition);
                try std.testing.expect(first);
                try std.testing.expectEqualStrings(baseline_language, span.language);
                try std.testing.expectEqualStrings("#", block.list_path);
                try std.testing.expectEqualStrings("2", block.number);
                try std.testing.expect(span.role == .normal and !span.italic);
            }
        }
        if (block.table) |table| for (table.rows) |row| for (row.cells) |cell| {
            cells += 1;
            for (cell.spans) |span| {
                if (std.mem.indexOf(u8, span.text, "حرِّض الناس على العنف") != null) {
                    arabic = true;
                    try std.testing.expect(span.role == .example and span.italic);
                    try std.testing.expectEqualStrings("en", span.language);
                }
                if (std.mem.eql(u8, span.text, "linked")) {
                    linked = true;
                    try std.testing.expect(span.kind == .link and span.role == .example and span.italic);
                    try std.testing.expectEqualStrings("target", span.target);
                    try std.testing.expectEqualStrings("en", span.language);
                }
                if (std.mem.eql(u8, span.text, "عربي")) {
                    override = true;
                    try std.testing.expect(span.kind == .link and span.role == .example and span.italic);
                    try std.testing.expectEqualStrings("عربي", span.target);
                    try std.testing.expectEqualStrings("ar", span.language);
                }
            }
        };
    };
    try std.testing.expect(first and example and qualifier and next and linked and arabic and override);
    try std.testing.expectEqual(@as(usize, 3), cells);
    try std.testing.expect(!report.unclosed_formatting and !report.literal_markup and !report.malformed_table and !report.rendered_lua_error);
    // Real boundaries still reset numbering; genuine child progress is kept
    // at the table itself rather than reconstructed from an old parent seed.
    for ([_]struct { between: []const u8, expected: []const u8, html: bool = false }{
        .{ .between = "", .expected = "2", .html = true },
        .{ .between = "\n", .expected = "1" },
        .{ .between = "===Boundary===\n", .expected = "1" },
        .{ .between = "# [[progress|Progress definition]]\n", .expected = "3" },
    }) |control| {
        const controlled_input = try std.fmt.allocPrint(a, "==English==\n===Verb===\n# [[first|First definition]]\n#: <i class=\"e-example\" lang=\"en\">example\n{s}{s}\n</i>\n# [[next|Next definition]]\n", .{ control.between, if (control.html) "<table><tr><td>[[cell|cell]]</td></tr></table>" else "{|\n| [[cell|cell]]\n|}" });
        var controlled_report: Fallbacks = .{};
        const controlled_bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", controlled_input, null, &controlled_report);
        const controlled = try codec.decodeAlloc(a, controlled_bytes, "entry", .language, .{ .code = "en", .heading = "English" });
        var found_next = false;
        var found_cell = false;
        var found_progress = false;
        for (controlled.entry.sections) |section| for (section.blocks) |block| {
            for (block.spans) |span| {
                if (span.kind == .link and std.mem.eql(u8, span.target, "next")) {
                    found_next = true;
                    try std.testing.expect(block.kind == .definition);
                    try std.testing.expectEqualStrings(control.expected, block.number);
                    try std.testing.expect(span.role == .normal and !span.italic);
                }
                if (span.kind == .link and std.mem.eql(u8, span.target, "progress")) {
                    found_progress = true;
                    try std.testing.expectEqualStrings("2", block.number);
                }
            }
            if (block.table) |table| for (table.rows) |row| for (row.cells) |cell| for (cell.spans) |span| {
                if (span.kind == .link and std.mem.eql(u8, span.target, "cell")) {
                    found_cell = true;
                    try std.testing.expect(span.role == .example and span.italic);
                }
            };
        };
        try std.testing.expect(found_next and found_cell);
        try std.testing.expectEqual(std.mem.indexOf(u8, control.between, "progress") != null, found_progress);
        try std.testing.expect(!controlled_report.unclosed_formatting and !controlled_report.malformed_table and !controlled_report.literal_markup);
    }
}

test "closing br preserves adjacent styles and actions through DPR2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoded = try compileAlloc(a, "entry", .language, "English", "en", "'''before'''</br>[[Target|after]]", null);
    const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
    var text: std.ArrayList(u8) = .empty;
    var breaks: usize = 0;
    var bold: usize = 0;
    var links: usize = 0;
    for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        if (span.kind == .line_break) {
            breaks += 1;
            try text.append(a, '\n');
        } else try text.appendSlice(a, span.text);
        if (std.mem.eql(u8, span.text, "before") and span.bold) bold += 1;
        if (span.kind == .link) {
            try std.testing.expectEqualStrings("after", span.text);
            try std.testing.expectEqualStrings("Target", span.target);
            links += 1;
        }
    };
    try std.testing.expectEqualStrings("before\nafter", text.items);
    try std.testing.expectEqual(@as(usize, 1), breaks);
    try std.testing.expectEqual(@as(usize, 1), bold);
    try std.testing.expectEqual(@as(usize, 1), links);
}
