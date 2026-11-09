//! Build-only, lazy category declarations borrowed from the normal dump reader.
const std = @import("std");
const encoder = @import("encoder");
const dump_source = @import("wikimedia_dump");
const namespaces = @import("namespace_registry");
const languages = @import("language_registry.zig");
const xml_decode = @import("xml_decode");
const syntax = encoder.wikitext_syntax;
const Resolved = encoder.blob_builder.ResolvedLanguage;

fn plain(value: []const u8) bool {
    if (value.len == 0 or std.mem.indexOfAny(u8, value, "[]{}<>&|=\r\n\t") != null) return false;
    for (value) |byte| if (byte < 32 or byte == 127) return false;
    return true;
}
fn argument(body: []const u8, key: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var at = syntax.delimiter(body, "|", 0) orelse return null;
    while (at < body.len) {
        const start = at + 1;
        const end = syntax.delimiter(body, "|", start) orelse body.len;
        const field = std.mem.trim(u8, body[start..end], " \t\r\n");
        if (syntax.delimiter(field, "=", 0)) |equal| {
            if (std.mem.eql(u8, std.mem.trim(u8, field[0..equal], " \t\r\n"), key)) {
                if (found != null) return null;
                found = std.mem.trim(u8, field[equal + 1 ..], " \t\r\n");
            }
        }
        at = end;
    }
    return found;
}

/// Recognize current source forwarding of the first positional language argument.
/// Comments, excluded documentation and nested calls cannot manufacture a proof.
pub fn topicTemplateForwardsLanguage(source: []const u8) bool {
    const raw = std.mem.trim(u8, source, " \t\r\n");
    const doc = "<noinclude>";
    const doc_end = "</noinclude>";
    if (!std.mem.startsWith(u8, raw, doc)) return false;
    const close = std.mem.indexOfPos(u8, raw, doc.len, doc_end) orelse return false;
    if (std.mem.indexOfScalar(u8, raw[doc.len..close], '<') != null) return false;
    const included = std.mem.trim(u8, raw[close + doc_end.len ..], " \t\r\n");
    const open = "<includeonly>";
    const end = "</includeonly>";
    if (!std.mem.startsWith(u8, included, open) or !std.mem.endsWith(u8, included, end) or included.len < open.len + end.len) return false;
    const body = included[open.len .. included.len - end.len];
    var at: usize = 0;
    var description = false;
    var parents = false;
    while (at < body.len) {
        if (std.mem.startsWith(u8, body[at..], "<!--")) {
            at = (std.mem.indexOfPos(u8, body, at + 4, "-->") orelse return false) + 3;
            continue;
        }
        if (body[at] == '<') {
            if (syntax.protectedEnd(body, at)) |protected_end| { at = protected_end; continue; }
            const tag = syntax.tagAt(body, at) orelse return false;
            if (tag.is("onlyinclude") or tag.is("includeonly") or tag.is("noinclude")) return false;
            at = tag.end;
            continue;
        }
        if (std.mem.startsWith(u8, body[at..], "[[")) {
            at = (syntax.balanced(body, at) orelse return false).end;
            continue;
        }
        if (std.mem.startsWith(u8, body[at..], "{{")) {
            const pair = syntax.balanced(body, at) orelse return false;
            const call = body[at + 2 .. pair.inner_end];
            const pipe = syntax.delimiter(call, "|", 0) orelse call.len;
            const name = std.mem.trim(u8, call[0..pipe], " \t\r\n");
            if (std.mem.eql(u8, name, "topic cat description")) {
                if (description or !std.mem.eql(u8, argument(call, "lang") orelse return false, "{{#if:{{{1|}}}|{{{1|}}}|en}}")) return false;
                description = true;
            } else if (std.mem.eql(u8, name, "topic cat parents")) {
                if (parents or !std.mem.eql(u8, argument(call, "lang") orelse return false, "{{{1|}}}")) return false;
                parents = true;
            }
            at = pair.end;
            continue;
        }
        at += 1;
    }
    return description and parents;
}

/// A declaration must agree with the category title and normal trusted alias.
/// This proves language ownership only; it supplies no POS or lexical senses.
pub fn categoryDeclaration(source: []const u8, category: []const u8, registry: *const languages.Registry) ?Resolved {
    const suffix = " పదాలు";
    if (!std.mem.endsWith(u8, category, suffix)) return null;
    const label = category[0 .. category.len - suffix.len];
    if (!plain(label)) return null;
    const owner = registry.resolveStrong(label) orelse registry.resolveTrusted(label) orelse return null;
    if (!topicDeclarationAgrees(source, category, owner.code)) return null;
    // Do not retain resolve()'s input-label fallback across scratch teardown.
    const code = registry.codes.getKey(owner.code) orelse return null;
    const heading = registry.headings.get(owner.code) orelse return null;
    return .{ .code = code, .heading = heading };
}

// The caller must independently establish the owner and authenticate the
// topic template's first-argument forwarding before using this agreement.
pub fn topicDeclarationAgrees(source: []const u8, category: []const u8, expected_code: []const u8) bool {
    var at: usize = 0;
    var declared = false;
    while (at < source.len) {
        if (std.mem.startsWith(u8, source[at..], "<!--")) {
            at = (std.mem.indexOfPos(u8, source, at + 4, "-->") orelse return false) + 3;
            continue;
        }
        if (source[at] == '<') {
            if (syntax.protectedEnd(source, at)) |protected_end| { at = protected_end; continue; }
            const tag = syntax.tagAt(source, at) orelse return false;
            if (tag.is("onlyinclude") or tag.is("includeonly") or tag.is("noinclude")) return false;
            at = tag.end;
            continue;
        }
        if (std.mem.startsWith(u8, source[at..], "[[")) {
            at = (syntax.balanced(source, at) orelse return false).end;
            continue;
        }
        if (std.mem.startsWith(u8, source[at..], "{{")) {
            const pair = syntax.balanced(source, at) orelse return false;
            const call = source[at + 2 .. pair.inner_end];
            const pipe = syntax.delimiter(call, "|", 0) orelse call.len;
            const name = std.mem.trim(u8, call[0..pipe], " \t\r\n");
            if (std.mem.eql(u8, name, "topic cat")) {
                if (declared or pipe == call.len) return false;
                const next = syntax.delimiter(call, "|", pipe + 1) orelse return false;
                if (syntax.delimiter(call, "|", next + 1) != null) return false;
                const code = std.mem.trim(u8, call[pipe + 1 .. next], " \t\r\n");
                const title = std.mem.trim(u8, call[next + 1 ..], " \t\r\n");
                if (!plain(code) or !plain(title) or !std.mem.eql(u8, code, expected_code) or !std.mem.eql(u8, title, category)) return false;
                declared = true;
            }
            at = pair.end;
            continue;
        }
        at += 1;
    }
    return declared;
}

// A single hidden category parent is a dependency edge, not an owner.
pub fn singleCategoryParent(source: []const u8, ns: *const namespaces.Registry) ?[]const u8 {
    const raw = std.mem.trim(u8, source, " \t\r\n");
    if (raw.len > 4096 or !std.mem.startsWith(u8, raw, "[[")) return null;
    const pair = syntax.balanced(raw, 0) orelse return null;
    if (pair.end != raw.len) return null;
    const target = raw[2..pair.inner_end];
    if (!plain(target) or target[0] == ':' or std.mem.indexOfScalar(u8, target, '#') != null or ns.ofTitle(target).id != 14) return null;
    return target;
}

// This category's complete authored declaration names Slovenian in prose and
// in its direct language parent. No category name or edition default alone is
// authority; additional/mixed/protected declarations are outside this proof.
pub fn slovenianNounDeclaration(source: []const u8, category: []const u8, registry: *const languages.Registry) ?Resolved {
    if (!std.mem.eql(u8, category, "Slovenski samostalniki")) return null;
    const declaration = "Ta [[Wikislovar:Kategorija|kategorija]] zajema [[slovenščina|slovenske]] [[samostalnik]]e.\n\n{{a-z}}\n\n[[Kategorija:Samostalniki]]\n[[Kategorija:Slovenščina|Samostalniki]]";
    if (!std.mem.eql(u8, std.mem.trim(u8, source, " \t\r\n"), declaration)) return null;
    const resolved = registry.resolveStrong("Slovenščina") orelse registry.resolveTrusted("Slovenščina") orelse return null;
    if (!std.mem.eql(u8, resolved.code, "sl")) return null;
    const code = registry.codes.getKey(resolved.code) orelse return null;
    const heading = registry.headings.get(resolved.code) orelse return null;
    return .{ .code = code, .heading = heading };
}

// The selected categoryTOC source role is finite and build-only. These complete
// reviewed source forms declare a language code and name; they do not prove
// arbitrary navigation/helper execution or add a global registry alias.
// Changed source declines until its role is reviewed. The name/code data below
// remain variable and independently checked against the current registry.
pub const CategoryTocRole = enum { toc, linkbox, description, flag };
pub fn categoryTocRoleSource(source: []const u8, role: CategoryTocRole) bool {
    const expected: []const u8 = switch (role) {
        .flag => "4712428546e555518337dd6cfacb1bd2a8abb6bc25b56ef82c2d504cdc1f2117",
        .toc => "b0af8cb18fb968194c72572f1fab0ad3f5d821fe9b7102612281be3ef96899f2",
        .linkbox => "5d88940d233dbdab320787afbf0be7e51c95f75f00130f3b57c9e30735c274a2",
        .description => "981d4035680ae4c240ede8186fe71b46b1b685840dcbd4996a670837c29308c3",
    };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    return std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), expected);
}

pub const CategoryTocDeclaration = struct { label: []const u8, code: []const u8 };
pub fn categoryTocDeclaration(source: []const u8, category: []const u8, ns: *const namespaces.Registry) ?CategoryTocDeclaration {
    if (!std.mem.eql(u8, ns.content_language, "lt")) return null;
    const raw = std.mem.trim(u8, source, " \t\r\n");
    if (raw.len > 8192 or !std.mem.startsWith(u8, raw, "{{categoryTOC|")) return null;
    const pair = syntax.balanced(raw, 0) orelse return null;
    const body = raw[2..pair.inner_end];
    const start = "categoryTOC|".len;
    const first_end = syntax.delimiter(body, "|", start) orelse return null;
    const label = body[start..first_end];
    if (!plain(label) or !std.mem.eql(u8, label, category) or std.mem.indexOfScalar(u8, label, ':') != null) return null;
    var code: ?[]const u8 = null;
    var current = false;
    var sister = false;
    var at = first_end;
    while (at < body.len) {
        const end = syntax.delimiter(body, "|", at + 1) orelse body.len;
        const field = body[at + 1 .. end];
        const equal = std.mem.indexOfScalar(u8, field, '=') orelse return null;
        const key = field[0..equal];
        const value = field[equal + 1 ..];
        if (!plain(value) or std.mem.indexOfScalar(u8, value, '=') != null) return null;
        if (std.mem.eql(u8, key, "kodas")) {
            if (code != null or value.len < 2 or value.len > 16) return null;
            for (value) |byte| if (!std.ascii.isLower(byte) and byte != '-') return null;
            code = value;
        } else if (std.mem.eql(u8, key, "current")) {
            if (current or !std.mem.eql(u8, value, "Kalbos")) return null;
            current = true;
        } else if (std.mem.eql(u8, key, "setsister")) {
            if (sister) return null;
            sister = true;
        } else return null;
        at = end;
    }
    if (!current) return null;
    // Additional declarations, calls, prose, comments or protected text do not
    // participate in this finite category contract. Literal taxonomy links do.
    var tail = std.mem.trim(u8, raw[pair.end..], " \t\r\n");
    while (tail.len != 0) {
        if (!std.mem.startsWith(u8, tail, "[[")) return null;
        const link = syntax.balanced(tail, 0) orelse return null;
        const inner = tail[2..link.inner_end];
        if (std.mem.indexOfAny(u8, inner, "[]{}<>&\r\n\t") != null) return null;
        const pipe = std.mem.indexOfScalar(u8, inner, '|') orelse inner.len;
        const target = inner[0..pipe];
        if (target.len == 0 or target[0] == ':' or ns.ofTitle(target).id != 14) return null;
        if (pipe < inner.len and (inner.len == pipe + 1 or std.mem.indexOfScalar(u8, inner[pipe + 1 ..], '|') != null)) return null;
        tail = std.mem.trim(u8, tail[link.end..], " \t\r\n");
    }
    return .{ .label = label, .code = code orelse return null };
}

// The authenticated categoryTOC role explicitly declares the code. Its paired
// lang:<code> source supplies this literal default-singular name, without template
// execution or a suffix-removal rule. Existing registry names still veto conflicts.
pub fn categoryTocLanguageName(a: std.mem.Allocator, source: []const u8, declaration: CategoryTocDeclaration, registry: *const languages.Registry) !bool {
    if (source.len > 4096 or !std.unicode.utf8ValidateSlice(source)) return false;
    const marker = " {{plural:{{{1|1}}}|";
    const split = std.mem.indexOf(u8, source, marker) orelse return false;
    const stem = source[0..split];
    if (!plain(stem) or std.mem.indexOfAny(u8, stem, "#:'\"") != null or
        !std.mem.endsWith(u8, source, "}}")) return false;
    const forms = source[split + marker.len .. source.len - 2];
    const pipe = std.mem.indexOfScalar(u8, forms, '|') orelse return false;
    const singular = forms[0..pipe];
    const plural = forms[pipe + 1 ..];
    if (!plain(singular) or !plain(plural) or std.mem.indexOfAny(u8, forms, "#:'\"") != null) return false;
    const code = registry.codes.getKey(declaration.code) orelse return false;
    if (registry.resolveStrong(stem) orelse registry.resolveSourceTrusted(stem)) |owner| {
        if (!std.mem.eql(u8, code, owner.code)) return false;
    } else {
        // Absence is distinct from a weak or ambiguous name. Only a genuinely
        // unregistered literal stem may use the category's explicit code.
        inline for (.{ registry.names, registry.local_aliases, registry.reviewed_aliases, registry.ambiguous }) |map| {
            var keys = map.keyIterator();
            while (keys.next()) |key| if (std.ascii.eqlIgnoreCase(key.*, stem)) return false;
        }
        if (!registry.sourceBannerLiteralCodeNameCompatible(code, stem)) return false;
    }
    const name = try std.fmt.allocPrint(a, "{s} {s}", .{ stem, singular });
    defer a.free(name);
    if (!std.mem.eql(u8, name, declaration.label)) return false;
    for ([_][]const u8{ stem, declaration.label, code }) |spelling| {
        if (registry.isLanguageBoundary(spelling)) return false;
        if (registry.resolve(spelling)) |resolved| if (!std.mem.eql(u8, resolved.code, code)) return false;
    }
    return true;
}

// Independently certify the complete raw heading-template declaration. A page
// may have unknown missing-dependency coordinates elsewhere; that metadata is
// preserved. It cannot manufacture this selected source, literal category name,
// explicit code agreement, or observed physical heading correspondence.
pub fn categoryTocBannerSource(a: std.mem.Allocator, source: []const u8, target: []const u8, owner: Resolved, ns: *const namespaces.Registry) !bool {
    const category = ns.ofTitle(target);
    const spec = ns.byId(14) orelse return false;
    if (category.id != 14 or !plain(category.text) or owner.code.len == 0) return false;
    const expected = try std.mem.concat(a, u8, &.{
        "{{flag|", owner.code, "|45}}[[:", target, "|", category.text,
        "]]{{#ifeq:{{NAMESPACE}}|{{ns:template}}|[[", spec.name,
        ":Kalbos kodų šablonai|{{PAGENAME}}]]|[[", spec.name, ":{{lang:",
        owner.code, "}}|{{ucfirst:{{PAGENAME}}}}]]}}",
    });
    defer a.free(expected);
    return std.mem.eql(u8, source, expected);
}

pub const Context = struct {
    allocator: std.mem.Allocator,
    registry: *const languages.Registry,
    namespace_catalog: *const namespaces.Registry,
    source: *dump_source.SourceReader,
    page_index: []const u8,
    title_index: dump_source.PageTitleIndex,
    // Callbacks acquire this before SourceReader.readAlloc; dispatch only takes
    // the source lock. Internal resolveHeading -> resolve calls stay unlocked.
    callback_mutex: std.Io.Mutex = .init,
    template_support: ?bool = null,
    category_toc_support: ?bool = null,
    cache: [16]?Cache = @splat(null),
    cache_cursor: usize = 0,
    const Cache = struct { title: []const u8, owner: ?Resolved };
    const Page = struct { title: []const u8, source: []const u8 };

    fn readPage(self: *Context, a: std.mem.Allocator, title: []const u8, namespace: u32, limit: usize) !?Page {
        const ref = (try self.title_index.lookup(self.page_index, title)) orelse return null;
        const offset = dump_source.pageRowRefOffset(ref);
        const end = std.mem.indexOfScalarPos(u8, self.page_index, offset, '\n') orelse self.page_index.len;
        const row = try dump_source.parsePageIndexLine(self.title_index.kind, self.page_index[offset..end]);
        if (row.ns != namespace or !row.has_source or row.redirect != null or !std.mem.eql(u8, row.content_model, "wikitext") or
            !std.mem.eql(u8, row.title, title) or dump_source.sourceLen(row.source) > limit) return null;
        const raw = try self.source.readAlloc(a, row.source);
        return .{ .title = row.title, .source = if (row.source_needs_decode) try xml_decode.decodeSinglePassAlloc(a, raw) else raw };
    }
    fn categoryTocSupport(self: *Context, a: std.mem.Allocator) !bool {
        if (self.category_toc_support) |supported| return supported;
        const spec = self.namespace_catalog.byId(10) orelse return false;
        const roles = [_]struct { name: []const u8, role: CategoryTocRole }{
            .{ .name = "flag", .role = .flag },
            .{ .name = "categoryTOC", .role = .toc },
            .{ .name = "categoryTOC/linkbox", .role = .linkbox },
            .{ .name = "categoryTOC/description", .role = .description },
        };
        for (roles) |role| {
            const title = try std.fmt.allocPrint(a, "{s}:{s}", .{ spec.name, role.name });
            const page = (try self.readPage(a, title, 10, 8192)) orelse {
                self.category_toc_support = false;
                return false;
            };
            if (!categoryTocRoleSource(page.source, role.role)) {
                self.category_toc_support = false;
                return false;
            }
        }
        self.category_toc_support = true;
        return true;
    }
    fn resolveCategoryToc(self: *Context, a: std.mem.Allocator, title: []const u8) !?Resolved {
        const page = (try self.readPage(a, title, 14, 8192)) orelse return null;
        const declaration = categoryTocDeclaration(page.source, self.namespace_catalog.ofTitle(page.title).text, self.namespace_catalog) orelse return null;
        if (!self.registry.codes.contains(declaration.code) or !try self.categoryTocSupport(a)) return null;
        const spec = self.namespace_catalog.byId(10) orelse return null;
        const name_title = try std.fmt.allocPrint(a, "{s}:lang:{s}", .{ spec.name, declaration.code });
        const name = (try self.readPage(a, name_title, 10, 4096)) orelse return null;
        if (!try categoryTocLanguageName(a, name.source, declaration, self.registry)) return null;
        return .{
            .code = self.registry.codes.getKey(declaration.code) orelse return null,
            .heading = self.registry.headings.get(declaration.code) orelse return null,
        };
    }
    pub fn resolveHeading(self: *Context, template_name: []const u8, target: []const u8) !?Resolved {
        if (!std.mem.eql(u8, self.namespace_catalog.content_language, "lt") or
            template_name.len == 0 or std.mem.indexOfAny(u8, template_name, "{}[]<>&|=:#'\" \t\r\n") != null) return null;
        const owner = (try self.resolve(target)) orelse return null;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const spec = self.namespace_catalog.byId(10) orelse return null;
        const title = try std.fmt.allocPrint(a, "{s}:{s}", .{ spec.name, template_name });
        const page = (try self.readPage(a, title, 10, 4096)) orelse return null;
        if (!try categoryTocBannerSource(a, page.source, target, owner, self.namespace_catalog)) return null;
        return owner;
    }
    pub fn headingCallback(raw: ?*anyopaque, template_name: []const u8, target: []const u8) anyerror!?Resolved {
        const self: *Context = @ptrCast(@alignCast(raw orelse return null));
        self.callback_mutex.lockUncancelable(self.source.io);
        defer self.callback_mutex.unlock(self.source.io);
        return self.resolveHeading(template_name, target);
    }
    pub fn resolve(self: *Context, target: []const u8) !?Resolved {
        if (self.namespace_catalog.ofTitle(target).id != 14) return null;
        if (self.title_index.page_index_size != self.page_index.len or self.title_index.kind != dump_source.pageIndexKind(self.page_index)) return error.PageTitleIndexMismatch;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const title = self.namespace_catalog.normalizeTitle(a, target, 0, .any) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        for (self.cache) |entry| if (entry) |cached| if (std.mem.eql(u8, cached.title, title)) return cached.owner;
        // Edition-local syntax scopes this source convention, never the owner.
        // Every returned owner still comes from explicit source code/name data.
        if (std.mem.eql(u8, self.namespace_catalog.content_language, "lt")) {
            const owner = try self.resolveCategoryToc(a, title);
            const indexed = (try self.title_index.lookup(self.page_index, title)) orelse return null;
            const offset = dump_source.pageRowRefOffset(indexed);
            const end = std.mem.indexOfScalarPos(u8, self.page_index, offset, '\n') orelse self.page_index.len;
            const row = try dump_source.parsePageIndexLine(self.title_index.kind, self.page_index[offset..end]);
            self.cache[self.cache_cursor] = .{ .title = row.title, .owner = owner };
            self.cache_cursor = (self.cache_cursor + 1) % self.cache.len;
            return owner;
        }
        // The SL declaration is direct source evidence, not the unrelated
        // Telugu topic-cat template convention. Preserve that path unchanged.
        if (std.mem.eql(u8, self.namespace_catalog.content_language, "sl") and
            std.mem.eql(u8, self.namespace_catalog.ofTitle(title).text, "Slovenski samostalniki"))
        {
            const category = (try self.readPage(a, title, 14, 4096)) orelse return null;
            const owner = slovenianNounDeclaration(category.source, self.namespace_catalog.ofTitle(category.title).text, self.registry);
            self.cache[self.cache_cursor] = .{ .title = category.title, .owner = owner };
            self.cache_cursor = (self.cache_cursor + 1) % self.cache.len;
            return owner;
        }
        if (self.template_support == null) {
            const spec = self.namespace_catalog.byId(10) orelse return null;
            const template_title = try std.fmt.allocPrint(a, "{s}:topic cat", .{spec.name});
            const template = (try self.readPage(a, template_title, 10, 8192)) orelse {
                self.template_support = false;
                return null;
            };
            self.template_support = topicTemplateForwardsLanguage(template.source);
        }
        if (!self.template_support.?) return null;
        const category = (try self.readPage(a, title, 14, 4096)) orelse return null;
        const owner = categoryDeclaration(category.source, self.namespace_catalog.ofTitle(category.title).text, self.registry);
        // Keys borrow the immutable page index; owners borrow trusted registry
        // strings. Neither points into this call's scratch source allocation.
        self.cache[self.cache_cursor] = .{ .title = category.title, .owner = owner };
        self.cache_cursor = (self.cache_cursor + 1) % self.cache.len;
        return owner;
    }
    // This can only corroborate an independently resolved owner. It never
    // resolves a parent or grants an owner to a category-only page.
    pub fn agrees(self: *Context, target: []const u8, expected: Resolved) !bool {
        if (!(self.template_support orelse false) or self.namespace_catalog.ofTitle(target).id != 14 or
            !self.registry.codes.contains(expected.code)) return false;
        if (self.title_index.page_index_size != self.page_index.len or self.title_index.kind != dump_source.pageIndexKind(self.page_index)) return error.PageTitleIndexMismatch;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const title = self.namespace_catalog.normalizeTitle(a, target, 0, .any) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        const peer = (try self.readPage(a, title, 14, 4096)) orelse return false;
        const parent = singleCategoryParent(peer.source, self.namespace_catalog) orelse return false;
        const parent_title = self.namespace_catalog.normalizeTitle(a, parent, 0, .any) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        const page = (try self.readPage(a, parent_title, 14, 4096)) orelse return false;
        return topicDeclarationAgrees(page.source, self.namespace_catalog.ofTitle(page.title).text, expected.code);
    }
    pub fn agreementCallback(raw: ?*anyopaque, target: []const u8, expected: Resolved) anyerror!bool {
        const self: *Context = @ptrCast(@alignCast(raw orelse return false));
        self.callback_mutex.lockUncancelable(self.source.io);
        defer self.callback_mutex.unlock(self.source.io);
        return self.agrees(target, expected);
    }
    pub fn callback(raw: ?*anyopaque, target: []const u8) anyerror!?Resolved {
        const self: *Context = @ptrCast(@alignCast(raw orelse return null));
        self.callback_mutex.lockUncancelable(self.source.io);
        defer self.callback_mutex.unlock(self.source.io);
        return self.resolve(target);
    }
};
