//! Runtime-specific native AOT expansion worker. No VM/bytecode imports belong here.
const std = @import("std");
const generated = @import("generated");
const rt = @import("zig_runtime");
const enc = @import("blob_encoder");
const blob_files = @import("blob_files");
const storage = @import("blob_storage");
const pages = @import("native_runtime_pages.zig");
const A = std.mem.Allocator;
const L = std.os.linux;

pub const Request = struct {
    root: []const u8,
    title: []const u8,
    source: []const u8,
    dictionary_root: ?[]const u8 = null,
    language: []const u8 = "English",
};

pub const Reply = struct {
    schema: []const u8 = "dict.expansion.v1",
    backend: []const u8 = "lua-aot",
    output: ?[]const u8 = null,
    stage: []const u8 = "expand",
    error_name: ?[]const u8 = null,
    detail: ?[]const u8 = null,
};

fn limit(resource: std.posix.rlimit_resource, value: u64) !void {
    const old = try std.posix.getrlimit(resource);
    const n = @min(value, old.max);
    try std.posix.setrlimit(resource, .{ .cur = @intCast(n), .max = @intCast(n) });
}

fn validateRequest(request: Request) !void {
    if (request.source.len > 16 * 1024 * 1024 or request.root.len == 0 or request.root.len > 4096 or request.title.len == 0 or request.title.len > 4096 or request.language.len > 4096) return error.InvalidRequest;
}

const ModuleResolver = struct {
    a: A,
    redirects: std.StringHashMapUnmanaged([]const u8) = .empty,
    fallback_ctx: ?*const anyopaque = null,
    fallback_lookup: ?rt.ModuleLookupFn = null,
    fallback_name: ?rt.ModuleNameFn = null,

    fn deinit(self: *ModuleResolver) void {
        var it = self.redirects.iterator();
        while (it.next()) |entry| {
            self.a.free(entry.key_ptr.*);
            self.a.free(entry.value_ptr.*);
        }
        self.redirects.deinit(self.a);
    }

    fn unescape(a: A, raw: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] != '\\' or i + 1 >= raw.len) {
                try out.append(a, raw[i]);
                continue;
            }
            i += 1;
            try out.append(a, switch (raw[i]) {
                't' => '\t',
                'n' => '\n',
                'r' => '\r',
                '\\' => '\\',
                else => raw[i],
            });
        }
        return out.toOwnedSlice(a);
    }

    fn put(self: *ModuleResolver, from: []const u8, to: []const u8) !void {
        const from_copy = try self.a.dupe(u8, from);
        errdefer self.a.free(from_copy);
        const to_copy = try self.a.dupe(u8, to);
        errdefer self.a.free(to_copy);
        const result = try self.redirects.getOrPut(self.a, from_copy);
        if (result.found_existing) {
            self.a.free(from_copy);
            self.a.free(result.value_ptr.*);
        } else result.key_ptr.* = from_copy;
        result.value_ptr.* = to_copy;
    }

    fn load(self: *ModuleResolver, io: std.Io, root: []const u8) !void {
        const path = try std.fs.path.join(self.a, &.{ root, "module-redirects.tsv" });
        defer self.a.free(path);
        if (std.Io.Dir.cwd().readFileAlloc(io, path, self.a, .limited(16 * 1024 * 1024))) |bytes| {
            defer self.a.free(bytes);
            var lines = std.mem.splitScalar(u8, bytes, '\n');
            while (lines.next()) |line| {
                if (!std.mem.startsWith(u8, line, "M\t")) continue;
                var fields = std.mem.splitScalar(u8, line, '\t');
                _ = fields.next();
                const from_raw = fields.next() orelse continue;
                const to_raw = fields.next() orelse continue;
                const from = try unescape(self.a, from_raw);
                defer self.a.free(from);
                const to = try unescape(self.a, to_raw);
                defer self.a.free(to);
                try self.put(from, to);
            }
            return;
        } else |err| if (err != error.FileNotFound) return err;

        const redirects_path = try std.fs.path.join(self.a, &.{ root, "redirects.wikblb" });
        defer self.a.free(redirects_path);
        var redirects_file = storage.File.open(io, self.a, redirects_path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer redirects_file.deinit();
        if (redirects_file.view.kind != .redirects or !redirects_file.view.symbolic) return error.InvalidRuntimeArtifact;
        var symbols: blob_files.SymbolSource = .{ .io = io, .a = self.a, .root = root };
        defer symbols.deinit();
        const names = try symbols.load();
        if (!std.mem.eql(u8, &names.digest(), &redirects_file.view.binding_id)) return error.SymbolIdentityMismatch;
        for (0..redirects_file.recordCount()) |i| {
            const key = try redirects_file.titleAt(i);
            const from_id = try std.fmt.parseInt(usize, key, 16);
            var record = try redirects_file.readAlloc(self.a, i);
            defer record.deinit();
            var pos: usize = 0;
            const to_id = try enc.blob_format.readPayloadLength(record.payload, &pos);
            if (pos != record.payload.len) return error.InvalidRedirect;
            try self.put(try names.get(from_id), try names.get(to_id));
        }
    }

    fn lookup(raw: ?*const anyopaque, raw_name: []const u8) ?u32 {
        const self: *const ModuleResolver = @ptrCast(@alignCast(raw orelse return null));
        const fallback = self.fallback_lookup orelse return null;
        var current = raw_name;
        var depth: usize = 0;
        while (self.redirects.get(current)) |target| {
            depth += 1;
            if (depth > 32) return null;
            current = target;
        }
        return fallback(self.fallback_ctx, current);
    }

    fn name(raw: ?*const anyopaque, id: u32) ?[]const u8 {
        const self: *const ModuleResolver = @ptrCast(@alignCast(raw orelse return null));
        const fallback = self.fallback_name orelse return null;
        return fallback(self.fallback_ctx, id);
    }

    fn configure(self: *ModuleResolver, ctx: *rt.Context) void {
        self.fallback_ctx = ctx.module_lookup_ctx;
        self.fallback_lookup = ctx.module_lookup;
        self.fallback_name = ctx.module_name;
        ctx.configureModules(self, lookup, name);
    }
};

const Engine = struct {
    io: std.Io,
    requested_root: []const u8,
    root: []const u8,
    program_data: ?rt.ProgramData = null,
    resolver: ModuleResolver,
    provider: ?pages.Provider = null,
    provider_dictionary_root: ?[]const u8 = null,
    provider_language: ?[]const u8 = null,

    fn fileExists(io: std.Io, path: []const u8) !bool {
        var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        file.close(io);
        return true;
    }

    fn init(io: std.Io, a: A, requested_root: []const u8) !Engine {
        const marker = try std.fs.path.join(a, &.{ requested_root, ".incomplete" });
        if (try fileExists(io, marker)) return error.RuntimeBuildIncomplete;
        const direct_manifest = try std.fs.path.join(a, &.{ requested_root, "manifest.jsonl" });
        const direct_templates = try std.fs.path.join(a, &.{ requested_root, "templates.wikblb" });
        const nested = try std.fs.path.join(a, &.{ requested_root, "runtime" });
        const nested_marker = try std.fs.path.join(a, &.{ nested, ".incomplete" });
        if (try fileExists(io, nested_marker)) return error.RuntimeBuildIncomplete;
        const nested_manifest = try std.fs.path.join(a, &.{ nested, "manifest.jsonl" });
        const root = if (try fileExists(io, direct_manifest) or try fileExists(io, direct_templates))
            try a.dupe(u8, requested_root)
        else if (try fileExists(io, nested_manifest))
            nested
        else
            return error.RuntimeAssetsMissing;
        var resolver: ModuleResolver = .{ .a = a };
        errdefer resolver.deinit();
        try resolver.load(io, root);
        const program_data: ?rt.ProgramData = if (generated.requires_program_data) blk: {
            const data_path = try std.fs.path.join(a, &.{ root, "aot-data.bin" });
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, data_path, a, .limited(1024 * 1024 * 1024));
            break :blk try rt.ProgramData.parse(bytes);
        } else null;
        return .{ .io = io, .requested_root = try a.dupe(u8, requested_root), .root = root, .program_data = program_data, .resolver = resolver };
    }

    fn sameOptional(a: ?[]const u8, b: ?[]const u8) bool {
        if (a == null or b == null) return a == null and b == null;
        return std.mem.eql(u8, a.?, b.?);
    }

    fn clearProvider(self: *Engine) void {
        const a = std.heap.smp_allocator;
        if (self.provider) |*provider| provider.deinit();
        self.provider = null;
        if (self.provider_dictionary_root) |root| a.free(root);
        if (self.provider_language) |language| a.free(language);
        self.provider_dictionary_root = null;
        self.provider_language = null;
    }

    fn deinit(self: *Engine) void {
        self.clearProvider();
        self.resolver.deinit();
    }

    fn providerFor(self: *Engine, dictionary_root: ?[]const u8, language: []const u8) !*pages.Provider {
        if (self.provider != null and sameOptional(self.provider_dictionary_root, dictionary_root) and
            self.provider_language != null and std.mem.eql(u8, self.provider_language.?, language))
            return &self.provider.?;

        self.clearProvider();
        const a = std.heap.smp_allocator;
        const root_copy = if (dictionary_root) |root| try a.dupe(u8, root) else null;
        errdefer if (root_copy) |root| a.free(root);
        const language_copy = try a.dupe(u8, language);
        errdefer a.free(language_copy);
        self.provider = try pages.Provider.init(self.io, a, self.root, root_copy, language_copy);
        self.provider_dictionary_root = root_copy;
        self.provider_language = language_copy;
        return &self.provider.?;
    }

    fn expand(self: *Engine, page_a: A, request: Request, stage: *[]const u8, detail: *?[]const u8) ![]const u8 {
        if (!std.mem.eql(u8, request.root, self.requested_root)) return error.RuntimeRootChanged;
        stage.* = "assets";
        const provider = try self.providerFor(request.dictionary_root, request.language);
        stage.* = "install";
        var ctx = if (generated.requires_program_data)
            try generated.initContextWithData(page_a, self.program_data orelse return error.RuntimeAssetsMissing)
        else
            try generated.initContext(page_a);
        defer ctx.deinit();
        self.resolver.configure(&ctx);
        var expander = generated.initExpander(&ctx, provider.api());
        stage.* = "expand";
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        return expander.expandFragment(request.title, request.source, now) catch |err| {
            detail.* = try page_a.dupe(u8, ctx.aotErrorName() orelse @errorName(err));
            return err;
        };
    }
};

fn writeFrame(w: *std.Io.Writer, bytes: []const u8) !void {
    if (bytes.len > 32 * 1024 * 1024) return error.FrameTooLarge;
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(bytes.len), .little);
    try w.writeAll(&length);
    try w.writeAll(bytes);
    try w.flush();
}

pub fn main(init: std.process.Init) !void {
    try limit(.CORE, 0);
    if (L.errno(L.prctl(@intFromEnum(L.PR.SET_PDEATHSIG), @intFromEnum(L.SIG.KILL), 0, 0, 0)) != .SUCCESS) return error.ParentDeathSignalFailed;
    if (L.getppid() == 1) return error.ParentExited;
    try limit(.AS, 2 * 1024 * 1024 * 1024);
    const persistent = init.arena.allocator();
    var engine: ?Engine = null;
    defer if (engine) |*value| value.deinit();
    var in_buf: [8192]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(init.io, &in_buf);
    var out_buf: [8192]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &out_buf);
    while (true) {
        var raw_length: [4]u8 = undefined;
        input.interface.readSliceAll(&raw_length) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        const length = std.mem.readInt(u32, &raw_length, .little);
        if (length == 0 or length > 32 * 1024 * 1024) return error.InvalidFrame;
        var page = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer page.deinit();
        const page_a = page.allocator();
        const bytes = try page_a.alloc(u8, length);
        try input.interface.readSliceAll(bytes);
        var reply: Reply = .{};
        const parsed = std.json.parseFromSlice(Request, page_a, bytes, .{}) catch |err| {
            reply.stage = "request";
            reply.error_name = @errorName(err);
            try writeFrame(&output.interface, try std.json.Stringify.valueAlloc(page_a, reply, .{}));
            continue;
        };
        const request = parsed.value;
        validateRequest(request) catch |err| {
            reply.stage = "request";
            reply.error_name = @errorName(err);
            try writeFrame(&output.interface, try std.json.Stringify.valueAlloc(page_a, reply, .{}));
            continue;
        };
        if (engine == null) {
            reply.stage = "assets";
            engine = Engine.init(init.io, persistent, request.root) catch |err| {
                reply.error_name = @errorName(err);
                try writeFrame(&output.interface, try std.json.Stringify.valueAlloc(page_a, reply, .{}));
                continue;
            };
        }
        reply.output = engine.?.expand(page_a, request, &reply.stage, &reply.detail) catch |err| blk: {
            reply.error_name = reply.detail orelse @errorName(err);
            break :blk null;
        };
        if (reply.output) |text| if (text.len > 16 * 1024 * 1024) {
            reply.output = null;
            reply.error_name = "ExpandedSourceTooLarge";
        };
        try writeFrame(&output.interface, try std.json.Stringify.valueAlloc(page_a, reply, .{}));
    }
}
