const std = @import("std");
const lua = @import("lua");
const decoder = @import("decoder");
const compact_pattern_seed = @import("compact_pattern_seed");
const required_path = @import("required_path");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2 or std.mem.eql(u8, args[1], "help") or std.mem.eql(u8, args[1], "--help")) {
        printUsage();
        return;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "compile")) {
        const input = flagValue(args[2..], "--input") orelse {
            printUsage();
            return;
        };
        required_path.ensureExistsOrExit(init.io, input, "lua source");
        const source = try readFileAlloc(init.io, allocator, input);
        var chunk = try lua.compile(allocator, source);
        defer chunk.deinit();
        const text = try lua.formatOpcodesAlloc(allocator, &chunk);
        std.debug.print("{s}", .{text});
        return;
    }
    if (std.mem.eql(u8, command, "run")) {
        const input = flagValue(args[2..], "--input") orelse {
            printUsage();
            return;
        };
        required_path.ensureExistsOrExit(init.io, input, "lua source");
        const source = try readFileAlloc(init.io, allocator, input);
        var chunk = try lua.compile(allocator, source);
        defer chunk.deinit();
        var result = try lua.run(allocator, &chunk);
        defer result.deinit();
        const rendered = try renderValuesAlloc(allocator, result.returns);
        std.debug.print("{s}\n", .{rendered});
        return;
    }
    if (std.mem.eql(u8, command, "dump-module")) {
        const input = flagValue(args[2..], "--input") orelse "data/wiktionary.xml";
        const name = flagValue(args[2..], "--name") orelse {
            printUsage();
            return;
        };
        required_path.ensureExistsOrExit(init.io, input, "wiktionary dump");
        const source = try lua.loadModuleSourceAlloc(allocator, input, name) orelse {
            std.debug.print("module not found: {s}\n", .{name});
            return error.ModuleNotFound;
        };
        std.debug.print("{s}", .{source});
        return;
    }
    if (std.mem.eql(u8, command, "deps")) {
        const input = flagValue(args[2..], "--input") orelse "data/wiktionary.xml";
        required_path.ensureExistsOrExit(init.io, input, "wiktionary dump");
        if (flagValue(args[2..], "--db")) |db_path| {
            required_path.ensureExistsOrExit(init.io, db_path, "dictionary binary");
            const template_names = try loadDbTemplateNamesAlloc(allocator, db_path);
            defer freeOwnedStrings(allocator, template_names);

            var report = try lua.analyzeTemplateDependenciesAlloc(allocator, input, template_names);
            defer report.deinit(allocator);
            try printTemplateDependencyReport(allocator, report);
            if (report.compiled_failed.len != 0 or report.bytecode_inconsistent.len != 0) return error.LuaDependencyAuditFailed;
            return;
        }

        const structure = flagValue(args[2..], "--structure") orelse "data/wiktionary-structure.json";
        required_path.ensureExistsOrExit(init.io, structure, "structure report");
        const report = try lua.analyzeDependenciesAlloc(allocator, input, structure);
        try printDependencyReport(allocator, report);
        return;
    }
    if (std.mem.eql(u8, command, "audit")) {
        const input = flagValue(args[2..], "--input") orelse "data/wiktionary.xml";
        const db_path = flagValue(args[2..], "--db") orelse "data/wiktionary.bin";
        required_path.ensureExistsOrExit(init.io, input, "wiktionary dump");
        required_path.ensureExistsOrExit(init.io, db_path, "dictionary binary");

        const template_names = try loadDbTemplateNamesAlloc(allocator, db_path);
        defer freeOwnedStrings(allocator, template_names);

        var report = try lua.analyzeTemplateDependenciesAlloc(allocator, input, template_names);
        defer report.deinit(allocator);
        try printTemplateDependencyReport(allocator, report);
        if (report.unresolved_templates.len != 0 or report.compiled_failed.len != 0 or report.bytecode_inconsistent.len != 0) {
            return error.LuaDependencyAuditFailed;
        }
        return;
    }

    printUsage();
}

fn printUsage() void {
    std.debug.print(
        \\dict-lua compile --input path.lua
        \\dict-lua run --input path.lua
        \\dict-lua dump-module --input data/wiktionary.xml --name "string utilities"
        \\dict-lua deps [--input data/wiktionary.xml] [--structure data/wiktionary-structure.json]
        \\dict-lua deps --input data/wiktionary.xml --db data/wiktionary.bin
        \\dict-lua audit --input data/wiktionary.xml --db data/wiktionary.bin
        \\
    , .{});
}

fn flagValue(args: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], name)) return args[i + 1];
    }
    return null;
}

fn renderValuesAlloc(allocator: std.mem.Allocator, values: []const lua.Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (values, 0..) |value, idx| {
        if (idx != 0) try out.appendSlice(allocator, "\t");
        switch (value) {
            .nil => try out.appendSlice(allocator, "nil"),
            .boolean => |v| try out.appendSlice(allocator, if (v) "true" else "false"),
            .number => |v| {
                const text = try std.fmt.allocPrint(allocator, "{d}", .{v});
                defer allocator.free(text);
                try out.appendSlice(allocator, text);
            },
            .string => |v| try out.appendSlice(allocator, v),
            .table => try out.appendSlice(allocator, "table"),
            .function => try out.appendSlice(allocator, "function"),
            .iterator => try out.appendSlice(allocator, "iterator"),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn printDependencyReport(allocator: std.mem.Allocator, report: lua.DependencyReport) !void {
    std.debug.print("direct templates: {d}\n", .{report.direct_templates.len});
    std.debug.print("direct modules: {d}\n", .{report.direct_modules.len});
    std.debug.print("transitive modules: {d}\n", .{report.transitive_modules.len});
    std.debug.print("compiled ok: {d}\n", .{report.compiled_ok.len});
    std.debug.print("compiled failed: {d}\n", .{report.compiled_failed.len});
    std.debug.print("bytecode consistent: {d}\n", .{report.bytecode_consistent.len});
    std.debug.print("bytecode inconsistent: {d}\n", .{report.bytecode_inconsistent.len});
    if (report.compiled_failed.len != 0) {
        std.debug.print("first failures:\n", .{});
        for (report.compiled_failed[0..@min(report.compiled_failed.len, 32)]) |failure| {
            std.debug.print("  {s}: {s}\n", .{ failure.name, failure.reason });
        }
    }
    if (report.bytecode_inconsistent.len != 0) {
        std.debug.print("first bytecode mismatches:\n", .{});
        for (report.bytecode_inconsistent[0..@min(report.bytecode_inconsistent.len, 32)]) |failure| {
            std.debug.print("  {s}: {s}\n", .{ failure.name, failure.reason });
        }
    }
    _ = allocator;
}

fn printTemplateDependencyReport(allocator: std.mem.Allocator, report: lua.TemplateDependencyReport) !void {
    std.debug.print("root templates: {d}\n", .{report.root_templates.len});
    std.debug.print("reachable templates: {d}\n", .{report.reachable_templates.len});
    std.debug.print("unresolved templates: {d}\n", .{report.unresolved_templates.len});
    std.debug.print("direct modules: {d}\n", .{report.direct_modules.len});
    std.debug.print("transitive modules: {d}\n", .{report.transitive_modules.len});
    std.debug.print("compiled ok: {d}\n", .{report.compiled_ok.len});
    std.debug.print("compiled failed: {d}\n", .{report.compiled_failed.len});
    std.debug.print("bytecode consistent: {d}\n", .{report.bytecode_consistent.len});
    std.debug.print("bytecode inconsistent: {d}\n", .{report.bytecode_inconsistent.len});
    if (report.unresolved_templates.len != 0) {
        std.debug.print("first unresolved templates:\n", .{});
        for (report.unresolved_templates[0..@min(report.unresolved_templates.len, 32)]) |name| {
            std.debug.print("  {s}\n", .{name});
        }
    }
    if (report.compiled_failed.len != 0) {
        std.debug.print("first failures:\n", .{});
        for (report.compiled_failed[0..@min(report.compiled_failed.len, 32)]) |failure| {
            std.debug.print("  {s}: {s}\n", .{ failure.name, failure.reason });
        }
    }
    if (report.bytecode_inconsistent.len != 0) {
        std.debug.print("first bytecode mismatches:\n", .{});
        for (report.bytecode_inconsistent[0..@min(report.bytecode_inconsistent.len, 32)]) |failure| {
            std.debug.print("  {s}: {s}\n", .{ failure.name, failure.reason });
        }
    }
    _ = allocator;
}

const static_bin_template_names = [_][]const u8{
    "en-noun",
    "en-verb",
    "en-adj",
    "en-proper noun",
    "head",
    "plural of",
    "infl of",
    "lb",
    "IPA",
    "audio",
    "rhymes",
    "col",
    "col2",
    "col3",
    "col4",
    "col5",
};

const MappedReadOnlyFile = struct {
    mapping: []align(std.heap.page_size_min) const u8,

    fn deinit(self: *MappedReadOnlyFile) void {
        std.posix.munmap(self.mapping);
        self.* = undefined;
    }
};

fn loadDbTemplateNamesAlloc(allocator: std.mem.Allocator, db_path: []const u8) ![]const []const u8 {
    var mapped = try mmapReadOnlyPath(db_path);
    defer mapped.deinit();

    const inspected = try decoder.format.inspectDictionary(mapped.mapping);
    const mapping_start: usize = @intCast(inspected.layout.mappings_offset);
    const mapping_end: usize = @intCast(inspected.layout.mappings_offset + inspected.layout.mappings_len);
    const mapping_blob = mapped.mapping[mapping_start..mapping_end];

    var mappings = try decoder.format.parseCompactMappingsAlloc(allocator, mapping_blob);
    defer mappings.deinit(allocator);

    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var covered: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = covered.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        covered.deinit(allocator);
    }
    try compact_pattern_seed.seedCoveredTemplateNames(allocator, &covered);

    var covered_it = covered.iterator();
    while (covered_it.next()) |entry| try names.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
    for (mappings.line_templates) |entry| try names.append(allocator, try allocator.dupe(u8, entry.name));
    for (mappings.translation_templates) |entry| try names.append(allocator, try allocator.dupe(u8, entry.name));
    for (static_bin_template_names) |name| try names.append(allocator, try allocator.dupe(u8, name));
    return names.toOwnedSlice(allocator);
}

fn freeOwnedStrings(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn mmapReadOnlyPath(path: []const u8) !MappedReadOnlyFile {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
    }, 0);

    const io = std.Options.debug_io;
    var file: std.Io.File = .{
        .handle = fd,
        .flags = .{ .nonblocking = false },
    };
    defer file.close(io);
    const stat = try file.stat(io);
    const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    if (len == 0) return error.FileTooBig;

    const mapping = try std.posix.mmap(
        null,
        len,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    );
    return .{ .mapping = mapping };
}

fn readFileAlloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    const buffer = try allocator.alloc(u8, len);
    _ = try file.readPositionalAll(io, buffer, 0);
    return buffer;
}
