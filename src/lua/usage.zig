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

fn isNonTemplateNamespace(raw: []const u8) bool {
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
    }) |namespace| if (nameEqual(raw, namespace)) return true;
    return false;
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

        if (isNonTemplateNamespace(prefix)) return null;
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
    dynamic_template_target: bool = false,
};

fn appendLiteralTemplateCandidate(
    a: std.mem.Allocator,
    raw: []const u8,
    out: *std.ArrayList(Ref),
) !bool {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return true;
    const target = try canonicalTemplate(a, value) orelse return false;
    try out.append(a, .{ .kind = .template, .target = target });
    return true;
}

fn expandFiniteDynamicTemplateHead(
    a: std.mem.Allocator,
    head_raw: []const u8,
    out: *std.ArrayList(Ref),
) !bool {
    const head = std.mem.trim(u8, head_raw, " \t\r\n");
    if (head.len < 4 or !std.mem.startsWith(u8, head, "{{")) return false;
    const end = preprocess.findTemplateEnd(head, 0) orelse return false;
    if (end + 2 != head.len) return false;

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(a);
    try preprocess.splitWikitextTop(a, head[2..end], '|', &parts);
    if (parts.items.len == 0) return false;
    const first = std.mem.trim(u8, parts.items[0], " \t\r\n");
    const colon = preprocess.findTopDelimiter(first, ':') orelse return false;
    const name = std.mem.trim(u8, first[0..colon], " \t\r\n");

    if (std.ascii.eqlIgnoreCase(name, "#if")) {
        if (parts.items.len < 2) return false;
        const checkpoint = out.items.len;
        if (!try appendLiteralTemplateCandidate(a, parts.items[1], out)) {
            while (out.items.len > checkpoint) a.free(out.pop().?.target);
            return false;
        }
        if (parts.items.len >= 3 and !try appendLiteralTemplateCandidate(a, parts.items[2], out)) {
            while (out.items.len > checkpoint) a.free(out.pop().?.target);
            return false;
        }
        if (parts.items.len > 3) {
            while (out.items.len > checkpoint) a.free(out.pop().?.target);
            return false;
        }
        return true;
    }

    if (std.ascii.eqlIgnoreCase(name, "#ifeq")) {
        if (parts.items.len < 3) return false;
        const checkpoint = out.items.len;
        if (!try appendLiteralTemplateCandidate(a, parts.items[2], out)) {
            while (out.items.len > checkpoint) a.free(out.pop().?.target);
            return false;
        }
        if (parts.items.len >= 4 and !try appendLiteralTemplateCandidate(a, parts.items[3], out)) {
            while (out.items.len > checkpoint) a.free(out.pop().?.target);
            return false;
        }
        if (parts.items.len > 4) {
            while (out.items.len > checkpoint) a.free(out.pop().?.target);
            return false;
        }
        return true;
    }

    return false;
}

fn classifyHead(a: std.mem.Allocator, head_raw: []const u8, out: *std.ArrayList(Ref), flags: *ScanFlags) !void {
    const head = std.mem.trim(u8, head_raw, " \t\r\n");
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
        if (name.len != 0 and name[0] == '#') return;
        if (!containsDynamicSyntax(name) and isNonTemplateNamespace(name)) return;
    } else if (head[0] == '#') {
        return;
    }
    if (try canonicalTemplate(a, head)) |target| {
        try out.append(a, .{ .kind = .template, .target = target });
    } else if (containsDynamicSyntax(head)) {
        if (!try expandFiniteDynamicTemplateHead(a, head, out))
            flags.dynamic_template_target = true;
    }
}

fn scanRange(a: std.mem.Allocator, source: []const u8, out: *std.ArrayList(Ref), flags: *ScanFlags, depth: usize) anyerror!void {
    if (depth >= 128) return;
    var pos: usize = 0;
    while (preprocess.findNextConstructOutsideLiteralTags(source, pos)) |construct| {
        switch (construct.kind) {
            .parameter => {
                if (construct.close > construct.open + 3)
                    try scanRange(a, source[construct.open + 3 .. construct.close], out, flags, depth + 1);
                pos = @min(construct.close + 3, source.len);
            },
            .template => {
                const body = source[construct.open + 2 .. construct.close];
                try classifyHead(a, firstTopLevelPart(body), out, flags);
                if (body.len != 0) try scanRange(a, body, out, flags, depth + 1);
                pos = @min(construct.close + 2, source.len);
            },
        }
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

const max_module_string_values: usize = 64;

const ModuleAbstractValue = struct {
    strings: []const []const u8 = &.{},
    integers: []const i64 = &.{},
    tables: []const *ModuleAbstractTable = &.{},
    unknown_string: bool = false,
    unknown_number: bool = false,
    may_falsy: bool = false,
    may_truthy_other: bool = false,
    may_require_loader: bool = false,
    may_load_data_loader: bool = false,
    may_string_namespace: bool = false,
    may_mw_namespace: bool = false,
    may_string_format: bool = false,

    fn unknown() ModuleAbstractValue {
        return .{
            .unknown_string = true,
            .unknown_number = true,
            .may_falsy = true,
            .may_truthy_other = true,
        };
    }

    fn nilValue() ModuleAbstractValue {
        return .{ .may_falsy = true };
    }

    fn boolValue(value: bool) ModuleAbstractValue {
        return if (value) .{ .may_truthy_other = true } else .{ .may_falsy = true };
    }

    fn unknownNumber() ModuleAbstractValue {
        return .{ .unknown_number = true };
    }

    fn truthyOther() ModuleAbstractValue {
        return .{ .may_truthy_other = true };
    }

    fn stringNamespace() ModuleAbstractValue {
        return .{ .may_string_namespace = true };
    }

    fn mwNamespace() ModuleAbstractValue {
        return .{ .may_mw_namespace = true };
    }

    fn stringFormat() ModuleAbstractValue {
        return .{ .may_string_format = true };
    }

    fn requireLoader() ModuleAbstractValue {
        return .{ .may_require_loader = true };
    }

    fn loadDataLoader() ModuleAbstractValue {
        return .{ .may_load_data_loader = true };
    }

    fn canBeTruthy(self: ModuleAbstractValue) bool {
        return self.strings.len != 0 or self.integers.len != 0 or self.tables.len != 0 or
            self.unknown_string or self.unknown_number or self.may_truthy_other or
            self.may_require_loader or self.may_load_data_loader or
            self.may_string_namespace or self.may_mw_namespace or self.may_string_format;
    }
};

const ModuleAbstractTable = struct {
    string_fields: std.StringHashMapUnmanaged(ModuleAbstractValue) = .empty,
    integer_fields: std.AutoHashMapUnmanaged(i64, ModuleAbstractValue) = .empty,
    unknown_field: ?ModuleAbstractValue = null,
};

const ModuleFlowSave = struct {
    name: []const u8,
    previous: ?ModuleAbstractValue,
};

const ModuleFlowState = struct {
    values: std.StringHashMapUnmanaged(ModuleAbstractValue) = .empty,
    saves: std.ArrayList(ModuleFlowSave) = .empty,

    fn clone(self: *const ModuleFlowState, a: std.mem.Allocator) !ModuleFlowState {
        var out: ModuleFlowState = .{};
        var it = self.values.iterator();
        while (it.next()) |entry|
            try out.values.put(a, entry.key_ptr.*, entry.value_ptr.*);
        return out;
    }

    fn bind(self: *ModuleFlowState, a: std.mem.Allocator, name: []const u8, value: ModuleAbstractValue) !void {
        try self.saves.append(a, .{ .name = name, .previous = self.values.get(name) });
        try self.values.put(a, name, value);
    }

    fn assign(self: *ModuleFlowState, a: std.mem.Allocator, name: []const u8, value: ModuleAbstractValue) !void {
        if (self.values.contains(name)) try self.values.put(a, name, value);
    }

    fn endScope(self: *ModuleFlowState, a: std.mem.Allocator, mark: usize) void {
        while (self.saves.items.len > mark) {
            const save = self.saves.pop().?;
            if (save.previous) |previous|
                self.values.put(a, save.name, previous) catch unreachable
            else
                _ = self.values.remove(save.name);
        }
    }
};

const ModuleValueScanner = struct {
    output_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    out: *std.ArrayList([]const u8),
    load_data: ?*std.ArrayList([]const u8),
    dynamic: bool = false,
    captured_mutation_names: std.StringHashMapUnmanaged(void) = .empty,

    fn init(
        allocator: std.mem.Allocator,
        out: *std.ArrayList([]const u8),
        load_data: ?*std.ArrayList([]const u8),
    ) ModuleValueScanner {
        return .{
            .output_allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .out = out,
            .load_data = load_data,
        };
    }

    fn deinit(self: *ModuleValueScanner) void {
        self.captured_mutation_names.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    fn a(self: *ModuleValueScanner) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn singletonString(self: *ModuleValueScanner, value: []const u8) !ModuleAbstractValue {
        const values = try self.a().alloc([]const u8, 1);
        values[0] = value;
        return .{ .strings = values };
    }

    fn singletonInteger(self: *ModuleValueScanner, value: i64) !ModuleAbstractValue {
        const values = try self.a().alloc(i64, 1);
        values[0] = value;
        return .{ .integers = values };
    }

    fn singletonTable(self: *ModuleValueScanner, table: *ModuleAbstractTable) !ModuleAbstractValue {
        const values = try self.a().alloc(*ModuleAbstractTable, 1);
        values[0] = table;
        return .{ .tables = values };
    }

    fn newTable(self: *ModuleValueScanner) !*ModuleAbstractTable {
        const table = try self.a().create(ModuleAbstractTable);
        table.* = .{};
        return table;
    }

    fn parseInteger(raw: []const u8) ?i64 {
        if (raw.len == 0) return null;
        var negative = false;
        var digits = raw;
        if (digits[0] == '-') {
            negative = true;
            digits = digits[1..];
            if (digits.len == 0) return null;
        }
        const is_hex = std.mem.startsWith(u8, digits, "0x") or std.mem.startsWith(u8, digits, "0X");
        if (!is_hex and std.mem.indexOfAny(u8, digits, ".eE") != null) return null;
        if (is_hex and std.mem.indexOfAny(u8, digits[2..], ".pP") != null) return null;
        const value = if (is_hex)
            std.fmt.parseInt(i64, digits[2..], 16) catch return null
        else
            std.fmt.parseInt(i64, digits, 10) catch return null;
        return if (negative) -value else value;
    }

    fn appendUniqueString(
        self: *ModuleValueScanner,
        list: *std.ArrayList([]const u8),
        value: []const u8,
        overflow: *bool,
    ) !void {
        for (list.items) |existing| if (std.mem.eql(u8, existing, value)) return;
        if (list.items.len >= max_module_string_values) {
            overflow.* = true;
            return;
        }
        try list.append(self.a(), value);
    }

    fn appendUniqueInteger(
        self: *ModuleValueScanner,
        list: *std.ArrayList(i64),
        value: i64,
        overflow: *bool,
    ) !void {
        for (list.items) |existing| if (existing == value) return;
        if (list.items.len >= max_module_string_values) {
            overflow.* = true;
            return;
        }
        try list.append(self.a(), value);
    }

    fn appendUniqueTable(
        self: *ModuleValueScanner,
        list: *std.ArrayList(*ModuleAbstractTable),
        value: *ModuleAbstractTable,
        overflow: *bool,
    ) !void {
        for (list.items) |existing| if (existing == value) return;
        if (list.items.len >= max_module_string_values) {
            overflow.* = true;
            return;
        }
        try list.append(self.a(), value);
    }

    fn joinValue(
        self: *ModuleValueScanner,
        lhs: ModuleAbstractValue,
        rhs: ModuleAbstractValue,
    ) !ModuleAbstractValue {
        var strings: std.ArrayList([]const u8) = .empty;
        var integers: std.ArrayList(i64) = .empty;
        var tables: std.ArrayList(*ModuleAbstractTable) = .empty;
        var string_overflow = lhs.unknown_string or rhs.unknown_string;
        var number_overflow = lhs.unknown_number or rhs.unknown_number;
        var table_overflow = false;
        for (lhs.strings) |value| try self.appendUniqueString(&strings, value, &string_overflow);
        for (rhs.strings) |value| try self.appendUniqueString(&strings, value, &string_overflow);
        for (lhs.integers) |value| try self.appendUniqueInteger(&integers, value, &number_overflow);
        for (rhs.integers) |value| try self.appendUniqueInteger(&integers, value, &number_overflow);
        for (lhs.tables) |value| try self.appendUniqueTable(&tables, value, &table_overflow);
        for (rhs.tables) |value| try self.appendUniqueTable(&tables, value, &table_overflow);
        return .{
            .strings = try strings.toOwnedSlice(self.a()),
            .integers = try integers.toOwnedSlice(self.a()),
            .tables = try tables.toOwnedSlice(self.a()),
            .unknown_string = string_overflow,
            .unknown_number = number_overflow,
            .may_falsy = lhs.may_falsy or rhs.may_falsy,
            .may_truthy_other = lhs.may_truthy_other or rhs.may_truthy_other or table_overflow,
            .may_require_loader = lhs.may_require_loader or rhs.may_require_loader,
            .may_load_data_loader = lhs.may_load_data_loader or rhs.may_load_data_loader,
            .may_string_namespace = lhs.may_string_namespace or rhs.may_string_namespace,
            .may_mw_namespace = lhs.may_mw_namespace or rhs.may_mw_namespace,
            .may_string_format = lhs.may_string_format or rhs.may_string_format,
        };
    }

    fn concatValue(
        self: *ModuleValueScanner,
        lhs: ModuleAbstractValue,
        rhs: ModuleAbstractValue,
    ) !ModuleAbstractValue {
        var strings: std.ArrayList([]const u8) = .empty;
        var overflow = lhs.unknown_string or rhs.unknown_string or
            lhs.unknown_number or rhs.unknown_number or
            lhs.may_truthy_other or rhs.may_truthy_other or
            lhs.tables.len != 0 or rhs.tables.len != 0 or
            lhs.may_require_loader or rhs.may_require_loader or
            lhs.may_load_data_loader or rhs.may_load_data_loader or
            lhs.may_string_namespace or rhs.may_string_namespace or
            lhs.may_mw_namespace or rhs.may_mw_namespace or
            lhs.may_string_format or rhs.may_string_format;
        for (lhs.strings) |left| for (rhs.strings) |right| {
            const joined = try std.mem.concat(self.a(), u8, &.{ left, right });
            try self.appendUniqueString(&strings, joined, &overflow);
        };
        for (lhs.strings) |left| for (rhs.integers) |right| {
            const right_text = try std.fmt.allocPrint(self.a(), "{d}", .{right});
            const joined = try std.mem.concat(self.a(), u8, &.{ left, right_text });
            try self.appendUniqueString(&strings, joined, &overflow);
        };
        for (lhs.integers) |left| for (rhs.strings) |right| {
            const left_text = try std.fmt.allocPrint(self.a(), "{d}", .{left});
            const joined = try std.mem.concat(self.a(), u8, &.{ left_text, right });
            try self.appendUniqueString(&strings, joined, &overflow);
        };
        for (lhs.integers) |left| for (rhs.integers) |right| {
            const joined = try std.fmt.allocPrint(self.a(), "{d}{d}", .{ left, right });
            try self.appendUniqueString(&strings, joined, &overflow);
        };
        return .{
            .strings = try strings.toOwnedSlice(self.a()),
            .unknown_string = overflow,
        };
    }

    fn setTableField(
        self: *ModuleValueScanner,
        table: *ModuleAbstractTable,
        key: ModuleAbstractValue,
        value: ModuleAbstractValue,
    ) !void {
        for (key.strings) |name| {
            const existing = table.string_fields.get(name) orelse ModuleAbstractValue.nilValue();
            try table.string_fields.put(self.a(), name, try self.joinValue(existing, value));
        }
        for (key.integers) |index| {
            const existing = table.integer_fields.get(index) orelse ModuleAbstractValue.nilValue();
            try table.integer_fields.put(self.a(), index, try self.joinValue(existing, value));
        }
        if (key.unknown_string or key.unknown_number or key.may_truthy_other or key.tables.len != 0 or
            key.may_require_loader or key.may_load_data_loader or key.may_string_namespace or
            key.may_mw_namespace or key.may_string_format)
        {
            table.unknown_field = if (table.unknown_field) |existing|
                try self.joinValue(existing, value)
            else
                value;
        }
    }

    fn allTableValues(self: *ModuleValueScanner, table: *const ModuleAbstractTable) !ModuleAbstractValue {
        var out = table.unknown_field orelse ModuleAbstractValue.nilValue();
        var strings = table.string_fields.valueIterator();
        while (strings.next()) |value| out = try self.joinValue(out, value.*);
        var integers = table.integer_fields.valueIterator();
        while (integers.next()) |value| out = try self.joinValue(out, value.*);
        return out;
    }

    fn lookupTable(
        self: *ModuleValueScanner,
        table: *const ModuleAbstractTable,
        key: ModuleAbstractValue,
    ) !ModuleAbstractValue {
        var out = ModuleAbstractValue.nilValue();
        for (key.strings) |name| {
            if (table.string_fields.get(name)) |value|
                out = try self.joinValue(out, value);
        }
        for (key.integers) |index| {
            if (table.integer_fields.get(index)) |value|
                out = try self.joinValue(out, value);
        }
        if (key.unknown_string or key.unknown_number or key.may_truthy_other or key.tables.len != 0 or
            key.may_require_loader or key.may_load_data_loader or key.may_string_namespace or
            key.may_mw_namespace or key.may_string_format)
            out = try self.joinValue(out, try self.allTableValues(table));
        if (table.unknown_field) |unknown| out = try self.joinValue(out, unknown);
        return out;
    }

    fn evalIndex(
        self: *ModuleValueScanner,
        object: ModuleAbstractValue,
        key: ModuleAbstractValue,
    ) !ModuleAbstractValue {
        var out = ModuleAbstractValue.nilValue();
        var handled_namespace = false;
        if (object.may_mw_namespace) {
            handled_namespace = true;
            for (key.strings) |name| {
                if (std.mem.eql(u8, name, "loadData"))
                    out = try self.joinValue(out, .loadDataLoader())
                else
                    out = try self.joinValue(out, .unknown());
            }
            if (key.unknown_string) out = try self.joinValue(out, .unknown());
        }
        if (object.may_string_namespace) {
            handled_namespace = true;
            for (key.strings) |name| {
                if (std.mem.eql(u8, name, "format"))
                    out = try self.joinValue(out, .stringFormat())
                else
                    out = try self.joinValue(out, .unknown());
            }
            if (key.unknown_string) out = try self.joinValue(out, .unknown());
        }
        for (object.tables) |table| out = try self.joinValue(out, try self.lookupTable(table, key));
        if (object.unknown_string or object.unknown_number or object.may_truthy_other or
            object.may_require_loader or object.may_load_data_loader or object.may_string_format)
            out = try self.joinValue(out, .unknown());
        if (!handled_namespace and object.tables.len == 0 and
            !object.unknown_string and !object.unknown_number and !object.may_truthy_other and
            !object.may_require_loader and !object.may_load_data_loader and !object.may_string_format and
            !object.may_falsy)
            return .nilValue();
        return out;
    }

    fn integerBinary(
        self: *ModuleValueScanner,
        op: lua.BinaryOp,
        lhs: ModuleAbstractValue,
        rhs: ModuleAbstractValue,
    ) !ModuleAbstractValue {
        var values: std.ArrayList(i64) = .empty;
        var overflow = lhs.unknown_number or rhs.unknown_number or lhs.strings.len != 0 or rhs.strings.len != 0 or
            lhs.unknown_string or rhs.unknown_string or lhs.may_truthy_other or rhs.may_truthy_other or
            lhs.tables.len != 0 or rhs.tables.len != 0;
        for (lhs.integers) |left| for (rhs.integers) |right| {
            const result: i64 = switch (op) {
                .add => std.math.add(i64, left, right) catch {
                    overflow = true;
                    continue;
                },
                .sub => std.math.sub(i64, left, right) catch {
                    overflow = true;
                    continue;
                },
                .mul => std.math.mul(i64, left, right) catch {
                    overflow = true;
                    continue;
                },
                .mod => if (right != 0) @mod(left, right) else {
                    overflow = true;
                    continue;
                },
                else => return .unknownNumber(),
            };
            try self.appendUniqueInteger(&values, result, &overflow);
        };
        return .{
            .integers = try values.toOwnedSlice(self.a()),
            .unknown_number = overflow,
        };
    }

    fn formatCharValue(
        self: *ModuleValueScanner,
        format_value: ModuleAbstractValue,
        arg: ModuleAbstractValue,
    ) !ModuleAbstractValue {
        var strings: std.ArrayList([]const u8) = .empty;
        var overflow = format_value.unknown_string or arg.unknown_number or
            format_value.may_truthy_other or arg.may_truthy_other;
        for (format_value.strings) |format_text| {
            const marker = std.mem.indexOf(u8, format_text, "%c") orelse {
                overflow = true;
                continue;
            };
            if (std.mem.indexOfPos(u8, format_text, marker + 2, "%") != null) {
                overflow = true;
                continue;
            }
            for (arg.integers) |code| {
                if (code < 0 or code > 255) {
                    overflow = true;
                    continue;
                }
                const output = try self.a().alloc(u8, format_text.len - 1);
                @memcpy(output[0..marker], format_text[0..marker]);
                output[marker] = @intCast(code);
                @memcpy(output[marker + 1 ..], format_text[marker + 2 ..]);
                try self.appendUniqueString(&strings, output, &overflow);
            }
        }
        return .{
            .strings = try strings.toOwnedSlice(self.a()),
            .unknown_string = overflow,
        };
    }

    fn numericRange(
        self: *ModuleValueScanner,
        start: ModuleAbstractValue,
        limit: ModuleAbstractValue,
        step: ?ModuleAbstractValue,
    ) !ModuleAbstractValue {
        if (start.unknown_number or limit.unknown_number or start.integers.len != 1 or limit.integers.len != 1)
            return .unknownNumber();
        const step_value = step orelse try self.singletonInteger(1);
        if (step_value.unknown_number or step_value.integers.len != 1 or step_value.integers[0] == 0)
            return .unknownNumber();
        const first = start.integers[0];
        const last = limit.integers[0];
        const stride = step_value.integers[0];
        var values: std.ArrayList(i64) = .empty;
        var current = first;
        var overflow = false;
        while ((stride > 0 and current <= last) or (stride < 0 and current >= last)) {
            try self.appendUniqueInteger(&values, current, &overflow);
            if (overflow) break;
            current = std.math.add(i64, current, stride) catch {
                overflow = true;
                break;
            };
        }
        return .{
            .integers = try values.toOwnedSlice(self.a()),
            .unknown_number = overflow,
        };
    }

    fn andValue(
        _: *ModuleValueScanner,
        lhs: ModuleAbstractValue,
        rhs: ModuleAbstractValue,
    ) !ModuleAbstractValue {
        if (!lhs.canBeTruthy()) return .{ .may_falsy = lhs.may_falsy };
        var out = rhs;
        out.may_falsy = out.may_falsy or lhs.may_falsy;
        return out;
    }

    fn orValue(
        self: *ModuleValueScanner,
        lhs: ModuleAbstractValue,
        rhs: ModuleAbstractValue,
    ) !ModuleAbstractValue {
        var truthy_lhs = lhs;
        truthy_lhs.may_falsy = false;
        if (!lhs.may_falsy) return truthy_lhs;
        return self.joinValue(truthy_lhs, rhs);
    }

    fn addModuleTargets(self: *ModuleValueScanner, value: ModuleAbstractValue, is_load_data: bool) !void {
        for (value.strings) |raw| if (try canonicalModule(self.output_allocator, raw)) |target| {
            try self.out.append(self.output_allocator, target);
            if (is_load_data) if (self.load_data) |items|
                try items.append(self.output_allocator, try self.output_allocator.dupe(u8, target));
        };
        if (value.unknown_string) self.dynamic = true;
    }

    fn scanLoaderCall(
        self: *ModuleValueScanner,
        loader: ModuleAbstractValue,
        arg: ModuleAbstractValue,
    ) !void {
        if (loader.may_require_loader) try self.addModuleTargets(arg, false);
        if (loader.may_load_data_loader) try self.addModuleTargets(arg, true);
    }

    fn evalExpr(self: *ModuleValueScanner, state: *ModuleFlowState, expr: *const lua.Expr) anyerror!ModuleAbstractValue {
        return switch (expr.*) {
            .nil_lit => .nilValue(),
            .bool_lit => |value| .boolValue(value.value),
            .number => |value| if (parseInteger(value.raw)) |integer|
                try self.singletonInteger(integer)
            else
                .unknownNumber(),
            .string => |value| try self.singletonString(value.value),
            .vararg => .unknown(),
            .name => |name| if (self.captured_mutation_names.contains(name.value))
                .unknown()
            else if (state.values.get(name.value)) |known|
                known
            else if (std.mem.eql(u8, name.value, "require"))
                .requireLoader()
            else if (std.mem.eql(u8, name.value, "string"))
                .stringNamespace()
            else if (std.mem.eql(u8, name.value, "mw"))
                .mwNamespace()
            else
                .unknown(),
            .paren => |value| try self.evalExpr(state, value.expr),
            .index => |value| blk: {
                const object = try self.evalExpr(state, value.object);
                const key = try self.evalExpr(state, value.key);
                break :blk try self.evalIndex(object, key);
            },
            .call => |call| blk: {
                const callee = try self.evalExpr(state, call.callee);
                const args = try self.a().alloc(ModuleAbstractValue, call.args.len);
                for (call.args, args) |arg_expr, *arg| arg.* = try self.evalExpr(state, arg_expr);
                if (call.callee.* == .name and std.mem.eql(u8, call.callee.name.value, "pcall") and args.len >= 2) {
                    try self.scanLoaderCall(args[0], args[1]);
                } else if (args.len != 0) {
                    try self.scanLoaderCall(callee, args[0]);
                }
                if (callee.may_string_format) {
                    if (args.len == 2) break :blk try self.formatCharValue(args[0], args[1]);
                    break :blk .unknown();
                }
                break :blk .unknown();
            },
            .method_call => |call| blk: {
                _ = try self.evalExpr(state, call.object);
                for (call.args) |arg| _ = try self.evalExpr(state, arg);
                break :blk .unknown();
            },
            .function => |function| blk: {
                var child = try state.clone(self.a());
                for (function.params) |name| try child.bind(self.a(), name, .unknown());
                try self.scanBlock(&child, function.body);
                break :blk .truthyOther();
            },
            .table => |table_expr| blk: {
                const table = try self.newTable();
                var list_index: i64 = 1;
                for (table_expr.fields) |field| switch (field) {
                    .list => |item| {
                        const key = try self.singletonInteger(list_index);
                        try self.setTableField(table, key, try self.evalExpr(state, item));
                        list_index = std.math.add(i64, list_index, 1) catch return error.ModuleValueSetOverflow;
                    },
                    .named => |item| {
                        try self.setTableField(
                            table,
                            try self.singletonString(item.name),
                            try self.evalExpr(state, item.value),
                        );
                    },
                    .keyed => |item| {
                        try self.setTableField(
                            table,
                            try self.evalExpr(state, item.key),
                            try self.evalExpr(state, item.value),
                        );
                    },
                };
                break :blk try self.singletonTable(table);
            },
            .unary => |value| blk: {
                const operand = try self.evalExpr(state, value.expr);
                break :blk switch (value.op) {
                    .not_ => .{ .may_falsy = true, .may_truthy_other = true },
                    .neg => if (operand.integers.len != 0 and !operand.unknown_number) neg: {
                        var ints: std.ArrayList(i64) = .empty;
                        var overflow = false;
                        for (operand.integers) |integer| {
                            const negated = std.math.negate(integer) catch {
                                overflow = true;
                                continue;
                            };
                            try self.appendUniqueInteger(&ints, negated, &overflow);
                        }
                        break :neg .{
                            .integers = try ints.toOwnedSlice(self.a()),
                            .unknown_number = overflow,
                        };
                    } else .unknownNumber(),
                    .len => if (operand.tables.len == 1 and !operand.unknown_number and !operand.unknown_string) len: {
                        const table = operand.tables[0];
                        var length: i64 = 0;
                        while (table.integer_fields.contains(length + 1)) length += 1;
                        break :len try self.singletonInteger(length);
                    } else .unknownNumber(),
                };
            },
            .binary => |value| blk: {
                const lhs = try self.evalExpr(state, value.lhs);
                const rhs = try self.evalExpr(state, value.rhs);
                break :blk switch (value.op) {
                    .concat => try self.concatValue(lhs, rhs),
                    .and_ => try self.andValue(lhs, rhs),
                    .or_ => try self.orValue(lhs, rhs),
                    .lt, .le, .gt, .ge, .eq, .ne => .{ .may_falsy = true, .may_truthy_other = true },
                    .add, .sub, .mul, .mod => try self.integerBinary(value.op, lhs, rhs),
                    .div, .pow => .unknownNumber(),
                };
            },
        };
    }

    fn joinStateInto(
        self: *ModuleValueScanner,
        state: *ModuleFlowState,
        branches: []const ModuleFlowState,
    ) !void {
        var it = state.values.iterator();
        while (it.next()) |entry| {
            var joined = entry.value_ptr.*;
            for (branches) |branch| {
                if (branch.values.get(entry.key_ptr.*)) |value|
                    joined = try self.joinValue(joined, value);
            }
            entry.value_ptr.* = joined;
        }
    }

    fn scanScopedBlock(self: *ModuleValueScanner, state: *ModuleFlowState, body: lua.Block) anyerror!void {
        const mark = state.saves.items.len;
        defer state.endScope(self.a(), mark);
        try self.scanBlock(state, body);
    }

    fn scanBlock(self: *ModuleValueScanner, state: *ModuleFlowState, body: lua.Block) anyerror!void {
        for (body) |stmt| switch (stmt.*) {
            .empty, .break_stmt => {},
            .local_assign => |assignment| {
                const values = try self.a().alloc(ModuleAbstractValue, assignment.names.len);
                for (values, 0..) |*out, index| out.* = if (index < assignment.values.len)
                    try self.evalExpr(state, assignment.values[index])
                else
                    .nilValue();
                for (assignment.names, values) |name, value|
                    try state.bind(self.a(), name, value);
                if (assignment.values.len > assignment.names.len) {
                    for (assignment.values[assignment.names.len..]) |extra|
                        _ = try self.evalExpr(state, extra);
                }
            },
            .assign => |assignment| {
                const values = try self.a().alloc(ModuleAbstractValue, assignment.targets.len);
                for (values, 0..) |*out, index| out.* = if (index < assignment.values.len)
                    try self.evalExpr(state, assignment.values[index])
                else
                    .nilValue();
                for (assignment.targets, values) |target, value| switch (target) {
                    .name => |name| try state.assign(self.a(), name, value),
                    .index => |index| {
                        const object = try self.evalExpr(state, index.object);
                        const key = try self.evalExpr(state, index.key);
                        for (object.tables) |table| try self.setTableField(table, key, value);
                    },
                };
                if (assignment.values.len > assignment.targets.len) {
                    for (assignment.values[assignment.targets.len..]) |extra|
                        _ = try self.evalExpr(state, extra);
                }
            },
            .call => |call| _ = try self.evalExpr(state, call.expr),
            .do_block => |block| try self.scanScopedBlock(state, block.body),
            .while_loop => |loop| {
                _ = try self.evalExpr(state, loop.cond);
                const base = try state.clone(self.a());
                var body_state = try base.clone(self.a());
                try self.scanScopedBlock(&body_state, loop.body);
                const branches = [_]ModuleFlowState{body_state};
                try self.joinStateInto(state, &branches);
            },
            .repeat_loop => |loop| {
                const base = try state.clone(self.a());
                var body_state = try base.clone(self.a());
                try self.scanScopedBlock(&body_state, loop.body);
                _ = try self.evalExpr(&body_state, loop.cond);
                const branches = [_]ModuleFlowState{body_state};
                try self.joinStateInto(state, &branches);
            },
            .if_stmt => |if_stmt| {
                const base = try state.clone(self.a());
                var branches: std.ArrayList(ModuleFlowState) = .empty;
                for (if_stmt.branches) |branch| {
                    _ = try self.evalExpr(state, branch.cond);
                    var branch_state = try base.clone(self.a());
                    try self.scanScopedBlock(&branch_state, branch.body);
                    try branches.append(self.a(), branch_state);
                }
                if (if_stmt.else_body) |else_body| {
                    var else_state = try base.clone(self.a());
                    try self.scanScopedBlock(&else_state, else_body);
                    try branches.append(self.a(), else_state);
                } else {
                    try branches.append(self.a(), base);
                }
                try self.joinStateInto(state, branches.items);
            },
            .numeric_for => |loop| {
                const start_value = try self.evalExpr(state, loop.start);
                const limit_value = try self.evalExpr(state, loop.limit);
                const step_value = if (loop.step) |step| try self.evalExpr(state, step) else null;
                const range = try self.numericRange(start_value, limit_value, step_value);
                const base = try state.clone(self.a());
                var body_state = try base.clone(self.a());
                const mark = body_state.saves.items.len;
                try body_state.bind(self.a(), loop.name, range);
                try self.scanBlock(&body_state, loop.body);
                body_state.endScope(self.a(), mark);
                const branches = [_]ModuleFlowState{body_state};
                try self.joinStateInto(state, &branches);
            },
            .generic_for => |loop| {
                for (loop.values) |value| _ = try self.evalExpr(state, value);
                const base = try state.clone(self.a());
                var body_state = try base.clone(self.a());
                const mark = body_state.saves.items.len;
                for (loop.names) |name| try body_state.bind(self.a(), name, .unknown());
                try self.scanBlock(&body_state, loop.body);
                body_state.endScope(self.a(), mark);
                const branches = [_]ModuleFlowState{body_state};
                try self.joinStateInto(state, &branches);
            },
            .function_assign => |function| {
                const fn_value = try self.evalExpr(state, function.function);
                switch (function.target) {
                    .name => |name| try state.assign(self.a(), name, fn_value),
                    .index => |index| {
                        _ = try self.evalExpr(state, index.object);
                        _ = try self.evalExpr(state, index.key);
                    },
                }
            },
            .local_function => |function| {
                try state.bind(self.a(), function.name, .truthyOther());
                _ = try self.evalExpr(state, function.function);
            },
            .return_stmt => |return_stmt| {
                for (return_stmt.values) |value|
                    _ = try self.evalExpr(state, value);
            },
        };
    }

    fn collectCapturedMutationNames(self: *ModuleValueScanner, body: lua.Block, nested: bool) !void {
        for (body) |stmt| switch (stmt.*) {
            .assign => |assignment| {
                if (nested) for (assignment.targets) |target| if (target == .name)
                    try self.captured_mutation_names.put(self.a(), target.name, {});
                for (assignment.values) |value| try self.collectCapturedMutationExpr(value, nested);
            },
            .local_assign => |assignment| for (assignment.values) |value|
                try self.collectCapturedMutationExpr(value, nested),
            .call => |call| try self.collectCapturedMutationExpr(call.expr, nested),
            .do_block => |block| try self.collectCapturedMutationNames(block.body, nested),
            .while_loop => |loop| {
                try self.collectCapturedMutationExpr(loop.cond, nested);
                try self.collectCapturedMutationNames(loop.body, nested);
            },
            .repeat_loop => |loop| {
                try self.collectCapturedMutationNames(loop.body, nested);
                try self.collectCapturedMutationExpr(loop.cond, nested);
            },
            .if_stmt => |if_stmt| {
                for (if_stmt.branches) |branch| {
                    try self.collectCapturedMutationExpr(branch.cond, nested);
                    try self.collectCapturedMutationNames(branch.body, nested);
                }
                if (if_stmt.else_body) |else_body| try self.collectCapturedMutationNames(else_body, nested);
            },
            .numeric_for => |loop| {
                try self.collectCapturedMutationExpr(loop.start, nested);
                try self.collectCapturedMutationExpr(loop.limit, nested);
                if (loop.step) |step| try self.collectCapturedMutationExpr(step, nested);
                try self.collectCapturedMutationNames(loop.body, nested);
            },
            .generic_for => |loop| {
                for (loop.values) |value| try self.collectCapturedMutationExpr(value, nested);
                try self.collectCapturedMutationNames(loop.body, nested);
            },
            .function_assign => |function| {
                if (nested and function.target == .name)
                    try self.captured_mutation_names.put(self.a(), function.target.name, {});
                try self.collectCapturedMutationExpr(function.function, true);
            },
            .local_function => |function| try self.collectCapturedMutationExpr(function.function, true),
            .return_stmt => |return_stmt| for (return_stmt.values) |value|
                try self.collectCapturedMutationExpr(value, nested),
            .empty, .break_stmt => {},
        };
    }

    fn collectCapturedMutationExpr(self: *ModuleValueScanner, expr: *const lua.Expr, nested: bool) anyerror!void {
        switch (expr.*) {
            .paren => |value| try self.collectCapturedMutationExpr(value.expr, nested),
            .index => |value| {
                try self.collectCapturedMutationExpr(value.object, nested);
                try self.collectCapturedMutationExpr(value.key, nested);
            },
            .call => |value| {
                try self.collectCapturedMutationExpr(value.callee, nested);
                for (value.args) |arg| try self.collectCapturedMutationExpr(arg, nested);
            },
            .method_call => |value| {
                try self.collectCapturedMutationExpr(value.object, nested);
                for (value.args) |arg| try self.collectCapturedMutationExpr(arg, nested);
            },
            .function => |function| try self.collectCapturedMutationNames(function.body, true),
            .table => |table| for (table.fields) |field| switch (field) {
                .list => |item| try self.collectCapturedMutationExpr(item, nested),
                .named => |item| try self.collectCapturedMutationExpr(item.value, nested),
                .keyed => |item| {
                    try self.collectCapturedMutationExpr(item.key, nested);
                    try self.collectCapturedMutationExpr(item.value, nested);
                },
            },
            .unary => |value| try self.collectCapturedMutationExpr(value.expr, nested),
            .binary => |value| {
                try self.collectCapturedMutationExpr(value.lhs, nested);
                try self.collectCapturedMutationExpr(value.rhs, nested);
            },
            else => {},
        }
    }

    fn run(self: *ModuleValueScanner, body: lua.Block) !bool {
        try self.collectCapturedMutationNames(body, false);
        var state: ModuleFlowState = .{};
        try self.scanBlock(&state, body);
        return self.dynamic;
    }
};

pub fn collectModuleLoadsDetailed(
    a: std.mem.Allocator,
    body: lua.Block,
    out: *std.ArrayList([]const u8),
    load_data: ?*std.ArrayList([]const u8),
) !bool {
    var scanner = ModuleValueScanner.init(a, out, load_data);
    defer scanner.deinit();
    return scanner.run(body);
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

test "module load value sets fold concatenation aliases and pcall" {
    const a = std.testing.allocator;
    var chunk = try lua.parse(a,
        \\local loader = require
        \\local data_loader = mw.loadData
        \\local suffix = flag and "A" or "B"
        \\local name = "Module:" .. suffix
        \\local a = data_loader("Module:Static_data")
        \\local b = pcall(loader, name)
        \\return loader(name)
    );
    defer chunk.deinit();
    var refs: std.ArrayList([]const u8) = .empty;
    defer {
        for (refs.items) |ref| a.free(ref);
        refs.deinit(a);
    }
    var load_data: std.ArrayList([]const u8) = .empty;
    defer {
        for (load_data.items) |ref| a.free(ref);
        load_data.deinit(a);
    }
    const dynamic = try collectModuleLoadsDetailed(a, chunk.body, &refs, &load_data);
    try std.testing.expect(!dynamic);
    try std.testing.expectEqual(@as(usize, 5), refs.items.len);
    try std.testing.expectEqualStrings("Module:Static data", refs.items[0]);
    try std.testing.expectEqualStrings("Module:A", refs.items[1]);
    try std.testing.expectEqualStrings("Module:B", refs.items[2]);
    try std.testing.expectEqualStrings("Module:A", refs.items[3]);
    try std.testing.expectEqualStrings("Module:B", refs.items[4]);
    try std.testing.expectEqual(@as(usize, 1), load_data.items.len);
    try std.testing.expectEqualStrings("Module:Static data", load_data.items[0]);
}

test "module load value sets join reassignment branches" {
    const a = std.testing.allocator;
    var chunk = try lua.parse(a,
        \\local name = "Module:A"
        \\if flag then name = "Module:B" end
        \\return require(name)
    );
    defer chunk.deinit();
    var refs: std.ArrayList([]const u8) = .empty;
    defer {
        for (refs.items) |ref| a.free(ref);
        refs.deinit(a);
    }
    try std.testing.expect(!try collectModuleLoads(a, chunk.body, &refs));
    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
    try std.testing.expectEqualStrings("Module:A", refs.items[0]);
    try std.testing.expectEqualStrings("Module:B", refs.items[1]);
}

test "module load value sets resolve table ranges and string format" {
    const a = std.testing.allocator;
    var chunk = try lua.parse(a,
        \\local string = string
        \\local format = string.format
        \\local modules = {"Module:One", "Module:Two"}
        \\for i = 1, 4 do
        \\  local name = modules[i] or format("Module:Generated/%c", 0x40 + i)
        \\  require(name)
        \\  require(name .. "/extra")
        \\end
    );
    defer chunk.deinit();
    var refs: std.ArrayList([]const u8) = .empty;
    defer {
        for (refs.items) |ref| a.free(ref);
        refs.deinit(a);
    }
    try std.testing.expect(!try collectModuleLoads(a, chunk.body, &refs));
    try std.testing.expect(refs.items.len >= 8);
    var saw_one = false;
    var saw_two = false;
    var saw_generated = false;
    for (refs.items) |ref| {
        saw_one = saw_one or std.mem.eql(u8, ref, "Module:One");
        saw_two = saw_two or std.mem.eql(u8, ref, "Module:Two");
        saw_generated = saw_generated or std.mem.eql(u8, ref, "Module:Generated/C");
    }
    try std.testing.expect(saw_one);
    try std.testing.expect(saw_two);
    try std.testing.expect(saw_generated);
}

test "module load value sets resolve bounded table and numeric format loops" {
    const a = std.testing.allocator;
    var chunk = try lua.parse(a,
        \\local format = string.format
        \\local modules = {"Module:A", "Module:B"}
        \\for i = 1, 4 do
        \\  local mname = modules[i] or format("Module:C/%c", 64 + i)
        \\  require(mname)
        \\  require(mname .. "/extra")
        \\end
    );
    defer chunk.deinit();
    var refs: std.ArrayList([]const u8) = .empty;
    defer {
        for (refs.items) |ref| a.free(ref);
        refs.deinit(a);
    }
    try std.testing.expect(!try collectModuleLoads(a, chunk.body, &refs));
    try std.testing.expectEqual(@as(usize, 12), refs.items.len);
    try std.testing.expectEqualStrings("Module:A", refs.items[0]);
    try std.testing.expectEqualStrings("Module:B", refs.items[1]);
    try std.testing.expectEqualStrings("Module:C/A", refs.items[2]);
    try std.testing.expectEqualStrings("Module:C/D/extra", refs.items[11]);
}

test "module load value sets keep unknown parameters dynamic" {
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, "return function(name) return require(name) end");
    defer chunk.deinit();
    var refs: std.ArrayList([]const u8) = .empty;
    defer {
        for (refs.items) |ref| a.free(ref);
        refs.deinit(a);
    }
    try std.testing.expect(try collectModuleLoads(a, chunk.body, &refs));
    try std.testing.expectEqual(@as(usize, 0), refs.items.len);
}

test "wikitext scan expands finite dynamic template heads" {
    const a = std.testing.allocator;
    var refs: std.ArrayList(Ref) = .empty;
    defer {
        for (refs.items) |ref| a.free(ref.target);
        refs.deinit(a);
    }

    const flags = try scanWikitextFlags(
        a,
        "{{ {{#if:{{{lang|}}}|check deprecated lang param usage|no deprecated lang param usage}}|x=1 }}",
        &refs,
    );
    try std.testing.expect(!flags.dynamic_template_target);
    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
    try std.testing.expectEqualStrings("Template:check deprecated lang param usage", refs.items[0].target);
    try std.testing.expectEqualStrings("Template:no deprecated lang param usage", refs.items[1].target);

    for (refs.items) |ref| a.free(ref.target);
    refs.clearRetainingCapacity();
    const ifeq_flags = try scanWikitextFlags(
        a,
        "{{{{#ifeq:{{{x|}}}|yes|alpha|beta}}|1}}",
        &refs,
    );
    try std.testing.expect(!ifeq_flags.dynamic_template_target);
    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
    try std.testing.expectEqualStrings("Template:alpha", refs.items[0].target);
    try std.testing.expectEqualStrings("Template:beta", refs.items[1].target);
}

test "wikitext scan separates unresolved invokes from dynamic template targets" {
    const a = std.testing.allocator;
    var refs: std.ArrayList(Ref) = .empty;
    defer {
        for (refs.items) |ref| a.free(ref.target);
        refs.deinit(a);
    }
    const flags = try scanWikitextFlags(a, "{{#invoke:{{{module}}}|run}} {{foo{{{template}}}|x}}", &refs);
    try std.testing.expect(flags.dynamic_module_target);
    try std.testing.expect(flags.dynamic_template_target);

    refs.clearRetainingCapacity();
    const template_only = try scanWikitextFlags(a, "{{foo{{{template}}}|x}}", &refs);
    try std.testing.expect(!template_only.dynamic_module_target);
    try std.testing.expect(template_only.dynamic_template_target);

    refs.clearRetainingCapacity();
    const non_templates = try scanWikitextFlags(
        a,
        "{{#if:{{{x}}}|yes|no}} {{Module:foo{{{x}}}}} {{Template:foo{{{x}}}}}",
        &refs,
    );
    try std.testing.expect(!non_templates.dynamic_module_target);
    try std.testing.expect(non_templates.dynamic_template_target);
}
