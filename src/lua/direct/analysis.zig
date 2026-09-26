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
    mutated: bool = false,
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
    callable_field_hint: ?[]const u8 = null,

    pub fn directCallOnly(self: Binding) bool {
        return self.function_span != null and self.called and !self.value_used and !self.captured and !self.mutated;
    }
};

pub const FunctionInfo = struct {
    id: u32,
    parent_id: ?u32 = null,
    params: []const []const u8,
    is_vararg: bool,
    body: lua.Block,
    span: lua.Span,
    bindings: []Binding,
    upvalues: []Upvalue,
    direct_only: bool = false,
    dead: bool = false,
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

    fn markLocalMutated(self: *Analyzer, binding: u32) void {
        self.bindings.items[binding].mutated = true;
        self.bindings.items[binding].static_module = null;
        self.invalidateStaticType(binding);
    }

    fn markUpvalueMutated(self: *Analyzer, ordinal: u32) void {
        if (ordinal >= self.upvalues.items.len) return;
        const source = self.upvalues.items[ordinal].source;
        self.upvalues.items[ordinal].mutated = true;
        const parent = self.parent orelse return;
        switch (source) {
            .local => |binding| parent.markLocalMutated(binding),
            .upvalue => |parent_ordinal| parent.markUpvalueMutated(parent_ordinal),
        }
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

    fn staticFieldName(value: *const lua.Expr) ?[]const u8 {
        return switch (value.*) {
            .index => |index| staticString(index.key),
            .paren => |paren| staticFieldName(paren.expr),
            else => null,
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
                .upvalue => |ordinal| self.markUpvalueMutated(ordinal),
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
                    if (s.values.len == s.names.len)
                        self.bindings.items[binding].callable_field_hint = staticFieldName(s.values[index]);
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
    info.* = .{
        .id = id,
        .parent_id = if (parent) |owner| owner.info.id else null,
        .params = params,
        .is_vararg = is_vararg,
        .body = body,
        .span = span,
        .bindings = &.{},
        .upvalues = &.{},
    };
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
    for (analyzer.bindings.items) |binding| if (binding.function_span) |target_span| {
        for (module.functions.items) |target| {
            if (target.span.start != target_span.start or target.span.end != target_span.end) continue;
            if (binding.directCallOnly()) target.direct_only = true;
            break;
        }
    };
    info.bindings = try analyzer.bindings.toOwnedSlice(allocator);
    info.upvalues = try analyzer.upvalues.toOwnedSlice(allocator);
    return info;
}

const FunctionOrigin = struct {
    owner_index: usize,
    binding: u32,
};

fn functionIndex(module: *const Module, id: u32) ?usize {
    if (id < module.base_id) return null;
    const index: usize = @intCast(id - module.base_id);
    return if (index < module.functions.items.len) index else null;
}

fn upvalueOrigin(module: *const Module, function_index: usize, ordinal: u32) ?FunctionOrigin {
    var current_index = function_index;
    var current_ordinal = ordinal;
    while (true) {
        const current = module.functions.items[current_index];
        if (current_ordinal >= current.upvalues.len) return null;
        const parent_index = functionIndex(module, current.parent_id orelse return null) orelse return null;
        switch (current.upvalues[current_ordinal].source) {
            .local => |binding| return .{ .owner_index = parent_index, .binding = binding },
            .upvalue => |parent_ordinal| {
                current_index = parent_index;
                current_ordinal = parent_ordinal;
            },
        }
    }
}

fn addFunctionEdge(adjacency: []std.ArrayList(u32), allocator: std.mem.Allocator, from: usize, to: usize) !void {
    for (adjacency[from].items) |existing| if (existing == to) return;
    try adjacency[from].append(allocator, @intCast(to));
}

fn computeFunctionLiveness(allocator: std.mem.Allocator, module: *Module) !void {
    if (module.functions.items.len == 0) return;

    var by_span: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer by_span.deinit(allocator);
    for (module.functions.items, 0..) |info, index|
        try by_span.put(allocator, info.span.start, @intCast(index));

    const bound = try allocator.alloc(bool, module.functions.items.len);
    defer allocator.free(bound);
    @memset(bound, false);

    const adjacency = try allocator.alloc(std.ArrayList(u32), module.functions.items.len);
    defer allocator.free(adjacency);
    for (adjacency) |*edges| edges.* = .empty;
    defer for (adjacency) |*edges| edges.deinit(allocator);

    for (module.functions.items, 0..) |owner, owner_index| {
        for (owner.bindings) |binding| if (binding.function_span) |span| {
            const target_index_u32 = by_span.get(span.start) orelse continue;
            const target_index: usize = @intCast(target_index_u32);
            const target = module.functions.items[target_index];
            if (target.span.end != span.end or target.parent_id != owner.id) continue;
            bound[target_index] = true;
            if (binding.called or binding.value_used or binding.mutated)
                try addFunctionEdge(adjacency, allocator, owner_index, target_index);
        };
    }

    for (module.functions.items[1..], 1..) |info, index| {
        if (bound[index]) continue;
        const parent_index = functionIndex(module, info.parent_id orelse continue) orelse continue;
        try addFunctionEdge(adjacency, allocator, parent_index, index);
    }

    for (module.functions.items, 0..) |info, source_index| {
        for (info.upvalues, 0..) |_, ordinal| {
            const origin = upvalueOrigin(module, source_index, @intCast(ordinal)) orelse continue;
            const owner = module.functions.items[origin.owner_index];
            if (origin.binding >= owner.bindings.len) return error.FunctionAnalysisMismatch;
            const span = owner.bindings[origin.binding].function_span orelse continue;
            const target_index_u32 = by_span.get(span.start) orelse continue;
            const target_index: usize = @intCast(target_index_u32);
            const target = module.functions.items[target_index];
            if (target.span.end != span.end or target.parent_id != owner.id) continue;
            try addFunctionEdge(adjacency, allocator, source_index, target_index);
        }
    }

    const live = try allocator.alloc(bool, module.functions.items.len);
    defer allocator.free(live);
    @memset(live, false);
    const queue = try allocator.alloc(u32, module.functions.items.len);
    defer allocator.free(queue);
    live[0] = true;
    queue[0] = 0;
    var read_at: usize = 0;
    var write_at: usize = 1;
    while (read_at < write_at) : (read_at += 1) {
        const source: usize = @intCast(queue[read_at]);
        for (adjacency[source].items) |target_u32| {
            const target: usize = @intCast(target_u32);
            if (live[target]) continue;
            live[target] = true;
            queue[write_at] = target_u32;
            write_at += 1;
        }
    }
    for (module.functions.items, live) |info, is_live| info.dead = !is_live;
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
    try computeFunctionLiveness(allocator, &module);
    return module;
}

test "analysis marks unused local functions and descendants dead" {
    const source =
        \\local function dead()
        \\  local function child() return 1 end
        \\  return child
        \\end
        \\local function live() return 2 end
        \\return live
    ;
    var chunk = try @import("../parser/root.zig").parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try analyze(std.testing.allocator, &globals, &chunk, 20);
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 4), module.functions.items.len);
    try std.testing.expect(!module.functions.items[0].dead);
    try std.testing.expect(module.functions.items[1].dead);
    try std.testing.expect(module.functions.items[2].dead);
    try std.testing.expect(!module.functions.items[3].dead);
    try std.testing.expectEqual(@as(?u32, 20), module.functions.items[1].parent_id);
    try std.testing.expectEqual(@as(?u32, 21), module.functions.items[2].parent_id);
}

test "analysis prunes unrooted recursive functions but keeps called recursion" {
    const source =
        \\local function called() return 1 end
        \\local function dead_recursive() return dead_recursive() end
        \\local function live_recursive(n)
        \\  if n == 0 then return 0 end
        \\  return live_recursive(n - 1)
        \\end
        \\called()
        \\return live_recursive(2)
    ;
    var chunk = try @import("../parser/root.zig").parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();

    try std.testing.expect(!module.functions.items[1].dead);
    try std.testing.expect(module.functions.items[1].direct_only);
    try std.testing.expect(module.functions.items[2].dead);
    try std.testing.expect(!module.functions.items[3].dead);
}

test "analysis roots function values through live captured dependencies only" {
    const source =
        \\local hidden = function() return 7 end
        \\local function dead_wrapper() return hidden end
        \\local kept = function() return 9 end
        \\local function live_wrapper() return kept() end
        \\return live_wrapper
    ;
    var chunk = try @import("../parser/root.zig").parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 5), module.functions.items.len);
    try std.testing.expect(module.functions.items[1].dead);
    try std.testing.expect(module.functions.items[2].dead);
    try std.testing.expect(!module.functions.items[3].dead);
    try std.testing.expect(!module.functions.items[4].dead);
}

test "analysis propagates captured upvalue mutation through descendants" {
    const source =
        \\local data = "a"
        \\local function outer()
        \\  local function inner() data = "b" end
        \\  return inner
        \\end
        \\return outer
    ;
    var chunk = try @import("../parser/root.zig").parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 3), module.functions.items.len);
    const outer = module.functions.items[1];
    const inner = module.functions.items[2];
    try std.testing.expectEqual(@as(usize, 1), outer.upvalues.len);
    try std.testing.expectEqual(@as(usize, 1), inner.upvalues.len);
    try std.testing.expect(outer.upvalues[0].mutated);
    try std.testing.expect(inner.upvalues[0].mutated);
}

fn isMultiExpr(value: *const lua.Expr) bool {
    return switch (value.*) {
        .call, .method_call, .vararg => true,
        else => false,
    };
}
