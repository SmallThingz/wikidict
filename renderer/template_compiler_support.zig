const std = @import("std");
const lua = @import("lua");

pub const TemplateClass = enum {
    metadata_only,
    compiled,
    unsupported,
};

pub const NamedArg = struct {
    name: []const u8,
    value: []const u8,
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

    pub fn addNamedBuffer(self: *TemplateArgsBuilder, allocator: std.mem.Allocator, name: []const u8, value: []u8) !void {
        try self.owned_buffers.append(allocator, value);
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

pub fn touchTemplateArgs(args: *const TemplateArgs) void {
    _ = args;
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
    return stripNamespace(args.page_title);
}

pub fn fullPageName(args: *const TemplateArgs) []const u8 {
    return args.page_title;
}

pub fn subPageName(args: *const TemplateArgs) []const u8 {
    const full = pageName(args);
    const idx = std.mem.lastIndexOfScalar(u8, full, '/') orelse return full;
    return full[idx + 1 ..];
}

pub fn basePageName(args: *const TemplateArgs) []const u8 {
    const full = pageName(args);
    const idx = std.mem.lastIndexOfScalar(u8, full, '/') orelse return full;
    return full[0..idx];
}

pub fn namespaceText(args: *const TemplateArgs) []const u8 {
    const title = args.page_title;
    const colon = std.mem.indexOfScalar(u8, title, ':') orelse return "";
    return trimWikiWhitespace(title[0..colon]);
}

pub fn namespaceNumber(args: *const TemplateArgs) []const u8 {
    return if (namespaceText(args).len == 0) "0" else "";
}

pub fn talkPageName(args: *const TemplateArgs) []const u8 {
    _ = args;
    return "";
}

pub fn wikimediaLanguage() []const u8 {
    return "en";
}

pub fn currentDayText() []const u8 {
    return "5";
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
    const results = lua.generatedInvoke(&generated.runtime, function_value, &.{frame}) catch return;
    if (results.len == 0) return;
    try lua.appendValueTextAlloc(out, allocator, results[0]);
}

fn buildGeneratedFrameFromTemplateArgsAlloc(
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

    try frame.putStringBorrowed("args", .{ .table = args_table });
    try frame.putStringBorrowed("getParent", try runtime.functionValue("frame.getParent", null, null, lua.generatedFrameGetParent));
    try frame.putStringBorrowed("expandTemplate", try runtime.functionValue("frame.expandTemplate", null, null, lua.generatedFrameExpandTemplate));
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
