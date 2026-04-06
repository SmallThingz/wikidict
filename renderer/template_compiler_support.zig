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

    pub fn deinit(self: *TemplateArgs, allocator: std.mem.Allocator) void {
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
    var owned_buffers: std.ArrayList([]u8) = .empty;
    errdefer {
        for (owned_buffers.items) |buffer| allocator.free(buffer);
        owned_buffers.deinit(allocator);
    }

    for (parts.items[1..]) |segment| {
        if (topLevelEquals(segment)) |equals| {
            const key = trimWikiWhitespace(segment[0..equals]);
            const value = trimWikiWhitespace(segment[equals + 1 ..]);
            const value_duped = try allocator.dupe(u8, value);
            try owned_buffers.append(allocator, value_duped);

            if (parseNumericKey(key)) |one_based| {
                if (one_based == 0) continue;
                while (positional.items.len < one_based) try positional.append(allocator, "");
                positional.items[one_based - 1] = value_duped;
            } else {
                try named.append(allocator, .{
                    .name = try allocator.dupe(u8, key),
                    .value = value_duped,
                });
                try owned_buffers.append(allocator, @constCast(named.items[named.items.len - 1].name));
            }
            continue;
        }

        const value_duped = try allocator.dupe(u8, trimWikiWhitespace(segment));
        try owned_buffers.append(allocator, value_duped);
        try positional.append(allocator, value_duped);
    }

    return .{
        .positional = try positional.toOwnedSlice(allocator),
        .named = try named.toOwnedSlice(allocator),
        .owned_buffers = try owned_buffers.toOwnedSlice(allocator),
    };
}

pub fn appendText(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    if (text.len == 0) return;
    try out.appendSlice(allocator, text);
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
    var lua_args = try allocator.alloc(lua.ModuleArg, args.positional.len + args.named.len);
    defer allocator.free(lua_args);

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

    const rendered = lua.runModuleFunctionAlloc(allocator, module_source, function_name, lua_args) catch return;
    defer allocator.free(rendered);
    if (rendered.len == 0) return;
    try out.appendSlice(allocator, rendered);
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
