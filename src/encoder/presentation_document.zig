const missing_dependency = @import("missing_dependency");
pub const MissingText = missing_dependency.Text;
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
    original_start: ?usize = null,
    source: []const u8,
    missing: ?MissingText = null,
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
    missing: ?MissingText = null,
    fallbacks: Fallbacks,
};
pub fn prepareBodySourceAlloc(a: A, title: []const u8, source: []const u8) !PreparedBodySource {
    var renderer: compiler.Renderer = .{ .a = a, .context = .{ .title = title, .unclosed_fragment_trace = try unclosedFragmentTraceFromEnv() } };
    const prepared = try renderer.prepareBodySource(source);
    return .{ .source = prepared, .fallbacks = renderer.fallbacks };
}
pub fn prepareBodySourceWithMissingAlloc(a: A, title: []const u8, source: MissingText) !PreparedBodySource {
    var renderer: compiler.Renderer = .{ .a = a, .context = .{ .title = title, .unclosed_fragment_trace = try unclosedFragmentTraceFromEnv() } };
    const prepared = try renderer.prepareBodySourceWithMissing(source);
    return .{ .source = prepared.bytes, .missing = prepared, .fallbacks = renderer.fallbacks };
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
            const owned_foreground = if (attributes.foreground) |color| try self.a.dupe(u8, color) else null;
            errdefer if (owned_foreground) |color| self.a.free(color);
            try self.scopes.append(self.a, .{
                .opening_start = absolute_open,
                .body_start = base + body_start,
                .body_end = base + body_end,
                .resume_at = base + resume_at,
                .matched = matched,
                .kind = kind,
                .formatting = formatting,
                .attributes = .{ .classes = owned_classes, .role = attributes.role, .relation_note = attributes.relation_note, .language = owned_language, .direction = owned_direction, .explanation = owned_explanation, .explanation_set = attributes.explanation_set, .foreground = owned_foreground, .foreground_set = attributes.foreground_set },
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
            if (scope.attributes.foreground) |color| a.free(color);
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
            .citations = reference_context.citations,
            .external_links_prepared = reference_context.citations != null,
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
pub const referenceDefinitionsWithMissingAlloc = compiler.referenceDefinitionsWithMissingAlloc;
pub const preparePageTocSourceAlloc = compiler.preparePageTocSourceAlloc;
pub const preparePageTocSourceWithMissingAlloc = compiler.preparePageTocSourceWithMissingAlloc;
pub const preparePageExternalLinksWithMissingAlloc = compiler.preparePageExternalLinksWithMissingAlloc;
pub const preparePageExternalLinksAlloc = compiler.preparePageExternalLinksAlloc;

fn requireCompiledText(text: []const u8) !void {
    return compiler.requireCompiledText(text);
}

fn requireCompiledSpans(a: A, spans: []const compiler.Span) !void {
    try requireCompiledText(try compiler.plainText(a, spans));
}

fn validateText(text: []const u8, report: ?*Fallbacks) !void {
    requireCompiledText(text) catch |err| {
        if (report) |fallback| fallback.literal_markup = true;
        // Reported diagnostics do not authorize raw parsed source in a record.
        // Protected/entity literals are excluded by validateSpans provenance.
        return err;
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
        if (span.kind == .external_link and compiler.unresolvedExternalActionTarget(span.target))
            return error.UncompiledTemplate;
        if (span.kind == .link and compiler.unresolvedActionTarget(span.target))
            return error.UncompiledTemplate;
    }
    // Only explicitly generated diagnostic spans may receive boundary spaces.
    // Authored text and protected/entity provenance are never rewritten here.
    try compiler.separateGeneratedDiagnosticBoundaries(a, @constCast(spans));
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
    missing: ?MissingText = null,
    page_title: []const u8,
};

const heading_ids = @import("presentation_heading_anchors.zig");
pub const HeadingSourceRange = struct { owner_start: usize, page_start: usize, len: usize };
pub const HeadingAnchor = struct { source_offset: usize, anchor: []const u8, anchor_fallback: []const u8 = "" };
pub const HeadingObservation = struct { items: []const HeadingAnchor = &.{} };

const WorkSection = struct {
    is_heading: bool = false,
    anchor: []const u8 = "",
    anchor_fallback: []const u8 = "",
    heading_source_offset: ?usize = null,
    heading_authored_id: []const u8 = "",
    title_depth: u8 = 0,
    title_list_path: []const u8 = "",
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

// One authoritative cell branch, one shared collection budget and table depth
// for each document pass. Cell headings remain Blocks throughout these visits.
const CompilerWalk = struct {
    remaining: usize = 1 << 20,

    fn take(self: *CompilerWalk, count: usize) !void {
        if (count > self.remaining) return error.InvalidPresentation;
        self.remaining -= count;
    }
    fn spans(self: *CompilerWalk, context: anytype, values: []const compiler.Span) anyerror!void {
        try self.take(values.len);
        try context.spans(values);
    }
    fn blocks(self: *CompilerWalk, context: anytype, values: []const compiler.Block, table_depth: usize) anyerror!void {
        try self.take(values.len);
        for (@constCast(values)) |*block| {
            try context.block(block);
            try self.spans(context, block.spans);
            if (block.table) |child_table| try self.table(context, child_table, table_depth + 1);
        }
    }
    fn table(self: *CompilerWalk, context: anytype, value: compiler.Table, table_depth: usize) anyerror!void {
        if (table_depth > types.max_table_depth) return error.InvalidPresentation;
        try self.spans(context, value.caption);
        try self.take(value.rows.len);
        for (value.rows) |row| {
            try self.take(row.cells.len);
            for (row.cells) |cell| {
                if (cell.blocks) |ordered_blocks| {
                    if (cell.spans.len != 0 or cell.nested_table != null) return error.InvalidPresentation;
                    try self.blocks(context, ordered_blocks, table_depth);
                } else {
                    try self.spans(context, cell.spans);
                    if (cell.nested_table) |child| try self.table(context, child, table_depth + 1);
                }
            }
        }
    }
};

const RebaseHeadingOffsets = struct {
    base: usize,
    fn spans(_: *@This(), _: []const compiler.Span) anyerror!void {}
    fn block(self: *@This(), value: *compiler.Block) anyerror!void {
        if (value.heading_source_offset) |offset|
            value.heading_source_offset = std.math.add(usize, self.base, offset) catch return error.InvalidHeadingProjection;
    }
};

const ObserveHeadings = struct {
    a: A,
    registry: *heading_ids.Registry,
    result: *std.ArrayList(HeadingAnchor),
    fn spans(_: *@This(), _: []const compiler.Span) anyerror!void {}
    fn add(self: *@This(), source_offset: ?usize, authored_id: []const u8, values: []const compiler.Span) !void {
        const offset = source_offset orelse return error.InvalidHeadingProjection;
        var report: Fallbacks = .{};
        try validateSpans(self.a, values, &report);
        const text = try compiler.plainText(self.a, values);
        const identity = if (authored_id.len != 0) try self.registry.authoredIds(self.a, authored_id) else try self.registry.headingIds(self.a, text);
        try self.result.append(self.a, .{ .source_offset = offset, .anchor = identity.anchor, .anchor_fallback = identity.anchor_fallback });
    }
    fn block(self: *@This(), value: *compiler.Block) anyerror!void {
        if (value.kind == .heading) try self.add(value.heading_source_offset, value.heading_authored_id, value.spans);
    }
};

const AssignHeadings = struct {
    a: A,
    registry: *heading_ids.Registry,
    observation: ?*const HeadingObservation,
    projection: []const HeadingSourceRange,
    fn spans(_: *@This(), _: []const compiler.Span) anyerror!void {}
    fn identity(self: *@This(), source_offset: ?usize, authored_id: []const u8, text: []const u8) !heading_ids.Ids {
        if (self.observation) |observation| {
            const local = source_offset orelse return error.InvalidHeadingProjection;
            var page: ?usize = null;
            for (self.projection) |range| {
                if (local >= range.owner_start and local - range.owner_start < range.len) {
                    page = std.math.add(usize, range.page_start, local - range.owner_start) catch return error.InvalidHeadingProjection;
                    break;
                }
            }
            const offset = page orelse return error.InvalidHeadingProjection;
            for (observation.items) |item| if (item.source_offset == offset)
                return .{ .anchor = item.anchor, .anchor_fallback = item.anchor_fallback };
            return error.InvalidHeadingProjection;
        }
        return if (authored_id.len != 0) try self.registry.authoredIds(self.a, authored_id) else try self.registry.headingIds(self.a, text);
    }
    fn block(self: *@This(), value: *compiler.Block) anyerror!void {
        if (value.kind != .heading) return;
        const ids = try self.identity(value.heading_source_offset, value.heading_authored_id, try compiler.plainText(self.a, value.spans));
        value.anchor = ids.anchor;
        value.anchor_fallback = ids.anchor_fallback;
    }
};

const ValidateCompilerSpans = struct {
    a: A,
    fallbacks: ?*Fallbacks,
    fn block(_: *@This(), _: *compiler.Block) anyerror!void {}
    fn spans(self: *@This(), values: []const compiler.Span) anyerror!void {
        try validateSpans(self.a, values, self.fallbacks);
    }
};

const Builder = struct {
    is_heading: bool = false,
    heading_source_offset: ?usize = null,
    heading_authored_id: []const u8 = "",
    title_depth: u8 = 0,
    title_list_path: []const u8 = "",
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
            .is_heading = self.is_heading,
            .heading_source_offset = self.heading_source_offset,
            .heading_authored_id = self.heading_authored_id,
            .title_spans = self.title_spans,
            .title_depth = self.title_depth,
            .title_list_path = self.title_list_path,
            .blocks = blocks,
        });
    }

    fn render(self: *Builder, source: []const u8) !void {
        try self.renderWithMissing(MissingText.untracked(source));
    }
    fn renderWithMissing(self: *Builder, source: MissingText) !void {
        try self.consume(try self.renderer.renderBodyWithMissing(source));
    }

    fn renderFragments(self: *Builder, fragments: []const SourceFragment) !void {
        var rendered: std.ArrayList(compiler.Block) = .empty;
        defer rendered.deinit(self.a);
        for (fragments) |fragment| {
            try rendered.appendSlice(self.a, try self.renderer.renderBodyWithFragmentPreAndMissing(fragment.missing orelse MissingText.untracked(fragment.source), fragment.pre));
        }
        try self.consume(try rendered.toOwnedSlice(self.a));
    }

    fn consume(self: *Builder, rendered: []const compiler.Block) !void {
        var section_start: usize = 0;
        for (rendered, 0..) |item, i| {
            if (item.kind == .heading) {
                try self.flush(rendered[section_start..i]);
                self.started = true;
                self.is_heading = true;
                self.heading_source_offset = item.heading_source_offset;
                self.heading_authored_id = item.heading_authored_id;
                self.title_spans = item.spans;
                self.title_depth = item.depth;
                self.title_list_path = item.list_path;
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
    return workAllocWithMissingFragments(a, title, language, MissingText.untracked(source), link_trail, namespace_catalog, behavior_switches, image_options, reference_context, poem_phase, fragments);
}
fn workAllocWithMissingFragments(a: A, title: []const u8, language: []const u8, tracked: MissingText, link_trail: ir.LinkTrail, namespace_catalog: ?*const NamespaceRegistry, behavior_switches: ?*const BehaviorRegistry, image_options: ?*const ImageRegistry, reference_context: compiler.ReferenceDefinitions, poem_phase: ?*const PoemPhase, fragments: []const SourceFragment) !Work {
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
            .citations = reference_context.citations,
            .external_links_prepared = reference_context.citations != null,
        },
    };
    renderer.page_reference_definitions = reference_context.items;
    renderer.fallbacks.merge(reference_context.fallbacks);
    var builder: Builder = .{
        .a = a,
        .renderer = &renderer,
        .title = if (language.len == 0) title else language,
    };
    if (fragments.len == 0) try builder.renderWithMissing(tracked) else try builder.renderFragments(fragments);
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

fn workWithHeadingOffsetsAlloc(a: A, title: []const u8, language: []const u8, source: MissingText, link_trail: ir.LinkTrail, namespace_catalog: ?*const NamespaceRegistry, behavior_switches: ?*const BehaviorRegistry, image_options: ?*const ImageRegistry, reference_context: compiler.ReferenceDefinitions, poem_phase: ?*const PoemPhase, fragments: []const SourceFragment) !Work {
    var renderer: compiler.Renderer = .{ .a = a, .context = .{ .title = title, .language = if (language.len == 0) "English" else language, .link_trail = link_trail, .namespace_catalog = namespace_catalog, .behavior_switches = behavior_switches, .image_options = image_options, .poem_phase = poem_phase } };
    renderer.context.citations = reference_context.citations;
    renderer.context.external_links_prepared = reference_context.citations != null;
    renderer.page_reference_definitions = reference_context.items;
    renderer.fallbacks.merge(reference_context.fallbacks);
    var builder: Builder = .{ .a = a, .renderer = &renderer, .title = if (language.len == 0) title else language };
    if (fragments.len == 0) {
        try builder.consume(try renderer.renderBodyWithHeadingOffsets(source));
    } else {
        var rendered: std.ArrayList(compiler.Block) = .empty;
        defer rendered.deinit(a);
        var owner_at: usize = 0;
        var walk: CompilerWalk = .{};
        for (fragments) |fragment| {
            const tracked = fragment.missing orelse MissingText.untracked(fragment.source);
            renderer.heading_source = tracked.bytes;
            const blocks = try renderer.renderBodyWithFragmentPreAndMissing(tracked, fragment.pre);
            var rebase: RebaseHeadingOffsets = .{ .base = owner_at };
            try walk.blocks(&rebase, blocks, 0);
            try rendered.appendSlice(a, blocks);
            owner_at = std.math.add(usize, owner_at, fragment.source.len) catch return error.InvalidHeadingProjection;
        }
        renderer.heading_source = null;
        try builder.consume(try rendered.toOwnedSlice(a));
    }
    return .{ .sections = try builder.sections.toOwnedSlice(a), .references = try renderer.finishReferences(), .media = try renderer.media.toOwnedSlice(a), .media_caption_spans = try renderer.media_caption_spans.toOwnedSlice(a), .rendered_templates = renderer.rendered_templates, .unresolved_templates = renderer.unresolved_templates, .fallbacks = renderer.fallbacks };
}

pub fn observeHeadingAnchorsAlloc(a: A, title: []const u8, source: MissingText, link_trail: ir.LinkTrail, namespace_catalog: ?*const NamespaceRegistry, behavior_switches: ?*const BehaviorRegistry, image_options: ?*const ImageRegistry, reference_context: compiler.ReferenceDefinitions, poem_phase: ?*const PoemPhase) !HeadingObservation {
    const work = try workWithHeadingOffsetsAlloc(a, title, "", source, link_trail, namespace_catalog, behavior_switches, image_options, reference_context, poem_phase, &.{});
    var registry: heading_ids.Registry = .{};
    defer registry.deinit(a);
    var result: std.ArrayList(HeadingAnchor) = .empty;
    defer result.deinit(a);
    var observe: ObserveHeadings = .{ .a = a, .registry = &registry, .result = &result };
    var walk: CompilerWalk = .{};
    for (work.sections) |section| {
        if (section.is_heading) try observe.add(section.heading_source_offset, section.heading_authored_id, section.title_spans);
        try walk.blocks(&observe, section.blocks, 0);
    }
    return .{ .items = try result.toOwnedSlice(a) };
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
    const spans = renderer.parseSpansWithMissing(value.missing orelse MissingText.untracked(value.source), .{ .role = .headword }) catch |err| {
        if (fallbacks) |report| switch (err) {
            error.RenderLimit => {
                report.render_limit = true;
                report.display_title_rejected = true;
                return &.{};
            },
            else => return err,
        } else return err;
    };
    if (fallbacks == null and (renderer.rendered_templates != 0 or renderer.unresolved_templates != 0)) return error.UncompiledTemplate;
    if (fallbacks) |report| report.merge(renderer.fallbacks);
    if (renderer.rendered_templates != 0 or renderer.unresolved_templates > renderer.diagnosed_missing_targets) {
        if (fallbacks) |report| {
            report.template_presentation = report.template_presentation or renderer.rendered_templates != 0;
            report.missing_template = report.missing_template or renderer.unresolved_templates != 0;
            report.display_title_rejected = true;
            return &.{};
        }
        return error.UncompiledTemplate;
    }
    // Suppressed self navigation is still an authored link, not title formatting.
    for (spans) |span| if (span.kind != .text or span.self_link) {
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

// Reported compilation retains typed source-error diagnostics, not raw parsed
// syntax. Compiler recoveries preserve independently parsed semantic content;
// any unsupported parsed leftovers still reject publication. Explicit protected
// and entity literal provenance remains display data, not an expansion input.
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
        found: bool = false,
        fn block(self: *@This(), value: *compiler.Block) anyerror!void {
            if (value.feature != null or value.kind == .rule) self.found = true;
        }
        fn spans(self: *@This(), values: []const compiler.Span) anyerror!void {
            for (values) |span| if (std.mem.trim(u8, span.text, " \t\r\n").len != 0 or span.target.len != 0) {
                self.found = true;
            };
        }
    };
    var has: Has = .{ .found = work.media.len != 0 };
    var walk: CompilerWalk = .{};
    for (work.references) |reference| try walk.spans(&has, reference.spans);
    for (work.sections) |section| {
        try walk.spans(&has, section.title_spans);
        try walk.blocks(&has, section.blocks, 0);
    }
    return has.found;
}

fn validateTableSpans(a: A, table: compiler.Table, fallbacks: ?*Fallbacks) anyerror!void {
    var validate: ValidateCompilerSpans = .{ .a = a, .fallbacks = fallbacks };
    var walk: CompilerWalk = .{};
    try walk.table(&validate, table, 1);
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
    return compileReportedWithReferencesAndPhasesFragmentsAlloc(a, title, kind, language, language_code, MissingText.untracked(source), display_title, link_trail, namespace_catalog, behavior_switches, image_options, reference_context, fallbacks, poem_phase, fragments);
}
pub fn compileReportedWithReferencesAndPhasesFragmentsAlloc(
    a: A,
    title: []const u8,
    kind: format.BlobKind,
    language: ?[]const u8,
    language_code: []const u8,
    source: MissingText,
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
    return compileReportedWithReferencesAndPhasesFragmentsAndHeadingAnchorsAlloc(a, title, kind, language, language_code, source, display_title, link_trail, namespace_catalog, behavior_switches, image_options, reference_context, fallbacks, poem_phase, fragments, null, &.{});
}
pub fn compileReportedWithReferencesAndPhasesFragmentsAndHeadingAnchorsAlloc(
    a: A,
    title: []const u8,
    kind: format.BlobKind,
    language: ?[]const u8,
    language_code: []const u8,
    source: MissingText,
    display_title: ?DisplayTitle,
    link_trail: ir.LinkTrail,
    namespace_catalog: ?*const NamespaceRegistry,
    behavior_switches: ?*const BehaviorRegistry,
    image_options: ?*const ImageRegistry,
    reference_context: compiler.ReferenceDefinitions,
    fallbacks: ?*Fallbacks,
    poem_phase: ?*const PoemPhase,
    fragments: []const SourceFragment,
    heading_observation: ?*const HeadingObservation,
    heading_projection: []const HeadingSourceRange,
) ![]u8 {
    const work = if (heading_observation != null)
        try workWithHeadingOffsetsAlloc(a, title, language orelse "", source, link_trail, namespace_catalog, behavior_switches, image_options, reference_context, poem_phase, fragments)
    else
        try workAllocWithMissingFragments(a, title, language orelse "", source, link_trail, namespace_catalog, behavior_switches, image_options, reference_context, poem_phase, fragments);
    if (fallbacks) |report| {
        report.merge(work.fallbacks);
        report.template_presentation = report.template_presentation or work.rendered_templates != 0;
        report.missing_template = report.missing_template or work.unresolved_templates != 0;
    } else if (work.rendered_templates != 0 or work.unresolved_templates != 0) return error.UncompiledTemplate;
    const display_spans = try displayTitleSpansAlloc(a, display_title, language orelse "", link_trail, namespace_catalog, behavior_switches, image_options, fallbacks, poem_phase);
    try validateSpans(a, display_spans, fallbacks);
    var validate: ValidateCompilerSpans = .{ .a = a, .fallbacks = fallbacks };
    var validation_walk: CompilerWalk = .{};
    for (@constCast(work.sections)) |*section| {
        if (section.title_spans.len != 0) {
            try validation_walk.spans(&validate, section.title_spans);
            section.title = trimHeading(try compiler.plainText(a, section.title_spans));
        } else try validateText(section.title, fallbacks);
        try validation_walk.blocks(&validate, section.blocks, 0);
    }
    for (work.references) |reference| try validateSpans(a, reference.spans, fallbacks);
    for (work.media_caption_spans, 0..) |caption_spans, index| {
        try validateSpans(a, caption_spans, fallbacks);
        @constCast(work.media)[index].caption = try compiler.plainText(a, caption_spans);
    }
    var heading_registry: heading_ids.Registry = .{};
    defer heading_registry.deinit(a);
    var assign: AssignHeadings = .{ .a = a, .registry = &heading_registry, .observation = heading_observation, .projection = heading_projection };
    var heading_walk: CompilerWalk = .{};
    for (@constCast(work.sections)) |*section| {
        // The shared registry follows section headings and cell blocks in source order.
        if (section.is_heading) {
            const identity = try assign.identity(section.heading_source_offset, section.heading_authored_id, try compiler.plainText(a, section.title_spans));
            section.anchor = identity.anchor;
            section.anchor_fallback = identity.anchor_fallback;
        }
        try heading_walk.blocks(&assign, section.blocks, 0);
    }
    // DPR2 section titles remain stable plain labels for TOC/folding. A linked
    // title includes self links whose styling survives without a navigation target.
    // It also retains its final validated spans in the first ordinary heading
    // block. Readers may use this exact companion for their existing header and
    // consume it only when they actually render those spans there.
    for (@constCast(work.sections)) |*section| {
        if (section.title.len == 0) continue;
        var navigable = false;
        var explained = false;
        var styled_self = false;
        var styled = false;
        for (section.title_spans) |span| {
            explained = explained or span.explanation.len != 0;
            styled_self = styled_self or (span.self_link and span.text.len != 0);
            styled = styled or (span.kind == .text and span.text.len != 0 and span.target.len == 0 and
                (@as(u8, @bitCast(span.flags)) != 0 or span.foreground != null or span.background != null or span.classes.len != 0 or
                    span.language.len != 0 or span.direction.len != 0 or span.role != .normal));
            if ((span.kind == .link or span.kind == .external_link) and span.target.len != 0 and span.text.len != 0) {
                navigable = true;
            }
        }
        if (navigable or explained or styled_self or styled or section.title_depth != 0 or section.title_list_path.len != 0) {
            const blocks = try a.alloc(compiler.Block, section.blocks.len + 1);
            blocks[0] = .{ .kind = .heading, .spans = section.title_spans, .level = section.level, .depth = section.title_depth, .list_path = section.title_list_path, .anchor = section.anchor, .anchor_fallback = section.anchor_fallback };
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
    try std.testing.expectError(error.UncompiledPresentation, compileReportedAlloc(a, "entry", .language, "English", "en", source, null, &report));
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

    for ([_][]const u8{ "[[cat]]", "[[cat|<span style=\"font-weight:normal\">cat</span>]]" }) |display_source| {
        const linked = try compileAlloc(a, "cat", .language, "English", "en", source, .{
            .source = display_source,
            .page_title = "cat",
        });
        const linked_parsed = try codec.decodeAlloc(a, linked, "cat", .language, .{ .code = "en", .heading = "English" });
        try std.testing.expectEqual(@as(usize, 0), linked_parsed.entry.display_title.len);
    }
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

    for ([_][]const u8{ "[[cat]]", "[[cat|<span style=\"font-weight:normal\">cat</span>]]" }) |display_source| {
        var linked_report: Fallbacks = .{};
        const linked = try compileReportedAlloc(a, "cat", .language, "English", "en", source, .{
            .source = display_source,
            .page_title = "cat",
        }, &linked_report);
        try std.testing.expect(linked_report.display_title_rejected);
        const linked_parsed = try codec.decodeAlloc(a, linked, "cat", .language, .{ .code = "en", .heading = "English" });
        try std.testing.expectEqual(@as(usize, 0), linked_parsed.entry.display_title.len);
    }
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
        .{ "A [[-", "A [malformed link] -" },
        .{ "B ]]word]]", "B  [malformed link]word [malformed link]" },
        .{ "C <small>x<small> y", "C x y" },
        // The raw empty wrapper is compiled into a nonaction diagnostic.
        .{ "D [[]] E", "D [malformed link] E" },
        // Orphan table closers have a separate semantic diagnostic regression.
        .{ "{|\n* [[one]]\n|}", "one" },
        .{ "X <script>y</script> Z", "X <script>y</script> Z" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var report: Fallbacks = .{};
        // The old MediaWiki literal display oracle is not a permission to ship
        // active parsed source. Preserve it above as the before-policy witness.
        if (std.mem.eql(u8, case[0], "X <script>y</script> Z")) {
            try std.testing.expectError(error.UncompiledPresentation, compileReportedAlloc(a, "entry", .language, "English", "en", case[0], null, &report));
            try std.testing.expect(report.literal_markup);
            continue;
        }
        const bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", case[0], null, &report);
        const parsed = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
        var text: std.ArrayList(u8) = .empty;
        for (parsed.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            try text.appendSlice(a, span.text);
            if (std.mem.eql(u8, case[0], "D [[]] E")) {
                try std.testing.expectEqual(types.InlineKind.text, span.kind);
                try std.testing.expectEqualStrings("", span.target);
                try std.testing.expectEqualStrings("", span.trail);
            }
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
    // The raw malformed suffix is now diagnosed before serialization; the
    // protected prefix retains literal bytes without authorizing raw leftovers.
    _ = try compileAlloc(a, "entry", .language, "English", "en", "<nowiki>{{example}}</nowiki> [[broken", null);
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
    // A parsed tag prefix cannot be published as literal HTML. Keep the
    // compiler's independently recovered child action assertions below.
    try std.testing.expectError(error.UncompiledPresentation, compileReportedAlloc(a, "entry", .language, "English", "en", attribute_source, null, &attribute_report));
    const attribute = try workAlloc(a, "entry", "English", attribute_source, .{}, null, null, null, .{});
    const spans = attribute.sections[0].blocks[0].spans;
    // Adjacent plain-text chunks may differ across scanner entry paths. Preserve
    // the exact visible prefix/link/suffix boundary and navigation instead.
    var attribute_prefix: std.ArrayList(u8) = .empty;
    var attribute_suffix: std.ArrayList(u8) = .empty;
    var attribute_links: usize = 0;
    for (spans) |span| {
        // Work spans encode trailing text as ordinary spans, covered below.
        try std.testing.expect(!span.self_link);
        if (span.kind == .external_link) {
            try std.testing.expectEqual(@as(usize, 0), attribute_links);
            try std.testing.expectEqualStrings("https://example.test/x", span.target);
            try std.testing.expectEqualStrings("hidden", span.text);
            attribute_links += 1;
        } else {
            try std.testing.expectEqual(ir.InlineKind.text, span.kind);
            try std.testing.expectEqualStrings("", span.target);
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
    // An entity-spelled opener does not protect its body. The compiler owns
    // only the literal angles of the unmatched raw closer; independent links
    // and controls keep the same semantics as explicitly entity-spelled edges.
    const raw_closer = "&lt;nowiki>__NOEDITSECTION__[[B]]</nowiki>";
    const literal_closer = "&lt;nowiki>__NOEDITSECTION__[[B]]&lt;/nowiki>";
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, normalized, raw_closer));
    const closer_at = std.mem.indexOf(u8, normalized, raw_closer).?;
    const literal_normalized = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ normalized[0..closer_at], literal_closer, normalized[closer_at + raw_closer.len ..] });
    for ([_][]const u8{ normalized, literal_normalized }) |fixture| {
        var report: Fallbacks = .{};
        const encoded = try compileReportedAlloc(a, "entry", .language, "English", "en", fixture, null, &report);
        try std.testing.expect(!report.literal_markup);
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
    // Check compiler provenance before DPR2 discards this internal distinction.
    var renderer: compiler.Renderer = .{ .a = a, .context = .{} };
    const blocks = try renderer.renderBody(raw_closer);
    var literal_angles: usize = 0;
    var body_links: usize = 0;
    for (blocks) |block| for (block.spans) |span| {
        if (std.mem.eql(u8, span.text, "<") or std.mem.eql(u8, span.text, ">")) {
            try std.testing.expect(span.provenance == .entity_literal);
            try std.testing.expect(span.kind == .text and !span.generated_diagnostic);
            literal_angles += 1;
        }
        if (span.kind == .link) {
            try std.testing.expectEqualStrings("B", span.target);
            try std.testing.expect(span.provenance == .parsed);
            body_links += 1;
        }
    };
    // Entity-authored opening '<', plus both compiler-owned closing angles.
    try std.testing.expectEqual(@as(usize, 3), literal_angles);
    try std.testing.expectEqual(@as(usize, 1), body_links);
    const raw = [_]compiler.Span{.{ .text = "</nowiki>" }};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &raw, null));
}

test "post-expansion reconstructed source hooks keep body actions active through DPR2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // stripExpandedComments asserts these exact handoff spellings for generated
    // sour<!--x-->ce and syntax<!--x-->highlight openers. Their strip hooks ran
    // before comment removal; only the original scopes below protect their body.
    for ([_][]const u8{ "source", "syntaxhighlight" }) |tag| {
        const normalized = try std.fmt.allocPrint(a, "&lt;{s}>[[cat]] __NOEDITSECTION__</{s}>\n\n<{s}>[[protected]] __NOEDITSECTION__</{s}>", .{ tag, tag, tag, tag });
        var renderer: compiler.Renderer = .{ .a = a, .context = .{} };
        const blocks = try renderer.renderBody(normalized);
        var parsed_links: usize = 0;
        for (blocks) |block| for (block.spans) |span| {
            if (span.kind == .link) {
                try std.testing.expectEqualStrings("cat", span.target);
                try std.testing.expect(span.provenance == .parsed);
                parsed_links += 1;
            }
        };
        try std.testing.expectEqual(@as(usize, 1), parsed_links);
        var report: Fallbacks = .{};
        const encoded = try compileReportedAlloc(a, "entry", .language, "English", "en", normalized, null, &report);
        try std.testing.expect(!report.literal_markup);
        const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
        var visible: std.ArrayList(u8) = .empty;
        var links: usize = 0;
        for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            try visible.appendSlice(a, span.text);
            if (span.kind == .link) {
                try std.testing.expectEqualStrings("cat", span.target);
                links += 1;
            }
        };
        try std.testing.expectEqual(@as(usize, 1), links);
        try std.testing.expect(std.mem.indexOf(u8, visible.items, try std.fmt.allocPrint(a, "<{s}>cat </{s}>", .{ tag, tag })) != null);
        try std.testing.expect(std.mem.indexOf(u8, visible.items, "[[protected]]") != null);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, visible.items, "__NOEDITSECTION__"));
        const raw = [_]compiler.Span{.{ .text = try std.fmt.allocPrint(a, "</{s}>", .{tag}) }};
        try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &raw, null));
    }
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

test "unlinked styled headings retain spans anchors and final sense indices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sources = [_][]const u8{
        "=== <b>Noun</b> ===\n# definition\n#: example\n",
        "=== <i>Noun</i> ===\n# definition\n#: example\n",
        "=== <span style=\"color:red\">Noun</span> ===\n# definition\n#: example\n",
        "=== <span class=label lang=fr dir=rtl>Noun</span> ===\n# definition\n#: example\n",
    };
    for (sources, 0..) |source, i| {
        const encoded = try compileAlloc(a, "entry", .language, "English", "en", source, null);
        const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
        const section = decoded.entry.sections[0];
        try std.testing.expectEqualStrings("Noun", section.title);
        try std.testing.expectEqualStrings("Noun", section.anchor);
        try std.testing.expectEqual(@as(usize, 3), section.blocks.len);
        const heading = section.blocks[0];
        try std.testing.expect(heading.kind == .heading and heading.level == section.level);
        try std.testing.expectEqualStrings(section.anchor, heading.anchor);
        const span = heading.spans[0];
        try std.testing.expect(span.kind == .text and span.target.len == 0);
        try std.testing.expectEqualStrings("Noun", span.text);
        switch (i) {
            0 => try std.testing.expect(span.bold),
            1 => try std.testing.expect(span.italic),
            2 => try std.testing.expectEqualStrings("#ff0000", span.foreground.?),
            3 => {
                try std.testing.expectEqualStrings("label", span.classes);
                try std.testing.expectEqualStrings("fr", span.language);
                try std.testing.expectEqualStrings("rtl", span.direction);
            },
            else => unreachable,
        }
        const lexeme = decoded.entry.organization.lexemes[0];
        try std.testing.expectEqualSlices(usize, &.{0}, lexeme.introduction);
        try std.testing.expectEqual(@as(usize, 1), lexeme.definitions[0].block);
        try std.testing.expectEqualSlices(usize, &.{2}, lexeme.definitions[0].examples);
        try std.testing.expectEqualStrings("definition", section.blocks[1].spans[0].text);
        try std.testing.expectEqualStrings("example", section.blocks[2].spans[0].text);
    }
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

test "self link heading companions preserve styling and final layout without navigation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "=== [[Page|<span class=label>''Noun''</span>]] ===\n# first definition\n#: first example\n=== [[Other|Noun]] ===\n# second definition\n#: second example\n";
    const encoded = try compileAlloc(a, "Page", .language, "English", "en", source, null);
    const decoded = try codec.decodeAlloc(a, encoded, "Page", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqual(@as(usize, 2), decoded.entry.sections.len);
    try std.testing.expectEqual(@as(usize, 2), decoded.entry.organization.lexemes.len);
    for (decoded.entry.sections, decoded.entry.organization.lexemes, 0..) |section, lexeme, index| {
        try std.testing.expectEqualStrings("Noun", section.title);
        try std.testing.expectEqual(@as(usize, 3), section.blocks.len);
        const heading = section.blocks[0];
        try std.testing.expect(heading.kind == .heading);
        try std.testing.expectEqual(section.level, heading.level);
        try std.testing.expectEqual(@as(usize, 1), heading.spans.len);
        const span = heading.spans[0];
        try std.testing.expectEqualStrings("Noun", span.text);
        if (index == 0) {
            try std.testing.expect(span.kind == .text and span.target.len == 0 and span.bold and span.italic);
            try std.testing.expect(std.mem.indexOf(u8, span.classes, "mw-selflink selflink") != null);
            try std.testing.expect(std.mem.indexOf(u8, span.classes, "label") != null);
        } else {
            try std.testing.expect(span.kind == .link);
            try std.testing.expectEqualStrings("Other", span.target);
        }
        try std.testing.expectEqual(index, lexeme.section);
        try std.testing.expectEqualSlices(usize, &.{0}, lexeme.introduction);
        try std.testing.expectEqual(@as(usize, 1), lexeme.definitions.len);
        try std.testing.expectEqual(@as(usize, 1), lexeme.definitions[0].block);
        try std.testing.expectEqualSlices(usize, &.{2}, lexeme.definitions[0].examples);
    }
    const plain_bytes = try compileAlloc(a, "Page", .language, "English", "en", "==Plain==\nbody", null);
    const plain = try codec.decodeAlloc(a, plain_bytes, "Page", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqual(@as(usize, 1), plain.entry.sections[0].blocks.len);
    try std.testing.expect(plain.entry.sections[0].blocks[0].kind == .paragraph);
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
    // An unrelated rejected action does not grant a page-wide waiver for
    // still-uncompiled parsed text outside its diagnostic label.
    var outside_report: Fallbacks = .{ .rejected_external_target = true };
    const outside = [_]compiler.Span{.{ .kind = .text, .text = "[[literal outside", .provenance = .parsed }};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &outside, &outside_report));
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
    try std.testing.expectEqualStrings("ቆጣሪ", decoded.entry.sections[2].blocks[0].spans[0].text);
    try std.testing.expectEqualStrings("የአገር ኮድ", decoded.entry.sections[3].blocks[0].spans[0].text);
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

test "literal closing URL braces compile strictly and preserve exact DPR2 targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { source: []const u8, target: []const u8, visible: []const u8, superscript: bool = false }{
        // Source-derived URL shape from ko-attest/data; volume is illustrative,
        // not an assertion about the unsaved failing page's runtime pairs order.
        .{ .source = "<sup>[https://find.됬.xyz/source?name=석보상절03}}]</sup>", .target = "https://find.됬.xyz/source?name=석보상절03}}", .visible = "[1]", .superscript = true },
        .{ .source = "https://example.test/a}}tail", .target = "https://example.test/a}}tail", .visible = "https://example.test/a}}tail" },
        .{ .source = "[https://example.test/a}} <b>label</b>]", .target = "https://example.test/a}}", .visible = "label" },
        .{ .source = "[https://example.test/a&#125;&#125;]", .target = "https://example.test/a}}", .visible = "[1]" },
        .{ .source = "https://example.test/a&#125;&#125;tail", .target = "https://example.test/a}}tail", .visible = "https://example.test/a}}tail" },
        .{ .source = "https://example.test/a%7D%7Dtail", .target = "https://example.test/a%7D%7Dtail", .visible = "https://example.test/a%7D%7Dtail" },
    };
    for (cases) |item| {
        const encoded = try compileAlloc(a, "closing braces", .language, "Middle Korean", "okm", item.source, null);
        const decoded = try codec.decodeAlloc(a, encoded, "closing braces", .language, .{ .code = "okm", .heading = "Middle Korean" });
        var visible: std.ArrayList(u8) = .empty;
        var actions: usize = 0;
        for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            try visible.appendSlice(a, span.text);
            try visible.appendSlice(a, span.trail);
            if (span.kind == .external_link) {
                actions += 1;
                try std.testing.expectEqualStrings(item.target, span.target);
                try std.testing.expectEqual(item.superscript, span.superscript);
            }
        };
        try std.testing.expect(actions != 0);
        try std.testing.expectEqualStrings(item.visible, visible.items);
    }
    for ([_][]const u8{
        "https://example.test/{{missing}}",
        "[https://example.test/{{missing}}]",
        "[https://example.test/&#123;&#123;missing&#125;&#125;]",
    }) |source| try std.testing.expectError(error.UncompiledTemplate, compileAlloc(a, "uncompiled", .language, "English", "en", source, null));
    // A URL-shaped internal action still does not acquire the URL exception.
    const internal = [_]compiler.Span{.{ .kind = .link, .text = "label", .target = "https://example.test/a}}", .provenance = .protected_literal }};
    try std.testing.expectError(error.UncompiledTemplate, validateSpans(a, &internal, null));
    // Nor does the literal URL run exempt ordinary visible markup elsewhere.
    try std.testing.expectError(error.UncompiledTemplate, compileAlloc(a, "uncompiled label", .language, "English", "en", "https://example.test/a}} {{missing}}", null));
}

test "physical colon heading metadata survives full document compilation and strict decode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const branches = [_]struct { target: []const u8, label: []const u8 }{
        .{ .target = "templlar/conj.BEN", .label = "la conchugazión benasquesa" },
        .{ .target = "templlar/conj.RIB", .label = "la conchugazión ribagorzana" },
    };
    for (branches) |branch| {
        const source = try std.fmt.allocPrint(a, "<h4>__NOEDITSECTION__\n:''Se beiga '''[[{s}|{s}]]''' d'este berbo.''</h4>after\n<h4>[[Normal|normal]]</h4>\nfollowing", .{ branch.target, branch.label });
        const expected = try std.fmt.allocPrint(a, "Se beiga {s} d'este berbo.", .{branch.label});
        const payload = try compileAlloc(a, "templlar", .language, "aragonés", "an", source, null);
        const decoded = try codec.decodeAlloc(a, payload, "templlar", .language, .{ .code = "an", .heading = "aragonés" });
        try std.testing.expectEqual(@as(usize, 2), decoded.entry.sections.len);
        const first = decoded.entry.sections[0];
        try std.testing.expectEqualStrings(expected, first.title);
        try std.testing.expectEqual(@as(u8, 4), first.level);
        try std.testing.expectEqual(@as(usize, 2), first.blocks.len);
        const heading_block = first.blocks[0];
        try std.testing.expect(heading_block.kind == .heading);
        try std.testing.expectEqual(@as(u8, 4), heading_block.level);
        try std.testing.expectEqual(@as(u8, 1), heading_block.depth);
        try std.testing.expectEqualStrings(":", heading_block.list_path);
        var text: std.ArrayList(u8) = .empty;
        var actions: usize = 0;
        for (heading_block.spans) |span| {
            try text.appendSlice(a, span.text);
            try text.appendSlice(a, span.trail);
            try std.testing.expect(span.italic);
            if (span.kind == .link) {
                actions += 1;
                try std.testing.expectEqualStrings(branch.target, span.target);
                try std.testing.expectEqualStrings(branch.label, span.text);
                try std.testing.expect(span.bold);
            }
        }
        try std.testing.expectEqualStrings(expected, text.items);
        try std.testing.expectEqual(@as(usize, 1), actions);
        try std.testing.expect(first.blocks[1].kind == .paragraph and first.blocks[1].depth == 0);
        try std.testing.expectEqualStrings("after", first.blocks[1].spans[0].text);
        const next = decoded.entry.sections[1];
        try std.testing.expectEqualStrings("normal", next.title);
        try std.testing.expectEqual(@as(usize, 2), next.blocks.len);
        try std.testing.expect(next.blocks[0].kind == .heading and next.blocks[0].depth == 0);
        try std.testing.expectEqualStrings("", next.blocks[0].list_path);
        try std.testing.expectEqualStrings("Normal", next.blocks[0].spans[0].target);
        try std.testing.expectEqualStrings("following", next.blocks[1].spans[0].text);
    }
    // Indentation is semantic even without a navigable/explained heading label.
    const plain = try compileAlloc(a, "entry", .language, "English", "en", "<h4>\n:plain</h4>", null);
    const decoded_plain = try codec.decodeAlloc(a, plain, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqual(@as(usize, 1), decoded_plain.entry.sections.len);
    const plain_section = decoded_plain.entry.sections[0];
    try std.testing.expectEqualStrings("plain", plain_section.title);
    try std.testing.expectEqual(@as(usize, 1), plain_section.blocks.len);
    try std.testing.expect(plain_section.blocks[0].kind == .heading and plain_section.blocks[0].level == 4 and plain_section.blocks[0].depth == 1);
    try std.testing.expectEqualStrings(":", plain_section.blocks[0].list_path);
    try std.testing.expectEqualStrings("plain", plain_section.blocks[0].spans[0].text);
}

test "reported missing internal targets encode semantic diagnostic without rejected link syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "==English==\n===Adjective===\n{|\n| Ealla ōðra ansīena: [[{{{Othera_declinunga}}}|{{{Othera_declinunga}}}]]\n|}\n";
    try std.testing.expectError(error.UncompiledTemplate, compileAlloc(a, "first", .language, "English", "en", source, null));
    var report: Fallbacks = .{};
    const bytes = try compileReportedAlloc(a, "first", .language, "English", "en", source, null, &report);
    try std.testing.expect(report.literal_markup and report.missing_template);
    const decoded = try codec.decodeAlloc(a, bytes, "first", .language, .{ .code = "en", .heading = "English" });
    var found = false;
    for (decoded.entry.sections) |section| for (section.blocks) |block_value| {
        if (block_value.table) |table_value| for (table_value.rows) |row| for (row.cells) |cell| for (cell.spans) |span| {
            try std.testing.expect(span.kind == .text);
            try std.testing.expectEqualStrings("", span.target);
            try std.testing.expect(std.mem.indexOf(u8, span.text, "[[") == null);
            try std.testing.expect(std.mem.indexOf(u8, span.text, "{{{") == null);
            found = found or std.mem.indexOf(u8, span.text, "[missing parameter]") != null;
        };
    };
    try std.testing.expect(found);
    const standalone_source = "==English==\n===Verb===\n{|\n| <small>{{{stem}}}</small>\n|}\n";
    // A pre-existing caller diagnostic must survive classification and encoding.
    var standalone_report: Fallbacks = .{ .malformed_table = true };
    const standalone_bytes = try compileReportedAlloc(a, "confegurar", .language, "English", "en", standalone_source, null, &standalone_report);
    try std.testing.expect(standalone_report.malformed_table and standalone_report.missing_template);
    const standalone_decoded = try codec.decodeAlloc(a, standalone_bytes, "confegurar", .language, .{ .code = "en", .heading = "English" });
    var standalone_found = false;
    for (standalone_decoded.entry.sections) |section| for (section.blocks) |block_value| {
        if (block_value.table) |table_value| for (table_value.rows) |row| for (row.cells) |cell| for (cell.spans) |span| {
            if (std.mem.eql(u8, span.text, "[missing parameter]")) {
                try std.testing.expect(span.kind == .text and span.small);
                try std.testing.expectEqualStrings("", span.target);
                standalone_found = true;
            }
        };
    };
    try std.testing.expect(standalone_found);
}

pub fn compileReportedWithOptionsAndPhasesAlloc(
    a: A,
    title: []const u8,
    kind: format.BlobKind,
    language: ?[]const u8,
    language_code: []const u8,
    source: MissingText,
    display_title: ?DisplayTitle,
    link_trail: ir.LinkTrail,
    namespace_catalog: ?*const NamespaceRegistry,
    behavior_switches: ?*const BehaviorRegistry,
    image_options: ?*const ImageRegistry,
    fallbacks: ?*Fallbacks,
    poem_phase: ?*const PoemPhase,
) ![]u8 {
    return compileReportedWithReferencesAndPhasesFragmentsAlloc(a, title, kind, language, language_code, source, display_title, link_trail, namespace_catalog, behavior_switches, image_options, .{}, fallbacks, poem_phase, &.{});
}

test "authenticated missing target survives page copies and preserves nonaction label style trail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var page: missing_dependency.Page = .{};
    const generated = try page.missing(a, "Template:language", "[[:Template:language]]");
    var joined: missing_dependency.Builder = .{};
    try joined.append(a, MissingText.untracked("__TOC__\n__TOC__\n==English==\n[https://example.test/first]\n[[x"));
    try joined.append(a, generated);
    try joined.append(a, MissingText.untracked("|''<span lang=la class=Latn>ferre</span>'']]s\n"));
    // Unrelated transformed text never invalidates this independently exact range.
    try joined.append(a, MissingText.transformed("unrelated Lua text"));
    const tracked = try joined.finish(a);
    const metadata = try missing_dependency.encode(a, tracked, MissingText.untracked(""), page.occurrences.items);
    var phase = try missing_dependency.decode(a, metadata, tracked.bytes, "");
    defer phase.deinit();
    const trail: ir.LinkTrail = .{ .contains_fn = struct {
        fn contains(_: ?*const anyopaque, cp: u21) bool {
            return cp == 's';
        }
    }.contains };
    var report: Fallbacks = .{};
    const bytes = try compileReportedWithOptionsAndPhasesAlloc(a, "host", .language, "English", "en", phase.output(), null, trail, null, null, null, &report, null);
    const decoded = try codec.decodeAlloc(a, bytes, "host", .language, .{ .code = "en", .heading = "English" });
    var visible: std.ArrayList(u8) = .empty;
    var styled_label = false;
    for (decoded.entry.sections) |section| for (section.blocks) |item| for (item.spans) |span| {
        try visible.appendSlice(a, span.text);
        try visible.appendSlice(a, span.trail);
        if (std.mem.eql(u8, span.text, "ferre")) {
            try std.testing.expect(span.kind == .text and span.target.len == 0);
            try std.testing.expect(span.italic);
            try std.testing.expectEqualStrings("la", span.language);
            try std.testing.expect(std.mem.indexOf(u8, span.classes, "Latn") != null);
            styled_label = true;
        }
        if (std.mem.indexOf(u8, span.text, "missing template") != null)
            try std.testing.expect(span.kind == .text and span.target.len == 0);
    };
    try std.testing.expect(styled_label and report.literal_markup and report.missing_template);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "ferres [missing template]") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "Template:language") == null);
    // This compiler remains strict when no build report owns source diagnostics.
    try std.testing.expectError(error.UncompiledTemplate, compileReportedWithOptionsAndPhasesAlloc(a, "host", .language, "English", "en", phase.output(), null, trail, null, null, null, null, null));
}

test "identical authored unknown and protected target bytes cannot authorize missing diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "[[x[[:Template:language]]|label]]";
    for ([_]MissingText{ MissingText.untracked(source), MissingText.transformed(source) }) |tracked| {
        var report: Fallbacks = .{};
        const bytes = try compileReportedWithOptionsAndPhasesAlloc(a, "host", .language, "English", "en", tracked, null, .{}, null, null, null, &report, null);
        const decoded = try codec.decodeAlloc(a, bytes, "host", .language, .{ .code = "en", .heading = "English" });
        for (decoded.entry.sections) |section| for (section.blocks) |item| for (item.spans) |span|
            try std.testing.expect(std.mem.indexOf(u8, span.text, "[missing template]") == null);
        try std.testing.expect(!report.missing_template);
    }
    var page: missing_dependency.Page = .{};
    const generated = try page.missing(a, "Template:language", source);
    var literal: missing_dependency.Builder = .{};
    try literal.append(a, MissingText.untracked("<nowiki>"));
    try literal.append(a, generated);
    try literal.append(a, MissingText.untracked("</nowiki>"));
    var report: Fallbacks = .{};
    const bytes = try compileReportedWithOptionsAndPhasesAlloc(a, "host", .language, "English", "en", try literal.finish(a), null, .{}, null, null, null, &report, null);
    const decoded = try codec.decodeAlloc(a, bytes, "host", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualStrings(source, decoded.entry.sections[0].blocks[0].spans[0].text);
    try std.testing.expect(!report.missing_template);
}

test "authenticated missing target copied into wiki caption and cell stays nonaction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var page: missing_dependency.Page = .{};
    const generated = try page.missing(a, "Template:language", "[[:Template:language]]");
    var source: missing_dependency.Builder = .{};
    try source.append(a, MissingText.untracked("==English==\n{|\n|+ [[x"));
    try source.append(a, generated);
    try source.append(a, MissingText.untracked("|caption]]\n| [[x"));
    try source.append(a, generated);
    try source.append(a, MissingText.untracked("|<small>cell</small>]]\n|}\n"));
    var report: Fallbacks = .{};
    const bytes = try compileReportedWithOptionsAndPhasesAlloc(a, "host", .language, "English", "en", try source.finish(a), null, .{}, null, null, null, &report, null);
    const decoded = try codec.decodeAlloc(a, bytes, "host", .language, .{ .code = "en", .heading = "English" });
    var caption_found = false;
    var cell_found = false;
    for (decoded.entry.sections) |section| for (section.blocks) |item| {
        if (item.table) |table| {
            var caption: std.ArrayList(u8) = .empty;
            for (table.caption) |span| {
                try std.testing.expect(span.kind == .text and span.target.len == 0);
                try caption.appendSlice(a, span.text);
            }
            caption_found = caption_found or std.mem.indexOf(u8, caption.items, "caption [missing template]") != null;
            for (table.rows) |row| for (row.cells) |cell| {
                var visible: std.ArrayList(u8) = .empty;
                var small_label = false;
                for (cell.spans) |span| {
                    try std.testing.expect(span.kind == .text and span.target.len == 0);
                    try visible.appendSlice(a, span.text);
                    if (std.mem.eql(u8, span.text, "cell")) small_label = span.small;
                }
                cell_found = cell_found or (small_label and std.mem.indexOf(u8, visible.items, "cell [missing template]") != null);
            };
        }
    };
    try std.testing.expect(caption_found and cell_found and report.missing_template and report.literal_markup);
}

test "empty rendered missing-target label emits marker before authored trail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", "<small></small>", "<span lang=la></span>" }) |label| {
        var page: missing_dependency.Page = .{};
        const generated = try page.missing(a, "Template:language", "[[:Template:language]]");
        var source: missing_dependency.Builder = .{};
        try source.append(a, MissingText.untracked("[[x"));
        try source.append(a, generated);
        try source.append(a, MissingText.untracked("|"));
        try source.append(a, MissingText.untracked(label));
        try source.append(a, MissingText.untracked("]]s"));
        const trail: ir.LinkTrail = .{ .contains_fn = struct {
            fn contains(_: ?*const anyopaque, cp: u21) bool {
                return cp == 's';
            }
        }.contains };
        var report: Fallbacks = .{};
        const bytes = try compileReportedWithOptionsAndPhasesAlloc(a, "host", .language, "English", "en", try source.finish(a), null, trail, null, null, null, &report, null);
        const decoded = try codec.decodeAlloc(a, bytes, "host", .language, .{ .code = "en", .heading = "English" });
        var visible: std.ArrayList(u8) = .empty;
        for (decoded.entry.sections) |section| for (section.blocks) |item| for (item.spans) |span| {
            try std.testing.expect(span.kind == .text and span.target.len == 0);
            try visible.appendSlice(a, span.text);
            try visible.appendSlice(a, span.trail);
        };
        try std.testing.expectEqualStrings("[missing template]s", visible.items);
    }
}

test "display-title-only missing target retains strict unreported refusal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var page: missing_dependency.Page = .{};
    const generated = try page.missing(a, "Template:language", "[[:Template:language]]");
    var source: missing_dependency.Builder = .{};
    try source.append(a, MissingText.untracked("[[x"));
    try source.append(a, generated);
    try source.append(a, MissingText.untracked("|label]]"));
    const tracked = try source.finish(a);
    // Refusal precedes both mismatching and coincidentally matching plain titles.
    for ([_][]const u8{ "host", "label [missing template]" }) |title| {
        try std.testing.expectError(error.UncompiledTemplate, displayTitleSpansAlloc(a, .{ .source = tracked.bytes, .page_title = title, .missing = tracked }, "English", .{}, null, null, null, null, null));
    }
}

test "malformed source recovery roundtrip stores diagnostics not active syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { source: []const u8, visible: []const u8, actions: usize, marker_bold: ?bool = null, bold_closer: bool = false }{
        .{ .source = "before {Wendung|en|run}} after", .visible = "before [malformed template] after", .actions = 0 },
        .{ .source = "[rīmcræftig]] (cræftig in [[rīmung]]e)", .visible = "rīmcræftig [malformed link] (cræftig in rīmunge)", .actions = 2 },
        .{ .source = "([[[[irregular]]]])", .visible = "(irregular [malformed link])", .actions = 1 },
        .{ .source = "'''[[[[taking]]s]]'''", .visible = "takings [malformed link]", .actions = 2 },
        .{ .source = "[[prefix [[taking]] suffix]]", .visible = "prefix taking suffix [malformed link]", .actions = 1 },
        .{ .source = "[[[[taking]]|label]]", .visible = "taking|label [malformed link]", .actions = 1 },
        .{ .source = "[[Engle]] [[-", .visible = "Engle [malformed link] -", .actions = 1 },
        .{ .source = "[[bótian]] (bet weorðan]]", .visible = "bótian (bet weorðan [malformed link]", .actions = 1 },
        .{ .source = "[[khrisma]", .visible = "khrisma [malformed link]", .actions = 0 },
        // Keep the authored outside bracket separate from the diagnostic close.
        .{ .source = "[[taking#x[y]]]", .visible = "taking#x[y [malformed link] ]", .actions = 0 },
        .{ .source = "[[]]<b>]</b>", .visible = "[malformed link] ]", .actions = 0, .marker_bold = false, .bold_closer = true },
        .{ .source = "{{broken]", .visible = "[malformed template] ]", .actions = 0 },
        .{ .source = "[<b>[[]]</b>", .visible = "[ [malformed link]", .actions = 0, .marker_bold = true },
        .{ .source = "[[gacat\nto]]w", .visible = "gacat tow [malformed link]", .actions = 0 },
    };
    for (cases) |case| {
        var report: Fallbacks = .{};
        const encoded = try compileReportedAlloc(a, "fixture", .language, "English", "en", case.source, null, &report);
        const decoded = try codec.decodeAlloc(a, encoded, "fixture", .language, .{ .code = "en", .heading = "English" });
        var visible: std.ArrayList(u8) = .empty;
        var actions: usize = 0;
        var bold_closers: usize = 0;
        for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            try visible.appendSlice(a, span.text);
            try visible.appendSlice(a, span.trail);
            if (span.kind == .link) actions += 1;
            if (std.mem.indexOf(u8, span.text, "[malformed") != null) {
                try std.testing.expect(span.kind == .text);
                try std.testing.expectEqualStrings("", span.target);
                if (case.marker_bold) |bold| try std.testing.expectEqual(bold, span.bold);
            } else if (case.bold_closer and span.bold) {
                try std.testing.expectEqualStrings("]", std.mem.trim(u8, span.text, " "));
                try std.testing.expect(span.kind == .text);
                try std.testing.expectEqualStrings("", span.target);
                bold_closers += 1;
            }
        };
        if (case.bold_closer) try std.testing.expectEqual(@as(usize, 1), bold_closers);
        try std.testing.expectEqualStrings(case.visible, visible.items);
        try std.testing.expectEqual(case.actions, actions);
        try std.testing.expect(report.literal_markup and !report.missing_template);
        try std.testing.expect(std.mem.indexOf(u8, encoded, "Wendung|en|run") == null);
    }
    var protected_report: Fallbacks = .{};
    const encoded = try compileReportedAlloc(a, "literal", .language, "English", "en", "<nowiki>{Wendung|en|run}} [[broken</nowiki>", null, &protected_report);
    const decoded = try codec.decodeAlloc(a, encoded, "literal", .language, .{ .code = "en", .heading = "English" });
    var visible: std.ArrayList(u8) = .empty;
    for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| try visible.appendSlice(a, span.text);
    try std.testing.expectEqualStrings("{Wendung|en|run}} [[broken", visible.items);
    try std.testing.expect(!protected_report.literal_markup);
    var valid_report: Fallbacks = .{};
    const valid = try compileReportedAlloc(a, "multiline label", .language, "English", "en", "[[A|first\nsecond]]", null, &valid_report);
    const valid_decoded = try codec.decodeAlloc(a, valid, "multiline label", .language, .{ .code = "en", .heading = "English" });
    var valid_action = false;
    for (valid_decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        if (span.kind == .link and std.mem.eql(u8, span.target, "A")) valid_action = true;
    };
    try std.testing.expect(valid_action and !valid_report.literal_markup);
    var residual: Fallbacks = .{};
    const split = [_]compiler.Span{ .{ .text = "[" }, .{ .text = "[uncompiled", .flags = .{ .bold = true } } };
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &split, &residual));
    try std.testing.expect(residual.literal_markup);
    var authored_marker_report: Fallbacks = .{};
    const authored_marker = [_]compiler.Span{ .{ .text = "[malformed link]" }, .{ .text = "]", .flags = .{ .bold = true } } };
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &authored_marker, &authored_marker_report));
    try std.testing.expect(authored_marker_report.literal_markup);
    const generated_copy = try a.dupe(compiler.Span, &.{
        .{ .text = "[", .flags = .{ .bold = true } },
        .{ .text = "" },
        .{ .text = "[malformed link]", .generated_diagnostic = true },
        .{ .text = "" },
        .{ .text = "]", .flags = .{ .italic = true } },
    });
    var copied_report: Fallbacks = .{};
    try validateSpans(a, generated_copy, &copied_report);
    try std.testing.expectEqualStrings("[", generated_copy[0].text);
    try std.testing.expectEqualStrings("]", generated_copy[4].text);
    try std.testing.expect(generated_copy[0].flags.bold and generated_copy[4].flags.italic);
    try std.testing.expectEqualStrings(" [malformed link] ", generated_copy[2].text);
    const once = generated_copy[2].text;
    try validateSpans(a, generated_copy, &copied_report);
    try std.testing.expectEqualStrings(once, generated_copy[2].text);
}

test "invalid nowiki literal angles pass strict document compilation with active children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "<nowiki/ >[[cat]]</nowiki>", "<nowiki/ >cat</nowiki>" },
        .{ "<NoWiKi/\t>[[cat]]</nowiki>", "<NoWiKi/\t>cat</nowiki>" },
        .{ "<nowiki/attr>[[cat]]</nowiki>", "<nowiki/attr>cat</nowiki>" },
        .{ "<nowiki/[[cat]]>[[dog]]</nowiki>", "<nowiki/cat>dog</nowiki>" },
    };
    for (cases, 0..) |case, i| {
        var report: Fallbacks = .{};
        const encoded = try compileReportedAlloc(a, "fixture", .language, "English", "en", case[0], null, &report);
        const decoded = try codec.decodeAlloc(a, encoded, "fixture", .language, .{ .code = "en", .heading = "English" });
        var visible: std.ArrayList(u8) = .empty;
        var actions: usize = 0;
        for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            try visible.appendSlice(a, span.text);
            try visible.appendSlice(a, span.trail);
            if (span.kind == .link) {
                actions += 1;
                try std.testing.expect(std.mem.eql(u8, span.target, "cat") or (i == 3 and std.mem.eql(u8, span.target, "dog")));
            }
        };
        try std.testing.expectEqualStrings(case[1], visible.items);
        try std.testing.expectEqual(@as(usize, if (i == 3) 2 else 1), actions);
    }
    // The closing angle may occur inside a link label crossing the visible
    // rejected token. Token-local parsing would incorrectly sever that link.
    var crossing_report: Fallbacks = .{};
    const crossing_bytes = try compileReportedAlloc(a, "fixture", .language, "English", "en", "</nowiki [[Target|>label]]", null, &crossing_report);
    const crossing = try codec.decodeAlloc(a, crossing_bytes, "fixture", .language, .{ .code = "en", .heading = "English" });
    var crossing_visible: std.ArrayList(u8) = .empty;
    var crossing_label: std.ArrayList(u8) = .empty;
    for (crossing.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        try crossing_visible.appendSlice(a, span.text);
        try crossing_visible.appendSlice(a, span.trail);
        if (span.kind == .link) {
            try std.testing.expectEqualStrings("Target", span.target);
            try crossing_label.appendSlice(a, span.text);
            try crossing_label.appendSlice(a, span.trail);
        }
    };
    try std.testing.expectEqualStrings("</nowiki >label", crossing_visible.items);
    try std.testing.expectEqualStrings(">label", crossing_label.items);
    // Merely setting ordinary parsed text to look literal cannot bypass the guard.
    const raw = [_]compiler.Span{.{ .text = "<nowiki/ >[[still raw]]</nowiki>" }};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &raw, null));
}

test "duplicate semantic headings retain distinct page IDs and shared companion IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "=== [[A|Noun]] ===\n# first\n=== [[B|Noun]] ===\n# second\n";
    const encoded = try compileAlloc(a, "entry", .language, "English", "en", source, null);
    const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualStrings("DPR5", encoded[0..4]);
    for (decoded.entry.sections, [_][]const u8{ "Noun", "Noun_2" }) |section, anchor| {
        try std.testing.expectEqualStrings("Noun", section.title);
        try std.testing.expectEqualStrings(anchor, section.anchor);
        try std.testing.expectEqualStrings(anchor, section.blocks[0].anchor);
    }
}

test "heading projection retains another language's page-wide collision history" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const french = "==French==\n===Noun===\n# French noun\n";
    const english = "==English==\n===Noun===\n# English noun\n";
    const page = french ++ english;
    const observation = try observeHeadingAnchorsAlloc(a, "entry", MissingText.untracked(page), .{}, null, null, null, .{}, null);
    const projection = [_]HeadingSourceRange{.{ .owner_start = 0, .page_start = french.len, .len = english.len }};
    const encoded = try compileReportedWithReferencesAndPhasesFragmentsAndHeadingAnchorsAlloc(a, "entry", .language, "English", "en", MissingText.untracked(english), null, .{}, null, null, null, .{}, null, null, &.{}, &observation, &projection);
    const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualStrings("English", decoded.entry.sections[0].anchor);
    try std.testing.expectEqualStrings("Noun_2", decoded.entry.sections[1].anchor);
    try std.testing.expectEqualStrings("Noun", decoded.entry.sections[1].title);
    const wrong = [_]HeadingSourceRange{.{ .owner_start = 0, .page_start = 1, .len = english.len }};
    try std.testing.expectError(error.InvalidHeadingProjection, compileReportedWithReferencesAndPhasesFragmentsAndHeadingAnchorsAlloc(a, "entry", .language, "English", "en", MissingText.untracked(english), null, .{}, null, null, null, .{}, null, null, &.{}, &observation, &wrong));
}

test "allocated tracked fragments retain projected page-wide heading IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const french = "==French==\n===Noun===\n# French noun\n";
    const english_heading = "==English==\n";
    const english_body = "=== [[word|Noun]] ===\n# English noun\n";
    const english = english_heading ++ english_body;
    const page = french ++ english;
    const observation = try observeHeadingAnchorsAlloc(a, "entry", MissingText.untracked(page), .{}, null, null, null, .{}, null);
    const fragments = [_]SourceFragment{
        .{ .source = english_heading, .missing = try missing_dependency.slice(a, MissingText.untracked(page), french.len, french.len + english_heading.len) },
        .{ .source = english_body, .missing = try missing_dependency.slice(a, MissingText.untracked(page), french.len + english_heading.len, page.len) },
    };
    // Tracked slices own copied bytes, as Writer's recovery fragments do.
    for (fragments) |fragment| {
        try std.testing.expect(fragment.source.ptr != fragment.missing.?.bytes.ptr);
        try std.testing.expectEqualStrings(fragment.source, fragment.missing.?.bytes);
    }
    const projection = [_]HeadingSourceRange{.{ .owner_start = 0, .page_start = french.len, .len = english.len }};
    const encoded = try compileReportedWithReferencesAndPhasesFragmentsAndHeadingAnchorsAlloc(a, "entry", .language, "English", "en", MissingText.untracked(english), null, .{}, null, null, null, .{}, null, null, &fragments, &observation, &projection);
    const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualStrings("English", decoded.entry.sections[0].anchor);
    try std.testing.expectEqualStrings("Noun_2", decoded.entry.sections[1].anchor);
    try std.testing.expectEqualStrings("Noun", decoded.entry.sections[1].title);
    try std.testing.expectEqualStrings("Noun_2", decoded.entry.sections[1].blocks[0].anchor);
}

test "leading NBSP heading identities stay distinct through observation projection and DPR2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const headings = "===&nbsp;Noun===\nfirst\n===Noun===\n[[#Noun|plain heading]]\n";
    const cases = [_]struct { source: []const u8, cell: bool }{
        .{ .source = headings, .cell = false },
        .{ .source = "{|\n| intro\n" ++ headings ++ "|}\n", .cell = true },
    };
    for (cases) |case| {
        const bytes = try compileAlloc(a, "entry", .language, "English", "en", case.source, null);
        const decoded = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
        const body_blocks = if (case.cell) cell: {
            try std.testing.expectEqual(@as(usize, 1), decoded.entry.sections.len);
            const blocks = decoded.entry.sections[0].blocks[0].table.?.rows[0].cells[0].blocks.?;
            try std.testing.expectEqual(types.BlockKind.heading, blocks[1].kind);
            try std.testing.expectEqual(types.BlockKind.heading, blocks[3].kind);
            try std.testing.expectEqualStrings("_Noun", blocks[1].anchor);
            try std.testing.expectEqualStrings("Noun", blocks[3].anchor);
            break :cell blocks;
        } else sections: {
            try std.testing.expectEqual(@as(usize, 2), decoded.entry.sections.len);
            try std.testing.expectEqualStrings("Noun", decoded.entry.sections[0].title);
            try std.testing.expectEqualStrings("Noun", decoded.entry.sections[1].title);
            try std.testing.expectEqualStrings("_Noun", decoded.entry.sections[0].anchor);
            try std.testing.expectEqualStrings("Noun", decoded.entry.sections[1].anchor);
            break :sections decoded.entry.sections[1].blocks;
        };
        var links: usize = 0;
        for (body_blocks) |block| for (block.spans) |span| {
            if (span.kind == .link) {
                try std.testing.expectEqualStrings("#Noun", span.target);
                try std.testing.expectEqualStrings("plain heading", span.text);
                links += 1;
            }
        };
        try std.testing.expectEqual(@as(usize, 1), links);
        const observation = try observeHeadingAnchorsAlloc(a, "entry", MissingText.untracked(case.source), .{}, null, null, null, .{}, null);
        try std.testing.expectEqual(@as(usize, 2), observation.items.len);
        try std.testing.expectEqualStrings("_Noun", observation.items[0].anchor);
        try std.testing.expectEqualStrings("Noun", observation.items[1].anchor);
        const projection = [_]HeadingSourceRange{.{ .owner_start = 0, .page_start = 0, .len = case.source.len }};
        const projected = try compileReportedWithReferencesAndPhasesFragmentsAndHeadingAnchorsAlloc(a, "entry", .language, "English", "en", MissingText.untracked(case.source), null, .{}, null, null, null, .{}, null, null, &.{}, &observation, &projection);
        try std.testing.expectEqualSlices(u8, bytes, projected);
    }
}

test "protected and entity literal heading text remains semantic display data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "===<nowiki>[[Noun]]</nowiki>===\n# first\n===&#91;&#91;Noun&#93;&#93;===\n# second\n";
    const encoded = try compileAlloc(a, "entry", .language, "English", "en", source, null);
    const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualStrings("[[Noun]]", decoded.entry.sections[0].title);
    try std.testing.expectEqualStrings("[[Noun]]", decoded.entry.sections[0].anchor);
    try std.testing.expectEqualStrings("[[Noun]]_2", decoded.entry.sections[1].anchor);
}

test "authored HTML heading IDs reserve canonical destinations without parsing their labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "<h3 id=\"Custom&amp;ID\">Noun</h3>\n# first\n===Custom&amp;ID===\n# second\n===Noun===\n# third\n";
    const encoded = try compileAlloc(a, "entry", .language, "English", "en", source, null);
    const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualStrings("Noun", decoded.entry.sections[0].title);
    try std.testing.expectEqualStrings("Custom&ID", decoded.entry.sections[0].anchor);
    try std.testing.expectEqualStrings("Custom&ID_2", decoded.entry.sections[1].anchor);
    try std.testing.expectEqualStrings("Noun", decoded.entry.sections[2].anchor);
}

test "authored HTML heading IDs sanitize raw whitespace before entity decoding" {
    const cases = [_]struct { source: []const u8, anchor: []const u8 }{
        .{ .source = "<h3 id=\" Custom  ID \">Noun</h3>\nbody", .anchor = "Custom_ID" },
        .{ .source = "<h3 id=\"\tCustom\r\n ID\t\">Noun</h3>\nbody", .anchor = "Custom_ID" },
        .{ .source = "<h3 id=\"   \">Noun</h3>\nbody", .anchor = "Noun" },
        .{ .source = "<h3 id=\"&#32;Custom&#32;&#32;ID&#32;\">Noun</h3>\nbody", .anchor = "_Custom__ID_" },
        .{ .source = "<h3 id=First ID=Last>Noun</h3>\nbody", .anchor = "Last" },
        .{ .source = "<h3 id=First id>Noun</h3>\nbody", .anchor = "Noun" },
        .{ .source = "<h3 id=\"Custom&#9;ID\">Noun</h3>\nbody", .anchor = "Custom_ID" },
        .{ .source = "<h3 id=\"Custom&#12;ID\">Noun</h3>\nbody", .anchor = "Custom_ID" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const encoded = try compileAlloc(a, "entry", .language, "English", "en", case.source, null);
        const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
        try std.testing.expectEqualStrings("Noun", decoded.entry.sections[0].title);
        try std.testing.expectEqualStrings(case.anchor, decoded.entry.sections[0].anchor);
        try std.testing.expectEqualStrings("", decoded.entry.sections[0].anchor_fallback);
        const observation = try observeHeadingAnchorsAlloc(a, "entry", MissingText.untracked(case.source), .{}, null, null, null, .{}, null);
        try std.testing.expectEqual(@as(usize, 1), observation.items.len);
        try std.testing.expectEqualStrings(case.anchor, observation.items[0].anchor);
        try std.testing.expectEqualStrings("", observation.items[0].anchor_fallback);
    }
}

test "legacy destination aliases and literal fallback-shaped headings retain distinct identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "=== [[A|\xc3\xa4]] ===\n# [[#.C3.A4|first]]\n=== [[B|.C3.A4]] ===\n# literal\n=== [[C|\xc3\xa4]] ===\n# [[#.C3.A4_3|later]]\n";
    const encoded = try compileAlloc(a, "entry", .language, "English", "en", source, null);
    const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
    const primary = [_][]const u8{ "\xc3\xa4", ".C3.A4_2", "\xc3\xa4_2" };
    const fallback = [_][]const u8{ ".C3.A4", "", ".C3.A4_3" };
    for (decoded.entry.sections, primary, fallback) |section, id, alias| {
        try std.testing.expectEqualStrings(id, section.anchor);
        try std.testing.expectEqualStrings(alias, section.anchor_fallback);
        try std.testing.expectEqualStrings(id, section.blocks[0].anchor);
        try std.testing.expectEqualStrings(alias, section.blocks[0].anchor_fallback);
    }
    try std.testing.expectEqualStrings("#.C3.A4", decoded.entry.sections[0].blocks[1].spans[0].target);
    try std.testing.expectEqualStrings("#.C3.A4 3", decoded.entry.sections[2].blocks[1].spans[0].target);
}

test "orphan physical table closer compiles diagnostic and preserves lexical body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The final closer models the extra translation footer, after a real table.
    const source = "# prefix [[Before|before]]\n{|\n| [[Inside|cell]]\n|}\n|}</div></div>suffix [[After|after]]\n# following [[Last|last]]\n";
    var report: Fallbacks = .{};
    const bytes = try compileReportedAlloc(a, "entry", .language, "Arabic", "ar", source, null, &report);
    const decoded = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "ar", .heading = "Arabic" });
    var visible: std.ArrayList(u8) = .empty;
    var tables: usize = 0;
    var diagnostics: usize = 0;
    var before = false;
    var inside = false;
    var after = false;
    var last = false;
    for (decoded.entry.sections) |section| for (section.blocks) |block| {
        for (block.spans) |span| {
            try visible.appendSlice(a, span.text);
            if (std.mem.eql(u8, span.text, "[malformed table]")) {
                diagnostics += 1;
                try std.testing.expect(span.kind == .text and span.target.len == 0);
            }
            if (span.kind == .link and std.mem.eql(u8, span.target, "Before")) before = true;
            if (span.kind == .link and std.mem.eql(u8, span.target, "After")) after = true;
            if (span.kind == .link and std.mem.eql(u8, span.target, "Last")) last = true;
        }
        if (block.table) |table| {
            tables += 1;
            for (table.rows) |row| for (row.cells) |cell| for (cell.spans) |span| {
                if (span.kind == .link and std.mem.eql(u8, span.target, "Inside")) inside = true;
            };
        }
    };
    try std.testing.expect(report.malformed_table and report.literal_markup);
    try std.testing.expectEqual(@as(usize, 1), tables);
    try std.testing.expectEqual(@as(usize, 1), diagnostics);
    try std.testing.expect(before and inside and after and last);
    for ([_][]const u8{ "prefix", "suffix", "following" }) |word|
        try std.testing.expect(std.mem.indexOf(u8, visible.items, word) != null);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "|}") == null);

    // A later physical LF stays eligible even inside an inline table capture.
    for ([_][]const u8{ "|}\nAfter", "<span>first\n|}After\n{|\n| cell\n|}\n</span>" }) |simple_source| {
        var simple_report: Fallbacks = .{};
        const simple = try compileReportedAlloc(a, "entry", .language, "English", "en", simple_source, null, &simple_report);
        const simple_decoded = try codec.decodeAlloc(a, simple, "entry", .language, .{ .code = "en", .heading = "English" });
        visible.clearRetainingCapacity();
        for (simple_decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span|
            try visible.appendSlice(a, span.text);
        try std.testing.expect(std.mem.indexOf(u8, visible.items, "[malformed table]") != null);
        try std.testing.expect(std.mem.indexOf(u8, visible.items, "After") != null);
        try std.testing.expect(simple_report.malformed_table and simple_report.literal_markup);
    }
    // The publication boundary still rejects any leaked parsed delimiter.
    const leaked = [_]compiler.Span{.{ .text = "|}" }};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &leaked, null));
}

test "orphan table recovery leaves inline protected entity and matched controls unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var inline_report: Fallbacks = .{};
    try std.testing.expectError(error.UncompiledPresentation, compileReportedAlloc(a, "entry", .language, "English", "en", "before |} after", null, &inline_report));
    try std.testing.expect(!inline_report.malformed_table);
    // Neither recursive same-line formatting nor a protected empty opener
    // promotes the following inline token to a physical table boundary.
    for ([_][]const u8{
        "[[Before]]|} after",
        "<small>|}</small>",
        "<nowiki/>|}suffix",
        "prefix <span>|} inline\n{|\n| cell\n|}\n</span> suffix [[After]]",
        "<span data-phonos-audio=\"Sound.ogg\">|} inline\n{|\n| cell\n|}\n</span>",
        "<ul>|}<li>item [[Keep]]</li></ul>",
        "<ul><li>item [[Keep]]</li>|}</ul>",
        "<table><tr><td>|} inline\n* later [[Keep]]</td></tr></table>",
    }) |source| {
        var split_report: Fallbacks = .{};
        try std.testing.expectError(error.UncompiledPresentation, compileReportedAlloc(a, "entry", .language, "English", "en", source, null, &split_report));
        try std.testing.expect(!split_report.malformed_table);
    }
    for ([_][]const u8{ "<nowiki>|}</nowiki>", "&#124;}", "<nowiki>\n|}\n</nowiki>" }) |source| {
        var protected_report: Fallbacks = .{};
        const bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", source, null, &protected_report);
        const decoded = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
        var visible: std.ArrayList(u8) = .empty;
        for (decoded.entry.sections[0].blocks[0].spans) |span| try visible.appendSlice(a, span.text);
        try std.testing.expectEqualStrings("|}", std.mem.trim(u8, visible.items, " \t\r\n"));
        try std.testing.expect(!protected_report.malformed_table and !protected_report.literal_markup);
    }
    // The existing nested-table oracle also closes its real parent before after.
    var table_report: Fallbacks = .{};
    const nested = "{|\n|-\n| outer\n{|\n|-\n| inner\n|}\n| sibling\n|-\n| final\n|}\n# after\n";
    const bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", nested, null, &table_report);
    const decoded = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    const blocks = decoded.entry.sections[0].blocks;
    try std.testing.expect(blocks[0].table != null);
    try std.testing.expectEqual(@as(usize, 2), blocks[0].table.?.rows.len);
    const outer_table = blocks[0].table.?;
    try std.testing.expectEqual(@as(usize, 2), outer_table.rows[0].cells.len);
    try std.testing.expectEqual(@as(usize, 1), outer_table.rows[1].cells.len);
    const outer_cell = outer_table.rows[0].cells[0];
    try std.testing.expect(outer_cell.spans.len == 0 and outer_cell.nested_table == null);
    const ordered = outer_cell.blocks.?;
    try std.testing.expectEqual(@as(usize, 2), ordered.len);
    try std.testing.expectEqual(types.BlockKind.paragraph, ordered[0].kind);
    try std.testing.expectEqual(types.BlockKind.table, ordered[1].kind);
    const inner_table = ordered[1].table.?;
    try std.testing.expectEqual(@as(usize, 1), inner_table.rows.len);
    try std.testing.expectEqual(@as(usize, 1), inner_table.rows[0].cells.len);
    var cell_text: std.ArrayList(u8) = .empty;
    const segments = [_][]const types.Span{ ordered[0].spans, inner_table.rows[0].cells[0].spans };
    for (segments, 0..) |spans, index| {
        if (index != 0) try cell_text.append(a, '\n');
        for (spans) |span| {
            if (span.kind == .line_break) try cell_text.append(a, '\n') else try cell_text.appendSlice(a, span.text);
        }
    }
    try std.testing.expectEqualStrings("outer\ninner", cell_text.items);
    cell_text.clearRetainingCapacity();
    for (outer_table.rows[0].cells[1].spans) |span| try cell_text.appendSlice(a, span.text);
    try std.testing.expectEqualStrings("sibling", cell_text.items);
    cell_text.clearRetainingCapacity();
    for (outer_table.rows[1].cells[0].spans) |span| try cell_text.appendSlice(a, span.text);
    try std.testing.expectEqualStrings("final", cell_text.items);
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expect(blocks[1].table == null);
    try std.testing.expectEqualStrings("#", blocks[1].list_path);
    cell_text.clearRetainingCapacity();
    for (blocks[1].spans) |span| try cell_text.appendSlice(a, span.text);
    try std.testing.expectEqualStrings("after", cell_text.items);
    try std.testing.expect(!table_report.malformed_table and !table_report.literal_markup);
}

test "orphan template closer diagnoses Arabic source and preserves neighboring actions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Retained AR page 101981/revision 1090426 has this authored close after
    // the independent link; the native expansion preserves the same sequence.
    const source = "'''عَمِلَ''' فعل ثلاثي مجرد (المضارع يَعْمَل والمصدر [[عَمَل]]}})\n# following [[Keep|kept]]\n";
    var report: Fallbacks = .{};
    const bytes = try compileReportedAlloc(a, "entry", .language, "Arabic", "ar", source, null, &report);
    const decoded = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "ar", .heading = "Arabic" });
    var visible: std.ArrayList(u8) = .empty;
    var diagnostics: usize = 0;
    var arabic_link = false;
    var following_link = false;
    var bold_word = false;
    for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        try visible.appendSlice(a, span.text);
        if (std.mem.eql(u8, span.text, "[malformed template]")) {
            diagnostics += 1;
            try std.testing.expect(span.kind == .text and span.target.len == 0 and span.trail.len == 0);
        }
        if (span.kind == .link and std.mem.eql(u8, span.target, "عَمَل")) arabic_link = true;
        if (span.kind == .link and std.mem.eql(u8, span.target, "Keep")) following_link = true;
        if (span.bold and std.mem.indexOf(u8, span.text, "عَمِلَ") != null) bold_word = true;
    };
    try std.testing.expectEqual(@as(usize, 1), diagnostics);
    try std.testing.expect(report.literal_markup and !report.missing_template);
    try std.testing.expect(arabic_link and following_link and bold_word);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "عَمَل[malformed template])") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "following kept") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "}}") == null);

    // A rejected label cannot donate its action to the generated marker.
    var renderer: compiler.Renderer = .{ .a = a, .context = .{} };
    const spans = try renderer.parseSpans("[[Keep|'''label}}tail''']]", .{});
    var generated = false;
    var child_link = false;
    for (spans) |span| {
        if (span.generated_diagnostic) {
            generated = true;
            try std.testing.expectEqualStrings("[malformed template]", span.text);
            try std.testing.expect(span.provenance == .parsed and span.kind == .text and span.target.len == 0);
            try std.testing.expect(span.flags.bold);
        } else if (span.kind == .link) child_link = true;
    }
    try std.testing.expect(generated and child_link);
    const leaked = [_]compiler.Span{.{ .text = "}}" }};
    const split = [_]compiler.Span{ .{ .text = "}" }, .{ .text = "}", .flags = .{ .bold = true } } };
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &leaked, null));
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &split, null));
}

test "orphan template recovery preserves literal URL balanced template and parameter paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "<nowiki>}}</nowiki>", .expected = "}}" },
        .{ .source = "}<nowiki>}</nowiki>", .expected = "}}" },
        .{ .source = "<pre>}}</pre>", .expected = "}}" },
        .{ .source = "&#125;&#125;", .expected = "}}" },
        .{ .source = "https://example.test/a}}", .expected = "https://example.test/a}}" },
        .{ .source = "[https://example.test/a}}]", .expected = "[1]" },
        .{ .source = "{{{absent|kept}}}", .expected = "kept" },
        .{ .source = "{{{absent|{{{inner|nested}}}}}}", .expected = "nested" },
        .{ .source = "single } suffix", .expected = "single } suffix" },
    };
    for (cases) |case| {
        var report: Fallbacks = .{};
        const bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", case.source, null, &report);
        const decoded = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
        var visible: std.ArrayList(u8) = .empty;
        for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span|
            try visible.appendSlice(a, span.text);
        try std.testing.expectEqualStrings(case.expected, std.mem.trim(u8, visible.items, " \t\r\n"));
        try std.testing.expect(!report.literal_markup);
    }
    var balanced_report: Fallbacks = .{};
    const balanced = try compileReportedAlloc(a, "entry", .language, "English", "en", "{{MissingFixture|secret_argument_body}}", null, &balanced_report);
    try std.testing.expect(balanced_report.missing_template and !balanced_report.literal_markup);
    try std.testing.expect(std.mem.indexOf(u8, balanced, "[malformed template]") == null);
    try std.testing.expect(std.mem.indexOf(u8, balanced, "secret_argument_body") == null);
    // An empty literal node cannot authorize two surrounding parsed braces.
    try std.testing.expectError(error.UncompiledPresentation, compileAlloc(a, "entry", .language, "English", "en", "}<nowiki/>}", null));
    // Ordinary code styling is not literal authority for authored raw closers.
    var code_report: Fallbacks = .{};
    const code_bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", "<code>}}</code>", null, &code_report);
    try std.testing.expect(code_report.literal_markup);
    try std.testing.expect(std.mem.indexOf(u8, code_bytes, "[malformed template]") != null);
}

test "angle enclosed bare URLs retain literal delimiters and exact navigation bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const jstor = "http://links.jstor.org/sici?sici=0041-9907(196003)108%3A5%3C699%3A%22PFUTC%3E2.0.CO%3B2-Z";
    const cases = [_]struct { source: []const u8, target: []const u8, visible: []const u8, bold: bool = false }{
        .{ .source = "<" ++ jstor ++ ">", .target = jstor, .visible = "<" ++ jstor ++ ">" },
        .{ .source = "<HTTPS://example.test/a%3Cb%3E>", .target = "HTTPS://example.test/a%3Cb%3E", .visible = "<HTTPS://example.test/a%3Cb%3E>" },
        .{ .source = "<https://example.test/a).>", .target = "https://example.test/a", .visible = "<https://example.test/a).>" },
        .{ .source = "<b><https://example.test/a></b>", .target = "https://example.test/a", .visible = "<https://example.test/a>", .bold = true },
        .{ .source = "<https://example.test/a}}>", .target = "https://example.test/a}}", .visible = "<https://example.test/a}}>" },
    };
    for (cases) |case| {
        var report: Fallbacks = .{};
        const bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", case.source, null, &report);
        const decoded = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
        var visible: std.ArrayList(u8) = .empty;
        var action_label: std.ArrayList(u8) = .empty;
        var actions: usize = 0;
        for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            try visible.appendSlice(a, span.text);
            if (span.kind == .external_link) {
                actions += 1;
                try action_label.appendSlice(a, span.text);
                try std.testing.expectEqualStrings(case.target, span.target);
                try std.testing.expectEqual(case.bold, span.bold);
            }
            if (std.mem.eql(u8, span.text, "<")) try std.testing.expect(span.kind == .text and span.target.len == 0);
        };
        // Closing-brace URL text intentionally spans parsed and protected runs.
        try std.testing.expect(actions > 0);
        try std.testing.expectEqualStrings(case.target, action_label.items);
        try std.testing.expectEqualStrings(case.visible, visible.items);
        try std.testing.expect(!report.any());
    }
    var renderer: compiler.Renderer = .{ .a = a, .context = .{} };
    const spans = try renderer.parseSpans("<https://example.test/a> [[Keep|after]]", .{});
    try std.testing.expect(spans[0].provenance == .protected_literal and spans[0].kind == .text and spans[0].target.len == 0);
    try std.testing.expectEqualStrings("<", spans[0].text);

    // Exact retained failed expansion, including its independently malformed
    // nested wikilink. The footer repair must not drop that diagnosed child.
    const captured =
        \\
        \\== إنجليزية[[تصنيف:إنجليزية]] ==
        \\
        \\=== Etymology ===
        \\[[un-|Un-]] + [[copyright]] ([[copy]] + [[right]]) + [[-able]] + [[-s]].
        \\
        \\=== اسم ===
        \\'''uncopyrightables'''
        \\
        \\# صِيغَةُ جَمْعٍ مُفْرَدُهَا [[[[uncopyrightable]]]][[تصنيف:صيغ جمع ]]
        \\
        \\#* '''1960''', W. J. G., H. K. S. [''sic''], "Copyright" Protection for '''Uncopyrightables''': The Common-Law Doctrines", in ''University of Pennsylvania Law Review'', Vol. 108, No. 5 (Mar., 1960), pp. 699-734
        \\#* '''1969''', P Goldstein, "Federal System Ordering of the Copyright Interest", in ''Columbia Law Review'', pp. 49-92
        \\#*: [...] are further condemned by Sears and Compco's second principle for their tendency to extend the equivalent of copyright protection to statutory '''uncopyrightables'''.
        \\
        \\==== Usage notes ====
        \\* Normally hyphenated; otherwise considered a spelling/construction error by many.
        \\
        \\==== Trivia ====
        \\"Uncopyrightables" is longest word in the [[Wikipedia:English language|English language]] that does not contain any repeated letters, if plurals are allowed.
        \\
        \\==== References ====
        \\"Copyright" Protection for Uncopyrightables: The Common-Law Doctrines
        \\W. J. G., H. K. S.
        \\University of Pennsylvania Law Review, Vol. 108, No. 5 (Mar., 1960), pp. 699-734
        \\doi:10.2307/3310268 <http://links.jstor.org/sici?sici=0041-9907(196003)108%3A5%3C699%3A%22PFUTC%3E2.0.CO%3B2-Z>
    ;
    var report: Fallbacks = .{};
    const bytes = try compileReportedAlloc(a, "uncopyrightables", .language, "English", "en", captured, null, &report);
    const decoded = try codec.decodeAlloc(a, bytes, "uncopyrightables", .language, .{ .code = "en", .heading = "English" });
    var visible: std.ArrayList(u8) = .empty;
    var jstor_actions: usize = 0;
    var nested_actions: usize = 0;
    var malformed_links: usize = 0;
    for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        try visible.appendSlice(a, span.text);
        if (span.kind == .external_link and std.mem.eql(u8, span.target, jstor)) jstor_actions += 1;
        if (span.kind == .link and std.mem.eql(u8, span.target, "uncopyrightable")) nested_actions += 1;
        if (std.mem.indexOf(u8, span.text, "[malformed link]") != null) {
            malformed_links += 1;
            try std.testing.expect(span.kind == .text and span.target.len == 0);
        }
    };
    try std.testing.expectEqual(@as(usize, 1), jstor_actions);
    try std.testing.expectEqual(@as(usize, 1), nested_actions);
    try std.testing.expectEqual(@as(usize, 1), malformed_links);
    try std.testing.expect(report.literal_markup and !report.missing_template);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "doi:10.2307/3310268 <" ++ jstor ++ ">") != null);
    for ([_][]const u8{ "Federal System Ordering", "Normally hyphenated", "does not contain any repeated letters" }) |phrase|
        try std.testing.expect(std.mem.indexOf(u8, visible.items, phrase) != null);
}

test "angle URL classification leaves HTML and unresolved delimiters strict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "<http:broken>",                         "<http://>",                   "<http://example.test attribute=bad>",
        "<script>https://example.test</script>", "<https://example.test/a{|b>", "<https://example.test/a[[b]]>",
    }) |source| try std.testing.expectError(error.UncompiledPresentation, compileAlloc(a, "entry", .language, "English", "en", source, null));
    try std.testing.expectError(error.UncompiledTemplate, compileAlloc(a, "entry", .language, "English", "en", "<https://example.test/{{missing}}>", null));
    // A rejected bracketed destination retains only its independent authored label.
    var rejected_report: Fallbacks = .{};
    const rejected_bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", "[https://example.test/{{missing}} label]", null, &rejected_report);
    const rejected = try codec.decodeAlloc(a, rejected_bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    var rejected_label: std.ArrayList(u8) = .empty;
    for (rejected.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        try rejected_label.appendSlice(a, span.text);
        try std.testing.expect(span.kind == .text and span.target.len == 0);
    };
    try std.testing.expectEqualStrings("label", rejected_label.items);
    try std.testing.expect(rejected_report.rejected_external_target and !rejected_report.literal_markup and !rejected_report.missing_template);
    const cases = [_]struct { source: []const u8, visible: []const u8, actions: usize }{
        .{ .source = "<nowiki><https://example.test/a></nowiki>", .visible = "<https://example.test/a>", .actions = 0 },
        .{ .source = "&lt;https://example.test/a&gt;", .visible = "<https://example.test/a>", .actions = 1 },
        .{ .source = "https://example.test/a", .visible = "https://example.test/a", .actions = 1 },
        .{ .source = "<https://example.test/a", .visible = "<https://example.test/a", .actions = 1 },
        .{ .source = "[https://example.test/a]", .visible = "[1]", .actions = 1 },
        .{ .source = "[https://example.test/a <i>label</i>]", .visible = "label", .actions = 1 },
        .{ .source = "<span title=\"https://example.test/a\">kept</span>", .visible = "kept", .actions = 0 },
    };
    for (cases) |case| {
        const bytes = try compileAlloc(a, "entry", .language, "English", "en", case.source, null);
        const decoded = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
        var visible: std.ArrayList(u8) = .empty;
        var actions: usize = 0;
        for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            try visible.appendSlice(a, span.text);
            if (span.kind == .external_link) actions += 1;
        };
        try std.testing.expectEqualStrings(case.visible, visible.items);
        try std.testing.expectEqual(case.actions, actions);
    }
    // Even a manually inserted safe external action cannot exempt parsed HTML
    // shaped display text. Only the compiler's proved source angle is literal.
    const direct = [_]compiler.Span{.{ .text = "<http://example.test>" }};
    const split = [_]compiler.Span{ .{ .text = "<" }, .{ .kind = .external_link, .text = "http://example.test", .target = "http://example.test" }, .{ .text = ">" } };
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &direct, null));
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &split, null));
}

test "captured malformed quoted li preserves literal spelling dictionary text and translation actions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const captured =
        "== عربية[[تصنيف:عربية]] ==\n" ++
        "[[ملف:Wikipedia-logo-v2.svg|30px]] '''[https://ar.wikipedia.org/wiki/إجرياء إجرياء]''' على [[ويكيبيديا]].\n" ++
        "\n" ++
        "=== تأثيل ===\n" ++
        "من الفعل [[أَجْرَى|جرى#أجرى]]، وقد تثبت بلا همزة (≠إجريا—مثنى [[جرى|إجري]] الفعل)\n" ++
        "\n" ++
        "=== اسم ===\n" ++
        "<ol style=\"list-style-type: upper-roman\">\n" ++
        "<li\">'''إِجرياء'''</li>\n" ++
        "* طريقة عمل الشيء؛ طبيعته۔\n" ++
        "* (لسانيات) علم قواعد اللغة — ''علم الصرف والنحو''۔\n" ++
        "=== تراجم ===\n" ++
        "\n" ++
        "{| class=\"wikitable collapsible\"\n" ++
        "!لغة!!ترجمة!!إجرياء: (لسانيات) علم قواعد اللغة — ''علم الصرف والنحو''\n" ++
        "|-\n" ++
        "|إنجليزية||[[grammar]]\n" ++
        "|-\n" ++
        "|فارسيَّة||[[دستور زبان]]\n" ++
        "|-\n" ++
        "|فرنسية||[[grammaire]]\n" ++
        "|-\n" ++
        "|سريانية|| <sup>(شرقية)</sup> [[ܓܪܲܡܲܛܝܼܩܘܘܬܵܐ]]<br /><sup>(غربية)</sup> [[ܓܪܰܡܰܛܺܩܘܘܬܳܐ]]\n" ++
        "|-\n" ++
        "|صينية|| <sup>(تقليدية)</sup> [[語法]]<br /><sup>(مبسطة)</sup> [[语法]]\n" ++
        "|-\n" ++
        "|عبرانية||[[דקדוק]]\n" ++
        "|-\n" ++
        "|كردية|| <sup>(سۆراني)</sup> [[ڕێزمان]]<br /><sup>(کورمانجي)</sup> [[rêziman]]\n" ++
        "|-\n" ++
        "||لوجبان||[[gerna]]\n" ++
        "|-\n" ++
        "|ملايوية||<sup>(جاوية)</sup> [[تاتابهاس]]<br /><sup>(لاتينية)</sup> [[tatabahasa]]\n" ++
        "|-\n" ++
        "||يونانية||[[γραμματική]]\n" ++
        "|}\n" ++
        "\n" ++
        "[[تصنيف:مفردات بلا تشكيل]]";
    var report: Fallbacks = .{};
    const bytes = try compileReportedAlloc(a, "إجرياء", .language, "العربية", "ar", captured, null, &report);
    const decoded = try codec.decodeAlloc(a, bytes, "إجرياء", .language, .{ .code = "ar", .heading = "العربية" });
    const Check = struct {
        const targets = [_][]const u8{ "أَجْرَى", "جرى", "grammar", "دستور زبان", "grammaire", "gerna", "γραμματική", "דקדוק" };
        visible: std.ArrayList(u8) = .empty,
        seen: [targets.len]bool = @splat(false),
        bold: bool = false,
        superscript: bool = false,
        fn add(self: *@This(), alloc: A, values: []const types.Span) !void {
            for (values) |span| {
                try self.visible.appendSlice(alloc, span.text);
                if (span.bold and std.mem.indexOf(u8, span.text, "إِجرياء") != null) self.bold = true;
                if (span.superscript and std.mem.indexOf(u8, span.text, "تقليدية") != null) self.superscript = true;
                for (targets, 0..) |target, i| if (span.kind == .link and std.mem.eql(u8, span.target, target)) {
                    self.seen[i] = true;
                };
            }
        }
    };
    var check: Check = .{};
    for (decoded.entry.sections) |section| for (section.blocks) |block| {
        try check.add(a, block.spans);
        if (block.table) |table| for (table.rows) |row| for (row.cells) |cell| {
            try check.add(a, cell.spans);
        };
    };
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, check.visible.items, "<li\">"));
    try std.testing.expect(std.mem.indexOf(u8, check.visible.items, "</li>") == null);
    try std.testing.expect(std.mem.indexOf(u8, check.visible.items, "طريقة عمل الشيء") != null);
    try std.testing.expect(std.mem.indexOf(u8, check.visible.items, "علم قواعد اللغة") != null);
    try std.testing.expect(check.bold and check.superscript and report.literal_markup and report.unclosed_formatting);
    for (check.seen) |seen| try std.testing.expect(seen);
    // Only proved source angles are escaped; raw parsed markup stays strict.
    const raw = [_]compiler.Span{.{ .text = "<li\">" }};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &raw, null));
    // Apostrophes and malformed attributes are outside this finite token family.
    try std.testing.expectError(error.UncompiledPresentation, compileAlloc(a, "entry", .language, "English", "en", "<li'>word</li>", null));
    try std.testing.expectError(error.UncompiledPresentation, compileAlloc(a, "entry", .language, "English", "en", "<li\" attr=x>word</li>", null));
}

test "qichwa citation language names remain visible through reference compilation and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Reduced from the actual 51,501-byte English qichwa expansion. Both raw
    // unknown names belong to the citation title, not to executable markup.
    const source = "==Quechua==\n===Etymology===\ntext<ref><span class=\"citation-whole\"><span class=\"cited-source\">Otra vuelta de tuerca: la etimología de <quechua> en quechua y aimara &#91;<span class=\"e-translation\">Another turn of the screw: The etymology of <Quechua> in Quechua and Aymara</span>&#93;</span></span></ref>\n===References===\n<references/>";
    var report: Fallbacks = .{};
    const bytes = try compileReportedAlloc(a, "qichwa", .language, "Quechua", "qu", source, null, &report);
    const decoded = try codec.decodeAlloc(a, bytes, "qichwa", .language, .{ .code = "qu", .heading = "Quechua" });
    try std.testing.expectEqual(@as(usize, 1), decoded.entry.references.len);
    var visible: std.ArrayList(u8) = .empty;
    for (decoded.entry.references[0].spans) |span| {
        try visible.appendSlice(a, span.text);
        try visible.appendSlice(a, span.trail);
    }
    try std.testing.expectEqualStrings("Otra vuelta de tuerca: la etimología de <quechua> en quechua y aimara [Another turn of the screw: The etymology of <Quechua> in Quechua and Aymara]", visible.items);
    try std.testing.expect(report.literal_markup);
    // Former unknown-tag rejection controls now exercise the same sanitizer.
    for ([_][]const u8{ "<unknown attr=x>word</unknown>", "<unknown href=\"https://example.test\">label</unknown>" }) |unknown| {
        var unknown_report: Fallbacks = .{};
        const unknown_bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", unknown, null, &unknown_report);
        _ = try codec.decodeAlloc(a, unknown_bytes, "entry", .language, .{ .code = "en", .heading = "English" });
        try std.testing.expect(unknown_report.literal_markup);
    }
    // Only the proven sanitizer emission receives literal provenance.
    const raw = [_]compiler.Span{.{ .text = "<quechua>" }};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &raw, null));
    try std.testing.expectError(error.UncompiledPresentation, compileAlloc(a, "entry", .language, "English", "en", "<li'>word</li>", null));
}

test "nested-only table cells participate in strict document span validation" {
    const a = std.testing.allocator;
    const child: compiler.Table = .{ .rows = &.{.{ .cells = &.{.{ .spans = &.{.{ .kind = .link, .text = "child", .target = "{{uncompiled}}" }} }} }} };
    const parent: compiler.Table = .{ .rows = &.{.{ .cells = &.{.{ .spans = &.{}, .nested_table = child }} }} };
    try std.testing.expectError(error.UncompiledTemplate, validateTableSpans(a, parent, null));
}

test "captured nested external link preserves literal protocol prefix and child action" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const captured = "== [[عربية]] ==\n=== المعاني ===\nفي علم النفس: يعد مرض ثنائى القطب حالة من التقلبات المزاجية التى يتعرض لها الشخص وتؤثر عليه بشكل عام.<blockquote>       ''فى معظم الحالات، يتم علاج الاضطراب ثنائي القطب بالأدوية و [http://[http://الاستشارات%20النفسية https://www.nosghy.com/] (العلاج النفسي).''<ref><nowiki>https://www.mayoclinic.org/ar/diseases-conditions/bipolar-disorder/symptoms-causes/syc-20355955</nowiki>\n\n</ref></blockquote><span dir=\"RTL\"></span>\n\n[[تصنيف:طب]]\n[[تصنيف:عربية]]";
    var report: Fallbacks = .{};
    const bytes = try compileReportedAlloc(a, "اضطراب ثنائي القطب", .language, "العربية", "ar", captured, null, &report);
    const decoded = try codec.decodeAlloc(a, bytes, "اضطراب ثنائي القطب", .language, .{ .code = "ar", .heading = "العربية" });
    var visible: std.ArrayList(u8) = .empty;
    var child_label: std.ArrayList(u8) = .empty;
    var literal_bracket = false;
    for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        try visible.appendSlice(a, span.text);
        if (span.kind == .external_link) {
            try std.testing.expectEqualStrings("http://الاستشارات%20النفسية", span.target);
            try std.testing.expect(span.italic);
            try child_label.appendSlice(a, span.text);
        }
        if (std.mem.eql(u8, span.text, "[")) {
            try std.testing.expect(span.kind == .text and span.target.len == 0);
            literal_bracket = true;
        }
    };
    try std.testing.expect(literal_bracket and report.literal_markup);
    try std.testing.expectEqualStrings("https://www.nosghy.com/", child_label.items);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "[http://https://www.nosghy.com/ (العلاج النفسي).") != null);
    // An ordinary neighboring child keeps its target, label and emphasis.
    const valid = try compileAlloc(a, "entry", .language, "English", "en", "[https://example.org valid] ''[https://example.net next]''", null);
    const control = try codec.decodeAlloc(a, valid, "entry", .language, .{ .code = "en", .heading = "English" });
    var found_valid = false;
    var found_next = false;
    for (control.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        if (std.mem.eql(u8, span.target, "https://example.org")) found_valid = span.kind == .external_link and std.mem.eql(u8, span.text, "valid") and !span.italic;
        if (std.mem.eql(u8, span.target, "https://example.net")) found_next = span.kind == .external_link and std.mem.eql(u8, span.text, "next") and span.italic;
    };
    try std.testing.expect(found_valid and found_next);
    const raw = [_]compiler.Span{.{ .text = "[http://" }};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &raw, null));
}

test "list-prefixed table closer remains literal through EOF and DPR2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prefix = "{|\n|-\n| bgcolor=\"#FFFFE0\" |\n* [[Keep]]\n* |} suffix [[After]]\n";
    const cases = [_]struct { source: []const u8, rows: usize, malformed: bool }{
        .{ .source = prefix, .rows = 1, .malformed = true },
        .{ .source = prefix ++ "|-\n| [[Second]]\n|}\n", .rows = 2, .malformed = false },
    };
    for (cases) |case| {
        var report: Fallbacks = .{};
        const bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", case.source, null, &report);
        const decoded = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
        const blocks = decoded.entry.sections[0].blocks;
        try std.testing.expectEqual(@as(usize, 1), blocks.len);
        const table = blocks[0].table orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(case.rows, table.rows.len);
        try std.testing.expectEqual(@as(usize, 1), table.rows[0].cells.len);
        try std.testing.expectEqualStrings("#ffffe0", table.rows[0].cells[0].background.?);
        var marker: usize = 0;
        var keep = false;
        var after = false;
        var visible: std.ArrayList(u8) = .empty;
        for (table.rows[0].cells[0].spans) |span| {
            try visible.appendSlice(a, span.text);
            if (std.mem.eql(u8, span.text, "|}")) marker += 1;
            if (span.kind == .link and std.mem.eql(u8, span.target, "Keep")) keep = true;
            if (span.kind == .link and std.mem.eql(u8, span.target, "After")) after = true;
        }
        try std.testing.expectEqual(@as(usize, 1), marker);
        try std.testing.expect(std.mem.indexOf(u8, visible.items, "|} suffix") != null);
        try std.testing.expect(keep and after);
        try std.testing.expectEqual(case.malformed, report.malformed_table);
        if (!case.malformed) {
            const cell = table.rows[1].cells[0];
            try std.testing.expectEqual(@as(usize, 1), cell.spans.len);
            try std.testing.expect(cell.spans[0].kind == .link);
            try std.testing.expectEqualStrings("Second", cell.spans[0].target);
        }
    }
    // A term/detail split consumes the same wiki-list phase before its body.
    var term_report: Fallbacks = .{};
    const term_bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", "; |}: [[Detail]]", null, &term_report);
    const term = try codec.decodeAlloc(a, term_bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expect(term.entry.sections[0].blocks[0].kind == .term);
    try std.testing.expectEqualStrings("|}", term.entry.sections[0].blocks[0].spans[0].text);
    try std.testing.expect(term.entry.sections[0].blocks[1].kind == .list_detail);
    try std.testing.expectEqualStrings("Detail", term.entry.sections[0].blocks[1].spans[0].target);
    // No global parsed-text exemption: inline and later delimiters still fail.
    for ([_][]const u8{ "before |} after", "* before |} after", "* |} suffix |}" }) |source| {
        var report: Fallbacks = .{};
        try std.testing.expectError(error.UncompiledPresentation, compileReportedAlloc(a, "entry", .language, "English", "en", source, null, &report));
    }
    // Exact source167 ordinal116548/page210773/revision1141827 expansion,
    // SHA256 368e4abbcd7a83c94356b980ac141e10922f6d86d7715eefd7935809516a9d29.
    // The authored bullet remains; the source parser closes the table at EOF.
    const actual_source =
        \\== عربية[[تصنيف:عربية]] ==
        \\=== المعاني ===
        \\[[اسْم]][[تصنيف:أسماء ]] [[اسم فاعل|اسْمُ فَاعِلٍ]] [[تصنيف:أسماء فاعل]]  [[مُؤَنَّث]]</span>.[[تصنيف:أسماء مؤنثة ]] يجمع جمع سالم [[سِفَارَات]]
        \\# [[اسم فاعل|اسْمُ فَاعِلٍ]] مِنْ [[سَفَرَ]][[تصنيف:أسماء فاعل]]
        \\# مَصْدَرٌ للفِعْلِ [[سَفَرَ]][[تصنيف:مصادر]]
        \\# '''السِّفارةُ''' :[[مقام]] أو [[مَقَر]]ُّ '''السَّفِيرِ'''، وَهِيَ [[إِدَارَة|إدَارَةٌ]] [[دِبْلُومَاسِيَّة]]ٌ يُمَثِّلُ أعْضَاؤُهَا دَوْلَتَهُمْ فِي [[دَوْلَة]]ٍ أُخْرَى
        \\# '''السِّفارةُ''' : عمل '''[[سَفِير|السفير]]''' ، تمثيل دبلوماسيّ لدولة لدى دولة أخرى
        \\# ملحق '''السِّفارة''': مكان يضمّ مكاتب '''السِّفارة'''
        \\# مُكَلَّفٌ بِالأَعْمَالِ فِي '''سِفَارَةٍ''' أَوْ قُنْصُلِيَّةٍ: نَائِبٌ مُفَوَّضٌ.
        \\# '''سِفَارَةً''' : [[وَسَاطَة]] , [[إِقَامَة]]ُ [[صُلْح|الصُّلْح]]
        \\
        \\=== [[ملف:Gartoon actions contents replaced.svg|34px]] كَلِمَاتٌ ذَاتُ عَلَاقَة ===
        \\
        \\=== من الجذر نفسه ===
        \\<div class="navbox-styles"><templatestyles src="Hlist/styles.css"/><templatestyles src="Module:Navbox/styles.css"/></div><div role="navigation" class="navbox" aria-labelledby="كلمات_من_الجذر_س_ف_ر" style="padding:1px"><table class="nowraplinks mw-collapsible expandCaption navbox-inner" style="border-spacing:0;background:transparent;color:inherit"><tr><th scope="col" class="navbox-title" colspan="2"><templatestyles src="Module:Navbar/styles.css"/><div class="navbar plainlinks hlist navbar-mini"><ul><li class="nv-اعرض">[[قالب:س ف ر|<abbr title="عرض هذا القالب">ع</abbr>]]</li><li class="nv-ناقش">[[نقاش القالب:س ف ر|<abbr title="ناقش هذا القالب">ن</abbr>]]</li><li class="nv-عدل">[//ar.wiktionary.org/w/index.php?title=%D9%82%D8%A7%D9%84%D8%A8:%D8%B3_%D9%81_%D8%B1&action=edit<abbr title="عدل هذا القالب">ت</abbr>]</li></ul></div><div id="كلمات_من_الجذر_س_ف_ر" style="font-size:114%;margin:0 4em">[[:تصنيف:س ف ر|كلمات من الجذر س ف ر]]</div></th></tr><tr><th scope="row" class="navbox-group" style="width:1%">[[:تصنيف:أفعال|أفعال]]</th><td class="navbox-list-with-group navbox-list navbox-odd" style="width:100%;padding:0"><div style="padding:0 0.25em">[[سَفَرَ]]، [[أَسْفَرَ]]، [[سَفَّرَ]]، [[اِسْتَفَرَ]]، [[تَسَفَّرَ]]، [[سَافَرَ]]، [[تَسَافَرَ]]، [[اِسْتَسْفَرَ]]، [[اِنْسَفَرَ]]</div></td></tr><tr><th scope="row" class="navbox-group" style="width:1%">أسماء [[:تصنيف:أسماء فاعل|فاعل]] [[:تصنيف:أسماء مفعول|ومفعول]]</th><td class="navbox-list-with-group navbox-list navbox-even" style="width:100%;padding:0"><div style="padding:0 0.25em">[[سَافِر]]، [[مَسْفُور]]، [[مُسْفَر]]، [[مِسْفَر]]، [[مُسْفِر]]، [[مُسَفِّر]]، [[مُسَفَّر]]، [[مُسْتَفِر]]، [[مُسْتَفَر]]، [[مُتَسَفِّر]]، [[مُتَسَفَّر]]، [[مُسَافِر]]، [[مُسَافَر]]، [[مُتَسَافِر]]، [[مُتَسَافَر]]، [[مُسْتَسْفَر]]، [[مُسْتَسْفِر]]، [[مُنْسَفِر]]، [[مُنْسَفَر]]</div></td></tr><tr><th scope="row" class="navbox-group" style="width:1%">[[:تصنيف:مصادر|مصادر]]</th><td class="navbox-list-with-group navbox-list navbox-odd" style="width:100%;padding:0"><div style="padding:0 0.25em">[[سَفْر]]، [[سَفَارَة]]، [[سِفَارَة]]، [[إِسْفَار]]، [[تَسْفِير]]، [[اِسْتِفَار]]، [[تَسَفُّر]]، [[مُسَافَرَة]]، [[تَسَافُر]]، [[اِسْتِسْفَار]]، [[اِنْسِفَار]]</div></td></tr><tr><th scope="row" class="navbox-group" style="width:1%">أخرى</th><td class="navbox-list-with-group navbox-list navbox-even" style="width:100%;padding:0"><div style="padding:0 0.25em">[[سَفَر]]،  [[سُفْر]]، [[سُفْرَة]]، [[سُفَر]]، [[سِفْر]]، [[سَفْر]]، [[سَفِير]]، [[سُفَارَة]]، [[سُفُور]]، [[سِفَار]]، [[سَفْرَة]]، [[سَفَرَة]]، [[سَفِيرَة]]، [[سَفَائِر]]، [[مَسْفِر]]، [[أَسْفَار]]، [[مَسَافِر]]</div></td></tr></table></div>
        \\[[تصنيف:س ف ر]]
        \\=== الترجمات ===
        \\<div class="NavFrame" style="border:solid .01em; border-collapse:collapse;">
        \\<div class="NavHead" style="min-height: 1.6em; font-weight: bold; font-size: 100%; background-color: #efefef; padding-right: 10px; text-align: right;">ترجمة </div>
        \\<div class="NavContent">
        \\{| border="0" width="100%" class="translations"
        \\|-
        \\| bgcolor="#FFFFE0" valign="top" width="48%" align="right" |[[تصنيف:رأس قالب الترجمة ليس مكتوب]]
        \\
        \\* بال[[إنجليزية]]: <span class="Latn" lang="en">[[:embassy#إنجليزية|embassy]]</span><span class="tpos">&nbsp;[[:en&#58;embassy|(en)]]</span>[[Category:كلمات مع ترجمة  إنجليزية|سِفَارَة]] <span class="Latn" lang="en">[[:conciliation#إنجليزية|conciliation]]</span><span class="tpos">&nbsp;[[:en&#58;conciliation|(en)]]</span>[[Category:كلمات مع ترجمة  إنجليزية|سِفَارَة]] <span class="Latn" lang="en">[[:mediation#إنجليزية|mediation]]</span><span class="tpos">&nbsp;[[:en&#58;mediation|(en)]]</span>[[Category:كلمات مع ترجمة  إنجليزية|سِفَارَة]] <span class="Latn" lang="en">[[:reconciliation#إنجليزية|reconciliation]]</span><span class="tpos">&nbsp;[[:en&#58;reconciliation|(en)]]</span>[[Category:كلمات مع ترجمة  إنجليزية|سِفَارَة]] <span class="Latn" lang="en">[[:peacemaking#إنجليزية|peacemaking]]</span><span class="tpos">&nbsp;[[:en&#58;peacemaking|(en)]]</span>[[Category:كلمات مع ترجمة  إنجليزية|سِفَارَة]]
        \\* بال[[فرنسية]]: <span class="Latn" lang="fr">[[:ambassade#فرنسية|ambassade]]</span><span class="tpos">&nbsp;[[:fr&#58;ambassade|(fr)]]</span>[[Category:كلمات مع ترجمة  فرنسية|سِفَارَة]] <span class="Latn" lang="fr">[[:intercession#فرنسية|intercession]]</span><span class="tpos">&nbsp;[[:fr&#58;intercession|(fr)]]</span>[[Category:كلمات مع ترجمة  فرنسية|سِفَارَة]] <span class="Latn" lang="fr">[[:conciliation#فرنسية|conciliation]]</span><span class="tpos">&nbsp;[[:fr&#58;conciliation|(fr)]]</span>[[Category:كلمات مع ترجمة  فرنسية|سِفَارَة]] <span class="Latn" lang="fr">[[:médiation#فرنسية|médiation]]</span><span class="tpos">&nbsp;[[:fr&#58;médiation|(fr)]]</span>[[Category:كلمات مع ترجمة  فرنسية|سِفَارَة]]
        \\* |}</div></div>
        \\
        \\[[تصنيف:فِعَالَة]]
    ;
    var actual_report: Fallbacks = .{};
    const actual_bytes = try compileReportedAlloc(a, "سِفَارَة", .language, "عربية", "ar", actual_source, null, &actual_report);
    const actual_decoded = try codec.decodeAlloc(a, actual_bytes, "سِفَارَة", .language, .{ .code = "ar", .heading = "عربية" });
    var definitions: usize = 0;
    var literal_markers: usize = 0;
    var embassy = false;
    for (actual_decoded.entry.sections) |section| for (section.blocks) |block| {
        if (block.kind == .definition) definitions += 1;
        for (block.spans) |span| if (std.mem.eql(u8, span.text, "|}")) {
            literal_markers += 1;
        };
        if (block.table) |table| for (table.rows) |row| for (row.cells) |cell| for (cell.spans) |span| {
            if (std.mem.eql(u8, span.text, "|}")) literal_markers += 1;
            if (span.kind == .link and std.mem.eql(u8, span.target, "embassy#إنجليزية")) embassy = true;
        };
    };
    try std.testing.expectEqual(@as(usize, 7), definitions);
    try std.testing.expectEqual(@as(usize, 1), literal_markers);
    try std.testing.expect(embassy and actual_report.malformed_table);
}

test "captured incomplete name and orphan ref retain both literals and the dictionary link through DPR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Exact announced167 record4 inputs, raw c6255337 and expanded1f1ead83.
    const raw =
        "{{شطب|صفحة تجربة و تخريب}}\n" ++
        "\n" ++
        "<reالميلاد [[التاريخ]] الميلاد197806o\n" ++
        "</ref>\n" ++
        "\n" ++
        "[[تصنيف:عربية]]";
    const expanded =
        "<div class=\"boilerplate metadata\" id=\"vfd\">\n" ++
        "{| style=\"background-color: #FFFCE6; margin: 0 2.5%; padding: 0 10px; border: 1px solid #aaa;\"\n" ++
        "| [[ملف:Nuvola apps important.svg|80px|شطب]]\n" ++
        "|'''لقد أدرجت هذه الصفحة للحذف السريع حسب [[ويكاموس:معايير الحذف السريع|سياسة الشطب]] لأنها: صفحة تجربة و تخريب\n" ++
        "\n" ++
        "سيقوم أحد [[ويكاموس:إداريون|الإداريين]] بمراجعة الصفحة للتأكد ومن ثم حذفها. رجاء لا تُزل هذا الإخطار إلا إذا قررت أن تعدل الصفحة لتدارك سبب الشطب.\n" ++
        "\n" ++
        "<small>'''للإداريين'''، افحص تاريخ الصفحة قبل الحذف بالضغط [//ar.wiktionary.org/w/index.php?title=%D8%A7%D9%84%D9%85%D9%8A%D9%84%D8%A7%D8%AF%D8%A7%D9%84%D8%AA%D8%A7%D8%B1%D9%8A%D8%AE_%D8%A7%D9%84%D9%85%D9%8A%D9%84%D8%A7%D8%AF197806o&action=delete&wpReason=%D8%B5%D9%81%D8%AD%D8%A9+%D8%AA%D8%AC%D8%B1%D8%A8%D8%A9+%D9%88+%D8%AA%D8%AE%D8%B1%D9%8A%D8%A8 هنا].</small>\n" ++
        "|}</div>\n" ++
        "[[تصنيف:صفحات للحذف السريع]]\n" ++
        "\n" ++
        "\n" ++
        "<reالميلاد [[التاريخ]] الميلاد197806o\n" ++
        "</ref>\n" ++
        "\n" ++
        "[[تصنيف:عربية]]";
    for ([_][]const u8{ raw, expanded }) |source| {
        var report: Fallbacks = .{};
        const bytes = try compileReportedAlloc(a, "الميلادالتاريخ الميلاد197806o", .language, "العربية", "ar", source, null, &report);
        const decoded = try codec.decodeAlloc(a, bytes, "الميلادالتاريخ الميلاد197806o", .language, .{ .code = "ar", .heading = "العربية" });
        var visible: std.ArrayList(u8) = .empty;
        var links: usize = 0;
        for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            try visible.appendSlice(a, span.text);
            if (span.kind == .link and std.mem.eql(u8, span.target, "التاريخ")) {
                links += 1;
                try std.testing.expectEqualStrings("التاريخ", span.text);
            }
        };
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, visible.items, "<reالميلاد"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, visible.items, "</ref>"));
        try std.testing.expectEqual(@as(usize, 1), links);
        try std.testing.expectEqual(@as(usize, 0), decoded.entry.references.len);
        try std.testing.expect(report.literal_markup);
    }
}

test "literal malformed reference recovery leaves valid reference compilation and parsed guards strict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "word<ref name=n>[[التاريخ]]</ref><references/>";
    var report: Fallbacks = .{};
    const bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", source, null, &report);
    const decoded = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqual(@as(usize, 1), decoded.entry.references.len);
    var reference_link = false;
    for (decoded.entry.references[0].spans) |span| if (span.kind == .link and std.mem.eql(u8, span.target, "التاريخ")) {
        reference_link = true;
    };
    try std.testing.expect(reference_link and !report.literal_markup and !report.unclosed_formatting);
    const direct = [_]compiler.Span{.{ .text = "<reالميلاد </ref>" }};
    const split = [_]compiler.Span{ .{ .text = "<" }, .{ .text = "reالميلاد " }, .{ .text = "</ref>" } };
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &direct, null));
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &split, null));
    for ([_][]const u8{ "<li'>word</li>", "<li\" attr=x>word</li>", "before |} after", "<reالميلاد>" }) |strict|
        try std.testing.expectError(error.UncompiledPresentation, compileAlloc(a, "entry", .language, "English", "en", strict, null));
    const protected_bytes = try compileAlloc(a, "entry", .language, "English", "en", "<nowiki><reالميلاد [[التاريخ]]</ref></nowiki>", null);
    const protected = try codec.decodeAlloc(a, protected_bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    for (protected.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span|
        try std.testing.expect(span.kind == .text and span.target.len == 0);
}

test "ordered wiki cell blocks share page anchors without promoting sections through DPR8" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Exact shared ordinary fixture 11607303, not a captured dictionary page.
    const source = "==English==\n{|\n| bgcolor='#ffeecc' colspan='2' | before [[Before|before action]]\n=== حرف ===\nparagraph ''[[Middle|middle action]]''\n* list [[Item|item action]]\n----\n{|\n| [[Child|child action]] || child second\n|}\nfollowing [[After|after action]]\n|}\n=== حرف ===\nouter tail\n";
    const bytes = try compileAlloc(a, "cell-heading-regression", .language, "English", "en", source, null);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "DPR8"));
    const decoded = try codec.decodeAlloc(a, bytes, "cell-heading-regression", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqual(@as(usize, 2), decoded.entry.sections.len);
    try std.testing.expectEqualStrings("English", decoded.entry.sections[0].anchor);
    try std.testing.expectEqualStrings("حرف_2", decoded.entry.sections[1].anchor);
    try std.testing.expectEqualStrings(".D8.AD.D8.B1.D9.81_2", decoded.entry.sections[1].anchor_fallback);
    const cell = decoded.entry.sections[0].blocks[0].table.?.rows[0].cells[0];
    try std.testing.expect(cell.spans.len == 0 and cell.nested_table == null and !cell.header);
    try std.testing.expectEqual(@as(u16, 2), cell.colspan);
    try std.testing.expectEqual(@as(u16, 1), cell.rowspan);
    try std.testing.expectEqualStrings("#ffeecc", cell.background.?);
    const blocks = cell.blocks.?;
    const kinds = [_]types.BlockKind{ .paragraph, .heading, .paragraph, .list_item, .rule, .table, .paragraph };
    try std.testing.expectEqual(kinds.len, blocks.len);
    for (blocks, kinds) |block, kind| try std.testing.expectEqual(kind, block.kind);
    try std.testing.expectEqual(@as(u8, 3), blocks[1].level);
    try std.testing.expectEqualStrings("حرف", blocks[1].anchor);
    try std.testing.expectEqualStrings(".D8.AD.D8.B1.D9.81", blocks[1].anchor_fallback);
    try std.testing.expectEqualStrings("*", blocks[3].list_path);
    try std.testing.expectEqual(@as(usize, 2), blocks[5].table.?.rows[0].cells.len);
    const Check = struct {
        index: usize = 0,
        fn spans(self: *@This(), values: []const types.Span) !void {
            const targets = [_][]const u8{ "Before", "Middle", "Item", "Child", "After" };
            const labels = [_][]const u8{ "before action", "middle action", "item action", "child action", "after action" };
            for (values) |span| if (span.kind == .link) {
                try std.testing.expect(self.index < targets.len);
                try std.testing.expectEqualStrings(targets[self.index], span.target);
                try std.testing.expectEqualStrings(labels[self.index], span.text);
                try std.testing.expectEqual(self.index == 1, span.italic);
                self.index += 1;
            };
        }
        fn visitBlocks(self: *@This(), values: []const types.Block) anyerror!void {
            for (values) |block| {
                try self.spans(block.spans);
                if (block.table) |table| {
                    try self.spans(table.caption);
                    for (table.rows) |row| for (row.cells) |child| {
                        if (child.blocks) |ordered| {
                            try self.visitBlocks(ordered);
                        } else {
                            try self.spans(child.spans);
                            if (child.nested_table) |nested| {
                                try self.spans(nested.caption);
                                for (nested.rows) |nested_row| for (nested_row.cells) |nested_cell| try self.spans(nested_cell.spans);
                            }
                        }
                    };
                }
            }
        }
    };
    var check: Check = .{};
    try check.visitBlocks(blocks);
    try std.testing.expectEqual(@as(usize, 5), check.index);
    const reencoded = try codec.encodeBuildAlloc(a, decoded.entry.display_title, decoded.entry.sections, decoded.entry.organization, decoded.entry.references, decoded.entry.media);
    try std.testing.expectEqualSlices(u8, bytes, reencoded);
}

test "allocated cell fragments project duplicate nested heading anchors into page history" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const previous = "=== Echo ===\nprior\n";
    const heading = "==English==\n";
    const body = "{|\n| intro\n=== Echo ===\none\n=== Echo ===\ntwo\n|}\n=== Echo ===\nlast\n";
    const owner = heading ++ body;
    const page = previous ++ owner;
    const observation = try observeHeadingAnchorsAlloc(a, "entry", MissingText.untracked(page), .{}, null, null, null, .{}, null);
    try std.testing.expectEqual(@as(usize, 5), observation.items.len);
    for (observation.items[1..], observation.items[0 .. observation.items.len - 1]) |current, prior| try std.testing.expect(current.source_offset > prior.source_offset);
    const fragments = [_]SourceFragment{
        .{ .source = heading, .missing = try missing_dependency.slice(a, MissingText.untracked(page), previous.len, previous.len + heading.len) },
        .{ .source = body, .missing = try missing_dependency.slice(a, MissingText.untracked(page), previous.len + heading.len, page.len) },
    };
    for (fragments) |fragment| {
        try std.testing.expect(fragment.source.ptr != fragment.missing.?.bytes.ptr);
        try std.testing.expectEqualStrings(fragment.source, fragment.missing.?.bytes);
    }
    const projection = [_]HeadingSourceRange{.{ .owner_start = 0, .page_start = previous.len, .len = owner.len }};
    const bytes = try compileReportedWithReferencesAndPhasesFragmentsAndHeadingAnchorsAlloc(a, "entry", .language, "English", "en", MissingText.untracked(owner), null, .{}, null, null, null, .{}, null, null, &fragments, &observation, &projection);
    const decoded = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqual(@as(usize, 2), decoded.entry.sections.len);
    const blocks = decoded.entry.sections[0].blocks[0].table.?.rows[0].cells[0].blocks.?;
    try std.testing.expectEqualStrings("Echo_2", blocks[1].anchor);
    try std.testing.expectEqualStrings("Echo_3", blocks[3].anchor);
    try std.testing.expectEqualStrings("Echo_4", decoded.entry.sections[1].anchor);
    // Mapping the outer heading alone cannot authorize cell-local regeneration.
    const missing_cell_range = [_]HeadingSourceRange{.{ .owner_start = 0, .page_start = previous.len, .len = heading.len }};
    try std.testing.expectError(error.InvalidHeadingProjection, compileReportedWithReferencesAndPhasesFragmentsAndHeadingAnchorsAlloc(a, "entry", .language, "English", "en", MissingText.untracked(owner), null, .{}, null, null, null, .{}, null, null, &fragments, &observation, &missing_cell_range));
}

test "HTML cell authored headings reserve shared anchors while remaining cell blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "==English==\n<table><tr><th colspan='2' bgcolor='#ffeecc'>before\n<h3 id='custom'>حرف</h3>\nparagraph ''[[Target|label]]''</th></tr></table>\n=== custom ===\nlast";
    const bytes = try compileAlloc(a, "entry", .language, "English", "en", source, null);
    const decoded = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqual(@as(usize, 2), decoded.entry.sections.len);
    const cell = decoded.entry.sections[0].blocks[0].table.?.rows[0].cells[0];
    try std.testing.expect(cell.header and cell.spans.len == 0 and cell.nested_table == null);
    try std.testing.expectEqual(@as(u16, 2), cell.colspan);
    try std.testing.expectEqualStrings("#ffeecc", cell.background.?);
    const blocks = cell.blocks.?;
    try std.testing.expectEqual(types.BlockKind.heading, blocks[1].kind);
    try std.testing.expectEqual(@as(u8, 3), blocks[1].level);
    try std.testing.expectEqualStrings("custom", blocks[1].anchor);
    try std.testing.expectEqualStrings("custom_2", decoded.entry.sections[1].anchor);
    var action = false;
    for (blocks[2].spans) |span| if (span.kind == .link and std.mem.eql(u8, span.target, "Target")) {
        action = true;
        try std.testing.expectEqualStrings("label", span.text);
        try std.testing.expect(span.italic);
    };
    try std.testing.expect(action);
}

test "authoritative cell blocks preserve strict validation empty authority and shared traversal bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const invalid: compiler.Table = .{ .rows = &.{.{ .cells = &.{.{ .spans = &.{}, .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "bad", .target = "{{uncompiled}}" }} }} }} }} };
    try std.testing.expectError(error.UncompiledTemplate, validateTableSpans(a, invalid, null));
    const empty: compiler.Table = .{ .rows = &.{.{ .cells = &.{.{ .spans = &.{}, .blocks = &.{} }} }} };
    try validateTableSpans(a, empty, null);
    const mixed_spans: compiler.Table = .{ .rows = &.{.{ .cells = &.{.{ .spans = &.{.{ .text = "legacy" }}, .blocks = &.{} }} }} };
    try std.testing.expectError(error.InvalidPresentation, validateTableSpans(a, mixed_spans, null));
    const mixed_nested: compiler.Table = .{ .rows = &.{.{ .cells = &.{.{ .spans = &.{}, .nested_table = empty, .blocks = &.{} }} }} };
    try std.testing.expectError(error.InvalidPresentation, validateTableSpans(a, mixed_nested, null));
    const Chain = struct {
        fn wrap(alloc: A, child: compiler.Table) !compiler.Table {
            const blocks = try alloc.alloc(compiler.Block, 1);
            blocks[0] = .{ .kind = .table, .table = child };
            const cells = try alloc.alloc(compiler.Cell, 1);
            cells[0] = .{ .spans = &.{}, .blocks = blocks };
            const rows = try alloc.alloc(compiler.Row, 1);
            rows[0] = .{ .cells = cells };
            return .{ .rows = rows };
        }
    };
    var chain = empty;
    for (1..types.max_table_depth) |_| chain = try Chain.wrap(a, chain);
    try validateTableSpans(a, chain, null);
    const too_deep = try Chain.wrap(a, chain);
    try std.testing.expectError(error.InvalidPresentation, validateTableSpans(a, too_deep, null));
    var validate: ValidateCompilerSpans = .{ .a = a, .fallbacks = null };
    var budget: CompilerWalk = .{ .remaining = 1 };
    try std.testing.expectError(error.InvalidPresentation, budget.table(&validate, empty, 1));
}

test "legacy null cell content keeps prior encoding and body probes see ordered content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "{|\n| == literal ==\n|}",
        "{|\n| <nowiki>\n== protected ==\n</nowiki>\n|}",
        "{|\n| before\nbefore == inline ==\n|}",
        "{|\n| before\n&#61;&#61; entity &#61;&#61;\n|}",
    }) |source| {
        const bytes = try compileAlloc(a, "entry", .language, "English", "en", source, null);
        try std.testing.expect(!std.mem.startsWith(u8, bytes, "DPR8"));
        const decoded = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
        try std.testing.expectEqual(@as(usize, 1), decoded.entry.sections.len);
        try std.testing.expect(decoded.entry.sections[0].blocks[0].table.?.rows[0].cells[0].blocks == null);
        const reencoded = try codec.encodeBuildAlloc(a, decoded.entry.display_title, decoded.entry.sections, decoded.entry.organization, decoded.entry.references, decoded.entry.media);
        try std.testing.expectEqualSlices(u8, bytes, reencoded);
    }
    const source = "{|\n| intro\n=== retained ===\nbody\n|}";
    try std.testing.expect(try hasBodyContentWithReferencesAndPoemFragmentsAlloc(a, "entry", "English", source, .{}, null, null, null, .{}, null, &.{}));
}

test "generated reference markers preserve bracket adjacency and validate authored groups" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { source: []const u8, visible: []const u8, marker: []const u8, group: []const u8 = "" }{
        .{ .source = "''word<ref>citation</ref>]'' tail [[Target|label]]", .visible = "word[1]] tail label", .marker = "[1]" },
        .{ .source = "''word<ref group='note'>citation</ref>]'' tail [[Target|label]]", .visible = "word[note 1]] tail label", .marker = "[note 1]", .group = "note" },
        .{ .source = "''[<ref>citation</ref>'' tail [[Target|label]]", .visible = "[[1] tail label", .marker = "[1]" },
        .{ .source = "''[<ref group='note'>citation</ref>'' tail [[Target|label]]", .visible = "[[note 1] tail label", .marker = "[note 1]", .group = "note" },
        .{ .source = "''word<ref group='n&amp;o'>citation</ref>]'' tail [[Target|label]]", .visible = "word[n&o 1]] tail label", .marker = "[n&o 1]", .group = "n&o" },
    };
    for (cases) |case| {
        var report: Fallbacks = .{};
        const bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", case.source, null, &report);
        try std.testing.expect(!report.literal_markup);
        const stored = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
        try std.testing.expectEqualSlices(u8, bytes, try codec.encodeAlloc(a, stored));
        try std.testing.expectEqual(@as(usize, 1), stored.entry.sections[0].blocks.len);
        var visible: std.ArrayList(u8) = .empty;
        defer visible.deinit(a);
        var marker_count: usize = 0;
        var ordinary_actions: usize = 0;
        for (stored.entry.sections[0].blocks[0].spans) |span| {
            try visible.appendSlice(a, span.text);
            if (span.role == .reference) {
                marker_count += 1;
                try std.testing.expectEqual(types.InlineKind.link, span.kind);
                try std.testing.expectEqualStrings(case.marker, span.text);
                try std.testing.expectEqualStrings("#reference-1", span.target);
                try std.testing.expect(span.superscript and span.italic);
            } else if (span.kind == .link) {
                ordinary_actions += 1;
                try std.testing.expectEqualStrings("label", span.text);
                try std.testing.expectEqualStrings("Target", span.target);
                try std.testing.expect(!span.superscript and !span.italic);
            } else {
                try std.testing.expectEqualStrings("", span.target);
            }
        }
        try std.testing.expectEqualStrings(case.visible, visible.items);
        try std.testing.expectEqual(@as(usize, 1), marker_count);
        try std.testing.expectEqual(@as(usize, 1), ordinary_actions);
        try std.testing.expectEqual(@as(usize, 1), stored.entry.references.len);
        try std.testing.expectEqualStrings(case.group, stored.entry.references[0].group);
        var citation: std.ArrayList(u8) = .empty;
        defer citation.deinit(a);
        for (stored.entry.references[0].spans) |span| try citation.appendSlice(a, span.text);
        try std.testing.expectEqualStrings("citation", citation.items);
    }
    // Authored raw closers are consumed by the existing malformed-link
    // recovery. Their diagnosed presentation is data, not an uncompiled pair.
    for ([_]bool{ false, true }) |reference_body| {
        var report: Fallbacks = .{};
        const source = if (reference_body) "word<ref>bad]]body</ref>]" else "word]]tail";
        const bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", source, null, &report);
        try std.testing.expect(report.literal_markup);
        const stored = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
        const values = if (reference_body) stored.entry.references[0].spans else stored.entry.sections[0].blocks[0].spans;
        var diagnosed: std.ArrayList(u8) = .empty;
        defer diagnosed.deinit(a);
        for (values) |span| {
            try diagnosed.appendSlice(a, span.text);
            try std.testing.expectEqual(types.InlineKind.text, span.kind);
            try std.testing.expectEqualStrings("", span.target);
            try std.testing.expect(std.mem.indexOf(u8, span.text, "]]") == null);
        }
        try std.testing.expectEqualStrings(if (reference_body) "bad [malformed link]body" else "word [malformed link]tail", diagnosed.items);
    }
    for ([_][]const u8{
        "word]__NOTOC__]tail",
        "word<ref group='bad]]name'>citation</ref>]",
        "word<ref group='bad[[name'>citation</ref>]",
    }) |source| {
        var report: Fallbacks = .{};
        try std.testing.expectError(error.UncompiledPresentation, compileReportedAlloc(a, "entry", .language, "English", "en", source, null, &report));
        try std.testing.expect(report.literal_markup);
    }
    const split = [_]compiler.Span{ .{ .text = "word]" }, .{ .text = "]tail" } };
    var split_report: Fallbacks = .{};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &split, &split_report));
    try std.testing.expect(split_report.literal_markup);
}

test "closed newline external citations preserve literal punctuation and bare URL actions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Check = struct {
        fn value(allocator: A, body: []const u8, target: []const u8, exact_visible: ?[]const u8) !void {
            const source = try std.fmt.allocPrint(allocator, "''word<ref>{s}</ref>'' tail [[Target|label]]\n<references />", .{body});
            var report: Fallbacks = .{};
            const bytes = try compileReportedAlloc(allocator, "entry", .language, "English", "en", source, null, &report);
            try std.testing.expect(report.literal_markup);
            var renderer: compiler.Renderer = .{ .a = allocator, .context = .{}, .in_reference = true };
            const parsed = try renderer.parseSpans(body, .{});
            try std.testing.expect(renderer.fallbacks.literal_markup);
            try std.testing.expectEqualStrings("[", parsed[0].text);
            try std.testing.expectEqual(compiler.Provenance.protected_literal, parsed[0].provenance);
            const stored = try codec.decodeAlloc(allocator, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
            try std.testing.expectEqualSlices(u8, bytes, try codec.encodeAlloc(allocator, stored));
            try std.testing.expectEqual(@as(usize, 1), stored.entry.references.len);
            const reference = stored.entry.references[0];
            try std.testing.expectEqual(@as(usize, 1), reference.number);
            var visible: std.ArrayList(u8) = .empty;
            defer visible.deinit(allocator);
            var urls: usize = 0;
            for (reference.spans) |span| {
                try std.testing.expect(span.kind != .line_break);
                try visible.appendSlice(allocator, span.text);
                if (span.kind == .external_link) {
                    urls += 1;
                    try std.testing.expectEqualStrings(target, span.target);
                    try std.testing.expectEqualStrings(target, span.text);
                } else {
                    try std.testing.expectEqual(types.InlineKind.text, span.kind);
                    try std.testing.expectEqualStrings("", span.target);
                }
            }
            try std.testing.expectEqual(@as(usize, 1), urls);
            try std.testing.expect(std.mem.startsWith(u8, visible.items, "["));
            try std.testing.expect(std.mem.endsWith(u8, visible.items, "]"));
            if (exact_visible) |expected| try std.testing.expectEqualStrings(expected, visible.items);
            // The exact captured citation words and punctuation remain ordered;
            // this projection does not assert a browser whitespace/pixel model.
            var authored = std.mem.tokenizeAny(u8, body, " \t\r\n");
            var displayed = std.mem.tokenizeAny(u8, visible.items, " \t\r\n");
            while (authored.next()) |word| {
                const observed = displayed.next();
                try std.testing.expect(observed != null);
                try std.testing.expectEqualStrings(word, observed.?);
            }
            try std.testing.expect(displayed.next() == null);
            var markers: usize = 0;
            var ordinary_links: usize = 0;
            for (stored.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
                if (span.role == .reference) {
                    markers += 1;
                    try std.testing.expectEqualStrings("[1]", span.text);
                    try std.testing.expectEqualStrings("#reference-1", span.target);
                    try std.testing.expect(span.superscript and span.italic);
                } else if (span.kind == .link) {
                    ordinary_links += 1;
                    try std.testing.expectEqualStrings("Target", span.target);
                    try std.testing.expectEqualStrings("label", span.text);
                    try std.testing.expect(!span.italic);
                }
            };
            try std.testing.expectEqual(@as(usize, 1), markers);
            try std.testing.expectEqual(@as(usize, 1), ordinary_links);
        }
    };
    const cases = [_]struct { source: []const u8, visible: []const u8 }{
        .{ .source = "[https://example.test Alpha\nBeta]", .visible = "[https://example.test Alpha Beta]" },
        .{ .source = "[https://example.test Alpha\n Beta]", .visible = "[https://example.test Alpha  Beta]" },
        .{ .source = "[https://example.test Alpha \nBeta]", .visible = "[https://example.test Alpha Beta]" },
        .{ .source = "[https://example.test Alpha\r\nBeta]", .visible = "[https://example.test Alpha Beta]" },
        .{ .source = "[https://example.test Alpha\rBeta]", .visible = "[https://example.test Alpha Beta]" },
        .{ .source = "[https://example.test Alpha\n<2026]", .visible = "[https://example.test Alpha <2026]" },
    };
    for (cases) |case| try Check.value(a, case.source, "https://example.test", case.visible);
    // Exact isolated LF-bearing reference bodies from all 24 retained AF pages.
    // Whole-page secondary failures remain the post-fix full-index audit's job.
    const captured = [_]struct { title: []const u8, source: []const u8, target: []const u8 }{
        .{ .title = "soeke", .source = "[https://www.litnet.co.za/stilgebed-en-skone-skeppendheid-om-uit-die-stilte-te-skep/ LitNet Akademies (Godsdienswetenskappe):\n Stilgebed en skone skeppendheid: Om uit die stilte te skep; Johann Rossouw; 2018]", .target = "https://www.litnet.co.za/stilgebed-en-skone-skeppendheid-om-uit-die-stilte-te-skep/" },
        .{ .title = "seehond", .source = "[https://scholar.sun.ac.za/server/api/core/bitstreams/766cef1a-9e73-4d9f-bc9d-d2daff2be021/content DIE GESKIEDENIS VAN DIE VISSERY AAN DIE KAAP TOT AAN DIE MIDDEL VAN DIE AGTIENDE EEU.; C. F. J. MUJ:;-LER, M.A..\n(M.A.-tesis, Universiteit van Stellenbosch, 1938).]", .target = "https://scholar.sun.ac.za/server/api/core/bitstreams/766cef1a-9e73-4d9f-bc9d-d2daff2be021/content" },
        .{ .title = "grendel", .source = "[https://www.dbnl.org/tekst/_pas002200101_01/_pas002200101_01_0040.php Passionate; Henning Jonathan Pieterse;\ndrie gedichten; 2010]", .target = "https://www.dbnl.org/tekst/_pas002200101_01/_pas002200101_01_0040.php" },
        .{ .title = "ewewig", .source = "[https://wisa.org.za/wp-content/uploads/2018/12/WISA1989-020P.pdf WISA; \nKristallisasie van kalsiumfosfaat in 'n sweefbedreaktor; W.A. Pretorius, M.A.A. Coetzee; 1989]", .target = "https://wisa.org.za/wp-content/uploads/2018/12/WISA1989-020P.pdf" },
        .{ .title = "edik", .source = "[https://journals.co.za/doi/pdf/10.17159/tvl.v.54i2.2989 Hitler, Verwoerd, Mandela and Me.\nMarianne Thamm; TYDSKRIF VIR LETTERKUNDE • 54 (2); 2017]", .target = "https://journals.co.za/doi/pdf/10.17159/tvl.v.54i2.2989" },
        .{ .title = "protes", .source = "[https://journals.co.za/doi/pdf/10.10520/ejc-litnet-v18-n3-a8 LitNet; Akademies 18(3); Houdings in verband met protesaksie in Suid-Afrika;\nJohan Zaaiman; 2021]", .target = "https://journals.co.za/doi/pdf/10.10520/ejc-litnet-v18-n3-a8" },
        .{ .title = "onverbrande", .source = "[https://agris.fao.org/search/en/providers/124740/records/67053f82b1dfe472e1468352 FAO; Savanna-woodland fire regimes: ecology, management and conservation of African protected areas; Nieman, Willem Adriaan, Leslie, Alison J., Van Wilgen, Brian, Radloff, Frans, Tambling, Craig; \n2021]", .target = "https://agris.fao.org/search/en/providers/124740/records/67053f82b1dfe472e1468352" },
        .{ .title = "neerlê", .source = "[https://core.ac.uk/download/pdf/335037622.pdf Christelike hoër onderwys en die teologie; Du Toit; <2025\n]", .target = "https://core.ac.uk/download/pdf/335037622.pdf" },
        .{ .title = "gekondenseer", .source = "[https://www.litnet.co.za/vir-brianvds-panda-angus-en-cornelius/ Litnet; Brianvds;\n2012]", .target = "https://www.litnet.co.za/vir-brianvds-panda-angus-en-cornelius/" },
        .{ .title = "verwantskap", .source = "[https://journals.co.za/doi/pdf/10.10520/AJA02580144_608 Verwantskap as bron van finansiele hulpverlening in Soshanguve;\nH.P. Steyn; S.Afr.J.Ethno1. 13(4); 1990]", .target = "https://journals.co.za/doi/pdf/10.10520/AJA02580144_608" },
        .{ .title = "verbergend", .source = "[https://repository.up.ac.za/server/api/core/bitstreams/6dbd5647-0386-494a-8c9c-1dbaed1929f8/content \nUniversiteit van Pretoria; Die neerslag van die metafoor. ’n Voorlopige besinning; Vos, CJA; 2007]", .target = "https://repository.up.ac.za/server/api/core/bitstreams/6dbd5647-0386-494a-8c9c-1dbaed1929f8/content" },
        .{ .title = "handwoordeboek", .source = "[https://journals.co.za/doi/pdf/10.10520/AJA16844904_406 Voorbeeldmateriaal in\nwoordeboeke; F.J. Lombard; 1992]", .target = "https://journals.co.za/doi/pdf/10.10520/AJA16844904_406" },
        .{ .title = "gefel", .source = "[https://journals.co.za/doi/pdf/10.10520/EJC109930 Geskiedenis, narratiwiteit en\ntweedegenerasie-trauma: Die problematiek van traumarepresentasie in La place de la Bastille deur Leon de Winter; Hennie van Coller en Cilliers van den Berg; STILET — Jg. XXI:1 — maart 2010]", .target = "https://journals.co.za/doi/pdf/10.10520/EJC109930" },
        .{ .title = "gehoopte", .source = "[https://repository.up.ac.za/bitstreams/30fee768-c1df-4d6d-83cb-6e02eda985a1/download HERDENKINGS TYDENS DIE ANGLO-BOEREOORLOG\n(1899 TOT 1901); A. Bailey; <2026]", .target = "https://repository.up.ac.za/bitstreams/30fee768-c1df-4d6d-83cb-6e02eda985a1/download" },
        .{ .title = "waansinnig", .source = "[https://journals.co.za/doi/pdf/10.10520/AJA00651141_789 DIE FIGUUR VAN ODUSSEUS BY\nGERHART HAUPTMANN; P. J. Conradie; 2009]", .target = "https://journals.co.za/doi/pdf/10.10520/AJA00651141_789" },
        .{ .title = "nesosilikaat", .source = "[https://opentran.net/af/kroaties-afrikaans/cirkonu.html \nCirkonu - vertaling na afrikaans, sinonieme, luister, definisie, antonieme, voorbeelde; <2026]", .target = "https://opentran.net/af/kroaties-afrikaans/cirkonu.html" },
        .{ .title = "posisiewerkwoord", .source = "[https://journals.co.za/doi/pdf/10.5774/52-0-709 Adri Breed; Stellenbosch Papers in Linguistics, 52, 23-43; 2017\n]", .target = "https://journals.co.za/doi/pdf/10.5774/52-0-709" },
        .{ .title = "vervange", .source = "[https://repository.up.ac.za/items/ff608612-4643-498f-96c6-7f5489043cc2 U. Pretoria; Mashiane, Ernest George; 2018\n]", .target = "https://repository.up.ac.za/items/ff608612-4643-498f-96c6-7f5489043cc2" },
        .{ .title = "gepak", .source = "[https://novanews.co.za/bloemnewsexpress/net-een-kan-suid-afrika-red-20240523-2/ Nova news; Net Een kan Suid-Afrika red; \nErica Pretorius; 2024]", .target = "https://novanews.co.za/bloemnewsexpress/net-een-kan-suid-afrika-red-20240523-2/" },
        .{ .title = "nefrologies", .source = "[https://journals.co.za/doi/pdf/10.10520/AJA20785135_26857 Geneeskundige Onderrig en Spesialisasie\nF. P. RETIEF; SA MEDIESE TYDSKRIF; 1975]", .target = "https://journals.co.za/doi/pdf/10.10520/AJA20785135_26857" },
        .{ .title = "gekoaguleerde", .source = "[https://www.netwerk24.com/land-van-te-veel-melk-en-te-min-heuning-20151021 Netwerk24; Land van te veel melk en te min heuning;\nErrieda du Toit; 2015]", .target = "https://www.netwerk24.com/land-van-te-veel-melk-en-te-min-heuning-20151021" },
        .{ .title = "onafgebreekte", .source = "[https://www.sasas.co.za/wp-content/uploads/2012/09/Brand18Issue3_0.pdf Sasas; Die benutting van ureumaangevulde en verskillende tipes geammoniseerde\ngarsstrooi by skape; A.A. Brand en S.W.P. Cloete; S-Afr. Tydskr. Veekunde 18(3); 1988]", .target = "https://www.sasas.co.za/wp-content/uploads/2012/09/Brand18Issue3_0.pdf" },
        .{ .title = "afgebyt", .source = "[https://argief.litnet.co.za/article.php?news_id=83595 Litnet; \nBlitsfiksie-kompetisie: Kuikenmoord; Lewies; 2010]", .target = "https://argief.litnet.co.za/article.php?news_id=83595" },
        .{ .title = "zetapotensiaal", .source = "[https://journals.co.za/doi/pdf/10.10520/AJA10212019_24099 \n'n Eenvoudige teoretiese model vir die versnelling van infiltrasie deur onversadigde klei met behulp van elektroosnlose; M de Wet; SAlCE-joernaal, 40(3): 17-20; 1998]", .target = "https://journals.co.za/doi/pdf/10.10520/AJA10212019_24099" },
    };
    for (captured) |case| {
        _ = case.title;
        try Check.value(a, case.source, case.target, null);
    }
    var direct_report: Fallbacks = .{};
    const direct_bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", "prefix [https://example.test Alpha\nBeta] suffix [[Target|label]]", null, &direct_report);
    try std.testing.expect(direct_report.literal_markup);
    const direct = try codec.decodeAlloc(a, direct_bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    var direct_text: std.ArrayList(u8) = .empty;
    defer direct_text.deinit(a);
    for (direct.entry.sections[0].blocks[0].spans) |span| try direct_text.appendSlice(a, span.text);
    try std.testing.expectEqualStrings("prefix [https://example.test Alpha Beta] suffix label", direct_text.items);
}

test "closed newline external recovery cannot borrow closure across source domains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "word<ref>[https://example.test Alpha\nBeta</ref>",
        "word [https://example.test Alpha\nBeta",
        "word<ref>[https:// Alpha\nBeta]</ref>",
        "word<ref>[https://outer.test Alpha\n[https://inner.test Beta]</ref>",
        "word<ref>[https://example.test Alpha\n<nowiki>]</nowiki></ref>",
        "word<ref>[https://example.test Alpha\n<span title=']'>Beta</span></ref>",
        "word<ref>[https://example.test Alpha\n&#93;</ref>",
    }) |source| {
        var report: Fallbacks = .{};
        try std.testing.expectError(error.UncompiledPresentation, compileReportedAlloc(a, "entry", .language, "English", "en", source, null, &report));
        try std.testing.expect(report.literal_markup);
    }
    // Valid single-line labels still own their whole label; LF after their
    // already consumed closer is ordinary following reference prose.
    var valid_report: Fallbacks = .{};
    const valid_bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", "word<ref>[https://example.test Label]\ncontinued</ref>", null, &valid_report);
    try std.testing.expect(!valid_report.literal_markup);
    const valid = try codec.decodeAlloc(a, valid_bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualStrings("Label", valid.entry.references[0].spans[0].text);
    try std.testing.expectEqualStrings("https://example.test", valid.entry.references[0].spans[0].target);
    var valid_text: std.ArrayList(u8) = .empty;
    defer valid_text.deinit(a);
    for (valid.entry.references[0].spans) |span| try valid_text.appendSlice(a, span.text);
    try std.testing.expectEqualStrings("Label continued", valid_text.items);
    // Separate inline calls cannot lend each other a literal closer.
    var split: compiler.Renderer = .{ .a = a, .context = .{}, .in_reference = true };
    try split.inlineText("[https://example.test Alpha\n", .{}, 0);
    try split.inlineText("Beta]", .{}, 0);
    var split_report: Fallbacks = .{};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, split.spans.items, &split_report));
    try std.testing.expect(split_report.literal_markup);
    // The next opener bounds each failed scan; only the last root closes.
    var repeated: std.ArrayList(u8) = .empty;
    defer repeated.deinit(a);
    for (0..128) |_| try repeated.appendSlice(a, "[https://example.test Alpha\n");
    try repeated.append(a, ']');
    var repeated_renderer: compiler.Renderer = .{ .a = a, .context = .{}, .in_reference = true };
    const repeated_spans = try repeated_renderer.parseSpans(repeated.items, .{});
    var proved: usize = 0;
    for (repeated_spans) |span| if (span.provenance == .protected_literal and std.mem.eql(u8, span.text, "[")) {
        proved += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), proved);
    var repeated_report: Fallbacks = .{};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, repeated_spans, &repeated_report));
    // Source case19 empty [] references and a bare URL plus authored ] remain
    // separate from the one diagnosed closed-newline citation.
    var extras_report: Fallbacks = .{};
    const extras_bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", "word<ref>[]</ref><ref>[]</ref><ref>[]</ref><ref>[https://example.test Alpha\nBeta]</ref><ref>https://other.test prose]</ref>", null, &extras_report);
    try std.testing.expect(extras_report.literal_markup);
    const extras = try codec.decodeAlloc(a, extras_bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqual(@as(usize, 5), extras.entry.references.len);
    for (extras.entry.references[0..3]) |reference| {
        var empty_text: std.ArrayList(u8) = .empty;
        defer empty_text.deinit(a);
        for (reference.spans) |span| {
            try std.testing.expectEqual(types.InlineKind.text, span.kind);
            try empty_text.appendSlice(a, span.text);
        }
        try std.testing.expectEqualStrings("[]", empty_text.items);
    }
    try std.testing.expectEqualStrings("https://other.test", extras.entry.references[4].spans[0].target);
    var bare_text: std.ArrayList(u8) = .empty;
    defer bare_text.deinit(a);
    for (extras.entry.references[4].spans) |span| try bare_text.appendSlice(a, span.text);
    try std.testing.expectEqualStrings("https://other.test prose]", bare_text.items);
    var sic_report: Fallbacks = .{};
    const sic_bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", "<small><sup>[sic]</sup></small><ref>soos dit aangehaal word</ref>''word<ref>[https://example.test Alpha\nBeta]</ref>''", null, &sic_report);
    try std.testing.expect(sic_report.literal_markup);
    const sic = try codec.decodeAlloc(a, sic_bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqual(@as(usize, 2), sic.entry.references.len);
    var first_note: std.ArrayList(u8) = .empty;
    defer first_note.deinit(a);
    for (sic.entry.references[0].spans) |span| try first_note.appendSlice(a, span.text);
    try std.testing.expectEqualStrings("soos dit aangehaal word", first_note.items);
    var sic_text: std.ArrayList(u8) = .empty;
    defer sic_text.deinit(a);
    var sic_markers: usize = 0;
    for (sic.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        if (span.role == .reference) {
            sic_markers += 1;
            try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "#reference-{d}", .{sic_markers}), span.target);
        } else if (span.small and span.superscript) try sic_text.appendSlice(a, span.text);
    };
    try std.testing.expectEqual(@as(usize, 2), sic_markers);
    try std.testing.expectEqualStrings("[sic]", sic_text.items);
}

test "prepared citation owner copies share temporal bodies and body probes retain orphan fragments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "<ref follow=absent>prefix orphan</ref>\n==English==\n===Noun===\n# first<ref name=shared>parent</ref>\n==French==\n===Noun===\n# second<ref follow=shared>tail</ref><ref name=shared/>\n";
    const prepared = try preparePageExternalLinksAlloc(a, raw, .{ .title = "entry" });
    try std.testing.expect(prepared.citations != null);
    var definitions = try referenceDefinitionsWithMissingAlloc(a, prepared.missing);
    definitions.citations = prepared.citations;
    const english = std.mem.indexOf(u8, prepared.source, "==English==").?;
    const french = std.mem.indexOf(u8, prepared.source, "==French==").?;
    const prefix = try a.dupe(u8, prepared.source[0..english]);
    try std.testing.expect(try hasBodyContentWithReferencesAndPoemFragmentsAlloc(a, "entry", "", prefix, .{}, null, null, null, definitions, prepared.poem_phase, &.{}));
    const prefix_work = try workAllocWithPoem(a, "entry", "", prefix, .{}, null, null, null, definitions, prepared.poem_phase);
    try std.testing.expectEqual(@as(usize, 1), prefix_work.references.len);
    try std.testing.expectEqualStrings("fragment", @tagName(prefix_work.references[0].kind));
    var prefix_text: std.ArrayList(u8) = .empty;
    for (prefix_work.references[0].spans) |span| try prefix_text.appendSlice(a, span.text);
    try std.testing.expectEqualStrings("prefix orphan", prefix_text.items);
    // Copies intentionally have no pointer or byte-offset relationship to the page.
    for ([_][]const u8{ prepared.source[english..french], prepared.source[french..] }) |slice| {
        const copy = try a.dupe(u8, slice);
        const fragments = [_]SourceFragment{.{ .source = copy }};
        const plain = try workAllocWithPoemFragments(a, "entry", "", copy, .{}, null, null, null, definitions, prepared.poem_phase, &fragments);
        const headings = try workWithHeadingOffsetsAlloc(a, "entry", "", MissingText.untracked(copy), .{}, null, null, null, definitions, prepared.poem_phase, &fragments);
        for ([_]Work{ plain, headings }) |work| {
            try std.testing.expectEqual(@as(usize, 1), work.references.len);
            try std.testing.expectEqualStrings("note", @tagName(work.references[0].kind));
            try std.testing.expectEqual(@as(usize, 1), work.references[0].number);
            var text: std.ArrayList(u8) = .empty;
            for (work.references[0].spans) |span| try text.appendSlice(a, span.text);
            try std.testing.expectEqualStrings("parent tail", text.items);
        }
        _ = try observePreScopesAlloc(a, "entry", copy, .{}, null, null, null, definitions, prepared.poem_phase);
    }
}
