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
    var at: usize = 0;
    var declared = false;
    while (at < source.len) {
        if (std.mem.startsWith(u8, source[at..], "<!--")) {
            at = (std.mem.indexOfPos(u8, source, at + 4, "-->") orelse return null) + 3;
            continue;
        }
        if (source[at] == '<') {
            if (syntax.protectedEnd(source, at)) |protected_end| { at = protected_end; continue; }
            const tag = syntax.tagAt(source, at) orelse return null;
            if (tag.is("onlyinclude") or tag.is("includeonly") or tag.is("noinclude")) return null;
            at = tag.end;
            continue;
        }
        if (std.mem.startsWith(u8, source[at..], "[[")) {
            at = (syntax.balanced(source, at) orelse return null).end;
            continue;
        }
        if (std.mem.startsWith(u8, source[at..], "{{")) {
            const pair = syntax.balanced(source, at) orelse return null;
            const call = source[at + 2 .. pair.inner_end];
            const pipe = syntax.delimiter(call, "|", 0) orelse call.len;
            const name = std.mem.trim(u8, call[0..pipe], " \t\r\n");
            if (std.mem.eql(u8, name, "topic cat")) {
                if (declared or pipe == call.len) return null;
                const next = syntax.delimiter(call, "|", pipe + 1) orelse return null;
                if (syntax.delimiter(call, "|", next + 1) != null) return null;
                const code = std.mem.trim(u8, call[pipe + 1 .. next], " \t\r\n");
                const title = std.mem.trim(u8, call[next + 1 ..], " \t\r\n");
                if (!plain(code) or !plain(title) or !std.mem.eql(u8, code, owner.code) or !std.mem.eql(u8, title, category)) return null;
                declared = true;
            }
            at = pair.end;
            continue;
        }
        at += 1;
    }
    if (!declared) return null;
    // Do not retain resolve()'s input-label fallback across scratch teardown.
    const code = registry.codes.getKey(owner.code) orelse return null;
    const heading = registry.headings.get(owner.code) orelse return null;
    return .{ .code = code, .heading = heading };
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

pub const Context = struct {
    allocator: std.mem.Allocator,
    registry: *const languages.Registry,
    namespace_catalog: *const namespaces.Registry,
    source: *dump_source.SourceReader,
    page_index: []const u8,
    title_index: dump_source.PageTitleIndex,
    template_support: ?bool = null,
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
    pub fn callback(raw: ?*anyopaque, target: []const u8) anyerror!?Resolved {
        const self: *Context = @ptrCast(@alignCast(raw orelse return null));
        return self.resolve(target);
    }
};
