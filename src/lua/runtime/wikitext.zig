const std = @import("std");
const rt = @import("zig_runtime");
const host_api = @import("host.zig");
const frame_lib = @import("frame.zig");
const namespace_lib = @import("namespaces.zig");
const preprocess = @import("lua_wikitext_preprocess");
const parser_expr = @import("lua_wikitext_expression");
const language_lib = @import("language.zig");
const uri_lib = @import("uri.zig");
const ustring_lib = @import("ustring.zig");
const text_lib = @import("text.zig");
const stdlib = @import("zig_stdlib");
const Value = rt.Value;

const nowiki_marker_prefix = "\x7f'\"`UNIQ--nowiki-";
const nowiki_marker_suffix = "-QINU`\"'\x7f";

fn makeNowikiMarker(a: std.mem.Allocator, id: u32) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}{X:0>8}{s}", .{ nowiki_marker_prefix, id, nowiki_marker_suffix });
}

fn canonicalExtensionTag(raw: []const u8) ?[]const u8 {
    inline for (&.{
        "nowiki",  "pre",      "gallery",      "indicator",  "ref",             "references", "templatestyles",
        "math",    "ce",       "chem",         "score",      "syntaxhighlight", "source",     "timeline",
        "hiero",   "poem",     "categorytree", "charinsert", "graph",           "mapframe",   "maplink",
        "section", "inputbox", "imagemap",
    }) |name| if (std.ascii.eqlIgnoreCase(raw, name)) return name;
    return null;
}

pub const InstallScribuntoFn = *const fn (
    *?*anyopaque,
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
    pub const InterwikiRow = host_api.InterwikiRow;
    pub const SymbolKind = CallSymbolKind;
    pub const Symbol = CallSymbol;
    ctx: ?*anyopaque = null,
    get: *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!?[]const u8,
    get_transclusion: ?*const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!?[]const u8 = null,
    redirect_target: ?*const fn (?*anyopaque, []const u8) anyerror!?[]const u8 = null,
    exists: *const fn (?*anyopaque, []const u8) anyerror!bool,
    interwiki_map: ?*const fn (?*anyopaque) anyerror![]const InterwikiRow = null,
    resolve_call_symbol: ?*const fn (?*anyopaque, *rt.Context, []const u8, CallSymbolKind) anyerror!?CallSymbol = null,
    get_template_symbol: ?*const fn (?*anyopaque, std.mem.Allocator, usize) anyerror!?[]const u8 = null,
};

pub const Expander = struct {
    runtime: *rt.Context,
    env_slot: u32,
    string_slot: u32,
    mw_slot: u32,
    provider: Provider,
    install_scribunto: ?InstallScribuntoFn = null,
    scribunto_state: ?*anyopaque = null,
    host: host_api.Host = .{},
    current_source: ?[]const u8 = null,
    page_allocator: ?std.mem.Allocator = null,
    page_heading_count: usize = 0,
    fake_heading_count: usize = 0,
    strip_counter: u32 = 0,
    strip_values: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    page_line: std.ArrayList(u8) = .empty,
    max_depth: usize = 128,

    pub fn attach(self: *Expander) void {
        self.host.ctx = self;
        self.host.page_exists = hostPageExists;
        self.host.page_content = hostPageContent;
        self.host.page_redirect = hostPageRedirect;
        self.host.frame_preprocess = hostFramePreprocess;
        self.host.frame_expand_template = hostFrameExpandTemplate;
        self.host.frame_extension_tag = hostFrameExtensionTag;
        self.host.frame_parser_function = hostFrameParserFunction;
        self.host.text_unstrip_no_wiki = hostTextUnstripNoWiki;
        self.host.site_interwiki_map = hostSiteInterwikiMap;
        host_api.set(self.runtime, &self.host);
    }

    pub fn beginPage(self: *Expander, title: []const u8, source: []const u8, now_unix: ?i64) void {
        self.host.current_title = title;
        self.host.now_unix = now_unix;
        self.current_source = source;
        self.page_allocator = self.runtime.allocator;
        self.scribunto_state = null;
        self.page_heading_count = 0;
        self.fake_heading_count = 0;
        self.strip_counter = 0;
        self.strip_values = .empty;
        self.page_line = .empty;
        self.attach();
    }

    fn hostPageContent(raw: ?*anyopaque, a: std.mem.Allocator, title: []const u8) anyerror!?[]const u8 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const canonical = try namespace_lib.canonicalizeTitle(a, title);
        if (std.mem.eql(u8, canonical, self.host.current_title)) if (self.current_source) |source| return source;
        return self.provider.get(self.provider.ctx, a, canonical);
    }

    fn hostPageRedirect(raw: ?*anyopaque, title: []const u8) anyerror!?[]const u8 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const get = self.provider.redirect_target orelse return null;
        const canonical = try namespace_lib.canonicalizeTitle(self.runtime.allocator, title);
        return get(self.provider.ctx, canonical);
    }

    fn hostSiteInterwikiMap(raw: ?*anyopaque) anyerror![]const host_api.InterwikiRow {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const get = self.provider.interwiki_map orelse return error.NotImplemented;
        return get(self.provider.ctx);
    }

    fn hostPageExists(raw: ?*anyopaque, title: []const u8) anyerror!bool {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const canonical = try namespace_lib.canonicalizeTitle(self.runtime.allocator, title);
        if (std.mem.eql(u8, canonical, self.host.current_title) and self.current_source != null) return true;
        if (try self.provider.exists(self.provider.ctx, canonical)) return true;
        if (namespace_lib.ofTitle(canonical).id == 828) {
            _ = self.runtime.resolveModule(canonical) catch return false;
            return true;
        }
        return false;
    }

    pub fn expandFragment(self: *Expander, title: []const u8, source: []const u8, now_unix: ?i64) anyerror![]const u8 {
        self.beginPage(title, source, now_unix);
        if (self.install_scribunto) |install| try install(&self.scribunto_state, self.runtime.allocator, self.runtime, self.env_slot, self.string_slot, self.mw_slot);
        const stripped = try preprocess.stripDecodedComments(self.runtime.allocator, source);
        defer self.runtime.allocator.free(stripped);
        const params = try self.runtime.newTable();
        return self.expandPageWikitext(stripped, params, title);
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

    fn expandPageWikitext(self: *Expander, text: []const u8, params: *rt.Table, host_title: []const u8) anyerror![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var pos: usize = 0;
        while (preprocess.findTemplateOpenOutsideLiteralTags(text, pos)) |open| {
            const literal = text[pos..open];
            try self.observePageOutput(literal);
            try out.appendSlice(self.runtime.allocator, literal);
            const expanded = if (open + 2 < text.len and text[open + 2] == '{') blk: {
                const close = preprocess.findParamEnd(text, open) orelse {
                    const literal_open = "{{{";
                    try self.observePageOutput(literal_open);
                    try out.appendSlice(self.runtime.allocator, literal_open);
                    pos = open + literal_open.len;
                    continue;
                };
                const value = try self.expandParameter(text[open + 3 .. close], params, host_title, 1);
                pos = close + 3;
                break :blk value;
            } else blk: {
                const close = preprocess.findTemplateEnd(text, open) orelse {
                    const literal_open = "{{";
                    try self.observePageOutput(literal_open);
                    try out.appendSlice(self.runtime.allocator, literal_open);
                    pos = open + literal_open.len;
                    continue;
                };
                const value = try self.expandConstruct(text[open + 2 .. close], params, host_title, 1);
                pos = close + 2;
                break :blk value;
            };
            try self.observePageOutput(expanded);
            try out.appendSlice(self.runtime.allocator, expanded);
        }
        const tail = text[pos..];
        try self.observePageOutput(tail);
        try out.appendSlice(self.runtime.allocator, tail);
        return out.toOwnedSlice(self.runtime.allocator);
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

    fn normalizeTransclusionName(self: *Expander, raw: []const u8) ![]const u8 {
        const name = std.mem.trim(u8, raw, " \t\r\n");
        if (name.len == 0) return error.MalformedWikitext;

        if (name[0] == ':') {
            const direct = std.mem.trim(u8, name[1..], " \t\r\n");
            if (direct.len == 0) return error.MalformedWikitext;
            return namespace_lib.canonicalizeTitle(self.runtime.allocator, direct);
        }

        if (std.mem.indexOfScalar(u8, name, ':')) |colon| {
            if (namespace_lib.byName(name[0..colon]) != null)
                return namespace_lib.canonicalizeTitle(self.runtime.allocator, name);
        }

        const out = try self.runtime.allocator.alloc(u8, "Template:".len + name.len);
        @memcpy(out[0.."Template:".len], "Template:");
        @memcpy(out["Template:".len..], name);
        std.mem.replaceScalar(u8, out, '_', ' ');
        return out;
    }

    fn expandTemplateSource(self: *Expander, title: []const u8, raw: []const u8, args: *rt.Table, depth: usize) anyerror![]const u8 {
        const body = try preprocess.transcludeDecodedAlloc(self.runtime.allocator, raw);
        defer self.runtime.allocator.free(body);
        return self.expandWikitext(body, args, title, depth + 1);
    }

    fn expandTemplateByName(self: *Expander, raw_name: []const u8, args: *rt.Table, depth: usize) anyerror![]const u8 {
        if (depth > self.max_depth) return error.TemplateDepth;
        const title = try self.normalizeTransclusionName(raw_name);
        const raw = if (self.provider.get_transclusion) |get|
            (try get(self.provider.ctx, self.runtime.allocator, title)) orelse return error.TemplateNotFound
        else
            (try hostPageContent(self, self.runtime.allocator, title)) orelse return error.TemplateNotFound;
        return self.expandTemplateSource(title, raw, args, depth);
    }

    fn expandTemplateBySymbol(self: *Expander, symbol: CallSymbol, args: *rt.Table, depth: usize) anyerror![]const u8 {
        if (depth > self.max_depth) return error.TemplateDepth;
        const title = try self.normalizeTransclusionName(symbol.text);
        const raw = if (self.provider.get_template_symbol) |get|
            (try get(self.provider.ctx, self.runtime.allocator, symbol.id)) orelse return error.TemplateNotFound
        else if (self.provider.get_transclusion) |get|
            (try get(self.provider.ctx, self.runtime.allocator, title)) orelse return error.TemplateNotFound
        else
            (try hostPageContent(self, self.runtime.allocator, title)) orelse return error.TemplateNotFound;
        return self.expandTemplateSource(title, raw, args, depth);
    }

    fn expandWikitext(self: *Expander, text: []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        if (depth > self.max_depth) return error.TemplateDepth;
        var out: std.ArrayList(u8) = .empty;
        var pos: usize = 0;
        while (preprocess.findTemplateOpenOutsideLiteralTags(text, pos)) |open| {
            try out.appendSlice(self.runtime.allocator, text[pos..open]);
            if (open + 2 < text.len and text[open + 2] == '{') {
                const close = preprocess.findParamEnd(text, open) orelse {
                    try out.appendSlice(self.runtime.allocator, "{{{");
                    pos = open + 3;
                    continue;
                };
                const expanded = try self.expandParameter(text[open + 3 .. close], params, host_title, depth + 1);
                try out.appendSlice(self.runtime.allocator, expanded);
                pos = close + 3;
            } else {
                const close = preprocess.findTemplateEnd(text, open) orelse {
                    try out.appendSlice(self.runtime.allocator, "{{");
                    pos = open + 2;
                    continue;
                };
                const expanded = try self.expandConstruct(text[open + 2 .. close], params, host_title, depth + 1);
                try out.appendSlice(self.runtime.allocator, expanded);
                pos = close + 2;
            }
        }
        try out.appendSlice(self.runtime.allocator, text[pos..]);
        return out.toOwnedSlice(self.runtime.allocator);
    }

    fn expandParameter(self: *Expander, inside: []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const split = preprocess.splitParameter(inside);
        const expanded_key = try self.expandWikitext(split.key, params, host_title, depth + 1);
        const key_text = std.mem.trim(u8, expanded_key, " \t\r\n");
        const key: Value = if (std.fmt.parseInt(i64, key_text, 10)) |number|
            .{ .number = @floatFromInt(number) }
        else |_|
            .{ .string = key_text };
        if (params.rawGet(key)) |value| return self.valueToWikitext(value);
        if (split.default) |fallback| return self.expandWikitext(fallback, params, host_title, depth + 1);
        return std.fmt.allocPrint(self.runtime.allocator, "{{{{{{{s}}}}}}}", .{inside});
    }

    fn buildExpandedArgs(self: *Expander, raw_args: []const []const u8, caller_params: *rt.Table, host_title: []const u8, depth: usize) anyerror!*rt.Table {
        const out = try self.runtime.newTable();
        var positional: i64 = 1;
        for (raw_args) |raw| {
            if (preprocess.findTopDelimiter(raw, '=')) |eq| {
                const key_expanded = try self.expandWikitext(raw[0..eq], caller_params, host_title, depth + 1);
                const key_text = std.mem.trim(u8, key_expanded, " \t\r\n");
                if (key_text.len == 0) continue;
                const key: Value = if (std.fmt.parseInt(i64, key_text, 10)) |number|
                    .{ .number = @floatFromInt(number) }
                else |_|
                    .{ .string = key_text };
                const value_raw = std.mem.trim(u8, raw[eq + 1 ..], " \t\r\n");
                const value = try self.expandWikitext(value_raw, caller_params, host_title, depth + 1);
                try out.rawSet(self.runtime.allocator, key, .{ .string = value });
            } else {
                const value = try self.expandWikitext(raw, caller_params, host_title, depth + 1);
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

    fn isTitleMagicName(raw: []const u8) bool {
        inline for (&.{
            "PAGENAME",     "FULLPAGENAME", "NAMESPACE",       "NAMESPACENUMBER",
            "BASEPAGENAME", "ROOTPAGENAME", "SUBPAGENAME",     "SUBJECTSPACE",
            "ARTICLESPACE", "TALKSPACE",    "SUBJECTPAGENAME", "ARTICLEPAGENAME",
            "TALKPAGENAME",
        }) |name| if (std.ascii.eqlIgnoreCase(raw, name)) return true;
        return false;
    }

    fn namespacedPageAlloc(self: *Expander, spec: namespace_lib.Spec, text: []const u8) ![]const u8 {
        if (spec.id == 0) return text;
        return std.fmt.allocPrint(self.runtime.allocator, "{s}:{s}", .{ spec.name, text });
    }

    fn titleMagic(self: *Expander, raw_name: []const u8, raw_page: ?[]const u8) !?[]const u8 {
        const name = std.mem.trim(u8, raw_name, " \t\r\n");
        if (!isTitleMagicName(name)) return null;
        const requested = if (raw_page) |value| blk: {
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            break :blk if (trimmed.len == 0) self.host.current_title else trimmed;
        } else self.host.current_title;
        const canonical_with_fragment = try namespace_lib.canonicalizeTitle(self.runtime.allocator, requested);
        const page = if (std.mem.indexOfScalar(u8, canonical_with_fragment, '#')) |hash|
            canonical_with_fragment[0..hash]
        else
            canonical_with_fragment;
        const ns = namespace_lib.ofTitle(page);
        if (std.ascii.eqlIgnoreCase(name, "PAGENAME")) return ns.text;
        if (std.ascii.eqlIgnoreCase(name, "FULLPAGENAME")) return page;
        if (std.ascii.eqlIgnoreCase(name, "NAMESPACE")) return ns.name;
        if (std.ascii.eqlIgnoreCase(name, "NAMESPACENUMBER")) return self.formatMagic("{d}", .{ns.id});
        if (std.ascii.eqlIgnoreCase(name, "BASEPAGENAME"))
            return if (std.mem.lastIndexOfScalar(u8, ns.text, '/')) |slash| ns.text[0..slash] else ns.text;
        if (std.ascii.eqlIgnoreCase(name, "ROOTPAGENAME"))
            return if (std.mem.indexOfScalar(u8, ns.text, '/')) |slash| ns.text[0..slash] else ns.text;
        if (std.ascii.eqlIgnoreCase(name, "SUBPAGENAME"))
            return if (std.mem.lastIndexOfScalar(u8, ns.text, '/')) |slash| ns.text[slash + 1 ..] else ns.text;

        const subject = namespace_lib.subjectSpec(ns.id) orelse return "";
        if (std.ascii.eqlIgnoreCase(name, "SUBJECTSPACE") or std.ascii.eqlIgnoreCase(name, "ARTICLESPACE"))
            return subject.name;
        if (std.ascii.eqlIgnoreCase(name, "SUBJECTPAGENAME") or std.ascii.eqlIgnoreCase(name, "ARTICLEPAGENAME"))
            return @as(?[]const u8, try self.namespacedPageAlloc(subject, ns.text));
        const talk = namespace_lib.talkSpec(ns.id) orelse return "";
        if (std.ascii.eqlIgnoreCase(name, "TALKSPACE")) return talk.name;
        if (std.ascii.eqlIgnoreCase(name, "TALKPAGENAME")) return @as(?[]const u8, try self.namespacedPageAlloc(talk, ns.text));
        unreachable;
    }

    fn magicWord(self: *Expander, raw: []const u8) !?[]const u8 {
        const head = std.mem.trim(u8, raw, " \t\r\n");
        if (try self.titleMagic(head, null)) |value| return value;
        if (std.mem.eql(u8, head, "!")) return "|";
        if (std.mem.eql(u8, head, "!!")) return "||";
        if (std.mem.eql(u8, head, "=")) return "=";
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
        const mw = self.runtime.getGlobal(self.mw_slot);
        if (mw != .table) return error.MissingMw;
        const ustring = try self.runtime.getIndex(mw, .{ .string = "ustring" });
        if (ustring != .table) return error.MissingUstring;
        const callable = try self.runtime.getIndex(ustring, .{ .string = if (upper) "upper" else "lower" });
        const result = try self.runtime.callValue(callable, &.{.{ .string = text }});
        defer rt.freeResults(result);
        if (result.len == 0 or result[0] != .string) return error.StringExpected;
        return result[0].string;
    }

    fn expandCaseParser(self: *Expander, raw: []const u8, params: *rt.Table, host_title: []const u8, depth: usize, upper: bool, first_only: bool) anyerror![]const u8 {
        const expanded = try self.expandWikitext(raw, params, host_title, depth + 1);
        if (!first_only or expanded.len == 0) return self.unicodeCase(expanded, upper);
        const first_len = std.unicode.utf8ByteSequenceLength(expanded[0]) catch return error.InvalidUtf8;
        if (first_len > expanded.len) return error.InvalidUtf8;
        const first = try self.unicodeCase(expanded[0..first_len], upper);
        return std.fmt.allocPrint(self.runtime.allocator, "{s}{s}", .{ first, expanded[first_len..] });
    }

    fn numericStringEqual(lhs: []const u8, rhs: []const u8) bool {
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

    fn expandIfEq(self: *Expander, lhs_raw: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const lhs = std.mem.trim(u8, try self.expandWikitext(lhs_raw, params, host_title, depth + 1), " \t\r\n");
        const rhs = if (args.len != 0) std.mem.trim(u8, try self.expandWikitext(args[0], params, host_title, depth + 1), " \t\r\n") else "";
        const chosen = if (ifEqEqual(lhs, rhs))
            (if (args.len > 1) args[1] else "")
        else
            (if (args.len > 2) args[2] else "");
        return self.expandWikitext(chosen, params, host_title, depth + 1);
    }

    fn expandSwitch(self: *Expander, key_raw: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const key = std.mem.trim(u8, try self.expandWikitext(key_raw, params, host_title, depth + 1), " \t\r\n");
        var pending = false;
        var fallback: ?[]const u8 = null;
        var trailing: ?[]const u8 = null;
        for (args) |raw_case| {
            if (preprocess.findTopDelimiter(raw_case, '=')) |eq| {
                const label_raw = std.mem.trim(u8, raw_case[0..eq], " \t\r\n");
                const value_raw = raw_case[eq + 1 ..];
                if (std.ascii.eqlIgnoreCase(label_raw, "#default")) {
                    fallback = value_raw;
                    if (pending) return self.expandWikitext(value_raw, params, host_title, depth + 1);
                    continue;
                }
                const label = std.mem.trim(u8, try self.expandWikitext(label_raw, params, host_title, depth + 1), " \t\r\n");
                if (pending or std.mem.eql(u8, key, label)) return self.expandWikitext(value_raw, params, host_title, depth + 1);
                pending = false;
            } else {
                trailing = raw_case;
                const label = std.mem.trim(u8, try self.expandWikitext(raw_case, params, host_title, depth + 1), " \t\r\n");
                if (std.mem.eql(u8, key, label)) pending = true;
            }
        }
        if (fallback) |value| return self.expandWikitext(value, params, host_title, depth + 1);
        if (trailing) |value| return self.expandWikitext(value, params, host_title, depth + 1);
        return "";
    }

    fn expandIfExist(self: *Expander, raw_title: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        var title = std.mem.trim(u8, try self.expandWikitext(raw_title, params, host_title, depth + 1), " \t\r\n");
        if (title.len != 0 and title[0] == ':') title = std.mem.trim(u8, title[1..], " \t\r\n");
        if (std.mem.indexOfScalar(u8, title, '#')) |hash| title = title[0..hash];
        const exists = title.len != 0 and try hostPageExists(self, title);
        const chosen = if (exists) (if (args.len > 0) args[0] else "") else (if (args.len > 1) args[1] else "");
        return self.expandWikitext(chosen, params, host_title, depth + 1);
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
        const tested = try self.expandWikitext(raw_test, params, host_title, depth + 1);
        const failed = std.mem.indexOf(u8, tested, "class=\"error\"") != null;
        if (failed)
            return self.expandWikitext(if (args.len > 0) args[0] else "", params, host_title, depth + 1);
        if (args.len > 1) return self.expandWikitext(args[1], params, host_title, depth + 1);
        return tested;
    }

    fn expandExprParser(self: *Expander, raw: []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const expanded = std.mem.trim(u8, try self.expandWikitext(raw, params, host_title, depth + 1), " \t\r\n");
        const value = parser_expr.eval(self.runtime.allocator, expanded) catch |err| return self.exprError(err);
        return parser_expr.format(self.runtime.allocator, value) catch |err| return self.exprError(err);
    }

    fn expandIfExpr(self: *Expander, raw: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const expanded = std.mem.trim(u8, try self.expandWikitext(raw, params, host_title, depth + 1), " \t\r\n");
        const value = parser_expr.eval(self.runtime.allocator, expanded) catch |err| return self.exprError(err);
        const chosen = if (value != 0) (if (args.len > 0) args[0] else "") else (if (args.len > 1) args[1] else "");
        return self.expandWikitext(chosen, params, host_title, depth + 1);
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

    fn expandUrlParser(self: *Expander, raw: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize, kind: uri_lib.WikiUrlKind, escaped: bool) anyerror![]const u8 {
        const title = std.mem.trim(u8, try self.expandWikitext(raw, params, host_title, depth + 1), " \t\r\n");
        const query: ?[]const u8 = if (args.len == 0) null else try self.expandWikitext(args[0], params, host_title, depth + 1);
        return uri_lib.buildWikiUrlRawQuery(self.runtime.allocator, title, query, kind, escaped, null);
    }

    fn expandUrlencodeParser(self: *Expander, raw: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const source = try self.expandWikitext(raw, params, host_title, depth + 1);
        const mw = self.runtime.getGlobal(self.mw_slot);
        const uri = try self.runtime.getIndex(mw, .{ .string = "uri" });
        const encode = try self.runtime.getIndex(uri, .{ .string = "encode" });
        var call_args: [2]Value = undefined;
        call_args[0] = .{ .string = source };
        var count: usize = 1;
        if (args.len != 0) {
            const mode = std.mem.trim(u8, try self.expandWikitext(args[0], params, host_title, depth + 1), " \t\r\n");
            if (mode.len != 0) {
                call_args[1] = .{ .string = mode };
                count = 2;
            }
        }
        const result = try self.runtime.callValue(encode, call_args[0..count]);
        defer rt.freeResults(result);
        if (result.len == 0 or result[0] != .string) return error.StringExpected;
        return result[0].string;
    }

    fn copyArgsTable(runtime: *rt.Context, source: *rt.Table) !*rt.Table {
        const out = try runtime.newTable();
        var it = source.iterator();
        while (it.next()) |entry| try out.rawSet(runtime.allocator, entry.key_ptr.*, entry.value_ptr.*);
        return out;
    }

    fn callSymbol(self: *Expander, raw: []const u8, kind: CallSymbolKind) anyerror!?CallSymbol {
        const resolve = self.provider.resolve_call_symbol orelse return null;
        return resolve(self.provider.ctx, self.runtime, raw, kind);
    }

    fn expandInvoke(self: *Expander, module_expr: []const u8, args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const module_symbol = try self.callSymbol(module_expr, .module);
        const module_raw = if (module_symbol) |symbol|
            symbol.text
        else
            try self.expandWikitext(module_expr, params, host_title, depth + 1);
        const module_trimmed = std.mem.trim(u8, module_raw, " \t\r\n");
        var module_buffer: [4096]u8 = undefined;
        const module_name = if (module_trimmed.len >= 7 and std.ascii.eqlIgnoreCase(module_trimmed[0..7], "Module:"))
            module_trimmed
        else
            std.fmt.bufPrint(&module_buffer, "Module:{s}", .{module_trimmed}) catch return error.ModuleNameTooLong;
        const function_symbol = if (args.len != 0) try self.callSymbol(args[0], .function) else null;
        const function_name = if (function_symbol) |symbol|
            symbol.text
        else if (args.len != 0)
            std.mem.trim(u8, try self.expandWikitext(args[0], params, host_title, depth + 1), " \t\r\n")
        else
            "main";

        const runtime = self.runtime;
        const invoke_args = try self.buildExpandedArgs(if (args.len > 0) args[1..] else &.{}, params, host_title, depth + 1);
        const parent_args = try copyArgsTable(runtime, params);
        const parent = try frame_lib.makeFrameFromTable(runtime, host_title, parent_args, null);
        const frame = try frame_lib.makeFrameFromTable(runtime, module_name, invoke_args, parent);
        const result = if (module_symbol) |symbol|
            if (symbol.module_id) |module_id|
                try frame_lib.invokeModuleId(runtime, module_id, module_name, function_name, frame)
            else
                try frame_lib.invoke(runtime, module_name, function_name, frame)
        else
            try frame_lib.invoke(runtime, module_name, function_name, frame);
        defer rt.freeResults(result);
        if (result.len == 0) return "";
        return self.valueToWikitext(result[0]);
    }

    fn expandTagParser(self: *Expander, raw_tag: []const u8, raw_args: []const []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        const tag = std.mem.trim(u8, try self.expandWikitext(raw_tag, params, host_title, depth + 1), " \t\r\n");
        const canonical = canonicalExtensionTag(tag) orelse return error.UnsupportedExtensionTag;
        const content: ?Value = if (raw_args.len == 0)
            .{ .string = "" }
        else
            .{ .string = try self.expandWikitext(raw_args[0], params, host_title, depth + 1) };
        var attrs: ?*rt.Table = null;
        if (raw_args.len > 1) {
            const table = try self.runtime.newTable();
            for (raw_args[1..]) |raw| {
                const eq = preprocess.findTopDelimiter(raw, '=') orelse continue;
                const key = std.mem.trim(u8, try self.expandWikitext(raw[0..eq], params, host_title, depth + 1), " \t\r\n");
                if (key.len == 0) continue;
                const value = try self.expandWikitext(raw[eq + 1 ..], params, host_title, depth + 1);
                try table.rawSet(self.runtime.allocator, .{ .string = key }, .{ .string = value });
            }
            attrs = table;
        }
        return self.serializeExtension(canonical, content, attrs);
    }

    fn expandConstruct(self: *Expander, content: []const u8, params: *rt.Table, host_title: []const u8, depth: usize) anyerror![]const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(self.runtime.allocator);
        try preprocess.splitWikitextTop(self.runtime.allocator, content, '|', &parts);
        if (parts.items.len == 0) return error.MalformedWikitext;
        var raw_head = std.mem.trim(u8, parts.items[0], " \t\r\n");
        if (raw_head.len >= 10 and std.ascii.eqlIgnoreCase(raw_head[0..10], "safesubst:"))
            raw_head = std.mem.trim(u8, raw_head[10..], " \t\r\n")
        else if (raw_head.len >= 6 and std.ascii.eqlIgnoreCase(raw_head[0..6], "subst:"))
            raw_head = std.mem.trim(u8, raw_head[6..], " \t\r\n");
        if (raw_head.len == 0) return error.MalformedWikitext;
        if (try self.magicWord(raw_head)) |value| return value;

        if (preprocess.findTopDelimiter(raw_head, ':')) |colon| {
            const name = std.mem.trim(u8, raw_head[0..colon], " \t\r\n");
            const first = raw_head[colon + 1 ..];
            if (isTitleMagicName(name)) {
                const page = try self.expandWikitext(first, params, host_title, depth + 1);
                return (try self.titleMagic(name, page)) orelse unreachable;
            }
            if (std.ascii.eqlIgnoreCase(name, "ns")) {
                const raw_ns = std.mem.trim(u8, try self.expandWikitext(first, params, host_title, depth + 1), " \t\r\n");
                const spec = if (std.fmt.parseInt(i32, raw_ns, 10)) |id|
                    namespace_lib.byId(id)
                else |_|
                    namespace_lib.byName(raw_ns);
                return (spec orelse return error.InvalidNamespace).name;
            }
            if (std.ascii.eqlIgnoreCase(name, "uc")) return self.expandCaseParser(first, params, host_title, depth + 1, true, false);
            if (std.ascii.eqlIgnoreCase(name, "lc")) return self.expandCaseParser(first, params, host_title, depth + 1, false, false);
            if (std.ascii.eqlIgnoreCase(name, "ucfirst")) return self.expandCaseParser(first, params, host_title, depth + 1, true, true);
            if (std.ascii.eqlIgnoreCase(name, "lcfirst")) return self.expandCaseParser(first, params, host_title, depth + 1, false, true);
            if (std.ascii.eqlIgnoreCase(name, "fullurl")) return self.expandUrlParser(first, parts.items[1..], params, host_title, depth + 1, .full, false);
            if (std.ascii.eqlIgnoreCase(name, "fullurle")) return self.expandUrlParser(first, parts.items[1..], params, host_title, depth + 1, .full, true);
            if (std.ascii.eqlIgnoreCase(name, "localurl")) return self.expandUrlParser(first, parts.items[1..], params, host_title, depth + 1, .local, false);
            if (std.ascii.eqlIgnoreCase(name, "canonicalurl")) return self.expandUrlParser(first, parts.items[1..], params, host_title, depth + 1, .canonical, false);
            if (std.ascii.eqlIgnoreCase(name, "urlencode")) return self.expandUrlencodeParser(first, parts.items[1..], params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "padleft")) return self.expandPadParser(first, parts.items[1..], params, host_title, depth + 1, true);
            if (std.ascii.eqlIgnoreCase(name, "padright")) return self.expandPadParser(first, parts.items[1..], params, host_title, depth + 1, false);
            if (std.ascii.eqlIgnoreCase(name, "#time")) return self.expandTimeParser(first, parts.items[1..], params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#sub")) return self.expandSubParser(first, parts.items[1..], params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#iferror")) return self.expandIfError(first, parts.items[1..], params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#invoke")) return self.expandInvoke(first, parts.items[1..], params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#if")) {
                const condition = try self.expandWikitext(first, params, host_title, depth + 1);
                const chosen = if (std.mem.trim(u8, condition, " \t\r\n").len != 0)
                    (if (parts.items.len > 1) parts.items[1] else "")
                else
                    (if (parts.items.len > 2) parts.items[2] else "");
                return self.expandWikitext(chosen, params, host_title, depth + 1);
            }
            if (std.ascii.eqlIgnoreCase(name, "#ifeq")) return self.expandIfEq(first, parts.items[1..], params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#ifexist")) return self.expandIfExist(first, parts.items[1..], params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#switch")) return self.expandSwitch(first, parts.items[1..], params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#expr")) return self.expandExprParser(first, params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#ifexpr")) return self.expandIfExpr(first, parts.items[1..], params, host_title, depth + 1);
            if (std.ascii.eqlIgnoreCase(name, "#tag")) return self.expandTagParser(first, parts.items[1..], params, host_title, depth + 1);
            if (name.len != 0 and name[0] == '#') return error.UnsupportedParserFunction;
        }
        if (raw_head[0] == '#') return error.UnsupportedParserFunction;
        if (try self.callSymbol(raw_head, .template)) |symbol| {
            const args = try self.buildExpandedArgs(parts.items[1..], params, host_title, depth + 1);
            return self.expandTemplateBySymbol(symbol, args, depth + 1);
        }
        const title = try self.expandWikitext(raw_head, params, host_title, depth + 1);
        const args = try self.buildExpandedArgs(parts.items[1..], params, host_title, depth + 1);
        return self.expandTemplateByName(title, args, depth + 1);
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

    fn serializeExtension(self: *Expander, name: []const u8, content: ?Value, attrs: ?*rt.Table) ![]const u8 {
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
                try out.appendSlice(a, key);
                try out.appendSlice(a, "=\"");
                try appendAttrEscaped(&out, a, try self.scalarText(table.rawGet(.{ .string = key }).?));
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

    fn hostFramePreprocess(raw: ?*anyopaque, a: std.mem.Allocator, source: []const u8, title: []const u8, args: *rt.Table) anyerror![]const u8 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        const stripped = try preprocess.stripDecodedComments(a, source);
        defer a.free(stripped);
        if (stripped.len >= 2 and stripped[0] == '=' and stripped[stripped.len - 1] == '=' and
            std.mem.indexOf(u8, stripped, nowiki_marker_prefix) != null)
        {
            const number = self.page_heading_count + self.fake_heading_count;
            self.fake_heading_count += 1;
            return std.fmt.allocPrint(a, "\x7f'\"`UNIQ--h-{d}--QINU`\"'\x7f", .{number});
        }
        return self.expandWikitext(stripped, args, title, 0);
    }

    fn hostFrameExpandTemplate(raw: ?*anyopaque, _: std.mem.Allocator, title: []const u8, args: *rt.Table) anyerror![]const u8 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        return self.expandTemplateByName(title, args, 0);
    }

    fn hostFrameExtensionTag(raw: ?*anyopaque, a: std.mem.Allocator, name: []const u8, content: ?Value, attrs: ?*rt.Table) anyerror![]const u8 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        if (std.ascii.eqlIgnoreCase(name, "nowiki")) {
            const text = if (content) |value| if (value == .string) value.string else "" else "";
            const id = self.strip_counter;
            self.strip_counter +%= 1;
            const page_a = self.page_allocator orelse return error.MissingPageAllocator;
            const stored = try page_a.dupe(u8, text);
            try self.strip_values.put(page_a, id, stored);
            return makeNowikiMarker(a, id);
        }
        const canonical = canonicalExtensionTag(name) orelse return error.UnsupportedExtensionTag;
        return self.serializeExtension(canonical, content, attrs);
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
            if (self.strip_values.get(id)) |text|
                try out.appendSlice(a, text)
            else
                try out.appendSlice(a, source[at..marker_end]);
            pos = marker_end;
        }
        try out.appendSlice(a, source[pos..]);
        return out.toOwnedSlice(a);
    }

    fn formattedDateSpan(self: *Expander, raw: []const u8, style_raw: ?[]const u8) ![]const u8 {
        const parsed = language_lib.parseExplicitDate(raw) catch return raw;
        if (!parsed.has_day) return raw;
        const civil = parsed.civil;
        const months = [_][]const u8{
            "January", "February", "March",     "April",   "May",      "June",
            "July",    "August",   "September", "October", "November", "December",
        };
        const canonical = try std.fmt.allocPrint(self.runtime.allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(civil.year)), civil.month, civil.day });
        const style = if (style_raw) |value| std.mem.trim(u8, value, " \t\r\n") else "";
        const display = if (style.len == 0)
            raw
        else if (std.ascii.eqlIgnoreCase(style, "dmy"))
            try std.fmt.allocPrint(self.runtime.allocator, "{d} {s} {d}", .{ civil.day, months[civil.month - 1], civil.year })
        else if (std.ascii.eqlIgnoreCase(style, "mdy"))
            try std.fmt.allocPrint(self.runtime.allocator, "{s} {d}, {d}", .{ months[civil.month - 1], civil.day, civil.year })
        else if (std.ascii.eqlIgnoreCase(style, "ymd"))
            try std.fmt.allocPrint(self.runtime.allocator, "{d} {s} {d}", .{ civil.year, months[civil.month - 1], civil.day })
        else if (std.ascii.eqlIgnoreCase(style, "ISO 8601")) canonical else raw;
        return std.fmt.allocPrint(self.runtime.allocator, "<span class=\"mw-formatted-date\" title=\"{s}\">{s}</span>", .{ canonical, display });
    }

    fn hostFrameParserFunction(raw: ?*anyopaque, _: std.mem.Allocator, name: []const u8, first: ?Value, second: ?Value) anyerror![]const u8 {
        const self: *Expander = @ptrCast(@alignCast(raw orelse return error.MissingWikitextHost));
        if (std.ascii.eqlIgnoreCase(name, "DEFAULTSORT") or std.ascii.eqlIgnoreCase(name, "DISPLAYTITLE")) return "";
        if (std.ascii.eqlIgnoreCase(name, "#formatdate")) {
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
    const mw = try runtime.newNativeNamespace(.mw);
    const ustring = try runtime.newNativeNamespace(.ustring);
    const string = runtime.getGlobal(string_slot);
    if (string != .table) return error.MissingStringLibrary;
    var it = string.table.iterator();
    while (it.next()) |entry| try ustring.rawSet(runtime.allocator, entry.key_ptr.*, entry.value_ptr.*);
    try ustring_lib.install(runtime, ustring);
    try mw.rawSet(runtime.allocator, .{ .string = "ustring" }, .{ .table = ustring });
    try text_lib.install(runtime, mw);
    try uri_lib.install(runtime, mw);
    try runtime.setGlobal(mw_slot, .{ .table = mw });
}

const TestProvider = struct {
    fn get(_: ?*anyopaque, _: std.mem.Allocator, title: []const u8) !?[]const u8 {
        if (std.mem.eql(u8, title, "Template:Hello")) return "Hi {{{1|friend}}} {{#if:{{{2|}}}|Y|N}}";
        if (std.mem.eql(u8, title, "Template:Only")) return "A<noinclude>X</noinclude>B<includeonly>C</includeonly>D";
        if (std.mem.eql(u8, title, "Main page")) return "main-transclusion";
        if (std.mem.eql(u8, title, "Wiktionary:Sandbox")) return "project-transclusion";
        return null;
    }
    fn exists(_: ?*anyopaque, title: []const u8) !bool {
        return std.mem.eql(u8, title, "Exists") or std.mem.eql(u8, title, "Wiktionary:Sandbox");
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
};

const TestModule = struct {
    fn lookup(_: ?*const anyopaque, raw_name: []const u8) ?u32 {
        return if (std.mem.eql(u8, raw_name, "Module:Test")) 0 else null;
    }
    fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
        return if (id == 0) "Module:Test" else null;
    }
    fn root(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        const exports = try ctx.newTable();
        try exports.rawSet(ctx.allocator, .{ .string = "run" }, try ctx.makeFunctionKnown(1, run, &.{}));
        try exports.rawSet(ctx.allocator, .{ .string = "fail" }, try ctx.makeFunctionKnown(2, fail, &.{}));
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
    fn fail(_: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        return error.NotCallable;
    }
};

test "native AOT wikitext expands templates parser functions and invoke" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.initProgram(arena.allocator(), 24, 1);
    defer runtime.deinit();
    const functions = [_]rt.FunctionFn{ rt.stabilize(TestModule.root), rt.stabilize(TestModule.run), rt.stabilize(TestModule.fail) };
    runtime.module_root_entries = &functions;
    runtime.configureModules(null, TestModule.lookup, TestModule.name);
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);

    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists } };
    const source = "{{Hello|Bob|1}}|{{Only}}|{{:Main_page}}|{{WT:Sandbox}}|{{T:Hello|Z|1}}|{{#ifeq:a|a|yes|no}}|{{#switch:x|y=no|x=yes|#default=d}}|{{#expr:2+3*4}}|{{#ifexist:Exists|E|N}}|{{#ifexist:WT:Sandbox|W|N}}|{{uc:hé}}|{{padleft:é|3|ø}}|{{CURRENTYEAR}}|{{#tag:ref|body|name=n}}|{{#tag:math|x+y}}|{{#tag:poem|one\ntwo}}|{{#invoke:Test|run|x=ok}}";
    const current_magic = try expander.expandFragment("Appendix:Page/Sub", "{{CURRENTDAYNAME}}|{{CURRENTWEEK}}|{{CURRENTMONTHNAMEGEN}}", 1_670_803_200);
    try std.testing.expectEqualStrings("Monday|50|December", current_magic);
    const got = try expander.expandFragment("Appendix:Page/Sub", source, 1_670_803_200);
    try std.testing.expectEqualStrings("Hi Bob Y|ABCD|main-transclusion|project-transclusion|Hi Z Y|yes|yes|14|E|W|HÉ|øøé|2022|<ref name=\"n\">body</ref>|<math>x+y</math>|<poem>one\ntwo</poem>|ok", got);
    const protected = try expander.expandFragment("Page", "<nowiki>{{Hello|Bob|1}}</nowiki>|{{Hello|A|}}", 1_670_803_200);
    try std.testing.expectEqualStrings("<nowiki>{{Hello|Bob|1}}</nowiki>|Hi A N", protected);
    const extension_bodies = try expander.expandFragment(
        "Page",
        "<math>{{Hello|M|1}}</math>|<syntaxhighlight>{{Hello|S|1}}</syntaxhighlight>|<ref>{{Hello|R|1}}</ref>|<poem>{{Hello|P|1}}</poem>",
        1_670_803_200,
    );
    try std.testing.expectEqualStrings(
        "<math>{{Hello|M|1}}</math>|<syntaxhighlight>{{Hello|S|1}}</syntaxhighlight>|<ref>Hi R Y</ref>|<poem>Hi P Y</poem>",
        extension_bodies,
    );
    try std.testing.expect(runtime.current_frame == null);
    var symbolic_expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists, .resolve_call_symbol = TestProvider.resolveCallSymbol, .get_template_symbol = TestProvider.getTemplateSymbol } };
    const symbolic = try symbolic_expander.expandFragment("Page", "{{PAGENAME}}|{{@template|Bob|1}}|{{#invoke:@module|@function|x=symbolic}}", 1_670_803_200);
    try std.testing.expectEqualStrings("Page|Hi Bob Y|symbolic", symbolic);
    try std.testing.expectError(error.AotCallFailed, expander.expandFragment("Page", "{{#invoke:Test|fail}}", 1_670_803_200));
    try std.testing.expectEqualStrings("NotCallable", runtime.aotErrorName().?);
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
}

test "bundle parser functions cover corpus time sub and iferror forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 24);
    defer runtime.deinit();
    try rt.bindGlobalTable(&runtime, null, 0);
    try stdlib.install(&runtime);
    try installTestHost(&runtime, 18, 23);
    var expander = Expander{ .runtime = &runtime, .env_slot = 0, .string_slot = 18, .mw_slot = 23, .provider = .{ .get = TestProvider.get, .exists = TestProvider.exists } };
    const source = "{{#time:Y M d|2013-3-31 +8 days}}|{{#time:/Y/F|2025-9}}|{{#sub:αβγ|-1}}|{{#sub:αβγ|0|-1}}|{{#iferror:{{#expr:bogus}}|ERR|OK}}|{{#iferror:plain|ERR|OK}}|{{#ifeq:01|1|NUM|BAD}}|{{#ifeq:+1.0|1|FLOAT|BAD}}|{{#ifeq:01x|1|BAD|TEXT}}|{{#ifeq:9007199254740993|9007199254740992|BAD|BIG}}|{{ns:0}}/{{ns:4}}/{{ns:Project}}/{{ns:MOD}}";
    const got = try expander.expandFragment("Page", source, 1_670_803_200);
    try std.testing.expectEqualStrings("2013 Apr 08|/2025/September|γ|αβ|ERR|OK|NUM|FLOAT|TEXT|BIG|/Wiktionary/Wiktionary/Module", got);
    try std.testing.expectError(error.InvalidNamespace, expander.expandFragment("Page", "{{ns:not-a-namespace}}", 1_670_803_200));

    expander.beginPage("Page", "source", 1_670_803_200);
    const frame_args = try runtime.newTable();
    const frame = try frame_lib.makeFrameFromTable(&runtime, "Template:Host", frame_args, null);
    const parser = try runtime.getIndex(frame, .{ .string = "callParserFunction" });
    const dated = try runtime.callValue(parser, &.{ frame, .{ .string = "#time" }, .{ .string = "Y-m-d" }, .{ .string = "2023-4-2 +8 days" } });
    defer rt.freeResults(dated);
    try std.testing.expectEqualStrings("2023-04-10", dated[0].string);
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
    const date = try runtime.callValue(parser, &.{ frame, .{ .string = "#formatdate" }, .{ .string = "12-December-2022" }, .{ .string = "dmy" } });
    defer rt.freeResults(date);
    try std.testing.expectEqualStrings("<span class=\"mw-formatted-date\" title=\"2022-12-12\">12 December 2022</span>", date[0].string);
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
}
