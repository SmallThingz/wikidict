const std = @import("std");
const lua = @import("parser/root.zig");
const preprocess = @import("wikitext/preprocess.zig");

pub const RefKind = enum {
    template,
    module,
};

pub const Ref = struct {
    kind: RefKind,
    target: []const u8,
};

fn containsDynamicSyntax(raw: []const u8) bool {
    return std.mem.indexOf(u8, raw, "{{") != null or
        std.mem.indexOf(u8, raw, "}}") != null;
}

fn nameEqual(raw: []const u8, expected: []const u8) bool {
    if (raw.len != expected.len) return false;
    for (raw, expected) |lhs_raw, rhs_raw| {
        const lhs = if (lhs_raw == '_') ' ' else lhs_raw;
        if (std.ascii.toLower(lhs) != std.ascii.toLower(rhs_raw)) return false;
    }
    return true;
}

fn stripSubst(raw: []const u8) []const u8 {
    var value = std.mem.trim(u8, raw, " \t\r\n");
    inline for (&.{ "subst:", "safesubst:" }) |prefix| {
        if (value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix))
            value = std.mem.trim(u8, value[prefix.len..], " \t\r\n");
    }
    return value;
}

pub fn canonicalTemplate(a: std.mem.Allocator, raw_in: []const u8) !?[]const u8 {
    const raw = stripSubst(raw_in);
    if (raw.len == 0 or raw[0] == '#' or raw[0] == ':' or containsDynamicSyntax(raw))
        return null;

    if (std.mem.indexOfScalar(u8, raw, ':')) |colon| {
        const prefix = raw[0..colon];
        if (nameEqual(prefix, "Template") or nameEqual(prefix, "T")) {
            const suffix = std.mem.trim(u8, raw[colon + 1 ..], " \t\r\n");
            if (suffix.len == 0) return null;
            const out = try std.fmt.allocPrint(a, "Template:{s}", .{suffix});
            std.mem.replaceScalar(u8, out, '_', ' ');
            return out;
        }

        inline for (&.{
            "Media",          "Special",         "Talk",
            "User",           "User talk",       "Wiktionary",
            "Project",        "WT",              "Wiktionary talk",
            "Project talk",   "File",            "Image",
            "File talk",      "Image talk",      "MediaWiki",
            "MediaWiki talk", "Template talk",   "Help",
            "Help talk",      "Category",        "CAT",
            "Category talk",  "Thread",          "Thread talk",
            "Summary",        "Summary talk",    "Appendix",
            "AP",             "Appendix talk",   "Rhymes",
            "Rhymes talk",    "Transwiki",       "Transwiki talk",
            "Thesaurus",      "WS",              "Wikisaurus",
            "Thesaurus talk", "Wikisaurus talk", "Citations",
            "Citations talk", "Sign gloss",      "Sign gloss talk",
            "Reconstruction", "RC",              "Reconstruction talk",
            "TimedText",      "TimedText talk",  "Module",
            "MOD",            "Module talk",     "Event",
            "Event talk",     "Topic",
        }) |namespace| if (nameEqual(prefix, namespace)) return null;
    }

    const out = try std.fmt.allocPrint(a, "Template:{s}", .{raw});
    std.mem.replaceScalar(u8, out, '_', ' ');
    return out;
}

pub fn canonicalModule(a: std.mem.Allocator, raw_in: []const u8) !?[]const u8 {
    const raw = std.mem.trim(u8, raw_in, " \t\r\n");
    if (raw.len == 0 or containsDynamicSyntax(raw)) return null;

    const suffix = if (std.mem.indexOfScalar(u8, raw, ':')) |colon| blk: {
        const prefix = raw[0..colon];
        if (!nameEqual(prefix, "Module") and !nameEqual(prefix, "MOD")) break :blk raw;
        break :blk std.mem.trim(u8, raw[colon + 1 ..], " \t\r\n");
    } else raw;
    if (suffix.len == 0) return null;

    const out = try std.fmt.allocPrint(a, "Module:{s}", .{suffix});
    std.mem.replaceScalar(u8, out, '_', ' ');
    return out;
}

fn firstTopLevelPart(body: []const u8) []const u8 {
    const pipe = preprocess.findTopDelimiter(body, '|') orelse body.len;
    return std.mem.trim(u8, body[0..pipe], " \t\r\n");
}

fn classifyHead(a: std.mem.Allocator, head: []const u8, out: *std.ArrayList(Ref)) !void {
    if (head.len == 0) return;
    if (preprocess.findTopDelimiter(head, ':')) |colon| {
        const name = std.mem.trim(u8, head[0..colon], " \t\r\n");
        if (std.ascii.eqlIgnoreCase(name, "#invoke")) {
            if (try canonicalModule(a, head[colon + 1 ..])) |target|
                try out.append(a, .{ .kind = .module, .target = target });
            return;
        }
    }
    if (try canonicalTemplate(a, head)) |target|
        try out.append(a, .{ .kind = .template, .target = target });
}

fn scanRange(a: std.mem.Allocator, source: []const u8, out: *std.ArrayList(Ref), depth: usize) anyerror!void {
    if (depth >= 128) return;
    var pos: usize = 0;
    while (preprocess.findTemplateOpenOutsideLiteralTags(source, pos)) |open| {
        if (open != 0 and source[open - 1] == '{') {
            pos = open + 2;
            continue;
        }
        if (open + 2 < source.len and source[open + 2] == '{') {
            const end = preprocess.findParamEnd(source, open) orelse {
                pos = open + 3;
                continue;
            };
            if (end > open + 3)
                try scanRange(a, source[open + 3 .. end], out, depth + 1);
            pos = @min(end + 3, source.len);
            continue;
        }

        const end = preprocess.findTemplateEnd(source, open) orelse {
            pos = open + 2;
            continue;
        };
        const body = source[open + 2 .. end];
        try classifyHead(a, firstTopLevelPart(body), out);
        if (body.len != 0) try scanRange(a, body, out, depth + 1);
        pos = @min(end + 2, source.len);
    }
}

pub fn scanWikitext(a: std.mem.Allocator, source: []const u8, out: *std.ArrayList(Ref)) !void {
    try scanRange(a, source, out, 0);
}

pub fn scanTemplateWikitext(a: std.mem.Allocator, source: []const u8, out: *std.ArrayList(Ref)) !void {
    const body = preprocess.transcludeDecodedAlloc(a, source) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer a.free(body);
    try scanRange(a, body, out, 0);
}

fn staticString(expr: *const lua.Expr) ?[]const u8 {
    return switch (expr.*) {
        .string => |value| value.value,
        .paren => |value| staticString(value.expr),
        else => null,
    };
}

fn collectExpr(a: std.mem.Allocator, expr: *const lua.Expr, out: *std.ArrayList([]const u8)) anyerror!void {
    switch (expr.*) {
        .paren => |value| try collectExpr(a, value.expr, out),
        .index => |value| {
            try collectExpr(a, value.object, out);
            try collectExpr(a, value.key, out);
        },
        .call => |value| {
            if (value.callee.* == .name and std.mem.eql(u8, value.callee.name.value, "require") and
                value.args.len != 0)
            {
                if (staticString(value.args[0])) |raw| {
                    if (try canonicalModule(a, raw)) |target| try out.append(a, target);
                }
            }
            try collectExpr(a, value.callee, out);
            for (value.args) |arg| try collectExpr(a, arg, out);
        },
        .method_call => |value| {
            try collectExpr(a, value.object, out);
            for (value.args) |arg| try collectExpr(a, arg, out);
        },
        .function => |value| try collectBlock(a, value.body, out),
        .table => |value| for (value.fields) |field| switch (field) {
            .list => |item| try collectExpr(a, item, out),
            .named => |item| try collectExpr(a, item.value, out),
            .keyed => |item| {
                try collectExpr(a, item.key, out);
                try collectExpr(a, item.value, out);
            },
        },
        .unary => |value| try collectExpr(a, value.expr, out),
        .binary => |value| {
            try collectExpr(a, value.lhs, out);
            try collectExpr(a, value.rhs, out);
        },
        else => {},
    }
}

fn collectBlock(a: std.mem.Allocator, body: lua.Block, out: *std.ArrayList([]const u8)) anyerror!void {
    for (body) |stmt| switch (stmt.*) {
        .assign => |value| {
            for (value.targets) |target| switch (target) {
                .name => {},
                .index => |index| {
                    try collectExpr(a, index.object, out);
                    try collectExpr(a, index.key, out);
                },
            };
            for (value.values) |expr| try collectExpr(a, expr, out);
        },
        .local_assign => |value| for (value.values) |expr| try collectExpr(a, expr, out),
        .call => |value| try collectExpr(a, value.expr, out),
        .do_block => |value| try collectBlock(a, value.body, out),
        .while_loop => |value| {
            try collectExpr(a, value.cond, out);
            try collectBlock(a, value.body, out);
        },
        .repeat_loop => |value| {
            try collectBlock(a, value.body, out);
            try collectExpr(a, value.cond, out);
        },
        .if_stmt => |value| {
            for (value.branches) |branch| {
                try collectExpr(a, branch.cond, out);
                try collectBlock(a, branch.body, out);
            }
            if (value.else_body) |else_body| try collectBlock(a, else_body, out);
        },
        .numeric_for => |value| {
            try collectExpr(a, value.start, out);
            try collectExpr(a, value.limit, out);
            if (value.step) |step| try collectExpr(a, step, out);
            try collectBlock(a, value.body, out);
        },
        .generic_for => |value| {
            for (value.values) |expr| try collectExpr(a, expr, out);
            try collectBlock(a, value.body, out);
        },
        .function_assign => |value| try collectExpr(a, value.function, out),
        .local_function => |value| try collectExpr(a, value.function, out),
        .return_stmt => |value| for (value.values) |expr| try collectExpr(a, expr, out),
        .empty, .break_stmt => {},
    };
}

pub fn collectStaticRequires(a: std.mem.Allocator, body: lua.Block, out: *std.ArrayList([]const u8)) !void {
    try collectBlock(a, body, out);
}

test "usage scanner finds static invokes and template references" {
    const a = std.testing.allocator;
    var refs: std.ArrayList(Ref) = .empty;
    defer {
        for (refs.items) |ref| a.free(ref.target);
        refs.deinit(a);
    }
    try scanWikitext(
        a,
        "A {{foo|{{#invoke:Bar_baz|run}}}} <nowiki>{{#invoke:Nope|x}}</nowiki> {{T:quux}}",
        &refs,
    );
    try std.testing.expectEqual(@as(usize, 3), refs.items.len);
    try std.testing.expectEqual(RefKind.template, refs.items[0].kind);
    try std.testing.expectEqualStrings("Template:foo", refs.items[0].target);
    try std.testing.expectEqual(RefKind.module, refs.items[1].kind);
    try std.testing.expectEqualStrings("Module:Bar baz", refs.items[1].target);
    try std.testing.expectEqual(RefKind.template, refs.items[2].kind);
    try std.testing.expectEqualStrings("Template:quux", refs.items[2].target);
}

test "usage scanner ignores dynamic and non-template transclusions" {
    const a = std.testing.allocator;
    var refs: std.ArrayList(Ref) = .empty;
    defer {
        for (refs.items) |ref| a.free(ref.target);
        refs.deinit(a);
    }
    try scanWikitext(
        a,
        "{{:Main page}}{{Module:X}}{{Thesaurus:foo}}{{#if:1|{{good}}|{{other}}}}{{{{{name}}}|x}}",
        &refs,
    );
    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
    try std.testing.expectEqualStrings("Template:good", refs.items[0].target);
    try std.testing.expectEqualStrings("Template:other", refs.items[1].target);
}

test "template usage profiling fails soft on malformed transclusion tags" {
    const a = std.testing.allocator;
    var refs: std.ArrayList(Ref) = .empty;
    defer refs.deinit(a);
    try scanTemplateWikitext(a, "A<noinclude>broken {{#invoke:Nope|x}}", &refs);
    try std.testing.expectEqual(@as(usize, 0), refs.items.len);
}

test "static require scanner walks nested Lua functions" {
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, "local a=require('A'); local function f() return require('Module:B_c') end");
    defer chunk.deinit();
    var refs: std.ArrayList([]const u8) = .empty;
    defer {
        for (refs.items) |ref| a.free(ref);
        refs.deinit(a);
    }
    try collectStaticRequires(a, chunk.body, &refs);
    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
    try std.testing.expectEqualStrings("Module:A", refs.items[0]);
    try std.testing.expectEqualStrings("Module:B c", refs.items[1]);
}
