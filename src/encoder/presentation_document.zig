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
    // Borrowed from the exact immutable page domain, not reconstructed markup.
    tag_name: []const u8 = "",
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
            const hidden_tag = if (kind == .hidden) blk: {
                const tag = blobs.wikitext_syntax.tagAt(domain, opening_start) orelse return error.InvalidPreContext;
                if (!matched or tag.closing or tag.self_closing or tag.end != body_start or target.len != 0) return error.InvalidPreContext;
                const pair = blobs.wikitext_syntax.matchingTag(domain, tag) orelse return error.InvalidPreContext;
                if (pair.inner_end != body_end or pair.end != resume_at) return error.InvalidPreContext;
                break :blk tag.name;
            } else "";
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
                .attributes = .{ .classes = owned_classes, .role = attributes.role, .relation_note = attributes.relation_note, .language = owned_language, .direction = owned_direction, .explanation = owned_explanation, .explanation_set = attributes.explanation_set, .foreground = owned_foreground, .foreground_set = attributes.foreground_set, .font_scale = attributes.font_scale, .font_scale_basis = attributes.font_scale_basis, .font_scale_set = attributes.font_scale_set },
                .target = owned_target,
                .tag_name = hidden_tag,
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
pub const HeadingObservation = struct {
    items: []const HeadingAnchor = &.{},
    page_html_openings: []const usize = &.{},
    page_html_source: ?[]const u8 = null,
};

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
    page_html_openings: []const usize = &.{},
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
    var html_openings: std.ArrayList(usize) = .empty;
    defer html_openings.deinit(a);
    var renderer: compiler.Renderer = .{ .a = a, .context = .{ .title = title, .language = if (language.len == 0) "English" else language, .link_trail = link_trail, .namespace_catalog = namespace_catalog, .behavior_switches = behavior_switches, .image_options = image_options, .poem_phase = poem_phase } };
    if (fragments.len == 0) renderer.page_html_heading_openings = &html_openings;
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
    return .{ .sections = try builder.sections.toOwnedSlice(a), .page_html_openings = try html_openings.toOwnedSlice(a), .references = try renderer.finishReferences(), .media = try renderer.media.toOwnedSlice(a), .media_caption_spans = try renderer.media_caption_spans.toOwnedSlice(a), .rendered_templates = renderer.rendered_templates, .unresolved_templates = renderer.unresolved_templates, .fallbacks = renderer.fallbacks };
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
    return .{ .items = try result.toOwnedSlice(a), .page_html_openings = work.page_html_openings, .page_html_source = source.bytes };
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
/// Explicit publication authority from the producer's resolved source group.
/// Generic compilation metadata alone is not evidence of a single owner.
pub const ClassifiedLanguage = struct { heading: []const u8, code: []const u8 };
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
    return compileClassifiedWithHeadingAnchorsAlloc(a, title, kind, language, language_code, source, display_title, link_trail, namespace_catalog, behavior_switches, image_options, reference_context, fallbacks, poem_phase, fragments, heading_observation, heading_projection, null);
}
pub fn compileClassifiedWithHeadingAnchorsAlloc(
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
    classified_owner: ?ClassifiedLanguage,
) ![]u8 {
    if (classified_owner) |owner| {
        if (kind != .language or owner.code.len == 0 or owner.heading.len == 0 or
            !std.mem.eql(u8, owner.code, language_code) or
            !std.mem.eql(u8, owner.heading, language orelse "")) return error.InvalidClassifiedLanguage;
    }

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
                (@as(u8, @bitCast(span.flags)) != 0 or span.foreground != null or span.background != null or span.font_scale != null or span.classes.len != 0 or
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
    else if (classified_owner) |owner|
        try semantic.buildOwned(a, work.sections, owner.heading)
    else
        try semantic.build(a, work.sections);
    return codec.encodeBuildAlloc(a, display_spans, work.sections, layout, work.references, work.media);
}

test "quoted colon prose survives roundtrip without weakening parsed residual guard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "==English==\n===Usage===\n# before <Usage:'That time'> after [[Target|child]]\n";
    var report: Fallbacks = .{};
    const encoded = try compileReportedAlloc(a, "entry", .language, "English", "en", source, null, &report);
    try std.testing.expect(report.literal_markup);
    try std.testing.expect(!report.unclosed_formatting and !report.unsupported_element);
    const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
    var text: std.ArrayList(u8) = .empty;
    var actions: usize = 0;
    for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        try text.appendSlice(a, span.text);
        if (std.mem.eql(u8, span.target, "Target")) actions += 1;
    };
    try std.testing.expect(std.mem.indexOf(u8, text.items, "<Usage:'That time'>") != null);
    try std.testing.expectEqual(@as(usize, 1), actions);
    const raw = [_]compiler.Span{.{ .text = "<Usage:'That time'>" }};
    var rejected: Fallbacks = .{};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &raw, &rejected));
    for ([_][]const u8{ "<ref:'word'>", "<https:'word'>", "{{deferred}}", "[[uncompiled" }) |residual|
        try std.testing.expectError(error.UncompiledPresentation, requireCompiledText(residual));
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

test "publication compiles rejected external opener as literal beside its live URL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "==English==\n===Noun===\n# A [https://example.test broken link.\n";
    const encoded = try compileAlloc(a, "entry", .language, "English", "en", source, null);
    const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqual(@as(usize, 2), decoded.entry.sections.len);
    try std.testing.expectEqualStrings("English", decoded.entry.sections[0].title);
    try std.testing.expectEqual(@as(usize, 0), decoded.entry.sections[0].blocks.len);
    try std.testing.expectEqualStrings("Noun", decoded.entry.sections[1].title);
    try std.testing.expectEqual(@as(usize, 1), decoded.entry.sections[1].blocks.len);
    try std.testing.expectEqual(types.BlockKind.definition, decoded.entry.sections[1].blocks[0].kind);
    const spans = decoded.entry.sections[1].blocks[0].spans;
    var visible: std.ArrayList(u8) = .empty;
    var url = false;
    for (spans) |span| {
        try visible.appendSlice(a, span.text);
        if (span.kind == .external_link and std.mem.eql(u8, span.target, "https://example.test")) url = true;
    }
    try std.testing.expectEqualStrings("A [https://example.test broken link.", visible.items);
    try std.testing.expect(url);

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
                try std.testing.expect(span.kind == .text and !span.small);
                try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 1.2), span.font_scale orelse return error.TestUnexpectedResult, 0.000001);
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
                    if (std.mem.eql(u8, span.text, "cell")) {
                        try std.testing.expect(!span.small);
                        try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 1.2), span.font_scale orelse return error.TestUnexpectedResult, 0.000001);
                        small_label = true;
                    }
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

test "colon angle literals preserve visible labels and targets through strict DPR2 compilation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { raw: []const u8, escaped: []const u8, visible: []const u8, target: ?[]const u8 = null, italic: bool = false }{
        .{ .raw = "<tr:āg>", .escaped = "&lt;tr:āg&gt;", .visible = "<tr:āg>" },
        .{ .raw = "</tr:āg>", .escaped = "&lt;/tr:āg&gt;", .visible = "</tr:āg>" },
        .{ .raw = "<tr:āg>word</tr:āg>", .escaped = "&lt;tr:āg&gt;word&lt;/tr:āg&gt;", .visible = "<tr:āg>word</tr:āg>" },
        .{ .raw = "<span><tr:āg></span>", .escaped = "<span>&lt;tr:āg&gt;</span>", .visible = "<tr:āg>" },
        .{ .raw = "[[આગ|આગ<tr:āg>]]", .escaped = "[[આગ|આગ&lt;tr:āg&gt;]]", .visible = "આગ<tr:āg>", .target = "આગ" },
        .{ .raw = "[[Target|before <custom:term> after]]", .escaped = "[[Target|before &lt;custom:term&gt; after]]", .visible = "before <custom:term> after", .target = "Target" },
        .{ .raw = "[[આગ|''આગ<tr:āg>tail</tr:āg>'']]", .escaped = "[[આગ|''આગ&lt;tr:āg&gt;tail&lt;/tr:āg&gt;'']]", .visible = "આગ<tr:āg>tail</tr:āg>", .target = "આગ", .italic = true },
    };
    for (cases) |case| for ([_][]const u8{ case.raw, case.escaped }, 0..) |source, variant| {
        var report: Fallbacks = .{};
        const encoded = try compileReportedAlloc(a, "fixture", .language, "English", "en", source, null, &report);
        const decoded = try codec.decodeAlloc(a, encoded, "fixture", .language, .{ .code = "en", .heading = "English" });
        var visible: std.ArrayList(u8) = .empty;
        var linked: std.ArrayList(u8) = .empty;
        for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            try visible.appendSlice(a, span.text);
            try visible.appendSlice(a, span.trail);
            try std.testing.expectEqual(case.italic, span.italic);
            try std.testing.expect(!span.bold);
            if (span.kind == .link) {
                try std.testing.expectEqualStrings(case.target orelse return error.UnexpectedLink, span.target);
                try linked.appendSlice(a, span.text);
                try linked.appendSlice(a, span.trail);
            }
        };
        try std.testing.expectEqualStrings(case.visible, visible.items);
        try std.testing.expectEqualStrings(if (case.target != null) case.visible else "", linked.items);
        try std.testing.expectEqual(variant == 0, report.literal_markup);
    };
    // Parsed source still fails the residual guard; only compiler-owned literal
    // angle provenance can make these visible spellings safe for a record.
    for ([_][]const u8{ "<tr:āg>", "</tr:āg>" }) |source| {
        const raw_spans = [_]compiler.Span{.{ .text = source }};
        try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &raw_spans, null));
    }
}

test "colon angle normalization preserves recognized HTML and opaque scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "<tr>kept</tr>", "kept" },
        .{ "<b>kept</b>", "kept" },
        .{ "<nowiki><tr:āg>[[Target]]</tr:āg></nowiki>", "<tr:āg>[[Target]]</tr:āg>" },
        .{ "<pre><tr:āg>[[Target]]</tr:āg></pre>", "<tr:āg>[[Target]]</tr:āg>" },
    };
    for (cases) |case| {
        var report: Fallbacks = .{};
        const encoded = try compileReportedAlloc(a, "fixture", .language, "English", "en", case[0], null, &report);
        const decoded = try codec.decodeAlloc(a, encoded, "fixture", .language, .{ .code = "en", .heading = "English" });
        var visible: std.ArrayList(u8) = .empty;
        for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            try visible.appendSlice(a, span.text);
            try std.testing.expect(span.kind != .link);
        };
        try std.testing.expectEqualStrings(case[1], visible.items);
        try std.testing.expect(!report.literal_markup);
    }
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

// Complete unknown names are escaped before quote/link parsing. A recognized
// prefix such as li/ref does not turn the complete name into that HTML element.
// REL1_43 Sanitizer::ELEMENT_BITS_REGEX and internalRemoveHtmlTags define this
// boundary; direct parsed spans still have no source-literal proof.
fn expectUnknownAtomicSourceLiteral(a: std.mem.Allocator, source: []const u8, escaped_reference: []const u8, expected_visible: []const u8) !void {
    errdefer std.debug.print("unknown atomic source case: {s}\n", .{source});
    const direct = [_]compiler.Span{.{ .text = source }};
    const split = [_]compiler.Span{ .{ .text = source[0..1] }, .{ .text = source[1..] } };
    try std.testing.expectError(error.UncompiledPresentation, requireCompiledText(source));
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &direct, null));
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &split, null));
    for ([_]bool{ false, true }) |with_child| {
        const suffix = if (with_child) " ''[[Target|kept]]''" else "";
        const input = try std.mem.concat(a, u8, &.{ source, suffix });
        const reference = try std.mem.concat(a, u8, &.{ escaped_reference, suffix });
        var report: Fallbacks = .{};
        const bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", input, null, &report);
        const expected = try compileAlloc(a, "entry", .language, "English", "en", reference, null);
        try std.testing.expectEqualSlices(u8, expected, bytes);
        const stored = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
        try std.testing.expectEqualSlices(u8, bytes, try codec.encodeAlloc(a, stored));
        try std.testing.expect(report.literal_markup);
        try std.testing.expectEqual(@as(usize, 0), stored.entry.references.len);
        try std.testing.expectEqual(@as(usize, 0), stored.entry.media.len);
        var visible: std.ArrayList(u8) = .empty;
        var actions: usize = 0;
        for (stored.entry.sections) |section| for (section.blocks) |block| {
            try std.testing.expect(block.table == null);
            for (block.spans) |span| {
                try visible.appendSlice(a, span.text);
                try visible.appendSlice(a, span.trail);
                if (span.kind == .link) {
                    try std.testing.expect(with_child);
                    try std.testing.expectEqualStrings("Target", span.target);
                    try std.testing.expectEqualStrings("kept", span.text);
                    try std.testing.expect(span.italic and !span.bold);
                    actions += 1;
                } else try std.testing.expect(span.kind == .text and span.target.len == 0);
            }
        };
        try std.testing.expectEqual(@as(usize, @intFromBool(with_child)), actions);
        const visible_reference = try std.mem.concat(a, u8, &.{ expected_visible, if (with_child) " kept" else "" });
        try std.testing.expectEqualStrings(visible_reference, visible.items);
    }
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
    // Whole unknown names retain their spelling rather than becoming li elements.
    try expectUnknownAtomicSourceLiteral(a, "<li'>word</li>", "&lt;li'&gt;word</li>", "<li'>word");
    try expectUnknownAtomicSourceLiteral(a, "<li\" attr=x>word</li>", "&lt;li\" attr=x&gt;word</li>", "<li\" attr=x>word");
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
    try expectUnknownAtomicSourceLiteral(a, "<li'>word</li>", "&lt;li'&gt;word</li>", "<li'>word");
}

test "nested-only table cells participate in strict document span validation" {
    const a = std.testing.allocator;
    const child: compiler.Table = .{ .rows = &.{.{ .cells = &.{.{ .spans = &.{.{ .kind = .link, .text = "child", .target = "{{uncompiled}}" }} }} }} };
    const parent: compiler.Table = .{ .rows = &.{.{ .cells = &.{.{ .spans = &.{}, .nested_table = child }} }} };
    try std.testing.expectError(error.UncompiledTemplate, validateTableSpans(a, parent, null));
}

test "citation raw quote external label survives presentation roundtrip without weakening residual guard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try compileAlloc(a, "Citations:witches' stone", .language, "English", "en", "* '''1895''', ''[https://archive.org/details/x?q=\"witches'+stones\" Notes and Queries]'', page 414:\n*: I found '''witches' stones''' [...compare...] here.", null);
    const decoded = try codec.decodeAlloc(a, bytes, "Citations:witches' stone", .language, .{ .code = "en", .heading = "English" });
    var label: std.ArrayList(u8) = .empty;
    var prose: std.ArrayList(u8) = .empty;
    for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        try prose.appendSlice(a, span.text);
        if (span.kind == .external_link) {
            try std.testing.expectEqualStrings("https://archive.org/details/x?q=", span.target);
            try std.testing.expect(span.italic);
            try label.appendSlice(a, span.text);
        }
    };
    try std.testing.expectEqualStrings("\"witches'+stones\" Notes and Queries", label.items);
    try std.testing.expect(std.mem.indexOf(u8, prose.items, "[...compare...]") != null);
    const raw = [_]compiler.Span{.{ .text = "[https://example.test" }};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &raw, null));
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
    try expectUnknownAtomicSourceLiteral(a, "<li'>word</li>", "&lt;li'&gt;word</li>", "<li'>word");
    try expectUnknownAtomicSourceLiteral(a, "<li\" attr=x>word</li>", "&lt;li\" attr=x&gt;word</li>", "<li\" attr=x>word");
    try expectUnknownAtomicSourceLiteral(a, "<reالميلاد>", "&lt;reالميلاد&gt;", "<reالميلاد>");
    try std.testing.expectError(error.UncompiledPresentation, compileAlloc(a, "entry", .language, "English", "en", "before |} after", null));
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
    const Check = struct {
        const Action = struct { text: []const u8, target: []const u8 };
        fn spans(allocator: A, values: anytype, visible: []const u8, actions: []const Action) !void {
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(allocator);
            var count: usize = 0;
            for (values) |span| {
                try text.appendSlice(allocator, span.text);
                if (span.kind == .external_link) {
                    try std.testing.expect(count < actions.len);
                    try std.testing.expectEqualStrings(actions[count].text, span.text);
                    try std.testing.expectEqualStrings(actions[count].target, span.target);
                    count += 1;
                } else {
                    try std.testing.expect(span.kind == .text);
                    try std.testing.expectEqualStrings("", span.target);
                }
            }
            try std.testing.expectEqual(actions.len, count);
            try std.testing.expectEqualStrings(visible, text.items);
        }
        fn rootLiteral(values: anytype, expected: usize) !void {
            var count: usize = 0;
            for (values) |span| if (std.mem.eql(u8, span.text, "[") and span.provenance == .protected_literal) { count += 1; };
            try std.testing.expectEqual(expected, count);
        }
    };
    const single = &[_]Check.Action{.{ .text = "https://example.test", .target = "https://example.test" }};
    const cases = [_]struct { source: []const u8, body: []const u8, visible: []const u8, reference: bool = true, actions: []const Check.Action = single }{
        .{ .source = "word<ref>[https://example.test Alpha\nBeta</ref>", .body = "[https://example.test Alpha\nBeta", .visible = "[https://example.test Alpha Beta" },
        .{ .source = "word [https://example.test Alpha\nBeta", .body = "word [https://example.test Alpha\nBeta", .visible = "word [https://example.test Alpha Beta", .reference = false },
        .{ .source = "word<ref>[https://outer.test Alpha\n[https://inner.test Beta]</ref>", .body = "[https://outer.test Alpha\n[https://inner.test Beta]", .visible = "[https://outer.test Alpha Beta", .actions = &.{ .{ .text = "https://outer.test", .target = "https://outer.test" }, .{ .text = "Beta", .target = "https://inner.test" } } },
        .{ .source = "word<ref>[https://example.test Alpha\n<nowiki>]</nowiki></ref>", .body = "[https://example.test Alpha\n<nowiki>]</nowiki>", .visible = "[https://example.test Alpha ]" },
        .{ .source = "word<ref>[https://example.test Alpha\n<span title=']'>Beta</span></ref>", .body = "[https://example.test Alpha\n<span title=']'>Beta</span>", .visible = "[https://example.test Alpha Beta" },
        .{ .source = "word<ref>[https://example.test Alpha\n&#93;</ref>", .body = "[https://example.test Alpha\n&#93;", .visible = "[https://example.test Alpha ]" },
        .{ .source = "word<ref>[https://example.test Alpha</ref>Beta]", .body = "[https://example.test Alpha", .visible = "[https://example.test Alpha" },
    };
    for (cases, 0..) |case, index| {
        errdefer std.debug.print("external recovery domain case {d}: {s}\n", .{ index, case.source });
        var report: Fallbacks = .{};
        const encoded = try compileReportedAlloc(a, "entry", .language, "English", "en", case.source, null, &report);
        try std.testing.expectEqualDeep(Fallbacks{ .literal_markup = true }, report);
        const stored = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
        try std.testing.expectEqualSlices(u8, encoded, try codec.encodeAlloc(a, stored));
        try std.testing.expectEqual(@as(usize, if (case.reference) 1 else 0), stored.entry.references.len);
        if (case.reference) {
            try std.testing.expectEqual(@as(usize, 1), stored.entry.references[0].number);
            try Check.spans(a, stored.entry.references[0].spans, case.visible, case.actions);
        } else {
            try std.testing.expectEqual(@as(usize, 1), stored.entry.sections.len);
            try std.testing.expectEqual(@as(usize, 1), stored.entry.sections[0].blocks.len);
            try Check.spans(a, stored.entry.sections[0].blocks[0].spans, case.visible, case.actions);
        }
        var markers: usize = 0;
        var outside: std.ArrayList(u8) = .empty;
        for (stored.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            try outside.appendSlice(a, span.text);
            if (span.role == .reference) {
                markers += 1;
                try std.testing.expectEqualStrings("[1]", span.text);
                try std.testing.expectEqualStrings("#reference-1", span.target);
                try std.testing.expect(span.superscript);
            } else if (case.reference) {
                try std.testing.expect(span.kind == .text);
                try std.testing.expectEqualStrings("", span.target);
            }
        };
        try std.testing.expectEqual(@as(usize, if (case.reference) 1 else 0), markers);
        if (case.reference) try std.testing.expectEqualStrings(if (index == cases.len - 1) "word[1]Beta]" else "word[1]", outside.items);
        var raw: compiler.Renderer = .{ .a = a, .context = .{}, .in_reference = case.reference };
        const raw_spans = try raw.parseSpans(case.body, .{});
        try Check.rootLiteral(raw_spans, 1);
        try std.testing.expect(raw.fallbacks.literal_markup);
        var validated: Fallbacks = .{};
        try validateSpans(a, raw_spans, &validated);
    }
    // A protocol with no address remains unresolved active syntax.
    var invalid_report: Fallbacks = .{};
    try std.testing.expectError(error.UncompiledPresentation, compileReportedAlloc(a, "entry", .language, "English", "en", "word<ref>[https:// Alpha\nBeta]</ref>", null, &invalid_report));
    try std.testing.expect(invalid_report.literal_markup);
    // A valid label owns its complete same-line raw domain before formatting
    // is parsed. Local formatting fragments must not invent unmatched openers.
    for ([_][]const u8{
        "word<ref>[https://example.test <b>Label</b>]</ref>",
        "word<ref><b>[https://example.test Label</b>]</ref>",
    }) |source| {
        var report: Fallbacks = .{};
        const bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", source, null, &report);
        try std.testing.expect(!report.any());
        const stored = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
        try std.testing.expectEqualSlices(u8, bytes, try codec.encodeAlloc(a, stored));
        try std.testing.expectEqual(@as(usize, 1), stored.entry.references.len);
        try Check.spans(a, stored.entry.references[0].spans, "Label", &.{.{ .text = "Label", .target = "https://example.test" }});
        for (stored.entry.references[0].spans) |span| if (span.kind == .external_link) { try std.testing.expect(span.bold); };
    }
    // Literal recovery preserves styles and unrelated actions within their scopes.
    var styled_report: Fallbacks = .{};
    const styled_bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", "''word''<ref>[https://example.test ''Alpha''\nBeta</ref> tail [[Target|label]]", null, &styled_report);
    try std.testing.expectEqualDeep(Fallbacks{ .literal_markup = true }, styled_report);
    const styled = try codec.decodeAlloc(a, styled_bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualSlices(u8, styled_bytes, try codec.encodeAlloc(a, styled));
    try std.testing.expectEqual(@as(usize, 1), styled.entry.references.len);
    try Check.spans(a, styled.entry.references[0].spans, "[https://example.test Alpha Beta", single);
    var alpha = false;
    var beta = false;
    for (styled.entry.references[0].spans) |span| {
        if (std.mem.eql(u8, span.text, "Alpha")) { alpha = true; try std.testing.expect(span.italic); }
        if (std.mem.eql(u8, std.mem.trim(u8, span.text, " "), "Beta")) { beta = true; try std.testing.expect(!span.italic); }
        if (span.kind == .external_link) try std.testing.expect(!span.italic);
    }
    try std.testing.expect(alpha and beta);
    var targets: usize = 0;
    var styled_markers: usize = 0;
    var styled_word = false;
    var styled_outside: std.ArrayList(u8) = .empty;
    defer styled_outside.deinit(a);
    for (styled.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        try styled_outside.appendSlice(a, span.text);
        if (std.mem.eql(u8, span.text, "word")) { styled_word = true; try std.testing.expect(span.italic); }
        if (span.kind == .link and span.role != .reference) {
            targets += 1;
            try std.testing.expectEqualStrings("Target", span.target);
            try std.testing.expectEqualStrings("label", span.text);
            try std.testing.expect(!span.italic);
        }
        if (span.role == .reference) {
            styled_markers += 1;
            try std.testing.expectEqualStrings("[1]", span.text);
            try std.testing.expectEqualStrings("#reference-1", span.target);
            try std.testing.expect(span.superscript and !span.italic);
        }
    };
    try std.testing.expect(styled_word);
    try std.testing.expectEqualStrings("word[1] tail label", styled_outside.items);
    try std.testing.expectEqual(@as(usize, 1), styled_markers);
    try std.testing.expectEqual(@as(usize, 1), targets);
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
    try validateSpans(a, split.spans.items, &split_report);
    try Check.rootLiteral(split.spans.items, 1);
    try Check.spans(a, split.spans.items, "[https://example.test Alpha Beta]", single);
    try std.testing.expect(split.fallbacks.literal_markup);
    // Each authored newline bounds its own unmatched root. The final closer
    // remains literal and cannot turn earlier prose into a bracketed label.
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
    try std.testing.expectEqual(@as(usize, 128), proved);
    var repeated_report: Fallbacks = .{};
    try validateSpans(a, repeated_spans, &repeated_report);
    var repeated_expected: std.ArrayList(u8) = .empty;
    defer repeated_expected.deinit(a);
    var repeated_actions: [128]Check.Action = undefined;
    for (&repeated_actions) |*action| {
        action.* = single[0];
        try repeated_expected.appendSlice(a, "[https://example.test Alpha ");
    }
    try repeated_expected.append(a, ']');
    try Check.spans(a, repeated_spans, repeated_expected.items, &repeated_actions);
    const repeated_source = try std.fmt.allocPrint(a, "word<ref>{s}</ref>", .{repeated.items});
    var repeated_document_report: Fallbacks = .{};
    const repeated_bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", repeated_source, null, &repeated_document_report);
    try std.testing.expectEqualDeep(Fallbacks{ .literal_markup = true }, repeated_document_report);
    const repeated_stored = try codec.decodeAlloc(a, repeated_bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualSlices(u8, repeated_bytes, try codec.encodeAlloc(a, repeated_stored));
    try std.testing.expectEqual(@as(usize, 1), repeated_stored.entry.references.len);
    try Check.spans(a, repeated_stored.entry.references[0].spans, repeated_expected.items, &repeated_actions);
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
        } else if (span.superscript) {
            try std.testing.expect(!span.small);
            try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 1.2), span.font_scale orelse return error.TestUnexpectedResult, 0.000001);
            try sic_text.appendSlice(a, span.text);
        }
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

test "RW rejected HTML link targets survive semantic table roundtrip without navigation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "== Ikinyarwanda ==\n# programmable device\n{|\n|-\n| [[<span lang=ar>حاسوب</span>]], [[<span lang=ar>كمبيوتر</span>]]\n|-\n| [[<span lang=ru>компьютер</span>]] and [[حاسوب|<span lang=ar>حاسوب</span>]]\n|}\n";
    var report: Fallbacks = .{};
    const encoded = try compileReportedAlloc(a, "mudasobwa", .language, "Ikinyarwanda", "rw", source, null, &report);
    const decoded = try codec.decodeAlloc(a, encoded, "mudasobwa", .language, .{ .code = "rw", .heading = "Ikinyarwanda" });
    var visible: std.ArrayList(u8) = .empty;
    var actions: usize = 0;
    var ar: usize = 0;
    var ru: usize = 0;
    var tables: usize = 0;
    for (decoded.entry.sections) |section| for (section.blocks) |block| {
        if (block.table) |table| {
            tables += 1;
            for (table.rows) |row| for (row.cells) |cell| for (cell.spans) |span| {
                try visible.appendSlice(a, span.text);
                if (span.kind == .link) {
                    actions += 1;
                    try std.testing.expectEqualStrings("حاسوب", span.target);
                    try std.testing.expectEqualStrings("ar", span.language);
                } else try std.testing.expectEqualStrings("", span.target);
                if (std.mem.eql(u8, span.language, "ar")) ar += 1;
                if (std.mem.eql(u8, span.language, "ru")) ru += 1;
            };
        }
    };
    try std.testing.expectEqual(@as(usize, 1), tables);
    try std.testing.expectEqual(@as(usize, 1), actions);
    try std.testing.expect(ar >= 3 and ru >= 1 and report.literal_markup);
    for ([_][]const u8{ "[[حاسوب]]", "[[كمبيوتر]]", "[[компьютер]]" }) |text|
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, visible.items, text));
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "<span") == null);
}

test "invalid title literal delimiters do not authorize deferred or parsed HTML content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed_html = [_]compiler.Span{.{ .text = "<span lang=ar>حاسوب</span>" }};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &parsed_html, null));
    const parsed_template = [_]compiler.Span{.{ .text = "{{deferred}}" }};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &parsed_template, null));
    try std.testing.expectError(error.UncompiledTemplate, compileAlloc(a, "entry", .language, "English", "en", "[[<span>{{missing}}</span>]]", null));
    try expectUnknownAtomicSourceLiteral(a, "[[<li'>word</li>]]", "[[&lt;li'&gt;word</li>]]", "[[<li'>word]]");
    _ = try compileAlloc(a, "entry", .language, "English", "en", "[[&lt;span lang=ar&gt;حاسوب&lt;/span&gt;]]", null);
}


test "publication roundtrip keeps unmatched external opener children at LF and EOF" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", "\nnext [[C]]" }) |tail| {
        const source = try std.fmt.allocPrint(a, "==English==\n===Noun===\n# Before [https://example.test unfinished ''kept'' [[B]] tail{s}", .{tail});
        const encoded = try compileAlloc(a, "entry", .language, "English", "en", source, null);
        const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
        var url = false;
        var child = false;
        var italic = false;
        var following = tail.len == 0;
        for (decoded.entry.sections) |section| for (section.blocks) |block_value| for (block_value.spans) |span| {
            if (span.kind == .external_link and std.mem.eql(u8, span.target, "https://example.test")) url = true;
            if (span.kind == .link and std.mem.eql(u8, span.target, "B")) child = true;
            if (span.kind == .link and std.mem.eql(u8, span.target, "C")) following = true;
            if (std.mem.eql(u8, span.text, "kept")) italic = span.italic;
        };
        try std.testing.expect(url and child and italic and following);
    }
    for ([_][]const u8{ "[https:// unfinished", "[https:// label]" }) |invalid| {
        const source = try std.fmt.allocPrint(a, "==English==\n===Noun===\n# {s}", .{invalid});
        try std.testing.expectError(error.UncompiledPresentation, compileAlloc(a, "entry", .language, "English", "en", source, null));
    }
}


test "generic document metadata does not claim classified single language authority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const source = "==English==\n===Noun===\n# English meaning.\n==French==\n===Verb===\n# French meaning.\n";
    const encoded = try compileAlloc(a, "unbound", .language, "Hausa", "ha", source, null);
    const decoded = try codec.decodeAlloc(a, encoded, "unbound", .language, .{ .code = "ha", .heading = "Hausa" });
    try std.testing.expectEqual(@as(usize, 2), decoded.entry.organization.lexemes.len);
    try std.testing.expectEqualStrings("English", decoded.entry.organization.lexemes[0].language);
    try std.testing.expectEqualStrings("French", decoded.entry.organization.lexemes[1].language);
    const unknown = try compileAlloc(a, "unbound", .language, "Unclassified", "", source, null);
    const unresolved = try codec.decodeAlloc(a, unknown, "unbound", .language, .{ .code = "", .heading = "Unclassified" });
    for (unresolved.entry.organization.lexemes) |lexeme| try std.testing.expectEqualStrings("", lexeme.language);
}


test "heading free cell rules survive typed codec in source order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "==01==\n{|\n| '''A'''\n----\n*[[alal]]\n'''B'''\n----\n*''[[baat]]''\n|}\n";
    const bytes = try compileAlloc(a, "cell-rules", .language, "Unclassified", "", source, null);
    const decoded = try codec.decodeAlloc(a, bytes, "cell-rules", .language, .{ .code = "", .heading = "Unclassified" });
    try std.testing.expectEqual(@as(usize, 1), decoded.entry.sections.len);
    try std.testing.expectEqualStrings("01", decoded.entry.sections[0].title);
    try std.testing.expectEqual(@as(usize, 1), decoded.entry.sections[0].blocks.len);
    const cell = decoded.entry.sections[0].blocks[0].table.?.rows[0].cells[0];
    try std.testing.expect(cell.spans.len == 0 and cell.nested_table == null);
    const ordered = cell.blocks orelse return error.TestUnexpectedResult;
    const kinds = [_]types.BlockKind{ .paragraph, .rule, .list_item, .paragraph, .rule, .list_item };
    try std.testing.expectEqual(kinds.len, ordered.len);
    for (ordered, kinds) |block, kind| try std.testing.expectEqual(kind, block.kind);
    for ([_]usize{ 0, 3 }, [_][]const u8{ "A", "B" }) |index, label| {
        try std.testing.expectEqual(@as(usize, 1), ordered[index].spans.len);
        try std.testing.expectEqualStrings(label, ordered[index].spans[0].text);
        try std.testing.expect(ordered[index].spans[0].bold);
    }
    for ([_]usize{ 2, 5 }, [_][]const u8{ "alal", "baat" }, 0..) |index, target, i| {
        try std.testing.expectEqualStrings("*", ordered[index].list_path);
        try std.testing.expectEqual(@as(usize, 1), ordered[index].spans.len);
        const span = ordered[index].spans[0];
        try std.testing.expect(span.kind == .link);
        try std.testing.expectEqualStrings(target, span.target);
        try std.testing.expectEqualStrings(target, span.text);
        try std.testing.expectEqual(i == 1, span.italic);
    }
    try std.testing.expectEqualSlices(u8, bytes, try codec.encodeBuildAlloc(a, decoded.entry.display_title, decoded.entry.sections, decoded.entry.organization, decoded.entry.references, decoded.entry.media));
}


test "angle bracketed external citation keeps typed navigation without synthesized HTML rejection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { source: []const u8, visible: []const u8, target: []const u8, bold_italic: bool = false }{
        .{ .source = "<[http://www.etymonline.com etymonline.com]>", .visible = "<etymonline.com>", .target = "http://www.etymonline.com" },
        .{ .source = "<b><[https://example.test ''label'']></b>", .visible = "<label>", .target = "https://example.test", .bold_italic = true },
        // Exact retained DIQ line56, excluding the enclosing span close whose
        // opener belongs to preceding lines. Metadata is only a test container.
        .{ .source = "# Etymonline. ''Online English Etymology Dictionary''. <[http://www.etymonline.com etymonline.com]> by Douglas Harper.", .visible = "Etymonline. Online English Etymology Dictionary. <etymonline.com> by Douglas Harper.", .target = "http://www.etymonline.com" },
    };
    for (cases) |case| {
        var report: Fallbacks = .{};
        const bytes = try compileReportedAlloc(a, "-ıstan", .language, "English", "en", case.source, null, &report);
        const decoded = try codec.decodeAlloc(a, bytes, "-ıstan", .language, .{ .code = "en", .heading = "English" });
        var visible: std.ArrayList(u8) = .empty;
        var actions: usize = 0;
        for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            try visible.appendSlice(a, span.text);
            if (span.kind == .external_link) {
                actions += 1;
                try std.testing.expectEqualStrings(case.target, span.target);
                try std.testing.expectEqual(case.bold_italic, span.bold);
                try std.testing.expectEqual(case.bold_italic, span.italic);
            }
            if (std.mem.eql(u8, span.text, "<") or std.mem.eql(u8, span.text, ">"))
                try std.testing.expect(span.kind == .text and span.target.len == 0);
        };
        try std.testing.expectEqualStrings(case.visible, visible.items);
        try std.testing.expectEqual(@as(usize, 1), actions);
        try std.testing.expect(!report.any());
    }
    // Identical display bytes without authored-boundary proof remain rejected.
    const raw = [_]compiler.Span{
        .{ .text = "<" },
        .{ .kind = .external_link, .text = "label", .target = "https://example.test" },
        .{ .text = ">" },
    };
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &raw, null));
    // Source compilation already preserves an ordinary unregistered tag as
    // literal text. The residual guard below receives no such source proof.
    var diq_formula_report: Fallbacks = .{};
    const diq_formula_bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", "<C6H6>", null, &diq_formula_report);
    const diq_formula_decoded = try codec.decodeAlloc(a, diq_formula_bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    var diq_formula_visible: std.ArrayList(u8) = .empty;
    for (diq_formula_decoded.entry.sections) |diq_formula_section| for (diq_formula_section.blocks) |diq_formula_block| for (diq_formula_block.spans) |diq_formula_span| {
        try diq_formula_visible.appendSlice(a, diq_formula_span.text);
        try std.testing.expect(diq_formula_span.kind == .text and diq_formula_span.target.len == 0);
    };
    try std.testing.expectEqualStrings("<C6H6>", diq_formula_visible.items);
    try std.testing.expect(diq_formula_report.literal_markup);
    try std.testing.expectError(error.UncompiledPresentation, compiler.requireCompiledText("<C6H6>"));
    for ([_][]const u8{ "<[https:// broken]>", "before |} after" }) |source|
        try std.testing.expectError(error.UncompiledPresentation, compileAlloc(a, "entry", .language, "English", "en", source, null));
}


test "single-brace template recovery does not exempt ordinary inline table delimiters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: Fallbacks = .{};
    const bytes = try compileReportedAlloc(a, "entry", .language, "Unclassified", "", "{{ png.|} [[Child|child]] ''kept''", null, &report);
    const decoded = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "", .heading = "Unclassified" });
    var visible: std.ArrayList(u8) = .empty;
    var actions: usize = 0;
    var italic = false;
    for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        try visible.appendSlice(a, span.text);
        if (span.kind == .link and std.mem.eql(u8, span.target, "Child")) actions += 1;
        if (std.mem.eql(u8, span.text, "kept") and span.italic) italic = true;
    };
    try std.testing.expectEqualStrings("[malformed template] child kept", visible.items);
    try std.testing.expect(actions == 1 and italic and report.literal_markup);
    for ([_][]const u8{ "before |} after", "* before |} after", "* |} suffix |}", "{{ png.|} suffix |}" }) |source| {
        var rejected: Fallbacks = .{};
        try std.testing.expectError(error.UncompiledPresentation, compileReportedAlloc(a, "entry", .language, "Unclassified", "", source, null, &rejected));
    }
    try std.testing.expectError(error.UncompiledPresentation, requireCompiledText("{{ png.|}"));
    try std.testing.expectError(error.UncompiledPresentation, requireCompiledText("before |} after"));
}


test "dotted external citation label roundtrips without relaxing raw residual validation" {
    var dotted_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer dotted_arena.deinit();
    const dotted_a = dotted_arena.allocator();
    const dotted_cases = [_]struct { source: []const u8, styled: bool }{
        // Exact bracketed citation from retained DIQ adır expanded line 81.
        .{ .source = "[http://www.nisanyansozluk.com <nisanyansozluk.com>]", .styled = false },
        .{ .source = "<b>[http://www.nisanyansozluk.com ''<nisanyansozluk.com>'']</b>", .styled = true },
    };
    for (dotted_cases) |dotted_case| {
        var dotted_report: Fallbacks = .{};
        const dotted_bytes = try compileReportedAlloc(dotted_a, "adır", .language, "English", "en", dotted_case.source, null, &dotted_report);
        const dotted_decoded = try codec.decodeAlloc(dotted_a, dotted_bytes, "adır", .language, .{ .code = "en", .heading = "English" });
        var dotted_visible: std.ArrayList(u8) = .empty;
        for (dotted_decoded.entry.sections) |dotted_section| for (dotted_section.blocks) |dotted_block| for (dotted_block.spans) |dotted_span| {
            try dotted_visible.appendSlice(dotted_a, dotted_span.text);
            try std.testing.expect(dotted_span.kind == .external_link);
            try std.testing.expectEqualStrings("http://www.nisanyansozluk.com", dotted_span.target);
            try std.testing.expectEqual(dotted_case.styled, dotted_span.bold);
            try std.testing.expectEqual(dotted_case.styled, dotted_span.italic);
        };
        try std.testing.expectEqualStrings("<nisanyansozluk.com>", dotted_visible.items);
        try std.testing.expect(dotted_report.literal_markup);
    }
    const dotted_raw = [_]compiler.Span{.{ .kind = .external_link, .text = "<nisanyansozluk.com>", .target = "http://www.nisanyansozluk.com" }};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(dotted_a, &dotted_raw, null));
    try std.testing.expectError(error.UncompiledPresentation, compiler.requireCompiledText("<nisanyansozluk.com>"));
    for ([_][]const u8{ "<[https:// broken]>", "before |} after" }) |dotted_rejected|
        try std.testing.expectError(error.UncompiledPresentation, compileAlloc(dotted_a, "entry", .language, "English", "en", dotted_rejected, null));
    var dotted_supported_report: Fallbacks = .{};
    const dotted_supported_bytes = try compileReportedAlloc(dotted_a, "entry", .language, "English", "en", "<b>kept</b>", null, &dotted_supported_report);
    const dotted_supported = try codec.decodeAlloc(dotted_a, dotted_supported_bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    var dotted_supported_text: std.ArrayList(u8) = .empty;
    for (dotted_supported.entry.sections) |dotted_section| for (dotted_section.blocks) |dotted_block| for (dotted_block.spans) |dotted_span| {
        try dotted_supported_text.appendSlice(dotted_a, dotted_span.text);
        try std.testing.expect(dotted_span.kind == .text and dotted_span.target.len == 0 and dotted_span.bold);
    };
    try std.testing.expectEqualStrings("kept", dotted_supported_text.items);
    try std.testing.expect(!dotted_supported_report.any());
}


test "iframe literal angles roundtrip without exempting attributes or body validation" {
    var pa_arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer pa_arena.deinit();
    const pa_alloc = pa_arena.allocator();
    for ([_][]const u8{ "iframe" }) |pa_tag| {
        const pa_source = try std.fmt.allocPrint(pa_alloc, "<{s}>[[Target|linked]]</{s}>", .{pa_tag, pa_tag});
        var pa_report: Fallbacks = .{};
        const pa_bytes = try compileReportedAlloc(pa_alloc, "entry", .language, "English", "en", pa_source, null, &pa_report);
        const pa_stored = try codec.decodeAlloc(pa_alloc, pa_bytes, "entry", .language, .{ .code = "en", .heading = "English" });
        try std.testing.expectEqualSlices(u8, pa_bytes, try codec.encodeAlloc(pa_alloc, pa_stored));
        var pa_visible: std.ArrayList(u8) = .empty;
        var pa_actions: usize = 0;
        for (pa_stored.entry.sections) |pa_section| for (pa_section.blocks) |pa_block| for (pa_block.spans) |pa_span| {
            try pa_visible.appendSlice(pa_alloc, pa_span.text);
            if (pa_span.kind == .link) {
                pa_actions += 1;
                try std.testing.expectEqualStrings("Target", pa_span.target);
                try std.testing.expectEqualStrings("linked", pa_span.text);
            } else try std.testing.expect(pa_span.kind == .text and pa_span.target.len == 0);
        };
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(pa_alloc, "<{s}>linked</{s}>", .{pa_tag, pa_tag}), pa_visible.items);
        try std.testing.expectEqual(@as(usize, 1), pa_actions);
        try std.testing.expect(pa_report.unsupported_element);
        // Protection belongs to the recognized tag token, never the ordinary body.
        const pa_bad_body = try std.fmt.allocPrint(pa_alloc, "<{s}>before |}} after</{s}>", .{pa_tag, pa_tag});
        try std.testing.expectError(error.UncompiledPresentation, compileAlloc(pa_alloc, "entry", .language, "English", "en", pa_bad_body, null));
    }
    // Existing disallowed-tag rejection contracts outside iframe are unchanged.
    for ([_][]const u8{ "script", "style", "object", "embed" }) |pa_other_tag| {
        const pa_other_source = try std.fmt.allocPrint(pa_alloc, "X <{s}>y</{s}> Z", .{pa_other_tag, pa_other_tag});
        try std.testing.expectError(error.UncompiledPresentation, compileAlloc(pa_alloc, "entry", .language, "English", "en", pa_other_source, null));
    }
    for ([_][]const u8{
        "<script>https://example.test</script>",
        "<iframe data-note='{{deferred}}'></iframe>",
        "<iframe data-note='before |} after'></iframe>",
        "<iframe data-note='[https:// broken]'></iframe>",
        "<iframe>before |} after</iframe>",
    }) |pa_strict_source|
        try std.testing.expectError(error.UncompiledPresentation, compileAlloc(pa_alloc, "entry", .language, "English", "en", pa_strict_source, null));
    const pa_raw = [_]compiler.Span{.{ .text = "<iframe>" }};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(pa_alloc, &pa_raw, null));
    try std.testing.expectError(error.UncompiledPresentation, compiler.requireCompiledText("<iframe>"));
    var pa_supported_report: Fallbacks = .{};
    const pa_supported_bytes = try compileReportedAlloc(pa_alloc, "entry", .language, "English", "en", "<b>bold</b><ref>note</ref>", null, &pa_supported_report);
    const pa_supported = try codec.decodeAlloc(pa_alloc, pa_supported_bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expect(!pa_supported_report.unsupported_element);
    try std.testing.expectEqual(@as(usize, 1), pa_supported.entry.references.len);
    var pa_bold_seen = false;
    for (pa_supported.entry.sections) |pa_section| for (pa_section.blocks) |pa_block| for (pa_block.spans) |pa_span| {
        if (std.mem.eql(u8, pa_span.text, "bold")) { pa_bold_seen = true; try std.testing.expect(pa_span.bold); }
    };
    try std.testing.expect(pa_bold_seen);
}


test "restored display close survives codec without exempting outside text or targets" {
    var nah_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer nah_arena.deinit();
    const nah_a = nah_arena.allocator();
    const nah_bytes = try compileAlloc(nah_a, "entry", .language, "English", "en", "''[[x|[label]]]]''", null);
    const nah_record = try codec.decodeAlloc(nah_a, nah_bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualSlices(u8, nah_bytes, try codec.encodeAlloc(nah_a, nah_record));
    var nah_visible: std.ArrayList(u8) = .empty;
    var nah_action: std.ArrayList(u8) = .empty;
    var nah_outside: usize = 0;
    for (nah_record.entry.sections) |nah_section| for (nah_section.blocks) |nah_block| for (nah_block.spans) |nah_span| {
        try nah_visible.appendSlice(nah_a, nah_span.text);
        try std.testing.expect(nah_span.italic);
        if (nah_span.kind == .link) {
            try std.testing.expectEqualStrings("x", nah_span.target);
            try nah_action.appendSlice(nah_a, nah_span.text);
        } else {
            try std.testing.expectEqualStrings("]", nah_span.text);
            try std.testing.expectEqualStrings("", nah_span.target);
            nah_outside += 1;
        }
    };
    try std.testing.expectEqualStrings("[label]]", nah_visible.items);
    try std.testing.expectEqualStrings("[label]", nah_action.items);
    try std.testing.expectEqual(@as(usize, 1), nah_outside);
    // Same visible bytes, entirely parsed/authored and without parser evidence.
    const nah_unowned = [_]compiler.Span{.{ .kind = .link, .target = "x", .text = "[label]" }, .{ .text = "]" }};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(nah_a, &nah_unowned, null));
    try std.testing.expectError(error.UncompiledPresentation, compiler.requireCompiledText("]]"));
    // The unchanged source parser diagnoses an orphan outside pair. It does
    // not pass those two authored bytes to the final residual validator.
    var nah_recovery_report: Fallbacks = .{};
    const nah_recovery_bytes = try compileReportedAlloc(nah_a, "entry", .language, "English", "en", "[[x|[label]]]]]", null, &nah_recovery_report);
    const nah_recovery_record = try codec.decodeAlloc(nah_a, nah_recovery_bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualSlices(u8, nah_recovery_bytes, try codec.encodeAlloc(nah_a, nah_recovery_record));
    var nah_recovery_visible: std.ArrayList(u8) = .empty;
    var nah_recovery_action: std.ArrayList(u8) = .empty;
    var nah_recovery_markers: usize = 0;
    for (nah_recovery_record.entry.sections) |nah_recovery_section| for (nah_recovery_section.blocks) |nah_recovery_block| for (nah_recovery_block.spans) |nah_recovery_span| {
        try nah_recovery_visible.appendSlice(nah_a, nah_recovery_span.text);
        if (nah_recovery_span.kind == .link) {
            try std.testing.expectEqualStrings("x", nah_recovery_span.target);
            try nah_recovery_action.appendSlice(nah_a, nah_recovery_span.text);
        } else {
            try std.testing.expectEqualStrings(" [malformed link]", nah_recovery_span.text);
            try std.testing.expectEqualStrings("", nah_recovery_span.target);
            nah_recovery_markers += 1;
        }
    };
    try std.testing.expectEqualStrings("[label] [malformed link]", nah_recovery_visible.items);
    try std.testing.expectEqualStrings("[label]", nah_recovery_action.items);
    try std.testing.expectEqual(@as(usize, 1), nah_recovery_markers);
    try std.testing.expect(nah_recovery_report.literal_markup);
    // An owned display byte still grants no exemption to a raw outside pair.
    const nah_owned_then_raw = [_]compiler.Span{
        .{ .kind = .link, .target = "x", .text = "[label" },
        .{ .kind = .link, .target = "x", .text = "]", .provenance = .entity_literal },
        .{ .text = "]]" },
    };
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(nah_a, &nah_owned_then_raw, null));
    const nah_bad_target = [_]compiler.Span{.{ .kind = .link, .target = "{{unresolved}}", .text = "]", .provenance = .entity_literal }};
    try std.testing.expectError(error.UncompiledTemplate, validateSpans(nah_a, &nah_bad_target, null));
}

const TlMalformedLayoutWitness = struct {
    visible: std.ArrayList(u8) = .empty,
    targets: std.ArrayList([]const u8) = .empty,
    diagnostics: usize = 0,
    tables: usize = 0,
    bold: bool = false,
    italic: bool = false,

    fn spans(self: *@This(), a: A, values: []const types.Span) !void {
        for (values) |span| {
            if (span.kind == .line_break) try self.visible.append(a, '\n') else try self.visible.appendSlice(a, span.text);
            if (span.kind == .link or span.kind == .external_link) try self.targets.append(a, span.target);
            if (std.mem.eql(u8, span.text, "[malformed table]")) {
                try std.testing.expect(span.kind == .text and span.target.len == 0);
                self.diagnostics += 1;
            }
            if (std.mem.indexOf(u8, span.text, "bold") != null and span.bold) self.bold = true;
            if (std.mem.indexOf(u8, span.text, "italic") != null and span.italic) self.italic = true;
        }
    }
    fn table(self: *@This(), a: A, value: types.Table) anyerror!void {
        self.tables += 1;
        try self.spans(a, value.caption);
        for (value.rows) |row| for (row.cells) |cell| {
            if (cell.blocks) |children| try self.blocks(a, children) else if (cell.nested_table) |child| try self.table(a, child) else try self.spans(a, cell.spans);
        };
    }
    fn blocks(self: *@This(), a: A, values: []const types.Block) anyerror!void {
        for (values) |block| {
            try self.spans(a, block.spans);
            if (block.table) |value| try self.table(a, value);
        }
    }
    fn hasTarget(self: @This(), wanted: []const u8) bool {
        for (self.targets.items) |target| if (std.mem.eql(u8, target, wanted)) return true;
        return false;
    }
};

test "malformed TL layout preserves physical close diagnostics and translation actions through codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Exact structural shape of both captured abaka translation sections:
    // the outer DIV and HTML table are unmatched, but the inner DIVs match.
    const source =
        "# prefix [[Before|before]]\n" ++
        "<div class=\"NavFrame\"><div class=\"NavHead\">First gloss</div><div class=\"NavContent\"><table class=\"translations\"><tr><td>\n" ++
        "<div class=\"references-small\">\n*[[Tsino]]: [[蕉麻]] (''italic'')\n*'''bold''' [[马尼拉麻]]\n|}</div></div>\n\n" ++
        "<div class=\"NavFrame\"><div class=\"NavHead\">Second gloss</div><div class=\"NavContent\"><table class=\"translations\"><tr><td>\n" ++
        "<div class=\"references-small\">\n*[[Tseko]]: [[manilské konopí]]\n|}</div></div>\n" ++
        "# suffix [[After|after]]\n";
    var report: Fallbacks = .{};
    const bytes = try compileReportedAlloc(a, "abaka", .language, "Tagalog", "tl", source, null, &report);
    const decoded = try codec.decodeAlloc(a, bytes, "abaka", .language, .{ .code = "tl", .heading = "Tagalog" });
    try std.testing.expectEqualSlices(u8, bytes, try codec.encodeAlloc(a, decoded));
    var observed: TlMalformedLayoutWitness = .{};
    for (decoded.entry.sections) |section| try observed.blocks(a, section.blocks);
    try std.testing.expectEqual(@as(usize, 2), observed.diagnostics);
    try std.testing.expect(report.malformed_table and report.literal_markup);
    try std.testing.expect(observed.bold and observed.italic);
    for ([_][]const u8{ "Before", "Tsino", "蕉麻", "马尼拉麻", "Tseko", "manilské konopí", "After" }) |target|
        try std.testing.expect(observed.hasTarget(target));
    for ([_][]const u8{ "prefix", "First gloss", "Second gloss", "suffix", "蕉麻", "manilské konopí" }) |text|
        try std.testing.expect(std.mem.indexOf(u8, observed.visible.items, text) != null);
    try std.testing.expect(std.mem.indexOf(u8, observed.visible.items, "|}") == null);
}

test "TL layout close routing keeps matched tables and protected action reference domains strict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A real matched table retains its cell and action; its following orphan
    // closer still has an independently authored physical line boundary.
    const matched = "<div><table><tr><td>[[Cell|cell]]</td></tr></table>\n|} suffix [[After|after]]\n</div>";
    var table_report: Fallbacks = .{};
    const bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", matched, null, &table_report);
    const decoded = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    var observed: TlMalformedLayoutWitness = .{};
    for (decoded.entry.sections) |section| try observed.blocks(a, section.blocks);
    try std.testing.expectEqual(@as(usize, 1), observed.tables);
    try std.testing.expectEqual(@as(usize, 1), observed.diagnostics);
    try std.testing.expect(observed.hasTarget("Cell") and observed.hasTarget("After"));
    try std.testing.expectEqualSlices(u8, bytes, try codec.encodeAlloc(a, decoded));
    for ([_][]const u8{
        "<div><nowiki>\n|}\n</nowiki></div>",
        "<div><pre>\n|}\n</pre></div>",
        "<div>\n&#124;}\n</div>",
    }) |protected_source| {
        var report: Fallbacks = .{};
        const protected_bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", protected_source, null, &report);
        const protected_decoded = try codec.decodeAlloc(a, protected_bytes, "entry", .language, .{ .code = "en", .heading = "English" });
        var protected: TlMalformedLayoutWitness = .{};
        for (protected_decoded.entry.sections) |section| try protected.blocks(a, section.blocks);
        try std.testing.expect(std.mem.indexOf(u8, protected.visible.items, "|}") != null);
        try std.testing.expectEqual(@as(usize, 0), protected.diagnostics);
        try std.testing.expect(!report.malformed_table);
    }
    for ([_][]const u8{
        "<div>|} same line</div>",
        "<div>first\ninline |} suffix</div>",
        "[[Target|<div>first\n|} label</div>]]",
        "<ref><div>first\n|} reference</div></ref>",
        "<div>first\n|} <script>still strict</script></div>",
    }) |strict_source| {
        var report: Fallbacks = .{};
        try std.testing.expectError(error.UncompiledPresentation, compileReportedAlloc(a, "entry", .language, "English", "en", strict_source, null, &report));
    }
    const leaked = [_]compiler.Span{.{ .text = "|}" }};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &leaked, null));
    try std.testing.expectError(error.UncompiledPresentation, requireCompiledText("|}"));
}

test "TL protected-only layout does not promote tag-local list or heading markers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "* literal", "== literal ==" }) |first_line| {
        for ([_]bool{ false, true }) |with_physical_close| {
            const source = try std.fmt.allocPrint(a,
                "<div><table><tr><td>{s}<nowiki>\n|}}\n</nowiki>{s}</div>",
                .{ first_line, if (with_physical_close) "\n|} actual [[After|after]]" else "" });
            var report: Fallbacks = .{};
            const bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", source, null, &report);
            const decoded = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
            var observed: TlMalformedLayoutWitness = .{};
            for (decoded.entry.sections) |section| try observed.blocks(a, section.blocks);
            try std.testing.expect(std.mem.indexOf(u8, observed.visible.items, first_line) != null);
            try std.testing.expect(std.mem.indexOf(u8, observed.visible.items, "|}") != null);
            try std.testing.expectEqual(@as(usize, if (with_physical_close) 1 else 0), observed.diagnostics);
            try std.testing.expectEqual(with_physical_close, report.malformed_table);
            if (with_physical_close) try std.testing.expect(observed.hasTarget("After"));
            try std.testing.expectEqualSlices(u8, bytes, try codec.encodeAlloc(a, decoded));
        }
    }
}


test "orphan gallery close survives codec with matched media table and bibliography action" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prefix = "==Heading==\n<Gallery>\nFile:Cat.jpg|caption\n</Gallery>\n<div class=NavFrame><div class=NavContent>\n{| class=wikitable\n| '''cell''' || [[Cell|linked]]\n|}\n</div></div>\n preformatted body\n\n'''Bibliography'''\n[[Bibliography|bibliography]]''";
    const suffix = "'' [[Tail|suffix]]";
    const source = try std.mem.concat(a, u8, &.{ prefix, "</Gallery>", suffix });
    const reference = try std.mem.concat(a, u8, &.{ prefix, "&lt;/Gallery>", suffix });
    var report: Fallbacks = .{};
    const bytes = try compileReportedAlloc(a, "entry", .language, "Unclassified", "", source, null, &report);
    const expected = try compileAlloc(a, "entry", .language, "Unclassified", "", reference, null);
    try std.testing.expectEqualSlices(u8, expected, bytes);
    const stored = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "", .heading = "Unclassified" });
    try std.testing.expectEqualSlices(u8, bytes, try codec.encodeAlloc(a, stored));
    try std.testing.expect(report.literal_markup);
    try std.testing.expectEqual(@as(usize, 1), stored.entry.media.len);
    var heading = false;
    var bibliography = false;
    var tail = false;
    var close_text: std.ArrayList(u8) = .empty;
    for (stored.entry.sections) |section| {
        if (std.mem.eql(u8, section.title, "Heading")) heading = true;
        for (section.blocks) |block| for (block.spans) |span| {
            if (span.kind == .link and std.mem.eql(u8, span.target, "Bibliography")) {
                bibliography = true;
                try std.testing.expectEqualStrings("bibliography", span.text);
            }
            if (span.kind == .link and std.mem.eql(u8, span.target, "Tail")) {
                tail = true;
                try std.testing.expectEqualStrings("suffix", span.text);
            }
            if (span.italic and span.kind == .text) try close_text.appendSlice(a, span.text);
        };
    }
    try std.testing.expect(heading and bibliography and tail);
    try std.testing.expectEqualStrings("</Gallery>", close_text.items);
    // Existing malformed-link recovery remains visible and non-actionable.
    // Neither an unmatched opener nor an invalid title is an unconditional
    // publication failure: their existing recovery paths clear action state.
    const recovered_cases = [_]struct { source: []const u8, visible: []const u8 }{
        .{ .source = "</Gallery> [[broken", .visible = "</Gallery> [malformed link] broken" },
        .{ .source = "[[</Gallery>|label]]", .visible = "[[</Gallery>|label]]" },
    };
    for (recovered_cases) |case| {
        var recovered_report: Fallbacks = .{};
        const recovered_bytes = try compileReportedAlloc(a, "entry", .language, "Unclassified", "", case.source, null, &recovered_report);
        const recovered = try codec.decodeAlloc(a, recovered_bytes, "entry", .language, .{ .code = "", .heading = "Unclassified" });
        try std.testing.expectEqualSlices(u8, recovered_bytes, try codec.encodeAlloc(a, recovered));
        var visible: std.ArrayList(u8) = .empty;
        for (recovered.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            try visible.appendSlice(a, span.text);
            try std.testing.expect(span.kind == .text and span.target.len == 0);
        };
        try std.testing.expectEqualStrings(case.visible, visible.items);
        try std.testing.expect(recovered_report.literal_markup);
    }
    // An escaped display token never exempts unrelated residuals or targets.
    for ([_][]const u8{
        "</Gallery> before |} after",
        "</Gallery x>",
        "</Gallery/>",
        "[https://example.test </Gallery>]",
    }) |rejected| try std.testing.expectError(error.UncompiledPresentation, compileAlloc(a, "entry", .language, "Unclassified", "", rejected, null));
    const raw = [_]compiler.Span{.{ .text = "</Gallery>" }};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &raw, null));
    try std.testing.expectError(error.UncompiledPresentation, compiler.requireCompiledText("</Gallery>"));
    // Display provenance cannot exempt unresolved action targets. This
    // validator rejects template syntax, independently of angle-token rules.
    const unresolved_target = [_]compiler.Span{.{ .kind = .link, .text = "label", .target = "{{missing}}", .provenance = .protected_literal }};
    try std.testing.expectError(error.UncompiledTemplate, validateSpans(a, &unresolved_target, null));
}

test "malformed template cell keeps later Cite planning heading observation and complete codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "<h2>Heading</h2>\n{|\n| before<ref group=N name=before>first [[First|one]]</ref><references group=N/>\n|}\n{|\n| {{trad|fr|mettre} des bottes} [[Kept|''kept'']]<ref group=N name=after>''later'' [[Later|two]]</ref>\n|}\n<references group=N/>";
    const prepared = try compiler.preparePageExternalLinksAlloc(a, source, .{});
    var reference_context = try referenceDefinitionsWithMissingAlloc(a, prepared.missing);
    reference_context.citations = prepared.citations;
    const observation = try observeHeadingAnchorsAlloc(a, "entry", prepared.missing, .{}, null, null, null, reference_context, prepared.poem_phase);
    try std.testing.expect(observation.items.len != 0);
    var report: Fallbacks = .{};
    const bytes = try compileReportedAlloc(a, "entry", .language, "Unclassified", "", source, null, &report);
    const stored = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "", .heading = "Unclassified" });
    try std.testing.expectEqualSlices(u8, bytes, try codec.encodeAlloc(a, stored));
    try std.testing.expectEqual(@as(usize, 2), stored.entry.references.len);
    try std.testing.expectEqualStrings("before", stored.entry.references[0].name);
    try std.testing.expectEqualStrings("after", stored.entry.references[1].name);
    try std.testing.expectEqualStrings("N", stored.entry.references[0].group);
    try std.testing.expectEqualStrings("N", stored.entry.references[1].group);
    const Witness = struct {
        visible: std.ArrayList(u8) = .empty,
        kept: bool = false,
        fn spans(self: *@This(), alloc: A, values: []const types.Span) !void {
            for (values) |span| {
                try self.visible.appendSlice(alloc, span.text);
                if (span.kind == .link and std.mem.eql(u8, span.target, "Kept")) {
                    try std.testing.expectEqualStrings("kept", span.text);
                    try std.testing.expect(span.italic);
                    self.kept = true;
                }
            }
        }
    };
    var witness: Witness = .{};
    var tables: usize = 0;
    var heading = false;
    for (stored.entry.sections) |section| {
        if (std.mem.eql(u8, section.title, "Heading")) heading = true;
        for (section.blocks) |block| {
            try witness.spans(a, block.spans);
            if (block.table) |table| {
                tables += 1;
                for (table.rows) |row| for (row.cells) |cell| try witness.spans(a, cell.spans);
            }
        }
    }
    try std.testing.expect(heading and tables == 2 and witness.kept);
    try std.testing.expect(std.mem.indexOf(u8, witness.visible.items, "[malformed template]") != null);
    try std.testing.expect(std.mem.indexOf(u8, witness.visible.items, "des bottes}") != null);
    try std.testing.expect(report.literal_markup);
    var first_action = false;
    var later_action = false;
    var later_italic = false;
    for (stored.entry.references[0].spans) |span| if (span.kind == .link and std.mem.eql(u8, span.target, "First")) { first_action = true; };
    for (stored.entry.references[1].spans) |span| {
        if (span.kind == .link and std.mem.eql(u8, span.target, "Later")) later_action = true;
        if (span.italic and std.mem.eql(u8, span.text, "later")) later_italic = true;
    }
    try std.testing.expect(first_action and later_action and later_italic);
    // Valid but unexpanded invocations remain rejected by strict publication.
    try std.testing.expectError(error.UncompiledTemplate, compileAlloc(a, "entry", .language, "Unclassified", "", "{{unexpanded|x}}<ref>note</ref><references/>", null));
    try std.testing.expectError(error.UncompiledPresentation, compiler.requireCompiledText("{{trad|fr|mettre} des bottes}"));
}


test "linked HTML H1 owner observation preserves original root and protected domains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var namespaces = try NamespaceRegistry.init(a,
        "# wikidict-namespace-registry-v1\n# wiki\tenwiktionary\n# dump-date\t20261001\n# content-language\ten\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tTemplate\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tCategoria\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    const heading = "<h1>[[English|English]]</h1>[[Categoria:English]]";
    const positives = [_][]const u8{ heading ++ "\n# body", heading ++ "\r\n# body", "prefix\n" ++ heading ++ "\n# body", "<h2>English</h2>\n# body" };
    for (positives) |source| {
        const prepared = try compiler.preparePageExternalLinksAlloc(a, source, .{ .namespace_catalog = &namespaces });
        var refs = try referenceDefinitionsWithMissingAlloc(a, prepared.missing);
        refs.citations = prepared.citations;
        const observed = try observeHeadingAnchorsAlloc(a, "entry", prepared.missing, .{}, &namespaces, null, null, refs, prepared.poem_phase);
        try std.testing.expectEqual(@as(usize, 1), observed.page_html_openings.len);
        const opening = observed.page_html_openings[0];
        try std.testing.expect(std.mem.startsWith(u8, prepared.source[opening..], if (std.mem.startsWith(u8, source, "<h2>")) "<h2>" else "<h1>"));
        try std.testing.expect(observed.page_html_source.?.ptr == prepared.source.ptr);
    }
    for ([_][]const u8{
        "<nowiki>\n" ++ heading ++ "\n</nowiki>",
        "<!--\n" ++ heading ++ "\n-->",
        "<pre>\n" ++ heading ++ "\n</pre>",
        "<blockquote>\n" ++ heading ++ "\n</blockquote>",
        "<div>\n" ++ heading ++ "\n</div>",
        "{|\n|\n" ++ heading ++ "\n|}",
        "<ref>\n" ++ heading ++ "\n</ref><references/>",
        "[[target|" ++ heading ++ "]]",
        "prefix " ++ heading,
        "<h1>[[English]]</h1>[[:Category:English]]",
        "<h1>[[File:English|English]]</h1>",
        "<h2>[[English]]</h2>",
    }) |source| {
        const prepared = try compiler.preparePageExternalLinksAlloc(a, source, .{ .namespace_catalog = &namespaces });
        var refs = try referenceDefinitionsWithMissingAlloc(a, prepared.missing);
        refs.citations = prepared.citations;
        const observed = try observeHeadingAnchorsAlloc(a, "entry", prepared.missing, .{}, &namespaces, null, null, refs, prepared.poem_phase);
        if (observed.page_html_openings.len != 0) std.debug.print("unexpected H1 root ownership scope: {s}\n", .{source});
        try std.testing.expectEqual(@as(usize, 0), observed.page_html_openings.len);
    }
}

test "terminal dot abbreviation preserves the captured HER reference through codec" {
    var hr_ref_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer hr_ref_arena.deinit();
    const hr_ref_a = hr_ref_arena.allocator();
    // Exact expanded bolnica line49 reference body, with an independently authored
    // entity-reference spelling at its sole terminal-dot token. This is a focused
    // reference regression, not a substitute for the original full4311 Writer case.
    const hr_ref_before = "==English==\n# [[Child|definition]]<ref name=\"HER\">Ljiljana Jojić, [[w:Ranko Matasović|Ranko Matasović]], gl. ur., ''Hrvatski enciklopedijski rječnik'', 4. sv. : Gra – J, Zagreb : EPH : Novi Liber, 2004., ISBN 953-6045-28-1 (cjelina), ISBN 953-6045-33-8 (";
    const hr_ref_after = " 4.), str. 140.</ref> [[hospitalac|hospitálac]]<ref name=\"HER\"/> [[špitalac|špítàlac]]\n<references/>\n";
    var hr_ref_report: Fallbacks = .{};
    const hr_ref_payload = try compileReportedAlloc(hr_ref_a, "reference-abbreviation", .language, "English", "en", hr_ref_before ++ "<Sv.>" ++ hr_ref_after, null, &hr_ref_report);
    const hr_ref_expected = try compileAlloc(hr_ref_a, "reference-abbreviation", .language, "English", "en", hr_ref_before ++ "&lt;Sv.>" ++ hr_ref_after, null);
    try std.testing.expectEqualSlices(u8, hr_ref_expected, hr_ref_payload);
    try std.testing.expect(hr_ref_report.literal_markup);
    const hr_ref_stored = try codec.decodeAlloc(hr_ref_a, hr_ref_payload, "reference-abbreviation", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualSlices(u8, hr_ref_payload, try codec.encodeAlloc(hr_ref_a, hr_ref_stored));
    try std.testing.expectEqual(@as(usize, 1), hr_ref_stored.entry.references.len);
    const hr_ref_note = hr_ref_stored.entry.references[0];
    try std.testing.expectEqualStrings("HER", hr_ref_note.name);
    var hr_ref_text: std.ArrayList(u8) = .empty;
    var hr_ref_ranko: usize = 0;
    var hr_ref_italic: bool = false;
    for (hr_ref_note.spans) |hr_ref_span| {
        try hr_ref_text.appendSlice(hr_ref_a, hr_ref_span.text);
        if (std.mem.eql(u8, hr_ref_span.text, "Ranko Matasović") and hr_ref_span.target.len != 0) hr_ref_ranko += 1;
        if (std.mem.indexOf(u8, hr_ref_span.text, "Hrvatski enciklopedijski rječnik") != null and hr_ref_span.italic) hr_ref_italic = true;
    }
    try std.testing.expectEqual(@as(usize, 1), hr_ref_ranko);
    try std.testing.expect(hr_ref_italic);
    try std.testing.expect(std.mem.indexOf(u8, hr_ref_text.items, "(<Sv.> 4.), str. 140.") != null);
    try std.testing.expect(std.mem.indexOf(u8, hr_ref_text.items, "ISBN 953-6045-28-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, hr_ref_text.items, "ISBN 953-6045-33-8") != null);
}

test "terminal dot abbreviation does not exempt parsed leftovers or action targets" {
    var hr_strict_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer hr_strict_arena.deinit();
    const hr_strict_a = hr_strict_arena.allocator();
    try std.testing.expectError(error.UncompiledPresentation, compiler.requireCompiledText("<Sv.>"));
    const hr_strict_raw = [_]compiler.Span{ .{ .text = "<Sv.>" } };
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(hr_strict_a, &hr_strict_raw, null));
    const hr_strict_after = [_]compiler.Span{
        .{ .text = "<", .provenance = .protected_literal },
        .{ .text = "Sv.> [[" },
    };
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(hr_strict_a, &hr_strict_after, null));
    const hr_strict_target = [_]compiler.Span{
        .{ .text = "<", .kind = .link, .target = "{{unresolved}}", .provenance = .protected_literal },
    };
    try std.testing.expectError(error.UncompiledTemplate, validateSpans(hr_strict_a, &hr_strict_target, null));
    const hr_strict_label = [_]compiler.Span{
        .{ .text = "<Sv.>", .kind = .link, .target = "Target" },
    };
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(hr_strict_a, &hr_strict_label, null));
}

// Append to presentation_document.zig after the unchanged terminal-dot patch.
test "Breton terminal dot example keeps italic body actions headings and complete codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before = "==Brezhoneg==\n===Furm araogenn===\n# ''[[furm|Furm]] an [[araogenn]] ''[[kenetre]]'', [[displeget]] [[en]] [[eil]] [[gour]] [[lies]]''\n#* ''";
    const after = "''\n====Troidigezhioù====\n* [[galleg]]\n";
    var report: Fallbacks = .{};
    const payload = try compileReportedAlloc(a, "kenetrezoc'h", .language, "Unclassified", "", before ++ "<skouer.>" ++ after, null, &report);
    const reference = try compileAlloc(a, "kenetrezoc'h", .language, "Unclassified", "", before ++ "&lt;skouer.>" ++ after, null);
    try std.testing.expectEqualSlices(u8, reference, payload);
    const stored = try codec.decodeAlloc(a, payload, "kenetrezoc'h", .language, .{ .code = "", .heading = "Unclassified" });
    try std.testing.expectEqualSlices(u8, payload, try codec.encodeAlloc(a, stored));
    var italic_example: std.ArrayList(u8) = .empty;
    var actions = std.StringHashMap(void).init(a);
    var definition = false;
    var quotation_examples: usize = 0;
    var pos_heading = false;
    var translations_heading = false;
    for (stored.entry.sections) |section| {
        if (std.mem.eql(u8, section.title, "Furm araogenn")) pos_heading = true;
        if (std.mem.eql(u8, section.title, "Troidigezhioù")) translations_heading = true;
        for (section.blocks) |block| {
            if (block.kind == .definition) definition = true;
            if (block.kind == .quotation and std.mem.eql(u8, block.list_path, "#*")) {
                var quotation: std.ArrayList(u8) = .empty;
                for (block.spans) |span| {
                    try std.testing.expect(span.kind == .text and span.target.len == 0);
                    if (std.mem.trim(u8, span.text, " \t").len != 0) try std.testing.expect(span.italic);
                    try quotation.appendSlice(a, span.text);
                }
                try std.testing.expectEqualStrings("<skouer.>", std.mem.trim(u8, quotation.items, " \t"));
                quotation_examples += 1;
            }
            for (block.spans) |span| {
                if (span.kind == .text and span.target.len == 0 and span.italic) try italic_example.appendSlice(a, span.text);
                if (span.kind == .link) {
                    try actions.put(span.target, {});
                    if (std.mem.eql(u8, span.target, "kenetre")) try std.testing.expect(!span.italic);
                    if (std.mem.eql(u8, span.target, "furm") or std.mem.eql(u8, span.target, "araogenn") or std.mem.eql(u8, span.target, "displeget")) try std.testing.expect(span.italic);
                }
            }
        }
    }
    try std.testing.expect(pos_heading and translations_heading and definition and report.literal_markup);
    try std.testing.expectEqual(@as(usize, 1), quotation_examples);
    try std.testing.expect(std.mem.indexOf(u8, italic_example.items, "<skouer.>") != null);
    for ([_][]const u8{ "furm", "araogenn", "kenetre", "displeget", "en", "eil", "gour", "lies", "galleg" }) |target| try std.testing.expect(actions.contains(target));
    try std.testing.expectError(error.UncompiledPresentation, compiler.requireCompiledText("<skouer.>"));
}


test "Norwegian translation list tail survives wrapper recovery and complete codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        "==Norsk==\n===Verb===\n# [[fokusere|focus]]\n" ++
        "<div class=\"NavFrame\">\n<div class=\"NavHead\">samle</div>\n<div class=\"NavContent\">\n" ++
        "{| class=\"translations\"\n|-\n| width=48% |\n* [[First|first]]\n| width=1% |\n| width=48% |\n" ++
        "* <span class=\"mallang\">tysk</span>: [[konzentrieren#Tysk|<span lang=\"de\">konzentrieren</span>]]<span class=\"tunk\"> [[Other|<span>other</span>]]</span>|}</div></div>\n" ++
        "|}</div></div>\n====After====\n# [[After|after]]\n";
    const literal_at = std.mem.indexOf(u8, source, "|}</div></div>").?;
    // The reference owns exactly the same two literal bytes; the format's }}
    // escapes one closing brace rather than changing the authored delimiter.
    const reference = try std.fmt.allocPrint(a, "{s}<nowiki>|}}</nowiki>{s}", .{ source[0..literal_at], source[literal_at + 2 ..] });
    var report: Fallbacks = .{};
    const bytes = try compileReportedAlloc(a, "entry", .language, "Norsk", "no", source, null, &report);
    const expected = try compileAlloc(a, "entry", .language, "Norsk", "no", reference, null);
    try std.testing.expectEqualSlices(u8, expected, bytes);
    const decoded = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "no", .heading = "Norsk" });
    try std.testing.expectEqualSlices(u8, bytes, try codec.encodeAlloc(a, decoded));
    const Witness = struct {
        tables: usize = 0,
        marker: usize = 0,
        diagnostic: usize = 0,
        german: bool = false,
        first: bool = false,
        other: bool = false,
        after: bool = false,
        focus: bool = false,
        fn spans(self: *@This(), values: []const types.Span) void {
            for (values) |span| {
                if (std.mem.eql(u8, span.text, "|}") and span.kind == .text and span.target.len == 0) self.marker += 1;
                if (std.mem.eql(u8, span.text, "[malformed table]") and span.kind == .text and span.target.len == 0) self.diagnostic += 1;
                if (span.kind == .link) {
                    if (std.mem.eql(u8, span.target, "konzentrieren#Tysk") and std.mem.eql(u8, span.text, "konzentrieren") and std.mem.eql(u8, span.language, "de")) self.german = true;
                    if (std.mem.eql(u8, span.target, "First")) self.first = true;
                    if (std.mem.eql(u8, span.target, "Other")) self.other = true;
                    if (std.mem.eql(u8, span.target, "After")) self.after = true;
                    if (std.mem.eql(u8, span.target, "fokusere")) self.focus = true;
                }
            }
        }
        fn blocks(self: *@This(), values: []const types.Block) void {
            for (values) |block| {
                self.spans(block.spans);
                if (block.table) |table| {
                    self.tables += 1;
                    self.spans(table.caption);
                    for (table.rows) |row| for (row.cells) |cell| {
                        if (cell.blocks) |children| self.blocks(children) else self.spans(cell.spans);
                    };
                }
            }
        }
    };
    var witness: Witness = .{};
    var after_heading = false;
    for (decoded.entry.sections) |section| {
        if (section.level == 4 and std.mem.eql(u8, section.title, "After")) after_heading = true;
        witness.blocks(section.blocks);
    }
    try std.testing.expectEqual(@as(usize, 1), witness.tables);
    try std.testing.expectEqual(@as(usize, 1), witness.marker);
    try std.testing.expectEqual(@as(usize, 1), witness.diagnostic);
    try std.testing.expect(witness.german and witness.first and witness.other and witness.after and witness.focus and after_heading);
    try std.testing.expect(report.malformed_table and report.literal_markup);
    for ([_][]const u8{
        "* before |} after", "* |} suffix |}",
        "* before |}<!-- hidden |}", "* before |}<includeonly>hidden |}",
        "[[Target|label |}]]",
    }) |strict| try std.testing.expectError(error.UncompiledPresentation, compileAlloc(a, "entry", .language, "Norsk", "no", strict, null));
    // The ordinary physical-line tail has independent source authority;
    // nested action labels above and raw semantic spans below do not.
    const plain_tail = try compileAlloc(a, "entry", .language, "Norsk", "no", "before |}", null);
    const plain_reference = try compileAlloc(a, "entry", .language, "Norsk", "no", "before <nowiki>|}</nowiki>", null);
    try std.testing.expectEqualSlices(u8, plain_reference, plain_tail);
    const plain_stored = try codec.decodeAlloc(a, plain_tail, "entry", .language, .{ .code = "no", .heading = "Norsk" });
    var plain_visible: std.ArrayList(u8) = .empty;
    for (plain_stored.entry.sections) |section| for (section.blocks) |block| {
        try std.testing.expect(block.table == null);
        for (block.spans) |span| {
            try std.testing.expect(span.kind == .text and span.target.len == 0);
            try plain_visible.appendSlice(a, span.text);
        }
    };
    try std.testing.expectEqualStrings("before |}", plain_visible.items);
    try std.testing.expectEqual(@as(usize, 0), plain_stored.entry.references.len);
    try std.testing.expectEqual(@as(usize, 0), plain_stored.entry.media.len);
    try std.testing.expectEqualSlices(u8, plain_tail, try codec.encodeAlloc(a, plain_stored));
    const raw = [_]compiler.Span{.{ .text = "|}" }};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &raw, null));
    // Entity and protected authorship keep their existing literal contracts;
    // their span segmentation need not match each other.
    for ([_][]const u8{ "* [[Target]]<nowiki>|}</nowiki>", "* [[Target]]&#124;}" }) |literal| {
        const literal_bytes = try compileAlloc(a, "entry", .language, "Norsk", "no", literal, null);
        const literal_stored = try codec.decodeAlloc(a, literal_bytes, "entry", .language, .{ .code = "no", .heading = "Norsk" });
        var visible: std.ArrayList(u8) = .empty;
        var target = false;
        for (literal_stored.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            try visible.appendSlice(a, span.text);
            if (span.kind == .link and std.mem.eql(u8, span.target, "Target")) target = true;
        };
        try std.testing.expect(target and std.mem.endsWith(u8, visible.items, "|}"));
        try std.testing.expectEqualSlices(u8, literal_bytes, try codec.encodeAlloc(a, literal_stored));
    }
}


test "TE retained translation list tails preserve literal separators later headings actions and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Complete retained expanded TE page1862/rev851370 (ce48803c), not a
    // corrected template expansion. The inline separator and close stay text.
    const source = "==వ్యాకరణ విశేషాలు== \n;భాషాభాగం:\n\n;వ్యుత్పత్తి:\n\n;బహువచనం లేక ఏక వచనం:\n\n==అర్థ వివరణ==\n\n==పదాలు==\n;నానార్థాలు:\n\n;సంబంధిత పదాలు:\n\n;వ్యతిరేక పదాలు:\n\n==పద ప్రయోగాలు==\n\n==అనువాదాలు==\n{| border=\"0\" width=\"100%\" class=\"translations\"\n|-\n| bgcolor=\"#FFFFE0\" valign=\"top\" width=\"48%\" |\n*[[ఇంగ్లీషు]]:*[[ఫ్రెంచి]]:*[[చైనీస్]]:*[[సంస్కృతం]]:*[[హిందీ]]:*[[అస్సామీ]]:*[[పంజాబీ]]:| width=1% |\n|bgcolor=\"#FFFFE0\" valign=top width=48%|\n*[[తమిళం]]:*[[కన్నడం]]:*[[మలయాళం]]:*[[మరాఠీ]]:*[[గుజరాతీ]]:*[[ఒరియా]]:*[[బెంగాలి]]:|}\n\n==మూలాలు, వనరులు==\n*[[wikipedia:india|india]]\n*[[w:తెవీకీ|తెవీకీ]]\n\n==బయటి లింకులు==\n*\n\n:__NOTOC__\n\n[[వర్గం:తెలుగు పదాలు]]";
    var namespaces = try NamespaceRegistry.init(a,
        "# wikidict-namespace-registry-v1\n# wiki\ttewiktionary\n# dump-date\t20261001\n# content-language\tte\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tTemplate\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tవర్గం\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    var report: Fallbacks = .{};
    const bytes = try compileReportedWithLinkTrailAlloc(a, "బంకముచ్చు", .language, "తెలుగు", "te", source, null, .{}, &namespaces, &report);
    const stored = try codec.decodeAlloc(a, bytes, "బంకముచ్చు", .language, .{ .code = "te", .heading = "తెలుగు" });
    try std.testing.expectEqualSlices(u8, bytes, try codec.encodeAlloc(a, stored));
    const Witness = struct {
        visible: std.ArrayList(u8) = .empty,
        targets: std.StringHashMap(void),
        headings: std.StringHashMap(void),
        tables: usize = 0,
        rows: usize = 0,
        cells: usize = 0,
        terms: usize = 0,
        lists: usize = 0,
        painted_cells: usize = 0,
        fn visit(self: *@This(), alloc: A, comptime T: type, value: T) anyerror!void {
            if (T == types.Span) {
                try self.visible.appendSlice(alloc, value.text);
                if (value.kind == .link) try self.targets.put(value.target, {});
                return;
            }
            if (T == types.Section) try self.headings.put(value.title, {});
            if (T == types.Block) {
                if (value.kind == .term) self.terms += 1;
                if (value.kind == .list_item) self.lists += 1;
                if (value.kind == .heading) {
                    var label: std.ArrayList(u8) = .empty;
                    for (value.spans) |span| try label.appendSlice(alloc, span.text);
                    try self.headings.put(try label.toOwnedSlice(alloc), {});
                }
            }
            if (T == types.Table) {
                self.tables += 1;
                self.rows += value.rows.len;
                for (value.rows) |row| self.cells += row.cells.len;
            }
            if (T == types.Cell) {
                if (value.background) |paint| if (std.mem.eql(u8, paint, "#ffffe0")) { self.painted_cells += 1; };
                if (value.blocks) |blocks| return self.visit(alloc, @TypeOf(blocks), blocks);
                if (value.nested_table) |table| return self.visit(alloc, @TypeOf(table), table);
                return self.visit(alloc, @TypeOf(value.spans), value.spans);
            }
            switch (@typeInfo(T)) {
                .@"struct" => |info| inline for (info.field_names) |name| try self.visit(alloc, @TypeOf(@field(value, name)), @field(value, name)),
                .pointer => |info| {
                    if (info.size != .slice) @compileError("Unsupported TE witness pointer");
                    if (info.child != u8) for (value) |child| try self.visit(alloc, info.child, child);
                },
                .optional => |info| if (value) |child| { try self.visit(alloc, info.child, child); },
                .array => |info| for (value) |child| try self.visit(alloc, info.child, child),
                .@"enum", .int, .bool => {},
                else => @compileError("Unhandled TE witness type: " ++ @typeName(T)),
            }
        }
    };
    var witness: Witness = .{ .targets = std.StringHashMap(void).init(a), .headings = std.StringHashMap(void).init(a) };
    try witness.visit(a, @TypeOf(stored.entry), stored.entry);
    try std.testing.expect(witness.tables == 1 and witness.rows == 1 and witness.cells == 2 and witness.painted_cells == 2);
    // Six semicolon terms and the authored bullet bodies remain typed content;
    // this page has no # definition source and does not invent lexical senses.
    try std.testing.expect(witness.terms >= 6 and witness.lists >= 4);
    for ([_][]const u8{ "ఇంగ్లీషు", "ఫ్రెంచి", "చైనీస్", "సంస్కృతం", "హిందీ", "అస్సామీ", "పంజాబీ", "తమిళం", "కన్నడం", "మలయాళం", "మరాఠీ", "గుజరాతీ", "ఒరియా", "బెంగాలి", "wikipedia:india", "w:తెవీకీ" }) |target|
        try std.testing.expect(witness.targets.contains(target));
    for ([_][]const u8{ "వ్యాకరణ విశేషాలు", "అర్థ వివరణ", "పదాలు", "పద ప్రయోగాలు", "అనువాదాలు", "మూలాలు, వనరులు", "బయటి లింకులు" }) |heading|
        try std.testing.expect(witness.headings.contains(heading));
    try std.testing.expect(std.mem.indexOf(u8, witness.visible.items, "| width=1% |") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, witness.visible.items, "|}"));
    try std.testing.expect(std.mem.indexOf(u8, witness.visible.items, "__NOTOC__") == null);
    try std.testing.expect(report.malformed_table);
    try std.testing.expectError(error.UncompiledPresentation, compiler.requireCompiledText("|}"));
}


test "OR exact jghana kupa body preserves malformed bibliography as literal through codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Captured ns0 p3082/r156367, raw and expanded both288B/d44c9de7.
    const source = "ସର୍ବନାମ,[[ବିଶେଷ୍ୟ]]\n" ++
        "*ସୁନ୍ଦରୀ ସ୍ତ୍ରୀମାନଙ୍କର କଟିଦେଶର ପଛ ପାଖରେ ଥିବା ଭଉଁରୀଦ୍ଵୟ<ref_ଅଜନ୍ତା ଓଡ଼ିଆ ଅଭିଧାନ ପୃଷ୍ଟା ୫୫୩=\"\"/>";
    const bibliography = "<ref_ଅଜନ୍ତା ଓଡ଼ିଆ ଅଭିଧାନ ପୃଷ୍ଟା ୫୫୩=\"\"/>";
    try std.testing.expectEqual(@as(usize, 288), source.len);
    var report: Fallbacks = .{};
    const bytes = try compileReportedAlloc(a, "ଜଘନ କୂପ", .language, "Unclassified", "", source, null, &report);
    const decoded = try codec.decodeAlloc(a, bytes, "ଜଘନ କୂପ", .language, .{ .code = "", .heading = "Unclassified" });
    try std.testing.expectEqualSlices(u8, bytes, try codec.encodeAlloc(a, decoded));
    var visible: std.ArrayList(u8) = .empty;
    var links: usize = 0;
    var bullets: usize = 0;
    for (decoded.entry.sections) |section| for (section.blocks) |block| {
        if (block.kind == .list_item) bullets += 1;
        for (block.spans) |span| {
            try visible.appendSlice(a, span.text);
            if (span.kind == .link) {
                try std.testing.expectEqualStrings("ବିଶେଷ୍ୟ", span.target);
                try std.testing.expectEqualStrings("ବିଶେଷ୍ୟ", span.text);
                links += 1;
            }
        }
    };
    try std.testing.expectEqual(@as(usize, 1), links);
    try std.testing.expectEqual(@as(usize, 1), bullets);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, visible.items, bibliography));
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "ସର୍ବନାମ,ବିଶେଷ୍ୟ") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "ସୁନ୍ଦରୀ ସ୍ତ୍ରୀମାନଙ୍କର କଟିଦେଶର ପଛ ପାଖରେ ଥିବା ଭଉଁରୀଦ୍ଵୟ") != null);
    try std.testing.expectEqual(@as(usize, 0), decoded.entry.references.len);
    try std.testing.expectEqualStrings("", decoded.entry.language_code);
    try std.testing.expect(report.literal_markup);
    try std.testing.expect(!report.unclosed_formatting);
}

test "underscore literal source proof cannot authorize parsed residual markup or alter valid refs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const leaked = [_]compiler.Span{.{ .text = "<ref_custom note=\"text\"/>" }};
    const split = [_]compiler.Span{ .{ .text = "<ref_" }, .{ .text = "custom/>" } };
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &leaked, null));
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &split, null));
    try std.testing.expectError(error.UncompiledPresentation, requireCompiledText("<ref_custom/>"));
    try std.testing.expectError(error.UncompiledPresentation, compileAlloc(a, "entry", .language, "English", "en", "<script>word</script>", null));
    try expectUnknownAtomicSourceLiteral(a, "<ref_custom>word", "&lt;ref_custom&gt;word", "<ref_custom>word");
    var report: Fallbacks = .{};
    const bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", "word<ref name=n>[[Target]]</ref><references/>", null, &report);
    const decoded = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqual(@as(usize, 1), decoded.entry.references.len);
    try std.testing.expect(!report.literal_markup);
    var link = false;
    for (decoded.entry.references[0].spans) |span| if (span.kind == .link and std.mem.eql(u8, span.target, "Target")) { link = true; };
    try std.testing.expect(link);
}


test "retained kuzhheoliou quote before protocol preserves literal wrapper and bare action" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "\n'''kuzhheolioù''' \n# furm lies kuzh-heol.\n#* ''Warlene, d’ar c’houlz bloaz-mañ, hevelep '''kuzh-heolioù''' Ne zegasent ket soñj din-me a vrezelioù. [''https://web.archive.org/web/20220102191405/http://www.daskor.bzh/auguste-bocher-hirvoudou-wreg-yaouank?language=fr ]\n\n==== <span title=\"Sterioù heñvel ouzh re « kuzhheolioù »\">Gerioù heñvelster</span> ====\n*[[kuzhioù-heol]]";
    try std.testing.expectEqual(@as(usize, 392), source.len);
    var report: Fallbacks = .{};
    const bytes = try compileReportedAlloc(a, "kuzhheolioù", .language, "Unclassified", "", source, null, &report);
    const decoded = try codec.decodeAlloc(a, bytes, "kuzhheolioù", .language, .{ .code = "", .heading = "Unclassified" });
    try std.testing.expectEqualSlices(u8, bytes, try codec.encodeAlloc(a, decoded));
    const target = "https://web.archive.org/web/20220102191405/http://www.daskor.bzh/auguste-bocher-hirvoudou-wreg-yaouank?language=fr";
    var visible: std.ArrayList(u8) = .empty;
    var urls: usize = 0;
    var synonym = false;
    var bold_word = false;
    for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        try visible.appendSlice(a, span.text);
        if (span.kind == .external_link) {
            try std.testing.expectEqualStrings(target, span.target);
            try std.testing.expectEqualStrings(target, span.text);
            try std.testing.expect(!span.italic);
            urls += 1;
        }
        if (span.kind == .link and std.mem.eql(u8, span.target, "kuzhioù-heol")) synonym = true;
        if (span.bold and std.mem.eql(u8, span.text, "kuzh-heolioù")) bold_word = true;
    };
    try std.testing.expectEqual(@as(usize, 1), urls);
    try std.testing.expect(synonym and bold_word and report.literal_markup);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "furm lies kuzh-heol.") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "a vrezelioù. [https://web.archive.org/") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "language=fr ]") != null);
    try std.testing.expectError(error.UncompiledPresentation, requireCompiledText("[https://example.test unfinished"));
}


test "apostrophe angle quotation keeps captured style links and block path through codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Exact local quote stream from complete laezh-glas expanded line13.
    const before = "==English==\n# [[Definition|definition]]\n#* ''Re [[Treger|Dreger]] a zo mat o blaz,''";
    const after = "Blaz [[krampouezh|krampouez]] fritet ha '''laez glas''' ;''<br>''Me re [[Gwened|Wened]] ha re [[Kemper|Gemper]],''\n";
    var report: Fallbacks = .{};
    const bytes = try compileReportedAlloc(a, "quote-token", .language, "English", "en", before ++ "<br''>" ++ after, null, &report);
    const expected = try compileAlloc(a, "quote-token", .language, "English", "en", before ++ "&lt;br''&gt;" ++ after, null);
    try std.testing.expectEqualSlices(u8, expected, bytes);
    const stored = try codec.decodeAlloc(a, bytes, "quote-token", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualSlices(u8, bytes, try codec.encodeAlloc(a, stored));
    var quotations: usize = 0;
    var definitions: usize = 0;
    var targets: std.StringHashMap(void) = .init(a);
    var bold_italic = false;
    for (stored.entry.sections) |section| for (section.blocks) |block| {
        if (block.kind == .definition) definitions += 1;
        if (block.kind == .quotation) {
            quotations += 1;
            try std.testing.expectEqualStrings("#*", block.list_path);
            var visible: std.ArrayList(u8) = .empty;
            for (block.spans) |span| {
                try visible.appendSlice(a, span.text);
                if (span.kind == .link) try targets.put(span.target, {});
                if (std.mem.eql(u8, span.text, "laez glas") and span.bold and span.italic) bold_italic = true;
            }
            try std.testing.expect(std.mem.indexOf(u8, visible.items, "Re Dreger a zo mat o blaz,<br>Blaz krampouez fritet ha laez glas ;") != null);
            try std.testing.expect(std.mem.indexOf(u8, visible.items, "Me re Wened ha re Gemper,") != null);
        }
    };
    try std.testing.expectEqual(@as(usize, 1), quotations);
    try std.testing.expectEqual(@as(usize, 1), definitions);
    try std.testing.expect(bold_italic and report.literal_markup);
    for ([_][]const u8{ "Treger", "krampouezh", "Gwened", "Kemper" }) |target| try std.testing.expect(targets.contains(target));
}

test "quote leading angle examples preserve literal brackets without relaxing residual validators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Both authored example forms from complete reoliek expanded lines30/32.
    const source = "==English==\n# [[First]]\n#* <skouer>\n# [[Second]]\n#* <''skouer''>\n";
    const reference = "==English==\n# [[First]]\n#* &lt;skouer&gt;\n# [[Second]]\n#* &lt;''skouer''&gt;\n";
    var report: Fallbacks = .{};
    const bytes = try compileReportedAlloc(a, "examples", .language, "English", "en", source, null, &report);
    const expected = try compileAlloc(a, "examples", .language, "English", "en", reference, null);
    try std.testing.expectEqualSlices(u8, expected, bytes);
    const stored = try codec.decodeAlloc(a, bytes, "examples", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualSlices(u8, bytes, try codec.encodeAlloc(a, stored));
    var quotations: usize = 0;
    for (stored.entry.sections) |section| for (section.blocks) |block| if (block.kind == .quotation) {
        try std.testing.expectEqualStrings("#*", block.list_path);
        var visible: std.ArrayList(u8) = .empty;
        var italic: std.ArrayList(u8) = .empty;
        for (block.spans) |span| {
            try visible.appendSlice(a, span.text);
            if (span.italic) try italic.appendSlice(a, span.text);
            try std.testing.expect(span.kind == .text and span.target.len == 0);
        }
        try std.testing.expectEqualStrings("<skouer>", visible.items);
        try std.testing.expectEqualStrings(if (quotations == 0) "" else "skouer", italic.items);
        quotations += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), quotations);
    try std.testing.expect(report.literal_markup);
    const raw = [_]compiler.Span{.{ .text = "<br''>" }};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &raw, null));
    const target = [_]compiler.Span{.{ .text = "<", .kind = .link, .target = "{{unexpanded}}", .provenance = .entity_literal }};
    try std.testing.expectError(error.UncompiledTemplate, validateSpans(a, &target, null));
    try std.testing.expectError(error.UncompiledPresentation, requireCompiledText("<skouer>"));
    try std.testing.expectError(error.UncompiledPresentation, requireCompiledText("<br''>"));
}

test "complete unknown atomic names retain lexical body and strict target guards through codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "==English==\n===Noun===\n* Myan-အ(part)+ထမ်း(v)+<Mon-သမာ>သမား(part)\n* Chin<youzhagui(n)>အီကြာကွေး(n)\n# ''definition'' [[Target|child]]\n#: exact example\n";
    const reference = "==English==\n===Noun===\n* Myan-အ(part)+ထမ်း(v)+&lt;Mon-သမာ&gt;သမား(part)\n* Chin&lt;youzhagui(n)&gt;အီကြာကွေး(n)\n# ''definition'' [[Target|child]]\n#: exact example\n";
    var report: Fallbacks = .{};
    const payload = try compileReportedAlloc(a, "atomic-names", .language, "English", "en", source, null, &report);
    const expected = try compileAlloc(a, "atomic-names", .language, "English", "en", reference, null);
    try std.testing.expectEqualSlices(u8, expected, payload);
    const stored = try codec.decodeAlloc(a, payload, "atomic-names", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualSlices(u8, payload, try codec.encodeAlloc(a, stored));
    var visible: std.ArrayList(u8) = .empty;
    var definitions: usize = 0;
    var examples: usize = 0;
    var lists: usize = 0;
    var child = false;
    var italic = false;
    var noun = false;
    for (stored.entry.sections) |section| {
        if (section.level == 3 and std.mem.eql(u8, section.title, "Noun")) noun = true;
        for (section.blocks) |block| {
            if (block.kind == .definition) definitions += 1;
            if (block.kind == .example) {
                examples += 1;
                try std.testing.expectEqualStrings("#:", block.list_path);
            }
            if (block.kind == .list_item) lists += 1;
            for (block.spans) |span| {
                try visible.appendSlice(a, span.text);
                if (span.kind == .link and std.mem.eql(u8, span.target, "Target") and std.mem.eql(u8, span.text, "child")) child = true;
                if (span.italic and std.mem.eql(u8, span.text, "definition")) italic = true;
            }
        }
    }
    try std.testing.expect(noun and child and italic and report.literal_markup);
    try std.testing.expectEqual(@as(usize, 2), lists);
    try std.testing.expectEqual(@as(usize, 1), definitions);
    try std.testing.expectEqual(@as(usize, 1), examples);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "Myan-အ(part)+ထမ်း(v)+<Mon-သမာ>သမား(part)") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "Chin<youzhagui(n)>အီကြာကွေး(n)") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "exact example") != null);
    const raw = [_]compiler.Span{.{ .text = "<Mon-သမာ>" }};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &raw, null));
    const target = [_]compiler.Span{.{ .text = "<", .kind = .link, .target = "{{unexpanded}}", .provenance = .entity_literal }};
    try std.testing.expectError(error.UncompiledTemplate, validateSpans(a, &target, null));
}

test "retained HE supplementary documentation excludes implementation and keeps complete visible body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "<includeonly>\n\n==={{{כותרת}}}[[תמונה:Vraagteken-2.svg|15px]]===\n{| class=\"toccolours\" border=\"1\" style=\"clear: both; float: left; margin-right: 0.5em; width:193px; font-size: 95%; border: gray solid 1px; border-collapse: collapse;\"\n!colspan=\"2\" | '''סימוכין'''\n|-\n|colspan=\"2\"|{{{סימוכין}}}\n|-\n!colspan=\"2\" | '''ראו גם'''\n|-\n| '''שיבושים דומים''' || {{{דומים}}}\n|-\n| '''עוד''' || {{{ראו גם}}}\n|}\n\n{{{פירוט}}}<br />\n[[תמונה:X mark.svg|15px|איקס]] - '''{{{שגוי}}}'''<br />\n[[קובץ:Yes check.svg|15px|וי]] - '''{{{נכון}}}'''<br />\n{{{הסבר}}}\n</includeonly><noinclude>\n\n==הוראות שימוש==\n\n===תחביר===\n<pre>\n{{/תבנית\n|כותרת=\n|סימוכין=\n|דומים=\n|ראו גם=\n|פירוט=\n|שגוי=\n|נכון=\n|הסבר=\n}}\n</pre>\n\n==דוגמה==\n\n===קוד===\n<pre>\n{{/תבנית\n|כותרת= איך הוגים 'נמלים' (רבים של [[נמל]])\n|סימוכין= * [http://www.safa-ivrit.org/pronounce/namel.php נמל (נמלים)]  באתר [[האקדמיה ללשון העברית]]\n|דומים= [[#באם|באם]]\n|ראו גם= [[משקל קְטָלָה]], [[נמל]], [[נמלה]]\n|פירוט= הנמל מקום מעגן לאניות או לסירות. הוא מנקד נָמֵל.\n|שגוי= נְמָלִים\n|נכון= נְמֵלִים\n|הסבר= נְמֵלִים (ר' של נְמָלָה) היא פרט ממשפחת חרקים המתשייכת לסדרת הדבוראים.\n}}\n</pre>\n===תוצאה===\n\n===איך הוגים 'נמלים' (רבים של [[נמל]])[[תמונה:Vraagteken-2.svg|15px]]===\n{| class=\"toccolours\" border=\"1\" style=\"clear: both; float: left; margin-right: 0.5em; width:193px; font-size: 95%; border: gray solid 1px; border-collapse: collapse;\"\n!colspan=\"2\" | '''סימוכין'''\n|-\n|colspan=\"2\"| * [http://www.safa-ivrit.org/pronounce/namel.php נמל (נמלים)]  באתר [[האקדמיה ללשון העברית]]\n|-\n!colspan=\"2\" | '''ראו גם'''\n|-\n| '''שיבושים דומים''' || [[#באם|באם]]\n|-\n| '''עוד''' || [[משקל קְטָלָה]], [[נמל]], [[נמלה]]\n|}\n\nהנמל מקום מעגן לאניות או לסירות. הוא מנקד נָמֵל.<br />\n[[תמונה:X mark.svg|15px|איקס]] - '''נְמָלִים'''<br />\n[[קובץ:Yes check.svg|15px|וי]] - '''נְמֵלִים'''<br />\nנְמֵלִים (ר' של נְמָלָה) פרט ממשפחת חרקים המתשייכת לסדרת הדבוראים.\n</noinclude>";
    try std.testing.expectEqual(@as(usize, 2495), source.len);
    const documentation_start = (std.mem.indexOf(u8, source, "<noinclude>") orelse return error.TestUnexpectedResult) + "<noinclude>".len;
    const documentation_end = std.mem.lastIndexOf(u8, source, "</noinclude>") orelse return error.TestUnexpectedResult;
    const reference = source[documentation_start..documentation_end];
    const title = "נספח:שיבושי הגייה/תבנית";
    var report: Fallbacks = .{};
    const bytes = try compileReportedAlloc(a, title, .supplemental, "", "", source, null, &report);
    const expected = try compileAlloc(a, title, .supplemental, "", "", reference, null);
    // Compare every semantic body/table/heading/style/action field, not a few
    // substrings. The independent reference is the authored visible docs only.
    try std.testing.expectEqualSlices(u8, expected, bytes);
    const stored = try codec.decodeAlloc(a, bytes, title, .supplemental, null);
    try std.testing.expectEqualSlices(u8, bytes, try codec.encodeAlloc(a, stored));
    var tables: usize = 0;
    var preformatted: usize = 0;
    for (stored.entry.sections) |section| for (section.blocks) |block| {
        if (block.table != null) tables += 1;
        if (block.kind == .preformatted) preformatted += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), tables);
    try std.testing.expectEqual(@as(usize, 2), preformatted);
    const raw = [_]compiler.Span{.{ .text = "{{{כותרת}}}" }};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &raw, null));
}

test "KBD retained conjugation tables keep all missing parameter diagnostics body and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const title = "спр-лъэмыӏ-щэнэуэн";
    const source = "==Глагол лъэмыӏэс \"[[щэнэуэн]]\"-ым и спряженэр==\n<br/>\n{| class=\"wikitable\"\n|-\n! Инфинитив (масдар) !!\n|-\n| щыӀэныгъэ: || {{{псалъэпкъ1}}}эн\n|-\n| щымыӀэныгъэ: || мы{{{псалъэпкъ1}}}эн\n|}\n\n{| class=\"wikitable\"\n|-\n! Инфинитив (масдар) щхьэкӀэ зэхъуэкӀа !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр\n|-\n| щыӀэныгъэ: || сы{{{псалъэпкъ1}}}эн || у{{{псалъэпкъ1}}}эн || {{{псалъэпкъ1}}}эн || ды{{{псалъэпкъ1}}}эн || фы{{{псалъэпкъ1}}}эн || {{{псалъэпкъ1}}}эн(хэ)\n|-\n| щымыӀэныгъэ: || сымы{{{псалъэпкъ1}}}эн || умы{{{псалъэпкъ1}}}эн || мы{{{псалъэпкъ1}}}эн || дымы{{{псалъэпкъ1}}}эн || фымы{{{псалъэпкъ1}}}эн || мы{{{псалъэпкъ1}}}эн(хэ)\n|}\n\n{| class=\"wikitable\"\n|-\n! унафэ наклоненэ !! уэ !! фэ \n|-\n| щыӀэныгъэ: || шэнауэ! || фышэнауэ!\n|-\n| щымыӀэныгъэ: || умышэнауэ! || фымышэнауэ!\n|}\n\n{| class=\"wikitable\"\n|-\n! Ре-кӀэ унафэ наклоненэ !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр\n|-\n| щыӀэныгъэ: || срешэнауэ || урешэнауэ || ирешэнауэ || дрешэнауэ || фрешэнауэ || ирешэнауэ\n|-\n| щымыӀэныгъэ: || сремышэнауэ || уремышэнауэ || иремышэнауэ || дремышэнауэ || фремышэнауэ || иремышэнауэ\n|}\n\n{| class=\"wikitable\"\n|-\n! ЗэраӀуатэ наклоненэ !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр\n|-\n| ит зэман – щыӀэныгъэ: || сошэнауэ(р) || уошэнауэ(р) || мэшэнауэ(р) || дошэнауэ(р) || фошэнауэ(р) || мэшэнауэ(хэ)(р)\n|-\n| ит зэман – щымыӀэныгъэ: || сышэнауэркъым || ушэнауэркъым || шэнауэркъым || дышэнауэркъым || фышэнауэркъым || шэнауэ(хэ)ркъым\n|-\n| блэкӀа зэфӀэмыкӀа зэман (имперфект) – щыӀэныгъэ: || сышэнауэ(р)т || ушэнауэ(р)т || шэнауэ(р)т || дышэнауэ(р)т || фышэнауэ(р)т || шэнауэ(хэ)(р)т\n|-\n| блэкӀа зэфӀэмыкӀа зэман (имперфект) – щымыӀэныгъэ: || сышэнауэ(р)тэкъым || ушэнауэ(р)тэкъым || шэнауэ(р)тэкъым || дышэнауэ(р)тэкъым || фышэнауэ(р)тэкъым || шэнауэ(хэ)(р)тэкъым\n|-\n| блэкӀа зэфӀэкӀа зэман (перфект) – щыӀэныгъэ: || сы{{{псалъэпкъ1}}}ащ || у{{{псалъэпкъ1}}}ащ || {{{псалъэпкъ1}}}ащ || ды{{{псалъэпкъ1}}}ащ || фы{{{псалъэпкъ1}}}ащ || {{{псалъэпкъ1}}}а(хэ)щ \n|-\n| блэкӀа зэфӀэкӀа зэман (перфект) – щымыӀэныгъэ: || сы{{{псалъэпкъ1}}}акъым || у{{{псалъэпкъ1}}}акъым || {{{псалъэпкъ1}}}акъым || ды{{{псалъэпкъ1}}}акъым || фы{{{псалъэпкъ1}}}акъым || {{{псалъэпкъ1}}}а(хэ)къым\n|-\n| блэкӀа зэфӀэкӀа и пэ ит зэман (плюс квамперфект) – щыӀэныгъэ: || сы{{{псалъэпкъ1}}}ат || у{{{псалъэпкъ1}}}ат || {{{псалъэпкъ1}}}ат || ды{{{псалъэпкъ1}}}ат || фы{{{псалъэпкъ1}}}ат || {{{псалъэпкъ1}}}а(хэ)т \n|-\n| блэкӀа зэфӀэкӀа и пэ ит зэман (плюс квамперфект) – щымыӀэныгъэ: || сы{{{псалъэпкъ1}}}атэкъым || у{{{псалъэпкъ1}}}атэкъым || {{{псалъэпкъ1}}}атэкъым || ды{{{псалъэпкъ1}}}атэкъым || фы{{{псалъэпкъ1}}}атэкъым || {{{псалъэпкъ1}}}а(хэ)тэкъым \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман – щыӀэныгъэ: || сы{{{псалъэпкъ1}}}эгъащ || у{{{псалъэпкъ1}}}эгъащ || {{{псалъэпкъ1}}}эгъащ || ды{{{псалъэпкъ1}}}эгъащ || фы{{{псалъэпкъ1}}}эгъащ || {{{псалъэпкъ1}}}эгъа(хэ)щ \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман – щымыӀэныгъэ: || сы{{{псалъэпкъ1}}}эгъакъым || у{{{псалъэпкъ1}}}эгъакъым || {{{псалъэпкъ1}}}эгъакъым || ды{{{псалъэпкъ1}}}эгъакъым || фы{{{псалъэпкъ1}}}эгъакъым || {{{псалъэпкъ1}}}эгъа(хэ)къым \n|-\n| блэкӀа жыжьэ зэфӀэкӀа и пэ ит зэман – щыӀэныгъэ: || сы{{{псалъэпкъ1}}}эгъат || у{{{псалъэпкъ1}}}эгъат || {{{псалъэпкъ1}}}эгъат || ды{{{псалъэпкъ1}}}эгъат || фы{{{псалъэпкъ1}}}эгъат || {{{псалъэпкъ1}}}эгъа(хэ)т \n|-\n| блэкӀа жыжьэ зэфӀэкӀа и пэ ит зэман – щымыӀэныгъэ: || сы{{{псалъэпкъ1}}}эгъатэкъым || у{{{псалъэпкъ1}}}эгъатэкъым || {{{псалъэпкъ1}}}эгъатэкъым || ды{{{псалъэпкъ1}}}эгъатэкъым || фы{{{псалъэпкъ1}}}эгъатэкъым || {{{псалъэпкъ1}}}эгъа(хэ)тэкъым \n|-\n| блэкӀа гъэкӀэщӀа зэман I – щыӀэныгъэ: || сышэнауэщ || ушэнауэщ || шэнауэщ || дышэнауэщ || фышэнауэщ || шэнауэ(хэ)щ \n|-\n| блэкӀа гъэкӀэщӀа зэман I – щымыӀэныгъэ: || сышэнауэкъым || ушэнауэкъым || шэнауэкъым || дышэнауэкъым || фышэнауэкъым || шэнауэ(хэ)къым \n|-\n| блэкӀа гъэкӀэщӀа зэман II – щыӀэныгъэ: || сышэнауэт || ушэнауэт || шэнауэт || дышэнауэт || фышэнауэт || шэнауэ(хэ)т \n|-\n| блэкӀа гъэкӀэщӀа зэман II – щымыӀэныгъэ: || сышэнауэтэкъым || ушэнауэтэкъым || шэнауэтэкъым || дышэнауэтэкъым || фышэнауэтэкъым || шэнауэ(хэ)тэкъым \n|-\n| къэкӀуэну мыгъэбелджыла зэман – щыӀэныгъэ: || сы{{{псалъэпкъ1}}}энщ || у{{{псалъэпкъ1}}}энщ || {{{псалъэпкъ1}}}энщ || ды{{{псалъэпкъ1}}}энщ || фы{{{псалъэпкъ1}}}энщ || {{{псалъэпкъ1}}}эн(хэ)щ \n|-\n| къэкӀуэну мыгъэбелджыла зэман – щымыӀэныгъэ: || сы{{{псалъэпкъ1}}}энкъым || у{{{псалъэпкъ1}}}энкъым || {{{псалъэпкъ1}}}энкъым || ды{{{псалъэпкъ1}}}энкъым || фы{{{псалъэпкъ1}}}энкъым || {{{псалъэпкъ1}}}эн(хэ)къым \n|-\n| къэкӀуэну гъэбелджыла зэман – щыӀэныгъэ: || сы{{{псалъэпкъ1}}}энущ || у{{{псалъэпкъ1}}}энущ || {{{псалъэпкъ1}}}энущ || ды{{{псалъэпкъ1}}}энущ || фы{{{псалъэпкъ1}}}энущ || {{{псалъэпкъ1}}}эну(хэ)щ \n|-\n| къэкӀуэну гъэбелджыла зэман – щымыӀэныгъэ: || сы{{{псалъэпкъ1}}}энукъым || у{{{псалъэпкъ1}}}энукъым || {{{псалъэпкъ1}}}энукъым || ды{{{псалъэпкъ1}}}энукъым || фы{{{псалъэпкъ1}}}энукъым || {{{псалъэпкъ1}}}эну(хэ)къым \n|}\n\n{| class=\"wikitable\"\n|-\n! ЗэрыупщӀэ наклоненэ !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр \n|-\n| ит зэман – щыӀэныгъэ: || сышэнауэрэ || ушэнауэрэ || шэнауэрэ || дышэнауэрэ || фышэнауэрэ || шэнауэ(хэ)рэ \n|-\n| ит зэман – щымыӀэныгъэ: || сышэнауэркъэ || ушэнауэркъэ || шэнауэркъэ || дышэнауэркъэ || фышэнауэркъэ || шэнауэ(хэ)ркъэ \n|-\n| блэкӀа зэфӀэмыкӀа зэман (имперфект) – щыӀэныгъэ: || сышэнауэ(р)т || ушэнауэ(р)т || шэнауэ(р)т || дышэнауэ(р)т || фышэнауэ(р)т || шэнауэ(хэ)(р)т\n|-\n| блэкӀа зэфӀэмыкӀа зэман (имперфект) – щымыӀэныгъэ: || сышэнауэ(р)тэкъэ || ушэнауэ(р)тэкъэ || шэнауэ(р)тэкъэ || дышэнауэ(р)тэкъэ || фышэнауэ(р)тэкъэ || шэнауэ(хэ)(р)тэкъэ\n|-\n| блэкӀа зэфӀэкӀа зэман (перфект) – щыӀэныгъэ: || сы{{{псалъэпкъ1}}}а || у{{{псалъэпкъ1}}}а || {{{псалъэпкъ1}}}а || ды{{{псалъэпкъ1}}}а || фы{{{псалъэпкъ1}}}а || {{{псалъэпкъ1}}}а(хэ) \n|-\n| блэкӀа зэфӀэкӀа зэман (перфект) – щымыӀэныгъэ: || сы{{{псалъэпкъ1}}}акъэ || у{{{псалъэпкъ1}}}акъэ || {{{псалъэпкъ1}}}акъэ || ды{{{псалъэпкъ1}}}акъэ || фы{{{псалъэпкъ1}}}акъэ || {{{псалъэпкъ1}}}а(хэ)къэ \n|-\n| блэкӀа зэфӀэкӀа и пэ ит зэман (плюс квамперфект) – щыӀэныгъэ: || сы{{{псалъэпкъ1}}}ат || у{{{псалъэпкъ1}}}ат || {{{псалъэпкъ1}}}ат || ды{{{псалъэпкъ1}}}ат || фы{{{псалъэпкъ1}}}ат || {{{псалъэпкъ1}}}а(хэ)т \n|-\n| блэкӀа зэфӀэкӀа и пэ ит зэман (плюс квамперфект) – щымыӀэныгъэ: || сы{{{псалъэпкъ1}}}атэкъэ || у{{{псалъэпкъ1}}}атэкъэ || {{{псалъэпкъ1}}}атэкъэ || ды{{{псалъэпкъ1}}}атэкъэ || фы{{{псалъэпкъ1}}}атэкъэ || {{{псалъэпкъ1}}}а(хэ)тэкъэ \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман – щыӀэныгъэ: || сы{{{псалъэпкъ1}}}эгъа || у{{{псалъэпкъ1}}}эгъа || {{{псалъэпкъ1}}}эгъа || ды{{{псалъэпкъ1}}}эгъа || фы{{{псалъэпкъ1}}}эгъа || {{{псалъэпкъ1}}}эгъа(хэ) \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман – щымыӀэныгъэ: || сы{{{псалъэпкъ1}}}эгъакъэ || у{{{псалъэпкъ1}}}эгъакъэ || {{{псалъэпкъ1}}}эгъакъэ || ды{{{псалъэпкъ1}}}эгъакъэ || фы{{{псалъэпкъ1}}}эгъакъэ || {{{псалъэпкъ1}}}эгъа(хэ)къэ \n|-\n| блэкӀа жыжьэ зэфӀэкӀа и пэ ит зэман – щыӀэныгъэ: || сы{{{псалъэпкъ1}}}эгъат || у{{{псалъэпкъ1}}}эгъат || {{{псалъэпкъ1}}}эгъат || ды{{{псалъэпкъ1}}}эгъат || фы{{{псалъэпкъ1}}}эгъат || {{{псалъэпкъ1}}}эгъа(хэ)т \n|-\n| блэкӀа жыжьэ зэфӀэкӀа и пэ ит зэман (плюс квамперфект) – щымыӀэныгъэ: || сы{{{псалъэпкъ1}}}эгъатэкъэ || у{{{псалъэпкъ1}}}эгъатэкъэ || {{{псалъэпкъ1}}}эгъатэкъэ || ды{{{псалъэпкъ1}}}эгъатэкъэ || фы{{{псалъэпкъ1}}}эгъатэкъэ || {{{псалъэпкъ1}}}эгъа(хэ)тэкъэ \n|-\n| блэкӀа гъэкӀэщӀа зэман I – щыӀэныгъэ: || сышэнауэ || ушэнауэ || шэнауэ || дышэнауэ || фышэнауэ || шэнауэ(хэ) \n|-\n| блэкӀа гъэкӀэщӀа зэман I – щымыӀэныгъэ: || сышэнауэкъэ || ушэнауэкъэ || шэнауэкъэ || дышэнауэкъэ || фышэнауэкъэ || шэнауэ(хэ)къэ \n|-\n| блэкӀа гъэкӀэщӀа зэман II – щыӀэныгъэ: || сышэнауэт || ушэнауэт || шэнауэт || дышэнауэт || фышэнауэт || шэнауэ(хэ)т \n|-\n| блэкӀа гъэкӀэщӀа зэман II – щымыӀэныгъэ: || сышэнауэтэкъэ || ушэнауэтэкъэ || шэнауэтэкъэ || дышэнауэтэкъэ || фышэнауэтэкъэ || шэнауэ(хэ)тэкъэ \n|-\n| къэкӀуэну  мыгъэбелджыла зэман – щыӀэныгъэ: || сы{{{псалъэпкъ1}}}эн || у{{{псалъэпкъ1}}}эн || {{{псалъэпкъ1}}}эн || ды{{{псалъэпкъ1}}}эн || фы{{{псалъэпкъ1}}}эн || {{{псалъэпкъ1}}}эн(хэ) \n|-\n| къэкӀуэну  мыгъэбелджыла зэман – щымыӀэныгъэ: || сы{{{псалъэпкъ1}}}энкъэ || у{{{псалъэпкъ1}}}энкъэ || {{{псалъэпкъ1}}}энкъэ || ды{{{псалъэпкъ1}}}энкъэ || фы{{{псалъэпкъ1}}}энкъэ || {{{псалъэпкъ1}}}эн(хэ)къэ \n|-\n| къэкӀуэну гъэбелджыла зэман – щыӀэныгъэ: || сы{{{псалъэпкъ1}}}эну || у{{{псалъэпкъ1}}}эну || {{{псалъэпкъ1}}}эну || ды{{{псалъэпкъ1}}}эну || фы{{{псалъэпкъ1}}}эну || {{{псалъэпкъ1}}}эну(хэ) \n|-\n| къэкӀуэну гъэбелджыла зэман – щымыӀэныгъэ: || сы{{{псалъэпкъ1}}}энукъэ || у{{{псалъэпкъ1}}}энукъэ || {{{псалъэпкъ1}}}энукъэ || ды{{{псалъэпкъ1}}}энукъэ || фы{{{псалъэпкъ1}}}энукъэ || {{{псалъэпкъ1}}}эну(хэ)къэ \n|}\n\n{| class=\"wikitable\"\n|-\n! условнэ ипэжыпӀэкӀэ щыӀэ наклоненэ !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр \n|-\n| ит зэман – щыӀэныгъэ: || сышэнауэмэ || ушэнауэмэ || шэнауэмэ || дышэнауэмэ || фышэнауэмэ || шэнауэ(хэ)мэ \n|-\n| ит зэман – щымыӀэныгъэ: || сымышэнауэмэ || умышэнауэмэ || мышэнауэмэ || дымышэнауэмэ || фымышэнауэмэ || мышэнауэ(хэ)мэ \n|-\n| блэкӀа зэфӀэкӀа зэман (перфект) – щыӀэныгъэ: || сы{{{псалъэпкъ1}}}амэ || у{{{псалъэпкъ1}}}амэ || {{{псалъэпкъ1}}}амэ || ды{{{псалъэпкъ1}}}амэ || фы{{{псалъэпкъ1}}}амэ || {{{псалъэпкъ1}}}а(хэ)мэ \n|-\n| блэкӀа зэфӀэкӀа зэман (перфект) – щымыӀэныгъэ: || сымы{{{псалъэпкъ1}}}амэ || умы{{{псалъэпкъ1}}}амэ || мы{{{псалъэпкъ1}}}амэ || дымы{{{псалъэпкъ1}}}амэ || фымы{{{псалъэпкъ1}}}амэ ||мы{{{псалъэпкъ1}}}а(хэ)мэ \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман (плюс квамперфект)– щыӀэныгъэ: || сы{{{псалъэпкъ1}}}эгъамэ || у{{{псалъэпкъ1}}}эгъамэ || {{{псалъэпкъ1}}}эгъамэ || ды{{{псалъэпкъ1}}}эгъамэ || фы{{{псалъэпкъ1}}}эгъамэ || {{{псалъэпкъ1}}}эгъа(хэ)мэ \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман (плюс квамперфект) – щымыӀэныгъэ: || сымы{{{псалъэпкъ1}}}эгъамэ || умы{{{псалъэпкъ1}}}эгъамэ || мы{{{псалъэпкъ1}}}эгъамэ || дымы{{{псалъэпкъ1}}}эгъамэ || фымы{{{псалъэпкъ1}}}эгъамэ || мы{{{псалъэпкъ1}}}эгъа(хэ)мэ \n|-\n| къэкӀуэну мыгъэбелджыла зэман – щыӀэныгъэ: || сы{{{псалъэпкъ1}}}энмэ || у{{{псалъэпкъ1}}}энмэ || {{{псалъэпкъ1}}}энмэ || ды{{{псалъэпкъ1}}}энмэ || фы{{{псалъэпкъ1}}}энмэ || {{{псалъэпкъ1}}}эн(хэ)мэ \n|-\n| къэкӀуэну мыгъэбелджыла зэман – щымыӀэныгъэ: || сымы{{{псалъэпкъ1}}}энмэ || умы{{{псалъэпкъ1}}}энмэ || мы{{{псалъэпкъ1}}}энмэ || дымы{{{псалъэпкъ1}}}энмэ || фымы{{{псалъэпкъ1}}}энмэ || мы{{{псалъэпкъ1}}}эн(хэ)мэ \n|-\n| къэкӀуэну гъэбелджыла зэман – щыӀэныгъэ: || сы{{{псалъэпкъ1}}}энумэ || у{{{псалъэпкъ1}}}энумэ || {{{псалъэпкъ1}}}энумэ || ды{{{псалъэпкъ1}}}энумэ || фы{{{псалъэпкъ1}}}энумэ || {{{псалъэпкъ1}}}эну(хэ)мэ \n|-\n| къэкӀуэну гъэбелджыла зэман – щымыӀэныгъэ: || сымы{{{псалъэпкъ1}}}энумэ || умы{{{псалъэпкъ1}}}энумэ || мы{{{псалъэпкъ1}}}энумэ || дымы{{{псалъэпкъ1}}}энумэ || фымы{{{псалъэпкъ1}}}энумэ || мы{{{псалъэпкъ1}}}эну(хэ)мэ \n|}\n\n{| class=\"wikitable\"\n|-\n! условнэ ипэжыпӀэкӀэ щымыӀэ наклоненэ !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр \n|-\n| ит зэман – щыӀэныгъэ: || сышэнауэтэмэ || ушэнауэтэмэ || шэнауэтэмэ || дышэнауэтэмэ || фышэнауэтэмэ || шэнауэ(хэ)тэмэ \n|-\n| ит зэман – щымыӀэныгъэ: || сымышэнауэтэмэ || умышэнауэтэмэ || мышэнауэтэмэ || дымышэнауэтэмэ || фымышэнауэтэмэ || мышэнауэ(хэ)тэмэ \n|-\n| блэкӀа зэфӀэкӀа зэман (перфект) – щыӀэныгъэ: || сы{{{псалъэпкъ1}}}атэмэ || у{{{псалъэпкъ1}}}атэмэ || {{{псалъэпкъ1}}}атэмэ || ды{{{псалъэпкъ1}}}атэмэ || фы{{{псалъэпкъ1}}}атэмэ || {{{псалъэпкъ1}}}а(хэ)тэмэ \n|-\n| блэкӀа зэфӀэкӀа зэман (перфект) – щымыӀэныгъэ: || сымы{{{псалъэпкъ1}}}атэмэ || умы{{{псалъэпкъ1}}}атэмэ || мы{{{псалъэпкъ1}}}атэмэ || дымы{{{псалъэпкъ1}}}атэмэ || фымы{{{псалъэпкъ1}}}атэмэ || мы{{{псалъэпкъ1}}}а(хэ)тэмэ \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман (плюс квамперфект)– щыӀэныгъэ: || сы{{{псалъэпкъ1}}}эгъатэмэ || у{{{псалъэпкъ1}}}эгъатэмэ || {{{псалъэпкъ1}}}эгъатэмэ || ды{{{псалъэпкъ1}}}эгъатэмэ || фы{{{псалъэпкъ1}}}эгъатэмэ || {{{псалъэпкъ1}}}эгъа(хэ)тэмэ \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман (плюс квамперфект) – щымыӀэныгъэ: || сымы{{{псалъэпкъ1}}}эгъатэмэ || умы{{{псалъэпкъ1}}}эгъатэмэ || мы{{{псалъэпкъ1}}}эгъатэмэ || дымы{{{псалъэпкъ1}}}эгъатэмэ || фымы{{{псалъэпкъ1}}}эгъатэмэ || мы{{{псалъэпкъ1}}}эгъа(хэ)тэмэ \n|-\n| къэкӀуэну мыгъэбелджыла зэман – щыӀэныгъэ: || сы{{{псалъэпкъ1}}}энтэмэ || у{{{псалъэпкъ1}}}энтэмэ || {{{псалъэпкъ1}}}энтэмэ || ды{{{псалъэпкъ1}}}энтэмэ || фы{{{псалъэпкъ1}}}энтэмэ || {{{псалъэпкъ1}}}эн(хэ)тэмэ \n|-\n| къэкӀуэну мыгъэбелджыла зэман – щымыӀэныгъэ: || сымы{{{псалъэпкъ1}}}энтэмэ || умы{{{псалъэпкъ1}}}энтэмэ || мы{{{псалъэпкъ1}}}энтэмэ || дымы{{{псалъэпкъ1}}}энтэмэ || фымы{{{псалъэпкъ1}}}энтэмэ || мы{{{псалъэпкъ1}}}эн(хэ)тэмэ \n|-\n| къэкӀуэну гъэбелджыла зэман – щыӀэныгъэ: || сы{{{псалъэпкъ1}}}энутэмэ || у{{{псалъэпкъ1}}}энутэмэ || {{{псалъэпкъ1}}}энутэмэ || ды{{{псалъэпкъ1}}}энутэмэ || фы{{{псалъэпкъ1}}}энутэмэ || {{{псалъэпкъ1}}}эну(хэ)тэмэ \n|-\n| къэкӀуэну гъэбелджыла зэман – щымыӀэныгъэ: || сымы{{{псалъэпкъ1}}}энутэмэ || умы{{{псалъэпкъ1}}}энутэмэ || мы{{{псалъэпкъ1}}}энутэмэ || дымы{{{псалъэпкъ1}}}энутэмэ || фымы{{{псалъэпкъ1}}}энутэмэ || мы{{{псалъэпкъ1}}}эну(хэ)тэмэ \n|}\n\n{| class=\"wikitable\"\n|-\n! сослагательнэ наклоненэ !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр \n|-\n| къэкӀуэну мыгъэбелджыла зэман – щыӀэныгъэ: || сы{{{псалъэпкъ1}}}энт || у{{{псалъэпкъ1}}}энт || {{{псалъэпкъ1}}}энт || ды{{{псалъэпкъ1}}}энт || фы{{{псалъэпкъ1}}}энт || {{{псалъэпкъ1}}}эн(хэ)т \n|-\n| къэкӀуэну мыгъэбелджыла зэман – щымыӀэныгъэ: || сы{{{псалъэпкъ1}}}энтэкъым || у{{{псалъэпкъ1}}}энтэкъым || {{{псалъэпкъ1}}}энтэкъым || ды{{{псалъэпкъ1}}}энтэкъым || фы{{{псалъэпкъ1}}}энтэкъым || {{{псалъэпкъ1}}}эн(хэ)тэкъым \n|-\n| къэкӀуэну гъэбелджыла зэман – щыӀэныгъэ: || сы{{{псалъэпкъ1}}}энут || у{{{псалъэпкъ1}}}энут || {{{псалъэпкъ1}}}энут || ды{{{псалъэпкъ1}}}энут || фы{{{псалъэпкъ1}}}энут || {{{псалъэпкъ1}}}эну(хэ)т \n|-\n| къэкӀуэну гъэбелджыла зэман – щымыӀэныгъэ: || сы{{{псалъэпкъ1}}}энутэкъым || у{{{псалъэпкъ1}}}энутэкъым || {{{псалъэпкъ1}}}энутэкъым || ды{{{псалъэпкъ1}}}энутэкъым || фы{{{псалъэпкъ1}}}энутэкъым || {{{псалъэпкъ1}}}эну(хэ)тэкъым \n|}\n\n{| class=\"wikitable\"\n|-\n! уступительнэ ипэжыпӀэкӀэ щыӀэ наклоненэ !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр \n|-\n| ит зэман – щыӀэныгъэ: || сышэнауэми || ушэнауэми || шэнауэми || дышэнауэми || фышэнауэми || шэнауэ(хэ)ми \n|-\n| ит зэман – щымыӀэныгъэ: || сымышэнауэми || умышэнауэми || мышэнауэми || дымышэнауэми || фымышэнауэми || мышэнауэ(хэ)ми \n|-\n| блэкӀа зэфӀэкӀа зэман (перфект) – щыӀэныгъэ: || сы{{{псалъэпкъ1}}}ами || у{{{псалъэпкъ1}}}ами || {{{псалъэпкъ1}}}ами || ды{{{псалъэпкъ1}}}ами || фы{{{псалъэпкъ1}}}ами || {{{псалъэпкъ1}}}а(хэ)ми \n|-\n| блэкӀа зэфӀэкӀа зэман (перфект) – щымыӀэныгъэ: || сымы{{{псалъэпкъ1}}}ами || умы{{{псалъэпкъ1}}}ами || мы{{{псалъэпкъ1}}}ами || дымы{{{псалъэпкъ1}}}ами || фымы{{{псалъэпкъ1}}}ами || мы{{{псалъэпкъ1}}}а(хэ)ми \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман (плюс квамперфект)– щыӀэныгъэ: || сы{{{псалъэпкъ1}}}эгъами || у{{{псалъэпкъ1}}}эгъами || {{{псалъэпкъ1}}}эгъами || ды{{{псалъэпкъ1}}}эгъами || фы{{{псалъэпкъ1}}}эгъами || {{{псалъэпкъ1}}}эгъа(хэ)ми \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман (плюс квамперфект) – щымыӀэныгъэ: || сымы{{{псалъэпкъ1}}}эгъами || умы{{{псалъэпкъ1}}}эгъами || мы{{{псалъэпкъ1}}}эгъами || дымы{{{псалъэпкъ1}}}эгъами || фымы{{{псалъэпкъ1}}}эгъами || мы{{{псалъэпкъ1}}}эгъа(хэ)ми \n|-\n| къэкӀуэну мыгъэбелджыла зэман – щыӀэныгъэ: || сы{{{псалъэпкъ1}}}энми || у{{{псалъэпкъ1}}}энми || {{{псалъэпкъ1}}}энми || ды{{{псалъэпкъ1}}}энми || фы{{{псалъэпкъ1}}}энми || {{{псалъэпкъ1}}}эн(хэ)ми \n|-\n| къэкӀуэну мыгъэбелджыла зэман – щымыӀэныгъэ: || сымы{{{псалъэпкъ1}}}энми || умы{{{псалъэпкъ1}}}энми || мы{{{псалъэпкъ1}}}энми || дымы{{{псалъэпкъ1}}}энми || фымы{{{псалъэпкъ1}}}энми || мы{{{псалъэпкъ1}}}эн(хэ)ми \n|-\n| къэкӀуэну гъэбелджыла зэман – щыӀэныгъэ: || сы{{{псалъэпкъ1}}}энуми || у{{{псалъэпкъ1}}}энуми || {{{псалъэпкъ1}}}энуми || ды{{{псалъэпкъ1}}}энуми || фы{{{псалъэпкъ1}}}энуми || {{{псалъэпкъ1}}}эну(хэ)ми \n|-\n| къэкӀуэну гъэбелджыла зэман – щымыӀэныгъэ: || сымы{{{псалъэпкъ1}}}энуми || умы{{{псалъэпкъ1}}}энуми || мы{{{псалъэпкъ1}}}энуми || дымы{{{псалъэпкъ1}}}энуми || фымы{{{псалъэпкъ1}}}энуми || мы{{{псалъэпкъ1}}}эну(хэ)ми \n|}\n\n{| class=\"wikitable\"\n|-\n! уступительнэ ипэжыпӀэкӀэ щымыӀэ наклоненэ !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр \n|-\n| ит зэман – щыӀэныгъэ: || сышэнауэтэми || ушэнауэтэми || шэнауэтэми || дышэнауэтэми || фышэнауэтэми || шэнауэ(хэ)тэми \n|-\n| ит зэман – щымыӀэныгъэ: || сымышэнауэтэми || умышэнауэтэми || мышэнауэтэми || дымышэнауэтэми || фымышэнауэтэми || мышэнауэ(хэ)тэми \n|-\n| блэкӀа зэфӀэкӀа зэман (перфект) – щыӀэныгъэ: || сы{{{псалъэпкъ1}}}атэми || у{{{псалъэпкъ1}}}атэми || {{{псалъэпкъ1}}}атэми || ды{{{псалъэпкъ1}}}атэми || фы{{{псалъэпкъ1}}}атэми || {{{псалъэпкъ1}}}а(хэ)тэми \n|-\n| блэкӀа зэфӀэкӀа зэман (перфект) – щымыӀэныгъэ: || сымы{{{псалъэпкъ1}}}атэми || умы{{{псалъэпкъ1}}}атэми || мы{{{псалъэпкъ1}}}атэми || дымы{{{псалъэпкъ1}}}атэми || фымы{{{псалъэпкъ1}}}атэми || мы{{{псалъэпкъ1}}}а(хэ)тэми \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман (плюс квамперфект)– щыӀэныгъэ: || сы{{{псалъэпкъ1}}}эгъатэми || у{{{псалъэпкъ1}}}эгъатэми || {{{псалъэпкъ1}}}эгъатэми || ды{{{псалъэпкъ1}}}эгъатэми || фы{{{псалъэпкъ1}}}эгъатэми || {{{псалъэпкъ1}}}эгъа(хэ)тэми \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман (плюс квамперфект) – щымыӀэныгъэ: || сымы{{{псалъэпкъ1}}}эгъатэми || умы{{{псалъэпкъ1}}}эгъатэми || мы{{{псалъэпкъ1}}}эгъатэми || дымы{{{псалъэпкъ1}}}эгъатэми || фымы{{{псалъэпкъ1}}}эгъатэми || мы{{{псалъэпкъ1}}}эгъа(хэ)тэми \n|-\n| къэкӀуэну мыгъэбелджыла зэман – щыӀэныгъэ: || сы{{{псалъэпкъ1}}}энтэми || у{{{псалъэпкъ1}}}энтэми || {{{псалъэпкъ1}}}энтэми || ды{{{псалъэпкъ1}}}энтэми || фы{{{псалъэпкъ1}}}энтэми || {{{псалъэпкъ1}}}эн(хэ)тэми \n|-\n| къэкӀуэну мыгъэбелджыла зэман – щымыӀэныгъэ: || сымы{{{псалъэпкъ1}}}энтэми || умы{{{псалъэпкъ1}}}энтэми || мы{{{псалъэпкъ1}}}энтэми || дымы{{{псалъэпкъ1}}}энтэми || фымы{{{псалъэпкъ1}}}энтэми || мы{{{псалъэпкъ1}}}эн(хэ)тэми \n|-\n| къэкӀуэну гъэбелджыла зэман – щыӀэныгъэ: || сы{{{псалъэпкъ1}}}энутэми || у{{{псалъэпкъ1}}}энутэми || {{{псалъэпкъ1}}}энутэми || ды{{{псалъэпкъ1}}}энутэми || фы{{{псалъэпкъ1}}}энутэми || {{{псалъэпкъ1}}}эну(хэ)тэми \n|-\n| къэкӀуэну гъэбелджыла зэман – щымыӀэныгъэ: || сымы{{{псалъэпкъ1}}}энутэми || умы{{{псалъэпкъ1}}}энутэми || мы{{{псалъэпкъ1}}}энутэми || дымы{{{псалъэпкъ1}}}энутэми || фымы{{{псалъэпкъ1}}}энутэми || мы{{{псалъэпкъ1}}}эну(хэ)тэми \n|}\n\n{| class=\"wikitable\"\n|-\n! гъэщӀэгъ{{{псалъэпкъ1}}}эныгъэ наклоненэ !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр \n|-\n|щыӀэныгъэ: || сы{{{псалъэпкъ1}}}аи || у{{{псалъэпкъ1}}}аи || {{{псалъэпкъ1}}}аи || ды{{{псалъэпкъ1}}}аи || фы{{{псалъэпкъ1}}}аи || {{{псалъэпкъ1}}}аи \n|-\n|щымыӀэныгъэ: || сы{{{псалъэпкъ1}}}акъыми || у{{{псалъэпкъ1}}}акъыми || {{{псалъэпкъ1}}}акъыми || ды{{{псалъэпкъ1}}}акъыми || фы{{{псалъэпкъ1}}}акъыми || {{{псалъэпкъ1}}}акъыми \n|}\n\n{| class=\"wikitable\"\n|-\n! фӀэфӀыныгъэ  наклоненэ !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр \n|-\n|щыӀэныгъэ: || сы{{{псалъэпкъ1}}}ащэрэт || у{{{псалъэпкъ1}}}ащэрэт || {{{псалъэпкъ1}}}ащэрэт || ды{{{псалъэпкъ1}}}ащэрэт || фы{{{псалъэпкъ1}}}ащэрэт || {{{псалъэпкъ1}}}ащэрэт \n|-\n|щымыӀэныгъэ: || сымы{{{псалъэпкъ1}}}ащэрэт || умы{{{псалъэпкъ1}}}ащэрэт || мы{{{псалъэпкъ1}}}ащэрэт || дымы{{{псалъэпкъ1}}}ащэрэт || фымы{{{псалъэпкъ1}}}ащэрэт || мы{{{псалъэпкъ1}}}ащэрэт \n|}\n\n{| class=\"wikitable\"\n|-\n! шэч къытехьэныгъэ наклоненэ !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр \n|-\n|гъэн-кӀэ мыгъэбелджыла - щыӀэныгъэ: || сы{{{псалъэпкъ1}}}агъэнщ || у{{{псалъэпкъ1}}}агъэнщ || {{{псалъэпкъ1}}}агъэнщ || ды{{{псалъэпкъ1}}}агъэнщ || фы{{{псалъэпкъ1}}}агъэнщ || {{{псалъэпкъ1}}}агъэнщ \n|-\n|гъэн-кӀэ мыгъэбелджыла - щымыӀэныгъэ: || сы{{{псалъэпкъ1}}}агъэнкъым || у{{{псалъэпкъ1}}}агъэнкъым || {{{псалъэпкъ1}}}агъэнкъым || ды{{{псалъэпкъ1}}}агъэнкъым || фы{{{псалъэпкъ1}}}агъэнкъым || {{{псалъэпкъ1}}}агъэнкъым \n|-\n|гъэнт-кӀэ мыгъэбелджыла - щыӀэныгъэ: || сы{{{псалъэпкъ1}}}агъэнт || у{{{псалъэпкъ1}}}агъэнт || {{{псалъэпкъ1}}}агъэнт || ды{{{псалъэпкъ1}}}агъэнт || фы{{{псалъэпкъ1}}}агъэнт || {{{псалъэпкъ1}}}агъэнт \n|-\n|гъэнт-кӀэ мыгъэбелджыла - щымыӀэныгъэ: || сы{{{псалъэпкъ1}}}агъэнтэкъым || у{{{псалъэпкъ1}}}агъэнтэкъым || {{{псалъэпкъ1}}}агъэнтэкъым || ды{{{псалъэпкъ1}}}агъэнтэкъым || фы{{{псалъэпкъ1}}}агъэнтэкъым || {{{псалъэпкъ1}}}агъэнтэкъым \n|-\n|гъэн-кӀэ мыгъэбелджыла зэрыупщӀэ - щыӀэныгъэ: || сы{{{псалъэпкъ1}}}агъэн || у{{{псалъэпкъ1}}}агъэн || {{{псалъэпкъ1}}}агъэн || ды{{{псалъэпкъ1}}}агъэн || фы{{{псалъэпкъ1}}}агъэн || {{{псалъэпкъ1}}}агъэн \n|-\n|гъэн-кӀэ мыгъэбелджыла зэрыупщӀэ - щымыӀэныгъэ: || сы{{{псалъэпкъ1}}}агъэнкъэ || у{{{псалъэпкъ1}}}агъэнкъэ || {{{псалъэпкъ1}}}агъэнкъэ || ды{{{псалъэпкъ1}}}агъэнкъэ || фы{{{псалъэпкъ1}}}агъэнкъэ || {{{псалъэпкъ1}}}агъэнкъэ \n|-\n|гъэнт-кӀэ мыгъэбелджыла зэрыупщӀэ - щыӀэныгъэ: || сы{{{псалъэпкъ1}}}агъэнт || у{{{псалъэпкъ1}}}агъэнт || {{{псалъэпкъ1}}}агъэнт || ды{{{псалъэпкъ1}}}агъэнт || фы{{{псалъэпкъ1}}}агъэнт || {{{псалъэпкъ1}}}агъэнт \n|-\n|гъэнт-кӀэ мыгъэбелджыла зэрыупщӀэ - щымыӀэныгъэ: || сы{{{псалъэпкъ1}}}агъэнтэкъэ || у{{{псалъэпкъ1}}}агъэнтэкъэ || {{{псалъэпкъ1}}}агъэнтэкъэ || ды{{{псалъэпкъ1}}}агъэнтэкъэ || фы{{{псалъэпкъ1}}}агъэнтэкъэ || {{{псалъэпкъ1}}}агъэнтэкъэ \n|-\n|гъэну-кӀэ гъэбелджыла - щыӀэныгъэ: || сы{{{псалъэпкъ1}}}агъэнущ || у{{{псалъэпкъ1}}}агъэнущ || {{{псалъэпкъ1}}}агъэнущ || ды{{{псалъэпкъ1}}}агъэнущ || фы{{{псалъэпкъ1}}}агъэнущ || {{{псалъэпкъ1}}}агъэнущ \n|-\n|гъэну-кӀэ гъэбелджыла - щымыӀэныгъэ: || сы{{{псалъэпкъ1}}}агъэнукъым || у{{{псалъэпкъ1}}}агъэнукъым || {{{псалъэпкъ1}}}агъэнукъым || ды{{{псалъэпкъ1}}}агъэнукъым || фы{{{псалъэпкъ1}}}агъэнукъым || {{{псалъэпкъ1}}}агъэнукъым \n|-\n|гъэнут-кӀэ гъэбелджыла - щыӀэныгъэ: || сы{{{псалъэпкъ1}}}агъэнут || у{{{псалъэпкъ1}}}агъэнут || {{{псалъэпкъ1}}}агъэнут || ды{{{псалъэпкъ1}}}агъэнут || фы{{{псалъэпкъ1}}}агъэнут || {{{псалъэпкъ1}}}агъэнут \n|-\n|гъэнут-кӀэ гъэбелджыла - щымыӀэныгъэ: || сы{{{псалъэпкъ1}}}агъэнутэкъым || у{{{псалъэпкъ1}}}агъэнутэкъым || {{{псалъэпкъ1}}}агъэнутэкъым || ды{{{псалъэпкъ1}}}агъэнутэкъым || фы{{{псалъэпкъ1}}}агъэнутэкъым || {{{псалъэпкъ1}}}агъэнутэкъым \n|-\n|гъэну-кӀэ гъэбелджыла зэрыупщӀэ - щыӀэныгъэ: || сы{{{псалъэпкъ1}}}агъэну || у{{{псалъэпкъ1}}}агъэну || {{{псалъэпкъ1}}}агъэну || ды{{{псалъэпкъ1}}}агъэну || фы{{{псалъэпкъ1}}}агъэну || {{{псалъэпкъ1}}}агъэну \n|-\n|гъэну-кӀэ гъэбелджыла зэрыупщӀэ - щымыӀэныгъэ: || сы{{{псалъэпкъ1}}}агъэнукъэ || у{{{псалъэпкъ1}}}агъэнукъэ || {{{псалъэпкъ1}}}агъэнукъэ || ды{{{псалъэпкъ1}}}агъэнукъэ || фы{{{псалъэпкъ1}}}агъэнукъэ || {{{псалъэпкъ1}}}агъэнукъэ \n|-\n|гъэнут-кӀэ гъэбелджыла зэрыупщӀэ - щыӀэныгъэ: || сы{{{псалъэпкъ1}}}агъэнут || у{{{псалъэпкъ1}}}агъэнут || {{{псалъэпкъ1}}}агъэнут || ды{{{псалъэпкъ1}}}агъэнут || фы{{{псалъэпкъ1}}}агъэнут || {{{псалъэпкъ1}}}агъэнут \n|-\n|гъэнут-кӀэ гъэбелджыла зэрыупщӀэ - щымыӀэныгъэ: || сы{{{псалъэпкъ1}}}агъэнутэкъэ || у{{{псалъэпкъ1}}}агъэнутэкъэ || {{{псалъэпкъ1}}}агъэнутэкъэ || ды{{{псалъэпкъ1}}}агъэнутэкъэ || фы{{{псалъэпкъ1}}}агъэнутэкъэ || {{{псалъэпкъ1}}}агъэнутэкъэ \n|}\n\n{| class=\"wikitable\"\n|-\n! Причастиехэр !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр\n|-\n! Зылэжь (субъектнэ) причастие !!  !!  !!  !!  !!  !! \n|-\n| ит зэман - щыӀэныгъэ ||  сышэнауэ || ушэнауэ || шэнауэ || дышэнауэ || фышэнауэ || шэнауэ(хэ) \n|-\n| ит зэман - щымыӀэныгъэ || сымышэнауэ || умышэнауэ || мышэнауэ || дымышэнауэ || фымышэнауэ ||  мышэнауэ(хэ)\n|-\n| блэкӀа зэфӀэкӀа зэман - щыӀэныгъэ ||  сы{{{псалъэпкъ1}}}а || у{{{псалъэпкъ1}}}а || {{{псалъэпкъ1}}}а || ды{{{псалъэпкъ1}}}а || фы{{{псалъэпкъ1}}}а || {{{псалъэпкъ1}}}а(хэ) \n|-\n| блэкӀа зэфӀэкӀа зэман - щымыӀэныгъэ ||  сымы{{{псалъэпкъ1}}}а || умы{{{псалъэпкъ1}}}а || мы{{{псалъэпкъ1}}}а || дымы{{{псалъэпкъ1}}}а || фымы{{{псалъэпкъ1}}}а || мы{{{псалъэпкъ1}}}а(хэ)  \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман - щыӀэныгъэ ||  сы{{{псалъэпкъ1}}}эгъа || у{{{псалъэпкъ1}}}эгъа || {{{псалъэпкъ1}}}эгъа || ды{{{псалъэпкъ1}}}эгъа || фы{{{псалъэпкъ1}}}эгъа || {{{псалъэпкъ1}}}эгъа(хэ) \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман - щымыӀэныгъэ ||  сымы{{{псалъэпкъ1}}}эгъа || умы{{{псалъэпкъ1}}}эгъа || мы{{{псалъэпкъ1}}}эгъа || дымы{{{псалъэпкъ1}}}эгъа || фымы{{{псалъэпкъ1}}}эгъа || мы{{{псалъэпкъ1}}}эгъа(хэ)  \n|-\n| къэкӀуэну мыгъэбелджыла зэман - щыӀэныгъэ ||  сы{{{псалъэпкъ1}}}эн || у{{{псалъэпкъ1}}}эн || {{{псалъэпкъ1}}}эн || ды{{{псалъэпкъ1}}}эн || фы{{{псалъэпкъ1}}}эн  || {{{псалъэпкъ1}}}эн(хэ) \n|-\n| къэкӀуэну мыгъэбелджыла зэман - щымыӀэныгъэ ||  сымы{{{псалъэпкъ1}}}эн || умы{{{псалъэпкъ1}}}эн || мы{{{псалъэпкъ1}}}эн || дымы{{{псалъэпкъ1}}}эн || фымы{{{псалъэпкъ1}}}эн  || мы{{{псалъэпкъ1}}}эн(хэ)\n|-\n| къэкӀуэну гъэбелджыла зэман - щыӀэныгъэ ||  сы{{{псалъэпкъ1}}}эну || у{{{псалъэпкъ1}}}эну || {{{псалъэпкъ1}}}эну || ды{{{псалъэпкъ1}}}эну || фы{{{псалъэпкъ1}}}эну  || {{{псалъэпкъ1}}}эну(хэ) \n|-\n| къэкӀуэну гъэбелджыла зэман - щымыӀэныгъэ ||  сымы{{{псалъэпкъ1}}}эну || умы{{{псалъэпкъ1}}}эну || мы{{{псалъэпкъ1}}}эну || дымы{{{псалъэпкъ1}}}эну || фымы{{{псалъэпкъ1}}}эну  || мы{{{псалъэпкъ1}}}эну(хэ)\n|-\n! Лэжьыгъэм и къэхъукӀэр зыгъэбелджылы причастие !!  !!  !!  !!  !!  !! \n|-\n| ит зэман - щыӀэныгъэ ||  сызэрышэнауэ || узэрышэнауэ || зэрышэнауэ || дызэрышэнауэ || фызэрышэнауэ  || зэрышэнауэ(хэ) \n|-\n| ит зэман - щымыӀэныгъэ || сызэрымышэнауэ || узэрымышэнауэ || зэрымышэнауэ || дызэрымышэнауэ || фызэрымышэнауэ ||  мызэрышэнауэ(хэ)\n|-\n| блэкӀа зэфӀэкӀа зэман - щыӀэныгъэ ||  сызэры{{{псалъэпкъ1}}}а || узэры{{{псалъэпкъ1}}}а || зэры{{{псалъэпкъ1}}}а || дызэры{{{псалъэпкъ1}}}а || фызэры{{{псалъэпкъ1}}}а || зэры{{{псалъэпкъ1}}}а(хэ) \n|-\n| блэкӀа зэфӀэкӀа зэман - щымыӀэныгъэ ||  сызэрымы{{{псалъэпкъ1}}}а || узэрымы{{{псалъэпкъ1}}}а || зэрымы{{{псалъэпкъ1}}}а || дызэрымы{{{псалъэпкъ1}}}а || фызэрымы{{{псалъэпкъ1}}}а || зэрымы{{{псалъэпкъ1}}}а(хэ)  \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман - щыӀэныгъэ ||  сызэры{{{псалъэпкъ1}}}эгъа || узэры{{{псалъэпкъ1}}}эгъа || зэры{{{псалъэпкъ1}}}эгъа || дызэры{{{псалъэпкъ1}}}эгъа || фызэры{{{псалъэпкъ1}}}эгъа || зэры{{{псалъэпкъ1}}}эгъа(хэ) \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман - щымыӀэныгъэ ||  сызэрымы{{{псалъэпкъ1}}}эгъа || узэрымы{{{псалъэпкъ1}}}эгъа || зэрымы{{{псалъэпкъ1}}}эгъа || дызэрымы{{{псалъэпкъ1}}}эгъа || фызэрымы{{{псалъэпкъ1}}}эгъа || зэрымы{{{псалъэпкъ1}}}эгъа(хэ)  \n|-\n| къэкӀуэну мыгъэбелджыла зэман - щыӀэныгъэ ||  сызэры{{{псалъэпкъ1}}}эн || узэры{{{псалъэпкъ1}}}эн || зэры{{{псалъэпкъ1}}}эн || дызэры{{{псалъэпкъ1}}}эн || фызэры{{{псалъэпкъ1}}}эн  || зэры{{{псалъэпкъ1}}}эн(хэ) \n|-\n| къэкӀуэну гъэбелджыла зэман - щымыӀэныгъэ ||  сызэрымы{{{псалъэпкъ1}}}эн || узэрымы{{{псалъэпкъ1}}}эн || зэрымы{{{псалъэпкъ1}}}эн || дызэрымы{{{псалъэпкъ1}}}эн || фызэрымы{{{псалъэпкъ1}}}эн  || зэрымы{{{псалъэпкъ1}}}эн(хэ)\n|-\n| къэкӀуэну гъэбелджыла зэман - щыӀэныгъэ ||  сызэры{{{псалъэпкъ1}}}эну || узэры{{{псалъэпкъ1}}}эну || зэры{{{псалъэпкъ1}}}эну || дызэры{{{псалъэпкъ1}}}эну || фызэры{{{псалъэпкъ1}}}эну  || зэры{{{псалъэпкъ1}}}эну(хэ) \n|-\n| къэкӀуэну гъэбелджыла зэман - щымыӀэныгъэ ||  сызэрымы{{{псалъэпкъ1}}}эну || узэрымы{{{псалъэпкъ1}}}эну || зэрымы{{{псалъэпкъ1}}}эну || дызэрымы{{{псалъэпкъ1}}}эну || фызэрымы{{{псалъэпкъ1}}}эну  || зэрымы{{{псалъэпкъ1}}}эну(хэ)\n|-\n! Зэман/щӀыпӀэ зыгъэбелджылы причастие !!  !!  !!  !!  !!  !! \n|-\n| ит зэман - щыӀэныгъэ ||  сыщышэнауэ || ущышэнауэ || щышэнауэ || дыщышэнауэ || фыщышэнауэ  || щышэнауэ(хэ) \n|-\n| ит зэман - щымыӀэныгъэ || сыщымышэнауэ || ущымышэнауэ || щымышэнауэ || дыщымышэнауэ || фыщымышэнауэ ||  щымышэнауэ(хэ)\n|-\n| блэкӀа зэфӀэкӀа зэман - щыӀэныгъэ ||  сыщы{{{псалъэпкъ1}}}а || ущы{{{псалъэпкъ1}}}а || щы{{{псалъэпкъ1}}}а || дыщы{{{псалъэпкъ1}}}а || фыщы{{{псалъэпкъ1}}}а || щы{{{псалъэпкъ1}}}а(хэ) \n|-\n| блэкӀа зэфӀэкӀа зэман - щымыӀэныгъэ ||  сыщымы{{{псалъэпкъ1}}}а || ущымы{{{псалъэпкъ1}}}а || щымы{{{псалъэпкъ1}}}а || дыщымы{{{псалъэпкъ1}}}а || фыщымы{{{псалъэпкъ1}}}а || щымы{{{псалъэпкъ1}}}а(хэ)  \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман - щыӀэныгъэ ||  сыщы{{{псалъэпкъ1}}}эгъа || ущы{{{псалъэпкъ1}}}эгъа || щы{{{псалъэпкъ1}}}эгъа || дыщы{{{псалъэпкъ1}}}эгъа || фыщы{{{псалъэпкъ1}}}эгъа || щы{{{псалъэпкъ1}}}эгъа(хэ) \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман - щымыӀэныгъэ ||  сыщымы{{{псалъэпкъ1}}}эгъа || ущымы{{{псалъэпкъ1}}}эгъа || щымы{{{псалъэпкъ1}}}эгъа || дыщымы{{{псалъэпкъ1}}}эгъа || фыщымы{{{псалъэпкъ1}}}эгъа || щымы{{{псалъэпкъ1}}}эгъа(хэ)  \n|-\n| къэкӀуэну мыгъэбелджылы зэман - щыӀэныгъэ ||  сыщы{{{псалъэпкъ1}}}эн || ущы{{{псалъэпкъ1}}}эн || щы{{{псалъэпкъ1}}}эн || дыщы{{{псалъэпкъ1}}}эн || фыщы{{{псалъэпкъ1}}}эн  || щы{{{псалъэпкъ1}}}эн(хэ) \n|-\n| къэкӀуэну мыгъэбелджылы зэман - щымыӀэныгъэ ||  сыщымы{{{псалъэпкъ1}}}эн || ущымы{{{псалъэпкъ1}}}эн || щымы{{{псалъэпкъ1}}}эн || дыщымы{{{псалъэпкъ1}}}эн || фыщымы{{{псалъэпкъ1}}}эн  || щымы{{{псалъэпкъ1}}}эн(хэ)\n|-\n| къэкӀуэну гъэбелджылы зэман - щыӀэныгъэ ||  сыщы{{{псалъэпкъ1}}}эну || ущы{{{псалъэпкъ1}}}эну || щы{{{псалъэпкъ1}}}эну || дыщы{{{псалъэпкъ1}}}эну || фыщы{{{псалъэпкъ1}}}эну  || щы{{{псалъэпкъ1}}}эну(хэ) \n|-\n| къэкӀуэну гъэбелджылы зэман - щымыӀэныгъэ ||  сыщымы{{{псалъэпкъ1}}}эну || ущымы{{{псалъэпкъ1}}}эну || щымы{{{псалъэпкъ1}}}эну || дыщымы{{{псалъэпкъ1}}}эну || фыщымы{{{псалъэпкъ1}}}эну  || щымы{{{псалъэпкъ1}}}эну(хэ)\n|-\n! ЩӀыпӀэ зыгъэбелджылы причастие !!  !!  !!  !!  !!  !! \n|-\n| ит зэман - щыӀэныгъэ ||  сыздэшэнауэ || уздэшэнауэ || здэшэнауэ || дыздэшэнауэ || фыздэшэнауэ  || здэшэнауэ(хэ) \n|-\n| ит зэман - щымыӀэныгъэ || сыздэмышэнауэ || уздэмышэнауэ || здэмышэнауэ || дыздэмышэнауэ || фыздэмышэнауэ ||  здэмышэнауэ(хэ)\n|-\n| блэкӀа зэфӀэкӀа зэман - щыӀэныгъэ ||  сыздэ{{{псалъэпкъ1}}}а || уздэ{{{псалъэпкъ1}}}а || здэ{{{псалъэпкъ1}}}а || дыздэ{{{псалъэпкъ1}}}а || фыздэ{{{псалъэпкъ1}}}а || здэ{{{псалъэпкъ1}}}а(хэ) \n|-\n| блэкӀа зэфӀэкӀа зэман - щымыӀэныгъэ ||  сыздэмы{{{псалъэпкъ1}}}а || уздэмы{{{псалъэпкъ1}}}а || здэмы{{{псалъэпкъ1}}}а || дыздэмы{{{псалъэпкъ1}}}а || фыздэмы{{{псалъэпкъ1}}}а || здэмы{{{псалъэпкъ1}}}а(хэ)  \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман - щыӀэныгъэ ||  сыздэ{{{псалъэпкъ1}}}эгъа || уздэ{{{псалъэпкъ1}}}эгъа || здэ{{{псалъэпкъ1}}}эгъа || дыздэ{{{псалъэпкъ1}}}эгъа || фыздэ{{{псалъэпкъ1}}}эгъа || здэ{{{псалъэпкъ1}}}эгъа(хэ) \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман - щымыӀэныгъэ ||  сыздэмы{{{псалъэпкъ1}}}эгъа || уздэмы{{{псалъэпкъ1}}}эгъа || здэмы{{{псалъэпкъ1}}}эгъа || дыздэмы{{{псалъэпкъ1}}}эгъа || фыздэмы{{{псалъэпкъ1}}}эгъа || здэмы{{{псалъэпкъ1}}}эгъа(хэ)  \n|-\n| къэкӀуэну мыгъэбелджылы зэман - щыӀэныгъэ ||  сыздэ{{{псалъэпкъ1}}}эн || уздэ{{{псалъэпкъ1}}}эн || здэ{{{псалъэпкъ1}}}эн || дыздэ{{{псалъэпкъ1}}}эн || фыздэ{{{псалъэпкъ1}}}эн  || здэ{{{псалъэпкъ1}}}эн(хэ) \n|-\n| къэкӀуэну мыгъэбелджылы зэман - щымыӀэныгъэ ||  сыздэмы{{{псалъэпкъ1}}}эн || уздэмы{{{псалъэпкъ1}}}эн || здэмы{{{псалъэпкъ1}}}эн || дыздэмы{{{псалъэпкъ1}}}эн || фыздэмы{{{псалъэпкъ1}}}эн  || здэмы{{{псалъэпкъ1}}}эн(хэ)\n|-\n| къэкӀуэну гъэбелджылы зэман - щыӀэныгъэ ||  сыздэ{{{псалъэпкъ1}}}эну || уздэ{{{псалъэпкъ1}}}эну || здэ{{{псалъэпкъ1}}}эну || дыздэ{{{псалъэпкъ1}}}эну || фыздэ{{{псалъэпкъ1}}}эну  || здэ{{{псалъэпкъ1}}}эну(хэ) \n|-\n| къэкӀуэну гъэбелджылы зэман - щымыӀэныгъэ ||  сыздэмы{{{псалъэпкъ1}}}эну || уздэмы{{{псалъэпкъ1}}}эну || здэмы{{{псалъэпкъ1}}}эну || дыздэмы{{{псалъэпкъ1}}}эну || фыздэмы{{{псалъэпкъ1}}}эну  || здэмы{{{псалъэпкъ1}}}эну(хэ)\n|-\n! Щхьэусыгъуэ, мурад зыгъэбелджылы причастие !!  !!  !!  !!  !!  !! \n|-\n| ит зэман - щыӀэныгъэ ||  сыщӀэшэнауэ || ущӀэшэнауэ || щӀэшэнауэ || дыщӀэшэнауэ || фыщӀэшэнауэ  || щӀэшэнауэ(хэ) \n|-\n| ит зэман - щымыӀэныгъэ || сыщӀэмышэнауэ || ущӀэмышэнауэ || щӀэмышэнауэ || дыщӀэмышэнауэ || фыщӀэмышэнауэ ||  щӀэмышэнауэ(хэ)\n|-\n| блэкӀа зэфӀэкӀа зэман - щыӀэныгъэ ||  сыщӀэ{{{псалъэпкъ1}}}а || ущӀэ{{{псалъэпкъ1}}}а || щӀэ{{{псалъэпкъ1}}}а || дыщӀэ{{{псалъэпкъ1}}}а || фыщӀэ{{{псалъэпкъ1}}}а || щӀэ{{{псалъэпкъ1}}}а(хэ) \n|-\n| блэкӀа зэфӀэкӀа зэман - щымыӀэныгъэ ||  сыщӀэмы{{{псалъэпкъ1}}}а || ущӀэмы{{{псалъэпкъ1}}}а || щӀэмы{{{псалъэпкъ1}}}а || дыщӀэмы{{{псалъэпкъ1}}}а || фыщӀэмы{{{псалъэпкъ1}}}а || щӀэмы{{{псалъэпкъ1}}}а(хэ)  \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман - щыӀэныгъэ ||  сыщӀэ{{{псалъэпкъ1}}}эгъа || ущӀэ{{{псалъэпкъ1}}}эгъа || щӀэ{{{псалъэпкъ1}}}эгъа || дыщӀэ{{{псалъэпкъ1}}}эгъа || фыщӀэ{{{псалъэпкъ1}}}эгъа || щӀэ{{{псалъэпкъ1}}}эгъа(хэ) \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман - щымыӀэныгъэ ||  сыщӀэмы{{{псалъэпкъ1}}}эгъа || ущӀэмы{{{псалъэпкъ1}}}эгъа || щӀэмы{{{псалъэпкъ1}}}эгъа || дыщӀэмы{{{псалъэпкъ1}}}эгъа || фыщӀэмы{{{псалъэпкъ1}}}эгъа || щӀэмы{{{псалъэпкъ1}}}эгъа(хэ)  \n|-\n| къэкӀуэну мыгъэбелджылы зэман - щыӀэныгъэ ||  сыщӀэ{{{псалъэпкъ1}}}эн || ущӀэ{{{псалъэпкъ1}}}эн || щӀэ{{{псалъэпкъ1}}}эн || дыщӀэ{{{псалъэпкъ1}}}эн || фыщӀэ{{{псалъэпкъ1}}}эн  || щӀэ{{{псалъэпкъ1}}}эн(хэ) \n|-\n| къэкӀуэну мыгъэбелджылы зэман - щымыӀэныгъэ ||  сыщӀэмы{{{псалъэпкъ1}}}эн || ущӀэмы{{{псалъэпкъ1}}}эн || щӀэмы{{{псалъэпкъ1}}}эн || дыщӀэмы{{{псалъэпкъ1}}}эн || фыщӀэмы{{{псалъэпкъ1}}}эн  || щӀэмы{{{псалъэпкъ1}}}эн(хэ)\n|-\n| къэкӀуэну гъэбелджылы зэман - щыӀэныгъэ ||  сыщӀэ{{{псалъэпкъ1}}}эну || ущӀэ{{{псалъэпкъ1}}}эну || щӀэ{{{псалъэпкъ1}}}эну || дыщӀэ{{{псалъэпкъ1}}}эну || фыщӀэ{{{псалъэпкъ1}}}эну  || щӀэ{{{псалъэпкъ1}}}эну(хэ) \n|-\n| къэкӀуэну гъэбелджылы зэман - щымыӀэныгъэ ||  сыщӀэмы{{{псалъэпкъ1}}}эну || ущӀэмы{{{псалъэпкъ1}}}эну || щӀэмы{{{псалъэпкъ1}}}эну || дыщӀэмы{{{псалъэпкъ1}}}эну || фыщӀэмы{{{псалъэпкъ1}}}эну  || щӀэмы{{{псалъэпкъ1}}}эну(хэ)\n|}\n\n{| class=\"wikitable\"\n|-\n! Деепричастиехэр !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр\n|-\n| ит зэман - щыӀэныгъэ ||  сышэнауэу || ушэнауэу || шэнауэу || дышэнауэу || фышэнауэу || шэнауэ(хэ)у\n|-\n| ит зэман - щымыӀэныгъэ ||  сымышэнауэу || умышэнауэу || мышэнауэу || дымышэнауэу || фымышэнауэу || мышэнауэ(хэ)у\n|-\n| блэкӀа зэман - щыӀэныгъэ ||  сы{{{псалъэпкъ1}}}ауэ || у{{{псалъэпкъ1}}}ауэ || {{{псалъэпкъ1}}}ауэ || ды{{{псалъэпкъ1}}}ауэ || фы{{{псалъэпкъ1}}}ауэ || {{{псалъэпкъ1}}}ауэ / {{{псалъэпкъ1}}}а(хэ)у\n|-\n| блэкӀа зэман - щымыӀэныгъэ ||  сымы{{{псалъэпкъ1}}}ауэ || умы{{{псалъэпкъ1}}}ауэ || мы{{{псалъэпкъ1}}}ауэ || дымы{{{псалъэпкъ1}}}ауэ || фымы{{{псалъэпкъ1}}}ауэ || мы{{{псалъэпкъ1}}}ауэ(хэ) / мы{{{псалъэпкъ1}}}а(хэ)у\n|-\n| -урэ-кӀэ деепричастие - щыӀэныгъэ ||  сышэнауэурэ || ушэнауэурэ || шэнауэурэ || дышэнауэурэ || фышэнауэурэ || шэнауэ(хэ)урэ \n|-\n| -урэ-кӀэ деепричастие - щымыӀэныгъэ ||  сымышэнауэурэ || умышэнауэурэ || мышэнауэурэ || дымышэнауэурэ || фымышэнауэурэ || мышэнауэ(хэ)урэ\n|}\n\n{| class=\"wikitable\"\n|-\n! !!  !! -э-кӀэ цӀэ склоненэм и фащэхэр !!  !! \n|-\n! !! Закъуэ бжьыгъэ  !! !! Куэд бжьыгъэ  !! \n|-\n| || '''Мыбелджылы''' || '''Белджылы''' || '''Мыбелджылы''' || '''Белджылы'''\n|-\n| '''Именительнэ:''' || [шэнау]э || [шэнау]эр || -- || [шэнау]эхэр\n|-\n| '''Эргативнэ:''' || [шэнау]э || [шэнау]эм || --  || [шэнау]эхэм\n|-\n| '''Послеложнэ:''' || [шэнау]экӀэ || [шэнау]эмкӀэ || [шэнау]эхэкӀэ || [шэнау]эхэмкӀэ\n|-\n| '''Обстоятельственнэ:''' || [шэнау]эуэ || [шэнау]эрауэ || [шэнау]эхэу || [шэнау]эхэрауэ\n|}\n\n{| class=\"wikitable\"\n|-\n! !!  !! -а-кӀэ цӀэ склоненэм и фащэхэр !!  !! \n|-\n! !! Закъуэ бжьыгъэ  !! !! Куэд бжьыгъэ  !! \n|-\n| || '''Мыбелджылы''' || '''Белджылы''' || '''Мыбелджылы''' || '''Белджылы'''\n|-\n| '''Именительнэ:''' || [{{{псалъэпкъ1}}}]а || [{{{псалъэпкъ1}}}]ар || -- || [{{{псалъэпкъ1}}}]ахэр\n|-\n| '''Эргативнэ:''' || [{{{псалъэпкъ1}}}]а || [{{{псалъэпкъ1}}}]ам || --  || [{{{псалъэпкъ1}}}]ахэм\n|-\n| '''Послеложнэ:''' || [{{{псалъэпкъ1}}}]акӀэ || [{{{псалъэпкъ1}}}]амкӀэ || [{{{псалъэпкъ1}}}]ахэкӀэ || [{{{псалъэпкъ1}}}]ахэмкӀэ\n|-\n| '''Обстоятельственнэ:''' || [{{{псалъэпкъ1}}}]ауэ || [{{{псалъэпкъ1}}}]арауэ || [{{{псалъэпкъ1}}}]ахэу || [{{{псалъэпкъ1}}}]ахэрауэ\n|}\n\n{| class=\"wikitable\"\n|-\n! !!  !! -эн-кӀэ цӀэ склоненэм и фащэхэр !!  !! \n|-\n! !! Закъуэ бжьыгъэ  !! !! Куэд бжьыгъэ  !! \n|-\n| || '''Мыбелджылы''' || '''Белджылы''' || '''Мыбелджылы''' || '''Белджылы'''\n|-\n| '''Именительнэ:''' || [{{{псалъэпкъ1}}}]эн || [{{{псалъэпкъ1}}}]эныр || -- || [{{{псалъэпкъ1}}}]энхэр\n|-\n| '''Эргативнэ:''' || [{{{псалъэпкъ1}}}]эн || [{{{псалъэпкъ1}}}]эным || --  || [{{{псалъэпкъ1}}}]энхэм\n|-\n| '''Послеложнэ:''' || [{{{псалъэпкъ1}}}]энкӀэ || [{{{псалъэпкъ1}}}]энымкӀэ || [{{{псалъэпкъ1}}}]энхэкӀэ || [{{{псалъэпкъ1}}}]энхэмкӀэ\n|-\n| '''Обстоятельственнэ:'' || [{{{псалъэпкъ1}}}]эну || [{{{псалъэпкъ1}}}]энырауэ || [{{{псалъэпкъ1}}}]энхэу || [{{{псалъэпкъ1}}}]энхэрауэ\n|}\n\n{| class=\"wikitable\"\n|-\n! !!  !!  -эну-кӀэ цӀэ склоненэм и фащэхэр !!  !! \n|-\n! !! Закъуэ бжьыгъэ  !! !! Куэд бжьыгъэ  !! \n|-\n| || '''Мыбелджылы''' || '''Белджылы''' || '''Мыбелджылы''' || '''Белджылы'''\n|-\n| '''Именительнэ:''' || [{{{псалъэпкъ1}}}]эну || [{{{псалъэпкъ1}}}]энур || -- || [{{{псалъэпкъ1}}}]энухэр\n|-\n| '''Эргативнэ:''' || [{{{псалъэпкъ1}}}]эну || [{{{псалъэпкъ1}}}]энум || --  || [{{{псалъэпкъ1}}}]энухэм\n|-\n| '''Послеложнэ:''' || [{{{псалъэпкъ1}}}]энукӀэ || [{{{псалъэпкъ1}}}]энумкӀэ || [{{{псалъэпкъ1}}}]энухэкӀэ || [{{{псалъэпкъ1}}}]энухэмкӀэ\n|-\n| '''Обстоятельственнэ:''' || [{{{псалъэпкъ1}}}]энууэ || [{{{псалъэпкъ1}}}]энурауэ || [{{{псалъэпкъ1}}}]энухэу || [{{{псалъэпкъ1}}}]энухэрауэ\n|}\n";
    // Independent explicit literal reference: only the known generated marker
    // replaces each unbound parameter; its 42 authored wrappers remain visible.
    const reference = "==Глагол лъэмыӏэс \"[[щэнэуэн]]\"-ым и спряженэр==\n<br/>\n{| class=\"wikitable\"\n|-\n! Инфинитив (масдар) !!\n|-\n| щыӀэныгъэ: || <nowiki>[missing parameter]</nowiki>эн\n|-\n| щымыӀэныгъэ: || мы<nowiki>[missing parameter]</nowiki>эн\n|}\n\n{| class=\"wikitable\"\n|-\n! Инфинитив (масдар) щхьэкӀэ зэхъуэкӀа !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр\n|-\n| щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>эн || у<nowiki>[missing parameter]</nowiki>эн || <nowiki>[missing parameter]</nowiki>эн || ды<nowiki>[missing parameter]</nowiki>эн || фы<nowiki>[missing parameter]</nowiki>эн || <nowiki>[missing parameter]</nowiki>эн(хэ)\n|-\n| щымыӀэныгъэ: || сымы<nowiki>[missing parameter]</nowiki>эн || умы<nowiki>[missing parameter]</nowiki>эн || мы<nowiki>[missing parameter]</nowiki>эн || дымы<nowiki>[missing parameter]</nowiki>эн || фымы<nowiki>[missing parameter]</nowiki>эн || мы<nowiki>[missing parameter]</nowiki>эн(хэ)\n|}\n\n{| class=\"wikitable\"\n|-\n! унафэ наклоненэ !! уэ !! фэ \n|-\n| щыӀэныгъэ: || шэнауэ! || фышэнауэ!\n|-\n| щымыӀэныгъэ: || умышэнауэ! || фымышэнауэ!\n|}\n\n{| class=\"wikitable\"\n|-\n! Ре-кӀэ унафэ наклоненэ !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр\n|-\n| щыӀэныгъэ: || срешэнауэ || урешэнауэ || ирешэнауэ || дрешэнауэ || фрешэнауэ || ирешэнауэ\n|-\n| щымыӀэныгъэ: || сремышэнауэ || уремышэнауэ || иремышэнауэ || дремышэнауэ || фремышэнауэ || иремышэнауэ\n|}\n\n{| class=\"wikitable\"\n|-\n! ЗэраӀуатэ наклоненэ !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр\n|-\n| ит зэман – щыӀэныгъэ: || сошэнауэ(р) || уошэнауэ(р) || мэшэнауэ(р) || дошэнауэ(р) || фошэнауэ(р) || мэшэнауэ(хэ)(р)\n|-\n| ит зэман – щымыӀэныгъэ: || сышэнауэркъым || ушэнауэркъым || шэнауэркъым || дышэнауэркъым || фышэнауэркъым || шэнауэ(хэ)ркъым\n|-\n| блэкӀа зэфӀэмыкӀа зэман (имперфект) – щыӀэныгъэ: || сышэнауэ(р)т || ушэнауэ(р)т || шэнауэ(р)т || дышэнауэ(р)т || фышэнауэ(р)т || шэнауэ(хэ)(р)т\n|-\n| блэкӀа зэфӀэмыкӀа зэман (имперфект) – щымыӀэныгъэ: || сышэнауэ(р)тэкъым || ушэнауэ(р)тэкъым || шэнауэ(р)тэкъым || дышэнауэ(р)тэкъым || фышэнауэ(р)тэкъым || шэнауэ(хэ)(р)тэкъым\n|-\n| блэкӀа зэфӀэкӀа зэман (перфект) – щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>ащ || у<nowiki>[missing parameter]</nowiki>ащ || <nowiki>[missing parameter]</nowiki>ащ || ды<nowiki>[missing parameter]</nowiki>ащ || фы<nowiki>[missing parameter]</nowiki>ащ || <nowiki>[missing parameter]</nowiki>а(хэ)щ \n|-\n| блэкӀа зэфӀэкӀа зэман (перфект) – щымыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>акъым || у<nowiki>[missing parameter]</nowiki>акъым || <nowiki>[missing parameter]</nowiki>акъым || ды<nowiki>[missing parameter]</nowiki>акъым || фы<nowiki>[missing parameter]</nowiki>акъым || <nowiki>[missing parameter]</nowiki>а(хэ)къым\n|-\n| блэкӀа зэфӀэкӀа и пэ ит зэман (плюс квамперфект) – щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>ат || у<nowiki>[missing parameter]</nowiki>ат || <nowiki>[missing parameter]</nowiki>ат || ды<nowiki>[missing parameter]</nowiki>ат || фы<nowiki>[missing parameter]</nowiki>ат || <nowiki>[missing parameter]</nowiki>а(хэ)т \n|-\n| блэкӀа зэфӀэкӀа и пэ ит зэман (плюс квамперфект) – щымыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>атэкъым || у<nowiki>[missing parameter]</nowiki>атэкъым || <nowiki>[missing parameter]</nowiki>атэкъым || ды<nowiki>[missing parameter]</nowiki>атэкъым || фы<nowiki>[missing parameter]</nowiki>атэкъым || <nowiki>[missing parameter]</nowiki>а(хэ)тэкъым \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман – щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>эгъащ || у<nowiki>[missing parameter]</nowiki>эгъащ || <nowiki>[missing parameter]</nowiki>эгъащ || ды<nowiki>[missing parameter]</nowiki>эгъащ || фы<nowiki>[missing parameter]</nowiki>эгъащ || <nowiki>[missing parameter]</nowiki>эгъа(хэ)щ \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман – щымыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>эгъакъым || у<nowiki>[missing parameter]</nowiki>эгъакъым || <nowiki>[missing parameter]</nowiki>эгъакъым || ды<nowiki>[missing parameter]</nowiki>эгъакъым || фы<nowiki>[missing parameter]</nowiki>эгъакъым || <nowiki>[missing parameter]</nowiki>эгъа(хэ)къым \n|-\n| блэкӀа жыжьэ зэфӀэкӀа и пэ ит зэман – щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>эгъат || у<nowiki>[missing parameter]</nowiki>эгъат || <nowiki>[missing parameter]</nowiki>эгъат || ды<nowiki>[missing parameter]</nowiki>эгъат || фы<nowiki>[missing parameter]</nowiki>эгъат || <nowiki>[missing parameter]</nowiki>эгъа(хэ)т \n|-\n| блэкӀа жыжьэ зэфӀэкӀа и пэ ит зэман – щымыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>эгъатэкъым || у<nowiki>[missing parameter]</nowiki>эгъатэкъым || <nowiki>[missing parameter]</nowiki>эгъатэкъым || ды<nowiki>[missing parameter]</nowiki>эгъатэкъым || фы<nowiki>[missing parameter]</nowiki>эгъатэкъым || <nowiki>[missing parameter]</nowiki>эгъа(хэ)тэкъым \n|-\n| блэкӀа гъэкӀэщӀа зэман I – щыӀэныгъэ: || сышэнауэщ || ушэнауэщ || шэнауэщ || дышэнауэщ || фышэнауэщ || шэнауэ(хэ)щ \n|-\n| блэкӀа гъэкӀэщӀа зэман I – щымыӀэныгъэ: || сышэнауэкъым || ушэнауэкъым || шэнауэкъым || дышэнауэкъым || фышэнауэкъым || шэнауэ(хэ)къым \n|-\n| блэкӀа гъэкӀэщӀа зэман II – щыӀэныгъэ: || сышэнауэт || ушэнауэт || шэнауэт || дышэнауэт || фышэнауэт || шэнауэ(хэ)т \n|-\n| блэкӀа гъэкӀэщӀа зэман II – щымыӀэныгъэ: || сышэнауэтэкъым || ушэнауэтэкъым || шэнауэтэкъым || дышэнауэтэкъым || фышэнауэтэкъым || шэнауэ(хэ)тэкъым \n|-\n| къэкӀуэну мыгъэбелджыла зэман – щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>энщ || у<nowiki>[missing parameter]</nowiki>энщ || <nowiki>[missing parameter]</nowiki>энщ || ды<nowiki>[missing parameter]</nowiki>энщ || фы<nowiki>[missing parameter]</nowiki>энщ || <nowiki>[missing parameter]</nowiki>эн(хэ)щ \n|-\n| къэкӀуэну мыгъэбелджыла зэман – щымыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>энкъым || у<nowiki>[missing parameter]</nowiki>энкъым || <nowiki>[missing parameter]</nowiki>энкъым || ды<nowiki>[missing parameter]</nowiki>энкъым || фы<nowiki>[missing parameter]</nowiki>энкъым || <nowiki>[missing parameter]</nowiki>эн(хэ)къым \n|-\n| къэкӀуэну гъэбелджыла зэман – щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>энущ || у<nowiki>[missing parameter]</nowiki>энущ || <nowiki>[missing parameter]</nowiki>энущ || ды<nowiki>[missing parameter]</nowiki>энущ || фы<nowiki>[missing parameter]</nowiki>энущ || <nowiki>[missing parameter]</nowiki>эну(хэ)щ \n|-\n| къэкӀуэну гъэбелджыла зэман – щымыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>энукъым || у<nowiki>[missing parameter]</nowiki>энукъым || <nowiki>[missing parameter]</nowiki>энукъым || ды<nowiki>[missing parameter]</nowiki>энукъым || фы<nowiki>[missing parameter]</nowiki>энукъым || <nowiki>[missing parameter]</nowiki>эну(хэ)къым \n|}\n\n{| class=\"wikitable\"\n|-\n! ЗэрыупщӀэ наклоненэ !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр \n|-\n| ит зэман – щыӀэныгъэ: || сышэнауэрэ || ушэнауэрэ || шэнауэрэ || дышэнауэрэ || фышэнауэрэ || шэнауэ(хэ)рэ \n|-\n| ит зэман – щымыӀэныгъэ: || сышэнауэркъэ || ушэнауэркъэ || шэнауэркъэ || дышэнауэркъэ || фышэнауэркъэ || шэнауэ(хэ)ркъэ \n|-\n| блэкӀа зэфӀэмыкӀа зэман (имперфект) – щыӀэныгъэ: || сышэнауэ(р)т || ушэнауэ(р)т || шэнауэ(р)т || дышэнауэ(р)т || фышэнауэ(р)т || шэнауэ(хэ)(р)т\n|-\n| блэкӀа зэфӀэмыкӀа зэман (имперфект) – щымыӀэныгъэ: || сышэнауэ(р)тэкъэ || ушэнауэ(р)тэкъэ || шэнауэ(р)тэкъэ || дышэнауэ(р)тэкъэ || фышэнауэ(р)тэкъэ || шэнауэ(хэ)(р)тэкъэ\n|-\n| блэкӀа зэфӀэкӀа зэман (перфект) – щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>а || у<nowiki>[missing parameter]</nowiki>а || <nowiki>[missing parameter]</nowiki>а || ды<nowiki>[missing parameter]</nowiki>а || фы<nowiki>[missing parameter]</nowiki>а || <nowiki>[missing parameter]</nowiki>а(хэ) \n|-\n| блэкӀа зэфӀэкӀа зэман (перфект) – щымыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>акъэ || у<nowiki>[missing parameter]</nowiki>акъэ || <nowiki>[missing parameter]</nowiki>акъэ || ды<nowiki>[missing parameter]</nowiki>акъэ || фы<nowiki>[missing parameter]</nowiki>акъэ || <nowiki>[missing parameter]</nowiki>а(хэ)къэ \n|-\n| блэкӀа зэфӀэкӀа и пэ ит зэман (плюс квамперфект) – щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>ат || у<nowiki>[missing parameter]</nowiki>ат || <nowiki>[missing parameter]</nowiki>ат || ды<nowiki>[missing parameter]</nowiki>ат || фы<nowiki>[missing parameter]</nowiki>ат || <nowiki>[missing parameter]</nowiki>а(хэ)т \n|-\n| блэкӀа зэфӀэкӀа и пэ ит зэман (плюс квамперфект) – щымыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>атэкъэ || у<nowiki>[missing parameter]</nowiki>атэкъэ || <nowiki>[missing parameter]</nowiki>атэкъэ || ды<nowiki>[missing parameter]</nowiki>атэкъэ || фы<nowiki>[missing parameter]</nowiki>атэкъэ || <nowiki>[missing parameter]</nowiki>а(хэ)тэкъэ \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман – щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>эгъа || у<nowiki>[missing parameter]</nowiki>эгъа || <nowiki>[missing parameter]</nowiki>эгъа || ды<nowiki>[missing parameter]</nowiki>эгъа || фы<nowiki>[missing parameter]</nowiki>эгъа || <nowiki>[missing parameter]</nowiki>эгъа(хэ) \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман – щымыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>эгъакъэ || у<nowiki>[missing parameter]</nowiki>эгъакъэ || <nowiki>[missing parameter]</nowiki>эгъакъэ || ды<nowiki>[missing parameter]</nowiki>эгъакъэ || фы<nowiki>[missing parameter]</nowiki>эгъакъэ || <nowiki>[missing parameter]</nowiki>эгъа(хэ)къэ \n|-\n| блэкӀа жыжьэ зэфӀэкӀа и пэ ит зэман – щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>эгъат || у<nowiki>[missing parameter]</nowiki>эгъат || <nowiki>[missing parameter]</nowiki>эгъат || ды<nowiki>[missing parameter]</nowiki>эгъат || фы<nowiki>[missing parameter]</nowiki>эгъат || <nowiki>[missing parameter]</nowiki>эгъа(хэ)т \n|-\n| блэкӀа жыжьэ зэфӀэкӀа и пэ ит зэман (плюс квамперфект) – щымыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>эгъатэкъэ || у<nowiki>[missing parameter]</nowiki>эгъатэкъэ || <nowiki>[missing parameter]</nowiki>эгъатэкъэ || ды<nowiki>[missing parameter]</nowiki>эгъатэкъэ || фы<nowiki>[missing parameter]</nowiki>эгъатэкъэ || <nowiki>[missing parameter]</nowiki>эгъа(хэ)тэкъэ \n|-\n| блэкӀа гъэкӀэщӀа зэман I – щыӀэныгъэ: || сышэнауэ || ушэнауэ || шэнауэ || дышэнауэ || фышэнауэ || шэнауэ(хэ) \n|-\n| блэкӀа гъэкӀэщӀа зэман I – щымыӀэныгъэ: || сышэнауэкъэ || ушэнауэкъэ || шэнауэкъэ || дышэнауэкъэ || фышэнауэкъэ || шэнауэ(хэ)къэ \n|-\n| блэкӀа гъэкӀэщӀа зэман II – щыӀэныгъэ: || сышэнауэт || ушэнауэт || шэнауэт || дышэнауэт || фышэнауэт || шэнауэ(хэ)т \n|-\n| блэкӀа гъэкӀэщӀа зэман II – щымыӀэныгъэ: || сышэнауэтэкъэ || ушэнауэтэкъэ || шэнауэтэкъэ || дышэнауэтэкъэ || фышэнауэтэкъэ || шэнауэ(хэ)тэкъэ \n|-\n| къэкӀуэну  мыгъэбелджыла зэман – щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>эн || у<nowiki>[missing parameter]</nowiki>эн || <nowiki>[missing parameter]</nowiki>эн || ды<nowiki>[missing parameter]</nowiki>эн || фы<nowiki>[missing parameter]</nowiki>эн || <nowiki>[missing parameter]</nowiki>эн(хэ) \n|-\n| къэкӀуэну  мыгъэбелджыла зэман – щымыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>энкъэ || у<nowiki>[missing parameter]</nowiki>энкъэ || <nowiki>[missing parameter]</nowiki>энкъэ || ды<nowiki>[missing parameter]</nowiki>энкъэ || фы<nowiki>[missing parameter]</nowiki>энкъэ || <nowiki>[missing parameter]</nowiki>эн(хэ)къэ \n|-\n| къэкӀуэну гъэбелджыла зэман – щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>эну || у<nowiki>[missing parameter]</nowiki>эну || <nowiki>[missing parameter]</nowiki>эну || ды<nowiki>[missing parameter]</nowiki>эну || фы<nowiki>[missing parameter]</nowiki>эну || <nowiki>[missing parameter]</nowiki>эну(хэ) \n|-\n| къэкӀуэну гъэбелджыла зэман – щымыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>энукъэ || у<nowiki>[missing parameter]</nowiki>энукъэ || <nowiki>[missing parameter]</nowiki>энукъэ || ды<nowiki>[missing parameter]</nowiki>энукъэ || фы<nowiki>[missing parameter]</nowiki>энукъэ || <nowiki>[missing parameter]</nowiki>эну(хэ)къэ \n|}\n\n{| class=\"wikitable\"\n|-\n! условнэ ипэжыпӀэкӀэ щыӀэ наклоненэ !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр \n|-\n| ит зэман – щыӀэныгъэ: || сышэнауэмэ || ушэнауэмэ || шэнауэмэ || дышэнауэмэ || фышэнауэмэ || шэнауэ(хэ)мэ \n|-\n| ит зэман – щымыӀэныгъэ: || сымышэнауэмэ || умышэнауэмэ || мышэнауэмэ || дымышэнауэмэ || фымышэнауэмэ || мышэнауэ(хэ)мэ \n|-\n| блэкӀа зэфӀэкӀа зэман (перфект) – щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>амэ || у<nowiki>[missing parameter]</nowiki>амэ || <nowiki>[missing parameter]</nowiki>амэ || ды<nowiki>[missing parameter]</nowiki>амэ || фы<nowiki>[missing parameter]</nowiki>амэ || <nowiki>[missing parameter]</nowiki>а(хэ)мэ \n|-\n| блэкӀа зэфӀэкӀа зэман (перфект) – щымыӀэныгъэ: || сымы<nowiki>[missing parameter]</nowiki>амэ || умы<nowiki>[missing parameter]</nowiki>амэ || мы<nowiki>[missing parameter]</nowiki>амэ || дымы<nowiki>[missing parameter]</nowiki>амэ || фымы<nowiki>[missing parameter]</nowiki>амэ ||мы<nowiki>[missing parameter]</nowiki>а(хэ)мэ \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман (плюс квамперфект)– щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>эгъамэ || у<nowiki>[missing parameter]</nowiki>эгъамэ || <nowiki>[missing parameter]</nowiki>эгъамэ || ды<nowiki>[missing parameter]</nowiki>эгъамэ || фы<nowiki>[missing parameter]</nowiki>эгъамэ || <nowiki>[missing parameter]</nowiki>эгъа(хэ)мэ \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман (плюс квамперфект) – щымыӀэныгъэ: || сымы<nowiki>[missing parameter]</nowiki>эгъамэ || умы<nowiki>[missing parameter]</nowiki>эгъамэ || мы<nowiki>[missing parameter]</nowiki>эгъамэ || дымы<nowiki>[missing parameter]</nowiki>эгъамэ || фымы<nowiki>[missing parameter]</nowiki>эгъамэ || мы<nowiki>[missing parameter]</nowiki>эгъа(хэ)мэ \n|-\n| къэкӀуэну мыгъэбелджыла зэман – щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>энмэ || у<nowiki>[missing parameter]</nowiki>энмэ || <nowiki>[missing parameter]</nowiki>энмэ || ды<nowiki>[missing parameter]</nowiki>энмэ || фы<nowiki>[missing parameter]</nowiki>энмэ || <nowiki>[missing parameter]</nowiki>эн(хэ)мэ \n|-\n| къэкӀуэну мыгъэбелджыла зэман – щымыӀэныгъэ: || сымы<nowiki>[missing parameter]</nowiki>энмэ || умы<nowiki>[missing parameter]</nowiki>энмэ || мы<nowiki>[missing parameter]</nowiki>энмэ || дымы<nowiki>[missing parameter]</nowiki>энмэ || фымы<nowiki>[missing parameter]</nowiki>энмэ || мы<nowiki>[missing parameter]</nowiki>эн(хэ)мэ \n|-\n| къэкӀуэну гъэбелджыла зэман – щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>энумэ || у<nowiki>[missing parameter]</nowiki>энумэ || <nowiki>[missing parameter]</nowiki>энумэ || ды<nowiki>[missing parameter]</nowiki>энумэ || фы<nowiki>[missing parameter]</nowiki>энумэ || <nowiki>[missing parameter]</nowiki>эну(хэ)мэ \n|-\n| къэкӀуэну гъэбелджыла зэман – щымыӀэныгъэ: || сымы<nowiki>[missing parameter]</nowiki>энумэ || умы<nowiki>[missing parameter]</nowiki>энумэ || мы<nowiki>[missing parameter]</nowiki>энумэ || дымы<nowiki>[missing parameter]</nowiki>энумэ || фымы<nowiki>[missing parameter]</nowiki>энумэ || мы<nowiki>[missing parameter]</nowiki>эну(хэ)мэ \n|}\n\n{| class=\"wikitable\"\n|-\n! условнэ ипэжыпӀэкӀэ щымыӀэ наклоненэ !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр \n|-\n| ит зэман – щыӀэныгъэ: || сышэнауэтэмэ || ушэнауэтэмэ || шэнауэтэмэ || дышэнауэтэмэ || фышэнауэтэмэ || шэнауэ(хэ)тэмэ \n|-\n| ит зэман – щымыӀэныгъэ: || сымышэнауэтэмэ || умышэнауэтэмэ || мышэнауэтэмэ || дымышэнауэтэмэ || фымышэнауэтэмэ || мышэнауэ(хэ)тэмэ \n|-\n| блэкӀа зэфӀэкӀа зэман (перфект) – щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>атэмэ || у<nowiki>[missing parameter]</nowiki>атэмэ || <nowiki>[missing parameter]</nowiki>атэмэ || ды<nowiki>[missing parameter]</nowiki>атэмэ || фы<nowiki>[missing parameter]</nowiki>атэмэ || <nowiki>[missing parameter]</nowiki>а(хэ)тэмэ \n|-\n| блэкӀа зэфӀэкӀа зэман (перфект) – щымыӀэныгъэ: || сымы<nowiki>[missing parameter]</nowiki>атэмэ || умы<nowiki>[missing parameter]</nowiki>атэмэ || мы<nowiki>[missing parameter]</nowiki>атэмэ || дымы<nowiki>[missing parameter]</nowiki>атэмэ || фымы<nowiki>[missing parameter]</nowiki>атэмэ || мы<nowiki>[missing parameter]</nowiki>а(хэ)тэмэ \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман (плюс квамперфект)– щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>эгъатэмэ || у<nowiki>[missing parameter]</nowiki>эгъатэмэ || <nowiki>[missing parameter]</nowiki>эгъатэмэ || ды<nowiki>[missing parameter]</nowiki>эгъатэмэ || фы<nowiki>[missing parameter]</nowiki>эгъатэмэ || <nowiki>[missing parameter]</nowiki>эгъа(хэ)тэмэ \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман (плюс квамперфект) – щымыӀэныгъэ: || сымы<nowiki>[missing parameter]</nowiki>эгъатэмэ || умы<nowiki>[missing parameter]</nowiki>эгъатэмэ || мы<nowiki>[missing parameter]</nowiki>эгъатэмэ || дымы<nowiki>[missing parameter]</nowiki>эгъатэмэ || фымы<nowiki>[missing parameter]</nowiki>эгъатэмэ || мы<nowiki>[missing parameter]</nowiki>эгъа(хэ)тэмэ \n|-\n| къэкӀуэну мыгъэбелджыла зэман – щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>энтэмэ || у<nowiki>[missing parameter]</nowiki>энтэмэ || <nowiki>[missing parameter]</nowiki>энтэмэ || ды<nowiki>[missing parameter]</nowiki>энтэмэ || фы<nowiki>[missing parameter]</nowiki>энтэмэ || <nowiki>[missing parameter]</nowiki>эн(хэ)тэмэ \n|-\n| къэкӀуэну мыгъэбелджыла зэман – щымыӀэныгъэ: || сымы<nowiki>[missing parameter]</nowiki>энтэмэ || умы<nowiki>[missing parameter]</nowiki>энтэмэ || мы<nowiki>[missing parameter]</nowiki>энтэмэ || дымы<nowiki>[missing parameter]</nowiki>энтэмэ || фымы<nowiki>[missing parameter]</nowiki>энтэмэ || мы<nowiki>[missing parameter]</nowiki>эн(хэ)тэмэ \n|-\n| къэкӀуэну гъэбелджыла зэман – щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>энутэмэ || у<nowiki>[missing parameter]</nowiki>энутэмэ || <nowiki>[missing parameter]</nowiki>энутэмэ || ды<nowiki>[missing parameter]</nowiki>энутэмэ || фы<nowiki>[missing parameter]</nowiki>энутэмэ || <nowiki>[missing parameter]</nowiki>эну(хэ)тэмэ \n|-\n| къэкӀуэну гъэбелджыла зэман – щымыӀэныгъэ: || сымы<nowiki>[missing parameter]</nowiki>энутэмэ || умы<nowiki>[missing parameter]</nowiki>энутэмэ || мы<nowiki>[missing parameter]</nowiki>энутэмэ || дымы<nowiki>[missing parameter]</nowiki>энутэмэ || фымы<nowiki>[missing parameter]</nowiki>энутэмэ || мы<nowiki>[missing parameter]</nowiki>эну(хэ)тэмэ \n|}\n\n{| class=\"wikitable\"\n|-\n! сослагательнэ наклоненэ !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр \n|-\n| къэкӀуэну мыгъэбелджыла зэман – щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>энт || у<nowiki>[missing parameter]</nowiki>энт || <nowiki>[missing parameter]</nowiki>энт || ды<nowiki>[missing parameter]</nowiki>энт || фы<nowiki>[missing parameter]</nowiki>энт || <nowiki>[missing parameter]</nowiki>эн(хэ)т \n|-\n| къэкӀуэну мыгъэбелджыла зэман – щымыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>энтэкъым || у<nowiki>[missing parameter]</nowiki>энтэкъым || <nowiki>[missing parameter]</nowiki>энтэкъым || ды<nowiki>[missing parameter]</nowiki>энтэкъым || фы<nowiki>[missing parameter]</nowiki>энтэкъым || <nowiki>[missing parameter]</nowiki>эн(хэ)тэкъым \n|-\n| къэкӀуэну гъэбелджыла зэман – щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>энут || у<nowiki>[missing parameter]</nowiki>энут || <nowiki>[missing parameter]</nowiki>энут || ды<nowiki>[missing parameter]</nowiki>энут || фы<nowiki>[missing parameter]</nowiki>энут || <nowiki>[missing parameter]</nowiki>эну(хэ)т \n|-\n| къэкӀуэну гъэбелджыла зэман – щымыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>энутэкъым || у<nowiki>[missing parameter]</nowiki>энутэкъым || <nowiki>[missing parameter]</nowiki>энутэкъым || ды<nowiki>[missing parameter]</nowiki>энутэкъым || фы<nowiki>[missing parameter]</nowiki>энутэкъым || <nowiki>[missing parameter]</nowiki>эну(хэ)тэкъым \n|}\n\n{| class=\"wikitable\"\n|-\n! уступительнэ ипэжыпӀэкӀэ щыӀэ наклоненэ !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр \n|-\n| ит зэман – щыӀэныгъэ: || сышэнауэми || ушэнауэми || шэнауэми || дышэнауэми || фышэнауэми || шэнауэ(хэ)ми \n|-\n| ит зэман – щымыӀэныгъэ: || сымышэнауэми || умышэнауэми || мышэнауэми || дымышэнауэми || фымышэнауэми || мышэнауэ(хэ)ми \n|-\n| блэкӀа зэфӀэкӀа зэман (перфект) – щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>ами || у<nowiki>[missing parameter]</nowiki>ами || <nowiki>[missing parameter]</nowiki>ами || ды<nowiki>[missing parameter]</nowiki>ами || фы<nowiki>[missing parameter]</nowiki>ами || <nowiki>[missing parameter]</nowiki>а(хэ)ми \n|-\n| блэкӀа зэфӀэкӀа зэман (перфект) – щымыӀэныгъэ: || сымы<nowiki>[missing parameter]</nowiki>ами || умы<nowiki>[missing parameter]</nowiki>ами || мы<nowiki>[missing parameter]</nowiki>ами || дымы<nowiki>[missing parameter]</nowiki>ами || фымы<nowiki>[missing parameter]</nowiki>ами || мы<nowiki>[missing parameter]</nowiki>а(хэ)ми \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман (плюс квамперфект)– щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>эгъами || у<nowiki>[missing parameter]</nowiki>эгъами || <nowiki>[missing parameter]</nowiki>эгъами || ды<nowiki>[missing parameter]</nowiki>эгъами || фы<nowiki>[missing parameter]</nowiki>эгъами || <nowiki>[missing parameter]</nowiki>эгъа(хэ)ми \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман (плюс квамперфект) – щымыӀэныгъэ: || сымы<nowiki>[missing parameter]</nowiki>эгъами || умы<nowiki>[missing parameter]</nowiki>эгъами || мы<nowiki>[missing parameter]</nowiki>эгъами || дымы<nowiki>[missing parameter]</nowiki>эгъами || фымы<nowiki>[missing parameter]</nowiki>эгъами || мы<nowiki>[missing parameter]</nowiki>эгъа(хэ)ми \n|-\n| къэкӀуэну мыгъэбелджыла зэман – щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>энми || у<nowiki>[missing parameter]</nowiki>энми || <nowiki>[missing parameter]</nowiki>энми || ды<nowiki>[missing parameter]</nowiki>энми || фы<nowiki>[missing parameter]</nowiki>энми || <nowiki>[missing parameter]</nowiki>эн(хэ)ми \n|-\n| къэкӀуэну мыгъэбелджыла зэман – щымыӀэныгъэ: || сымы<nowiki>[missing parameter]</nowiki>энми || умы<nowiki>[missing parameter]</nowiki>энми || мы<nowiki>[missing parameter]</nowiki>энми || дымы<nowiki>[missing parameter]</nowiki>энми || фымы<nowiki>[missing parameter]</nowiki>энми || мы<nowiki>[missing parameter]</nowiki>эн(хэ)ми \n|-\n| къэкӀуэну гъэбелджыла зэман – щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>энуми || у<nowiki>[missing parameter]</nowiki>энуми || <nowiki>[missing parameter]</nowiki>энуми || ды<nowiki>[missing parameter]</nowiki>энуми || фы<nowiki>[missing parameter]</nowiki>энуми || <nowiki>[missing parameter]</nowiki>эну(хэ)ми \n|-\n| къэкӀуэну гъэбелджыла зэман – щымыӀэныгъэ: || сымы<nowiki>[missing parameter]</nowiki>энуми || умы<nowiki>[missing parameter]</nowiki>энуми || мы<nowiki>[missing parameter]</nowiki>энуми || дымы<nowiki>[missing parameter]</nowiki>энуми || фымы<nowiki>[missing parameter]</nowiki>энуми || мы<nowiki>[missing parameter]</nowiki>эну(хэ)ми \n|}\n\n{| class=\"wikitable\"\n|-\n! уступительнэ ипэжыпӀэкӀэ щымыӀэ наклоненэ !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр \n|-\n| ит зэман – щыӀэныгъэ: || сышэнауэтэми || ушэнауэтэми || шэнауэтэми || дышэнауэтэми || фышэнауэтэми || шэнауэ(хэ)тэми \n|-\n| ит зэман – щымыӀэныгъэ: || сымышэнауэтэми || умышэнауэтэми || мышэнауэтэми || дымышэнауэтэми || фымышэнауэтэми || мышэнауэ(хэ)тэми \n|-\n| блэкӀа зэфӀэкӀа зэман (перфект) – щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>атэми || у<nowiki>[missing parameter]</nowiki>атэми || <nowiki>[missing parameter]</nowiki>атэми || ды<nowiki>[missing parameter]</nowiki>атэми || фы<nowiki>[missing parameter]</nowiki>атэми || <nowiki>[missing parameter]</nowiki>а(хэ)тэми \n|-\n| блэкӀа зэфӀэкӀа зэман (перфект) – щымыӀэныгъэ: || сымы<nowiki>[missing parameter]</nowiki>атэми || умы<nowiki>[missing parameter]</nowiki>атэми || мы<nowiki>[missing parameter]</nowiki>атэми || дымы<nowiki>[missing parameter]</nowiki>атэми || фымы<nowiki>[missing parameter]</nowiki>атэми || мы<nowiki>[missing parameter]</nowiki>а(хэ)тэми \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман (плюс квамперфект)– щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>эгъатэми || у<nowiki>[missing parameter]</nowiki>эгъатэми || <nowiki>[missing parameter]</nowiki>эгъатэми || ды<nowiki>[missing parameter]</nowiki>эгъатэми || фы<nowiki>[missing parameter]</nowiki>эгъатэми || <nowiki>[missing parameter]</nowiki>эгъа(хэ)тэми \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман (плюс квамперфект) – щымыӀэныгъэ: || сымы<nowiki>[missing parameter]</nowiki>эгъатэми || умы<nowiki>[missing parameter]</nowiki>эгъатэми || мы<nowiki>[missing parameter]</nowiki>эгъатэми || дымы<nowiki>[missing parameter]</nowiki>эгъатэми || фымы<nowiki>[missing parameter]</nowiki>эгъатэми || мы<nowiki>[missing parameter]</nowiki>эгъа(хэ)тэми \n|-\n| къэкӀуэну мыгъэбелджыла зэман – щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>энтэми || у<nowiki>[missing parameter]</nowiki>энтэми || <nowiki>[missing parameter]</nowiki>энтэми || ды<nowiki>[missing parameter]</nowiki>энтэми || фы<nowiki>[missing parameter]</nowiki>энтэми || <nowiki>[missing parameter]</nowiki>эн(хэ)тэми \n|-\n| къэкӀуэну мыгъэбелджыла зэман – щымыӀэныгъэ: || сымы<nowiki>[missing parameter]</nowiki>энтэми || умы<nowiki>[missing parameter]</nowiki>энтэми || мы<nowiki>[missing parameter]</nowiki>энтэми || дымы<nowiki>[missing parameter]</nowiki>энтэми || фымы<nowiki>[missing parameter]</nowiki>энтэми || мы<nowiki>[missing parameter]</nowiki>эн(хэ)тэми \n|-\n| къэкӀуэну гъэбелджыла зэман – щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>энутэми || у<nowiki>[missing parameter]</nowiki>энутэми || <nowiki>[missing parameter]</nowiki>энутэми || ды<nowiki>[missing parameter]</nowiki>энутэми || фы<nowiki>[missing parameter]</nowiki>энутэми || <nowiki>[missing parameter]</nowiki>эну(хэ)тэми \n|-\n| къэкӀуэну гъэбелджыла зэман – щымыӀэныгъэ: || сымы<nowiki>[missing parameter]</nowiki>энутэми || умы<nowiki>[missing parameter]</nowiki>энутэми || мы<nowiki>[missing parameter]</nowiki>энутэми || дымы<nowiki>[missing parameter]</nowiki>энутэми || фымы<nowiki>[missing parameter]</nowiki>энутэми || мы<nowiki>[missing parameter]</nowiki>эну(хэ)тэми \n|}\n\n{| class=\"wikitable\"\n|-\n! гъэщӀэгъ<nowiki>[missing parameter]</nowiki>эныгъэ наклоненэ !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр \n|-\n|щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>аи || у<nowiki>[missing parameter]</nowiki>аи || <nowiki>[missing parameter]</nowiki>аи || ды<nowiki>[missing parameter]</nowiki>аи || фы<nowiki>[missing parameter]</nowiki>аи || <nowiki>[missing parameter]</nowiki>аи \n|-\n|щымыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>акъыми || у<nowiki>[missing parameter]</nowiki>акъыми || <nowiki>[missing parameter]</nowiki>акъыми || ды<nowiki>[missing parameter]</nowiki>акъыми || фы<nowiki>[missing parameter]</nowiki>акъыми || <nowiki>[missing parameter]</nowiki>акъыми \n|}\n\n{| class=\"wikitable\"\n|-\n! фӀэфӀыныгъэ  наклоненэ !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр \n|-\n|щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>ащэрэт || у<nowiki>[missing parameter]</nowiki>ащэрэт || <nowiki>[missing parameter]</nowiki>ащэрэт || ды<nowiki>[missing parameter]</nowiki>ащэрэт || фы<nowiki>[missing parameter]</nowiki>ащэрэт || <nowiki>[missing parameter]</nowiki>ащэрэт \n|-\n|щымыӀэныгъэ: || сымы<nowiki>[missing parameter]</nowiki>ащэрэт || умы<nowiki>[missing parameter]</nowiki>ащэрэт || мы<nowiki>[missing parameter]</nowiki>ащэрэт || дымы<nowiki>[missing parameter]</nowiki>ащэрэт || фымы<nowiki>[missing parameter]</nowiki>ащэрэт || мы<nowiki>[missing parameter]</nowiki>ащэрэт \n|}\n\n{| class=\"wikitable\"\n|-\n! шэч къытехьэныгъэ наклоненэ !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр \n|-\n|гъэн-кӀэ мыгъэбелджыла - щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>агъэнщ || у<nowiki>[missing parameter]</nowiki>агъэнщ || <nowiki>[missing parameter]</nowiki>агъэнщ || ды<nowiki>[missing parameter]</nowiki>агъэнщ || фы<nowiki>[missing parameter]</nowiki>агъэнщ || <nowiki>[missing parameter]</nowiki>агъэнщ \n|-\n|гъэн-кӀэ мыгъэбелджыла - щымыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>агъэнкъым || у<nowiki>[missing parameter]</nowiki>агъэнкъым || <nowiki>[missing parameter]</nowiki>агъэнкъым || ды<nowiki>[missing parameter]</nowiki>агъэнкъым || фы<nowiki>[missing parameter]</nowiki>агъэнкъым || <nowiki>[missing parameter]</nowiki>агъэнкъым \n|-\n|гъэнт-кӀэ мыгъэбелджыла - щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>агъэнт || у<nowiki>[missing parameter]</nowiki>агъэнт || <nowiki>[missing parameter]</nowiki>агъэнт || ды<nowiki>[missing parameter]</nowiki>агъэнт || фы<nowiki>[missing parameter]</nowiki>агъэнт || <nowiki>[missing parameter]</nowiki>агъэнт \n|-\n|гъэнт-кӀэ мыгъэбелджыла - щымыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>агъэнтэкъым || у<nowiki>[missing parameter]</nowiki>агъэнтэкъым || <nowiki>[missing parameter]</nowiki>агъэнтэкъым || ды<nowiki>[missing parameter]</nowiki>агъэнтэкъым || фы<nowiki>[missing parameter]</nowiki>агъэнтэкъым || <nowiki>[missing parameter]</nowiki>агъэнтэкъым \n|-\n|гъэн-кӀэ мыгъэбелджыла зэрыупщӀэ - щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>агъэн || у<nowiki>[missing parameter]</nowiki>агъэн || <nowiki>[missing parameter]</nowiki>агъэн || ды<nowiki>[missing parameter]</nowiki>агъэн || фы<nowiki>[missing parameter]</nowiki>агъэн || <nowiki>[missing parameter]</nowiki>агъэн \n|-\n|гъэн-кӀэ мыгъэбелджыла зэрыупщӀэ - щымыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>агъэнкъэ || у<nowiki>[missing parameter]</nowiki>агъэнкъэ || <nowiki>[missing parameter]</nowiki>агъэнкъэ || ды<nowiki>[missing parameter]</nowiki>агъэнкъэ || фы<nowiki>[missing parameter]</nowiki>агъэнкъэ || <nowiki>[missing parameter]</nowiki>агъэнкъэ \n|-\n|гъэнт-кӀэ мыгъэбелджыла зэрыупщӀэ - щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>агъэнт || у<nowiki>[missing parameter]</nowiki>агъэнт || <nowiki>[missing parameter]</nowiki>агъэнт || ды<nowiki>[missing parameter]</nowiki>агъэнт || фы<nowiki>[missing parameter]</nowiki>агъэнт || <nowiki>[missing parameter]</nowiki>агъэнт \n|-\n|гъэнт-кӀэ мыгъэбелджыла зэрыупщӀэ - щымыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>агъэнтэкъэ || у<nowiki>[missing parameter]</nowiki>агъэнтэкъэ || <nowiki>[missing parameter]</nowiki>агъэнтэкъэ || ды<nowiki>[missing parameter]</nowiki>агъэнтэкъэ || фы<nowiki>[missing parameter]</nowiki>агъэнтэкъэ || <nowiki>[missing parameter]</nowiki>агъэнтэкъэ \n|-\n|гъэну-кӀэ гъэбелджыла - щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>агъэнущ || у<nowiki>[missing parameter]</nowiki>агъэнущ || <nowiki>[missing parameter]</nowiki>агъэнущ || ды<nowiki>[missing parameter]</nowiki>агъэнущ || фы<nowiki>[missing parameter]</nowiki>агъэнущ || <nowiki>[missing parameter]</nowiki>агъэнущ \n|-\n|гъэну-кӀэ гъэбелджыла - щымыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>агъэнукъым || у<nowiki>[missing parameter]</nowiki>агъэнукъым || <nowiki>[missing parameter]</nowiki>агъэнукъым || ды<nowiki>[missing parameter]</nowiki>агъэнукъым || фы<nowiki>[missing parameter]</nowiki>агъэнукъым || <nowiki>[missing parameter]</nowiki>агъэнукъым \n|-\n|гъэнут-кӀэ гъэбелджыла - щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>агъэнут || у<nowiki>[missing parameter]</nowiki>агъэнут || <nowiki>[missing parameter]</nowiki>агъэнут || ды<nowiki>[missing parameter]</nowiki>агъэнут || фы<nowiki>[missing parameter]</nowiki>агъэнут || <nowiki>[missing parameter]</nowiki>агъэнут \n|-\n|гъэнут-кӀэ гъэбелджыла - щымыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>агъэнутэкъым || у<nowiki>[missing parameter]</nowiki>агъэнутэкъым || <nowiki>[missing parameter]</nowiki>агъэнутэкъым || ды<nowiki>[missing parameter]</nowiki>агъэнутэкъым || фы<nowiki>[missing parameter]</nowiki>агъэнутэкъым || <nowiki>[missing parameter]</nowiki>агъэнутэкъым \n|-\n|гъэну-кӀэ гъэбелджыла зэрыупщӀэ - щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>агъэну || у<nowiki>[missing parameter]</nowiki>агъэну || <nowiki>[missing parameter]</nowiki>агъэну || ды<nowiki>[missing parameter]</nowiki>агъэну || фы<nowiki>[missing parameter]</nowiki>агъэну || <nowiki>[missing parameter]</nowiki>агъэну \n|-\n|гъэну-кӀэ гъэбелджыла зэрыупщӀэ - щымыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>агъэнукъэ || у<nowiki>[missing parameter]</nowiki>агъэнукъэ || <nowiki>[missing parameter]</nowiki>агъэнукъэ || ды<nowiki>[missing parameter]</nowiki>агъэнукъэ || фы<nowiki>[missing parameter]</nowiki>агъэнукъэ || <nowiki>[missing parameter]</nowiki>агъэнукъэ \n|-\n|гъэнут-кӀэ гъэбелджыла зэрыупщӀэ - щыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>агъэнут || у<nowiki>[missing parameter]</nowiki>агъэнут || <nowiki>[missing parameter]</nowiki>агъэнут || ды<nowiki>[missing parameter]</nowiki>агъэнут || фы<nowiki>[missing parameter]</nowiki>агъэнут || <nowiki>[missing parameter]</nowiki>агъэнут \n|-\n|гъэнут-кӀэ гъэбелджыла зэрыупщӀэ - щымыӀэныгъэ: || сы<nowiki>[missing parameter]</nowiki>агъэнутэкъэ || у<nowiki>[missing parameter]</nowiki>агъэнутэкъэ || <nowiki>[missing parameter]</nowiki>агъэнутэкъэ || ды<nowiki>[missing parameter]</nowiki>агъэнутэкъэ || фы<nowiki>[missing parameter]</nowiki>агъэнутэкъэ || <nowiki>[missing parameter]</nowiki>агъэнутэкъэ \n|}\n\n{| class=\"wikitable\"\n|-\n! Причастиехэр !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр\n|-\n! Зылэжь (субъектнэ) причастие !!  !!  !!  !!  !!  !! \n|-\n| ит зэман - щыӀэныгъэ ||  сышэнауэ || ушэнауэ || шэнауэ || дышэнауэ || фышэнауэ || шэнауэ(хэ) \n|-\n| ит зэман - щымыӀэныгъэ || сымышэнауэ || умышэнауэ || мышэнауэ || дымышэнауэ || фымышэнауэ ||  мышэнауэ(хэ)\n|-\n| блэкӀа зэфӀэкӀа зэман - щыӀэныгъэ ||  сы<nowiki>[missing parameter]</nowiki>а || у<nowiki>[missing parameter]</nowiki>а || <nowiki>[missing parameter]</nowiki>а || ды<nowiki>[missing parameter]</nowiki>а || фы<nowiki>[missing parameter]</nowiki>а || <nowiki>[missing parameter]</nowiki>а(хэ) \n|-\n| блэкӀа зэфӀэкӀа зэман - щымыӀэныгъэ ||  сымы<nowiki>[missing parameter]</nowiki>а || умы<nowiki>[missing parameter]</nowiki>а || мы<nowiki>[missing parameter]</nowiki>а || дымы<nowiki>[missing parameter]</nowiki>а || фымы<nowiki>[missing parameter]</nowiki>а || мы<nowiki>[missing parameter]</nowiki>а(хэ)  \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман - щыӀэныгъэ ||  сы<nowiki>[missing parameter]</nowiki>эгъа || у<nowiki>[missing parameter]</nowiki>эгъа || <nowiki>[missing parameter]</nowiki>эгъа || ды<nowiki>[missing parameter]</nowiki>эгъа || фы<nowiki>[missing parameter]</nowiki>эгъа || <nowiki>[missing parameter]</nowiki>эгъа(хэ) \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман - щымыӀэныгъэ ||  сымы<nowiki>[missing parameter]</nowiki>эгъа || умы<nowiki>[missing parameter]</nowiki>эгъа || мы<nowiki>[missing parameter]</nowiki>эгъа || дымы<nowiki>[missing parameter]</nowiki>эгъа || фымы<nowiki>[missing parameter]</nowiki>эгъа || мы<nowiki>[missing parameter]</nowiki>эгъа(хэ)  \n|-\n| къэкӀуэну мыгъэбелджыла зэман - щыӀэныгъэ ||  сы<nowiki>[missing parameter]</nowiki>эн || у<nowiki>[missing parameter]</nowiki>эн || <nowiki>[missing parameter]</nowiki>эн || ды<nowiki>[missing parameter]</nowiki>эн || фы<nowiki>[missing parameter]</nowiki>эн  || <nowiki>[missing parameter]</nowiki>эн(хэ) \n|-\n| къэкӀуэну мыгъэбелджыла зэман - щымыӀэныгъэ ||  сымы<nowiki>[missing parameter]</nowiki>эн || умы<nowiki>[missing parameter]</nowiki>эн || мы<nowiki>[missing parameter]</nowiki>эн || дымы<nowiki>[missing parameter]</nowiki>эн || фымы<nowiki>[missing parameter]</nowiki>эн  || мы<nowiki>[missing parameter]</nowiki>эн(хэ)\n|-\n| къэкӀуэну гъэбелджыла зэман - щыӀэныгъэ ||  сы<nowiki>[missing parameter]</nowiki>эну || у<nowiki>[missing parameter]</nowiki>эну || <nowiki>[missing parameter]</nowiki>эну || ды<nowiki>[missing parameter]</nowiki>эну || фы<nowiki>[missing parameter]</nowiki>эну  || <nowiki>[missing parameter]</nowiki>эну(хэ) \n|-\n| къэкӀуэну гъэбелджыла зэман - щымыӀэныгъэ ||  сымы<nowiki>[missing parameter]</nowiki>эну || умы<nowiki>[missing parameter]</nowiki>эну || мы<nowiki>[missing parameter]</nowiki>эну || дымы<nowiki>[missing parameter]</nowiki>эну || фымы<nowiki>[missing parameter]</nowiki>эну  || мы<nowiki>[missing parameter]</nowiki>эну(хэ)\n|-\n! Лэжьыгъэм и къэхъукӀэр зыгъэбелджылы причастие !!  !!  !!  !!  !!  !! \n|-\n| ит зэман - щыӀэныгъэ ||  сызэрышэнауэ || узэрышэнауэ || зэрышэнауэ || дызэрышэнауэ || фызэрышэнауэ  || зэрышэнауэ(хэ) \n|-\n| ит зэман - щымыӀэныгъэ || сызэрымышэнауэ || узэрымышэнауэ || зэрымышэнауэ || дызэрымышэнауэ || фызэрымышэнауэ ||  мызэрышэнауэ(хэ)\n|-\n| блэкӀа зэфӀэкӀа зэман - щыӀэныгъэ ||  сызэры<nowiki>[missing parameter]</nowiki>а || узэры<nowiki>[missing parameter]</nowiki>а || зэры<nowiki>[missing parameter]</nowiki>а || дызэры<nowiki>[missing parameter]</nowiki>а || фызэры<nowiki>[missing parameter]</nowiki>а || зэры<nowiki>[missing parameter]</nowiki>а(хэ) \n|-\n| блэкӀа зэфӀэкӀа зэман - щымыӀэныгъэ ||  сызэрымы<nowiki>[missing parameter]</nowiki>а || узэрымы<nowiki>[missing parameter]</nowiki>а || зэрымы<nowiki>[missing parameter]</nowiki>а || дызэрымы<nowiki>[missing parameter]</nowiki>а || фызэрымы<nowiki>[missing parameter]</nowiki>а || зэрымы<nowiki>[missing parameter]</nowiki>а(хэ)  \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман - щыӀэныгъэ ||  сызэры<nowiki>[missing parameter]</nowiki>эгъа || узэры<nowiki>[missing parameter]</nowiki>эгъа || зэры<nowiki>[missing parameter]</nowiki>эгъа || дызэры<nowiki>[missing parameter]</nowiki>эгъа || фызэры<nowiki>[missing parameter]</nowiki>эгъа || зэры<nowiki>[missing parameter]</nowiki>эгъа(хэ) \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман - щымыӀэныгъэ ||  сызэрымы<nowiki>[missing parameter]</nowiki>эгъа || узэрымы<nowiki>[missing parameter]</nowiki>эгъа || зэрымы<nowiki>[missing parameter]</nowiki>эгъа || дызэрымы<nowiki>[missing parameter]</nowiki>эгъа || фызэрымы<nowiki>[missing parameter]</nowiki>эгъа || зэрымы<nowiki>[missing parameter]</nowiki>эгъа(хэ)  \n|-\n| къэкӀуэну мыгъэбелджыла зэман - щыӀэныгъэ ||  сызэры<nowiki>[missing parameter]</nowiki>эн || узэры<nowiki>[missing parameter]</nowiki>эн || зэры<nowiki>[missing parameter]</nowiki>эн || дызэры<nowiki>[missing parameter]</nowiki>эн || фызэры<nowiki>[missing parameter]</nowiki>эн  || зэры<nowiki>[missing parameter]</nowiki>эн(хэ) \n|-\n| къэкӀуэну гъэбелджыла зэман - щымыӀэныгъэ ||  сызэрымы<nowiki>[missing parameter]</nowiki>эн || узэрымы<nowiki>[missing parameter]</nowiki>эн || зэрымы<nowiki>[missing parameter]</nowiki>эн || дызэрымы<nowiki>[missing parameter]</nowiki>эн || фызэрымы<nowiki>[missing parameter]</nowiki>эн  || зэрымы<nowiki>[missing parameter]</nowiki>эн(хэ)\n|-\n| къэкӀуэну гъэбелджыла зэман - щыӀэныгъэ ||  сызэры<nowiki>[missing parameter]</nowiki>эну || узэры<nowiki>[missing parameter]</nowiki>эну || зэры<nowiki>[missing parameter]</nowiki>эну || дызэры<nowiki>[missing parameter]</nowiki>эну || фызэры<nowiki>[missing parameter]</nowiki>эну  || зэры<nowiki>[missing parameter]</nowiki>эну(хэ) \n|-\n| къэкӀуэну гъэбелджыла зэман - щымыӀэныгъэ ||  сызэрымы<nowiki>[missing parameter]</nowiki>эну || узэрымы<nowiki>[missing parameter]</nowiki>эну || зэрымы<nowiki>[missing parameter]</nowiki>эну || дызэрымы<nowiki>[missing parameter]</nowiki>эну || фызэрымы<nowiki>[missing parameter]</nowiki>эну  || зэрымы<nowiki>[missing parameter]</nowiki>эну(хэ)\n|-\n! Зэман/щӀыпӀэ зыгъэбелджылы причастие !!  !!  !!  !!  !!  !! \n|-\n| ит зэман - щыӀэныгъэ ||  сыщышэнауэ || ущышэнауэ || щышэнауэ || дыщышэнауэ || фыщышэнауэ  || щышэнауэ(хэ) \n|-\n| ит зэман - щымыӀэныгъэ || сыщымышэнауэ || ущымышэнауэ || щымышэнауэ || дыщымышэнауэ || фыщымышэнауэ ||  щымышэнауэ(хэ)\n|-\n| блэкӀа зэфӀэкӀа зэман - щыӀэныгъэ ||  сыщы<nowiki>[missing parameter]</nowiki>а || ущы<nowiki>[missing parameter]</nowiki>а || щы<nowiki>[missing parameter]</nowiki>а || дыщы<nowiki>[missing parameter]</nowiki>а || фыщы<nowiki>[missing parameter]</nowiki>а || щы<nowiki>[missing parameter]</nowiki>а(хэ) \n|-\n| блэкӀа зэфӀэкӀа зэман - щымыӀэныгъэ ||  сыщымы<nowiki>[missing parameter]</nowiki>а || ущымы<nowiki>[missing parameter]</nowiki>а || щымы<nowiki>[missing parameter]</nowiki>а || дыщымы<nowiki>[missing parameter]</nowiki>а || фыщымы<nowiki>[missing parameter]</nowiki>а || щымы<nowiki>[missing parameter]</nowiki>а(хэ)  \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман - щыӀэныгъэ ||  сыщы<nowiki>[missing parameter]</nowiki>эгъа || ущы<nowiki>[missing parameter]</nowiki>эгъа || щы<nowiki>[missing parameter]</nowiki>эгъа || дыщы<nowiki>[missing parameter]</nowiki>эгъа || фыщы<nowiki>[missing parameter]</nowiki>эгъа || щы<nowiki>[missing parameter]</nowiki>эгъа(хэ) \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман - щымыӀэныгъэ ||  сыщымы<nowiki>[missing parameter]</nowiki>эгъа || ущымы<nowiki>[missing parameter]</nowiki>эгъа || щымы<nowiki>[missing parameter]</nowiki>эгъа || дыщымы<nowiki>[missing parameter]</nowiki>эгъа || фыщымы<nowiki>[missing parameter]</nowiki>эгъа || щымы<nowiki>[missing parameter]</nowiki>эгъа(хэ)  \n|-\n| къэкӀуэну мыгъэбелджылы зэман - щыӀэныгъэ ||  сыщы<nowiki>[missing parameter]</nowiki>эн || ущы<nowiki>[missing parameter]</nowiki>эн || щы<nowiki>[missing parameter]</nowiki>эн || дыщы<nowiki>[missing parameter]</nowiki>эн || фыщы<nowiki>[missing parameter]</nowiki>эн  || щы<nowiki>[missing parameter]</nowiki>эн(хэ) \n|-\n| къэкӀуэну мыгъэбелджылы зэман - щымыӀэныгъэ ||  сыщымы<nowiki>[missing parameter]</nowiki>эн || ущымы<nowiki>[missing parameter]</nowiki>эн || щымы<nowiki>[missing parameter]</nowiki>эн || дыщымы<nowiki>[missing parameter]</nowiki>эн || фыщымы<nowiki>[missing parameter]</nowiki>эн  || щымы<nowiki>[missing parameter]</nowiki>эн(хэ)\n|-\n| къэкӀуэну гъэбелджылы зэман - щыӀэныгъэ ||  сыщы<nowiki>[missing parameter]</nowiki>эну || ущы<nowiki>[missing parameter]</nowiki>эну || щы<nowiki>[missing parameter]</nowiki>эну || дыщы<nowiki>[missing parameter]</nowiki>эну || фыщы<nowiki>[missing parameter]</nowiki>эну  || щы<nowiki>[missing parameter]</nowiki>эну(хэ) \n|-\n| къэкӀуэну гъэбелджылы зэман - щымыӀэныгъэ ||  сыщымы<nowiki>[missing parameter]</nowiki>эну || ущымы<nowiki>[missing parameter]</nowiki>эну || щымы<nowiki>[missing parameter]</nowiki>эну || дыщымы<nowiki>[missing parameter]</nowiki>эну || фыщымы<nowiki>[missing parameter]</nowiki>эну  || щымы<nowiki>[missing parameter]</nowiki>эну(хэ)\n|-\n! ЩӀыпӀэ зыгъэбелджылы причастие !!  !!  !!  !!  !!  !! \n|-\n| ит зэман - щыӀэныгъэ ||  сыздэшэнауэ || уздэшэнауэ || здэшэнауэ || дыздэшэнауэ || фыздэшэнауэ  || здэшэнауэ(хэ) \n|-\n| ит зэман - щымыӀэныгъэ || сыздэмышэнауэ || уздэмышэнауэ || здэмышэнауэ || дыздэмышэнауэ || фыздэмышэнауэ ||  здэмышэнауэ(хэ)\n|-\n| блэкӀа зэфӀэкӀа зэман - щыӀэныгъэ ||  сыздэ<nowiki>[missing parameter]</nowiki>а || уздэ<nowiki>[missing parameter]</nowiki>а || здэ<nowiki>[missing parameter]</nowiki>а || дыздэ<nowiki>[missing parameter]</nowiki>а || фыздэ<nowiki>[missing parameter]</nowiki>а || здэ<nowiki>[missing parameter]</nowiki>а(хэ) \n|-\n| блэкӀа зэфӀэкӀа зэман - щымыӀэныгъэ ||  сыздэмы<nowiki>[missing parameter]</nowiki>а || уздэмы<nowiki>[missing parameter]</nowiki>а || здэмы<nowiki>[missing parameter]</nowiki>а || дыздэмы<nowiki>[missing parameter]</nowiki>а || фыздэмы<nowiki>[missing parameter]</nowiki>а || здэмы<nowiki>[missing parameter]</nowiki>а(хэ)  \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман - щыӀэныгъэ ||  сыздэ<nowiki>[missing parameter]</nowiki>эгъа || уздэ<nowiki>[missing parameter]</nowiki>эгъа || здэ<nowiki>[missing parameter]</nowiki>эгъа || дыздэ<nowiki>[missing parameter]</nowiki>эгъа || фыздэ<nowiki>[missing parameter]</nowiki>эгъа || здэ<nowiki>[missing parameter]</nowiki>эгъа(хэ) \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман - щымыӀэныгъэ ||  сыздэмы<nowiki>[missing parameter]</nowiki>эгъа || уздэмы<nowiki>[missing parameter]</nowiki>эгъа || здэмы<nowiki>[missing parameter]</nowiki>эгъа || дыздэмы<nowiki>[missing parameter]</nowiki>эгъа || фыздэмы<nowiki>[missing parameter]</nowiki>эгъа || здэмы<nowiki>[missing parameter]</nowiki>эгъа(хэ)  \n|-\n| къэкӀуэну мыгъэбелджылы зэман - щыӀэныгъэ ||  сыздэ<nowiki>[missing parameter]</nowiki>эн || уздэ<nowiki>[missing parameter]</nowiki>эн || здэ<nowiki>[missing parameter]</nowiki>эн || дыздэ<nowiki>[missing parameter]</nowiki>эн || фыздэ<nowiki>[missing parameter]</nowiki>эн  || здэ<nowiki>[missing parameter]</nowiki>эн(хэ) \n|-\n| къэкӀуэну мыгъэбелджылы зэман - щымыӀэныгъэ ||  сыздэмы<nowiki>[missing parameter]</nowiki>эн || уздэмы<nowiki>[missing parameter]</nowiki>эн || здэмы<nowiki>[missing parameter]</nowiki>эн || дыздэмы<nowiki>[missing parameter]</nowiki>эн || фыздэмы<nowiki>[missing parameter]</nowiki>эн  || здэмы<nowiki>[missing parameter]</nowiki>эн(хэ)\n|-\n| къэкӀуэну гъэбелджылы зэман - щыӀэныгъэ ||  сыздэ<nowiki>[missing parameter]</nowiki>эну || уздэ<nowiki>[missing parameter]</nowiki>эну || здэ<nowiki>[missing parameter]</nowiki>эну || дыздэ<nowiki>[missing parameter]</nowiki>эну || фыздэ<nowiki>[missing parameter]</nowiki>эну  || здэ<nowiki>[missing parameter]</nowiki>эну(хэ) \n|-\n| къэкӀуэну гъэбелджылы зэман - щымыӀэныгъэ ||  сыздэмы<nowiki>[missing parameter]</nowiki>эну || уздэмы<nowiki>[missing parameter]</nowiki>эну || здэмы<nowiki>[missing parameter]</nowiki>эну || дыздэмы<nowiki>[missing parameter]</nowiki>эну || фыздэмы<nowiki>[missing parameter]</nowiki>эну  || здэмы<nowiki>[missing parameter]</nowiki>эну(хэ)\n|-\n! Щхьэусыгъуэ, мурад зыгъэбелджылы причастие !!  !!  !!  !!  !!  !! \n|-\n| ит зэман - щыӀэныгъэ ||  сыщӀэшэнауэ || ущӀэшэнауэ || щӀэшэнауэ || дыщӀэшэнауэ || фыщӀэшэнауэ  || щӀэшэнауэ(хэ) \n|-\n| ит зэман - щымыӀэныгъэ || сыщӀэмышэнауэ || ущӀэмышэнауэ || щӀэмышэнауэ || дыщӀэмышэнауэ || фыщӀэмышэнауэ ||  щӀэмышэнауэ(хэ)\n|-\n| блэкӀа зэфӀэкӀа зэман - щыӀэныгъэ ||  сыщӀэ<nowiki>[missing parameter]</nowiki>а || ущӀэ<nowiki>[missing parameter]</nowiki>а || щӀэ<nowiki>[missing parameter]</nowiki>а || дыщӀэ<nowiki>[missing parameter]</nowiki>а || фыщӀэ<nowiki>[missing parameter]</nowiki>а || щӀэ<nowiki>[missing parameter]</nowiki>а(хэ) \n|-\n| блэкӀа зэфӀэкӀа зэман - щымыӀэныгъэ ||  сыщӀэмы<nowiki>[missing parameter]</nowiki>а || ущӀэмы<nowiki>[missing parameter]</nowiki>а || щӀэмы<nowiki>[missing parameter]</nowiki>а || дыщӀэмы<nowiki>[missing parameter]</nowiki>а || фыщӀэмы<nowiki>[missing parameter]</nowiki>а || щӀэмы<nowiki>[missing parameter]</nowiki>а(хэ)  \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман - щыӀэныгъэ ||  сыщӀэ<nowiki>[missing parameter]</nowiki>эгъа || ущӀэ<nowiki>[missing parameter]</nowiki>эгъа || щӀэ<nowiki>[missing parameter]</nowiki>эгъа || дыщӀэ<nowiki>[missing parameter]</nowiki>эгъа || фыщӀэ<nowiki>[missing parameter]</nowiki>эгъа || щӀэ<nowiki>[missing parameter]</nowiki>эгъа(хэ) \n|-\n| блэкӀа жыжьэ зэфӀэкӀа зэман - щымыӀэныгъэ ||  сыщӀэмы<nowiki>[missing parameter]</nowiki>эгъа || ущӀэмы<nowiki>[missing parameter]</nowiki>эгъа || щӀэмы<nowiki>[missing parameter]</nowiki>эгъа || дыщӀэмы<nowiki>[missing parameter]</nowiki>эгъа || фыщӀэмы<nowiki>[missing parameter]</nowiki>эгъа || щӀэмы<nowiki>[missing parameter]</nowiki>эгъа(хэ)  \n|-\n| къэкӀуэну мыгъэбелджылы зэман - щыӀэныгъэ ||  сыщӀэ<nowiki>[missing parameter]</nowiki>эн || ущӀэ<nowiki>[missing parameter]</nowiki>эн || щӀэ<nowiki>[missing parameter]</nowiki>эн || дыщӀэ<nowiki>[missing parameter]</nowiki>эн || фыщӀэ<nowiki>[missing parameter]</nowiki>эн  || щӀэ<nowiki>[missing parameter]</nowiki>эн(хэ) \n|-\n| къэкӀуэну мыгъэбелджылы зэман - щымыӀэныгъэ ||  сыщӀэмы<nowiki>[missing parameter]</nowiki>эн || ущӀэмы<nowiki>[missing parameter]</nowiki>эн || щӀэмы<nowiki>[missing parameter]</nowiki>эн || дыщӀэмы<nowiki>[missing parameter]</nowiki>эн || фыщӀэмы<nowiki>[missing parameter]</nowiki>эн  || щӀэмы<nowiki>[missing parameter]</nowiki>эн(хэ)\n|-\n| къэкӀуэну гъэбелджылы зэман - щыӀэныгъэ ||  сыщӀэ<nowiki>[missing parameter]</nowiki>эну || ущӀэ<nowiki>[missing parameter]</nowiki>эну || щӀэ<nowiki>[missing parameter]</nowiki>эну || дыщӀэ<nowiki>[missing parameter]</nowiki>эну || фыщӀэ<nowiki>[missing parameter]</nowiki>эну  || щӀэ<nowiki>[missing parameter]</nowiki>эну(хэ) \n|-\n| къэкӀуэну гъэбелджылы зэман - щымыӀэныгъэ ||  сыщӀэмы<nowiki>[missing parameter]</nowiki>эну || ущӀэмы<nowiki>[missing parameter]</nowiki>эну || щӀэмы<nowiki>[missing parameter]</nowiki>эну || дыщӀэмы<nowiki>[missing parameter]</nowiki>эну || фыщӀэмы<nowiki>[missing parameter]</nowiki>эну  || щӀэмы<nowiki>[missing parameter]</nowiki>эну(хэ)\n|}\n\n{| class=\"wikitable\"\n|-\n! Деепричастиехэр !! сэ  !! уэ !! ар !! дэ !! фэ !! ахэр\n|-\n| ит зэман - щыӀэныгъэ ||  сышэнауэу || ушэнауэу || шэнауэу || дышэнауэу || фышэнауэу || шэнауэ(хэ)у\n|-\n| ит зэман - щымыӀэныгъэ ||  сымышэнауэу || умышэнауэу || мышэнауэу || дымышэнауэу || фымышэнауэу || мышэнауэ(хэ)у\n|-\n| блэкӀа зэман - щыӀэныгъэ ||  сы<nowiki>[missing parameter]</nowiki>ауэ || у<nowiki>[missing parameter]</nowiki>ауэ || <nowiki>[missing parameter]</nowiki>ауэ || ды<nowiki>[missing parameter]</nowiki>ауэ || фы<nowiki>[missing parameter]</nowiki>ауэ || <nowiki>[missing parameter]</nowiki>ауэ / <nowiki>[missing parameter]</nowiki>а(хэ)у\n|-\n| блэкӀа зэман - щымыӀэныгъэ ||  сымы<nowiki>[missing parameter]</nowiki>ауэ || умы<nowiki>[missing parameter]</nowiki>ауэ || мы<nowiki>[missing parameter]</nowiki>ауэ || дымы<nowiki>[missing parameter]</nowiki>ауэ || фымы<nowiki>[missing parameter]</nowiki>ауэ || мы<nowiki>[missing parameter]</nowiki>ауэ(хэ) / мы<nowiki>[missing parameter]</nowiki>а(хэ)у\n|-\n| -урэ-кӀэ деепричастие - щыӀэныгъэ ||  сышэнауэурэ || ушэнауэурэ || шэнауэурэ || дышэнауэурэ || фышэнауэурэ || шэнауэ(хэ)урэ \n|-\n| -урэ-кӀэ деепричастие - щымыӀэныгъэ ||  сымышэнауэурэ || умышэнауэурэ || мышэнауэурэ || дымышэнауэурэ || фымышэнауэурэ || мышэнауэ(хэ)урэ\n|}\n\n{| class=\"wikitable\"\n|-\n! !!  !! -э-кӀэ цӀэ склоненэм и фащэхэр !!  !! \n|-\n! !! Закъуэ бжьыгъэ  !! !! Куэд бжьыгъэ  !! \n|-\n| || '''Мыбелджылы''' || '''Белджылы''' || '''Мыбелджылы''' || '''Белджылы'''\n|-\n| '''Именительнэ:''' || [шэнау]э || [шэнау]эр || -- || [шэнау]эхэр\n|-\n| '''Эргативнэ:''' || [шэнау]э || [шэнау]эм || --  || [шэнау]эхэм\n|-\n| '''Послеложнэ:''' || [шэнау]экӀэ || [шэнау]эмкӀэ || [шэнау]эхэкӀэ || [шэнау]эхэмкӀэ\n|-\n| '''Обстоятельственнэ:''' || [шэнау]эуэ || [шэнау]эрауэ || [шэнау]эхэу || [шэнау]эхэрауэ\n|}\n\n{| class=\"wikitable\"\n|-\n! !!  !! -а-кӀэ цӀэ склоненэм и фащэхэр !!  !! \n|-\n! !! Закъуэ бжьыгъэ  !! !! Куэд бжьыгъэ  !! \n|-\n| || '''Мыбелджылы''' || '''Белджылы''' || '''Мыбелджылы''' || '''Белджылы'''\n|-\n| '''Именительнэ:''' || [<nowiki> [missing parameter] </nowiki>]а || [<nowiki> [missing parameter] </nowiki>]ар || -- || [<nowiki> [missing parameter] </nowiki>]ахэр\n|-\n| '''Эргативнэ:''' || [<nowiki> [missing parameter] </nowiki>]а || [<nowiki> [missing parameter] </nowiki>]ам || --  || [<nowiki> [missing parameter] </nowiki>]ахэм\n|-\n| '''Послеложнэ:''' || [<nowiki> [missing parameter] </nowiki>]акӀэ || [<nowiki> [missing parameter] </nowiki>]амкӀэ || [<nowiki> [missing parameter] </nowiki>]ахэкӀэ || [<nowiki> [missing parameter] </nowiki>]ахэмкӀэ\n|-\n| '''Обстоятельственнэ:''' || [<nowiki> [missing parameter] </nowiki>]ауэ || [<nowiki> [missing parameter] </nowiki>]арауэ || [<nowiki> [missing parameter] </nowiki>]ахэу || [<nowiki> [missing parameter] </nowiki>]ахэрауэ\n|}\n\n{| class=\"wikitable\"\n|-\n! !!  !! -эн-кӀэ цӀэ склоненэм и фащэхэр !!  !! \n|-\n! !! Закъуэ бжьыгъэ  !! !! Куэд бжьыгъэ  !! \n|-\n| || '''Мыбелджылы''' || '''Белджылы''' || '''Мыбелджылы''' || '''Белджылы'''\n|-\n| '''Именительнэ:''' || [<nowiki> [missing parameter] </nowiki>]эн || [<nowiki> [missing parameter] </nowiki>]эныр || -- || [<nowiki> [missing parameter] </nowiki>]энхэр\n|-\n| '''Эргативнэ:''' || [<nowiki> [missing parameter] </nowiki>]эн || [<nowiki> [missing parameter] </nowiki>]эным || --  || [<nowiki> [missing parameter] </nowiki>]энхэм\n|-\n| '''Послеложнэ:''' || [<nowiki> [missing parameter] </nowiki>]энкӀэ || [<nowiki> [missing parameter] </nowiki>]энымкӀэ || [<nowiki> [missing parameter] </nowiki>]энхэкӀэ || [<nowiki> [missing parameter] </nowiki>]энхэмкӀэ\n|-\n| '''Обстоятельственнэ:'' || [<nowiki> [missing parameter] </nowiki>]эну || [<nowiki> [missing parameter] </nowiki>]энырауэ || [<nowiki> [missing parameter] </nowiki>]энхэу || [<nowiki> [missing parameter] </nowiki>]энхэрауэ\n|}\n\n{| class=\"wikitable\"\n|-\n! !!  !!  -эну-кӀэ цӀэ склоненэм и фащэхэр !!  !! \n|-\n! !! Закъуэ бжьыгъэ  !! !! Куэд бжьыгъэ  !! \n|-\n| || '''Мыбелджылы''' || '''Белджылы''' || '''Мыбелджылы''' || '''Белджылы'''\n|-\n| '''Именительнэ:''' || [<nowiki> [missing parameter] </nowiki>]эну || [<nowiki> [missing parameter] </nowiki>]энур || -- || [<nowiki> [missing parameter] </nowiki>]энухэр\n|-\n| '''Эргативнэ:''' || [<nowiki> [missing parameter] </nowiki>]эну || [<nowiki> [missing parameter] </nowiki>]энум || --  || [<nowiki> [missing parameter] </nowiki>]энухэм\n|-\n| '''Послеложнэ:''' || [<nowiki> [missing parameter] </nowiki>]энукӀэ || [<nowiki> [missing parameter] </nowiki>]энумкӀэ || [<nowiki> [missing parameter] </nowiki>]энухэкӀэ || [<nowiki> [missing parameter] </nowiki>]энухэмкӀэ\n|-\n| '''Обстоятельственнэ:''' || [<nowiki> [missing parameter] </nowiki>]энууэ || [<nowiki> [missing parameter] </nowiki>]энурауэ || [<nowiki> [missing parameter] </nowiki>]энухэу || [<nowiki> [missing parameter] </nowiki>]энухэрауэ\n|}\n";
    try std.testing.expectEqual(@as(usize, 58938), source.len);
    var report: Fallbacks = .{};
    const bytes = try compileReportedAlloc(a, title, .language, "Unclassified", "", source, null, &report);
    const expected = try compileAlloc(a, title, .language, "Unclassified", "", reference, null);
    try std.testing.expectEqualSlices(u8, expected, bytes);
    const stored = try codec.decodeAlloc(a, bytes, title, .language, .{ .code = "", .heading = "Unclassified" });
    try std.testing.expectEqualSlices(u8, bytes, try codec.encodeAlloc(a, stored));
    try std.testing.expect(report.missing_template);
    try std.testing.expectEqual(@as(usize, 1), stored.entry.sections.len);
    try std.testing.expectEqualStrings("Глагол лъэмыӏэс \"щэнэуэн\"-ым и спряженэр", stored.entry.sections[0].title);
    try std.testing.expectEqual(@as(usize, 0), stored.entry.references.len);
    try std.testing.expectEqual(@as(usize, 0), stored.entry.media.len);
    const expected_rows = [_]usize{ 3, 3, 3, 3, 21, 21, 11, 11, 5, 11, 11, 3, 3, 17, 56, 7, 7, 7, 7, 7 };
    const expected_columns = [_]usize{ 2, 7, 3, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 5, 5, 5, 5 };
    var tables: usize = 0;
    var cells: usize = 0;
    var headers: usize = 0;
    var markers: usize = 0;
    var wrappers: usize = 0;
    var authored_brackets: usize = 0;
    for (stored.entry.sections) |section| for (section.blocks) |block| if (block.table) |table| {
        try std.testing.expect(tables < expected_rows.len);
        try std.testing.expectEqual(expected_rows[tables], table.rows.len);
        for (table.rows) |row| {
            try std.testing.expectEqual(expected_columns[tables], row.cells.len);
            for (row.cells) |cell| {
                cells += 1;
                headers += @intFromBool(cell.header);
                try std.testing.expect(cell.blocks == null and cell.nested_table == null);
                var text: std.ArrayList(u8) = .empty;
                for (cell.spans) |span| {
                    try std.testing.expect(span.kind == .text and span.target.len == 0);
                    try text.appendSlice(a, span.text);
                }
                markers += std.mem.count(u8, text.items, "[missing parameter]");
                wrappers += std.mem.count(u8, text.items, "[ [missing parameter] ]");
                authored_brackets += std.mem.count(u8, text.items, "[шэнау]");
                try std.testing.expect(std.mem.indexOf(u8, text.items, "{{{") == null);
                try std.testing.expect(std.mem.indexOf(u8, text.items, "[[") == null);
            }
        }
        tables += 1;
    };
    try std.testing.expectEqual(@as(usize, 20), tables);
    try std.testing.expectEqual(@as(usize, 1436), cells);
    try std.testing.expectEqual(@as(usize, 178), headers);
    try std.testing.expectEqual(@as(usize, 791), markers);
    try std.testing.expectEqual(@as(usize, 42), wrappers);
    try std.testing.expectEqual(@as(usize, 14), authored_brackets);
    // No source-provenance exemption is added to document validation.
    const unproved = [_]compiler.Span{ .{ .text = "[" }, .{ .text = "[missing parameter]" }, .{ .text = "]" } };
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &unproved, null));
    try std.testing.expectError(error.UncompiledTemplate, compileAlloc(a, "entry", .language, "English", "en", "[{{{stem}}}]", null));
    const target = [_]compiler.Span{.{ .kind = .link, .text = "diagnostic", .target = "{{deferred}}", .generated_diagnostic = true }};
    try std.testing.expectError(error.UncompiledTemplate, validateSpans(a, &target, null));
}

// Append only to presentation_document.zig in the selected private candidate.
// Scoped raw-text/Reader-field regression, not a full saved-page expansion.
// Full UG02 Reader output remains the independent complete-body baseline.
test "UG exact noun classification preserves scoped body actions and codec under explicit owners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = "بىرەر كىشى ياكى نەرسىگە يېتىدىغان مەنپەئەت، نەپ";
    const quote = "قىلىدىغان ئىش بولمىسا، ئۆيگە بېرىپ ئۆز ئىشىمىزنى قىلساق شۇ پايدا ئەمەسمۇ؟";
    const second = "‹س ئىقتىساد› ئىشلەپچىقرىش، سودا-سېتىق ۋە تۈرلۈك تىجارەت يوللىرى ئارقىلىق كىرگۈزگەن كىرىمىدىن، تەننەرخى ياكى دەسمايىنى ۋە باجنى چىقىرىۋەتكەندىن كېيىنكى ئاشقان سومما، نەپ.";
    // Explicit entity literal exercises the observed visible IPA. This does not
    // reconstruct the unavailable current full expanded template output.
    const tail = "'''پايدا''' / &lt;pɑyɗɑ&gt; /\n# " ++ first ++ "\n#* " ++ quote ++ "\n# " ++ second ++ "\n==== مەنىداش سۆزلەر ====\n* [[نەپ]]، [[مەنپەئەت]]\n==== قارشى مەنىلىك سۆزلەر ====\n* [[زىيان]]، [[زەرەر]]\n";
    const source = "=== ئومۇمىي ئىسىم ===\n" ++ tail;
    const canonical = "=== Noun ===\n" ++ tail;
    const Owner = struct { heading: []const u8, code: []const u8 };
    for ([_]Owner{
        .{ .heading = "ئۇيغۇرچە / Uyghurche", .code = "ug" },
        .{ .heading = "English", .code = "en" },
    }) |owner| {
        // Authority is supplied explicitly by this scoped control, independently
        // of the localized POS label. No language alias or inference is tested.
        const bytes = try compileClassifiedWithHeadingAnchorsAlloc(a, "پايدا", .language, owner.heading, owner.code, MissingText.untracked(source), null, .{}, null, null, null, .{}, null, null, &.{}, null, &.{}, .{ .heading = owner.heading, .code = owner.code });
        const reference = try compileClassifiedWithHeadingAnchorsAlloc(a, "پايدا", .language, owner.heading, owner.code, MissingText.untracked(canonical), null, .{}, null, null, null, .{}, null, null, &.{}, null, &.{}, .{ .heading = owner.heading, .code = owner.code });
        const stored = try codec.decodeAlloc(a, bytes, "پايدا", .language, .{ .code = owner.code, .heading = owner.heading });
        const expected = try codec.decodeAlloc(a, reference, "پايدا", .language, .{ .code = owner.code, .heading = owner.heading });
        try std.testing.expectEqualStrings(owner.heading, stored.entry.language.?);
        try std.testing.expectEqualStrings(owner.code, stored.entry.language_code);
        try std.testing.expectEqual(@as(usize, 3), stored.entry.sections.len);
        try std.testing.expectEqualStrings("ئومۇمىي ئىسىم", stored.entry.sections[0].title);
        try std.testing.expectEqualDeep(expected.entry.organization, stored.entry.organization);
        for (expected.entry.sections, stored.entry.sections) |before, after|
            try std.testing.expectEqualDeep(before.blocks, after.blocks);
        try std.testing.expectEqualDeep(expected.entry.display_title, stored.entry.display_title);
        try std.testing.expectEqualDeep(expected.entry.references, stored.entry.references);
        try std.testing.expectEqualDeep(expected.entry.media, stored.entry.media);
        try std.testing.expectEqual(@as(usize, 1), stored.entry.organization.lexemes.len);
        const noun = stored.entry.organization.lexemes[0];
        try std.testing.expectEqualStrings("Noun", noun.kind);
        try std.testing.expectEqualStrings(owner.heading, noun.language);
        try std.testing.expectEqual(@as(usize, 0), noun.section);
        try std.testing.expectEqual(@as(usize, 2), noun.definitions.len);
        try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, noun.related_sections);
        const blocks = stored.entry.sections[noun.section].blocks;
        try std.testing.expectEqual(@as(usize, 1), noun.definitions[0].block);
        try std.testing.expectEqual(@as(usize, 3), noun.definitions[1].block);
        try std.testing.expectEqualSlices(usize, &.{2}, noun.definitions[0].quotations);
        try std.testing.expectEqual(@as(usize, 0), noun.definitions[1].quotations.len);
        try std.testing.expectEqualStrings(first, blocks[1].spans[0].text);
        try std.testing.expectEqualStrings(quote, blocks[2].spans[0].text);
        try std.testing.expectEqualStrings(second, blocks[3].spans[0].text);
        try std.testing.expect(blocks[2].kind == .quotation and blocks[2].depth == 2);
        try std.testing.expectEqualStrings("#*", blocks[2].list_path);
        for (noun.definitions) |sense| {
            try std.testing.expect(sense.parent == null and sense.form == null);
            try std.testing.expectEqualStrings("#", blocks[sense.block].list_path);
        }
        var headword = false;
        var intro: std.ArrayList(u8) = .empty;
        for (blocks[0].spans) |span| {
            try intro.appendSlice(a, span.text);
            if (std.mem.eql(u8, span.text, "پايدا")) headword = span.bold;
        }
        try std.testing.expect(headword);
        try std.testing.expectEqualStrings("پايدا / <pɑyɗɑ> /", intro.items);
        const targets = [_][]const u8{ "نەپ", "مەنپەئەت", "زىيان", "زەرەر" };
        var links: usize = 0;
        for (stored.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            if (span.kind == .link) {
                try std.testing.expect(links < targets.len);
                try std.testing.expectEqualStrings(targets[links], span.text);
                try std.testing.expectEqualStrings(targets[links], span.target);
                links += 1;
            }
        };
        try std.testing.expectEqual(@as(usize, 4), links);
        try std.testing.expectEqualSlices(u8, bytes, try codec.encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media));
    }
}

// Append only to presentation_document.zig in the selected private candidate.
// Authored scoped body from raw p22/r356746 and observed AST04 Reader fields.
// Omits template-generated headings, subject labels, translation grids and media.
// Full published-page Reader evidence remains separate and is not reconstructed.
test "AST exact noun classification preserves three senses source actions styles and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = "Órganu muscular carnosu y móvil, asitiáu nel interior de la boca, que pertime percibir el sentíu del gustu y d'articular dellos soníos.";
    const second = "Sistema de comunicación que consiste en facer usu de soníos y/o xestos pa espresar pensamientos y sentimientos.";
    const third = "Sistema de comunicación oral y natural propiu a una determinada comunidá o grupu humanos.";
    const origin = "=== Etimoloxía ===\n* Del ''[[lingua]]'', de mesmu significáu.\n";
    const tail = "''femenín singular'' '''llingua'''; ''plural'' '''[[llingües]]'''\n# Órganu muscular carnosu y móvil, asitiáu nel interior de la [[boca]], que pertime percibir el [[sentíu]] del [[gustu]] y d'articular dellos [[soníu|soníos]].\n# " ++ second ++ "\n# " ++ third ++ "\n=== Sinónimos ===\n* [[parpayuela]]\n* [[llinguaxe]] ~ [[llinguax]]\n* [[idioma]]\n";
    const source = origin ++ "== Sustantivu ==\n" ++ tail;
    const canonical = origin ++ "== Noun ==\n" ++ tail;
    const Owner = struct { heading: []const u8, code: []const u8 };
    const Text = struct {
        fn join(allocator: A, spans: anytype) ![]const u8 {
            var out: std.ArrayList(u8) = .empty;
            for (spans) |span| try out.appendSlice(allocator, span.text);
            return out.toOwnedSlice(allocator);
        }
    };
    for ([_]Owner{ .{ .heading = "asturianu", .code = "ast" }, .{ .heading = "English", .code = "en" } }) |owner| {
        const bytes = try compileClassifiedWithHeadingAnchorsAlloc(a, "llingua", .language, owner.heading, owner.code, MissingText.untracked(source), null, .{}, null, null, null, .{}, null, null, &.{}, null, &.{}, .{ .heading = owner.heading, .code = owner.code });
        const reference = try compileClassifiedWithHeadingAnchorsAlloc(a, "llingua", .language, owner.heading, owner.code, MissingText.untracked(canonical), null, .{}, null, null, null, .{}, null, null, &.{}, null, &.{}, .{ .heading = owner.heading, .code = owner.code });
        const stored = try codec.decodeAlloc(a, bytes, "llingua", .language, .{ .code = owner.code, .heading = owner.heading });
        const expected = try codec.decodeAlloc(a, reference, "llingua", .language, .{ .code = owner.code, .heading = owner.heading });
        try std.testing.expectEqualStrings(owner.heading, stored.entry.language.?);
        try std.testing.expectEqualStrings(owner.code, stored.entry.language_code);
        try std.testing.expectEqual(@as(usize, 3), stored.entry.sections.len);
        try std.testing.expectEqualStrings("Sustantivu", stored.entry.sections[1].title);
        try std.testing.expectEqualDeep(expected.entry.organization, stored.entry.organization);
        for (expected.entry.sections, stored.entry.sections) |before, after|
            try std.testing.expectEqualDeep(before.blocks, after.blocks);
        try std.testing.expectEqualDeep(expected.entry.display_title, stored.entry.display_title);
        try std.testing.expectEqualDeep(expected.entry.references, stored.entry.references);
        try std.testing.expectEqualDeep(expected.entry.media, stored.entry.media);
        try std.testing.expectEqual(@as(usize, 1), stored.entry.organization.lexemes.len);
        const noun = stored.entry.organization.lexemes[0];
        try std.testing.expectEqualStrings("Noun", noun.kind);
        try std.testing.expectEqualStrings(owner.heading, noun.language);
        try std.testing.expectEqual(@as(usize, 1), noun.section);
        try std.testing.expectEqualSlices(usize, &.{0}, noun.introduction);
        try std.testing.expectEqualSlices(usize, &.{2}, noun.related_sections);
        try std.testing.expectEqualSlices(usize, &.{0}, stored.entry.organization.other_sections);
        try std.testing.expectEqual(@as(usize, 3), noun.definitions.len);
        const blocks = stored.entry.sections[noun.section].blocks;
        for (noun.definitions, 0..) |sense, i| {
            try std.testing.expectEqual(i + 1, sense.block);
            try std.testing.expect(sense.parent == null and sense.form == null);
            try std.testing.expectEqual(@as(usize, 0), sense.quotations.len);
            try std.testing.expectEqualStrings("#", blocks[sense.block].list_path);
        }
        try std.testing.expectEqualStrings(first, try Text.join(a, blocks[1].spans));
        try std.testing.expectEqualStrings(second, try Text.join(a, blocks[2].spans));
        try std.testing.expectEqualStrings(third, try Text.join(a, blocks[3].spans));
        const targets = [_][]const u8{ "boca", "sentíu", "gustu", "soníu" };
        const labels = [_][]const u8{ "boca", "sentíu", "gustu", "soníos" };
        var links: usize = 0;
        for (blocks[1].spans) |span| if (span.kind == .link) {
            try std.testing.expect(links < targets.len);
            try std.testing.expectEqualStrings(targets[links], span.target);
            try std.testing.expectEqualStrings(labels[links], span.text);
            links += 1;
        };
        try std.testing.expectEqual(@as(usize, 4), links);
        var headword = false;
        var plural = false;
        for (blocks[0].spans) |span| {
            if (std.mem.eql(u8, span.text, "llingua")) headword = span.bold;
            if (span.kind == .link and std.mem.eql(u8, span.target, "llingües")) {
                try std.testing.expectEqualStrings("llingües", span.text);
                plural = span.bold;
            }
        }
        try std.testing.expect(headword and plural);
        var etymology_link = false;
        for (stored.entry.sections[0].blocks[0].spans) |span| if (span.kind == .link and std.mem.eql(u8, span.target, "lingua")) {
            try std.testing.expectEqualStrings("lingua", span.text);
            etymology_link = span.italic;
        };
        try std.testing.expect(etymology_link);
        const synonym_targets = [_][]const u8{ "parpayuela", "llinguaxe", "llinguax", "idioma" };
        var synonyms: usize = 0;
        for (stored.entry.sections[2].blocks) |block| for (block.spans) |span| if (span.kind == .link) {
            try std.testing.expect(synonyms < synonym_targets.len);
            try std.testing.expectEqualStrings(synonym_targets[synonyms], span.target);
            try std.testing.expectEqualStrings(synonym_targets[synonyms], span.text);
            synonyms += 1;
        };
        try std.testing.expectEqual(@as(usize, 4), synonyms);
        try std.testing.expectEqualSlices(u8, bytes, try codec.encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media));
    }
}

test "scope collection and fragment replay preserve explicit numeric identity cancellation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Fragment scope observations own multiline body spans, not single-line inline spans.
    const source = "<span style=\"font-size:125%\"><span style=\"font-size:80%\">cancel\n</span>parent</span>outside";
    const observation = try observePreScopesAlloc(a, "entry", source, .{}, null, null, null, .{}, null);
    try std.testing.expectEqual(@as(usize, 2), observation.scopes.len);
    const outer = observation.scopes[0];
    const inner = observation.scopes[1];
    try std.testing.expectEqual(@as(?f32, 1.25), outer.attributes.font_scale);
    try std.testing.expect(outer.attributes.font_scale_set);
    // null alone is ambiguous: the explicit bit must survive Collector copying
    // to stop the replay inheriting 125% again after 125% * 80% cancels to 1.
    try std.testing.expect(inner.attributes.font_scale == null and inner.attributes.font_scale_set);
    const cut = std.mem.indexOf(u8, source, "cancel") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(cut, inner.body_start);
    const initial = [_]FragmentPreContext.Initial{
        .{ .body_end = inner.body_end - cut, .resume_at = inner.resume_at - cut, .kind = inner.kind, .formatting = inner.formatting, .attributes = inner.attributes },
        .{ .body_end = outer.body_end - cut, .resume_at = outer.resume_at - cut, .kind = outer.kind, .formatting = outer.formatting, .attributes = outer.attributes },
    };
    var renderer: compiler.Renderer = .{ .a = a, .context = .{} };
    const blocks = try renderer.renderBodyWithFragmentPre(source[cut..], .{ .initial = &initial });
    var seen: usize = 0;
    for (blocks) |block| for (block.spans) |span| {
        if (std.mem.indexOf(u8, span.text, "cancel") != null) {
            try std.testing.expect(span.font_scale == null and span.font_scale_set);
            seen += 1;
        }
        if (std.mem.indexOf(u8, span.text, "parent") != null) {
            try std.testing.expectEqual(@as(?f32, 1.25), span.font_scale);
            seen += 1;
        }
        if (std.mem.indexOf(u8, span.text, "outside") != null) {
            try std.testing.expect(span.font_scale == null);
            seen += 1;
        }
    };
    try std.testing.expectEqual(@as(usize, 3), seen);
    try std.testing.expect(!renderer.fallbacks.unclosed_formatting and !renderer.fallbacks.render_limit);

    // The other fragment edge must admit the same observed SPAN scopes too.
    const trailing = [_]FragmentPreContext.Trailing{
        .{ .opening_start = outer.opening_start, .body_start = outer.body_start, .kind = outer.kind, .formatting = outer.formatting, .attributes = outer.attributes },
        .{ .opening_start = inner.opening_start, .body_start = inner.body_start, .kind = inner.kind, .formatting = inner.formatting, .attributes = inner.attributes },
    };
    var prefix_renderer: compiler.Renderer = .{ .a = a, .context = .{} };
    const prefix = try prefix_renderer.renderBodyWithFragmentPre(source[0..inner.body_end], .{ .trailing = &trailing });
    var prefix_seen: usize = 0;
    for (prefix) |block| for (block.spans) |span| if (std.mem.indexOf(u8, span.text, "cancel") != null) {
        try std.testing.expect(span.font_scale == null and span.font_scale_set);
        prefix_seen += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), prefix_seen);
    try std.testing.expect(!prefix_renderer.fallbacks.unclosed_formatting and !prefix_renderer.fallbacks.render_limit);

    // A non-leading multiline inclusion wrapper uses the same observed kind.
    const inclusion_source = "prefix<noinclude>inner\n</noinclude>outside";
    const inclusion = try observePreScopesAlloc(a, "entry", inclusion_source, .{}, null, null, null, .{}, null);
    try std.testing.expectEqual(@as(usize, 1), inclusion.scopes.len);
    const wrapper = inclusion.scopes[0];
    try std.testing.expectEqual(FragmentPreContext.Kind.formatting, wrapper.kind);
    const inclusion_initial = [_]FragmentPreContext.Initial{.{ .body_end = wrapper.body_end - wrapper.body_start, .resume_at = wrapper.resume_at - wrapper.body_start, .kind = wrapper.kind, .formatting = wrapper.formatting, .attributes = wrapper.attributes }};
    var inclusion_suffix: compiler.Renderer = .{ .a = a, .context = .{} };
    const suffix_blocks = try inclusion_suffix.renderBodyWithFragmentPre(inclusion_source[wrapper.body_start..], .{ .initial = &inclusion_initial });
    var suffix_words: usize = 0;
    for (suffix_blocks) |block| for (block.spans) |span| {
        if (std.mem.indexOf(u8, span.text, "inner") != null) suffix_words += 1;
        if (std.mem.indexOf(u8, span.text, "outside") != null) suffix_words += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), suffix_words);
    try std.testing.expect(!inclusion_suffix.fallbacks.unclosed_formatting and !inclusion_suffix.fallbacks.render_limit);
    const inclusion_trailing = [_]FragmentPreContext.Trailing{.{ .opening_start = wrapper.opening_start, .body_start = wrapper.body_start, .kind = wrapper.kind, .formatting = wrapper.formatting, .attributes = wrapper.attributes }};
    var inclusion_prefix: compiler.Renderer = .{ .a = a, .context = .{} };
    const prefix_blocks = try inclusion_prefix.renderBodyWithFragmentPre(inclusion_source[0..wrapper.body_end], .{ .trailing = &inclusion_trailing });
    var prefix_words: usize = 0;
    for (prefix_blocks) |block| for (block.spans) |span| {
        if (std.mem.indexOf(u8, span.text, "prefix") != null) prefix_words += 1;
        if (std.mem.indexOf(u8, span.text, "inner") != null) prefix_words += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), prefix_words);
    try std.testing.expect(!inclusion_prefix.fallbacks.unclosed_formatting and !inclusion_prefix.fallbacks.render_limit);

    // A non-formatting DIV cannot be forged into this narrow formatting kind.
    var rejected: compiler.Renderer = .{ .a = a, .context = .{} };
    const bad_initial = [_]FragmentPreContext.Initial{.{ .body_end = 1, .resume_at = 7, .kind = .formatting }};
    try std.testing.expectError(error.InvalidPreContext, rejected.renderBodyWithFragmentPre("x</div>", .{ .initial = &bad_initial }));
    const bad_trailing = [_]FragmentPreContext.Trailing{.{ .opening_start = 0, .body_start = 5, .kind = .formatting }};
    try std.testing.expectError(error.InvalidPreContext, rejected.renderBodyWithFragmentPre("<div>x", .{ .trailing = &bad_trailing }));

}

test "complete retained OC nicard reference angles preserve full body actions and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Complete authenticated p14558/r350147 expanded page, 3258 bytes.
    const source = "<h1 style=\"clear: both; font-family: sans-serif; font-weight: bold; font-size: 1.3em; line-height: 1.3em; padding: 0.5em; background-color: #F7EED6; color:#000; border-top: 1px solid #AAA; border-bottom: 1px solid #AAA;\">[[occitan|Occitan]]</h1>[[Categoria:occitan]]\n\n<h3 style=\"border-bottom: 1px #AAA dotted;\" title=\"Entre-senhas fonologicas sul mot : niçard\"> [[prononciacion|Prononciacion]]  </h3>\n<nowiki>/</nowiki><span class=\"pron-AFI-SAMPA\"><span lang=\"en\" class=\"AFI\" style=\"font-family: 'DejaVu Sans', 'Segoe UI', 'Segoe UI Symbol', 'Lucida Grande', 'Arial Unicode MS', 'Lucida Sans Unicode', 'Charis SIL', 'Doulos SIL', Gentium, GentiumAlt, 'Adobe Pi Std', Code2000, 'Chrysanthi Unicode', 'TITUS Cyberbit Basic', 'Bitstream Cyberbit', 'Hiragino Kaku Gothic Pro', 'Matrix Unicode', sans-serif;\"><span title=\"AFI\">niˈsart</span></span></span><nowiki>/</nowiki><span class=\"AFI-e-SAMPA\" style=\"display:none;\">, </span><span class=\"SAMPA\" style=\"display:none;\">[[Annèxa:Prononciacion|<span title=\"X-SAMPA\">/<span class=\"X-SAMPA\">niˈsart</span>/</span>]]</span>\n\nFrança (Bearn) : escotar « niçard » [[Fichièr:LL-Q14185 (oci)-Davidgrosclaude-niçard.wav]]\n<h2 style=\"font-family: sans-serif; font-weight: bold; font-size: 1.2em; line-height: 1.2em; padding: 0.5em; border-top: 1px dotted #AAA; border-bottom: 1px dotted #AAA;\"><span style=\"padding-right: 0.5em;\">[[Fichièr:Open book 01.svg|25px|middle|link=]]</span>Adjectiu   </h2>\n[[Categoria:occitan|niçard]]\n[[Categoria:Adjectius en occitan|niçard]]\n'''niçard'''; ''feminin'' : '''niçarda'''\n\n# Originari de [[Niça]].\n\n<h2 style=\"font-family: sans-serif; font-weight: bold; font-size: 1.2em; line-height: 1.2em; padding: 0.5em; border-top: 1px dotted #AAA; border-bottom: 1px dotted #AAA;\"><span style=\"padding-right: 0.5em;\">[[Fichièr:Open book 01.svg|25px|middle|link=]]</span>Nom comun  [[Categoria:occitan]][[Categoria:Noms comuns en occitan]] </h2>\n'''niçard''' <span style=\"color:#002000;\">''masculin''</span>\n\n# Varietat regionala de l'[[occitan]] que si parla dins la part bassa dau [[w:Comtat de Niça|Comtat de Niça]], a l'entorn de la vila de [[Niça]]. Es un sosdialècte dau [[provençau]] segon la classificacion dialectologica<ref>En [[w:nòrma classica|nòrma classica]], s'escriu ''niçard niçarda''. En [[w:nòrma mistralenca|nòrma mistralenca]], s'escriu ''<niçart niçarda>'' o mens correctament ''<[[nissart]] nissarda>''.</ref>.\n\n \n<h3 style=\"border-bottom: 1px #AAA dotted;\" title=\"\"> [[traduccion|Traduccions]]  </h3>\n{|  width=\"100%\" style=\"background-color: #FAFAFA; color:#000; border: 1px solid #AAA; margin: 1em 0;\"\n\n|- class=\"mw-collapsible-content\"\n| valign=\"top\" width=\"50%\" style=\"padding: 4px 8px 12px; background-color: #FFF; color:#000; border: 1px dotted #AAA;\" |\n* \n* [[francés]]: [[niçois#fr|niçois]] [[:fr:niçois|<small><sup>(fr)</sup></small>]]\n* \n* [[italian]]: [[nizzardo#it|nizzardo]] [[:it:nizzardo|<small><sup>(it)</sup></small>]]\n* \n* [[sicilian]]: [[nizzardu#scn|nizzardu]] [[:scn:nizzardu|<small><sup>(scn)</sup></small>]]\n* \n* [[còrs]]: [[nizzardu#co|nizzardu]] [[:co:nizzardu|<small><sup>(co)</sup></small>]]\n|}\n===Nòtas===\n<references />\n\n[[Categoria:Gentilicis en occitan]]\n\n[[en:niçard]]\n[[fi:niçard]]\n[[fr:niçard]]";
    const namespace_source = "# wikidict-namespace-registry-v1\n# wiki\tocwiktionary\n# dump-date\t20261001\n# content-language\toc\n-2\tMèdia\tMedia\tcase-sensitive\t0\t0\t0\t\tcompile_only\tvirtual_namespace\n-1\tEspecial\tSpecial\tfirst-letter\t0\t0\t0\t\tcompile_only\tvirtual_namespace\n0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tdictionary_entries\n1\tDiscutir\tTalk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tDiscuter\n2\tUtilizaire\tUser\tfirst-letter\t1\t0\t0\t\tcompile_only\tstandard_build_input\tUtilisator\n3\tDiscussion Utilizaire\tUser talk\tfirst-letter\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tDiscussion Utilisateur\tDiscussion Utilisator\tDiscutida Utilisator\n4\tWikiccionari\tProject\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\tWT\tWiktionary\n5\tDiscussion Wikiccionari\tProject talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tWiktionary talk\n6\tFichièr\tFile\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\tImage\tImatge\n7\tDiscussion Fichièr\tFile talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tDiscussion Fichier\tDiscussion Image\tDiscussion Imatge\tDiscutida Imatge\tImage talk\tImatge Discussió\n8\tMediaWiki\tMediaWiki\tfirst-letter\t1\t0\t0\t\tcompile_only\tstandard_build_input\tMediaòiqui\n9\tDiscussion MediaWiki\tMediaWiki talk\tfirst-letter\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tDiscussion Mediaòiqui\tDiscutida Mediaòiqui\n10\tModèl\tTemplate\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n11\tDiscussion Modèl\tTemplate talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tDiscussion Modèle\tDiscutida Modèl\n12\tAjuda\tHelp\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n13\tDiscussion Ajuda\tHelp talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tDiscussion Aide\tDiscutida Ajuda\n14\tCategoria\tCategory\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\n15\tDiscussion Categoria\tCategory talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tDiscussion Catégorie\tDiscutida Categoria\n100\tAnnèxa\tAnnèxa\tcase-sensitive\t1\t0\t0\t\tsupplemental\tunclassified_subject_retained\n101\tDiscussion Annèxa\tDiscussion Annèxa\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n710\tTimedText\tTimedText\tcase-sensitive\t0\t0\t0\t\tcompile_only\tancillary_site_input\n711\tTimedText talk\tTimedText talk\tcase-sensitive\t0\t0\t0\t\tcompile_only\tdiscussion_namespace\n828\tMòdul\tModule\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n829\tMòdul Discussió\tModule talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n1728\tEvent\tEvent\tcase-sensitive\t1\t0\t0\t\tcompile_only\tancillary_site_input\n1729\tEvent talk\tEvent talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n";
    try std.testing.expectEqual(@as(usize, 3258), source.len);
    var namespaces = try NamespaceRegistry.init(a, namespace_source);
    defer namespaces.deinit();
    // Change only the authored opening angle to an explicit literal entity.
    // Child wiki action, tail, styles, references and complete page stay intact.
    const reference_source = try std.mem.replaceOwned(u8, a, source, "<[[nissart]] nissarda>", "&lt;[[nissart]] nissarda>");
    var actual_report: Fallbacks = .{};
    var expected_report: Fallbacks = .{};
    const actual = try compileReportedWithLinkTrailAlloc(a, "niçard", .language, "Occitan", "oc", source, null, .{}, &namespaces, &actual_report);
    const expected = try compileReportedWithLinkTrailAlloc(a, "niçard", .language, "Occitan", "oc", reference_source, null, .{}, &namespaces, &expected_report);
    try std.testing.expectEqualSlices(u8, expected, actual);
    try std.testing.expectEqualDeep(expected_report, actual_report);
    const stored = try codec.decodeAlloc(a, actual, "niçard", .language, .{ .code = "oc", .heading = "Occitan" });
    try std.testing.expectEqualStrings("DPRB", actual[0..4]);
    var sized_headings: u8 = 0;
    for (stored.entry.sections) |section| for (section.blocks) |block| {
        if (block.kind != .heading) continue;
        for (block.spans) |span| {
            const language_title = std.mem.eql(u8, span.text, "Occitan");
            const adjective_title = std.mem.indexOf(u8, span.text, "Adjectiu") != null;
            const noun_title = std.mem.indexOf(u8, span.text, "Nom comun") != null;
            if (!language_title and !adjective_title and !noun_title) continue;
            try std.testing.expectEqual(blobs.presentation_types.FontScaleBasis.normal_body, span.font_scale_basis);
            try std.testing.expectEqual(@as(?f32, if (language_title) 1.3 else 1.2), span.font_scale);
            if (language_title) {
                try std.testing.expect(span.kind == .link);
                try std.testing.expectEqualStrings("occitan", span.target);
            }
            sized_headings |= if (language_title) @as(u8, 1) else if (adjective_title) 2 else 4;
        }
    };
    try std.testing.expectEqual(@as(u8, 7), sized_headings);
    try std.testing.expectEqualSlices(u8, actual, try codec.encodeAlloc(a, stored));
    try std.testing.expectEqual(@as(usize, 1), stored.entry.references.len);
    var reference_text: std.ArrayList(u8) = .empty;
    var nissart_actions: usize = 0;
    for (stored.entry.references[0].spans) |span| {
        try reference_text.appendSlice(a, span.text);
        if (span.kind == .link and std.mem.eql(u8, span.target, "nissart")) {
            nissart_actions += 1;
            try std.testing.expectEqualStrings("nissart", span.text);
            try std.testing.expect(span.italic);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), nissart_actions);
    try std.testing.expectEqualStrings("En nòrma classica, s'escriu niçard niçarda. En nòrma mistralenca, s'escriu <niçart niçarda> o mens correctament <nissart nissarda>.", reference_text.items);
    var definitions: usize = 0;
    var tables: usize = 0;
    for (stored.entry.sections) |section| for (section.blocks) |block| {
        if (block.kind == .definition) definitions += 1;
        if (block.table != null) tables += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), definitions);
    try std.testing.expectEqual(@as(usize, 1), tables);
    try std.testing.expectEqual(@as(usize, 1), stored.entry.media.len);
    try std.testing.expect(stored.entry.media[0].kind == .audio);
    const raw = [_]compiler.Span{.{ .text = "<nissart nissarda>" }};
    const split = [_]compiler.Span{
        .{ .text = "<" },
        .{ .kind = .link, .text = "nissart", .target = "nissart" },
        .{ .text = " nissarda>" },
    };
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &raw, null));
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &split, null));
    const unresolved = [_]compiler.Span{.{ .kind = .link, .text = "label", .target = "{{missing}}", .provenance = .protected_literal }};
    try std.testing.expectError(error.UncompiledTemplate, validateSpans(a, &unresolved, null));
}

test "complete retained SD claptrap inline close preserves original body styles and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "=== سنڌي ===\n# ڏيکاءُ\n# مَڪر\n\n== انگريزي ==\n# Something that is showy or pretentious, often used to describe empty talk\n# Deceit or trickery, suitable for situations where \"claptrap\" implies something misleading or insincere\n\n===لاڳاپيل لفظ ۽ اصطلاح===\n=== [[Image:trans.png|30px]] ترجما ===\n== رومن سنڌي / (لپي مَٽَ) ==|}\n''Ddekhhau''\n''Makar''\n\n\n[[زمرو:انڊس رومن سنڌي]]\n[[زمرو:سنڌو رومن سنڌي]]\n[[category:Indus Roman Sindhi]]\n\n\n\n[[زمرو:اصطلاح]]\n[[زمرو: رومن سنڌي]]\n[[Category: Transliteration]]";
    const namespace_source = "# wikidict-namespace-registry-v1\n# wiki\tsdwiktionary\n# dump-date\t20261001\n# content-language\tsd\n-2\tذريعات\tMedia\tcase-sensitive\t0\t0\t0\t\tcompile_only\tvirtual_namespace\n-1\tخاص\tSpecial\tfirst-letter\t0\t0\t0\t\tcompile_only\tvirtual_namespace\n0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tdictionary_entries\n1\tبحث\tTalk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n2\tواپرائيندڙ\tUser\tfirst-letter\t1\t0\t0\t\tcompile_only\tstandard_build_input\tيوزر\n3\tواپرائيندڙ بحث\tUser talk\tfirst-letter\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tيوزر بحث\n4\tWiktionary\tProject\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\tWT\n5\tWiktionary بحث\tProject talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tWiktionary talk\n6\tفائل\tFile\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\tImage\tعڪس\n7\tفائل بحث\tFile talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tImage talk\tعڪس بحث\n8\tذريعات وڪي\tMediaWiki\tfirst-letter\t1\t0\t0\t\tcompile_only\tstandard_build_input\n9\tذريعات وڪي بحث\tMediaWiki talk\tfirst-letter\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n10\tسانچو\tTemplate\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\tسنچو\n11\tسانچو بحث\tTemplate talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tسنچو بحث\n12\tمدد\tHelp\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n13\tمدد بحث\tHelp talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n14\tزمرو\tCategory\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\n15\tزمرو بحث\tCategory talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n710\tTimedText\tTimedText\tcase-sensitive\t0\t0\t0\t\tcompile_only\tancillary_site_input\n711\tTimedText talk\tTimedText talk\tcase-sensitive\t0\t0\t0\t\tcompile_only\tdiscussion_namespace\n828\tماڊيول\tModule\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n829\tماڊيول بحث\tModule talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n1728\tEvent\tEvent\tcase-sensitive\t1\t0\t0\t\tcompile_only\tancillary_site_input\n1729\tEvent talk\tEvent talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n";
    try std.testing.expectEqual(@as(usize, 608), source.len);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "|}"));
    var namespaces = try NamespaceRegistry.init(a, namespace_source);
    defer namespaces.deinit();
    const reference = try std.mem.replaceOwned(u8, a, source, "|}", "<nowiki>|}</nowiki>");
    var actual_report: Fallbacks = .{};
    var expected_report: Fallbacks = .{};
    const actual = try compileReportedWithLinkTrailAlloc(a, "claptrap", .language, "Unclassified", "", source, null, .{}, &namespaces, &actual_report);
    const expected = try compileReportedWithLinkTrailAlloc(a, "claptrap", .language, "Unclassified", "", reference, null, .{}, &namespaces, &expected_report);
    try std.testing.expectEqualSlices(u8, expected, actual);
    try std.testing.expectEqualDeep(expected_report, actual_report);
    const stored = try codec.decodeAlloc(a, actual, "claptrap", .language, .{ .code = "", .heading = "Unclassified" });
    try std.testing.expectEqualSlices(u8, actual, try codec.encodeAlloc(a, stored));
    var definitions: usize = 0;
    var literal_close = false;
    var roman_one = false;
    var roman_two = false;
    for (stored.entry.sections) |section| for (section.blocks) |block| {
        try std.testing.expect(block.table == null);
        if (block.kind == .definition) definitions += 1;
        for (block.spans) |span| {
            if (std.mem.indexOf(u8, span.text, "|}") != null) literal_close = true;
            if (span.italic and std.mem.eql(u8, span.text, "Ddekhhau")) roman_one = true;
            if (span.italic and std.mem.eql(u8, span.text, "Makar")) roman_two = true;
        }
    };
    try std.testing.expectEqual(@as(usize, 4), definitions);
    try std.testing.expect(literal_close and roman_one and roman_two);
    try std.testing.expectEqual(@as(usize, 1), stored.entry.media.len);
    try std.testing.expectEqualStrings("trans.png", stored.entry.media[0].file);
    const raw = [_]compiler.Span{.{ .text = "ordinary |}" }};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &raw, null));
    const target = [_]compiler.Span{.{ .kind = .link, .text = "label", .target = "{{unresolved}}", .provenance = .protected_literal }};
    try std.testing.expectError(error.UncompiledTemplate, validateSpans(a, &target, null));
}

test "complete retained KAA teberik double angles preserve both definitions and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "Atlıq.\n\n# Áshirepi, qımbatlı, qádirli.\n# Awıs. Káramatlı, sharapatlı, baxıt beriwshi, húrmetli.  Jurınnıń góne shapanın, Tuwmay júrgen hayallar, Teberik dep bólisti (<<Qırq qız>>).";
    try std.testing.expectEqual(@as(usize, 200), source.len);
    const reference = try std.mem.replaceOwned(u8, a, source, "<<Qırq qız>>", "&lt;&lt;Qırq qız&gt;&gt;");
    var actual_report: Fallbacks = .{};
    var expected_report: Fallbacks = .{};
    const actual = try compileReportedAlloc(a, "teberik", .language, "Unclassified", "", source, null, &actual_report);
    const expected = try compileReportedAlloc(a, "teberik", .language, "Unclassified", "", reference, null, &expected_report);
    try std.testing.expectEqualSlices(u8, expected, actual);
    try std.testing.expect(actual_report.literal_markup and !expected_report.literal_markup);
    expected_report.literal_markup = true;
    try std.testing.expectEqualDeep(expected_report, actual_report);
    const stored = try codec.decodeAlloc(a, actual, "teberik", .language, .{ .code = "", .heading = "Unclassified" });
    try std.testing.expectEqualSlices(u8, actual, try codec.encodeAlloc(a, stored));
    const definitions = [_][]const u8{
        "Áshirepi, qımbatlı, qádirli.",
        "Awıs. Káramatlı, sharapatlı, baxıt beriwshi, húrmetli.  Jurınnıń góne shapanın, Tuwmay júrgen hayallar, Teberik dep bólisti (<<Qırq qız>>).",
    };
    var seen: usize = 0;
    for (stored.entry.sections) |section| for (section.blocks) |block| {
        if (block.kind != .definition) continue;
        try std.testing.expect(seen < definitions.len);
        var visible: std.ArrayList(u8) = .empty;
        for (block.spans) |span| {
            try visible.appendSlice(a, span.text);
            try std.testing.expect(span.kind == .text and span.target.len == 0);
        }
        try std.testing.expectEqualStrings(definitions[seen], visible.items);
        seen += 1;
    };
    try std.testing.expectEqual(definitions.len, seen);
    try std.testing.expectEqual(@as(usize, 0), stored.entry.media.len);
    try std.testing.expectEqual(@as(usize, 0), stored.entry.references.len);
    const raw = [_]compiler.Span{.{ .text = "<<Qırq qız>>" }};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &raw, null));
    const unresolved = [_]compiler.Span{.{ .kind = .link, .text = "label", .target = "{{target}}", .provenance = .protected_literal }};
    try std.testing.expectError(error.UncompiledTemplate, validateSpans(a, &unresolved, null));
}

test "complete retained IG Okwu ojoo bracket label preserves body media and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "\n'''Okwu Ọjọọ'''\n\n==Nkọwa==\nNke a bụ ụka maọbụ okwu na adịghị mma.\n\n===Nkejiasụsụ===\nAha\n\n===Ọmụmaatụ===\nỌ gwara ya okwu ọjọọ\n\n===Mkpọpụta===\n[[File:Ig-Okwu ọjọọ.ogg|thumb|left]]\n\n\n\n\n\n\n===Olumba===\n\n=Ntụghari n'asụsụ ọzọ=\n\n=Bekee=\n[https://en.wiktionary.org/wiki/[bad word bad word]\n\n[[Òtù:aha]]";
    const namespace_source = "# wikidict-namespace-registry-v1\n# wiki\tigwiktionary\n# dump-date\t20261001\n# content-language\tig\n-2\tMidia\tMedia\tcase-sensitive\t0\t0\t0\t\tcompile_only\tvirtual_namespace\tNká\n-1\tỌpụrụiche\tSpecial\tfirst-letter\t0\t0\t0\t\tcompile_only\tvirtual_namespace\tIhü kárírí\n0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tdictionary_entries\n1\tŃkàtá\tTalk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tOkwu\tṄkàtá\n2\tOjiarụ\tUser\tfirst-letter\t1\t0\t0\t\tcompile_only\tstandard_build_input\tỌ'bànifé\tỌbanife\n3\tŃkàtá ojiarụ\tUser talk\tfirst-letter\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tOkwu ọ'bànifé\tOkwu ọbanife\tṄkàtá ojiarụ\n4\tWiktionary\tProject\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\tWT\n5\tŃkàtá Wiktionary\tProject talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tOkwu Wiktionary\tWiktionary talk\tṄkàtá Wiktionary\n6\tFaịlụ\tFile\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\tImage\tUsòrò\tÁkwúkwó orünotu\n7\tŃkàtá faịlụ\tFile talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tImage talk\tOkwu usòrò\tOkwu ákwúkwó orünotu\tṄkàtá faịlụ\n8\tMidiaWiki\tMediaWiki\tfirst-letter\t1\t0\t0\t\tcompile_only\tstandard_build_input\tNkáWiki\n9\tŃkàtá MidiaWiki\tMediaWiki talk\tfirst-letter\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tOkwu MidiaWiki\tOkwu NkáWiki\tṄkàtá MidiaWiki\n10\tTempleeti\tTemplate\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\tÀtụ\n11\tŃkàtá templeeti\tTemplate talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tOkwu àtụ\tṄkàtá templeeti\n12\tEnyemaka\tHelp\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\tNkwadọ\tNkwádọ\n13\tŃkàtá enyemaka\tHelp talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tOkwu nkwadọ\tOkwu nkwádọ\tṄkàtá enyemaka\n14\tOtú\tCategory\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\tÉbéonọr\tÒtù\n15\tŃkàtá otú\tCategory talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tOkwu ébéonọr\tOkwu òtù\tṄkàtá otú\n710\tTimedText\tTimedText\tcase-sensitive\t0\t0\t0\t\tcompile_only\tancillary_site_input\n711\tTimedText talk\tTimedText talk\tcase-sensitive\t0\t0\t0\t\tcompile_only\tdiscussion_namespace\n828\tModule\tModule\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n829\tModule talk\tModule talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n1728\tEvent\tEvent\tcase-sensitive\t1\t0\t0\t\tcompile_only\tancillary_site_input\n1729\tEvent talk\tEvent talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n";
    try std.testing.expectEqual(@as(usize, 355), source.len);
    var namespaces = try NamespaceRegistry.init(a, namespace_source);
    defer namespaces.deinit();
    const reference_source = try std.mem.replaceOwned(u8, a, source, "wiki/[bad", "wiki/ [bad");
    var actual_report: Fallbacks = .{};
    var expected_report: Fallbacks = .{};
    const actual = try compileReportedWithLinkTrailAlloc(a, "Okwu ọjọọ", .language, "Unclassified", "", source, null, .{}, &namespaces, &actual_report);
    const expected = try compileReportedWithLinkTrailAlloc(a, "Okwu ọjọọ", .language, "Unclassified", "", reference_source, null, .{}, &namespaces, &expected_report);
    try std.testing.expectEqualSlices(u8, expected, actual);
    try std.testing.expectEqualDeep(expected_report, actual_report);
    const stored = try codec.decodeAlloc(a, actual, "Okwu ọjọọ", .language, .{ .code = "", .heading = "Unclassified" });
    try std.testing.expectEqualSlices(u8, actual, try codec.encodeAlloc(a, stored));
    var external: usize = 0;
    var bold_headword = false;
    var gloss = false;
    var example = false;
    for (stored.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        if (span.kind == .external_link) {
            external += 1;
            try std.testing.expectEqualStrings("https://en.wiktionary.org/wiki/", span.target);
            try std.testing.expectEqualStrings("[bad word bad word", span.text);
        }
        if (span.bold and std.mem.eql(u8, span.text, "Okwu Ọjọọ")) bold_headword = true;
        if (std.mem.indexOf(u8, span.text, "Nke a bụ ụka maọbụ okwu na adịghị mma.") != null) gloss = true;
        if (std.mem.indexOf(u8, span.text, "Ọ gwara ya okwu ọjọọ") != null) example = true;
    };
    try std.testing.expectEqual(@as(usize, 1), external);
    try std.testing.expect(bold_headword and gloss and example);
    try std.testing.expectEqual(@as(usize, 1), stored.entry.media.len);
    try std.testing.expect(stored.entry.media[0].kind == .audio);
    try std.testing.expectEqualStrings("Ig-Okwu ọjọọ.ogg", stored.entry.media[0].file);
    // Parsing the source owns this boundary; forged residual spans do not.
    const raw = [_]compiler.Span{.{ .text = "[https://en.wiktionary.org/wiki/[bad word bad word]" }};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &raw, null));
    const unsafe = [_]compiler.Span{.{ .kind = .external_link, .text = "label", .target = "https://example.test/{{unresolved}}", .provenance = .protected_literal }};
    try std.testing.expectError(error.UncompiledTemplate, validateSpans(a, &unsafe, null));
    var styled: compiler.Renderer = .{ .a = a, .context = .{} };
    const styled_spans = try styled.parseSpans("''[https://example.test/[word]'' tail", .{});
    var styled_links: usize = 0;
    for (styled_spans) |span| if (span.kind == .external_link) {
        styled_links += 1;
        try std.testing.expect(span.flags.italic);
        try std.testing.expectEqualStrings("[word", span.text);
        try std.testing.expectEqualStrings("https://example.test/", span.target);
    };
    try std.testing.expectEqual(@as(usize, 1), styled_links);
}

test "complete retained YI world computed names preserve tables actions styles and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "[[category:{{{VERSION}}}]]\n{| border=\"0\" cellpadding=\"3\" align=\"center\"\n|+ <font size=\"4\">'''וועלט'''</font> &nbsp; </span dir=\"ltr\" ></span>&nbsp; <small>{{{VERSION}}}/15801</small></span> &nbsp; <small>[//yi.wiktionary.org/w/index.php?title=:%D7%95%D7%95%D7%A2%D7%9C%D7%98&action=purge ↺]</small> &nbsp; <small>[//yi.wiktionary.org/w/index.php?title=:%D7%95%D7%95%D7%A2%D7%9C%D7%98&diff=15801&oldid=6055 δ]</small> &nbsp; [[google:וועלט|*]]\n! ראָמאַניזאַציע: !!<span dir=\"ltr\">velt  &nbsp; [[google:velt|*]]</span> !! <span dir=\"ltr\">romanizatsye:</span>\n|-\n| colspan=\"3\" align=\"center\" | [[category:סובסטאַנטיוו - substantiv]]\n{| style=\"background:#efefef\" border=\"0\" cellpadding=\"3\" align=\"center\" width=100%\n|-\n| align=\"left\" | ''סובסטאַנטיוו'' <br /> ‫װעלטן\n| align=\"center\" | &nbsp;\n| align=\"right\" | <span dir=\"ltr\">''substantiv'' f</span><br /> veltn\n|}\n|-\n| colspan=\"3\" align=\"center\" style=\"background:#efefef\" | {{about_templates_{{{TEMPLATES}}}}} {{about_templates_{{{TEMPLATES_YIVO}}}}}\n|-\n| colspan=\"3\" align=\"center\" style=\"background:#efefef\" | \n{| style=\"background:#efefef\" border=\"0\" cellpadding=\"3\" align=\"center\" width=100%\n|-\n| align=\"left\" valign=\"middle\" | \n| align=\"center\" | &nbsp;\n| align=\"right\" valign=\"middle\" | <span dir=\"ltr\"></span>\n|}\n|-\n| align=\"left\" | ???:\n| align=\"center\" |//\n| align=\"right\" | <span dir=\"ltr\">IPA:</span>\n|-\n| align=\"left\" | ???:\n| align=\"center\" | []\n| align=\"right\" | <span dir=\"ltr\">SAMPA:</span>\n|-\n| align=\"left\" | ‫װאַריאַנט(ן):\n| align=\"center\" | \n| align=\"right\" | <span dir=\"ltr\">variant(n):</span>\n|-\n| align=\"left\" | אונגאַריש:\n| align=\"center\" | <span dir=\"ltr\"></span>\n| align=\"right\" | <span dir=\"ltr\">ungarish:</span>\n|-\n| align=\"left\" | איטאַליעניש:\n| align=\"center\" | <span dir=\"ltr\">mondo ''m''</span>\n| align=\"right\" | <span dir=\"ltr\">italyenish:</span>\n|-\n| align=\"left\" | איסלענדיש:\n| align=\"center\" | <span dir=\"ltr\"></span>\n| align=\"right\" | <span dir=\"ltr\">islendish:</span>\n|-\n| align=\"left\" | אַראַביש:\n| align=\"center\" | <span dir=\"ltr\"></span>\n| align=\"right\" | <span dir=\"ltr\">arabish:</span>\n|-\n| align=\"left\" | בולגאריש:\n| align=\"center\" | <span dir=\"ltr\">{{{BG}}}</span>\n| align=\"right\" | <span dir=\"ltr\">bulgarish:</span>\n|-\n| align=\"left\" | גריכיש:\n| align=\"center\" | <span dir=\"ltr\">{{{EL}}}</span>\n| align=\"right\" | <span dir=\"ltr\">grikhish:</span>\n|-\n| align=\"left\" | דײַטש:\n| align=\"center\" | <span dir=\"ltr\">[[:de:Welt|Welt]] ''f''</span>\n| align=\"right\" | <span dir=\"ltr\">daytsh:</span>\n|-\n| align=\"left\" | דעניש:\n| align=\"center\" | <span dir=\"ltr\">{{{DA}}}</span>\n| align=\"right\" | <span dir=\"ltr\">denish:</span>\n|-\n| align=\"left\" | האָלענדיש:\n| align=\"center\" | <span dir=\"ltr\">[[:nl:wereld|wereld]] ''m''</span>\n| align=\"right\" | <span dir=\"ltr\">holendish:</span>\n|-\n| align=\"left\" | העברעיש:\n| align=\"center\" | <span dir=\"rtl\">עולם<br /><span dir=\"ltr\">(O'lam) m</span></span>\n| align=\"right\" | <span dir=\"ltr\">hebreish:</span>\n|-\n| align=\"left\" | ‫װוילערישע לשון:\n| align=\"center\" | <span dir=\"rtl\"></span><br /><span dir=\"ltr\">{{{SLANG_YIVO}}}</span>\n| align=\"right\" | <span dir=\"ltr\">voylerishe loshn:</span>\n|-\n| align=\"left\" | טערקיש:\n| align=\"center\" | <span dir=\"ltr\">Dünya, Yerküre, Evren</span>\n| align=\"right\" | <span dir=\"ltr\">terkish:</span>\n|-\n| align=\"left\" | טשעכיש:\n| align=\"center\" | <span dir=\"ltr\">svět ''m''</span>\n| align=\"right\" | <span dir=\"ltr\">tshekhish:</span>\n|-\n| align=\"left\" | יאַפּאַניש:\n| align=\"center\" | <span dir=\"ltr\">世界 (せかい, sekai), 界 (かい, kai)</span>\n| align=\"right\" | <span dir=\"ltr\">yapanish:</span>\n|-\n| align=\"left\" | כינעזיש:\n| align=\"center\" | <span dir=\"ltr\">{{{ZH}}}</span>\n| align=\"right\" | <span dir=\"ltr\">khinezish:</span>\n|-\n| align=\"left\" | לאַטייניש:\n| align=\"center\" | <span dir=\"ltr\">mundus</span>\n| align=\"right\" | <span dir=\"ltr\">lateynish:</span>\n|-\n| align=\"left\" | ליטוויש:\n| align=\"center\" | <span dir=\"ltr\"></span>\n| align=\"right\" | <span dir=\"ltr\">litvish:</span>\n|-\n| align=\"left\" | לעטיש:\n| align=\"center\" | <span dir=\"ltr\">pasaulis ''m''</span>\n| align=\"right\" | <span dir=\"ltr\">letish:</span>\n|-\n| align=\"left\" | נארוועגיש:\n| align=\"center\" | <span dir=\"ltr\">{{{NN}}}</span>\n| align=\"right\" | <span dir=\"ltr\">norvegish:</span>\n|-\n| align=\"left\" | סלאוואַקיש:\n| align=\"center\" | <span dir=\"ltr\">{{{SK}}}</span>\n| align=\"right\" | <span dir=\"ltr\">slovakish:</span>\n|-\n| align=\"left\" | ‫סלאָװעניש:\n| align=\"center\" | <span dir=\"ltr\">svet ''m''</span>\n| align=\"right\" | <span dir=\"ltr\">slovenish:</span>\n|-\n| align=\"left\" | סערביש:\n| align=\"center\" | <span dir=\"ltr\"></span>\n| align=\"right\" | <span dir=\"ltr\">serbish:</span>\n|-\n| align=\"left\" | ענגליש:\n| align=\"center\" | <span dir=\"ltr\">[[:en:world|world]]</span>\n| align=\"right\" | <span dir=\"ltr\">english:</span>\n|-\n| align=\"left\" | עסטיש:\n| align=\"center\" | <span dir=\"ltr\">{{{ET}}}</span>\n| align=\"right\" | <span dir=\"ltr\">estish:</span>\n|-\n| align=\"left\" | עספּעראַנטאָ:\n| align=\"center\" | <span dir=\"ltr\">mondo</span>\n| align=\"right\" | <span dir=\"ltr\">esperanto:</span>\n|-\n| align=\"left\" | פּאָרטוגעזיש:\n| align=\"center\" | <span dir=\"ltr\">[[:pt:mundo|mundo]] ''m''</span>\n| align=\"right\" | <span dir=\"ltr\">portugezish:</span>\n|-\n| align=\"left\" | פּױליש:\n| align=\"center\" | <span dir=\"ltr\">świat ''m''</span>\n| align=\"right\" | <span dir=\"ltr\">poylish:</span>\n|-\n| align=\"left\" | פֿיניש:\n| align=\"center\" | <span dir=\"ltr\">{{{FI}}}</span>\n| align=\"right\" | <span dir=\"ltr\">finish:</span>\n|-\n| align=\"left\" | פֿראַנצױזיש:\n| align=\"center\" | <span dir=\"ltr\">monde ''m''</span>\n| align=\"right\" | <span dir=\"ltr\">frantsoyzish:</span>\n|-\n| align=\"left\" | רומעניש:\n| align=\"center\" | <span dir=\"ltr\">lume ''f''</span>\n| align=\"right\" | <span dir=\"ltr\">rumenish:</span>\n|-\n| align=\"left\" | רוסיש:\n| align=\"center\" | <span dir=\"ltr\">[[:ru:мир|мир]], свет</span>\n| align=\"right\" | <span dir=\"ltr\">rusish:</span>\n|-\n| align=\"left\" | שװעדיש:\n| align=\"center\" | <span dir=\"ltr\">värld ''c''</span>\n| align=\"right\" | <span dir=\"ltr\">shvedish:</span>\n|-\n| align=\"left\" | שפּאַניש:\n| align=\"center\" | <span dir=\"ltr\">mundo ''m''</span>\n| align=\"right\" | <span dir=\"ltr\">shpanish:</span>\n|-\n| align=\"left\" | NB:\n| align=\"center\" | <span dir=\"ltr\">{{{NB}}}</span>\n| align=\"right\" | <span dir=\"ltr\">NB:</span>\n|}\n\n{{{CATEGORIES}}}\n\n\n<center>\n<s>וועלט</s> &nbsp; [[google:וועלט|*]]\n</center>\n\n[[קאַטעגאָריע:!]]\n[[קאַטעגאָריע:װ]]\n[[קאַטעגאָריע:ייִדיש]]";
    const namespace_source = "# wikidict-namespace-registry-v1\n# wiki\tyiwiktionary\n# dump-date\t20261001\n# content-language\tyi\n-2\tמעדיע\tMedia\tcase-sensitive\t0\t0\t0\t\tcompile_only\tvirtual_namespace\n-1\tבאַזונדער\tSpecial\tfirst-letter\t0\t0\t0\t\tcompile_only\tvirtual_namespace\tבאזונדער\n0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tdictionary_entries\n1\tרעדן\tTalk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n2\tבאַניצער\tUser\tfirst-letter\t1\t0\t0\t\tcompile_only\tstandard_build_input\tבאַניצערין\tבאנוצער\tבאניצער\tמשתמש\tמשתמשת\n3\tבאַניצער רעדן\tUser talk\tfirst-letter\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tבאַניצערין רעדן\tבאנוצער רעדן\tבאניצער רעדן\tשיחת משתמש\tשיחת משתמשת\n4\tװיקיװערטערבוך\tProject\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\tWT\tWiktionary\tוויקיווערטערבוך\n5\tװיקיװערטערבוך רעדן\tProject talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tWiktionary talk\tוויקיווערטערבוך רעדן\n6\tטעקע\tFile\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\tImage\tבילד\tתמונה\n7\tטעקע רעדן\tFile talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tImage talk\tבילד רעדן\tשיחת תמונה\n8\tמעדיעװיקי\tMediaWiki\tfirst-letter\t1\t0\t0\t\tcompile_only\tstandard_build_input\tמעדיעוויקי\n9\tמעדיעװיקי רעדן\tMediaWiki talk\tfirst-letter\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tמעדיעוויקי רעדן\n10\tמוסטער\tTemplate\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n11\tמוסטער רעדן\tTemplate talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n12\tהילף\tHelp\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n13\tהילף רעדן\tHelp talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n14\tקאַטעגאָריע\tCategory\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\tקאטעגאריע\n15\tקאַטעגאָריע רעדן\tCategory talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tקאטעגאריע רעדן\n710\tTimedText\tTimedText\tcase-sensitive\t0\t0\t0\t\tcompile_only\tancillary_site_input\n711\tTimedText talk\tTimedText talk\tcase-sensitive\t0\t0\t0\t\tcompile_only\tdiscussion_namespace\n828\tיחידה\tModule\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n829\tשיחת יחידה\tModule talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n1728\tאירוע\tEvent\tcase-sensitive\t1\t0\t0\t\tcompile_only\tancillary_site_input\n1729\tשיחת אירוע\tEvent talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n";
    try std.testing.expectEqual(@as(usize, 6765), source.len);
    var namespaces = try NamespaceRegistry.init(a, namespace_source);
    defer namespaces.deinit();
    var reference_source: []const u8 = source;
    for ([_][]const u8{ "{{about_templates_{{{TEMPLATES}}}}}", "{{about_templates_{{{TEMPLATES_YIVO}}}}}" }) |token| {
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, token));
        reference_source = try std.mem.replaceOwned(u8, a, reference_source, token, try std.fmt.allocPrint(a, "<nowiki>{s}</nowiki>", .{token}));
    }
    var actual_report: Fallbacks = .{};
    var reference_report: Fallbacks = .{};
    // No language or POS is inferred from this headingless table page.
    const actual = try compileReportedWithLinkTrailAlloc(a, "וועלט", .language, "Unclassified", "", source, null, .{}, &namespaces, &actual_report);
    const expected = try compileReportedWithLinkTrailAlloc(a, "וועלט", .language, "Unclassified", "", reference_source, null, .{}, &namespaces, &reference_report);
    try std.testing.expectEqualSlices(u8, expected, actual);
    try std.testing.expectEqualDeep(reference_report, actual_report);
    const stored = try codec.decodeAlloc(a, actual, "וועלט", .language, .{ .code = "", .heading = "Unclassified" });
    try std.testing.expectEqualSlices(u8, actual, try codec.encodeAlloc(a, stored));
    try std.testing.expectEqual(@as(usize, 0), stored.entry.organization.lexemes.len);
    var tables: usize = 0;
    for (stored.entry.sections) |section| for (section.blocks) |block| {
        if (block.table != null) tables += 1;
    };
    try std.testing.expect(tables != 0);
    // Missing valid titles still use the existing reported redlink conversion.
    var missing_report: Fallbacks = .{};
    const missing = try a.alloc(compiler.Span, 1);
    missing[0] = .{ .kind = .template, .text = "ordinary_missing|argument", .target = "ordinary_missing" };
    try validateSpans(a, missing, &missing_report);
    try std.testing.expect(missing_report.missing_template);
    try std.testing.expectEqualStrings("Template:ordinary_missing", missing[0].target);
    const raw = [_]compiler.Span{.{ .text = "{{about_templates_{{{TEMPLATES}}}}}" }};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &raw, null));
    const target = [_]compiler.Span{.{ .kind = .link, .text = "label", .target = "about_templates_{{{TEMPLATES}}}", .provenance = .protected_literal }};
    try std.testing.expectError(error.UncompiledTemplate, validateSpans(a, &target, null));
}

test "heading typography source trees preserve whole document except explicit basis through codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body_source = "<h2 style=\"font-size:125%\"><small>Head [[Target|child]]</small></h2>\nordinary [[Sibling]]\n# meaning<ref>note [[Note]]</ref>\n<references />";
    const context_source = "<h2><span style=\"font-size:125%\"><small>Head [[Target|child]]</small></span></h2>\nordinary [[Sibling]]\n# meaning<ref>note [[Note]]</ref>\n<references />";
    const body_bytes = try compileAlloc(a, "entry", .supplemental, null, "", body_source, null);
    const context_bytes = try compileAlloc(a, "entry", .supplemental, null, "", context_source, null);
    try std.testing.expectEqualStrings("DPRB", body_bytes[0..4]);
    try std.testing.expectEqualStrings("DPRA", context_bytes[0..4]);
    const body = try codec.decodeAlloc(a, body_bytes, "entry", .supplemental, null);
    const contextual = try codec.decodeAlloc(a, context_bytes, "entry", .supplemental, null);
    try std.testing.expectEqualSlices(u8, body_bytes, try codec.encodeAlloc(a, body));
    try std.testing.expectEqualSlices(u8, context_bytes, try codec.encodeAlloc(a, contextual));
    var heading_spans: usize = 0;
    var child_actions: usize = 0;
    for (body.entry.sections) |section| for (section.blocks) |block| {
        for (@constCast(block.spans)) |*span| {
            if (block.kind == .heading) {
                try std.testing.expectApproxEqAbs(@as(f32, 1.25 / 1.2), span.font_scale orelse return error.TestUnexpectedResult, 0.000001);
                try std.testing.expectEqual(blobs.presentation_types.FontScaleBasis.normal_body, span.font_scale_basis);
                try std.testing.expect(!span.small);
                if (span.kind == .link and std.mem.eql(u8, span.target, "Target")) child_actions += 1;
                // Compare every other semantic field against the other source tree.
                span.font_scale_basis = .context;
                heading_spans += 1;
            } else {
                try std.testing.expect(span.font_scale == null);
                try std.testing.expectEqual(blobs.presentation_types.FontScaleBasis.context, span.font_scale_basis);
            }
        }
    };
    try std.testing.expect(heading_spans >= 2);
    try std.testing.expectEqual(@as(usize, 1), child_actions);
    try std.testing.expectEqualDeep(contextual, body);
    try std.testing.expectEqualSlices(u8, context_bytes, try codec.encodeAlloc(a, body));
}

test "fragment replay retains body identity set marker without changing ordinary sibling basis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "<span style=\"font-size:100%\">inside\n</span>outside";
    const observation = try observePreScopesAlloc(a, "entry", source, .{}, null, null, null, .{}, null);
    try std.testing.expectEqual(@as(usize, 1), observation.scopes.len);
    const scope = observation.scopes[0];
    var attributes = scope.attributes;
    attributes.font_scale = 1;
    attributes.font_scale_basis = .normal_body;
    attributes.font_scale_set = true;
    const initial = [_]FragmentPreContext.Initial{.{
        .body_end = scope.body_end - scope.body_start,
        .resume_at = scope.resume_at - scope.body_start,
        .kind = scope.kind,
        .formatting = scope.formatting,
        .attributes = attributes,
    }};
    var renderer: compiler.Renderer = .{ .a = a, .context = .{} };
    const blocks = try renderer.renderBodyWithFragmentPre(source[scope.body_start..], .{ .initial = &initial });
    var seen: u8 = 0;
    for (blocks) |block| for (block.spans) |span| {
        if (std.mem.indexOf(u8, span.text, "inside") != null) {
            try std.testing.expectEqual(@as(?f32, 1), span.font_scale);
            try std.testing.expectEqual(compiler.FontScaleBasis.normal_body, span.font_scale_basis);
            try std.testing.expect(span.font_scale_set);
            seen |= 1;
        }
        if (std.mem.indexOf(u8, span.text, "outside") != null) {
            try std.testing.expect(span.font_scale == null);
            try std.testing.expectEqual(compiler.FontScaleBasis.context, span.font_scale_basis);
            seen |= 2;
        }
    };
    try std.testing.expectEqual(@as(u8, 3), seen);
}

test "complete retained PNB ilzam big text preserves source body and numeric size through codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // p220/r22725; retained ordinary source, not an invented language owner.
    const source = "==[[||ناں]]==\n\n<big>شکیت، دوش</big> \n\n\n[[Category:پنجابی وکشنری]]";
    try std.testing.expectEqual(@as(usize, 88), source.len);
    const reference = "==[[||ناں]]==\n\n<span style='font-size:120%'>شکیت، دوش</span> \n\n\n[[Category:پنجابی وکشنری]]";
    var actual_report: Fallbacks = .{};
    var expected_report: Fallbacks = .{};
    const actual = try compileReportedAlloc(a, "الزام", .language, "Unclassified", "", source, null, &actual_report);
    const expected = try compileReportedAlloc(a, "الزام", .language, "Unclassified", "", reference, null, &expected_report);
    try std.testing.expectEqualSlices(u8, expected, actual);
    try std.testing.expectEqualDeep(expected_report, actual_report);
    const stored = try codec.decodeAlloc(a, actual, "الزام", .language, .{ .code = "", .heading = "Unclassified" });
    try std.testing.expectEqualStrings("الزام", stored.entry.title);
    try std.testing.expectEqualStrings("", stored.entry.language_code);
    try std.testing.expectEqual(@as(usize, 0), stored.entry.references.len);
    try std.testing.expectEqual(@as(usize, 0), stored.entry.media.len);
    var sized: usize = 0;
    for (stored.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        if (!std.mem.eql(u8, span.text, "شکیت، دوش")) continue;
        try std.testing.expect(span.kind == .text and span.target.len == 0 and !span.small);
        try std.testing.expectEqual(@as(?f32, 1.2), span.font_scale);
        try std.testing.expectEqual(types.FontScaleBasis.context, span.font_scale_basis);
        sized += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), sized);
    try std.testing.expectEqualSlices(u8, actual, try codec.encodeAlloc(a, stored));
}


test "complete retained GD cat keeps all typed presentation fields through orphan close repair" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // p2048/r67019 ordinal196. Raw3491/35497e3a, expanded28842/c7195243.
    // Unclassified is an explicit test container, not corpus language authority.
    const raw = "{{Speciesbox\n|name= Cat calla\n|status= DOM\n<!-- There has been extensive discussion about the choice of image in this infobox. Before replacing this image with something else, consider if it actually improves on the ENCYCLOPEDIC CRITERIA which led to this choice. See [[Talk:Cat]] and [[Talk:Cat/Lead photo]] and if in doubt, DISCUSS IT FIRST! -->\n|image= Cat poster 1.jpg<!--please do not change without consensus, see talk page-->\n|image_upright= 1.2\n|image_caption= Diofar sheòrsan den chat calla\n|genus= Felis\n|species= catus<ref name=\"Linnaeus1758\">{{Cite book |last=Linnaeus |first=C. |title=Systema naturae per regna tria naturae: secundum classes, ordines, genera, species, cum characteribus, differentiis, synonymis, locis |location=Holmiae |publisher=Laurentii Salvii |date=1758 |page=42 |chapter=Felis Catus |language=la |volume=1 |edition=Tenth reformed |chapter-url= https://archive.org/details/mobot31753000798865/page/42}}</ref>\n\n|authority=({{enUici|Carl Linnaeus|Linnaeus}}, {{enUici|10th edition of Systema Naturae|1758}})<ref name=\"MSW3fc\">{{MSW3 Wozencraft |id=14000031 |pages=534–535 |heading=Species ''Felis catus''}}</ref>\n|synonyms= {{Show|Co-fhaclan|\n*''F. catus domesticus'' {{Small|{{enUici|Johann Christian Polycarp Erxleben|Erxleben}}, 1777}}<ref name=Erxleben>{{Cite book |last=Erxleben |first=J. C. P. |date=1777 |title=Systema regni animalis per classes, ordines, genera, species, varietates cvm synonymia et historia animalivm. Classis I. Mammalia |location=Lipsiae |publisher=Weygandt |pages=520–521 |chapter=Felis Catus domesticus |chapter-url= https://archive.org/details/iochristpolycerx00erxl/page/520}}\n</ref>\n*''F. angorensis'' {{Small|{{enUici|Karl Christian Gmelin|Gmelin}}, 1788}}\n*''F. vulgaris'' {{Small|Fischer, 1829}}\n}} }}\n{{=gd=}}\n{{-bunachas-}}\n{{rfe|lang=gd}}\n{{-fuaimneachadh-}}\n{{IPA|/kahd/|<ref name=AFB>{{ref:AFB}}. Dàta air inntrigeadh air 13<sup>mh</sup> Am Faoilleach 2020. </ref>}}\n{{rfap|lang=gd}}\n{{-ainm-|gd}}\n{{gd-ainm|m|gp=\tcait}}<ref name=AFB>{{ref:AFB}}. Dàta air inntrigeadh air 13<sup>mh</sup> Am Faoilleach 2020. </ref>\n# ({{Mamal|gd}}) [[gnè]] {{Species|Felis|lang=gd}}\n#:[[seòrsachan]]:\n## {{Species|Felis catus|lang=gd}}\n## {{Species|Felis silvestris|lang=gd}}\n### {{Species|Felis silvestris silvestris|lang=gd}}\n### {{Species|Felis silvestris grampia|lang=gd}}\n## {{Species|Felis chaus|lang=gd}}\n## {{Species|Felis lybica|lang=gd}}\n## {{Species|Felis nigripes|lang=gd}}\n## {{Species|Felis margarita|lang=gd}}\n## {{Species|Felis bieti|lang=gd}}\n\n{{=C=|en}}\n{{-bunachas-}}\n{{rfe|lang=en}}\n{{-fuaimneachadh-}}\n{{IPA|/kæt/''',''' [kʰæt] '''no''' [kʰæʔ]|lang=en|teacsa='''<big>{{en-GB}}</big>'''}} \n{{Audio-IPA|En-uk-a cat.ogg||lang=en|teacsa='''<big>{{en-GB}}</big>'''}}\n{{IPA|/kæt/''',''' [kʰæt]''',''' [kʰæʔ]''',''' [kʰeə̯t̚]''',''' [kʰæt̚] '''no''' [kʰæʔt̚]|lang=en|teacsa='''<big>{{en-US}}</big>'''}} \n{{Audio-IPA|En-us-cat.ogg||lang=en|teacsa='''<big>{{en-US}}</big>'''}}\n{{Audio-IPA|En-us-inlandnorth-cat.ogg| |lang=en|teacsa='''<big>[[SAA]] a tuath (staigh-thìrean)</big>'''}}\n{{-ainm-|en}}\n{{-enregpl-}}\n# ({{Mamal|en}}) {{Species|Felis|lang=en}}\n# ({{Mamal|en}}) {{Species|Felidae|lang=en}}\n\n{{=C=|ga}}\n{{-bunachas-}}\n{{rfe|lang=ga}}\n{{-fuaimneachadh-}}\n{{rfp|lang=ga}}\n{{rfap|lang=ga}}\n{{-ainm-|ga}}\n{{pn}} {{Fir}} ({{Iol}}: '''cait''')\n# ({{Mamal|ga}}) {{Species|Felis catus|lang=ga}}\n\n\n{{E-t:cat}}\n{{-iom-}}\n[[Roinn-seòrsa:Felidae {{gd|g}}]]\n[[Roinn-seòrsa:Felidae {{ga|g}}]]";
    const source = "\n{| class=\"infobox biota\" style=\"text-align: left; width: 200px; font-size: 100%\"\n|-\n! colspan=2 style=\"text-align: center&#59; background-color: rgb(235,235,210)\" | Cat calla\n|-\n| colspan=2 style=\"text-align: center\" | [[Faidhle:Cat poster 1.jpg|frameless|upright=1.2]]\n|-\n| colspan=2 style=\"text-align: center; font-size: 88%\" | Diofar sheòrsan den chat calla\n|-\n\n|- colspan=2 style=\"text-align: center&#59; background-color: rgb(235,235,210)\"\n! colspan = 2 | <div style = \"text-align: center\">[[:en:w:Conservation status|Inbhe glèidhteachais]]</div>\n|-\n| colspan = 2 | <div style = \"text-align: center\">Callaidh<br>[[Roinn-seòrsa:Domesticated animals]]<small></small></div>\n|-\n|-\n! colspan=2 style=\"min-width:15em; text-align: center&#59; background-color: rgb(235,235,210)\" | [[:en:w:Taxonomy (biology)|Seòrsachadh saidheansail]] <span class='plainlinks' style='font-size:smaller; float:right; padding-right:0.4em; margin-left:-3em;'>[[File:Red Pencil Icon.png|link=Template:Taxonomy/Felis | edit ]]</span>\n|-\n|Rìoghachd:\n|[[:en:w:Animalia|Animalia]]\n|-\n|Fine:\n|[[:en:w:Chordata|Chordata]]\n|-\n|Clas:\n|[[:en:w:Mammalia|Mammalia]]\n|-\n|Òrdugh:\n|[[:en:w:Carnivora|Carnivora]]\n|-\n|Fo-òrdugh:\n|[[:en:w:Feliformia|Feliformia]]\n|-\n|Teaghlach:\n|[[:en:w:Felidae|Felidae]]\n|-\n|Fo-theaghlach:\n|[[:en:w:Felinae|Felinae]]\n|-\n|Gnè:\n|[[:en:w:Felis|''Felis'']]\n|-\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n| Seòrsa:\n| <div style=\"display:inline\" class=\"seòrsa\">'''''F.&nbsp;c. n. c. b. C. <span style=\"font-style:normal;\">(</span>1.<span style=\"font-style:normal;\">)</span> [. \"F.\" C. S. n. p. r. t. n. s. c. o. g. s. c. c. d. s. l. <span style=\"font-style:normal;\">(</span>i.<span style=\"font-style:normal;\">)</span> L. <. <span style=\"font-style:normal;\">(</span>T.<span style=\"font-style:normal;\">)</span> r. e. H. L. S. p. L. s. <span style=\"font-style:normal;\">(</span>l.<span style=\"font-style:normal;\">)</span> src=\"Module:Citation/CS1/styles.css\"></templatestyles></ref>'''''</div>\n|-\n\n\n|-\n\n\n\n\n|-\n! colspan=2 style=\"text-align: center&#59; background-color: rgb(235,235,210)\" | [[:en:w:Binomial nomenclature|Ainm dà-nòmach]] \n|-\n| colspan=2 style=\"text-align: center\" | <b><span class=\"binomial\"><span style=\"font-weight:normal;\"></span>''Felis catus<ref name=\"Linnaeus1758\"><cite class=\"citation book\">Linnaeus, C. <span style=\"font-style:normal;\">(</span>1758<span style=\"font-style:normal;\">)</span>. [https://archive.org/details/mobot31753000798865/page/42 \"Felis Catus\"]. Systema naturae per regna tria naturae: secundum classes, ordines, genera, species, cum characteribus, differentiis, synonymis, locis <span style=\"font-style:normal;\">(</span>in Laideann<span style=\"font-style:normal;\">)</span>. <b>1</b> <span style=\"font-style:normal;\">(</span>Tenth reformed ed.<span style=\"font-style:normal;\">)</span>. Holmiae: Laurentii Salvii. p.&nbsp;42.</cite>[[Category:CS1 Laideann-language sources <span style=\"font-style:normal;\">(</span>la<span style=\"font-style:normal;\">)</span>]]<templatestyles src=\"Module:Citation/CS1/styles.css\"></templatestyles></ref>''</span></b><br/><div style=\"font-size: 85%;\">([[:en:w:Carl Linnaeus|Linnaeus]], [[:en:w:10th edition of Systema Naturae|1758]])<ref name=\"MSW3fc\">\n<strong class=\"error\"><span class=\"scribunto-error\">Lua error in Mòideal:Citation/CS1: Wikibase entity snapshot missing entity=Q190593</span></strong></ref></div>\n|- style=\"text-align: center&#59; background-color: rgb(235,235,210)\"\n\n|-\n\n|-\n\n|-\n\n|-\n\n|-\n\n|-\n\n|-\n\n|-\n\n|-\n\n|-\n\n\n\n\n\n\n\n\n\n\n\n|-\n! colspan=2 style=\"text-align: center&#59; background-color: rgb(235,235,210)\" | [[:en:w:Synonym (taxonomy)|Co-fhaclan]] \n|-\n| colspan=2 style=\"text-align: left\" |\n<div class=\"mw-collapsible  mw-collapsed \" style=\"box-sizing:border-box;width:100%;font-size:95%;padding:4px;border:none;padding: 0px;\"><div style=\"font-size:100%;line-height:1.6;font-weight:bold;background:transparent;text-align:left;;padding: 0px;\">Co-fhaclan</div><div class=\"mw-collapsible-content\" style=\"background:transparent;text-align:left;;padding: 0px;\">\n*''F. catus domesticus'' <span style=\"font-size:85%;\">[[:en:w:Johann Christian Polycarp Erxleben|Erxleben]], 1777</span><ref name=Erxleben><cite class=\"citation book\">Erxleben, J. C. P. (1777). [https://archive.org/details/iochristpolycerx00erxl/page/520 \"Felis Catus domesticus\"]. ''Systema regni animalis per classes, ordines, genera, species, varietates cvm synonymia et historia animalivm. Classis I. Mammalia''. Lipsiae: Weygandt. pp.&nbsp;520–521.</cite><span title=\"ctx_ver=Z39.88-2004&rft_val_fmt=info%3Aofi%2Ffmt%3Akev%3Amtx%3Abook&rft.genre=bookitem&rft.atitle=Felis+Catus+domesticus&rft.btitle=Systema+regni+animalis+per+classes%2C+ordines%2C+genera%2C+species%2C+varietates+cvm+synonymia+et+historia+animalivm.+Classis+I.+Mammalia&rft.place=Lipsiae&rft.pages=520-521&rft.pub=Weygandt&rft.date=1777&rft.aulast=Erxleben&rft.aufirst=J.+C.+P.&rft_id=https%3A%2F%2Farchive.org%2Fdetails%2Fiochristpolycerx00erxl%2Fpage%2F520&rfr_id=info%3Asid%2Fgd.wiktionary.org%3Acat\" class=\"Z3988\"></span><templatestyles src=\"Module:Citation/CS1/styles.css\"></templatestyles>\n</ref>\n*''F. angorensis'' <span style=\"font-size:85%;\">[[:en:w:Karl Christian Gmelin|Gmelin]], 1788</span>\n*''F. vulgaris'' <span style=\"font-size:85%;\">Fischer, 1829</span>\n</div></div>\n|-\n\n|}[[Roinn-seòrsa:Articles with 'species' microformats]]<strong class=\"error\"><span class=\"scribunto-error\">Lua error in Mòideal:Taxonbar/candidate: Wikibase page-link snapshot missing title=cat</span></strong>\n\n</div><div style=\"margin-top: 1em; padding: 0.5em; border: solid grey 1px; background-color: #fdfffe\">\n== [[Faidhle:Flag of Scotland.svg|border|75px|middle]] Gàidhlig ==\n[[Roinn-seòrsa:Faclan Gàidhlig]]\n<h3>Freumhachadh</h3>\n\n<div class=\"noprint request-box\" style=\"width: auto; margin: 0; padding: 0.5em; border-collapse: collapse;overflow: hidden;\">\n{| style=\"background:#FFFFFF; width:90%; margin: auto; border:1px dashed #999999; text-align:left\"\n| [[File:EB1911_-_Volume_01_-_Page_001_-_1.svg|100px]]\n| Chan eil freumh-fhaclachd aig an duilleag seo. An urrainn dhuibh i cur ris?<br><br>This page has no etymology. Can you add it?\n|}\n</div>[[Roinn-seòrsa:Iarrtasan airson freumhachadh Gàidhlig]]\n<h3>Fuaimneachadh</h3>\n\n<strong class=\"error\"><span class=\"scribunto-error\">Lua error in Mòideal:IPA/templates: Parameter 1 must be a valid language or etymology language code; the value \"/kahd/\" is not valid. See [[WT:LOL]] and [[WT:LOL/E]].</span></strong>\n<div class=\"noprint request-box\" style=\"width: auto; margin: 0; padding: 0.5em; border-collapse: collapse;overflow: hidden;\">\n{| style=\"background:#FFFFFF; width:90%; margin: auto; border:1px dashed #999999; text-align:left\"\n| [[Faidhle:Headset_icon.svg|75px]]\n| Feumaidh an inntrigeadh seo co-dhiù aon fhaidhle-fuaime. Ma tha microfòn agad, clàraich fear agus luchdaich suas e.<br><br>This entry needs at least one audio file. If you have a microphone, please [[:en:Help:Audio pronunciations|record one]] and [//commons.wikimedia.org/wiki/Sònraichte:Upload upload] it. <br><small>(For audio required quickly, please visit  [[:commons:Commons:Pronunciation_files_requests]].)</small>\n|}\n</div>[[Roinn-seòrsa:Iarrtasan airson faidhle-fuaime Gàidhlig]]\n\n<h3>Ainmear</h3>\n[[Roinn-seòrsa:Ainmearan Gàidhlig]]\n'''cat''' ''fireann''   (''ginideach'' [[⁊]] ''iolra'': '''[[cait]]''')   <ref name=AFB>''[https://faclair.com/ '''Am Faclair Beag''']''  Bauer, Mìcheal. Faclair Gàidhlig is Beurla le Dwelly 'na bhroinn. An English - Scottish Gaelic dictionary incorporating Dwelly.. Dàta air inntrigeadh air 13<sup>mh</sup> Am Faoilleach 2020. </ref>\n# (''mamal''[[Roinn-seòrsa:Ainmhidhean sa Ghàidhlig]] [[Roinn-seòrsa:Mamalan sa Ghàidhlig]]) [[gnè]] [[:wikispecies:Felis|<span style=\"color:green;\">''Felis''</span>]][[Roinn-seòrsa:Felis sa Ghàidhlig]][[Roinn-seòrsa:Ainmean tacsonamach (gnè) sa Ghàidhlig]]\n#:[[seòrsachan]]:\n## [[:wikispecies:Felis catus|<span style=\"color:green;\">''Felis catus''</span>]][[Roinn-seòrsa:Felis catus sa Ghàidhlig]][[Roinn-seòrsa:Ainmean tacsonamach (gnè) sa Ghàidhlig]]\n## [[:wikispecies:Felis silvestris|<span style=\"color:green;\">''Felis silvestris''</span>]][[Roinn-seòrsa:Felis silvestris sa Ghàidhlig]][[Roinn-seòrsa:Ainmean tacsonamach (gnè) sa Ghàidhlig]]\n### [[:wikispecies:Felis silvestris silvestris|<span style=\"color:green;\">''Felis silvestris silvestris''</span>]][[Roinn-seòrsa:Felis silvestris silvestris sa Ghàidhlig]][[Roinn-seòrsa:Ainmean tacsonamach (gnè) sa Ghàidhlig]]\n### [[:wikispecies:Felis silvestris grampia|<span style=\"color:green;\">''Felis silvestris grampia''</span>]][[Roinn-seòrsa:Felis silvestris grampia sa Ghàidhlig]][[Roinn-seòrsa:Ainmean tacsonamach (gnè) sa Ghàidhlig]]\n## [[:wikispecies:Felis chaus|<span style=\"color:green;\">''Felis chaus''</span>]][[Roinn-seòrsa:Felis chaus sa Ghàidhlig]][[Roinn-seòrsa:Ainmean tacsonamach (gnè) sa Ghàidhlig]]\n## [[:wikispecies:Felis lybica|<span style=\"color:green;\">''Felis lybica''</span>]][[Roinn-seòrsa:Felis lybica sa Ghàidhlig]][[Roinn-seòrsa:Ainmean tacsonamach (gnè) sa Ghàidhlig]]\n## [[:wikispecies:Felis nigripes|<span style=\"color:green;\">''Felis nigripes''</span>]][[Roinn-seòrsa:Felis nigripes sa Ghàidhlig]][[Roinn-seòrsa:Ainmean tacsonamach (gnè) sa Ghàidhlig]]\n## [[:wikispecies:Felis margarita|<span style=\"color:green;\">''Felis margarita''</span>]][[Roinn-seòrsa:Felis margarita sa Ghàidhlig]][[Roinn-seòrsa:Ainmean tacsonamach (gnè) sa Ghàidhlig]]\n## [[:wikispecies:Felis bieti|<span style=\"color:green;\">''Felis bieti''</span>]][[Roinn-seòrsa:Felis bieti sa Ghàidhlig]][[Roinn-seòrsa:Ainmean tacsonamach (gnè) sa Ghàidhlig]]\n\n\n</div><div style=\"margin-top: 1em; padding: 0.5em; border: solid grey 1px; background-color: #fdfffe\">\n== Beurla ==\n[[Roinn-seòrsa:Faclan Beurla]]\n\n<h3>Freumhachadh</h3>\n\n<div class=\"noprint request-box\" style=\"width: auto; margin: 0; padding: 0.5em; border-collapse: collapse;overflow: hidden;\">\n{| style=\"background:#FFFFFF; width:90%; margin: auto; border:1px dashed #999999; text-align:left\"\n| [[File:EB1911_-_Volume_01_-_Page_001_-_1.svg|100px]]\n| Chan eil freumh-fhaclachd aig an duilleag seo. An urrainn dhuibh i cur ris?<br><br>This page has no etymology. Can you add it?\n|}\n</div>[[Roinn-seòrsa:Iarrtasan airson freumhachadh Beurla]]\n<h3>Fuaimneachadh</h3>\n\n<strong class=\"error\"><span class=\"scribunto-error\">Lua error in Mòideal:IPA/templates: Parameter \"teacsa\" is not used by this template.</span></strong> \n<div style=\"margin-top: 1em; padding: 0.5em; border: solid grey 1px; background-color: #F1fffe\">&nbsp;'''<big>Beurla Bhreatannach ([[RA]])</big>'''&nbsp;&nbsp;'''AEF:'''&nbsp;&nbsp;<span class=\"IPA audiolink nounderlines\" style=\"white-space: nowrap;\"></span><table class=\"audiotable\" style=\"vertical-align: middle; display:inline-block; list-style:none;line-height: 1em;\"><tr><td class=\"audiofile\">[[Faidhle:En-uk-a cat.ogg]] [[:Faidhle:En-uk-a cat.ogg]]</td></tr></table><span class=\"metadata audiolinkinfo\"><sup>[[:en:w:WP:Media help (Ogg)|cobhair - help]]</sup></span><span class=\"IPA audiolink nounderlines\" style=\"white-space: nowrap;\"></span></div>[[Roinn-seòrsa:Briathran Beurla le ceanglaichean-fuaime]]\n<strong class=\"error\"><span class=\"scribunto-error\">Lua error in Mòideal:IPA/templates: Parameter \"teacsa\" is not used by this template.</span></strong> \n<div style=\"margin-top: 1em; padding: 0.5em; border: solid grey 1px; background-color: #F1fffe\">&nbsp;'''<big>Beurla Aimeireaganach ([[SAA]])</big>'''&nbsp;&nbsp;'''AEF:'''&nbsp;&nbsp;<span class=\"IPA audiolink nounderlines\" style=\"white-space: nowrap;\"></span><table class=\"audiotable\" style=\"vertical-align: middle; display:inline-block; list-style:none;line-height: 1em;\"><tr><td class=\"audiofile\">[[Faidhle:En-us-cat.ogg]] [[:Faidhle:En-us-cat.ogg]]</td></tr></table><span class=\"metadata audiolinkinfo\"><sup>[[:en:w:WP:Media help (Ogg)|cobhair - help]]</sup></span><span class=\"IPA audiolink nounderlines\" style=\"white-space: nowrap;\"></span></div>[[Roinn-seòrsa:Briathran Beurla le ceanglaichean-fuaime]]\n<div style=\"margin-top: 1em; padding: 0.5em; border: solid grey 1px; background-color: #F1fffe\">&nbsp;'''<big>[[SAA]] a tuath (staigh-thìrean)</big>'''&nbsp;&nbsp;'''AEF:'''&nbsp;&nbsp;<span class=\"IPA audiolink nounderlines\" style=\"white-space: nowrap;\"></span><table class=\"audiotable\" style=\"vertical-align: middle; display:inline-block; list-style:none;line-height: 1em;\"><tr><td class=\"audiofile\">[[Faidhle:En-us-inlandnorth-cat.ogg]] [[:Faidhle:En-us-inlandnorth-cat.ogg]]</td></tr></table><span class=\"metadata audiolinkinfo\"><sup>[[:en:w:WP:Media help (Ogg)|cobhair - help]]</sup></span><span class=\"IPA audiolink nounderlines\" style=\"white-space: nowrap;\"></span></div>[[Roinn-seòrsa:Briathran Beurla le ceanglaichean-fuaime]]\n\n<h3>Ainmear</h3>\n[[Roinn-seòrsa:Ainmearan Beurla]]\n'''cat''' (''iolra'': '''[[cats]]''')\n# (''mamal''[[Roinn-seòrsa:Ainmhidhean sa Bheurla]] [[Roinn-seòrsa:Mamalan sa Bheurla]]) [[:wikispecies:Felis|<span style=\"color:green;\">''Felis''</span>]][[Roinn-seòrsa:Felis sa Bheurla]][[Roinn-seòrsa:Ainmean tacsonamach (gnè) sa Bheurla]]\n# (''mamal''[[Roinn-seòrsa:Ainmhidhean sa Bheurla]] [[Roinn-seòrsa:Mamalan sa Bheurla]]) [[:wikispecies:Felidae|<span style=\"color:green;\">''Felidae''</span>]][[Roinn-seòrsa:Felidae sa Bheurla]][[Roinn-seòrsa:Ainmean tacsonamach (gnè) sa Bheurla]]\n\n\n</div><div style=\"margin-top: 1em; padding: 0.5em; border: solid grey 1px; background-color: #fdfffe\">\n== Gaeilge ==\n[[Roinn-seòrsa:Faclan Gaeilge]]\n\n<h3>Freumhachadh</h3>\n\n<div class=\"noprint request-box\" style=\"width: auto; margin: 0; padding: 0.5em; border-collapse: collapse;overflow: hidden;\">\n{| style=\"background:#FFFFFF; width:90%; margin: auto; border:1px dashed #999999; text-align:left\"\n| [[File:EB1911_-_Volume_01_-_Page_001_-_1.svg|100px]]\n| Chan eil freumh-fhaclachd aig an duilleag seo. An urrainn dhuibh i cur ris?<br><br>This page has no etymology. Can you add it?\n|}\n</div>[[Roinn-seòrsa:Iarrtasan airson freumhachadh Gaeilge]]\n<h3>Fuaimneachadh</h3>\n\n<div class=\"noprint request-box\" style=\"width: auto; margin: 0; padding: 0.5em; border-collapse: collapse;overflow: hidden;\">\n{| style=\"background:#FFFFFF; width:90%; margin: auto; border:1px dashed #999999; text-align:left\"\n| [[Faidhle:Phonetik.svg|100px]]\n| Feumaidh an inntrigeadh seo fiosrachadh fuaimneachaidh. Ma tha thu eòlach air an [[:en:w:International Phonetic Alphabet|Aibidil Fhuaim-Eòlach Eadar-nàiseanta (AFE)]] feuch an cuir thu cuid ris!<br><br>This entry needs pronunciation information. If you are familiar with the [[:en:w:International Phonetic Alphabet|IPA]] then please add some!\n|}\n</div>[[Roinn-seòrsa:Iarrtasan airson fuaimneachadh Gaeilge]]\n<div class=\"noprint request-box\" style=\"width: auto; margin: 0; padding: 0.5em; border-collapse: collapse;overflow: hidden;\">\n{| style=\"background:#FFFFFF; width:90%; margin: auto; border:1px dashed #999999; text-align:left\"\n| [[Faidhle:Headset_icon.svg|75px]]\n| Feumaidh an inntrigeadh seo co-dhiù aon fhaidhle-fuaime. Ma tha microfòn agad, clàraich fear agus luchdaich suas e.<br><br>This entry needs at least one audio file. If you have a microphone, please [[:en:Help:Audio pronunciations|record one]] and [//commons.wikimedia.org/wiki/Sònraichte:Upload upload] it. <br><small>(For audio required quickly, please visit  [[:commons:Commons:Pronunciation_files_requests]].)</small>\n|}\n</div>[[Roinn-seòrsa:Iarrtasan airson faidhle-fuaime Gaeilge]]\n\n<h3>Ainmear</h3>\n[[Roinn-seòrsa:Ainmearan Gaeilge]]\n'''cat''' ''fireann'' (''iolra'': '''cait''')\n# (''mamal''[[Roinn-seòrsa:Ainmhidhean sa Ghaeilge]] [[Roinn-seòrsa:Mamalan sa Ghaeilge]]) [[:wikispecies:Felis catus|<span style=\"color:green;\">''Felis catus''</span>]][[Roinn-seòrsa:Felis catus sa Ghaeilge]][[Roinn-seòrsa:Ainmean tacsonamach (gnè) sa Ghaeilge]]\n\n\n</div><div style=\"margin-top: 1em; padding: 0.5em; border: solid gray 1px; background-color: #fdfffe\">\n==Eadar-theangachaidhean==\n{| class=\"wikitable sortable collapsible collapsed\"                                                 \n|+\n|-\n!colspan=\"4\"|''Felis sylvestris catus''\n|-\n!Còd\n!Cànan\n!Teaghlach\n!Faclan\n|-\n|af  ||Afraganais  ||ine (Innd-Eòrpach):gem (Gearmanach):gmw (Gearmanach an Iar)  ||<span lang=\"af\"xml:lang=\"af\">[[kat#af|kat]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:af:kat|(af)]]</sup></span>     <br>\n|-\n|an  ||Aragonais  ||ine (Innd-Eòrpach):itc (Italiceach):roa (Romansach)  ||<span lang=\"an\"xml:lang=\"an\">[[gato#an|gato]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:an:gato|(an)]]</sup></span>  <br>\n|-\n|ast  ||Astùrais  ||ine (Innd-Eòrpach):itc (Italiceach):roa (Romansach)  ||<span lang=\"ast\"xml:lang=\"ast\">[[gatu#ast|gatu]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:ast:gatu|(ast)]]</sup></span>  <br>\n|-\n|bg  ||Bulgarais  ||ine (Innd-Eòrpach):sla (Slàbhach):zls (Slàbhach a Deas)  ||<span lang=\"bg\"xml:lang=\"bg\">[[коткa#bg|коткa]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:bg:коткa|(bg)]]</sup></span>  (kotka)  <br>\n|-\n|ca  ||Catalanais  ||ine (Innd-Eòrpach):itc (Italiceach):roa (Romansach)  ||<span lang=\"ca\"xml:lang=\"ca\">[[gat#ca|gat]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:ca:gat|(ca)]]</sup></span>  ''fireann''  <br>\n|-\n|zh  ||Sìnis  ||sit (Sìonach-Tibeiteach):zhx (Sìneach)  ||<span lang=\"zh\"xml:lang=\"zh\">[[猫#zh|猫]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:zh:猫|(zh)]]</sup></span>  (māo)  <br>\n|-\n|da  ||Danmhairgis  ||ine (Innd-Eòrpach):gem (Gearmanach):gmq (Gearmanach a Tuath)  ||<span lang=\"da\"xml:lang=\"da\">[[kat#da|kat]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:da:kat|(da)]]</sup></span>  ''cumanta''  <br>\n|-\n|de  ||Gearmailtis  ||ine (Innd-Eòrpach):gem (Gearmanach):gmw (Gearmanach an Iar)  ||<span lang=\"de\"xml:lang=\"de\">[[Katze#de|Katze]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:de:Katze|(de)]]</sup></span>  ''boireann''  <br>\n|-\n|en  ||Beurla  ||ine (Innd-Eòrpach):gem (Gearmanach):gmw (Gearmanach an Iar)  ||<span lang=\"en\"xml:lang=\"en\">[[cat#en|cat]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:en:cat|(en)]]</sup></span>  <br>\n|-\n|eo ||Esperanto ||art (cànain-fhuadain) ||<span lang=\"eo\"xml:lang=\"eo\">[[kato#eo|kato]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:eo:kato|(eo)]]</sup></span> <br>\n|-\n|et ||Eastonais ||urj (Uralach):fiu (Finno-Ugriceach) ||<span lang=\"et\"xml:lang=\"et\">[[kass#et|kass]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:et:kass|(et)]]</sup></span> <br>\n|-\n|fo ||Fàrothais ||ine (Innd-Eòrpach):gem (Gearmanach):gmq (Gearmanach a Tuath) ||<span lang=\"fo\"xml:lang=\"fo\">[[kattur#fo|kattur]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:fo:kattur|(fo)]]</sup></span> <br>\n|-\n|fi ||Fionnlannais ||urj (Uralach):fiu (Finno-Ugriceach) ||<span lang=\"fi\"xml:lang=\"fi\">[[kissa#fi|kissa]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:fi:kissa|(fi)]]</sup></span> <br>\n|-\n|fr ||Fraingis ||ine (Innd-Eòrpach):itc (Italiceach):roa (Romansach) ||<span lang=\"fr\"xml:lang=\"fr\">[[chat#fr|chat]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:fr:chat|(fr)]]</sup></span>  ''fireann'' <br>\n|-\n|fy ||Frìoslannais ||ine (Innd-Eòrpach):gem (Gearmanach):gmw (Gearmanach an Iar) ||<span lang=\"fy\"xml:lang=\"fy\">[[kat#fy|kat]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:fy:kat|(fy)]]</sup></span>  ''cumanta'' <br>\n|-\n|haw ||cànan Hawai'i ||map (Ostronèiseach):poz (Malaidheach-Pholynèisich):pqe (Malaidheach-Pholynèisich an Ear) ||<span lang=\"haw\"xml:lang=\"haw\">[[popoki#haw|popoki]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:haw:popoki|(haw)]]</sup></span> <br>\n|-\n|he ||Eabhra ||afa (Afra-Àisianach):sem (Semiticeach) ||<span lang=\"he\"xml:lang=\"he\">[[חתול#he|חתול]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:he:חתול|(he)]]</sup></span>  (xatul) <br>\n|-\n|hi ||Hindis ||ine (Innd-Eòrpach):iir (Innd-Iorànach):inc (Innd-Arianach) ||<span lang=\"hi\"xml:lang=\"hi\">[[बिल्ली#hi|बिल्ली]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:hi:बिल्ली|(hi)]]</sup></span>  (billī) ''boireann'' <br>\n|-\n|hu ||Ungairis ||urj (Uralach):fiu (Finno-Ugriceach) ||<span lang=\"hu\"xml:lang=\"hu\">[[macska#hu|macska]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:hu:macska|(hu)]]</sup></span> <br>\n|-\n|io ||Ido ||art (cànain-fhuadain) ||<span lang=\"io\"xml:lang=\"io\">[[kato#io|kato]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:io:kato|(io)]]</sup></span> <br>\n|-\n|ga ||Gaeilge ||ine (Innd-Eòrpach):cel (Ceilteach) ||<span lang=\"ga\"xml:lang=\"ga\">[[cat#ga|cat]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:ga:cat|(ga)]]</sup></span> <br>\n|-\n|is ||Innis Tìlis ||ine (Innd-Eòrpach):gem (Gearmanach):gmq (Gearmanach a Tuath) ||<span lang=\"is\"xml:lang=\"is\">[[köttur#is|köttur]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:is:köttur|(is)]]</sup></span>  ''fireann'' <br>\n|-\n|id ||Innd-Innsis ||map (Ostronèiseach):poz (Malaidheach-Pholynèisich):pqw (Malaidheach-Pholynèisich an Iar) ||<span lang=\"id\"xml:lang=\"id\">[[kucing#id|kucing]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:id:kucing|(id)]]</sup></span> <br>\n|-\n|ia ||Interlingua ||art (cànain-fhuadain) ||<span lang=\"ia\"xml:lang=\"ia\">[[catto#ia|catto]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:ia:catto|(ia)]]</sup></span> <br>\n|-\n|it ||Eadailtis ||ine (Innd-Eòrpach):itc (Italiceach):roa (Romansach) ||<span lang=\"it\"xml:lang=\"it\">[[gatto#it|gatto]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:it:gatto|(it)]]</sup></span>  ''fireann'' <br>\n|-\n|ja ||Seapanais ||jpx (Seapanach) ||<span lang=\"ja\"xml:lang=\"ja\">[[猫#ja|猫]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:ja:猫|(ja)]]</sup></span>  (neko) <br>\n|-\n|kk ||Casachais ||tut (Altaiceach):trk (Turcach) ||<span lang=\"kk\"xml:lang=\"kk\">[[коска#kk|коска]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:kk:коска|(kk)]]</sup></span>  (koska) <br>\n|-\n|crh ||Qırım tili ||tut (Altaiceach):trk (Turcach) ||<span lang=\"crh\"xml:lang=\"crh\">[[mışıq#crh|mışıq]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:crh:mışıq|(crh)]]</sup></span> <br>\n|-\n|ktu ||Kituba\n ||nic (Nìgeir-Kordofanianach):alv (Congo-Atlantaigiche):bnt (Bantuthach)\n ||<span lang=\"ktu\"xml:lang=\"ktu\">[[pusu#ktu|pusu]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:ktu:pusu|(ktu)]]</sup></span> , <span lang=\"ktu\"xml:lang=\"ktu\">[[niawu#ktu|niawu]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:ktu:niawu|(ktu)]]</sup></span> <br>\n|-\n|ko ||Coirèanais ||tut (Altaiceach) ||<span lang=\"ko\"xml:lang=\"ko\">[[고양이#ko|고양이]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:ko:고양이|(ko)]]</sup></span>  (goyangi') <br>\n|-\n|min ||Minangkabau\n ||map (Ostronèiseach):poz (Malaidheach-Pholynèisich):pqw (Malaidheach-Pholynèisich an Iar)\n ||<span lang=\"min\"xml:lang=\"min\">[[kuciang#min|kuciang]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:min:kuciang|(min)]]</sup></span> <br>\n|-\n|no ||Nirribhis ||ine (Innd-Eòrpach):gem (Gearmanach):gmq (Gearmanach a Tuath) ||<span lang=\"no\"xml:lang=\"no\">[[katt#no|katt]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:no:katt|(no)]]</sup></span>  ''fireann'', <span lang=\"no\"xml:lang=\"no\">[[katte#no|katte]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:no:katte|(no)]]</sup></span>  ''fireann''/''boireann'' <br>\n|-\n|nn ||Nynorsk na Nirribhidh ||ine (Innd-Eòrpach):gem (Gearmanach):gmq (Gearmanach a Tuath) ||<span lang=\"nn\"xml:lang=\"nn\">[[katt#nn|katt]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:nn:katt|(nn)]]</sup></span>  ''fireann'', <span lang=\"nn\"xml:lang=\"nn\">[[katte#nn|katte]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:nn:katte|(nn)]]</sup></span>  ''boireann'' <br>\n|-\n|oc ||Ogsatanais ||ine (Innd-Eòrpach):itc (Italiceach):roa (Romansach) ||<span lang=\"oc\"xml:lang=\"oc\">[[gat#oc|gat]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:oc:gat|(oc)]]</sup></span>  ''fireann'', <span lang=\"oc\"xml:lang=\"oc\">[[cat#oc|cat]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:oc:cat|(oc)]]</sup></span>  ''fireann'' <br>\n|-\n|uk ||Ucràinis ||ine (Innd-Eòrpach):sla (Slàbhach):zle (Slàbhach an Ear) ||<span lang=\"uk\"xml:lang=\"uk\">[[кiт#uk|кiт]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:uk:кiт|(uk)]]</sup></span>  (kit), <span lang=\"uk\"xml:lang=\"uk\">[[кішка#uk|кішка]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:uk:кішка|(uk)]]</sup></span>  (kishka) <br>\n|-\n|non ||Seann-Lochlannais ||ine (Innd-Eòrpach):gem (Gearmanach):gmq (Gearmanach a Tuath) ||<span lang=\"non\"xml:lang=\"non\">[[kǫttr#non|kǫttr]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:non:kǫttr|(non)]]</sup></span>  ''fireann'' <br>\n|-\n|pl ||Pòlainnis ||ine (Innd-Eòrpach):sla (Slàbhach):zlw (Slàbhach an Iar) ||<span lang=\"pl\"xml:lang=\"pl\">[[kot#pl|kot]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:pl:kot|(pl)]]</sup></span>  ''fireann'' <br>\n|-\n|pt ||Portagailis ||ine (Innd-Eòrpach):itc (Italiceach):roa (Romansach) ||<span lang=\"pt\"xml:lang=\"pt\">[[gato#pt|gato]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:pt:gato|(pt)]]</sup></span>  ''fireann'' <br>\n|-\n|qu ||Quechua ||sai (cànain dhùthchasach nan Aimeireaga):qwe (Quechuanach) ||<span lang=\"qu\"xml:lang=\"qu\">[[michi#qu|michi]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:qu:michi|(qu)]]</sup></span> , <span lang=\"qu\"xml:lang=\"qu\">[[misi#qu|misi]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:qu:misi|(qu)]]</sup></span>  (''Ecuador'') <br>\n|-\n|ro ||Romàinis ||ine (Innd-Eòrpach):itc (Italiceach):roa (Romansach) ||<span lang=\"ro\"xml:lang=\"ro\">[[pisică#ro|pisică]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:ro:pisică|(ro)]]</sup></span>  ''boireann'' <br>\n|-\n|ru ||Ruisis ||ine (Innd-Eòrpach):sla (Slàbhach):zle (Slàbhach an Ear) ||<span lang=\"ru\"xml:lang=\"ru\">[[кот#ru|кот]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:ru:кот|(ru)]]</sup></span>  (kot) ''fireann'' <br>\n|-\n|sl ||Slòbhainis ||ine (Innd-Eòrpach):sla (Slàbhach):zls (Slàbhach a Deas) ||<span lang=\"sl\"xml:lang=\"sl\">[[maček#sl|maček]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:sl:maček|(sl)]]</sup></span>  ''fireann'', <span lang=\"sl\"xml:lang=\"sl\">[[mačka#sl|mačka]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:sl:mačka|(sl)]]</sup></span>  ''boireann'' <br>\n|-\n|sk ||Slòbhacais ||ine (Innd-Eòrpach):sla (Slàbhach):zlw (Slàbhach an Iar) ||<span lang=\"sk\"xml:lang=\"sk\">[[mačka#sk|mačka]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:sk:mačka|(sk)]]</sup></span>  ''boireann'', <span lang=\"sk\"xml:lang=\"sk\">[[kocúr#sk|kocúr]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:sk:kocúr|(sk)]]</sup></span>  ''fireann'' <br>\n|-\n|es ||Spàinntis ||ine (Innd-Eòrpach):itc (Italiceach):roa (Romansach) ||<span lang=\"es\"xml:lang=\"es\">[[gato#es|gato]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:es:gato|(es)]]</sup></span>  ''fireann'' <br>\n|-\n|cs ||Seicis ||ine (Innd-Eòrpach):sla (Slàbhach):zlw (Slàbhach an Iar) ||<span lang=\"cs\"xml:lang=\"cs\">[[kočka#cs|kočka]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:cs:kočka|(cs)]]</sup></span>  ''boireann'', <span lang=\"cs\"xml:lang=\"cs\">[[kocour#cs|kocour]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:cs:kocour|(cs)]]</sup></span>  ''fireann'' <br>\n|-\n|tr ||Turcais ||tut (Altaiceach):trk (Turcach) ||<span lang=\"tr\"xml:lang=\"tr\">[[kedi#tr|kedi]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:tr:kedi|(tr)]]</sup></span> <br>\n|-\n|vi ||Bhiet-Namais ||aav (Ostroàiseach):mkh (Mon–Cmèar):vi (Bhieteach) ||<span lang=\"vi\"xml:lang=\"vi\">[[mèo#vi|mèo]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:vi:mèo|(vi)]]</sup></span> <br>\n|-\n|cy ||a' Chuimris ||ine (Innd-Eòrpach):cel (Ceilteach) ||<span lang=\"cy\"xml:lang=\"cy\">[[cath#cy|cath]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:cy:cath|(cy)]]</sup></span> <br>\n|-\n|sv ||Suainis ||ine (Innd-Eòrpach):gem (Gearmanach):gmq (Gearmanach a Tuath):sv (Suainis) ||<span lang=\"sv\"xml:lang=\"sv\">[[katt#sv|katt]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:sv:katt|(sv)]]</sup></span>  ''cumanta'' <br>\n|-\n|gd ||Gàidhlig ||ine (Innd-Eòrpach):cel (Ceilteach) ||<span lang=\"gd\"xml:lang=\"gd\">[[cat#gd|cat]]</span>&nbsp;<span class=\"trad-sup-code\"><sup>[[:gd:cat|(gd)]]</sup></span>                                                                                                                                                                                                                                                                                                                                                               \n|}<br clear=\"all\">\n</div><div style=\"margin-top: 1em; padding: 0.5em; border: solid gray 1px; background-color: #fdfffe\">\n==Iomraidhean - References==\n\n[[Roinn-seòrsa:Felidae Gàidhlig]]\n[[Roinn-seòrsa:Felidae Gaeilge]]";
    try std.testing.expectEqual(@as(usize, 3491), raw.len);
    try std.testing.expectEqual(@as(usize, 28842), source.len);
    const orphan_at: usize = 1998;
    const close = "</templatestyles>";
    try std.testing.expectEqualStrings(close, source[orphan_at..][0..close.len]);
    // Independent Sanitizer spelling: entity-escape only the unmatched close.
    // Exact complete encoded equality checks every typed body/style/action/
    // reference/media field, without flattening or removing structural blocks.
    const reference = try std.fmt.allocPrint(a, "{s}&lt;/templatestyles&gt;{s}", .{ source[0..orphan_at], source[orphan_at + close.len ..] });
    var namespaces = try NamespaceRegistry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tgdwiktionary\n# dump-date\t20261001\n# content-language\tgd\n0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tdictionary_entries\n6\tFaidhle\tFile\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\tImage\n10\tTeamplaid\tTemplate\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n14\tRoinn-seòrsa\tCategory\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\n828\tMòideal\tModule\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n");
    defer namespaces.deinit();
    try namespaces.attachInterwikiMap("# interwiki-magic\t1\ncommons\t1\t0\t0\t0\thttps://commons.wikimedia.org/wiki/$1\t0\nwikispecies\t1\t0\t0\t0\thttps://species.wikimedia.org/wiki/$1\t0\naf\t1\t0\t0\t0\thttps://af.wiktionary.org/wiki/$1\t1\nan\t1\t0\t0\t0\thttps://an.wiktionary.org/wiki/$1\t1\nast\t1\t0\t0\t0\thttps://ast.wiktionary.org/wiki/$1\t1\nbg\t1\t0\t0\t0\thttps://bg.wiktionary.org/wiki/$1\t1\nca\t1\t0\t0\t0\thttps://ca.wiktionary.org/wiki/$1\t1\ncrh\t1\t0\t0\t0\thttps://crh.wiktionary.org/wiki/$1\t1\ncs\t1\t0\t0\t0\thttps://cs.wiktionary.org/wiki/$1\t1\ncy\t1\t0\t0\t0\thttps://cy.wiktionary.org/wiki/$1\t1\nda\t1\t0\t0\t0\thttps://da.wiktionary.org/wiki/$1\t1\nde\t1\t0\t0\t0\thttps://de.wiktionary.org/wiki/$1\t1\nen\t1\t0\t0\t0\thttps://en.wiktionary.org/wiki/$1\t1\neo\t1\t0\t0\t0\thttps://eo.wiktionary.org/wiki/$1\t1\nes\t1\t0\t0\t0\thttps://es.wiktionary.org/wiki/$1\t1\net\t1\t0\t0\t0\thttps://et.wiktionary.org/wiki/$1\t1\nfi\t1\t0\t0\t0\thttps://fi.wiktionary.org/wiki/$1\t1\nfo\t1\t0\t0\t0\thttps://fo.wiktionary.org/wiki/$1\t1\nfr\t1\t0\t0\t0\thttps://fr.wiktionary.org/wiki/$1\t1\nfy\t1\t0\t0\t0\thttps://fy.wiktionary.org/wiki/$1\t1\nga\t1\t0\t0\t0\thttps://ga.wiktionary.org/wiki/$1\t1\ngd\t1\t1\t0\t0\thttps://gd.wiktionary.org/wiki/$1\t1\nhaw\t1\t0\t0\t0\thttps://haw.wiktionary.org/wiki/$1\t1\nhe\t1\t0\t0\t0\thttps://he.wiktionary.org/wiki/$1\t1\nhi\t1\t0\t0\t0\thttps://hi.wiktionary.org/wiki/$1\t1\nhu\t1\t0\t0\t0\thttps://hu.wiktionary.org/wiki/$1\t1\nia\t1\t0\t0\t0\thttps://ia.wiktionary.org/wiki/$1\t1\nid\t1\t0\t0\t0\thttps://id.wiktionary.org/wiki/$1\t1\nio\t1\t0\t0\t0\thttps://io.wiktionary.org/wiki/$1\t1\nis\t1\t0\t0\t0\thttps://is.wiktionary.org/wiki/$1\t1\nit\t1\t0\t0\t0\thttps://it.wiktionary.org/wiki/$1\t1\nja\t1\t0\t0\t0\thttps://ja.wiktionary.org/wiki/$1\t1\nkk\t1\t0\t0\t0\thttps://kk.wiktionary.org/wiki/$1\t1\nko\t1\t0\t0\t0\thttps://ko.wiktionary.org/wiki/$1\t1\nmin\t1\t0\t0\t0\thttps://min.wiktionary.org/wiki/$1\t1\nnn\t1\t0\t0\t0\thttps://nn.wiktionary.org/wiki/$1\t1\nno\t1\t0\t0\t0\thttps://no.wiktionary.org/wiki/$1\t1\noc\t1\t0\t0\t0\thttps://oc.wiktionary.org/wiki/$1\t1\npl\t1\t0\t0\t0\thttps://pl.wiktionary.org/wiki/$1\t1\npt\t1\t0\t0\t0\thttps://pt.wiktionary.org/wiki/$1\t1\nqu\t1\t0\t0\t0\thttps://qu.wiktionary.org/wiki/$1\t1\nro\t1\t0\t0\t0\thttps://ro.wiktionary.org/wiki/$1\t1\nru\t1\t0\t0\t0\thttps://ru.wiktionary.org/wiki/$1\t1\nsk\t1\t0\t0\t0\thttps://sk.wiktionary.org/wiki/$1\t1\nsl\t1\t0\t0\t0\thttps://sl.wiktionary.org/wiki/$1\t1\nsv\t1\t0\t0\t0\thttps://sv.wiktionary.org/wiki/$1\t1\ntr\t1\t0\t0\t0\thttps://tr.wiktionary.org/wiki/$1\t1\nuk\t1\t0\t0\t0\thttps://uk.wiktionary.org/wiki/$1\t1\nvi\t1\t0\t0\t0\thttps://vi.wiktionary.org/wiki/$1\t1\nzh\t1\t0\t0\t0\thttps://zh.wiktionary.org/wiki/$1\t1\n");
    var actual_report: Fallbacks = .{};
    var expected_report: Fallbacks = .{};
    const actual = try compileReportedWithLinkTrailAlloc(a, "cat", .language, "Unclassified", "", source, null, .{}, &namespaces, &actual_report);
    const expected = try compileReportedWithLinkTrailAlloc(a, "cat", .language, "Unclassified", "", reference, null, .{}, &namespaces, &expected_report);
    try std.testing.expectEqualSlices(u8, expected, actual);
    try std.testing.expectEqualDeep(expected_report, actual_report);
    try std.testing.expect(actual_report.literal_markup);
    const stored = try codec.decodeAlloc(a, actual, "cat", .language, .{ .code = "", .heading = "Unclassified" });
    try std.testing.expectEqualStrings("", stored.entry.language_code);
    try std.testing.expectEqualSlices(u8, actual, try codec.encodeAlloc(a, stored));
    try std.testing.expectEqual(@as(usize, 4), stored.entry.references.len);
    for ([_][]const u8{ "Linnaeus1758", "MSW3fc", "Erxleben", "AFB" }) |name| {
        var matches: usize = 0;
        for (stored.entry.references) |ref| if (std.mem.eql(u8, name, ref.name)) { matches += 1; };
        try std.testing.expectEqual(@as(usize, 1), matches);
    }
    for ([_][]const u8{ "Cat poster 1.jpg", "En-uk-a cat.ogg", "En-us-cat.ogg", "En-us-inlandnorth-cat.ogg" }) |file| {
        var found = false;
        for (stored.entry.media) |media| if (std.mem.eql(u8, file, media.file)) { found = true; };
        try std.testing.expect(found);
    }
    const Witness = struct {
        tables: usize = 0,
        actions: usize = 0,
        lua_errors: usize = 0,
        green_italic_species: bool = false,
        orphan_literal: bool = false,
        taxonomy_prefix: bool = false,
        fn spans(self: *@This(), spans_: []const types.Span) !void {
            for (spans_) |span| {
                if (span.kind == .link or span.kind == .external_link) self.actions += 1;
                if (std.mem.eql(u8, span.text, "Felis") and span.italic and span.foreground != null) {
                    try std.testing.expectEqualStrings("#008000", span.foreground.?);
                    self.green_italic_species = true;
                }
                if (std.mem.indexOf(u8, span.text, "Lua error in ") != null) {
                    self.lua_errors += 1;
                    try std.testing.expect(span.bold);
                }
                if (std.mem.indexOf(u8, span.text, "templatestyles") != null) self.orphan_literal = true;
                if (std.mem.indexOf(u8, span.text, "src=\"Module:Citation/CS1/styles.css\"") != null) self.taxonomy_prefix = true;
            }
        }
        fn table(self: *@This(), value: types.Table) anyerror!void {
            self.tables += 1;
            try self.spans(value.caption);
            for (value.rows) |row| for (row.cells) |cell| {
                if (cell.blocks) |children| try self.blocks(children) else if (cell.nested_table) |nested| try self.table(nested) else try self.spans(cell.spans);
            };
        }
        fn blocks(self: *@This(), values: []const types.Block) anyerror!void {
            for (values) |block| {
                try self.spans(block.spans);
                if (block.table) |value| try self.table(value);
            }
        }
    };
    var witness: Witness = .{};
    for (stored.entry.sections) |section| try witness.blocks(section.blocks);
    for (stored.entry.references) |ref| {
        try witness.spans(ref.spans);
        // Full encoded equality above retains every stored reference field.
    }
    try std.testing.expect(witness.tables >= 8);
    try std.testing.expect(witness.actions >= 100);
    try std.testing.expectEqual(@as(usize, 5), witness.lua_errors);
    try std.testing.expect(witness.green_italic_species and witness.orphan_literal and witness.taxonomy_prefix);
}


test "complete retained WA armonak interrupted attributes preserve whole body styles links references and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "== <strong class=\"error\"><span class=\"scribunto-error\">Lua error in Module:Lingaedje: NotCallable</span></strong> ==\n<gallery>\nÅrmonak des cwate Matî 1910.jpg|Coviete d’ èn årmonak e walon di 1910.\n</gallery>\n\n=== <span id=\"Walon\">Etimolodjeye</span> ===\n<span class=\"info\">S’ i gn åreut ene sakî ki sepreut cwè åd fwait di l’ etimolodjeye di « '''årmonak''' », el pout stitchî vaici.</span>[[Categoreye:Mots do walon sins etimolodjeye]]\n\n=== <span id=\"\">Prononçaedje</span> ===\n* [[Wiccionaire:AFE|AFE]] :\n** [[Wiccionaire:Walon#Accints do walon|diferins prononçaedjes]] :[[Categoreye:Mots walons avou sacwants prononçaedjes coinreces]] <span class=\"afe\" title=\"Scrijhaedje e l’ alfabet fonetike eternåcionå\">/ɔːʀmɔnak/</span> <span class=\"afe\" title=\"Scrijhaedje e l’ alfabet fonetike eternåcionå\">/oːʀmɔnak/</span> <span class=\"afe\" title=\"Scrijhaedje e l’ alfabet fonetike eternåcionå\">/aːʀmɔnak/</span> <span class=\"afe\" title=\"Scrijhaedje e l’ alfabet fonetike eternåcionå\">/oːʀmanak/</span> <span class=\"afe\" title=\"Scrijhaedje e l’ alfabet fonetike eternåcionå\">/oːlmanak/</span>[[Categoreye:Årtikes sins sillabe dins l' modele AFE]] ([[w:Betchfessî å|betchfessî å]])\n[[Categoreye:Mots avou l' betchfessî å]]\n** [[Wiccionaire:Prononçaedje zero-cnoxheu|prononçaedje zero-cnoxheu]] : <span class=\"afe\" title=\"Scrijhaedje e l’ alfabet fonetike eternåcionå\">/ɔːʀmɔnak/</span>[[Categoreye:Årtikes sins sillabe dins l' modele AFE]]\n\n=== <span id=\"Walon Sustantif\">Sustantif</span>[[Categoreye:Sustantifs do walon]] ===\n\n{| class=\"acoirds\"\n\n\n\n! singulî\n\n! pluriyal\n|-\n\n| <span lang=\"wa\" class=\"lang-wa\" dir=\"ltr\">[[årmonak#Walon Sustantif|årmonak]]</span>\n| <span lang=\"wa\" class=\"lang-wa\" dir=\"ltr\">[[årmonaks#Walon Sustantif|årmonaks]]</span>\n|}\n<span class=\"mot\">årmonak</span> ''omrin'' / ''femrin''\n# ''([[cronolodjeye]])''[[Categoreye:Motlî do walon pol cronolodjeye]] ptit live avou tos les djoûs d’ ene anêye, et des ptits scrijhaedjes djondant.\n#* <span lang=\"wa-felLi pus grand d' sès plêsîrs, qwand dji v'néve li dîmègne,</br>C'èsteût si p'tit paquèt ; li djôye lî féve fé 'ne hègne,</br>Tot d'loyant s' norèt d' potche, qwand prindéve si toubak,</br>Adon-pwis si p'tite gote, féve-t-i dès-'''årmanaks''' !\" class=\"lang-wa-felLi pus grand d' sès plêsîrs, qwand dji v'néve li dîmègne,</br>C'èsteût si p'tit paquèt ; li djôye lî féve fé 'ne hègne,</br>Tot d'loyant s' norèt d' potche, qwand prindéve si toubak,</br>Adon-pwis si p'tite gote, féve-t-i dès-'''årmanaks''' !\" dir=\"ltr\"></span> <strong class=\"error\"><span class=\"scribunto-error\">Lua error in Module:Sourdant: Wikibase entity snapshot missing entity=Q3185766</span></strong>\n#* Infén, di ces tins ci, i raplike moens sovint e m’ måjhone. Gn ddja pont d’ må. I shonnreut ki c’ est a cåze k’ il a do succès avou ses viyès biestreyes d’ <span class=\"mot\">årmonak</span>. <strong class=\"error\"><span class=\"scribunto-error\">Lua error in Module:Sourdant: Wikibase entity snapshot missing entity=Q13213105</span></strong>\n# ''(pa [[Wiccionaire:Stindaedje do sinse|stindaedje do sinse]])'' ''(pus sovint eployî å [[pluriyal]])''[[Categoreye:Sustantifs ki l' pluriyal est pus corant]] [[ridit]], [[riprotche]], (mwais) [[comintåre]], [[cancan]].\n#* Ni fwai nén tant ds <span class=\"mot\">årmonaks</span> po si pô d’ tchoi. <strong class=\"error\"><span class=\"scribunto-error\">Lua error in Module:Sourdant: Wikibase entity snapshot missing entity=Q20619553</span></strong>\n\n==== <span id=\"\">Ratourneures</span> ====\n# <span class=\"rato\">[[djåzer come èn årmonak]]</span>[[Categoreye:Mots do walon avou des ratourneures]]\n\n==== <span id=\"\">Mots d’ aplacaedje</span> ====\n* [[fijheu d’ årmonaks]]\n\n==== <span id=\"\">Mots vijhéns</span> ====\n* [[calindrî]]\n\n==== <span id=\"\">Rilomêye do mot</span> ====\nLi mot dins on '''[[tite]]''' di [[live]], di [[gazete]], di [[soce]], di [[marke]]\n* [[w:Årmonak Matî Lansbert|Årmonak Matî Lansbert]]\n* [[w:Årmonak des bierdjîs|Årmonak des bierdjîs]]\n* [[w:Årmonak des cwate Matî|Årmonak des cwate Matî]]\n\n==== <span id=\"\">Ortografeyes</span> ====\n<div class=\"g-or\"><div class=\"TBox og og-d1900\"><div class=\"TBox-title ogt\">[[Wiccionaire:Walon#Sistinmes_di_dvant_Feller|Divant 1900]] :</div><div class=\"TBox-content\"><ul><li>[[armonack#Walon (vîs sistinmes)|armonack]] : [[Sourdant:E212|E212]] <sup>([[:s:fr:Dictionnaire wallon-françois (Villers)/armonack|lére]])</sup></li><li>[[armanak#Walon (vîs sistinmes)|armanak]] : [[Sourdant:E89|E89]] <sup>([[:s:fr:Dictionnaire wallon-français (Cambresier)/Armanak|lére]])</sup>, [[Sourdant:E177a|E177a]] <sup>([[:s:fr:Dictionnaire wallon-français (Remacle, 1e éd.)/Armanak|lére]])</sup></li><li>[[ârmanak#Walon (vîs sistinmes)|ârmanak]] : [[Sourdant:E203|E203]] <sup>([[:s:fr:Dictionnaire liégeois-français (Forir)/Ârmanak|lére]])</sup></li></ul></div></div><div class=\"TBox og og-s20es\"><div class=\"TBox-title ogt\">[[Wiccionaire:Walon#Sistinme_Feller_(et_cpagneye)|Après 1900]], foû rfondou <small>(Feller, Feller ricandjî, nén Feller)</small> :</div><div class=\"TBox-content c-3\"\"><ul><li>[[aurmonac#Walon-Feller|aurmonac]] : [[Sourdant:C9|C9]]</li><li>[[armonak'#Walon-Feller|armonak']] : [[Sourdant:O4|O4]]</li><li>[[aulmanak#Walon-Feller|aulmanak]] : [[Sourdant:S109|S109]]</li><li>[[aurmonak#Walon-Feller|aurmonak]] : [[Sourdant:C1|C1]]</li><li>[[aurmonac’#Walon-Feller|aurmonac’]] : [[Sourdant:O0|O0]]</li><li>'''årmonak''' : [[Sourdant:E34|E34]]</li><li>[[armanack#Walon-Feller|armanack]] : [[Sourdant:JVri|JVri]]</li><li>[[årmanac’#Walon-Feller|årmanac’]] : [[Sourdant:E1|E1]] <sup>([[:s:fr:Dictionnaire liégeois (Haust)/årmanac’|lére]])</sup></li><li>[[aurmanak#Walon-Feller|aurmanak]] : [[Sourdant:C8|C8]], [[Sourdant:C13|C13]]</li></ul></div></div><div class=\"TBox og og-rif\"><div class=\"TBox-title ogt\">E [[Wiccionaire:Walon#Rifondou_walon|rfondou walon]] :</div><div class=\"TBox-content\"><ul><li>'''årmonak''' : [[Sourdant:R10|R10]] <sup class=\"plainlinks\">([http://dtw.walon.org/index.php?query=%C3%A5rmonak lére])</sup>, [[Sourdant:R13|R13]]</li></ul></div></div></div>[[Categoreye:Mots ki sont dins l' motî d' Vervî]][[Categoreye:Mots ki sont dins l' DTW]][[Categoreye:Mots ki sont dins l' motî Yoran Embanner]][[Categoreye:Mots ki l' rifondowe est dins l' motî d' Vervî]]\n\n==== <span id=\"\">Ratournaedjes</span> ====\n<div class=\"TBox TBox-ratour\"><div class=\"TBox-title\">ptit live avou tos les djoûs d’ ene anêye\n</div><div class=\"TBox-content\"><ul><li>[[Imådje:Flag of France.svg|19px|link=]] Francès : <span lang=\"fr\" class=\"lang-fr\" dir=\"ltr\">[[almanach&#x23;Francès|almanach]]</span> <sup class=\"trad-sup-code\">[[:fr:almanach&#x23;Français|(fr)]]</sup></li></ul></div></div>\n<div class=\"TBox TBox-ratour\"><div class=\"TBox-title\">ridit, riprotche, evnd\n</div><div class=\"TBox-content\"><ul><li>[[Imådje:Flag of France.svg|19px|link=]] Francès : <span lang=\"fr\" class=\"lang-fr\" dir=\"ltr\">[[commentaire&#x23;Francès|commentaire]]</span> <sup class=\"trad-sup-code\">[[:fr:commentaire&#x23;Français|(fr)]]</sup>, <span lang=\"fr\" class=\"lang-fr\" dir=\"ltr\">[[développement&#x23;Francès|développement]]</span> <sup class=\"trad-sup-code\">[[:fr:développement&#x23;Français|(fr)]]</sup>, <span lang=\"fr\" class=\"lang-fr\" dir=\"ltr\">[[paraphrase&#x23;Francès|paraphrase]]</span> <sup class=\"trad-sup-code\">[[:fr:paraphrase&#x23;Français|(fr)]]</sup>, <span lang=\"fr\" class=\"lang-fr\" dir=\"ltr\">[[reproche&#x23;Francès|reproche]]</span> <sup class=\"trad-sup-code\">[[:fr:reproche&#x23;Français|(fr)]]</sup>, <span lang=\"fr\" class=\"lang-fr\" dir=\"ltr\">[[glose&#x23;Francès|glose]]</span> <sup class=\"trad-sup-code\">[[:fr:glose&#x23;Français|(fr)]]</sup>, <span lang=\"fr\" class=\"lang-fr\" dir=\"ltr\">[[critique&#x23;Francès|critique]]</span> <sup class=\"trad-sup-code\">[[:fr:critique&#x23;Français|(fr)]]</sup></li></ul></div></div>\n\n=== <span id=\"\">Waitîz eto</span> ===\n[[File:Wikipedia-logo-v2.svg|20px|link=]]&#x20;Lijhoz l’ årtike&#x20;''[[:w:årmonak|årmonak]]'' so Wikipedia";
    const reference_source = "== <strong class=\"error\"><span class=\"scribunto-error\">Lua error in Module:Lingaedje: NotCallable</span></strong> ==\n<gallery>\nÅrmonak des cwate Matî 1910.jpg|Coviete d’ èn årmonak e walon di 1910.\n</gallery>\n\n=== <span id=\"Walon\">Etimolodjeye</span> ===\n<span class=\"info\">S’ i gn åreut ene sakî ki sepreut cwè åd fwait di l’ etimolodjeye di « '''årmonak''' », el pout stitchî vaici.</span>[[Categoreye:Mots do walon sins etimolodjeye]]\n\n=== <span id=\"\">Prononçaedje</span> ===\n* [[Wiccionaire:AFE|AFE]] :\n** [[Wiccionaire:Walon#Accints do walon|diferins prononçaedjes]] :[[Categoreye:Mots walons avou sacwants prononçaedjes coinreces]] <span class=\"afe\" title=\"Scrijhaedje e l’ alfabet fonetike eternåcionå\">/ɔːʀmɔnak/</span> <span class=\"afe\" title=\"Scrijhaedje e l’ alfabet fonetike eternåcionå\">/oːʀmɔnak/</span> <span class=\"afe\" title=\"Scrijhaedje e l’ alfabet fonetike eternåcionå\">/aːʀmɔnak/</span> <span class=\"afe\" title=\"Scrijhaedje e l’ alfabet fonetike eternåcionå\">/oːʀmanak/</span> <span class=\"afe\" title=\"Scrijhaedje e l’ alfabet fonetike eternåcionå\">/oːlmanak/</span>[[Categoreye:Årtikes sins sillabe dins l' modele AFE]] ([[w:Betchfessî å|betchfessî å]])\n[[Categoreye:Mots avou l' betchfessî å]]\n** [[Wiccionaire:Prononçaedje zero-cnoxheu|prononçaedje zero-cnoxheu]] : <span class=\"afe\" title=\"Scrijhaedje e l’ alfabet fonetike eternåcionå\">/ɔːʀmɔnak/</span>[[Categoreye:Årtikes sins sillabe dins l' modele AFE]]\n\n=== <span id=\"Walon Sustantif\">Sustantif</span>[[Categoreye:Sustantifs do walon]] ===\n\n{| class=\"acoirds\"\n\n\n\n! singulî\n\n! pluriyal\n|-\n\n| <span lang=\"wa\" class=\"lang-wa\" dir=\"ltr\">[[årmonak#Walon Sustantif|årmonak]]</span>\n| <span lang=\"wa\" class=\"lang-wa\" dir=\"ltr\">[[årmonaks#Walon Sustantif|årmonaks]]</span>\n|}\n<span class=\"mot\">årmonak</span> ''omrin'' / ''femrin''\n# ''([[cronolodjeye]])''[[Categoreye:Motlî do walon pol cronolodjeye]] ptit live avou tos les djoûs d’ ene anêye, et des ptits scrijhaedjes djondant.\n#* &lt;span lang=\"wa-felLi pus grand d' sès plêsîrs, qwand dji v'néve li dîmègne,</br>C'èsteût si p'tit paquèt ; li djôye lî féve fé 'ne hègne,</br>Tot d'loyant s' norèt d' potche, qwand prindéve si toubak,</br>Adon-pwis si p'tite gote, féve-t-i dès-'''årmanaks''' !\" class=\"lang-wa-felLi pus grand d' sès plêsîrs, qwand dji v'néve li dîmègne,</br>C'èsteût si p'tit paquèt ; li djôye lî féve fé 'ne hègne,</br>Tot d'loyant s' norèt d' potche, qwand prindéve si toubak,</br>Adon-pwis si p'tite gote, féve-t-i dès-'''årmanaks''' !\" dir=\"ltr\"></span> <strong class=\"error\"><span class=\"scribunto-error\">Lua error in Module:Sourdant: Wikibase entity snapshot missing entity=Q3185766</span></strong>\n#* Infén, di ces tins ci, i raplike moens sovint e m’ måjhone. Gn ddja pont d’ må. I shonnreut ki c’ est a cåze k’ il a do succès avou ses viyès biestreyes d’ <span class=\"mot\">årmonak</span>. <strong class=\"error\"><span class=\"scribunto-error\">Lua error in Module:Sourdant: Wikibase entity snapshot missing entity=Q13213105</span></strong>\n# ''(pa [[Wiccionaire:Stindaedje do sinse|stindaedje do sinse]])'' ''(pus sovint eployî å [[pluriyal]])''[[Categoreye:Sustantifs ki l' pluriyal est pus corant]] [[ridit]], [[riprotche]], (mwais) [[comintåre]], [[cancan]].\n#* Ni fwai nén tant ds <span class=\"mot\">årmonaks</span> po si pô d’ tchoi. <strong class=\"error\"><span class=\"scribunto-error\">Lua error in Module:Sourdant: Wikibase entity snapshot missing entity=Q20619553</span></strong>\n\n==== <span id=\"\">Ratourneures</span> ====\n# <span class=\"rato\">[[djåzer come èn årmonak]]</span>[[Categoreye:Mots do walon avou des ratourneures]]\n\n==== <span id=\"\">Mots d’ aplacaedje</span> ====\n* [[fijheu d’ årmonaks]]\n\n==== <span id=\"\">Mots vijhéns</span> ====\n* [[calindrî]]\n\n==== <span id=\"\">Rilomêye do mot</span> ====\nLi mot dins on '''[[tite]]''' di [[live]], di [[gazete]], di [[soce]], di [[marke]]\n* [[w:Årmonak Matî Lansbert|Årmonak Matî Lansbert]]\n* [[w:Årmonak des bierdjîs|Årmonak des bierdjîs]]\n* [[w:Årmonak des cwate Matî|Årmonak des cwate Matî]]\n\n==== <span id=\"\">Ortografeyes</span> ====\n<div class=\"g-or\"><div class=\"TBox og og-d1900\"><div class=\"TBox-title ogt\">[[Wiccionaire:Walon#Sistinmes_di_dvant_Feller|Divant 1900]] :</div><div class=\"TBox-content\"><ul><li>[[armonack#Walon (vîs sistinmes)|armonack]] : [[Sourdant:E212|E212]] <sup>([[:s:fr:Dictionnaire wallon-françois (Villers)/armonack|lére]])</sup></li><li>[[armanak#Walon (vîs sistinmes)|armanak]] : [[Sourdant:E89|E89]] <sup>([[:s:fr:Dictionnaire wallon-français (Cambresier)/Armanak|lére]])</sup>, [[Sourdant:E177a|E177a]] <sup>([[:s:fr:Dictionnaire wallon-français (Remacle, 1e éd.)/Armanak|lére]])</sup></li><li>[[ârmanak#Walon (vîs sistinmes)|ârmanak]] : [[Sourdant:E203|E203]] <sup>([[:s:fr:Dictionnaire liégeois-français (Forir)/Ârmanak|lére]])</sup></li></ul></div></div><div class=\"TBox og og-s20es\"><div class=\"TBox-title ogt\">[[Wiccionaire:Walon#Sistinme_Feller_(et_cpagneye)|Après 1900]], foû rfondou <small>(Feller, Feller ricandjî, nén Feller)</small> :</div><div class=\"TBox-content c-3\"\"><ul><li>[[aurmonac#Walon-Feller|aurmonac]] : [[Sourdant:C9|C9]]</li><li>[[armonak'#Walon-Feller|armonak']] : [[Sourdant:O4|O4]]</li><li>[[aulmanak#Walon-Feller|aulmanak]] : [[Sourdant:S109|S109]]</li><li>[[aurmonak#Walon-Feller|aurmonak]] : [[Sourdant:C1|C1]]</li><li>[[aurmonac’#Walon-Feller|aurmonac’]] : [[Sourdant:O0|O0]]</li><li>'''årmonak''' : [[Sourdant:E34|E34]]</li><li>[[armanack#Walon-Feller|armanack]] : [[Sourdant:JVri|JVri]]</li><li>[[årmanac’#Walon-Feller|årmanac’]] : [[Sourdant:E1|E1]] <sup>([[:s:fr:Dictionnaire liégeois (Haust)/årmanac’|lére]])</sup></li><li>[[aurmanak#Walon-Feller|aurmanak]] : [[Sourdant:C8|C8]], [[Sourdant:C13|C13]]</li></ul></div></div><div class=\"TBox og og-rif\"><div class=\"TBox-title ogt\">E [[Wiccionaire:Walon#Rifondou_walon|rfondou walon]] :</div><div class=\"TBox-content\"><ul><li>'''årmonak''' : [[Sourdant:R10|R10]] <sup class=\"plainlinks\">([http://dtw.walon.org/index.php?query=%C3%A5rmonak lére])</sup>, [[Sourdant:R13|R13]]</li></ul></div></div></div>[[Categoreye:Mots ki sont dins l' motî d' Vervî]][[Categoreye:Mots ki sont dins l' DTW]][[Categoreye:Mots ki sont dins l' motî Yoran Embanner]][[Categoreye:Mots ki l' rifondowe est dins l' motî d' Vervî]]\n\n==== <span id=\"\">Ratournaedjes</span> ====\n<div class=\"TBox TBox-ratour\"><div class=\"TBox-title\">ptit live avou tos les djoûs d’ ene anêye\n</div><div class=\"TBox-content\"><ul><li>[[Imådje:Flag of France.svg|19px|link=]] Francès : <span lang=\"fr\" class=\"lang-fr\" dir=\"ltr\">[[almanach&#x23;Francès|almanach]]</span> <sup class=\"trad-sup-code\">[[:fr:almanach&#x23;Français|(fr)]]</sup></li></ul></div></div>\n<div class=\"TBox TBox-ratour\"><div class=\"TBox-title\">ridit, riprotche, evnd\n</div><div class=\"TBox-content\"><ul><li>[[Imådje:Flag of France.svg|19px|link=]] Francès : <span lang=\"fr\" class=\"lang-fr\" dir=\"ltr\">[[commentaire&#x23;Francès|commentaire]]</span> <sup class=\"trad-sup-code\">[[:fr:commentaire&#x23;Français|(fr)]]</sup>, <span lang=\"fr\" class=\"lang-fr\" dir=\"ltr\">[[développement&#x23;Francès|développement]]</span> <sup class=\"trad-sup-code\">[[:fr:développement&#x23;Français|(fr)]]</sup>, <span lang=\"fr\" class=\"lang-fr\" dir=\"ltr\">[[paraphrase&#x23;Francès|paraphrase]]</span> <sup class=\"trad-sup-code\">[[:fr:paraphrase&#x23;Français|(fr)]]</sup>, <span lang=\"fr\" class=\"lang-fr\" dir=\"ltr\">[[reproche&#x23;Francès|reproche]]</span> <sup class=\"trad-sup-code\">[[:fr:reproche&#x23;Français|(fr)]]</sup>, <span lang=\"fr\" class=\"lang-fr\" dir=\"ltr\">[[glose&#x23;Francès|glose]]</span> <sup class=\"trad-sup-code\">[[:fr:glose&#x23;Français|(fr)]]</sup>, <span lang=\"fr\" class=\"lang-fr\" dir=\"ltr\">[[critique&#x23;Francès|critique]]</span> <sup class=\"trad-sup-code\">[[:fr:critique&#x23;Français|(fr)]]</sup></li></ul></div></div>\n\n=== <span id=\"\">Waitîz eto</span> ===\n[[File:Wikipedia-logo-v2.svg|20px|link=]]&#x20;Lijhoz l’ årtike&#x20;''[[:w:årmonak|årmonak]]'' so Wikipedia";
    try std.testing.expectEqual(@as(usize, 8193), source.len);
    var actual_report: Fallbacks = .{};
    var reference_report: Fallbacks = .{};
    const actual = try compileReportedAlloc(a, "årmonak", .language, "Walon", "wa", source, null, &actual_report);
    const expected = try compileReportedAlloc(a, "årmonak", .language, "Walon", "wa", reference_source, null, &reference_report);
    try std.testing.expectEqualSlices(u8, expected, actual);
    try std.testing.expect(actual_report.literal_markup);
    const stored = try codec.decodeAlloc(a, actual, "årmonak", .language, .{ .code = "wa", .heading = "Walon" });
    try std.testing.expectEqualSlices(u8, actual, try codec.encodeAlloc(a, stored));
}


test "complete retained SQ kardinalitet formulas preserve whole body actions style and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "<div class=\"sister-wikipedia\"><div class=\"sister-project\"><div class=\"noprint\" style=\"clear: right; border: solid #aaa 1px; margin: 0 0 1em 1em; font-size: 90%; width: 250px; padding: 4px; text-align: left; float: right;\"> \n<div style=\"float: left;\"><div style=\"position: relative; width: 50px; height: 50px; overflow: hidden\">\n<div style=\"position: absolute; top: 0px; left: 0px; font-size: 100px; overflow: hidden; line-height: 100px; z-index: 3\">[[w:sq:Faqja Kryesore|&nbsp;&nbsp;&nbsp;]]</div>\n<div style=\"position: absolute; top: 0px; left: 0px; z-index: 2\">[[Image:Wikipedia-logo-en.png|50px|w:sq:Faqja Kryesore]]</div>\n</div></div>\n<div style=\"margin-left: 60px;\">[[w:sq:Wikipedia|Wikipedia]] ka një artikull për fjalën: <div style=\"margin-left: 10px;\">'''''[[w:Kardinalitet|Kardinalitet]]'''''</div>\n</div>\n</div>\n</div></div></span>\n==Shqip==\n===Emër===\n'''kardinalitet''' m.\n# Në [[matematikë]], kardinaliteti i një bashkësie është matja e numrit të elementëve të bashkësisë. P.sh nëse bashkësia A = ( a , b , c , d , e )   {\\displaystyle A=(a,b,c,d,e)}  {\\displaystyle A=(a,b,c,d,e)} përmban 5 elemente, themi që bashkësia A   {\\displaystyle A}  {\\displaystyle A} ka një kardinalitet të barabartë me 5. Kardinaliteti shënohet me |  A |    {\\displaystyle |A|}  {\\displaystyle |A|}, dy vija vertikale në anet e emrit të bashkësisë. Ka të njëjtin simbol matematikor me vlerën absolute, por kuptimi varet nga konteksi i përdorimit. \n\n[[Kategoria:Matematikë shqip]]";
    const reference_source = "<div class=\"sister-wikipedia\"><div class=\"sister-project\"><div class=\"noprint\" style=\"clear: right; border: solid #aaa 1px; margin: 0 0 1em 1em; font-size: 90%; width: 250px; padding: 4px; text-align: left; float: right;\"> \n<div style=\"float: left;\"><div style=\"position: relative; width: 50px; height: 50px; overflow: hidden\">\n<div style=\"position: absolute; top: 0px; left: 0px; font-size: 100px; overflow: hidden; line-height: 100px; z-index: 3\">[[w:sq:Faqja Kryesore|&nbsp;&nbsp;&nbsp;]]</div>\n<div style=\"position: absolute; top: 0px; left: 0px; z-index: 2\">[[Image:Wikipedia-logo-en.png|50px|w:sq:Faqja Kryesore]]</div>\n</div></div>\n<div style=\"margin-left: 60px;\">[[w:sq:Wikipedia|Wikipedia]] ka një artikull për fjalën: <div style=\"margin-left: 10px;\">'''''[[w:Kardinalitet|Kardinalitet]]'''''</div>\n</div>\n</div>\n</div></div></span>\n==Shqip==\n===Emër===\n'''kardinalitet''' m.\n# Në [[matematikë]], kardinaliteti i një bashkësie është matja e numrit të elementëve të bashkësisë. P.sh nëse bashkësia A = ( a , b , c , d , e )   {\\displaystyle A=(a,b,c,d,e)}  {\\displaystyle A=(a,b,c,d,e)} përmban 5 elemente, themi që bashkësia A   {\\displaystyle A}  {\\displaystyle A} ka një kardinalitet të barabartë me 5. Kardinaliteti shënohet me |  A |    {\\displaystyle |A<nowiki>|}</nowiki>  {\\displaystyle |A<nowiki>|}</nowiki>, dy vija vertikale në anet e emrit të bashkësisë. Ka të njëjtin simbol matematikor me vlerën absolute, por kuptimi varet nga konteksi i përdorimit. \n\n[[Kategoria:Matematikë shqip]]";
    try std.testing.expectEqual(@as(usize, 1504), source.len);
    var actual_report: Fallbacks = .{};
    var reference_report: Fallbacks = .{};
    const actual = try compileReportedAlloc(a, "kardinalitet", .language, "Shqip", "sq", source, null, &actual_report);
    const expected = try compileReportedAlloc(a, "kardinalitet", .language, "Shqip", "sq", reference_source, null, &reference_report);
    try std.testing.expectEqualSlices(u8, expected, actual);
    const stored = try codec.decodeAlloc(a, actual, "kardinalitet", .language, .{ .code = "sq", .heading = "Shqip" });
    try std.testing.expectEqualSlices(u8, actual, try codec.encodeAlloc(a, stored));
}


test "complete retained MN deluun malformed attributed text preserves body style actions and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "[[Category:Монголоор]]__NOEDITSECTION__\n==<div id=\"toc\" class=\"toccolours\" ><big><big><big>[[Image:Flag of Mongolia.svg|border|35px]] Монголоор </big></big></big></div>==\n<br>\n===Дуудлага===\n[delь:] (дэлигүү)\n===Үгийн утга===\n'''дэлүү(н) I''' ''нэр.''<br />\n&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; 1. биезүй. Цус төлжүүлэх болон эсийн дархлаанд чухал үүрэг гүйцэтгэдэг, хэвлийн зүүн дээд хэсэгт байрлах, цулцан эрхтэн<br />\n&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; 2. ''анагаах.'' Дэлүү үрэвсэж өвчлөх өвчин<br />\n===Шилжсэн утга===\n\n===Холбоо үг===\n*'''дэлүү''' томрох ''анагаах.'' (дэлүү хөөх өвчин) \n*'''дэлүү''' тусах (дэлүү өвчлөх)\n\n===Хоршоо үг===\n\n===Эсрэг үг===\n\n===Зүйр цэцэн үг===\n*дэлбэ алгадаж '''дэлүү''' наах, шалба алгадаж шаварнаах ''зүйр.'' (ширүүлэн хатуурхсанаа зөөлрөн аргадах)\n\n===Хэвшмэл хэлц===\n\n\n===Өвөрмөц хэлц===\n\n===Зөв бичих зүй===\n*дэ|лүү(н) нэр ~ өвчлөх, дэлүүний, дэ­лүүнд, дэлүүнээс\n===Ертөнцийн гурав===\n===Монгол бичиг===\nght:60px;\"><spandiv style=\"w<idth:10px; hei style=\"display:block;-webkit-transform: rotate(90deg); -moz-transform: rotate(90deg);\"><font  face=\"CMs Ulaanbaatar\" size=\"6\"></font></span></div>\n\n\n===Хуучирсан үг===";
    const reference_source = "[[Category:Монголоор]]__NOEDITSECTION__\n==<div id=\"toc\" class=\"toccolours\" ><big><big><big>[[Image:Flag of Mongolia.svg|border|35px]] Монголоор </big></big></big></div>==\n<br>\n===Дуудлага===\n[delь:] (дэлигүү)\n===Үгийн утга===\n'''дэлүү(н) I''' ''нэр.''<br />\n&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; 1. биезүй. Цус төлжүүлэх болон эсийн дархлаанд чухал үүрэг гүйцэтгэдэг, хэвлийн зүүн дээд хэсэгт байрлах, цулцан эрхтэн<br />\n&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; 2. ''анагаах.'' Дэлүү үрэвсэж өвчлөх өвчин<br />\n===Шилжсэн утга===\n\n===Холбоо үг===\n*'''дэлүү''' томрох ''анагаах.'' (дэлүү хөөх өвчин) \n*'''дэлүү''' тусах (дэлүү өвчлөх)\n\n===Хоршоо үг===\n\n===Эсрэг үг===\n\n===Зүйр цэцэн үг===\n*дэлбэ алгадаж '''дэлүү''' наах, шалба алгадаж шаварнаах ''зүйр.'' (ширүүлэн хатуурхсанаа зөөлрөн аргадах)\n\n===Хэвшмэл хэлц===\n\n\n===Өвөрмөц хэлц===\n\n===Зөв бичих зүй===\n*дэ|лүү(н) нэр ~ өвчлөх, дэлүүний, дэ­лүүнд, дэлүүнээс\n===Ертөнцийн гурав===\n===Монгол бичиг===\nght:60px;\">&lt;spandiv style=\"w&lt;idth:10px; hei style=\"display:block;-webkit-transform: rotate(90deg); -moz-transform: rotate(90deg);\"&gt;<font  face=\"CMs Ulaanbaatar\" size=\"6\"></font></span></div>\n\n\n===Хуучирсан үг===";
    try std.testing.expectEqual(@as(usize, 1639), source.len);
    var actual_report: Fallbacks = .{};
    var reference_report: Fallbacks = .{};
    const actual = try compileReportedAlloc(a, "дэлүүн", .language, "Монголоор", "mn", source, null, &actual_report);
    const expected = try compileReportedAlloc(a, "дэлүүн", .language, "Монголоор", "mn", reference_source, null, &reference_report);
    try std.testing.expectEqualSlices(u8, expected, actual);
    try std.testing.expect(actual_report.literal_markup);
    const stored = try codec.decodeAlloc(a, actual, "дэлүүн", .language, .{ .code = "mn", .heading = "Монголоор" });
    try std.testing.expectEqualSlices(u8, actual, try codec.encodeAlloc(a, stored));
}


test "complete retained KA globus malformed citation preserves body actions styles and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "== ქართული==\n=== გლობუსი ===\n[[ფაილი:Moscow SHM asv2019-06 img17.jpg|მინი]]\n[[ფაილი:20110726 Celestial globe Museo Milan 6151.jpg|მინი]]\n==== ეტიმოლოგია ====\nნასესხებია [[ლათინური]] სიტყვიდან ''[[globus]]''[[კატეგორია:ლათინური ეტიმოლოგიის სიტყვები (ქართული)]] „[[ბურთი]]“.   \n\n==== წაკითხვა ====\n* <span style=\"text-decoration: none; font-size: 80%;\">[[w:IPA ნიშნების სია|ფონეტიკური ტრანსლიტერაცია (IPA)]]:</span> [ɡlɔbusi]\n* <span style=\"text-decoration: none; font-size: 80%;\">[[დახმარება:აუდიო მაგალითები|აუდიო მაგალითი]]:</span> <span class=\"audiolink\">[[:Media:ka-გლობუსი.ogg|გლობუსი]]</span> <sup>[[:ფაილი:ka-გლობუსი.ogg|?]]</sup>\n* დამარცვლა: გლო<span style=\"color:FireBrick;\">'''·'''</span>ბუ<span style=\"color:FireBrick;\">'''·'''</span>სი, მრ. რ. გლო<span style=\"color:FireBrick;\">'''·'''</span>ბუ<span style=\"color:FireBrick;\">'''·'''</span>სე<span style=\"color:FireBrick;\">'''·'''</span>ბი, გლო<span style=\"color:FireBrick;\">'''·'''</span>ბუს<span style=\"color:FireBrick;\">'''·'''</span>ნი \n* <span style=\"text-decoration: none; font-size: 80%;\">პარონიმები:</span> [[გლობული]]\n\n==== მნიშვნელობა ====\n===== [[დახმარება:ლექსიკური ერთეულის კატეგორიები|არსებითი სახელი]][[კატეგორია:ქართული ენა]][[კატეგორია:არსებითი სახელი (ქართული)]] =====\n{| role=\"presentation\" class=\"mw-collapsible mw-collapsed\" data-expandtext=\"▼ ბრუნება სრულად\" data-collapsetext=\"▲ ნაკლების ჩვენება\"\n|-\n| <span style=\"color:#009999\">➤ '''გლობუს'''-ი, '''''გლობუს'''-ის(ა)'', <span style=\"text-decoration: none; font-size: 80%;\">[[:w:მრავლობითი რიცხვი|მრავლობითი:]]</span> '''''გლობუს'''-ებ-ი, '''გლობუს'''-ნ-ი''</span> &nbsp;&nbsp;&nbsp;\n|-\n|\n{| style=\"float:right; clear:right; margin-left:0,5em; margin-bottom0,5em; border: 2px solid #ffffff; border-collapse:collapse;\" cellpadding=\"4\" rules=\"all\" \n|-\n! bgcolor=\"#d0e5f5\"  | [[ბრუნვა]]\n! bgcolor=\"#d0e5f5\"  | [[მხოლობითი]]\n! bgcolor=\"#d0e5f5\" colspan=\"2\" | [[მრავლობითი]]\n|-\n| bgcolor=\"#d0e5f5\" | <p style=\"text-align:right;\"><small>[[სახელობითი]]</small></p>\n| bgcolor=\"#f1f5fc\" |  [[გლობუსი]] \n| bgcolor=\"#f1f5fc\" | [[გლობუსები]] \n| bgcolor=\"#f1f5fc\" | [[გლობუსნი]] \n|-\n| bgcolor=\"#d0e5f5\" | <p style=\"text-align:right;\"><small>[[მოთხრობითი]]</small></p>\n| bgcolor=\"#f1f5fc\" |  [[გლობუსმა]] \n| bgcolor=\"#f1f5fc\" | [[გლობუსებმა]]\n| bgcolor=\"#f1f5fc\" | [[გლობუსთ]] / [[გლობუსთა]] \n|-\n| bgcolor=\"#d0e5f5\" | <p style=\"text-align:right;\"><small>[[მიცემითი]]</small></p>\n| bgcolor=\"#f1f5fc\" |  [[გლობუსს]] / [[გლობუსსა]] \n| bgcolor=\"#f1f5fc\" | [[გლობუსებს]] / [[გლობუსებსა]] \n| bgcolor=\"#f1f5fc\" | [[გლობუსთ]] / [[გლობუსთა]] \n|-\n| bgcolor=\"#d0e5f5\" | <p style=\"text-align:right;\"><small>[[ნათესაობითი]]</small></p>\n| bgcolor=\"#f1f5fc\" |  [[გლობუსის]] / [[გლობუსისა]] \n| bgcolor=\"#f1f5fc\" | [[გლობუსების]] / [[გლობუსებისა]] \n| bgcolor=\"#f1f5fc\" | [[გლობუსთ]] / [[გლობუსთა]] \n|-\n| bgcolor=\"#d0e5f5\" | <p style=\"text-align:right;\"><small>[[მოქმედებითი]]</small></p>\n| bgcolor=\"#f1f5fc\" |  [[გლობუსით]] / [[გლობუსითა]] \n| bgcolor=\"#f1f5fc\" | [[გლობუსებით]] / [[გლობუსებითა]] \n|-\n| bgcolor=\"#d0e5f5\" | <p style=\"text-align:right;\"><small>[[ვითარებითი]]</small></p>\n| bgcolor=\"#f1f5fc\" |  [[გლობუსად]] / [[გლობუსადა]] \n| bgcolor=\"#f1f5fc\" | [[გლობუსებად]] / [[გლობუსებადა]] \n|-\n| bgcolor=\"#d0e5f5\" | <p style=\"text-align:right;\"><small>[[წოდებითი]]</small></p>\n| bgcolor=\"#f1f5fc\" |  [[გლობუსო]]\n| bgcolor=\"#f1f5fc\" | [[გლობუსებო]] \n| bgcolor=\"#f1f5fc\" | [[გლობუსნო]] \n|-\n| bgcolor=\"#d0e5f5\" colspan=\"4\" | ''ყველა სხვა ფორმა იხილეთ '''[[ფორმაწარმოება:გლობუსი|ფორმაწარმოების გვერდზე]]'''''\n|}\n|}[[კატეგორია:ქართული ენა]][[კატეგორია:არსებითი სახელი (ქართული)]]\n# [[დედამიწა|დედამიწის]] [[მოდელი]] [[მცირე]] [[მასშტაბი|მასშტაბისა]] (ჩვეულებისამებრ, [[ღერძი|ღერძზე]] [[მბრუნავი]]). \n#: \n#:<span style=\"font-size: 80%;\"><div class=\"mw-collapsible mw-collapsed\" data-expandtext=\"➤ ციტატების გაშლა\" data-collapsetext=\"▼ ციტატების დახურვა\">\n#:*    [[კატეგორია:ციტატები აკლია (ქართული)]]''ამ მნიშვნელობისათვის [[:კატეგორია:ციტატები აკლია (ქართული)|ციტატები არ გვაქვს.]] დაგვეხმარეთ მოძიებაში.''\n#::\n#:</div></span>\n#:  \n#:  \n#:  \n#:  \n#:  \n#:  \n\n==== წარმოებული ლექსიკა ====\n: \n:\n:\n:\n\n==== თარგმანები ====\n<div class=\"NavFrame\" >\n<div class=\"NavHead\" style=\"text-align:left; \"> \n&nbsp;</div>\n<div class=\"NavContent\">\n{| class=\"translations\" role=\"presentation\" style=\"width:100%;\"\n|-\n| class=\"translations-cell\" style=\"background-color:#ffffe0; vertical-align:top; width:48%; text-align:left; \" |\n<div style=\"column-count: 2;\">\n\n* [[ბერძნული]]: <span class=\"Grek\" lang=\"el\">[[υδρόγειος σφαίρα#Greek|υδρόγειος σφαίρα]]</span><span class=\"tpos\">&nbsp;[[:el:υδρόγειος σφαίρα|(el)]]</span>&nbsp;<span class=\"gender\"><small><i><abbr title=\"მდედრობითი სქესი\">მდედრ.</abbr></i></small></small> <span class=\"mention-gloss-paren annotation-paren\">(</span><span lang=\"el-Latn\" class=\"tr Latn\">ydrógeios sfaíra</span><span class=\"mention-gloss-paren annotation-paren\">)</span>\n* [[გერმანული]]: <span class=\"Latn\" lang=\"de\">[[Globus#German|Globus]]</span><span class=\"tpos\">&nbsp;[[:de:Globus|(de)]]</span>&nbsp;<span class=\"gender\"><small><i><abbr title=\"მამრობითი სქესი\">მამრ.</abbr></i></small></small>\n* [[ესპანური]]: <span class=\"Latn\" lang=\"es\">[[globo#Spanish|globo]]</span><span class=\"tpos\">&nbsp;[[:es:globo|(es)]]</span>    <span class=\"Latn\" lang=\"es\">[[globo terráqueo#Spanish|globo terráqueo]]</span><span class=\"tpos\">&nbsp;[[:es:globo terráqueo|(es)]]</span>\n* [[თურქული]]: <span class=\"Latn\" lang=\"tr\">[[küre#თურქული|küre]]</span><span class=\"tpos\">&nbsp;[[:tr:küre|(tr)]]</span>,  <span class=\"Latn\" lang=\"tr\">[[yerküre#თურქული|yerküre]]</span><span class=\"tpos\">&nbsp;[[:tr:yerküre|(tr)]]</span>\n* [[ინგლისური]]: <span class=\"Latn\" lang=\"en\">[[globe#English|globe]]</span><span class=\"tpos\">&nbsp;[[:en:globe|(en)]]</span>\n* [[იტალიური]]: <span class=\"Latn\" lang=\"it\">[[globo#Italian|globo]]</span><span class=\"tpos\">&nbsp;[[:it:globo|(it)]]</span>\n* [[პოლონური]]: <span class=\"Latn\" lang=\"pl\">[[globus#Polish|globus]]</span><span class=\"tpos\">&nbsp;[[:pl:globus|(pl)]]</span>\n* [[პორტუგალიური]]: <span class=\"Latn\" lang=\"pt\">[[globo#Portuguese|globo]]</span><span class=\"tpos\">&nbsp;[[:pt:globo|(pt)]]</span>\n* [[რუსული]]: <span class=\"Cyrl\" lang=\"ru\">[[глобус#რუსული|гло́бус]]</span><span class=\"tpos\">&nbsp;[[:ru:глобус|(ru)]]</span>&nbsp;<span class=\"gender\"><small><i><abbr title=\"მამრობითი სქესი\">მამრ.</abbr></i></small></small> <span class=\"mention-gloss-paren annotation-paren\">(</span><span lang=\"ru-Latn\" class=\"tr Latn\">glóbus</span><span class=\"mention-gloss-paren annotation-paren\">)</span>\n* [[ფრანგული]]: <span class=\"Latn\" lang=\"fr\">[[globe#French|globe]]</span><span class=\"tpos\">&nbsp;[[:fr:globe|(fr)]]</span>\n* [[შვედური]]: <span class=\"Latn\" lang=\"sv\">[[glob#Swedish|glob]]</span><span class=\"tpos\">&nbsp;[[:sv:glob|(sv)]]</span>&nbsp;<span class=\"gender\"><small><i><abbr title=\"საერთო სქესი\">საერთ.</abbr></i></small></small>    <span class=\"Latn\" lang=\"sv\">[[jordglob#Swedish|jordglob]]</span><span class=\"tpos\">&nbsp;[[:sv:jordglob|(sv)]]</span>&nbsp;<span class=\"gender\"><small><i><abbr title=\"საერთო სქესი\">საერთ.</abbr></i></small></small>\n</div>\n|}\n</div></div>\n\n==== წყაროები და რესურსები ====\n* [[ფაილი:Searchtool.svg|15px]] [[w:ქართული ენის განმარტებითი ლექსიკონი|ქართული ენის განმარტებითი ლექსიკონი]], ტომი 2, გვერდი 1561, <span title=\"საქართველოს სსრ მეცნიერებათა აკადემიის გამომცემლობა\" style=\"border-bottom: 1px dotted; cursor: help; white-space: nowrap\">თბილისი</span>, 2010 [[წელი]].\n* [[ფაილი:Wikipedia-logo.png|15px]] იხილეთ '''[[ქართული]]''' '''[[w:ka:|ვიკიპედიის]]''' სტატია „'''[[Wikipedia:ka:გლობუსი|გლობუსი]]'''“\n* [http://www.ena.ge/explanatory-online?ls=YToyOntzOjEyOiJ3b3JkX21ldGF1cmkiO3M6MTk6IuGDkuGDmuGDneGDkeGDo+GDoSAiO3M6MTE6IndvcmRfc3RhdGlhIjtzOjA6IiI7fQ== „გლობუსი“ ქართული ენის განმარტებით ონლაინ-ლექსიკონში]\n*[[ფაილი:Searchtool.svg|15px]] ქართული ენის ორთოგრაფიული ლექსიკონი, [[w:ვარლამ თოფურია|ვარლამ თოფურია]],    [[w:ივანე გიგინეიშვილი|ივანე გიგინეიშვილი]], თბილისი „განათლება“, 1998, გვ. 190\n\n*{{საჯარო მოხელის ორთოგრაფიულ-სტილისტიკური ლექსიკონი |2022|}235}\n*[[ფაილი:Searchtool.svg|15px]] [[w:მიხეილ ჭაბაშვილი|''ჭაბაშვილი მ.'']], უცხო სიტყვათა ლექსიკონი, თბილისი, 1989, გვ. 107.\n";
    const reference_source = "== ქართული==\n=== გლობუსი ===\n[[ფაილი:Moscow SHM asv2019-06 img17.jpg|მინი]]\n[[ფაილი:20110726 Celestial globe Museo Milan 6151.jpg|მინი]]\n==== ეტიმოლოგია ====\nნასესხებია [[ლათინური]] სიტყვიდან ''[[globus]]''[[კატეგორია:ლათინური ეტიმოლოგიის სიტყვები (ქართული)]] „[[ბურთი]]“.   \n\n==== წაკითხვა ====\n* <span style=\"text-decoration: none; font-size: 80%;\">[[w:IPA ნიშნების სია|ფონეტიკური ტრანსლიტერაცია (IPA)]]:</span> [ɡlɔbusi]\n* <span style=\"text-decoration: none; font-size: 80%;\">[[დახმარება:აუდიო მაგალითები|აუდიო მაგალითი]]:</span> <span class=\"audiolink\">[[:Media:ka-გლობუსი.ogg|გლობუსი]]</span> <sup>[[:ფაილი:ka-გლობუსი.ogg|?]]</sup>\n* დამარცვლა: გლო<span style=\"color:FireBrick;\">'''·'''</span>ბუ<span style=\"color:FireBrick;\">'''·'''</span>სი, მრ. რ. გლო<span style=\"color:FireBrick;\">'''·'''</span>ბუ<span style=\"color:FireBrick;\">'''·'''</span>სე<span style=\"color:FireBrick;\">'''·'''</span>ბი, გლო<span style=\"color:FireBrick;\">'''·'''</span>ბუს<span style=\"color:FireBrick;\">'''·'''</span>ნი \n* <span style=\"text-decoration: none; font-size: 80%;\">პარონიმები:</span> [[გლობული]]\n\n==== მნიშვნელობა ====\n===== [[დახმარება:ლექსიკური ერთეულის კატეგორიები|არსებითი სახელი]][[კატეგორია:ქართული ენა]][[კატეგორია:არსებითი სახელი (ქართული)]] =====\n{| role=\"presentation\" class=\"mw-collapsible mw-collapsed\" data-expandtext=\"▼ ბრუნება სრულად\" data-collapsetext=\"▲ ნაკლების ჩვენება\"\n|-\n| <span style=\"color:#009999\">➤ '''გლობუს'''-ი, '''''გლობუს'''-ის(ა)'', <span style=\"text-decoration: none; font-size: 80%;\">[[:w:მრავლობითი რიცხვი|მრავლობითი:]]</span> '''''გლობუს'''-ებ-ი, '''გლობუს'''-ნ-ი''</span> &nbsp;&nbsp;&nbsp;\n|-\n|\n{| style=\"float:right; clear:right; margin-left:0,5em; margin-bottom0,5em; border: 2px solid #ffffff; border-collapse:collapse;\" cellpadding=\"4\" rules=\"all\" \n|-\n! bgcolor=\"#d0e5f5\"  | [[ბრუნვა]]\n! bgcolor=\"#d0e5f5\"  | [[მხოლობითი]]\n! bgcolor=\"#d0e5f5\" colspan=\"2\" | [[მრავლობითი]]\n|-\n| bgcolor=\"#d0e5f5\" | <p style=\"text-align:right;\"><small>[[სახელობითი]]</small></p>\n| bgcolor=\"#f1f5fc\" |  [[გლობუსი]] \n| bgcolor=\"#f1f5fc\" | [[გლობუსები]] \n| bgcolor=\"#f1f5fc\" | [[გლობუსნი]] \n|-\n| bgcolor=\"#d0e5f5\" | <p style=\"text-align:right;\"><small>[[მოთხრობითი]]</small></p>\n| bgcolor=\"#f1f5fc\" |  [[გლობუსმა]] \n| bgcolor=\"#f1f5fc\" | [[გლობუსებმა]]\n| bgcolor=\"#f1f5fc\" | [[გლობუსთ]] / [[გლობუსთა]] \n|-\n| bgcolor=\"#d0e5f5\" | <p style=\"text-align:right;\"><small>[[მიცემითი]]</small></p>\n| bgcolor=\"#f1f5fc\" |  [[გლობუსს]] / [[გლობუსსა]] \n| bgcolor=\"#f1f5fc\" | [[გლობუსებს]] / [[გლობუსებსა]] \n| bgcolor=\"#f1f5fc\" | [[გლობუსთ]] / [[გლობუსთა]] \n|-\n| bgcolor=\"#d0e5f5\" | <p style=\"text-align:right;\"><small>[[ნათესაობითი]]</small></p>\n| bgcolor=\"#f1f5fc\" |  [[გლობუსის]] / [[გლობუსისა]] \n| bgcolor=\"#f1f5fc\" | [[გლობუსების]] / [[გლობუსებისა]] \n| bgcolor=\"#f1f5fc\" | [[გლობუსთ]] / [[გლობუსთა]] \n|-\n| bgcolor=\"#d0e5f5\" | <p style=\"text-align:right;\"><small>[[მოქმედებითი]]</small></p>\n| bgcolor=\"#f1f5fc\" |  [[გლობუსით]] / [[გლობუსითა]] \n| bgcolor=\"#f1f5fc\" | [[გლობუსებით]] / [[გლობუსებითა]] \n|-\n| bgcolor=\"#d0e5f5\" | <p style=\"text-align:right;\"><small>[[ვითარებითი]]</small></p>\n| bgcolor=\"#f1f5fc\" |  [[გლობუსად]] / [[გლობუსადა]] \n| bgcolor=\"#f1f5fc\" | [[გლობუსებად]] / [[გლობუსებადა]] \n|-\n| bgcolor=\"#d0e5f5\" | <p style=\"text-align:right;\"><small>[[წოდებითი]]</small></p>\n| bgcolor=\"#f1f5fc\" |  [[გლობუსო]]\n| bgcolor=\"#f1f5fc\" | [[გლობუსებო]] \n| bgcolor=\"#f1f5fc\" | [[გლობუსნო]] \n|-\n| bgcolor=\"#d0e5f5\" colspan=\"4\" | ''ყველა სხვა ფორმა იხილეთ '''[[ფორმაწარმოება:გლობუსი|ფორმაწარმოების გვერდზე]]'''''\n|}\n|}[[კატეგორია:ქართული ენა]][[კატეგორია:არსებითი სახელი (ქართული)]]\n# [[დედამიწა|დედამიწის]] [[მოდელი]] [[მცირე]] [[მასშტაბი|მასშტაბისა]] (ჩვეულებისამებრ, [[ღერძი|ღერძზე]] [[მბრუნავი]]). \n#: \n#:<span style=\"font-size: 80%;\"><div class=\"mw-collapsible mw-collapsed\" data-expandtext=\"➤ ციტატების გაშლა\" data-collapsetext=\"▼ ციტატების დახურვა\">\n#:*    [[კატეგორია:ციტატები აკლია (ქართული)]]''ამ მნიშვნელობისათვის [[:კატეგორია:ციტატები აკლია (ქართული)|ციტატები არ გვაქვს.]] დაგვეხმარეთ მოძიებაში.''\n#::\n#:</div></span>\n#:  \n#:  \n#:  \n#:  \n#:  \n#:  \n\n==== წარმოებული ლექსიკა ====\n: \n:\n:\n:\n\n==== თარგმანები ====\n<div class=\"NavFrame\" >\n<div class=\"NavHead\" style=\"text-align:left; \"> \n&nbsp;</div>\n<div class=\"NavContent\">\n{| class=\"translations\" role=\"presentation\" style=\"width:100%;\"\n|-\n| class=\"translations-cell\" style=\"background-color:#ffffe0; vertical-align:top; width:48%; text-align:left; \" |\n<div style=\"column-count: 2;\">\n\n* [[ბერძნული]]: <span class=\"Grek\" lang=\"el\">[[υδρόγειος σφαίρα#Greek|υδρόγειος σφαίρα]]</span><span class=\"tpos\">&nbsp;[[:el:υδρόγειος σφαίρα|(el)]]</span>&nbsp;<span class=\"gender\"><small><i><abbr title=\"მდედრობითი სქესი\">მდედრ.</abbr></i></small></small> <span class=\"mention-gloss-paren annotation-paren\">(</span><span lang=\"el-Latn\" class=\"tr Latn\">ydrógeios sfaíra</span><span class=\"mention-gloss-paren annotation-paren\">)</span>\n* [[გერმანული]]: <span class=\"Latn\" lang=\"de\">[[Globus#German|Globus]]</span><span class=\"tpos\">&nbsp;[[:de:Globus|(de)]]</span>&nbsp;<span class=\"gender\"><small><i><abbr title=\"მამრობითი სქესი\">მამრ.</abbr></i></small></small>\n* [[ესპანური]]: <span class=\"Latn\" lang=\"es\">[[globo#Spanish|globo]]</span><span class=\"tpos\">&nbsp;[[:es:globo|(es)]]</span>    <span class=\"Latn\" lang=\"es\">[[globo terráqueo#Spanish|globo terráqueo]]</span><span class=\"tpos\">&nbsp;[[:es:globo terráqueo|(es)]]</span>\n* [[თურქული]]: <span class=\"Latn\" lang=\"tr\">[[küre#თურქული|küre]]</span><span class=\"tpos\">&nbsp;[[:tr:küre|(tr)]]</span>,  <span class=\"Latn\" lang=\"tr\">[[yerküre#თურქული|yerküre]]</span><span class=\"tpos\">&nbsp;[[:tr:yerküre|(tr)]]</span>\n* [[ინგლისური]]: <span class=\"Latn\" lang=\"en\">[[globe#English|globe]]</span><span class=\"tpos\">&nbsp;[[:en:globe|(en)]]</span>\n* [[იტალიური]]: <span class=\"Latn\" lang=\"it\">[[globo#Italian|globo]]</span><span class=\"tpos\">&nbsp;[[:it:globo|(it)]]</span>\n* [[პოლონური]]: <span class=\"Latn\" lang=\"pl\">[[globus#Polish|globus]]</span><span class=\"tpos\">&nbsp;[[:pl:globus|(pl)]]</span>\n* [[პორტუგალიური]]: <span class=\"Latn\" lang=\"pt\">[[globo#Portuguese|globo]]</span><span class=\"tpos\">&nbsp;[[:pt:globo|(pt)]]</span>\n* [[რუსული]]: <span class=\"Cyrl\" lang=\"ru\">[[глобус#რუსული|гло́бус]]</span><span class=\"tpos\">&nbsp;[[:ru:глобус|(ru)]]</span>&nbsp;<span class=\"gender\"><small><i><abbr title=\"მამრობითი სქესი\">მამრ.</abbr></i></small></small> <span class=\"mention-gloss-paren annotation-paren\">(</span><span lang=\"ru-Latn\" class=\"tr Latn\">glóbus</span><span class=\"mention-gloss-paren annotation-paren\">)</span>\n* [[ფრანგული]]: <span class=\"Latn\" lang=\"fr\">[[globe#French|globe]]</span><span class=\"tpos\">&nbsp;[[:fr:globe|(fr)]]</span>\n* [[შვედური]]: <span class=\"Latn\" lang=\"sv\">[[glob#Swedish|glob]]</span><span class=\"tpos\">&nbsp;[[:sv:glob|(sv)]]</span>&nbsp;<span class=\"gender\"><small><i><abbr title=\"საერთო სქესი\">საერთ.</abbr></i></small></small>    <span class=\"Latn\" lang=\"sv\">[[jordglob#Swedish|jordglob]]</span><span class=\"tpos\">&nbsp;[[:sv:jordglob|(sv)]]</span>&nbsp;<span class=\"gender\"><small><i><abbr title=\"საერთო სქესი\">საერთ.</abbr></i></small></small>\n</div>\n|}\n</div></div>\n\n==== წყაროები და რესურსები ====\n* [[ფაილი:Searchtool.svg|15px]] [[w:ქართული ენის განმარტებითი ლექსიკონი|ქართული ენის განმარტებითი ლექსიკონი]], ტომი 2, გვერდი 1561, <span title=\"საქართველოს სსრ მეცნიერებათა აკადემიის გამომცემლობა\" style=\"border-bottom: 1px dotted; cursor: help; white-space: nowrap\">თბილისი</span>, 2010 [[წელი]].\n* [[ფაილი:Wikipedia-logo.png|15px]] იხილეთ '''[[ქართული]]''' '''[[w:ka:|ვიკიპედიის]]''' სტატია „'''[[Wikipedia:ka:გლობუსი|გლობუსი]]'''“\n* [http://www.ena.ge/explanatory-online?ls=YToyOntzOjEyOiJ3b3JkX21ldGF1cmkiO3M6MTk6IuGDkuGDmuGDneGDkeGDo+GDoSAiO3M6MTE6IndvcmRfc3RhdGlhIjtzOjA6IiI7fQ== „გლობუსი“ ქართული ენის განმარტებით ონლაინ-ლექსიკონში]\n*[[ფაილი:Searchtool.svg|15px]] ქართული ენის ორთოგრაფიული ლექსიკონი, [[w:ვარლამ თოფურია|ვარლამ თოფურია]],    [[w:ივანე გიგინეიშვილი|ივანე გიგინეიშვილი]], თბილისი „განათლება“, 1998, გვ. 190\n\n*<nowiki>{{საჯარო მოხელის ორთოგრაფიულ-სტილისტიკური ლექსიკონი |2022|}</nowiki>235}\n*[[ფაილი:Searchtool.svg|15px]] [[w:მიხეილ ჭაბაშვილი|''ჭაბაშვილი მ.'']], უცხო სიტყვათა ლექსიკონი, თბილისი, 1989, გვ. 107.\n";
    try std.testing.expectEqual(@as(usize, 11975), source.len);
    var actual_report: Fallbacks = .{};
    var expected_report: Fallbacks = .{};
    const actual = try compileReportedAlloc(a, "გლობუსი", .language, "ქართული", "ka", source, null, &actual_report);
    const expected = try compileReportedAlloc(a, "გლობუსი", .language, "ქართული", "ka", reference_source, null, &expected_report);
    try std.testing.expectEqualSlices(u8, expected, actual);
    try std.testing.expect(actual_report.literal_markup);
    const stored = try codec.decodeAlloc(a, actual, "გლობუსი", .language, .{ .code = "ka", .heading = "ქართული" });
    try std.testing.expectEqualSlices(u8, actual, try codec.encodeAlloc(a, stored));
}

test "complete retained SL piacy opening seam keeps conjugation body actions and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "==[[File:Flag of Belarus (1918, 1991–1995).svg|50px|link=]] Beloruščina==\n\n\n<div class=\"NavFrame\" style=\"width:48em\">\n<div class=\"NavHead\" style=\"background:#d9ebff\" >&nbsp; &nbsp; Spregatev besede '''пячы'''</small></div>\n<div class=\"NavContent\">\n\n{| class=\"inflection-table\" style=\"border-collapse:collapse; background:#F9F9F9; text-align:center; width:48em\"\n! style=\"background:eff7ff\" | \n! colspan=\"1\" style=\"background:#eff7ff\" | sedanji čas\n! colspan=\"1\" style=\"background:#eff7ff\" | velelnik\n! colspan=\"1\" style=\"background:#eff7ff\" | pretekli čas\n|-\n! style=\"eff7ff\" | prva oseba (ednina)\n| пяку\n|\n|-\n! style=\"eff7ff\" | druga oseba (ednina)\n| пячэш\n| пячы\n|-\n! style=\"eff7ff\" | tretja oseba (ednina)\n| пячэ\n|\n|-\n! style=\"eff7ff\" | prva oseba (množina)\n| пячом\n|\n|-\n! style=\"eff7ff\" | druga oseba (množina)\n| печаце\n| пячыце\n|-\n! style=\"eff7ff\" | tretja oseba (množina)\n| пякуць\n|\n|-\n! style=\"eff7ff\" | moški rod\n|\n|\n| пёк\n|-\n! style=\"eff7ff\" | ženski rod\n|\n|\n| пякла\n|-\n! style=\"eff7ff\" | srednji rod\n|\n|\n| пякло\n|-\n! style=\"eff7ff\" | množina\n|\n|\n| пяклі\n|\n|}</div></div>\n\n''пячы, [[glagol]]''[[Kategorija:Beloruski glagoli]],&#32;[[nedovršen]][[Kategorija:Belorusk nedovršni glagoli]]\n\n<p style=\"margin-bottom: -0.3em;\">'''Transkripcija:'''\n\n*pjačy\n\n<p style=\"margin-bottom: -0.3em; margin-top: 0.7em\">'''Pomeni:'''\n\n#[[peči]]\n\n<p style=\"margin-bottom: -0.3em;\">'''Izgovarjava:'''\n\n*[[:en:Appendix:Slovene_pronunciation|IPA]]: [<span class=\"IPA\">[pʲaˈt͡ʂɨ</span>]\n\n<p style=\"margin-bottom: -0.3em;\">'''Protipomenke:'''\n\n:[[сьпячы]]\n\n<p style=\"margin-bottom: -0.3em;\">'''Besedne zveze:'''\n\n:[[пекар]], [[пячэнне]], [[адпячы]], [[дапячы]], [[напячы]], [[падпячы]], [[папячы]], [[перапячы]], [[прапячы]], [[расьпячы]], [[упячы]]\n\n<p style=\"margin-bottom: -0.3em;\">'''Zunanje povezave:'''</p>\n*Энцыкляпэдыя электронная „[http://www.slounik.org/search?dict=&search=пячы пячы]“<br />";
    const namespace_source = "# wikidict-namespace-registry-v1\n# wiki\tslwiktionary\n# dump-date\t20261001\n# content-language\tsl\n-2\tDatoteka\tMedia\tcase-sensitive\t0\t0\t0\t\tcompile_only\tvirtual_namespace\n-1\tPosebno\tSpecial\tfirst-letter\t0\t0\t0\t\tcompile_only\tvirtual_namespace\n0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tdictionary_entries\n1\tPogovor\tTalk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n2\tUporabnik\tUser\tfirst-letter\t1\t0\t0\t\tcompile_only\tstandard_build_input\n3\tUporabniški pogovor\tUser talk\tfirst-letter\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n4\tWikislovar\tProject\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\tWT\tWiktionary\n5\tPogovor o Wikislovarju\tProject talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tWiktionary talk\n6\tSlika\tFile\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\tImage\n7\tPogovor o sliki\tFile talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tImage talk\n8\tMediaWiki\tMediaWiki\tfirst-letter\t1\t0\t0\t\tcompile_only\tstandard_build_input\n9\tPogovor o MediaWiki\tMediaWiki talk\tfirst-letter\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n10\tPredloga\tTemplate\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n11\tPogovor o predlogi\tTemplate talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n12\tPomoč\tHelp\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n13\tPogovor o pomoči\tHelp talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n14\tKategorija\tCategory\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\n15\tPogovor o kategoriji\tCategory talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n710\tTimedText\tTimedText\tcase-sensitive\t0\t0\t0\t\tcompile_only\tancillary_site_input\n711\tTimedText talk\tTimedText talk\tcase-sensitive\t0\t0\t0\t\tcompile_only\tdiscussion_namespace\n828\tModul\tModule\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n829\tPogovor o modulu\tModule talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n1728\tEvent\tEvent\tcase-sensitive\t1\t0\t0\t\tcompile_only\tancillary_site_input\n1729\tEvent talk\tEvent talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n";
    try std.testing.expectEqual(@as(usize, 2085), source.len);
    var namespaces = try NamespaceRegistry.init(a, namespace_source);
    defer namespaces.deinit();
    const reference = try std.mem.replaceOwned(u8, a, source, "[<span class=\"IPA\">[", "&#91;<span class=\"IPA\">[");
    var actual_report: Fallbacks = .{};
    var expected_report: Fallbacks = .{};
    const actual = try compileReportedWithLinkTrailAlloc(a, "пячы", .language, "Beloruščina", "be", source, null, .{}, &namespaces, &actual_report);
    const expected = try compileReportedWithLinkTrailAlloc(a, "пячы", .language, "Beloruščina", "be", reference, null, .{}, &namespaces, &expected_report);
    try std.testing.expectEqualSlices(u8, expected, actual);
    try std.testing.expectEqualDeep(expected_report, actual_report);
    const stored = try codec.decodeAlloc(a, actual, "пячы", .language, .{ .code = "be", .heading = "Beloruščina" });
    try std.testing.expectEqualSlices(u8, actual, try codec.encodeAlloc(a, stored));
    var tables: usize = 0;
    var definitions: usize = 0;
    var ipa = false;
    var external: usize = 0;
    for (stored.entry.sections) |section| for (section.blocks) |block| {
        if (block.table != null) tables += 1;
        if (block.kind == .definition) {
            definitions += 1;
            var definition: std.ArrayList(u8) = .empty;
            for (block.spans) |span| try definition.appendSlice(a, span.text);
            try std.testing.expectEqualStrings("peči", definition.items);
        }
        var visible: std.ArrayList(u8) = .empty;
        for (block.spans) |span| {
            try visible.appendSlice(a, span.text);
            if (span.kind == .external_link) {
                external += 1;
                try std.testing.expectEqualStrings("http://www.slounik.org/search?dict=&search=пячы", span.target);
                try std.testing.expectEqualStrings("пячы", span.text);
            }
            if (std.mem.indexOf(u8, span.text, "pʲaˈt͡ʂɨ") != null)
                try std.testing.expect(std.mem.eql(u8, span.classes, "IPA"));
        }
        if (std.mem.indexOf(u8, visible.items, "[[pʲaˈt͡ʂɨ]") != null) ipa = true;
    };
    try std.testing.expectEqual(@as(usize, 1), tables);
    try std.testing.expectEqual(@as(usize, 1), definitions);
    try std.testing.expectEqual(@as(usize, 1), external);
    try std.testing.expect(ipa);
    try std.testing.expectEqual(@as(usize, 0), stored.entry.references.len);
    const raw = [_]compiler.Span{.{ .text = "[[pʲaˈt͡ʂɨ]" }};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &raw, null));
    const unresolved = [_]compiler.Span{.{ .kind = .link, .text = "label", .target = "{{target}}", .provenance = .protected_literal }};
    try std.testing.expectError(error.UncompiledTemplate, validateSpans(a, &unresolved, null));
}

test "complete retained KAA jolawshi dotted quotation preserves body and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "at.Bir jaqqa jol júriwshi,sapar etiwshi adam..Jolawshı jalǵız bolsa,oylanǵısh keledi(<<QQ.x.n.>>). Alıstan kiyatırǵan jolawshılar Aysánemge ap-anıq kórindi(N.Dáwqaraev).";
    try std.testing.expectEqual(@as(usize, 183), source.len);
    const reference = try std.mem.replaceOwned(u8, a, source, "<<QQ.x.n.>>", "&lt;&lt;QQ.x.n.&gt;&gt;");
    var actual_report: Fallbacks = .{};
    var expected_report: Fallbacks = .{};
    const actual = try compileReportedAlloc(a, "jolawshı", .language, "Unclassified", "", source, null, &actual_report);
    const expected = try compileReportedAlloc(a, "jolawshı", .language, "Unclassified", "", reference, null, &expected_report);
    try std.testing.expectEqualSlices(u8, expected, actual);
    try std.testing.expect(actual_report.literal_markup and !expected_report.literal_markup);
    expected_report.literal_markup = true;
    try std.testing.expectEqualDeep(expected_report, actual_report);
    const stored = try codec.decodeAlloc(a, actual, "jolawshı", .language, .{ .code = "", .heading = "Unclassified" });
    try std.testing.expectEqualSlices(u8, actual, try codec.encodeAlloc(a, stored));
    var visible: std.ArrayList(u8) = .empty;
    var blocks: usize = 0;
    for (stored.entry.sections) |section| for (section.blocks) |block| {
        blocks += 1;
        try std.testing.expect(block.kind == .paragraph and block.table == null);
        for (block.spans) |span| {
            try visible.appendSlice(a, span.text);
            try std.testing.expect(span.kind == .text and span.target.len == 0);
        }
    };
    try std.testing.expectEqual(@as(usize, 1), blocks);
    try std.testing.expectEqualStrings(std.mem.trim(u8, source, "\r\n"), visible.items);
    try std.testing.expectEqual(@as(usize, 0), stored.entry.references.len);
    try std.testing.expectEqual(@as(usize, 0), stored.entry.media.len);
    const raw = [_]compiler.Span{.{ .text = "<<QQ.x.n.>>" }};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &raw, null));
    const unresolved = [_]compiler.Span{.{ .kind = .link, .text = "label", .target = "{{target}}", .provenance = .protected_literal }};
    try std.testing.expectError(error.UncompiledTemplate, validateSpans(a, &unresolved, null));
}

test "complete retained MR cross wrapper table preserves body grid styles actions and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "\n==मराठी भाषा==\n<noinclude>*'''शब्दाचे आय.पी.ए. उच्चारण''' : XXXXXX [[वर्ग:पाहिजे आय.पी.ए. उच्चारण]]</noinclude><br />\n<noinclude>*'''उच्चारण संचिका''' :  [[वर्ग:पाहिजे उच्चारण संचिका]]</noinclude><br />\n<noinclude><div class=\"NavFrame\" style=\"clear:both;\">\n<div class=\"NavHead\" align=\"left\">&nbsp; &nbsp; '''शब्दाचे इतर भाषेतील उच्चार'''</div>\n<div class=\"NavContent\">\n{| border=\"0\" width=\"100%\" class=\"translations\"\n|-\n| bgcolor=\"#FFFFE0\" valign=\"top\" width=\"48%\" align=\"left\" |</noinclude><br />\n<noinclude>*इंग्रजी : XXXXXX [[वर्ग:पाहिजे इंग्रजीमध्ये उच्चार]]</noinclude><br />\n<noinclude>*उर्दू : XXXXXX [[वर्ग:पाहिजे उर्दूमध्ये उच्चार]]</noinclude><br />\n<noinclude>*ओरिसी : XXXXXX [[वर्ग:पाहिजे ओरिसीमध्ये उच्चार]]</noinclude><br />\n<noinclude>*कानडी : XXXXXX [[वर्ग:पाहिजे कानडीमध्ये उच्चार]]</noinclude><br />\n<noinclude>*गुजराती : XXXXXX [[वर्ग:पाहिजे गुजरातीमध्ये उच्चार]]</noinclude><br />\n<noinclude>*ग्रीक : XXXXXX [[वर्ग:पाहिजे ग्रीकमध्ये उच्चार]]</noinclude><br />\n<noinclude>*जर्मन : XXXXXX [[वर्ग:पाहिजे जर्मनमध्ये उच्चार]]</noinclude><br />\n<noinclude>*जपानी : XXXXXX [[वर्ग:पाहिजे जपानीमध्ये उच्चार]]</noinclude><br />\n<noinclude>*तमिळ : XXXXXX [[वर्ग:पाहिजे तमिळमध्ये उच्चार]]</noinclude><br />\n<noinclude>*तेलुगू : XXXXXX [[वर्ग:पाहिजे तेलुगूमध्ये उच्चार]]</noinclude><br />\n<noinclude>| width=1% |\n|bgcolor=\"#FFFFE0\" valign=top align=left width=48%|</noinclude><br />\n<noinclude>*पंजाबी : XXXXXX [[वर्ग:पाहिजे पंजाबीमध्ये उच्चार]]</noinclude><br />\n<noinclude>*बंगाली : XXXXXX [[वर्ग:पाहिजे बंगालीमध्ये उच्चार]]</noinclude><br />\n<noinclude>*फ्रेंच : XXXXXX [[वर्ग:पाहिजे फ्रेंचमध्ये उच्चार]]</noinclude><br />\n<noinclude>*मराठी : XXXXXX [[वर्ग:पाहिजे मराठीमध्ये उच्चार]]</noinclude><br />\n<noinclude>*मल्याळम : XXXXXX [[वर्ग:पाहिजे मल्याळममध्ये उच्चार]]</noinclude><br />\n<noinclude>*रशियन : XXXXXX [[वर्ग:पाहिजे रशियनमध्ये उच्चार]]</noinclude><br />\n<noinclude>*संस्कृत : XXXXXX [[वर्ग:पाहिजे संस्कृतमध्ये उच्चार]]</noinclude><br />\n<noinclude>*हिब्रू : XXXXXX [[वर्ग:पाहिजे हिब्रूमध्ये उच्चार]]</noinclude><br />\n<noinclude>*हिंदी (हिंदी): XXXXXX [[वर्ग:पाहिजे हिंदीमध्ये उच्चार]]</noinclude><br />\n<noinclude>|}</div></div></noinclude><br />\n\n[[वर्ग:विक्शनरी: आदर्श मांडणी क्रम]]\n[[वर्ग:मराठी शब्द]][[Image:Wikipedia-logo.svg|15px|link=w:अनिर्वचनिय]] <b class=\"None\" lang=\"en>[[w:अनिर्वचनिय|अनिर्वचनिय]]</b> on  Wikipedia.<span class=\"interProject\">[[w:अनिर्वचनिय|Wikipedia ]]</span>";
    const namespace_source = "# wikidict-namespace-registry-v1\n# wiki\tmrwiktionary\n# dump-date\t20261001\n# content-language\tmr\n-2\tमिडिया\tMedia\tcase-sensitive\t0\t0\t0\t\tcompile_only\tvirtual_namespace\n-1\tविशेष\tSpecial\tfirst-letter\t0\t0\t0\t\tcompile_only\tvirtual_namespace\n0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tdictionary_entries\n1\tचर्चा\tTalk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n2\tसदस्य\tUser\tfirst-letter\t1\t0\t0\t\tcompile_only\tstandard_build_input\n3\tसदस्य चर्चा\tUser talk\tfirst-letter\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n4\tविक्शनरी\tProject\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\tWT\tWiktionary\n5\tविक्शनरी चर्चा\tProject talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tWiktionary talk\n6\tचित्र\tFile\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\tImage\n7\tचित्र चर्चा\tFile talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tImage talk\n8\tमिडियाविकी\tMediaWiki\tfirst-letter\t1\t0\t0\t\tcompile_only\tstandard_build_input\n9\tमिडियाविकी चर्चा\tMediaWiki talk\tfirst-letter\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n10\tसाचा\tTemplate\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n11\tसाचा चर्चा\tTemplate talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n12\tसहाय्य\tHelp\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\tसाहाय्य\n13\tसहाय्य चर्चा\tHelp talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tसाहाय्य चर्चा\n14\tवर्ग\tCategory\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\n15\tवर्ग चर्चा\tCategory talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n104\tसूची\tसूची\tcase-sensitive\t1\t0\t0\t\tsupplemental\tunclassified_subject_retained\n105\tसूची चर्चा\tसूची चर्चा\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n710\tTimedText\tTimedText\tcase-sensitive\t0\t0\t0\t\tcompile_only\tancillary_site_input\n711\tTimedText talk\tTimedText talk\tcase-sensitive\t0\t0\t0\t\tcompile_only\tdiscussion_namespace\n828\tविभाग\tModule\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n829\tविभाग चर्चा\tModule talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n1728\tEvent\tEvent\tcase-sensitive\t1\t0\t0\t\tcompile_only\tancillary_site_input\n1729\tEvent talk\tEvent talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n";
    try std.testing.expectEqual(@as(usize, 4024), source.len);
    var namespaces = try NamespaceRegistry.init(a, namespace_source);
    defer namespaces.deinit();
    // The independent reference removes only the neutral wrappers surrounding
    // the one cross-wrapper table. All contents, br tags and newlines survive.
    const start = std.mem.indexOf(u8, source, "<noinclude><div class=\"NavFrame\"").?;
    const finish = std.mem.indexOf(u8, source, "|}</div></div></noinclude>").? + "|}</div></div></noinclude>".len;
    const without_openers = try std.mem.replaceOwned(u8, a, source[start..finish], "<noinclude>", "");
    const body = try std.mem.replaceOwned(u8, a, without_openers, "</noinclude>", "");
    const reference = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ source[0..start], body, source[finish..] });
    try std.testing.expectEqual(std.mem.count(u8, source, "\n"), std.mem.count(u8, reference, "\n"));
    try std.testing.expectEqual(@as(usize, 24), std.mem.count(u8, reference, "<br />"));
    try std.testing.expectEqual(@as(usize, 20), std.mem.count(u8, reference, "XXXXXX"));
    // Keep the same authenticated namespace registry, with no language guess.
    var actual_report: Fallbacks = .{};
    var expected_report: Fallbacks = .{};
    const actual = try compileReportedWithLinkTrailAlloc(a, "अनिर्वचनिय", .language, "Unclassified", "", source, null, .{}, &namespaces, &actual_report);
    const expected = try compileReportedWithLinkTrailAlloc(a, "अनिर्वचनिय", .language, "Unclassified", "", reference, null, .{}, &namespaces, &expected_report);
    try std.testing.expectEqualSlices(u8, expected, actual);
    try std.testing.expectEqualDeep(expected_report, actual_report);
    const stored = try codec.decodeAlloc(a, actual, "अनिर्वचनिय", .language, .{ .code = "", .heading = "Unclassified" });
    try std.testing.expectEqualSlices(u8, actual, try codec.encodeAlloc(a, stored));
    var table_count: usize = 0;
    var heading = false;
    var strong_title = false;
    var bold_link = false;
    var links: usize = 0;
    var action_counts = [_]usize{ 0, 0, 0 };
    const action_labels = [_][]const u8{ "Wikipedia-logo.svg", "अनिर्वचनिय", "Wikipedia " };
    const action_classes = [_][]const u8{ "wikidict-media wikidict-media-file-57696b6970656469612d6c6f676f2e737667", "None", "interProject" };
    var visible: std.ArrayList(u8) = .empty;
    const Scan = struct {
        fn spans(allocator: A, out: *std.ArrayList(u8), values: []const types.Span) !void {
            for (values) |span| {
                try out.appendSlice(allocator, span.text);
                try std.testing.expect(std.mem.indexOf(u8, span.target, "वर्ग:") == null);
            }
        }
        fn blocks(allocator: A, out: *std.ArrayList(u8), values: []const types.Block) anyerror!void {
            for (values) |block| {
                try spans(allocator, out, block.spans);
                if (block.table) |table| for (table.rows) |row| for (row.cells) |cell| {
                    if (cell.blocks) |children| try blocks(allocator, out, children) else try spans(allocator, out, cell.spans);
                };
            }
        }
    };
    for (stored.entry.sections) |section| {
        heading = heading or std.mem.eql(u8, section.title, "मराठी भाषा");
        try Scan.blocks(a, &visible, section.blocks);
        for (section.blocks) |block| {
            if (block.table) |table| {
                table_count += 1;
                try std.testing.expectEqual(@as(usize, 1), table.rows.len);
                try std.testing.expectEqual(@as(usize, 3), table.rows[0].cells.len);
                try std.testing.expectEqualStrings("#ffffe0", table.rows[0].cells[0].background.?);
                try std.testing.expectEqualStrings("#ffffe0", table.rows[0].cells[2].background.?);
                for (table.rows[0].cells) |cell| try std.testing.expect(!cell.header and cell.colspan == 1 and cell.rowspan == 1);
            }
            for (block.spans) |span| {
                if (span.bold and std.mem.indexOf(u8, span.text, "शब्दाचे इतर भाषेतील उच्चार") != null) strong_title = true;
                if (span.kind == .link) {
                    links += 1;
                    try std.testing.expectEqualStrings("w:अनिर्वचनिय", span.target);
                    const action_index = for (action_labels, 0..) |label, index| {
                        if (std.mem.eql(u8, span.text, label)) break index;
                    } else return error.TestUnexpectedResult;
                    action_counts[action_index] += 1;
                    try std.testing.expectEqualStrings(action_classes[action_index], span.classes);
                    try std.testing.expectEqualStrings("", span.trail);
                    try std.testing.expectEqual(action_index == 1, span.bold);
                    try std.testing.expectEqualStrings(if (action_index == 1) "en" else "", span.language);
                    if (span.bold and std.mem.eql(u8, span.text, "अनिर्वचनिय")) {
                        try std.testing.expectEqualStrings("en", span.language);
                        bold_link = true;
                    }
                }
            }
        }
    }
    try std.testing.expect(heading and strong_title and bold_link);
    try std.testing.expectEqual(@as(usize, 1), table_count);
    try std.testing.expectEqual(@as(usize, 3), links);
    try std.testing.expectEqualSlices(usize, &.{ 1, 1, 1 }, &action_counts);
    try std.testing.expectEqual(@as(usize, 20), std.mem.count(u8, visible.items, "XXXXXX"));
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "इंग्रजी :") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "हिंदी (हिंदी):") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "on  Wikipedia.") != null);
    try std.testing.expectEqual(@as(usize, 1), stored.entry.media.len);
    try std.testing.expectEqualStrings("Wikipedia-logo.svg", stored.entry.media[0].file);
    try std.testing.expectEqual(@as(usize, 0), stored.entry.references.len);
    // No source transformation authorizes already-parsed residuals or targets.
    const residual = [_]compiler.Span{.{ .text = "{|\n| cell\n|}" }};
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &residual, null));
    const target = [_]compiler.Span{.{ .kind = .link, .text = "label", .target = "{{unresolved}}", .provenance = .protected_literal }};
    try std.testing.expectError(error.UncompiledTemplate, validateSpans(a, &target, null));
}
