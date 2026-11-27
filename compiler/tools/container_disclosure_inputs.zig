//! Build-only, edition-local capture inputs. This checks the identity and
//! custody of an explicit observation; it does not infer an initializer or CSS
//! policy from a title, class, missing field, or equal text on another page.
const std = @import("std");
const encoder = @import("encoder");
const namespace_registry = @import("namespace_registry");
const T = encoder.presentation_types;
const PC = encoder.presentation_compile;

pub const filename = "container-disclosure-captures.json";
pub const max_input = 1024 * 1024;
pub const Reference = struct {
    scope: []const u8,
    full_page_cascade_qualified: bool,
    historical_deployment_qualified: bool,
    observed_html_sha256: []const u8,
    actual_reference_sha256: []const u8,
    capture_binding_sha256: []const u8,
};
pub const Capture = struct {
    source_labels: ?PC.ContainerDisclosureSourceLabels = null,
    owner_start: usize,
    owner_end: usize,
    content_start: usize,
    content_end: usize,
    owner_sha256: []const u8,
    reference: Reference,
    policy: T.ContainerDisclosure,
};
pub const Page = struct {
    namespace_id: i32,
    title: []const u8,
    page_id: u64,
    revision_id: u64,
    raw_sha256: []const u8,
    expanded_sha256: []const u8,
    captures: []const Capture,
};
// Shared screen-policy inputs are a separate version from finite page rows.
// The source issuer verifies the retained normal-capture and initializer
// closure before producing this input. Native loading rechecks all supplied
// byte bodies, edition binding and the bounded stylesheet parser inputs.
pub const SharedStyleInput = struct {
    url: []const u8,
    sha256: []const u8,
    body: []const u8,
};
pub const SharedReference = struct {
    scope: []const u8,
    historical_deployment_qualified: bool,
    initializer_sha256: []const u8,
    source_closure_sha256: []const u8,
    validation_sha256: []const u8,
    ua_basis_sha256: []const u8,
    parser_constructor_sha256: ?[]const u8 = null,
};
pub const SharedInput = struct {
    protocol: []const u8,
    reference: SharedReference,
    styles: []const SharedStyleInput,
    ua: encoder.table_style_profile.DisclosureUaBasis,
    boundary: encoder.table_style_profile.DisclosureBoundary,
    placement_shell: ?[]const encoder.table_style_profile.DisclosureShellStep = null,
    parser_output_direction: ?T.BidiResolvedDirection = null,
};

fn sharedProfile(a: std.mem.Allocator, input: SharedInput) !*const encoder.table_style_profile.DisclosureSharedProfile {
    const S = encoder.table_style_profile;
    if (!std.mem.eql(u8, input.protocol, "mediawiki-native-div-disclosure.v1") or
        !std.mem.eql(u8, input.reference.scope, "current_normal_shared_initializer_css") or
        input.reference.historical_deployment_qualified or input.styles.len == 0 or input.styles.len > 32 or
        input.boundary.absent_tags.len != 0 or input.boundary.absent_classes.len != 0)
        return error.InvalidContainerDisclosureInput;
    // Per-query ancestry absence is never borrowed from a validation page.
    // The local source issuer may add its own verified absence facts later.
    _ = try digest(input.reference.initializer_sha256);
    _ = try digest(input.reference.source_closure_sha256);
    _ = try digest(input.reference.validation_sha256);
    _ = try digest(input.reference.ua_basis_sha256);
    if (input.placement_shell) |shell| {
        if (shell.len < 2 or shell.len > 32 or !std.ascii.eqlIgnoreCase(shell[0].tag, "html") or
            !std.ascii.eqlIgnoreCase(shell[1].tag, "body")) return error.InvalidContainerDisclosureInput;
        _ = try digest(input.reference.parser_constructor_sha256 orelse return error.InvalidContainerDisclosureInput);
    } else if (input.parser_output_direction != null or input.reference.parser_constructor_sha256 != null)
        return error.InvalidContainerDisclosureInput;
    if (!T.validContainerDisclosureButton(input.ua.button) or
        (input.ua.foreground.kind != .rgb and input.ua.foreground.kind != .transparent))
        return error.InvalidContainerDisclosureInput;
    const sources = try a.alloc(S.Source, input.styles.len);
    var total: usize = 0;
    for (input.styles, sources) |source, *out| {
        if (source.url.len == 0 or source.url.len > 4096 or !std.unicode.utf8ValidateSlice(source.url) or
            !try matches(source.body, source.sha256)) return error.InvalidContainerDisclosureInput;
        total = std.math.add(usize, total, source.body.len) catch return error.InvalidContainerDisclosureInput;
        if (total > 768 * 1024) return error.InvalidContainerDisclosureInput;
        out.* = .{ .css = source.body, .base_url = source.url };
    }
    const styles = try a.create(S.Profile);
    styles.* = try S.parseSourcesForTargetAlloc(a, sources, .screen);
    errdefer styles.deinit();
    const held = try a.create(S.DisclosureSharedProfile);
    held.* = .{ .styles = styles, .ua = input.ua, .boundary = input.boundary, .placement_shell = input.placement_shell };
    return held;
}


pub const Input = struct {
    schema: []const u8,
    wiki: []const u8,
    dump_date: []const u8,
    namespace_sha256: []const u8,
    pages: []const Page = &.{},
    shared: ?SharedInput = null,
};

fn digest(text: []const u8) ![32]u8 {
    if (text.len != 64) return error.InvalidContainerDisclosureInput;
    var value: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&value, text) catch return error.InvalidContainerDisclosureInput;
    if (!std.mem.eql(u8, text, &std.fmt.bytesToHex(value, .lower)) or
        std.mem.allEqual(u8, &value, 0)) return error.InvalidContainerDisclosureInput;
    return value;
}

fn matches(bytes: []const u8, expected: []const u8) !bool {
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
    return std.mem.eql(u8, &actual, &(try digest(expected)));
}

pub const Book = struct {
    arena: std.heap.ArenaAllocator,
    input: Input,
    shared: ?*const encoder.table_style_profile.DisclosureSharedProfile = null,

    pub fn init(backing: std.mem.Allocator, bytes: []const u8, namespaces: *const namespace_registry.Registry) !Book {
        if (bytes.len == 0 or bytes.len > max_input) return error.InvalidContainerDisclosureInput;
        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        // Always own strings: the mmap used by the loader closes on return.
        const input = try std.json.parseFromSliceLeaky(Input, arena.allocator(), bytes, .{ .allocate = .alloc_always });
        const finite = std.mem.eql(u8, input.schema, "wikidict.container-disclosure-captures.v1");
        const shared_version = std.mem.eql(u8, input.schema, "wikidict.container-disclosure-inputs.v2");
        if ((!finite and !shared_version) or (finite and input.shared != null) or
            (shared_version and input.shared == null) or
            !std.mem.eql(u8, input.wiki, namespaces.wiki) or
            !std.mem.eql(u8, input.dump_date, namespaces.dump_date) or
            !std.mem.eql(u8, &(try digest(input.namespace_sha256)), &namespaces.source_sha256) or
            (input.pages.len == 0 and input.shared == null) or input.pages.len > 4096) return error.InvalidContainerDisclosureInput;
        var count: usize = 0;
        for (input.pages, 0..) |page, i| {
            if (page.namespace_id != 0 or page.title.len == 0 or page.title.len > 4096 or
                !std.unicode.utf8ValidateSlice(page.title) or page.page_id == 0 or page.revision_id == 0 or
                page.captures.len == 0 or page.captures.len > 64) return error.InvalidContainerDisclosureInput;
            for (page.title) |c| if (c == 0 or c == '\r' or c == '\n') return error.InvalidContainerDisclosureInput;
            for (input.pages[0..i]) |previous| {
                if (previous.page_id == page.page_id or
                    (previous.namespace_id == page.namespace_id and std.mem.eql(u8, previous.title, page.title)))
                    return error.InvalidContainerDisclosureInput;
            }
            _ = try digest(page.raw_sha256);
            _ = try digest(page.expanded_sha256);
            count += page.captures.len;
            if (count > 4096) return error.InvalidContainerDisclosureInput;
            var previous_end: usize = 0;
            for (page.captures, 0..) |capture, at| {
                if (capture.owner_start >= capture.content_start or capture.content_start >= capture.content_end or
                    capture.content_end >= capture.owner_end or (at != 0 and capture.owner_start < previous_end) or
                    !T.validContainerDisclosure(capture.policy) or capture.policy.button == null or capture.policy.direction == null)
                    return error.InvalidContainerDisclosureInput;
                previous_end = capture.owner_end;
                _ = try digest(capture.owner_sha256);
                const reference = capture.reference;
                if (reference.full_page_cascade_qualified or reference.historical_deployment_qualified)
                    return error.InvalidContainerDisclosureInput;
                if (std.mem.eql(u8, reference.scope, "normal_current_initialized_component")) {
                    const labels = capture.source_labels orelse return error.InvalidContainerDisclosureInput;
                    if (!labels.matchesPolicy(capture.policy)) return error.InvalidContainerDisclosureInput;
                } else if (!std.mem.eql(u8, reference.scope, "controlled_component_current_initializer_css") or
                    capture.source_labels != null) return error.InvalidContainerDisclosureInput;
                _ = try digest(reference.observed_html_sha256);
                _ = try digest(reference.actual_reference_sha256);
                _ = try digest(reference.capture_binding_sha256);
            }
        }
        const shared = if (input.shared) |value| try sharedProfile(arena.allocator(), value) else null;
        return .{ .arena = arena, .input = input, .shared = shared };
    }

    pub fn deinit(self: *Book) void {
        if (self.shared) |shared| @constCast(shared.styles).deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn bind(self: *const Book, a: std.mem.Allocator, namespace_id: i32, language_record: bool,
        alias: bool, title: []const u8, page_id: u64, revision_id: u64, raw: []const u8, expanded: []const u8) !?*const PC.ContainerDisclosureSource
    {
        for (self.input.pages) |page| {
            // A different page has no capture. A partial identity match is a
            // stale/crossed input and fails instead of silently borrowing it.
            const same_title = namespace_id == page.namespace_id and std.mem.eql(u8, title, page.title);
            if (!same_title and page_id != page.page_id) continue;
            if (!same_title or page_id != page.page_id or revision_id != page.revision_id or !language_record or alias or
                !try matches(raw, page.raw_sha256) or !try matches(expanded, page.expanded_sha256))
                return error.InvalidContainerDisclosureInput;
            for (page.captures) |capture| {
                if (capture.owner_end > expanded.len or
                    !try matches(expanded[capture.owner_start..capture.owner_end], capture.owner_sha256))
                    return error.InvalidContainerDisclosureInput;
            }
            const rows = try a.alloc(PC.ContainerDisclosureCapture, page.captures.len);
            for (rows, page.captures) |*row, capture| row.* = .{
                .owner_start = capture.owner_start, .owner_end = capture.owner_end,
                .content_start = capture.content_start, .content_end = capture.content_end,
                .policy = capture.policy, .source_labels = capture.source_labels,
            };
            const held = try a.create(PC.ContainerDisclosureSource);
            held.* = .{ .source = expanded, .captures = rows, .shared_profile = self.shared, .parser_output_direction = if (self.input.shared) |shared| shared.parser_output_direction else null };
            return held;
        }
        if (self.shared) |shared| {
            if (namespace_id != 0 or !language_record or alias) return null;
            if (title.len == 0 or title.len > 4096 or !std.unicode.utf8ValidateSlice(title) or
                page_id == 0 or revision_id == 0 or raw.len == 0 or expanded.len == 0)
                return error.InvalidContainerDisclosureInput;
            for (title) |c| if (c == 0 or c == '\r' or c == '\n') return error.InvalidContainerDisclosureInput;
            const held = try a.create(PC.ContainerDisclosureSource);
            held.* = .{ .source = expanded, .captures = &.{}, .shared_profile = shared, .parser_output_direction = self.input.shared.?.parser_output_direction };
            return held;
        }
        return null;
    }
};
