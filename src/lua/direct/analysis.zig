const std = @import("std");
const lua = @import("../parser/root.zig");
const global_abi = @import("../abi/globals.zig");

pub const Globals = struct {
    allocator: std.mem.Allocator,
    names: std.ArrayList([]const u8) = .empty,
    by_name: std.StringHashMapUnmanaged(u32) = .empty,
    mutated: std.AutoHashMapUnmanaged(u32, void) = .empty,
    owned: std.ArrayList([]u8) = .empty,
    global_table_escapes: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Globals {
        var self = Globals{ .allocator = allocator };
        errdefer self.deinit();
        for (global_abi.names) |name| _ = try self.ensure(name);
        return self;
    }

    pub fn deinit(self: *Globals) void {
        self.by_name.deinit(self.allocator);
        self.mutated.deinit(self.allocator);
        self.names.deinit(self.allocator);
        for (self.owned.items) |name| self.allocator.free(name);
        self.owned.deinit(self.allocator);
    }
    pub fn ensure(self: *Globals, name: []const u8) !u32 {
        if (self.by_name.get(name)) |slot| return slot;
        const copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(copy);
        const slot: u32 = @intCast(self.names.items.len);
        try self.names.append(self.allocator, copy);
        self.owned.append(self.allocator, copy) catch |err| {
            _ = self.names.pop();
            return err;
        };
        try self.by_name.put(self.allocator, copy, slot);
        return slot;
    }

    pub fn get(self: *const Globals, name: []const u8) ?u32 {
        return self.by_name.get(name);
    }
    pub fn markMutated(self: *Globals, name: []const u8) !void {
        const slot = try self.ensure(name);
        try self.mutated.put(self.allocator, slot, {});
    }

    pub fn stable(self: *const Globals, name: []const u8) bool {
        if (self.global_table_escapes) return false;
        const slot = self.get(name) orelse return false;
        return !self.mutated.contains(slot);
    }

    pub fn stableSlot(self: *const Globals, slot: u32) bool {
        return !self.global_table_escapes and slot < self.names.items.len and !self.mutated.contains(slot);
    }
};

pub const UpvalueSource = union(enum) {
    local: u32,
    upvalue: u32,
};

pub const Upvalue = struct {
    name: []const u8,
    source: UpvalueSource,
};
pub const StaticType = enum { unknown, nil, boolean, number, string };
pub const Binding = struct {
    name: []const u8,
    captured: bool = false,
    mutated: bool = false,
    called: bool = false,
    value_used: bool = false,
    function_span: ?lua.Span = null,
    late_function_init: bool = false,
    static_type: StaticType = .unknown,
    static_module: ?[]const u8 = null,

    pub fn directCallOnly(self: Binding) bool {
        return self.function_span != null and self.called and !self.value_used and !self.captured and !self.mutated;
    }
};

pub const FunctionInfo = struct {
    id: u32,
    params: []const []const u8,
    is_vararg: bool,
    body: lua.Block,
    span: lua.Span,
    bindings: []Binding,
    upvalues: []Upvalue,
    direct_only: bool = false,
};

pub const Module = struct {
    allocator: std.mem.Allocator,
    base_id: u32,
    functions: std.ArrayList(*FunctionInfo) = .empty,
    root: *FunctionInfo,

    pub fn deinit(self: *Module) void {
        for (self.functions.items) |info| {
            self.allocator.free(info.bindings);
            self.allocator.free(info.upvalues);
            self.allocator.destroy(info);
        }
        self.functions.deinit(self.allocator);
    }
};

const Capture = union(enum) { global, local: u32, upvalue: u32 };
const Save = struct { name: []const u8, previous: ?u32 };
const TypeDependency = struct { source: u32, target: u32 };
const Analyzer = struct {
    allocator: std.mem.Allocator,
    globals: *Globals,
    module: *Module,
    parent: ?*Analyzer,
    info: *FunctionInfo,
    locals: std.StringHashMapUnmanaged(u32) = .empty,
    saves: std.ArrayList(Save) = .empty,
    bindings: std.ArrayList(Binding) = .empty,
    upvalues: std.ArrayList(Upvalue) = .empty,
    upvalue_by_name: std.StringHashMapUnmanaged(u32) = .empty,
    type_dependencies: std.ArrayList(TypeDependency) = .empty,

    fn deinit(self: *Analyzer) void {
        self.locals.deinit(self.allocator);
        self.saves.deinit(self.allocator);
        self.bindings.deinit(self.allocator);
        self.upvalues.deinit(self.allocator);
        self.upvalue_by_name.deinit(self.allocator);
        self.type_dependencies.deinit(self.allocator);
    }

    fn bind(self: *Analyzer, name: []const u8) !u32 {
        const id: u32 = @intCast(self.bindings.items.len);
        try self.bindings.append(self.allocator, .{ .name = name });
        try self.saves.append(self.allocator, .{ .name = name, .previous = self.locals.get(name) });
        try self.locals.put(self.allocator, name, id);
        return id;
    }
    fn endScope(self: *Analyzer, mark: usize) void {
        while (self.saves.items.len > mark) {
            const save = self.saves.pop().?;
            if (save.previous) |id|
                self.locals.put(self.allocator, save.name, id) catch unreachable
            else
                _ = self.locals.remove(save.name);
        }
    }

    fn ensureUpvalue(self: *Analyzer, name: []const u8, source: UpvalueSource) !u32 {
        if (self.upvalue_by_name.get(name)) |ordinal| return ordinal;
        const ordinal: u32 = @intCast(self.upvalues.items.len);
        try self.upvalues.append(self.allocator, .{ .name = name, .source = source });
        try self.upvalue_by_name.put(self.allocator, name, ordinal);
        return ordinal;
    }

    fn captureForChild(self: *Analyzer, name: []const u8) !Capture {
        if (self.locals.get(name)) |binding| {
            self.bindings.items[binding].captured = true;
            // Captured locals live in boxed cells. Any scalar type inferred by
            // aliases before this closure was seen must be invalidated too.
            self.invalidateStaticType(binding);
            return .{ .local = binding };
        }
        const parent = self.parent orelse return .global;
        const outer = try parent.captureForChild(name);
        return switch (outer) {
            .global => .global,
            .local => |id| .{ .upvalue = try self.ensureUpvalue(name, .{ .local = id }) },
            .upvalue => |id| .{ .upvalue = try self.ensureUpvalue(name, .{ .upvalue = id }) },
        };
    }
    fn markValueUse(self: *Analyzer, name: []const u8) !void {
        switch (try self.resolve(name)) {
            .local => |binding| self.bindings.items[binding].value_used = true,
            .upvalue, .global => {},
        }
    }

    fn callee(self: *Analyzer, value: *const lua.Expr) anyerror!void {
        switch (value.*) {
            .name => |name| switch (try self.resolve(name.value)) {
                .local => |binding| self.bindings.items[binding].called = true,
                .upvalue, .global => {},
            },
            .paren => |v| try self.callee(v.expr),
            else => try self.expr(value),
        }
    }

    fn resolve(self: *Analyzer, name: []const u8) !Capture {
        if (self.locals.get(name)) |binding| return .{ .local = binding };
        const parent = self.parent orelse {
            _ = try self.globals.ensure(name);
            return .global;
        };
        const outer = try parent.captureForChild(name);
        return switch (outer) {
            .global => blk: {
                _ = try self.globals.ensure(name);
                break :blk .global;
            },
            .local => |id| .{ .upvalue = try self.ensureUpvalue(name, .{ .local = id }) },
            .upvalue => |id| .{ .upvalue = try self.ensureUpvalue(name, .{ .upvalue = id }) },
        };
    }

    fn staticString(value: *const lua.Expr) ?[]const u8 {
        return switch (value.*) {
            .string => |literal| literal.value,
            .paren => |paren| staticString(paren.expr),
            else => null,
        };
    }

    fn staticModuleValue(self: *Analyzer, value: *const lua.Expr) anyerror!?[]const u8 {
        return switch (value.*) {
            .call => |call| blk: {
                if (call.args.len != 1 or call.callee.* != .name or
                    !std.mem.eql(u8, call.callee.name.value, "require"))
                    break :blk null;
                switch (try self.resolve("require")) {
                    .global => {},
                    else => break :blk null,
                }
                break :blk staticString(call.args[0]);
            },
            .paren => |paren| self.staticModuleValue(paren.expr),
            .name => |name| switch (try self.resolve(name.value)) {
                .local => |binding| self.bindings.items[binding].static_module,
                else => null,
            },
            else => null,
        };
    }

    fn exprStaticType(self: *const Analyzer, value: *const lua.Expr) StaticType {
        return switch (value.*) {
            .nil_lit => .nil,
            .bool_lit => .boolean,
            .number => .number,
            .string => .string,
            .name => |name| if (self.locals.get(name.value)) |binding| self.bindings.items[binding].static_type else .unknown,
            .paren => |v| self.exprStaticType(v.expr),
            .unary => |v| switch (v.op) {
                .not_ => .boolean,
                .neg => if (self.exprStaticType(v.expr) == .number) .number else .unknown,
                .len => .number,
            },
            .binary => |v| switch (v.op) {
                .eq, .ne, .lt, .le, .gt, .ge => .boolean,
                .add, .sub, .mul, .div, .mod, .pow => if (self.exprStaticType(v.lhs) == .number and self.exprStaticType(v.rhs) == .number) .number else .unknown,
                .concat => blk: {
                    const lhs = self.exprStaticType(v.lhs);
                    const rhs = self.exprStaticType(v.rhs);
                    break :blk if ((lhs == .number or lhs == .string) and (rhs == .number or rhs == .string)) .string else .unknown;
                },
                // Lua logical operators return an operand, and the emitter keeps
                // their short-circuit result boxed. Keep mutable-local storage
                // conservative rather than claiming a native scalar type here.
                .and_, .or_ => .unknown,
            },
            .index, .call, .method_call, .function, .table, .vararg => .unknown,
        };
    }

    fn rhsTypes(self: *const Analyzer, values: []const *lua.Expr, needed: usize) ![]StaticType {
        const out = try self.allocator.alloc(StaticType, needed);
        if (needed == 0) return out;
        for (0..needed) |index| {
            if (index >= values.len) {
                const last_is_multi = values.len != 0 and isMultiExpr(values[values.len - 1]);
                out[index] = if (last_is_multi) .unknown else .nil;
            } else if (index + 1 == values.len and isMultiExpr(values[index])) {
                out[index] = .unknown;
            } else {
                out[index] = self.exprStaticType(values[index]);
            }
        }
        return out;
    }

    fn invalidateStaticType(self: *Analyzer, binding: u32) void {
        if (self.bindings.items[binding].static_type == .unknown) return;
        self.bindings.items[binding].static_type = .unknown;
        for (self.type_dependencies.items) |dependency|
            if (dependency.source == binding) self.invalidateStaticType(dependency.target);
    }

    fn addTypeDependency(self: *Analyzer, source: u32, target: u32) !void {
        if (source == target) return;
        for (self.type_dependencies.items) |dependency|
            if (dependency.source == source and dependency.target == target) return;
        try self.type_dependencies.append(self.allocator, .{ .source = source, .target = target });
    }

    fn collectTypeSources(self: *const Analyzer, value: *const lua.Expr, out: *std.ArrayList(u32)) !void {
        switch (value.*) {
            .name => |name| if (self.locals.get(name.value)) |binding| {
                for (out.items) |existing| if (existing == binding) return;
                try out.append(self.allocator, binding);
            },
            .paren => |v| try self.collectTypeSources(v.expr, out),
            .unary => |v| if (v.op == .neg) try self.collectTypeSources(v.expr, out),
            .binary => |v| switch (v.op) {
                .add, .sub, .mul, .div, .mod, .pow => {
                    try self.collectTypeSources(v.lhs, out);
                    try self.collectTypeSources(v.rhs, out);
                },
                else => {},
            },
            else => {},
        }
    }

    fn addTypeDependencies(self: *Analyzer, target: u32, value: *const lua.Expr) !void {
        var sources: std.ArrayList(u32) = .empty;
        defer sources.deinit(self.allocator);
        try self.collectTypeSources(value, &sources);
        for (sources.items) |source| try self.addTypeDependency(source, target);
    }

    fn mergeWriteType(self: *Analyzer, target: lua.LValue, incoming: StaticType) void {
        if (target != .name) return;
        const binding = self.locals.get(target.name) orelse return;
        if (self.bindings.items[binding].static_type != incoming) self.invalidateStaticType(binding);
    }

    fn analyzeWriteTarget(self: *Analyzer, target: lua.LValue) anyerror!void {
        switch (target) {
            .name => |name| switch (try self.resolve(name)) {
                .local => |binding| {
                    self.bindings.items[binding].mutated = true;
                    self.bindings.items[binding].static_module = null;
                },
                .upvalue => {},
                .global => try self.globals.markMutated(name),
            },
            .index => |idx| {
                try self.expr(idx.object);
                try self.expr(idx.key);
            },
        }
    }

    fn expr(self: *Analyzer, value: *const lua.Expr) anyerror!void {
        switch (value.*) {
            .name => |name| {
                if (std.mem.eql(u8, name.value, "_G")) self.globals.global_table_escapes = true;
                try self.markValueUse(name.value);
            },
            .paren => |v| try self.expr(v.expr),
            .index => |v| {
                try self.expr(v.object);
                try self.expr(v.key);
            },
            .call => |v| {
                try self.callee(v.callee);
                for (v.args) |arg| try self.expr(arg);
            },
            .method_call => |v| {
                try self.expr(v.object);
                for (v.args) |arg| try self.expr(arg);
            },
            .function => |f| _ = try analyzeFunction(self.allocator, self.globals, self.module, self, f.params, f.is_vararg, f.body, f.span),
            .table => |v| for (v.fields) |field| switch (field) {
                .list => |item| try self.expr(item),
                .named => |item| try self.expr(item.value),
                .keyed => |item| {
                    try self.expr(item.key);
                    try self.expr(item.value);
                },
            },
            .unary => |v| try self.expr(v.expr),
            .binary => |v| {
                try self.expr(v.lhs);
                try self.expr(v.rhs);
            },
            .nil_lit, .bool_lit, .number, .string, .vararg => {},
        }
    }

    fn scopedBlock(self: *Analyzer, body: lua.Block) anyerror!void {
        const mark = self.saves.items.len;
        defer self.endScope(mark);
        try self.block(body);
    }

    fn block(self: *Analyzer, body: lua.Block) anyerror!void {
        for (body) |stmt| try self.statement(stmt);
    }

    fn statement(self: *Analyzer, stmt: *const lua.Stmt) anyerror!void {
        switch (stmt.*) {
            .empty, .break_stmt => {},
            .local_assign => |s| {
                for (s.values) |value| try self.expr(value);
                const static_module = if (s.names.len == 1 and s.values.len == 1)
                    try self.staticModuleValue(s.values[0])
                else
                    null;
                const types = try self.rhsTypes(s.values, s.names.len);
                defer self.allocator.free(types);
                const sources = try self.allocator.alloc(std.ArrayList(u32), s.names.len);
                defer self.allocator.free(sources);
                for (sources) |*items| items.* = .empty;
                defer for (sources) |*items| items.deinit(self.allocator);
                for (s.names, 0..) |_, index| if (index < s.values.len and !(index + 1 == s.values.len and isMultiExpr(s.values[index])))
                    try self.collectTypeSources(s.values[index], &sources[index]);
                for (s.names, types, 0..) |name, static_type, index| {
                    const binding = try self.bind(name);
                    self.bindings.items[binding].static_type = static_type;
                    if (index == 0) self.bindings.items[binding].static_module = static_module;
                    for (sources[index].items) |source| try self.addTypeDependency(source, binding);
                    if (s.values.len == s.names.len and s.values[index].* == .function)
                        self.bindings.items[binding].function_span = s.values[index].function.span;
                }
            },
            .assign => |s| {
                for (s.targets) |target| try self.analyzeWriteTarget(target);
                for (s.values) |value| try self.expr(value);
                const types = try self.rhsTypes(s.values, s.targets.len);
                defer self.allocator.free(types);
                for (s.targets, types, 0..) |target, static_type, index| {
                    self.mergeWriteType(target, static_type);
                    if (target == .name and index < s.values.len and !(index + 1 == s.values.len and isMultiExpr(s.values[index]))) {
                        const binding = self.locals.get(target.name) orelse continue;
                        if (self.bindings.items[binding].static_type != .unknown)
                            try self.addTypeDependencies(binding, s.values[index]);
                    }
                }
            },
            .call => |s| try self.expr(s.expr),
            .do_block => |s| try self.scopedBlock(s.body),
            .while_loop => |s| {
                try self.expr(s.cond);
                try self.scopedBlock(s.body);
            },
            .repeat_loop => |s| {
                const mark = self.saves.items.len;
                defer self.endScope(mark);
                try self.block(s.body);
                try self.expr(s.cond);
            },
            .if_stmt => |s| {
                for (s.branches) |branch| {
                    try self.expr(branch.cond);
                    try self.scopedBlock(branch.body);
                }
                if (s.else_body) |body| try self.scopedBlock(body);
            },
            .numeric_for => |s| {
                try self.expr(s.start);
                try self.expr(s.limit);
                if (s.step) |step| try self.expr(step);
                const mark = self.saves.items.len;
                defer self.endScope(mark);
                const binding = try self.bind(s.name);
                self.bindings.items[binding].mutated = true;
                self.bindings.items[binding].static_type = .number;
                try self.block(s.body);
            },
            .generic_for => |s| {
                for (s.values) |value| try self.expr(value);
                const mark = self.saves.items.len;
                defer self.endScope(mark);
                for (s.names) |name| {
                    const binding = try self.bind(name);
                    self.bindings.items[binding].mutated = true;
                }
                try self.block(s.body);
            },
            .function_assign => |s| {
                try self.analyzeWriteTarget(s.target);
                self.mergeWriteType(s.target, .unknown);
                try self.expr(s.function);
            },
            .local_function => |s| {
                const binding = try self.bind(s.name);
                self.bindings.items[binding].function_span = s.function.function.span;
                self.bindings.items[binding].late_function_init = true;
                try self.expr(s.function);
            },
            .return_stmt => |s| for (s.values) |value| try self.expr(value),
        }
    }
};

fn analyzeFunction(
    allocator: std.mem.Allocator,
    globals: *Globals,
    module: *Module,
    parent: ?*Analyzer,
    params: []const []const u8,
    is_vararg: bool,
    body: lua.Block,
    span: lua.Span,
) anyerror!*FunctionInfo {
    const info = try allocator.create(FunctionInfo);
    errdefer allocator.destroy(info);
    const id: u32 = module.base_id + @as(u32, @intCast(module.functions.items.len));
    info.* = .{ .id = id, .params = params, .is_vararg = is_vararg, .body = body, .span = span, .bindings = &.{}, .upvalues = &.{} };
    try module.functions.append(allocator, info);
    var analyzer = Analyzer{
        .allocator = allocator,
        .globals = globals,
        .module = module,
        .parent = parent,
        .info = info,
    };
    defer analyzer.deinit();
    for (params) |name| _ = try analyzer.bind(name);
    try analyzer.block(body);
    for (analyzer.bindings.items) |binding| if (binding.directCallOnly()) {
        const target_span = binding.function_span.?;
        for (module.functions.items) |target| {
            if (target.span.start == target_span.start and target.span.end == target_span.end) {
                target.direct_only = true;
                break;
            }
        }
    };
    info.bindings = try analyzer.bindings.toOwnedSlice(allocator);
    info.upvalues = try analyzer.upvalues.toOwnedSlice(allocator);
    return info;
}

pub fn analyze(
    allocator: std.mem.Allocator,
    globals: *Globals,
    chunk: *const lua.Chunk,
    function_base: u32,
) !Module {
    var module = Module{ .allocator = allocator, .root = undefined, .base_id = function_base };
    errdefer module.deinit();
    const synthetic_span = lua.Span{ .start = 0, .end = @intCast(chunk.source.len) };
    module.root = try analyzeFunction(allocator, globals, &module, null, &.{}, true, chunk.body, synthetic_span);
    return module;
}

fn isMultiExpr(value: *const lua.Expr) bool {
    return switch (value.*) {
        .call, .method_call, .vararg => true,
        else => false,
    };
}
