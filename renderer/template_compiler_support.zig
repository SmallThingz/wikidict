const std = @import("std");
const lua = @import("lua");
const template_dispatch = @import("template_dispatch");

pub const TemplateClass = enum {
    metadata_only,
    compiled,
    unsupported,
};

pub const TemplateDispatchId = u16;

pub const BytecodeParserFunctionKind = enum {
    displaytitle,
    if_,
    ifexist,
    ifeq,
    ifexpr,
    expr,
    switch_,
    special,
    tag,
    lc,
    uc,
    lcfirst,
    ucfirst,
    formatnum,
    formatdate,
    anchorencode,
    padleft,
    padright,
    time,
    fullurl,
    urlencode,
    currentday,
    currentday2,
    currentmonth,
    currentmonthname,
    currentyear,
    revisionyear,
    revisionuser,
    pagename,
    fullpagename,
    fullpagenamee,
    basepagename,
    subpagename,
    namespace,
    namespacenumber,
    talkpagename,
    wikimedialanguage,
};

pub const BytecodeArg = struct {
    name: ?[]const u8 = null,
    name_nodes: []const BytecodeNode = &.{},
    name_is_dynamic: bool = false,
    value_nodes: []const BytecodeNode,
};

pub const BytecodeParam = struct {
    key: []const u8,
    default_nodes: []const BytecodeNode,
};

pub const BytecodeTemplateCall = struct {
    dispatch_id: TemplateDispatchId = 0,
    name_nodes: []const BytecodeNode = &.{},
    args: []const BytecodeArg = &.{},
};

pub const BytecodeInvokeCall = struct {
    module_index: u16,
    export_id: u16,
    args: []const BytecodeArg = &.{},
};

pub const BytecodeParserFunction = struct {
    kind: BytecodeParserFunctionKind,
    args: []const BytecodeArg = &.{},
};

pub const BytecodeNode = union(enum) {
    text: []const u8,
    param: BytecodeParam,
    template_call: BytecodeTemplateCall,
    invoke_call: BytecodeInvokeCall,
    parser_func: BytecodeParserFunction,
};

pub fn templateDispatchId(name: []const u8) ?u16 {
    return template_dispatch.dispatchIdFromName(name);
}

pub const NormalizedTemplateNameKey = struct {
    primary: u64,
    secondary: u64,
    len: u32,
};

pub fn normalizedTemplateNameKey(name: []const u8) NormalizedTemplateNameKey {
    var primary = std.hash.Wyhash.init(0x6b7d4f13e9c2a581);
    var secondary = std.hash.Wyhash.init(0x91a54d7bc38ef245);
    var len: u32 = 0;
    for (name) |byte| {
        if (isTemplateNameSpacer(byte)) continue;
        const normalized = std.ascii.toLower(byte);
        primary.update(&[_]u8{normalized});
        secondary.update(&[_]u8{normalized});
        len += 1;
    }
    return .{
        .primary = primary.final(),
        .secondary = secondary.final(),
        .len = len,
    };
}

pub fn compareNormalizedTemplateNameKey(lhs: NormalizedTemplateNameKey, rhs: NormalizedTemplateNameKey) std.math.Order {
    if (lhs.primary < rhs.primary) return .lt;
    if (lhs.primary > rhs.primary) return .gt;
    if (lhs.secondary < rhs.secondary) return .lt;
    if (lhs.secondary > rhs.secondary) return .gt;
    if (lhs.len < rhs.len) return .lt;
    if (lhs.len > rhs.len) return .gt;
    return .eq;
}

pub const NamedArg = struct {
    name: []const u8,
    value: []const u8,
};

pub const BorrowedText = struct {
    items: []const u8,

    pub fn deinit(_: *BorrowedText, _: std.mem.Allocator) void {}
};

pub const TemplateArgs = struct {
    positional: []const []const u8,
    named: []const NamedArg,
    owned_buffers: []const []u8 = &.{},
    page_title: []const u8 = "",
    ownership: enum { owned, borrowed } = .owned,

    pub fn deinit(self: *TemplateArgs, allocator: std.mem.Allocator) void {
        if (self.ownership == .borrowed) {
            self.* = undefined;
            return;
        }
        for (self.owned_buffers) |buffer| allocator.free(buffer);
        allocator.free(self.owned_buffers);
        allocator.free(self.positional);
        allocator.free(self.named);
        self.* = undefined;
    }

    pub fn positionalArg(self: *const TemplateArgs, index: usize) ?[]const u8 {
        return if (index < self.positional.len) self.positional[index] else null;
    }

    pub fn namedArg(self: *const TemplateArgs, name: []const u8) ?[]const u8 {
        for (self.named) |arg| {
            if (templateNameEquals(arg.name, name)) return arg.value;
        }
        return null;
    }

    pub fn paramValue(self: *const TemplateArgs, key: []const u8) ?[]const u8 {
        if (parseNumericKey(key)) |one_based| {
            if (one_based == 0) return null;
            return self.positionalArg(one_based - 1);
        }
        return self.namedArg(key);
    }
};

// Legacy generated runtimes call this to mark the argument bundle as observed.
// Keeping the shim avoids rebuilding every previously generated template runtime.
pub fn touchTemplateArgs(args: *const TemplateArgs) void {
    _ = args;
}

pub const TemplateArgsBuilder = struct {
    positional: std.ArrayList([]const u8) = .empty,
    named: std.ArrayList(NamedArg) = .empty,
    owned_buffers: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *TemplateArgsBuilder, allocator: std.mem.Allocator) void {
        for (self.owned_buffers.items) |buffer| allocator.free(buffer);
        self.owned_buffers.deinit(allocator);
        self.positional.deinit(allocator);
        self.named.deinit(allocator);
        self.* = .{};
    }

    pub fn addPositionalOwned(self: *TemplateArgsBuilder, allocator: std.mem.Allocator, value: []const u8) !void {
        const duped = try allocator.dupe(u8, value);
        try self.owned_buffers.append(allocator, duped);
        try self.positional.append(allocator, duped);
    }

    pub fn addNamedOwned(self: *TemplateArgsBuilder, allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        const duped = try allocator.dupe(u8, value);
        try self.owned_buffers.append(allocator, duped);
        try self.named.append(allocator, .{
            .name = name,
            .value = duped,
        });
    }

    pub fn addPositionalBuffer(self: *TemplateArgsBuilder, allocator: std.mem.Allocator, value: []u8) !void {
        try self.owned_buffers.append(allocator, value);
        try self.positional.append(allocator, value);
    }

    pub fn addPositionalBorrowed(self: *TemplateArgsBuilder, allocator: std.mem.Allocator, value: []const u8) !void {
        try self.positional.append(allocator, value);
    }

    pub fn addNamedBuffer(self: *TemplateArgsBuilder, allocator: std.mem.Allocator, name: []const u8, value: []u8) !void {
        try self.owned_buffers.append(allocator, value);
        try self.named.append(allocator, .{
            .name = name,
            .value = value,
        });
    }

    pub fn addNamedBorrowed(self: *TemplateArgsBuilder, allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        try self.named.append(allocator, .{
            .name = name,
            .value = value,
        });
    }

    pub fn addNamedOwnedBuffers(self: *TemplateArgsBuilder, allocator: std.mem.Allocator, name: []u8, value: []u8) !void {
        try self.owned_buffers.append(allocator, name);
        try self.owned_buffers.append(allocator, value);
        try self.named.append(allocator, .{
            .name = name,
            .value = value,
        });
    }

    pub fn buildOwned(self: *TemplateArgsBuilder, allocator: std.mem.Allocator) !TemplateArgs {
        const positional = try self.positional.toOwnedSlice(allocator);
        errdefer allocator.free(positional);
        const named = try self.named.toOwnedSlice(allocator);
        errdefer allocator.free(named);
        const owned_buffers = try self.owned_buffers.toOwnedSlice(allocator);
        self.* = .{};
        return .{
            .positional = positional,
            .named = named,
            .owned_buffers = owned_buffers,
            .page_title = "",
            .ownership = .owned,
        };
    }

    pub fn buildBorrowed(self: *const TemplateArgsBuilder, page_title: []const u8) TemplateArgs {
        return .{
            .positional = self.positional.items,
            .named = self.named.items,
            .owned_buffers = self.owned_buffers.items,
            .page_title = page_title,
            .ownership = .borrowed,
        };
    }
};

pub fn templateArgsFromPartsAlloc(
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
) !TemplateArgs {
    var positional: std.ArrayList([]const u8) = .empty;
    errdefer positional.deinit(allocator);
    var named: std.ArrayList(NamedArg) = .empty;
    errdefer named.deinit(allocator);

    for (parts.items[1..]) |segment| {
        if (topLevelEquals(segment)) |equals| {
            const key = trimWikiWhitespace(segment[0..equals]);
            const value = trimWikiWhitespace(segment[equals + 1 ..]);

            if (parseNumericKey(key)) |one_based| {
                if (one_based == 0) continue;
                while (positional.items.len < one_based) try positional.append(allocator, "");
                positional.items[one_based - 1] = value;
            } else {
                try named.append(allocator, .{
                    .name = key,
                    .value = value,
                });
            }
            continue;
        }

        try positional.append(allocator, trimWikiWhitespace(segment));
    }

    return .{
        .positional = try positional.toOwnedSlice(allocator),
        .named = try named.toOwnedSlice(allocator),
        .owned_buffers = try allocator.alloc([]u8, 0),
        .page_title = "",
        .ownership = .owned,
    };
}

pub fn appendText(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    if (text.len == 0) return;
    try out.appendSlice(allocator, text);
}

pub fn appendLower(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |byte| try out.append(allocator, std.ascii.toLower(byte));
}

pub fn appendUpper(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |byte| try out.append(allocator, std.ascii.toUpper(byte));
}

pub fn appendLcFirst(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    if (text.len == 0) return;
    try out.append(allocator, std.ascii.toLower(text[0]));
    try out.appendSlice(allocator, text[1..]);
}

pub fn appendUcFirst(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    if (text.len == 0) return;
    try out.append(allocator, std.ascii.toUpper(text[0]));
    try out.appendSlice(allocator, text[1..]);
}

pub fn appendFormatNum(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    // Wiktionary mostly uses this as a formatting pass-through in textual output.
    try appendText(out, allocator, trimWikiWhitespace(text));
}

pub fn appendAnchorEncode(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (trimWikiWhitespace(text)) |byte| switch (byte) {
        ' ' => try out.append(allocator, '_'),
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', ':' => try out.append(allocator, byte),
        else => {
            var buf: [3]u8 = undefined;
            _ = try std.fmt.bufPrint(&buf, "%{X:0>2}", .{byte});
            try out.appendSlice(allocator, &buf);
        },
    };
}

pub fn appendPad(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    text: []const u8,
    width: usize,
    pad_text: []const u8,
    side: enum { left, right },
) !void {
    const effective_pad = if (pad_text.len == 0) "0" else pad_text;
    if (text.len >= width) {
        try appendText(out, allocator, text);
        return;
    }
    const pad_len = width - text.len;
    if (side == .left) try appendRepeatedPad(out, allocator, effective_pad, pad_len);
    try appendText(out, allocator, text);
    if (side == .right) try appendRepeatedPad(out, allocator, effective_pad, pad_len);
}

fn appendRepeatedPad(out: *std.ArrayList(u8), allocator: std.mem.Allocator, pad_text: []const u8, total_len: usize) !void {
    if (pad_text.len == 0 or total_len == 0) return;
    var remaining = total_len;
    while (remaining > 0) {
        const chunk_len = @min(remaining, pad_text.len);
        try out.appendSlice(allocator, pad_text[0..chunk_len]);
        remaining -= chunk_len;
    }
}

pub fn isTruthy(text: []const u8) bool {
    return trimWikiWhitespace(text).len != 0;
}

pub fn wikiTextEquals(lhs: []const u8, rhs: []const u8) bool {
    return std.mem.eql(u8, trimWikiWhitespace(lhs), trimWikiWhitespace(rhs));
}

pub fn pageName(args: *const TemplateArgs) []const u8 {
    return pageNameFromTitle(args.page_title);
}

pub fn fullPageName(args: *const TemplateArgs) []const u8 {
    return fullPageNameFromTitle(args.page_title);
}

pub fn fullPageNameEncoded(args: *const TemplateArgs) []const u8 {
    return fullPageNameEncodedFromTitle(args.page_title);
}

pub fn subPageName(args: *const TemplateArgs) []const u8 {
    return subPageNameFromTitle(args.page_title);
}

pub fn basePageName(args: *const TemplateArgs) []const u8 {
    return basePageNameFromTitle(args.page_title);
}

pub fn namespaceText(args: *const TemplateArgs) []const u8 {
    return namespaceTextFromTitle(args.page_title);
}

pub fn namespaceNumber(args: *const TemplateArgs) []const u8 {
    return namespaceNumberFromTitle(args.page_title);
}

pub fn talkPageName(args: *const TemplateArgs) []const u8 {
    return talkPageNameFromTitle(args.page_title);
}

pub fn pageNameFromTitle(title: []const u8) []const u8 {
    return stripNamespace(trimWikiWhitespace(title));
}

pub fn fullPageNameFromTitle(title: []const u8) []const u8 {
    return trimWikiWhitespace(title);
}

pub fn fullPageNameEncodedFromTitle(title: []const u8) []const u8 {
    return trimWikiWhitespace(title);
}

pub fn subPageNameFromTitle(title: []const u8) []const u8 {
    const full = pageNameFromTitle(title);
    const idx = std.mem.lastIndexOfScalar(u8, full, '/') orelse return full;
    return full[idx + 1 ..];
}

pub fn basePageNameFromTitle(title: []const u8) []const u8 {
    const full = pageNameFromTitle(title);
    const idx = std.mem.lastIndexOfScalar(u8, full, '/') orelse return full;
    return full[0..idx];
}

pub fn namespaceTextFromTitle(title: []const u8) []const u8 {
    const trimmed = trimWikiWhitespace(title);
    if (trimmed.len == 0) return "";
    if (std.mem.eql(u8, trimmed, "0")) return "";
    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return "";
    return trimWikiWhitespace(trimmed[0..colon]);
}

pub fn namespaceNumberFromTitle(title: []const u8) []const u8 {
    const trimmed = trimWikiWhitespace(title);
    if (trimmed.len == 0) return "0";
    if (parseNumericKey(trimmed)) |_| return trimmed;
    return if (namespaceTextFromTitle(trimmed).len == 0) "0" else "";
}

pub fn talkPageNameFromTitle(title: []const u8) []const u8 {
    _ = title;
    return "";
}

pub fn wikimediaLanguage() []const u8 {
    return "en";
}

pub fn currentDayText() []const u8 {
    return "5";
}

pub fn currentDay2Text() []const u8 {
    return "05";
}

pub fn currentMonthText() []const u8 {
    return "04";
}

pub fn currentMonthName() []const u8 {
    return "April";
}

pub fn currentYearText() []const u8 {
    return "2026";
}

pub fn revisionYearText() []const u8 {
    return currentYearText();
}

pub fn revisionUserText() []const u8 {
    return "";
}

// The template compiler currently has no page-existence index in this support
// runtime. Treat non-empty titles as existing so common maintenance/link
// templates still compile through the static path instead of remaining
// unsupported.
pub fn pageExists(title: []const u8) bool {
    return trimWikiWhitespace(title).len != 0;
}

pub fn appendFormatDate(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    try appendText(out, allocator, trimRelativeDateModifier(trimWikiWhitespace(text)));
}

pub fn appendTime(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    format_text: []const u8,
    value_text: []const u8,
) !void {
    const format = trimWikiWhitespace(format_text);
    const value = trimRelativeDateModifier(trimWikiWhitespace(value_text));
    if (format.len == 0) {
        try appendText(out, allocator, value);
        return;
    }
    if (std.mem.eql(u8, format, "U")) {
        try appendText(out, allocator, "0");
        return;
    }
    if (std.mem.eql(u8, format, "Y")) {
        if (extractYear(value)) |year| {
            try appendText(out, allocator, year);
        } else {
            try appendText(out, allocator, currentYearText());
        }
        return;
    }
    if (std.mem.eql(u8, format, "j F Y")) {
        if (value.len != 0) {
            try appendText(out, allocator, value);
        } else {
            try appendText(out, allocator, currentDayText());
            try appendText(out, allocator, " ");
            try appendText(out, allocator, currentMonthName());
            try appendText(out, allocator, " ");
            try appendText(out, allocator, currentYearText());
        }
        return;
    }
    try appendText(out, allocator, if (value.len != 0) value else format);
}

pub fn appendExpr(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    const trimmed = trimWikiWhitespace(text);
    if (evalSimpleNumericExpr(trimmed)) |value| {
        var buf: [64]u8 = undefined;
        const printed = if (@round(value) == value)
            try std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intFromFloat(value))})
        else
            try std.fmt.bufPrint(&buf, "{}", .{value});
        try appendText(out, allocator, printed);
        return;
    }
    try appendText(out, allocator, trimmed);
}

pub fn appendUrlEncode(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    try appendPercentEncoded(out, allocator, trimWikiWhitespace(text));
}

pub fn appendSpecialPageName(out: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8) !void {
    try appendText(out, allocator, "Special:");
    try appendText(out, allocator, trimWikiWhitespace(name));
}

pub fn appendFullUrl(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    title_text: []const u8,
    query_text: []const u8,
) !void {
    try appendText(out, allocator, "https://en.wiktionary.org/wiki/");
    try appendPercentEncoded(out, allocator, trimWikiWhitespace(title_text));
    const query = trimWikiWhitespace(query_text);
    if (query.len != 0) {
        try appendText(out, allocator, "?");
        try appendText(out, allocator, query);
    }
}

pub fn exprTruthy(text: []const u8) bool {
    const trimmed = trimWikiWhitespace(text);
    if (trimmed.len == 0) return false;
    if (findComparator(trimmed)) |cmp| {
        const lhs = evalSimpleNumericExpr(trimmed[0..cmp.index]) orelse return isTruthy(trimmed);
        const rhs = evalSimpleNumericExpr(trimmed[cmp.index + cmp.width ..]) orelse return isTruthy(trimmed);
        return switch (cmp.kind) {
            .eq => lhs == rhs,
            .ne => lhs != rhs,
            .lt => lhs < rhs,
            .le => lhs <= rhs,
            .gt => lhs > rhs,
            .ge => lhs >= rhs,
        };
    }
    const value = evalSimpleNumericExpr(trimmed) orelse return isTruthy(trimmed);
    return value != 0;
}

pub fn appendResolvedParam(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    args: *const TemplateArgs,
    key: []const u8,
    default_value: []const u8,
) !void {
    try appendText(out, allocator, args.paramValue(key) orelse default_value);
}

pub fn invokeModuleFunction(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    module_source: []const u8,
    function_name: []const u8,
    args: *const TemplateArgs,
) !void {
    const lua_args = try buildLuaArgsAlloc(allocator, args);
    defer allocator.free(lua_args);

    const rendered = lua.runModuleFunctionAlloc(allocator, module_source, function_name, lua_args) catch return;
    defer allocator.free(rendered);
    if (rendered.len == 0) return;
    try out.appendSlice(allocator, rendered);
}

pub fn invokeGeneratedModuleFunction(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    run_module: *const fn (std.mem.Allocator) anyerror!lua.GeneratedRunResult,
    function_name: []const u8,
    args: *const TemplateArgs,
) !void {
    var generated = run_module(allocator) catch return;
    defer generated.deinit();

    if (generated.returns.len == 0 or generated.returns[0] != .table) return;

    const function_value = generated.returns[0].table.get(.{ .string = function_name });
    if (function_value != .function) return;

    const frame = try buildGeneratedFrameFromTemplateArgsAlloc(&generated.runtime, args);
    const first = lua.generatedCallFirst(&generated.runtime, function_value, &.{frame}) catch return;
    try lua.appendValueTextAlloc(out, allocator, first);
}

pub fn templateArgsToLuaArgsAlloc(
    allocator: std.mem.Allocator,
    args: *const TemplateArgs,
) ![]lua.ModuleArg {
    return buildLuaArgsAlloc(allocator, args);
}

pub fn renderBytecodeTemplate(
    comptime Runtime: type,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    nodes: []const BytecodeNode,
    args: *const TemplateArgs,
) !void {
    try renderBytecodeNodes(Runtime, out, allocator, nodes, args);
}

fn renderBytecodeNodes(
    comptime Runtime: type,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    nodes: []const BytecodeNode,
    args: *const TemplateArgs,
) !void {
    for (nodes) |node| switch (node) {
        .text => |text| {
            if (text.len == 0) continue;
            try appendText(out, allocator, text);
        },
        .param => |param| {
            if (args.paramValue(param.key)) |value| {
                try appendText(out, allocator, value);
            } else {
                try renderBytecodeNodes(Runtime, out, allocator, param.default_nodes, args);
            }
        },
        .template_call => |call| try renderBytecodeTemplateCall(Runtime, out, allocator, call, args),
        .invoke_call => |call| try renderBytecodeInvokeCall(Runtime, out, allocator, call, args),
        .parser_func => |func| try renderBytecodeParserFunction(Runtime, out, allocator, func, args),
    };
}

fn renderBytecodeNodesAlloc(
    comptime Runtime: type,
    allocator: std.mem.Allocator,
    nodes: []const BytecodeNode,
    args: *const TemplateArgs,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try renderBytecodeNodes(Runtime, &out, allocator, nodes, args);
    return out.toOwnedSlice(allocator);
}

fn buildBytecodeChildArgsAlloc(
    comptime Runtime: type,
    allocator: std.mem.Allocator,
    arg_specs: []const BytecodeArg,
    parent_args: *const TemplateArgs,
) !TemplateArgs {
    var builder: TemplateArgsBuilder = .{};
    defer builder.deinit(allocator);

    for (arg_specs) |arg| {
        const value = try renderBytecodeNodesAlloc(Runtime, allocator, arg.value_nodes, parent_args);
        errdefer allocator.free(value);
        if (arg.name_is_dynamic) {
            const name = try renderBytecodeNodesAlloc(Runtime, allocator, arg.name_nodes, parent_args);
            errdefer allocator.free(name);
            try builder.addNamedOwnedBuffers(allocator, name, value);
            continue;
        }
        if (arg.name) |name| {
            try builder.addNamedBuffer(allocator, name, value);
            continue;
        }
        try builder.addPositionalBuffer(allocator, value);
    }

    var child_args = try builder.buildOwned(allocator);
    child_args.page_title = parent_args.page_title;
    return child_args;
}

fn renderBytecodeTemplateCall(
    comptime Runtime: type,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    call: BytecodeTemplateCall,
    parent_args: *const TemplateArgs,
) !void {
    var child_args = try buildBytecodeChildArgsAlloc(Runtime, allocator, call.args, parent_args);
    defer child_args.deinit(allocator);

    const dispatch_id = if (call.dispatch_id != 0)
        call.dispatch_id
    else blk: {
        const name = try renderBytecodeNodesAlloc(Runtime, allocator, call.name_nodes, parent_args);
        defer allocator.free(name);
        break :blk Runtime.lookupDynamicTemplateDispatchId(name) orelse return;
    };
    _ = try Runtime.renderTemplateByDispatchId(out, allocator, dispatch_id, &child_args);
}

fn renderBytecodeInvokeCall(
    comptime Runtime: type,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    call: BytecodeInvokeCall,
    parent_args: *const TemplateArgs,
) !void {
    var child_args = try buildBytecodeChildArgsAlloc(Runtime, allocator, call.args, parent_args);
    defer child_args.deinit(allocator);
    try Runtime.generatedRenderModuleByIndexDynamic(out, allocator, call.module_index, call.export_id, &child_args);
}

fn parserArgValueNodes(args: []const BytecodeArg, index: usize) []const BytecodeNode {
    return if (index < args.len) args[index].value_nodes else &.{};
}

fn renderParserArgTextAlloc(
    comptime Runtime: type,
    allocator: std.mem.Allocator,
    args: []const BytecodeArg,
    index: usize,
    template_args: *const TemplateArgs,
) ![]u8 {
    return renderBytecodeNodesAlloc(Runtime, allocator, parserArgValueNodes(args, index), template_args);
}

fn bytecodeSwitchArgIsDefault(arg: BytecodeArg) bool {
    if (arg.name_is_dynamic) return false;
    const name = arg.name orelse return false;
    return std.ascii.eqlIgnoreCase(name, "#default");
}

fn bytecodeSwitchArgMatches(
    comptime Runtime: type,
    allocator: std.mem.Allocator,
    arg: BytecodeArg,
    key: []const u8,
    template_args: *const TemplateArgs,
) !bool {
    if (arg.name_is_dynamic) {
        const name = try renderBytecodeNodesAlloc(Runtime, allocator, arg.name_nodes, template_args);
        defer allocator.free(name);
        return wikiTextEquals(key, name);
    }
    if (arg.name) |name| return wikiTextEquals(key, name);
    const value = try renderBytecodeNodesAlloc(Runtime, allocator, arg.value_nodes, template_args);
    defer allocator.free(value);
    return wikiTextEquals(key, value);
}

fn renderBytecodeParserFunction(
    comptime Runtime: type,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    func: BytecodeParserFunction,
    args: *const TemplateArgs,
) !void {
    switch (func.kind) {
        .displaytitle => return,
        .if_ => {
            const cond = try renderParserArgTextAlloc(Runtime, allocator, func.args, 0, args);
            defer allocator.free(cond);
            if (isTruthy(cond)) {
                try renderBytecodeNodes(Runtime, out, allocator, parserArgValueNodes(func.args, 1), args);
            } else {
                try renderBytecodeNodes(Runtime, out, allocator, parserArgValueNodes(func.args, 2), args);
            }
        },
        .ifexist => {
            const title = try renderParserArgTextAlloc(Runtime, allocator, func.args, 0, args);
            defer allocator.free(title);
            if (pageExists(title)) {
                try renderBytecodeNodes(Runtime, out, allocator, parserArgValueNodes(func.args, 1), args);
            } else {
                try renderBytecodeNodes(Runtime, out, allocator, parserArgValueNodes(func.args, 2), args);
            }
        },
        .ifeq => {
            const lhs = try renderParserArgTextAlloc(Runtime, allocator, func.args, 0, args);
            defer allocator.free(lhs);
            const rhs = try renderParserArgTextAlloc(Runtime, allocator, func.args, 1, args);
            defer allocator.free(rhs);
            if (wikiTextEquals(lhs, rhs)) {
                try renderBytecodeNodes(Runtime, out, allocator, parserArgValueNodes(func.args, 2), args);
            } else {
                try renderBytecodeNodes(Runtime, out, allocator, parserArgValueNodes(func.args, 3), args);
            }
        },
        .ifexpr => {
            const expr = try renderParserArgTextAlloc(Runtime, allocator, func.args, 0, args);
            defer allocator.free(expr);
            if (exprTruthy(expr)) {
                try renderBytecodeNodes(Runtime, out, allocator, parserArgValueNodes(func.args, 1), args);
            } else {
                try renderBytecodeNodes(Runtime, out, allocator, parserArgValueNodes(func.args, 2), args);
            }
        },
        .expr => {
            const expr = try renderParserArgTextAlloc(Runtime, allocator, func.args, 0, args);
            defer allocator.free(expr);
            try appendExpr(out, allocator, expr);
        },
        .switch_ => {
            const key = try renderParserArgTextAlloc(Runtime, allocator, func.args, 0, args);
            defer allocator.free(key);

            var pending_start: usize = 1;
            var matched = false;
            var saw_default = false;
            var i: usize = 1;
            while (i < func.args.len) : (i += 1) {
                const arg = func.args[i];
                if (arg.name != null or arg.name_is_dynamic) {
                    if (!matched) {
                        var matches = false;
                        var label_index = pending_start;
                        while (label_index < i) : (label_index += 1) {
                            if (try bytecodeSwitchArgMatches(Runtime, allocator, func.args[label_index], key, args)) {
                                matches = true;
                                break;
                            }
                        }
                        if (!matches) {
                            if (!bytecodeSwitchArgIsDefault(arg)) {
                                matches = try bytecodeSwitchArgMatches(Runtime, allocator, arg, key, args);
                            } else {
                                matches = true;
                                saw_default = true;
                            }
                        }
                        if (matches) {
                            try renderBytecodeNodes(Runtime, out, allocator, arg.value_nodes, args);
                            matched = true;
                        }
                    } else if (bytecodeSwitchArgIsDefault(arg)) {
                        saw_default = true;
                    }
                    pending_start = i + 1;
                }
            }
            if (!matched and !saw_default and pending_start < func.args.len) {
                try renderBytecodeNodes(Runtime, out, allocator, func.args[func.args.len - 1].value_nodes, args);
            }
        },
        .special => {
            const name = try renderParserArgTextAlloc(Runtime, allocator, func.args, 0, args);
            defer allocator.free(name);
            try appendSpecialPageName(out, allocator, name);
        },
        .tag => try renderBytecodeNodes(Runtime, out, allocator, parserArgValueNodes(func.args, 1), args),
        .lc => {
            const text = try renderParserArgTextAlloc(Runtime, allocator, func.args, 0, args);
            defer allocator.free(text);
            try appendLower(out, allocator, text);
        },
        .uc => {
            const text = try renderParserArgTextAlloc(Runtime, allocator, func.args, 0, args);
            defer allocator.free(text);
            try appendUpper(out, allocator, text);
        },
        .lcfirst => {
            const text = try renderParserArgTextAlloc(Runtime, allocator, func.args, 0, args);
            defer allocator.free(text);
            try appendLcFirst(out, allocator, text);
        },
        .ucfirst => {
            const text = try renderParserArgTextAlloc(Runtime, allocator, func.args, 0, args);
            defer allocator.free(text);
            try appendUcFirst(out, allocator, text);
        },
        .formatnum => {
            const text = try renderParserArgTextAlloc(Runtime, allocator, func.args, 0, args);
            defer allocator.free(text);
            try appendFormatNum(out, allocator, text);
        },
        .formatdate => {
            const text = try renderParserArgTextAlloc(Runtime, allocator, func.args, 0, args);
            defer allocator.free(text);
            try appendFormatDate(out, allocator, text);
        },
        .anchorencode => {
            const text = try renderParserArgTextAlloc(Runtime, allocator, func.args, 0, args);
            defer allocator.free(text);
            try appendAnchorEncode(out, allocator, text);
        },
        .padleft, .padright => {
            const text = try renderParserArgTextAlloc(Runtime, allocator, func.args, 0, args);
            defer allocator.free(text);
            const width_text = try renderParserArgTextAlloc(Runtime, allocator, func.args, 1, args);
            defer allocator.free(width_text);
            const pad_text = try renderParserArgTextAlloc(Runtime, allocator, func.args, 2, args);
            defer allocator.free(pad_text);
            const width = std.fmt.parseUnsigned(usize, std.mem.trim(u8, width_text, " \t\r\n"), 10) catch text.len;
            try appendPad(out, allocator, text, width, pad_text, if (func.kind == .padleft) .left else .right);
        },
        .time => {
            const format = try renderParserArgTextAlloc(Runtime, allocator, func.args, 0, args);
            defer allocator.free(format);
            const value = try renderParserArgTextAlloc(Runtime, allocator, func.args, 1, args);
            defer allocator.free(value);
            try appendTime(out, allocator, format, value);
        },
        .fullurl => {
            const title = try renderParserArgTextAlloc(Runtime, allocator, func.args, 0, args);
            defer allocator.free(title);
            const query = try renderParserArgTextAlloc(Runtime, allocator, func.args, 1, args);
            defer allocator.free(query);
            try appendFullUrl(out, allocator, title, query);
        },
        .urlencode => {
            const text = try renderParserArgTextAlloc(Runtime, allocator, func.args, 0, args);
            defer allocator.free(text);
            try appendUrlEncode(out, allocator, text);
        },
        .currentday => try appendText(out, allocator, currentDayText()),
        .currentday2 => try appendText(out, allocator, currentDay2Text()),
        .currentmonth => try appendText(out, allocator, currentMonthText()),
        .currentmonthname => try appendText(out, allocator, currentMonthName()),
        .currentyear => try appendText(out, allocator, currentYearText()),
        .revisionyear => try appendText(out, allocator, revisionYearText()),
        .revisionuser => try appendText(out, allocator, revisionUserText()),
        .pagename => try appendText(out, allocator, pageName(args)),
        .fullpagename => try appendText(out, allocator, fullPageName(args)),
        .fullpagenamee => try appendText(out, allocator, fullPageNameEncoded(args)),
        .basepagename => try appendText(out, allocator, basePageName(args)),
        .subpagename => try appendText(out, allocator, subPageName(args)),
        .namespace => try appendText(out, allocator, namespaceText(args)),
        .namespacenumber => try appendText(out, allocator, namespaceNumber(args)),
        .talkpagename => try appendText(out, allocator, talkPageName(args)),
        .wikimedialanguage => try appendText(out, allocator, wikimediaLanguage()),
    }
}

// Generated template runtimes reuse the same frame builder so #invoke and
// generated module exports see the same `frame.args` layout everywhere.
pub fn buildGeneratedFrameFromTemplateArgsAlloc(
    runtime: *lua.GeneratedRuntime,
    args: *const TemplateArgs,
) !lua.Value {
    const frame = try lua.Table.init(runtime.alloc());
    const args_table = try lua.Table.init(runtime.alloc());

    for (args.positional, 0..) |value, idx| {
        try args_table.putNumber(@floatFromInt(idx + 1), .{ .string = value });
    }
    for (args.named) |arg| {
        try args_table.putStringBorrowed(arg.name, .{ .string = arg.value });
    }

    const get_parent_value = runtime.generatedCallableValue(lua.generated_callable_id_frame_get_parent, null, null);
    const expand_template_value = runtime.generatedCallableValue(lua.generated_callable_id_frame_expand_template, null, null);
    try frame.putStringBorrowed("args", .{ .table = args_table });
    try frame.putStringBorrowed("getParent", get_parent_value);
    try frame.putStringBorrowed("expandTemplate", expand_template_value);
    return .{ .table = frame };
}

fn buildLuaArgsAlloc(
    allocator: std.mem.Allocator,
    args: *const TemplateArgs,
) ![]lua.ModuleArg {
    var lua_args = try allocator.alloc(lua.ModuleArg, args.positional.len + args.named.len);

    var idx: usize = 0;
    for (args.positional) |value| {
        lua_args[idx] = .{ .value = value };
        idx += 1;
    }
    for (args.named) |arg| {
        lua_args[idx] = .{
            .name = arg.name,
            .value = arg.value,
        };
        idx += 1;
    }
    return lua_args;
}

fn parseNumericKey(key: []const u8) ?usize {
    const trimmed = trimWikiWhitespace(key);
    if (trimmed.len == 0) return null;
    for (trimmed) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    return std.fmt.parseUnsigned(usize, trimmed, 10) catch null;
}

pub fn templateNameEquals(lhs: []const u8, rhs: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < lhs.len and isTemplateNameSpacer(lhs[i])) : (i += 1) {}
        while (j < rhs.len and isTemplateNameSpacer(rhs[j])) : (j += 1) {}
        if (i == lhs.len or j == rhs.len) break;
        if (std.ascii.toLower(lhs[i]) != std.ascii.toLower(rhs[j])) return false;
        i += 1;
        j += 1;
    }
    while (i < lhs.len and isTemplateNameSpacer(lhs[i])) : (i += 1) {}
    while (j < rhs.len and isTemplateNameSpacer(rhs[j])) : (j += 1) {}
    return i == lhs.len and j == rhs.len;
}

pub fn compareTemplateNameToNormalized(lhs: []const u8, rhs_normalized: []const u8) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < lhs.len and isTemplateNameSpacer(lhs[i])) : (i += 1) {}
        if (i == lhs.len or j == rhs_normalized.len) break;
        const lhs_byte = std.ascii.toLower(lhs[i]);
        const rhs_byte = rhs_normalized[j];
        if (lhs_byte < rhs_byte) return .lt;
        if (lhs_byte > rhs_byte) return .gt;
        i += 1;
        j += 1;
    }
    while (i < lhs.len and isTemplateNameSpacer(lhs[i])) : (i += 1) {}
    if (i == lhs.len and j == rhs_normalized.len) return .eq;
    if (i == lhs.len) return .lt;
    return .gt;
}

fn isTemplateNameSpacer(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == '_';
}

fn topLevelEquals(segment: []const u8) ?usize {
    var templates: usize = 0;
    var params: usize = 0;
    var links: usize = 0;
    var i: usize = 0;
    while (i < segment.len) : (i += 1) {
        if (i + 3 <= segment.len and std.mem.eql(u8, segment[i .. i + 3], "{{{")) {
            params += 1;
            i += 2;
            continue;
        }
        if (i + 3 <= segment.len and std.mem.eql(u8, segment[i .. i + 3], "}}}")) {
            if (params != 0) params -= 1;
            i += 2;
            continue;
        }
        if (i + 2 <= segment.len and std.mem.eql(u8, segment[i .. i + 2], "{{")) {
            templates += 1;
            i += 1;
            continue;
        }
        if (i + 2 <= segment.len and std.mem.eql(u8, segment[i .. i + 2], "}}")) {
            if (templates != 0) templates -= 1;
            i += 1;
            continue;
        }
        if (i + 2 <= segment.len and std.mem.eql(u8, segment[i .. i + 2], "[[")) {
            links += 1;
            i += 1;
            continue;
        }
        if (i + 2 <= segment.len and std.mem.eql(u8, segment[i .. i + 2], "]]")) {
            if (links != 0) links -= 1;
            i += 1;
            continue;
        }
        if (segment[i] == '=' and templates == 0 and params == 0 and links == 0) return i;
    }
    return null;
}

fn trimWikiWhitespace(input: []const u8) []const u8 {
    return std.mem.trim(u8, input, " \t\r\n");
}

fn trimRelativeDateModifier(input: []const u8) []const u8 {
    const trimmed = trimWikiWhitespace(input);
    const plus = std.mem.indexOfScalar(u8, trimmed, '+') orelse return trimmed;
    return trimWikiWhitespace(trimmed[0..plus]);
}

fn extractYear(text: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 4 <= text.len) : (i += 1) {
        const candidate = text[i .. i + 4];
        var all_digits = true;
        for (candidate) |byte| {
            if (!std.ascii.isDigit(byte)) {
                all_digits = false;
                break;
            }
        }
        if (all_digits) return candidate;
    }
    return null;
}

fn appendPercentEncoded(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~', '/', ':' => try out.append(allocator, byte),
        else => {
            var buf: [3]u8 = undefined;
            buf[0] = '%';
            _ = try std.fmt.bufPrint(buf[1..], "{X:0>2}", .{byte});
            try out.appendSlice(allocator, &buf);
        },
    };
}

const ComparatorKind = enum { eq, ne, lt, le, gt, ge };

const Comparator = struct {
    index: usize,
    width: usize,
    kind: ComparatorKind,
};

fn findComparator(text: []const u8) ?Comparator {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '(' => depth += 1,
            ')' => {
                if (depth != 0) depth -= 1;
            },
            else => {},
        }
        if (depth != 0) continue;
        if (i + 2 <= text.len) {
            if (std.mem.eql(u8, text[i .. i + 2], ">=")) return .{ .index = i, .width = 2, .kind = .ge };
            if (std.mem.eql(u8, text[i .. i + 2], "<=")) return .{ .index = i, .width = 2, .kind = .le };
            if (std.mem.eql(u8, text[i .. i + 2], "!=")) return .{ .index = i, .width = 2, .kind = .ne };
        }
        switch (text[i]) {
            '=' => return .{ .index = i, .width = 1, .kind = .eq },
            '>' => return .{ .index = i, .width = 1, .kind = .gt },
            '<' => return .{ .index = i, .width = 1, .kind = .lt },
            else => {},
        }
    }
    return null;
}

fn evalSimpleNumericExpr(text: []const u8) ?f64 {
    var parser = NumericExprParser{ .input = trimWikiWhitespace(text) };
    const value = parser.parseExpr() orelse return null;
    parser.skipSpaces();
    return if (parser.index == parser.input.len) value else null;
}

const NumericExprParser = struct {
    input: []const u8,
    index: usize = 0,

    fn skipSpaces(self: *NumericExprParser) void {
        while (self.index < self.input.len and std.ascii.isWhitespace(self.input[self.index])) : (self.index += 1) {}
    }

    fn parseExpr(self: *NumericExprParser) ?f64 {
        var lhs = self.parseTerm() orelse return null;
        while (true) {
            self.skipSpaces();
            if (self.index >= self.input.len) return lhs;
            const op = self.input[self.index];
            if (op != '+' and op != '-') return lhs;
            self.index += 1;
            const rhs = self.parseTerm() orelse return null;
            lhs = if (op == '+') lhs + rhs else lhs - rhs;
        }
    }

    fn parseTerm(self: *NumericExprParser) ?f64 {
        var lhs = self.parseFactor() orelse return null;
        while (true) {
            self.skipSpaces();
            if (self.index >= self.input.len) return lhs;
            const op = self.input[self.index];
            if (op != '*' and op != '/') return lhs;
            self.index += 1;
            const rhs = self.parseFactor() orelse return null;
            lhs = if (op == '*') lhs * rhs else lhs / rhs;
        }
    }

    fn parseFactor(self: *NumericExprParser) ?f64 {
        self.skipSpaces();
        if (self.index >= self.input.len) return null;
        if (self.input[self.index] == '+') {
            self.index += 1;
            return self.parseFactor();
        }
        if (self.input[self.index] == '-') {
            self.index += 1;
            const value = self.parseFactor() orelse return null;
            return -value;
        }
        if (self.input[self.index] == '(') {
            self.index += 1;
            const value = self.parseExpr() orelse return null;
            self.skipSpaces();
            if (self.index >= self.input.len or self.input[self.index] != ')') return null;
            self.index += 1;
            return value;
        }
        return self.parseNumber();
    }

    fn parseNumber(self: *NumericExprParser) ?f64 {
        self.skipSpaces();
        const start = self.index;
        var seen_digit = false;
        while (self.index < self.input.len) : (self.index += 1) {
            const byte = self.input[self.index];
            if (std.ascii.isDigit(byte)) {
                seen_digit = true;
                continue;
            }
            if (byte == '.') continue;
            break;
        }
        if (!seen_digit) return null;
        return std.fmt.parseFloat(f64, self.input[start..self.index]) catch null;
    }
};

fn stripNamespace(title: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, title, ':') orelse return title;
    return title[colon + 1 ..];
}

test "template args parse positional and named fields" {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(std.testing.allocator);
    try parts.append(std.testing.allocator, "demo");
    try parts.append(std.testing.allocator, "en");
    try parts.append(std.testing.allocator, "2=term");
    try parts.append(std.testing.allocator, "gloss=test");

    var args = try templateArgsFromPartsAlloc(std.testing.allocator, &parts);
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("en", args.positionalArg(0).?);
    try std.testing.expectEqualStrings("term", args.positionalArg(1).?);
    try std.testing.expectEqualStrings("test", args.namedArg("gloss").?);
}

test "compareTemplateNameToNormalized ignores casing and spacers" {
    try std.testing.expectEqual(std.math.Order.eq, compareTemplateNameToNormalized("Plu ral", "plural"));
    try std.testing.expectEqual(std.math.Order.eq, compareTemplateNameToNormalized("yes_no", "yesno"));
    try std.testing.expectEqual(std.math.Order.lt, compareTemplateNameToNormalized("alpha", "beta"));
    try std.testing.expectEqual(std.math.Order.gt, compareTemplateNameToNormalized("beta", "alpha"));
}

test "normalizedTemplateNameKey matches equivalent names" {
    const a = normalizedTemplateNameKey("Plu ral");
    const b = normalizedTemplateNameKey("plural");
    const c = normalizedTemplateNameKey("yes_no");
    const d = normalizedTemplateNameKey("yesno");
    try std.testing.expectEqual(std.math.Order.eq, compareNormalizedTemplateNameKey(a, b));
    try std.testing.expectEqual(std.math.Order.eq, compareNormalizedTemplateNameKey(c, d));
    try std.testing.expect(compareNormalizedTemplateNameKey(a, normalizedTemplateNameKey("zeta")) != .eq);
}
