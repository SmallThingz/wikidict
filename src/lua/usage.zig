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

pub const ScanFlags = struct {
    dynamic_module_target: bool = false,
};

fn classifyHead(a: std.mem.Allocator, head: []const u8, out: *std.ArrayList(Ref), flags: *ScanFlags) !void {
    if (head.len == 0) return;
    if (preprocess.findTopDelimiter(head, ':')) |colon| {
        const name = std.mem.trim(u8, head[0..colon], " \t\r\n");
        if (std.ascii.eqlIgnoreCase(name, "#invoke")) {
            if (try canonicalModule(a, head[colon + 1 ..])) |target|
                try out.append(a, .{ .kind = .module, .target = target })
            else
                flags.dynamic_module_target = true;
            return;
        }
    }
    if (try canonicalTemplate(a, head)) |target|
        try out.append(a, .{ .kind = .template, .target = target })
    else if (containsDynamicSyntax(head))
        flags.dynamic_module_target = true;
}

fn scanRange(a: std.mem.Allocator, source: []const u8, out: *std.ArrayList(Ref), flags: *ScanFlags, depth: usize) anyerror!void {
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
                try scanRange(a, source[open + 3 .. end], out, flags, depth + 1);
            pos = @min(end + 3, source.len);
            continue;
        }

        const end = preprocess.findTemplateEnd(source, open) orelse {
            pos = open + 2;
            continue;
        };
        const body = source[open + 2 .. end];
        try classifyHead(a, firstTopLevelPart(body), out, flags);
        if (body.len != 0) try scanRange(a, body, out, flags, depth + 1);
        pos = @min(end + 2, source.len);
    }
}

pub fn scanWikitextFlags(a: std.mem.Allocator, source: []const u8, out: *std.ArrayList(Ref)) !ScanFlags {
    var flags: ScanFlags = .{};
    try scanRange(a, source, out, &flags, 0);
    return flags;
}

pub fn scanWikitext(a: std.mem.Allocator, source: []const u8, out: *std.ArrayList(Ref)) !void {
    _ = try scanWikitextFlags(a, source, out);
}

pub fn scanTemplateWikitextFlags(a: std.mem.Allocator, source: []const u8, out: *std.ArrayList(Ref)) !ScanFlags {
    const body = preprocess.transcludeDecodedAlloc(a, source) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{},
    };
    defer a.free(body);
    var flags: ScanFlags = .{};
    try scanRange(a, body, out, &flags, 0);
    return flags;
}

pub fn scanTemplateWikitext(a: std.mem.Allocator, source: []const u8, out: *std.ArrayList(Ref)) !void {
    _ = try scanTemplateWikitextFlags(a, source, out);
}

fn staticString(expr: *const lua.Expr) ?[]const u8 {
    return switch (expr.*) {
        .string => |value| value.value,
        .paren => |value| staticString(value.expr),
        else => null,
    };
}

fn isMwLoadData(expr: *const lua.Expr) bool {
    if (expr.* != .index) return false;
    const value = expr.index;
    const key = staticString(value.key) orelse return false;
    return value.object.* == .name and
        std.mem.eql(u8, value.object.name.value, "mw") and
        std.mem.eql(u8, key, "loadData");
}

fn collectExpr(a: std.mem.Allocator, expr: *const lua.Expr, out: *std.ArrayList([]const u8), load_data: ?*std.ArrayList([]const u8), dynamic: *bool) anyerror!void {
    switch (expr.*) {
        .paren => |value| try collectExpr(a, value.expr, out, load_data, dynamic),
        .index => |value| {
            try collectExpr(a, value.object, out, load_data, dynamic);
            try collectExpr(a, value.key, out, load_data, dynamic);
        },
        .call => |value| {
            const module_loader =
                (value.callee.* == .name and std.mem.eql(u8, value.callee.name.value, "require")) or
                isMwLoadData(value.callee);
            if (module_loader and value.args.len != 0) {
                if (staticString(value.args[0])) |raw| {
                    if (try canonicalModule(a, raw)) |target| {
                        try out.append(a, target);
                        if (isMwLoadData(value.callee)) if (load_data) |items|
                            try items.append(a, target);
                    }
                } else {
                    dynamic.* = true;
                }
            }
            try collectExpr(a, value.callee, out, load_data, dynamic);
            for (value.args) |arg| try collectExpr(a, arg, out, load_data, dynamic);
        },
        .method_call => |value| {
            try collectExpr(a, value.object, out, load_data, dynamic);
            for (value.args) |arg| try collectExpr(a, arg, out, load_data, dynamic);
        },
        .function => |value| try collectBlock(a, value.body, out, load_data, dynamic),
        .table => |value| for (value.fields) |field| switch (field) {
            .list => |item| try collectExpr(a, item, out, load_data, dynamic),
            .named => |item| try collectExpr(a, item.value, out, load_data, dynamic),
            .keyed => |item| {
                try collectExpr(a, item.key, out, load_data, dynamic);
                try collectExpr(a, item.value, out, load_data, dynamic);
            },
        },
        .unary => |value| try collectExpr(a, value.expr, out, load_data, dynamic),
        .binary => |value| {
            try collectExpr(a, value.lhs, out, load_data, dynamic);
            try collectExpr(a, value.rhs, out, load_data, dynamic);
        },
        else => {},
    }
}

fn collectBlock(a: std.mem.Allocator, body: lua.Block, out: *std.ArrayList([]const u8), load_data: ?*std.ArrayList([]const u8), dynamic: *bool) anyerror!void {
    for (body) |stmt| switch (stmt.*) {
        .assign => |value| {
            for (value.targets) |target| switch (target) {
                .name => {},
                .index => |index| {
                    try collectExpr(a, index.object, out, load_data, dynamic);
                    try collectExpr(a, index.key, out, load_data, dynamic);
                },
            };
            for (value.values) |expr| try collectExpr(a, expr, out, load_data, dynamic);
        },
        .local_assign => |value| for (value.values) |expr| try collectExpr(a, expr, out, load_data, dynamic),
        .call => |value| try collectExpr(a, value.expr, out, load_data, dynamic),
        .do_block => |value| try collectBlock(a, value.body, out, load_data, dynamic),
        .while_loop => |value| {
            try collectExpr(a, value.cond, out, load_data, dynamic);
            try collectBlock(a, value.body, out, load_data, dynamic);
        },
        .repeat_loop => |value| {
            try collectBlock(a, value.body, out, load_data, dynamic);
            try collectExpr(a, value.cond, out, load_data, dynamic);
        },
        .if_stmt => |value| {
            for (value.branches) |branch| {
                try collectExpr(a, branch.cond, out, load_data, dynamic);
                try collectBlock(a, branch.body, out, load_data, dynamic);
            }
            if (value.else_body) |else_body| try collectBlock(a, else_body, out, load_data, dynamic);
        },
        .numeric_for => |value| {
            try collectExpr(a, value.start, out, load_data, dynamic);
            try collectExpr(a, value.limit, out, load_data, dynamic);
            if (value.step) |step| try collectExpr(a, step, out, load_data, dynamic);
            try collectBlock(a, value.body, out, load_data, dynamic);
        },
        .generic_for => |value| {
            for (value.values) |expr| try collectExpr(a, expr, out, load_data, dynamic);
            try collectBlock(a, value.body, out, load_data, dynamic);
        },
        .function_assign => |value| try collectExpr(a, value.function, out, load_data, dynamic),
        .local_function => |value| try collectExpr(a, value.function, out, load_data, dynamic),
        .return_stmt => |value| for (value.values) |expr| try collectExpr(a, expr, out, load_data, dynamic),
        .empty, .break_stmt => {},
    };
}

pub fn collectModuleLoadsDetailed(
    a: std.mem.Allocator,
    body: lua.Block,
    out: *std.ArrayList([]const u8),
    load_data: ?*std.ArrayList([]const u8),
) !bool {
    var dynamic = false;
    try collectBlock(a, body, out, load_data, &dynamic);
    return dynamic;
}

pub fn collectModuleLoads(
    a: std.mem.Allocator,
    body: lua.Block,
    out: *std.ArrayList([]const u8),
) !bool {
    return collectModuleLoadsDetailed(a, body, out, null);
}

pub fn collectStaticRequires(a: std.mem.Allocator, body: lua.Block, out: *std.ArrayList([]const u8)) !void {
    _ = try collectModuleLoads(a, body, out);
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

test "module load scan includes mw.loadData and flags dynamic require" {
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, "local a=mw.loadData('Module:Static_data'); local name='Module:'..'X'; return require(name)");
    defer chunk.deinit();
    var refs: std.ArrayList([]const u8) = .empty;
    defer {
        for (refs.items) |ref| a.free(ref);
        refs.deinit(a);
    }
    const dynamic = try collectModuleLoads(a, chunk.body, &refs);
    try std.testing.expect(dynamic);
    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
    try std.testing.expectEqualStrings("Module:Static data", refs.items[0]);
}

test "wikitext scan flags unresolved invoke and dynamic template targets" {
    const a = std.testing.allocator;
    var refs: std.ArrayList(Ref) = .empty;
    defer {
        for (refs.items) |ref| a.free(ref.target);
        refs.deinit(a);
    }
    const flags = try scanWikitextFlags(a, "{{#invoke:{{{module}}}|run}} {{{{{template}}}|x}}", &refs);
    try std.testing.expect(flags.dynamic_module_target);
}
