const std = @import("std");
const structure_report = @import("shared_structure_report");
const xml_decode = @import("shared_xml_decode");

pub const CompileError = error{
    UnexpectedToken,
    UnexpectedEof,
    UnsupportedSyntax,
    InvalidNumber,
    InvalidAssignment,
};

pub const RuntimeError = error{
    TypeError,
    UnknownVariable,
    InvalidCall,
    InvalidIndex,
    UnsupportedGenericFor,
};

pub const Value = union(enum) {
    nil,
    boolean: bool,
    number: f64,
    string: []const u8,
    table: *Table,
    generated_callable: GeneratedCallable,
    function: *Function,
    iterator: Iterator,

    pub fn truthy(self: Value) bool {
        return switch (self) {
            .nil => false,
            .boolean => |v| v,
            else => true,
        };
    }
};

pub const Iterator = struct {
    kind: enum { pairs, ipairs },
    table: *Table,
    index: usize = 0,
};

pub const GeneratedCallable = struct {
    id: u32,
    capture: ?*anyopaque,
    globals: ?*anyopaque,
};

pub const Table = struct {
    allocator: std.mem.Allocator,
    array: std.ArrayList(Value) = .empty,
    string_fields: std.StringHashMapUnmanaged(Value) = .empty,
    int_fields: std.AutoHashMapUnmanaged(i64, Value) = .empty,

    pub fn init(allocator: std.mem.Allocator) !*Table {
        const table = try allocator.create(Table);
        table.* = .{ .allocator = allocator };
        return table;
    }

    pub fn get(self: *const Table, key: Value) Value {
        return switch (key) {
            .string => |name| self.getString(name),
            .number => |num| self.getNumber(num),
            else => .nil,
        };
    }

    pub fn set(self: *Table, key: Value, value: Value) !void {
        switch (key) {
            .string => |name| try self.putString(name, value),
            .number => |num| try self.putNumber(num, value),
            else => return error.InvalidIndex,
        }
    }

    pub fn getString(self: *const Table, key: []const u8) Value {
        return self.string_fields.get(key) orelse .nil;
    }

    pub fn putString(self: *Table, key: []const u8, value: Value) !void {
        const gop = try self.string_fields.getOrPut(self.allocator, key);
        if (!gop.found_existing) gop.key_ptr.* = try self.allocator.dupe(u8, key);
        gop.value_ptr.* = value;
    }

    pub fn putStringBorrowed(self: *Table, key: []const u8, value: Value) !void {
        const gop = try self.string_fields.getOrPut(self.allocator, key);
        if (!gop.found_existing) gop.key_ptr.* = key;
        gop.value_ptr.* = value;
    }

    fn getNumber(self: *const Table, num: f64) Value {
        const int = floatToExactPositiveInt(num) orelse return .nil;
        if (int >= 1 and int <= self.array.items.len) return self.array.items[int - 1];
        return if (self.int_fields.get(@intCast(int))) |value| value else .nil;
    }

    pub fn putNumber(self: *Table, num: f64, value: Value) !void {
        const int = floatToExactPositiveInt(num) orelse return error.InvalidIndex;
        if (int >= 1 and int <= self.array.items.len + 1) {
            if (int == self.array.items.len + 1) {
                try self.array.append(self.allocator, value);
            } else {
                self.array.items[int - 1] = value;
            }
            return;
        }
        try self.int_fields.put(self.allocator, @intCast(int), value);
    }
};

const NativeFn = *const fn (vm: *Vm, args: []const Value) anyerror![]Value;
pub const GeneratedInvokeFn = *const fn (
    capture: ?*anyopaque,
    globals: ?*anyopaque,
    runtime: *GeneratedRuntime,
    args: []const Value,
) anyerror![]Value;

pub const ConstValueSeed = union(enum) {
    nil,
    boolean: bool,
    number: f64,
    string: []const u8,
    table: *const ConstTableSeed,
};

pub const ConstTableStringFieldSeed = struct {
    key: []const u8,
    value: ConstValueSeed,
};

pub const ConstTableIntFieldSeed = struct {
    key: i64,
    value: ConstValueSeed,
};

pub const ConstTableSeed = struct {
    array: []const ConstValueSeed,
    string_fields: []const ConstTableStringFieldSeed,
    int_fields: []const ConstTableIntFieldSeed,
};

pub const FunctionKind = union(enum) {
    user: UserFunction,
    native: NativeFn,
    generated: struct {
        capture: ?*anyopaque,
        globals: ?*anyopaque,
        invoke: GeneratedInvokeFn,
    },
};

pub const Function = struct {
    name: []const u8,
    kind: FunctionKind,
    env: ?*Env,
};

pub const UserFunction = struct {
    params: []const []const u8,
    body: []const *Stmt,
    is_vararg: bool = false,
};

pub const Chunk = struct {
    arena: std.heap.ArenaAllocator,
    source: []const u8,
    body: []const *Stmt,

    pub fn deinit(self: *Chunk) void {
        self.arena.deinit();
    }
};

pub const RunResult = struct {
    vm: Vm,
    returns: []const Value,

    pub fn deinit(self: *RunResult) void {
        self.vm.deinit();
        self.* = undefined;
    }
};

pub const GeneratedRunResult = struct {
    runtime: GeneratedRuntime,
    returns: []const Value,

    pub fn deinit(self: *GeneratedRunResult) void {
        self.runtime.deinit();
        self.* = undefined;
    }
};

pub const GeneratedRuntime = struct {
    arena: std.heap.ArenaAllocator,
    // Generated modules are cached by compact index to keep the runtime layout
    // aligned with the static dispatch tables emitted by codegen.
    generated_module_loaded: []bool = &.{},
    generated_module_values: []Value = &.{},
    generated_module_globals: []?*anyopaque = &.{},

    pub fn init(allocator: std.mem.Allocator) GeneratedRuntime {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *GeneratedRuntime) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn alloc(self: *GeneratedRuntime) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn allocValues(self: *GeneratedRuntime, values: []const Value) ![]Value {
        return try self.alloc().dupe(Value, values);
    }

    pub fn singleReturn(self: *GeneratedRuntime, value: Value) ![]Value {
        const out = try self.alloc().alloc(Value, 1);
        out[0] = value;
        return out;
    }

    pub fn getGeneratedModuleByIndex(self: *const GeneratedRuntime, module_index: u16) ?Value {
        const index: usize = module_index;
        if (index >= self.generated_module_loaded.len or !self.generated_module_loaded[index]) return null;
        return self.generated_module_values[index];
    }

    pub fn getGeneratedModuleGlobalsByIndex(self: *const GeneratedRuntime, module_index: u16) ?*anyopaque {
        const index: usize = module_index;
        if (index >= self.generated_module_loaded.len or !self.generated_module_loaded[index]) return null;
        return self.generated_module_globals[index];
    }

    pub fn putGeneratedModuleByIndex(
        self: *GeneratedRuntime,
        module_index: u16,
        value: Value,
        globals: ?*anyopaque,
    ) !void {
        const needed_len: usize = @as(usize, module_index) + 1;
        if (needed_len > self.generated_module_loaded.len) try self.ensureGeneratedModuleSlots(needed_len);
        const index: usize = module_index;
        self.generated_module_loaded[index] = true;
        self.generated_module_values[index] = value;
        self.generated_module_globals[index] = globals;
    }

    fn ensureGeneratedModuleSlots(self: *GeneratedRuntime, needed_len: usize) !void {
        if (needed_len <= self.generated_module_loaded.len) return;

        const allocator = self.alloc();
        const loaded = try allocator.alloc(bool, needed_len);
        const values = try allocator.alloc(Value, needed_len);
        const globals = try allocator.alloc(?*anyopaque, needed_len);

        @memset(loaded, false);
        for (values) |*slot| slot.* = .nil;
        @memset(globals, null);

        @memcpy(loaded[0..self.generated_module_loaded.len], self.generated_module_loaded);
        @memcpy(values[0..self.generated_module_values.len], self.generated_module_values);
        @memcpy(globals[0..self.generated_module_globals.len], self.generated_module_globals);

        self.generated_module_loaded = loaded;
        self.generated_module_values = values;
        self.generated_module_globals = globals;
    }

    pub fn functionValue(
        self: *GeneratedRuntime,
        name: []const u8,
        capture: ?*anyopaque,
        globals: ?*anyopaque,
        invoke: GeneratedInvokeFn,
    ) !Value {
        const function = try self.alloc().create(Function);
        function.* = .{
            .name = name,
            .kind = .{ .generated = .{
                .capture = capture,
                .globals = globals,
                .invoke = invoke,
            } },
            .env = null,
        };
        return .{ .function = function };
    }

    pub fn generatedCallableValue(
        _: *GeneratedRuntime,
        id: u32,
        capture: ?*anyopaque,
        globals: ?*anyopaque,
    ) Value {
        return .{ .generated_callable = .{
            .id = id,
            .capture = capture,
            .globals = globals,
        } };
    }
};

pub const Stmt = union(enum) {
    local_assign: struct {
        names: []const []const u8,
        exprs: []const *Expr,
    },
    assign: struct {
        targets: []const LValue,
        exprs: []const *Expr,
    },
    function_def: struct {
        target: LValue,
        params: []const []const u8,
        body: []const *Stmt,
        is_vararg: bool = false,
        is_local: bool = false,
    },
    if_stmt: struct {
        branches: []const IfBranch,
        else_body: []const *Stmt,
    },
    do_block: []const *Stmt,
    while_stmt: struct {
        condition: *Expr,
        body: []const *Stmt,
    },
    repeat_stmt: struct {
        body: []const *Stmt,
        condition: *Expr,
    },
    numeric_for: struct {
        name: []const u8,
        start: *Expr,
        finish: *Expr,
        step: ?*Expr,
        body: []const *Stmt,
    },
    generic_for: struct {
        names: []const []const u8,
        iterator_exprs: []const *Expr,
        body: []const *Stmt,
    },
    return_stmt: struct {
        exprs: []const *Expr,
    },
    break_stmt,
    expr_stmt: *Expr,
};

pub const IfBranch = struct {
    condition: *Expr,
    body: []const *Stmt,
};

pub const Expr = union(enum) {
    nil_lit,
    bool_lit: bool,
    number_lit: f64,
    string_lit: []const u8,
    variable: []const u8,
    varargs,
    unary: struct {
        op: UnaryOp,
        expr: *Expr,
    },
    binary: struct {
        op: BinaryOp,
        lhs: *Expr,
        rhs: *Expr,
    },
    table_ctor: []const TableField,
    // Hoisted immutable template cloned on each evaluation.
    const_table: *const Table,
    field: struct {
        object: *Expr,
        name: []const u8,
    },
    index: struct {
        object: *Expr,
        key: *Expr,
    },
    call: struct {
        callee: *Expr,
        args: []const *Expr,
    },
    function_lit: struct {
        params: []const []const u8,
        body: []const *Stmt,
        is_vararg: bool,
    },
};

pub const TableField = union(enum) {
    array: *Expr,
    named: struct {
        name: []const u8,
        value: *Expr,
    },
    indexed: struct {
        key: *Expr,
        value: *Expr,
    },
};

pub const LValue = union(enum) {
    name: []const u8,
    field: struct {
        object: *Expr,
        name: []const u8,
    },
    index: struct {
        object: *Expr,
        key: *Expr,
    },
};

pub const UnaryOp = enum {
    negate,
    not_,
    length,
};

pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    concat,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    and_,
    or_,
};

const ParseError = CompileError || std.mem.Allocator.Error;
const EvalError = anyerror;
const OptimizeError = std.mem.Allocator.Error;

const TokenTag = enum {
    eof,
    identifier,
    number,
    string,
    kw_and,
    kw_break,
    kw_do,
    kw_else,
    kw_elseif,
    kw_end,
    kw_false,
    kw_for,
    kw_function,
    kw_if,
    kw_in,
    kw_local,
    kw_nil,
    kw_not,
    kw_or,
    kw_repeat,
    kw_return,
    kw_then,
    kw_true,
    kw_until,
    kw_while,
    plus,
    minus,
    star,
    slash,
    percent,
    caret,
    hash,
    eq,
    eqeq,
    ne,
    lt,
    le,
    gt,
    ge,
    dot,
    dotdot,
    ellipsis,
    comma,
    semi,
    colon,
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
};

const Token = struct {
    tag: TokenTag,
    lexeme: []const u8,
};

pub fn compile(allocator: std.mem.Allocator, source: []const u8) !Chunk {
    return compileWithDiagnostics(allocator, source, true);
}

fn compileQuiet(allocator: std.mem.Allocator, source: []const u8) !Chunk {
    return compileWithDiagnostics(allocator, source, false);
}

fn compileWithDiagnostics(allocator: std.mem.Allocator, source: []const u8, diagnostics: bool) !Chunk {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const owned_source = try a.dupe(u8, source);
    var parser = try Parser.init(a, owned_source, diagnostics);
    const body = parser.parseChunk() catch |err| {
        if (diagnostics) reportParseError(owned_source, &parser, err);
        return err;
    };
    try optimizeChunk(a, body);
    return .{
        .arena = arena,
        .source = owned_source,
        .body = body,
    };
}

pub fn run(allocator: std.mem.Allocator, chunk: *const Chunk) !RunResult {
    var vm = try Vm.init(allocator);
    const env = try vm.createEnv(null);
    try vm.installBuiltins(env);
    const exec = try vm.executeBlock(env, chunk.body);
    return .{
        .vm = vm,
        .returns = switch (exec) {
            .none => &.{},
            .returned => |returns| returns,
            .break_loop => return error.UnsupportedSyntax,
        },
    };
}

pub const ModuleArg = struct {
    name: ?[]const u8 = null,
    value: []const u8,
};

pub fn appendValueTextAlloc(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: Value) !void {
    try appendValueText(out, allocator, value);
}

pub fn runModuleFunctionAlloc(
    allocator: std.mem.Allocator,
    module_source: []const u8,
    function_name: []const u8,
    args: []const ModuleArg,
) ![]u8 {
    var chunk = try compile(allocator, module_source);
    defer chunk.deinit();

    return try runCompiledModuleFunctionAlloc(allocator, &chunk, function_name, args);
}

pub fn runCompiledModuleFunctionAlloc(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    function_name: []const u8,
    args: []const ModuleArg,
) ![]u8 {
    var vm = try Vm.init(allocator);
    defer vm.deinit();

    const env = try vm.createEnv(null);
    try vm.installBuiltins(env);
    const exec = try vm.executeBlock(env, chunk.body);
    const module_returns = switch (exec) {
        .returned => |returns| returns,
        .none => &.{},
        .break_loop => return error.UnsupportedSyntax,
    };
    if (module_returns.len == 0 or module_returns[0] != .table) return allocator.dupe(u8, "");

    const function_value = module_returns[0].table.getString(function_name);
    if (function_value != .function) return allocator.dupe(u8, "");

    const frame_table = try buildModuleFrameTable(&vm, args);
    const results = try vm.callFunction(function_value.function, &.{.{ .table = frame_table }});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    if (results.len != 0) try appendValueText(&out, allocator, results[0]);
    return out.toOwnedSlice(allocator);
}

pub fn generatedFrameGetParent(_: ?*anyopaque, _: ?*anyopaque, runtime: *GeneratedRuntime, args: []const Value) anyerror![]Value {
    return runtime.singleReturn(if (args.len == 0) .nil else args[0]);
}

pub fn generatedFrameExpandTemplate(_: ?*anyopaque, _: ?*anyopaque, runtime: *GeneratedRuntime, _: []const Value) anyerror![]Value {
    return runtime.singleReturn(.{ .string = "" });
}

pub fn buildGeneratedModuleFrameValueAlloc(runtime: *GeneratedRuntime, args: []const ModuleArg) !Value {
    const frame = try Table.init(runtime.alloc());
    const args_table = try Table.init(runtime.alloc());

    for (args, 0..) |arg, idx| {
        try args_table.putNumber(@floatFromInt(idx + 1), .{ .string = arg.value });
        if (arg.name) |name| {
            try args_table.putStringBorrowed(name, .{ .string = arg.value });
        }
    }

    const get_parent_value = runtime.generatedCallableValue(generated_callable_id_frame_get_parent, null, null);
    const expand_template_value = runtime.generatedCallableValue(generated_callable_id_frame_expand_template, null, null);
    try frame.putStringBorrowed("args", .{ .table = args_table });
    try frame.putStringBorrowed("getParent", get_parent_value);
    try frame.putStringBorrowed("expandTemplate", expand_template_value);
    return .{ .table = frame };
}

pub fn generatedCall(runtime: *GeneratedRuntime, callee: Value, args: []const Value) ![]Value {
    return switch (callee) {
        .generated_callable => if (try generatedDispatchKnownRuntimeFirst(runtime, callee, args)) |first|
            runtime.singleReturn(first)
        else
            error.InvalidCall,
        .function => |function| switch (function.kind) {
            .generated => |generated| try generated.invoke(generated.capture, generated.globals, runtime, args),
            else => error.InvalidCall,
        },
        else => error.InvalidCall,
    };
}

pub fn generatedCallFirst(runtime: *GeneratedRuntime, callee: Value, args: []const Value) !Value {
    const results = try generatedCall(runtime, callee, args);
    return if (results.len == 0) .nil else results[0];
}

pub fn generatedResultsFirst(results: []const Value) Value {
    return if (results.len == 0) .nil else results[0];
}

pub fn generatedDispatchKnownRuntimeFirst(
    runtime: *GeneratedRuntime,
    callee: Value,
    args: []const Value,
) !?Value {
    return switch (callee) {
        .generated_callable => |generated| switch (generated.id) {
            generated_callable_id_builtin_print,
            generated_callable_id_builtin_tostring,
            generated_callable_id_builtin_tonumber,
            generated_callable_id_builtin_type,
            generated_callable_id_builtin_unpack,
            generated_callable_id_builtin_pairs,
            generated_callable_id_builtin_ipairs,
            generated_callable_id_builtin_string_len,
            generated_callable_id_builtin_string_lower,
            generated_callable_id_builtin_string_upper,
            generated_callable_id_builtin_string_sub,
            generated_callable_id_builtin_string_gsub,
            generated_callable_id_builtin_math_floor,
            generated_callable_id_builtin_math_ceil,
            generated_callable_id_builtin_math_abs,
            generated_callable_id_builtin_table_insert,
            generated_callable_id_builtin_table_remove,
            generated_callable_id_builtin_table_sort,
            generated_callable_id_builtin_table_unpack,
            generated_callable_id_builtin_table_concat,
            => generatedResultsFirst(try generatedBuiltinInvokeById(generated.id, runtime, args)),
            generated_callable_id_frame_get_parent => generatedResultsFirst(try generatedFrameGetParent(
                generated.capture,
                generated.globals,
                runtime,
                args,
            )),
            generated_callable_id_frame_expand_template => generatedResultsFirst(try generatedFrameExpandTemplate(
                generated.capture,
                generated.globals,
                runtime,
                args,
            )),
            generated_callable_id_frame_preprocess => generatedResultsFirst(try generatedFramePreprocess(
                generated.capture,
                generated.globals,
                runtime,
                args,
            )),
            generated_callable_id_mw_get_current_frame => generatedResultsFirst(try generatedMwGetCurrentFrame(
                generated.capture,
                generated.globals,
                runtime,
                args,
            )),
            generated_callable_id_mw_get_content_language => generatedResultsFirst(try generatedMwGetContentLanguage(
                generated.capture,
                generated.globals,
                runtime,
                args,
            )),
            generated_callable_id_mw_dump_object => generatedResultsFirst(try generatedMwDumpObject(
                generated.capture,
                generated.globals,
                runtime,
                args,
            )),
            generated_callable_id_content_language_ucfirst => generatedResultsFirst(try generatedContentLanguageUcfirst(
                generated.capture,
                generated.globals,
                runtime,
                args,
            )),
            else => null,
        },
        .function => |function| switch (function.kind) {
            .generated => |generated| {
                if (generated.invoke == generatedBuiltinInvoke) {
                    return generatedResultsFirst(try generatedBuiltinInvoke(
                        generated.capture,
                        generated.globals,
                        runtime,
                        args,
                    ));
                }
                if (generated.invoke == generatedFrameGetParent) {
                    return generatedResultsFirst(try generatedFrameGetParent(
                        generated.capture,
                        generated.globals,
                        runtime,
                        args,
                    ));
                }
                if (generated.invoke == generatedFrameExpandTemplate) {
                    return generatedResultsFirst(try generatedFrameExpandTemplate(
                        generated.capture,
                        generated.globals,
                        runtime,
                        args,
                    ));
                }
                if (generated.invoke == generatedFramePreprocess) {
                    return generatedResultsFirst(try generatedFramePreprocess(
                        generated.capture,
                        generated.globals,
                        runtime,
                        args,
                    ));
                }
                if (generated.invoke == generatedMwGetCurrentFrame) {
                    return generatedResultsFirst(try generatedMwGetCurrentFrame(
                        generated.capture,
                        generated.globals,
                        runtime,
                        args,
                    ));
                }
                if (generated.invoke == generatedMwGetContentLanguage) {
                    return generatedResultsFirst(try generatedMwGetContentLanguage(
                        generated.capture,
                        generated.globals,
                        runtime,
                        args,
                    ));
                }
                if (generated.invoke == generatedMwDumpObject) {
                    return generatedResultsFirst(try generatedMwDumpObject(
                        generated.capture,
                        generated.globals,
                        runtime,
                        args,
                    ));
                }
                if (generated.invoke == generatedContentLanguageUcfirst) {
                    return generatedResultsFirst(try generatedContentLanguageUcfirst(
                        generated.capture,
                        generated.globals,
                        runtime,
                        args,
                    ));
                }
                return null;
            },
            else => null,
        },
        else => null,
    };
}

pub fn cloneConstTableSeedAlloc(allocator: std.mem.Allocator, seed: *const ConstTableSeed) !*Table {
    return try loadStaticConstTableAlloc(allocator, seed);
}

pub fn executeUnaryValueAlloc(op: UnaryOp, value: Value) !Value {
    return try executeUnaryValue(op, value);
}

pub fn executeBinaryValueAlloc(allocator: std.mem.Allocator, op: BinaryOp, lhs: Value, rhs: Value) !Value {
    return try executeBinaryValue(allocator, op, lhs, rhs);
}

pub fn valueToNumberAlloc(value: Value) !f64 {
    return try valueToNumber(value);
}

pub fn valueToStringValueAlloc(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    return try valueToStringAlloc(allocator, value);
}

pub fn generatedPairsIterator(value: Value) !Iterator {
    if (value != .table) return error.TypeError;
    return .{ .kind = .pairs, .table = value.table };
}

pub fn generatedIpairsIterator(value: Value) !Iterator {
    if (value != .table) return error.TypeError;
    return .{ .kind = .ipairs, .table = value.table };
}

pub fn generatedIteratorNext(iterator: *Iterator) !?[2]Value {
    return try iteratorNextAlloc(iterator);
}

pub fn generatedPrint(runtime: *GeneratedRuntime, args: []const Value) !Value {
    var out: std.ArrayList(u8) = .empty;
    for (args, 0..) |arg, idx| {
        if (idx != 0) try out.appendSlice(runtime.alloc(), "\t");
        try appendValueText(&out, runtime.alloc(), arg);
    }
    try out.appendSlice(runtime.alloc(), "\n");
    try std.Io.File.stdout().writeStreamingAll(std.Options.debug_io, out.items);
    return .nil;
}

pub fn generatedTostring(runtime: *GeneratedRuntime, value: Value) !Value {
    return .{ .string = try valueToStringAlloc(runtime.alloc(), value) };
}

pub fn generatedTonumber(value: Value) !Value {
    return .{ .number = try valueToNumber(value) };
}

pub fn generatedType(value: Value) Value {
    return .{ .string = switch (value) {
        .nil => "nil",
        .boolean => "boolean",
        .number => "number",
        .string => "string",
        .table => "table",
        .generated_callable => "function",
        .function => "function",
        .iterator => "userdata",
    } };
}

pub fn generatedTouchValues(values: []const Value) void {
    _ = values;
}

pub fn generatedStringLen(value: Value) !Value {
    if (value != .string) return error.TypeError;
    return .{ .number = @floatFromInt(value.string.len) };
}

pub fn generatedStringLower(runtime: *GeneratedRuntime, value: Value) !Value {
    if (value != .string) return error.TypeError;
    const out = try runtime.alloc().dupe(u8, value.string);
    for (out) |*byte| byte.* = std.ascii.toLower(byte.*);
    return .{ .string = out };
}

pub fn generatedStringUpper(runtime: *GeneratedRuntime, value: Value) !Value {
    if (value != .string) return error.TypeError;
    const out = try runtime.alloc().dupe(u8, value.string);
    for (out) |*byte| byte.* = std.ascii.toUpper(byte.*);
    return .{ .string = out };
}

pub fn generatedStringSub(runtime: *GeneratedRuntime, str_value: Value, start_value: Value, finish_value: ?Value) !Value {
    if (str_value != .string) return error.TypeError;
    const str = str_value.string;
    const start_num = try valueToNumber(start_value);
    const finish_num = if (finish_value) |value| try valueToNumber(value) else @as(f64, @floatFromInt(str.len));
    const start = @max(@as(usize, 1), @as(usize, @intFromFloat(start_num)));
    const finish = @min(str.len, @as(usize, @intFromFloat(finish_num)));
    if (start > finish or start > str.len) return .{ .string = "" };
    return .{ .string = try runtime.alloc().dupe(u8, str[start - 1 .. finish]) };
}

fn tryDecodeLuaLiteralPatternAlloc(allocator: std.mem.Allocator, pattern: []const u8) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < pattern.len) {
        const byte = pattern[index];
        if (byte == '%') {
            if (index + 1 >= pattern.len) return null;
            const escaped = pattern[index + 1];
            switch (escaped) {
                '%', '^', '$', '(', ')', '.', '[', ']', '*', '+', '-', '?' => try out.append(allocator, escaped),
                else => return null,
            }
            index += 2;
            continue;
        }
        switch (byte) {
            '^', '$', '(', ')', '.', '[', ']', '*', '+', '-', '?' => return null,
            else => try out.append(allocator, byte),
        }
        index += 1;
    }

    return out.toOwnedSlice(allocator);
}

pub fn generatedStringGsub(
    runtime: *GeneratedRuntime,
    str_value: Value,
    pattern_value: Value,
    replacement_value: Value,
) !Value {
    if (str_value != .string or pattern_value != .string) return error.TypeError;
    const pattern = tryDecodeLuaLiteralPatternAlloc(runtime.alloc(), pattern_value.string) orelse {
        return .{ .string = try runtime.alloc().dupe(u8, str_value.string) };
    };
    defer runtime.alloc().free(pattern);

    const replacement_text = try valueToStringAlloc(runtime.alloc(), replacement_value);
    const input = str_value.string;
    if (pattern.len == 0) return .{ .string = try runtime.alloc().dupe(u8, input) };

    var out: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, input, cursor, pattern)) |match_index| {
        try out.appendSlice(runtime.alloc(), input[cursor..match_index]);
        try out.appendSlice(runtime.alloc(), replacement_text);
        cursor = match_index + pattern.len;
    }
    try out.appendSlice(runtime.alloc(), input[cursor..]);
    return .{ .string = try out.toOwnedSlice(runtime.alloc()) };
}

pub fn generatedMathFloor(value: Value) !Value {
    return .{ .number = @floor(try valueToNumber(value)) };
}

pub fn generatedMathCeil(value: Value) !Value {
    return .{ .number = @ceil(try valueToNumber(value)) };
}

pub fn generatedMathAbs(value: Value) !Value {
    return .{ .number = @abs(try valueToNumber(value)) };
}

pub fn generatedTableInsert(table_value: Value, value: Value) !Value {
    if (table_value != .table) return error.TypeError;
    try table_value.table.array.append(table_value.table.allocator, value);
    return .nil;
}

pub fn generatedTableRemove(table_value: Value, index_value: ?Value) !Value {
    if (table_value != .table) return error.TypeError;
    if (table_value.table.array.items.len == 0) return .nil;
    const raw_index = if (index_value) |value|
        @as(usize, @intFromFloat(try valueToNumber(value)))
    else
        table_value.table.array.items.len;
    if (raw_index == 0 or raw_index > table_value.table.array.items.len) return .nil;
    const removed = table_value.table.array.items[raw_index - 1];
    _ = table_value.table.array.orderedRemove(raw_index - 1);
    return removed;
}

fn generatedSortValueLessThan(_: void, lhs: Value, rhs: Value) bool {
    return switch (lhs) {
        .string => |text| switch (rhs) {
            .string => |rhs_text| std.mem.lessThan(u8, text, rhs_text),
            else => false,
        },
        .number => |number| switch (rhs) {
            .number => |rhs_number| number < rhs_number,
            else => false,
        },
        else => false,
    };
}

pub fn generatedTableSort(table_value: Value) !Value {
    if (table_value != .table) return error.TypeError;
    std.mem.sort(Value, table_value.table.array.items, {}, generatedSortValueLessThan);
    return .nil;
}

pub fn generatedTableUnpack(runtime: *GeneratedRuntime, table_value: Value) ![]Value {
    if (table_value != .table) return error.TypeError;
    return runtime.allocValues(table_value.table.array.items);
}

pub fn generatedFramePreprocess(_: ?*anyopaque, _: ?*anyopaque, runtime: *GeneratedRuntime, args: []const Value) anyerror![]Value {
    return runtime.singleReturn(if (args.len <= 1) .{ .string = "" } else args[1]);
}

fn generatedContentLanguageTableValue(runtime: *GeneratedRuntime, globals: ?*anyopaque) !Value {
    const table = try Table.init(runtime.alloc());
    const ucfirst_value = runtime.generatedCallableValue(generated_callable_id_content_language_ucfirst, null, globals);
    try table.putStringBorrowed("ucfirst", ucfirst_value);
    return .{ .table = table };
}

pub fn generatedMwGetContentLanguage(_: ?*anyopaque, globals: ?*anyopaque, runtime: *GeneratedRuntime, _: []const Value) anyerror![]Value {
    return runtime.singleReturn(try generatedContentLanguageTableValue(runtime, globals));
}

pub fn generatedMwGetCurrentFrame(_: ?*anyopaque, _: ?*anyopaque, runtime: *GeneratedRuntime, _: []const Value) anyerror![]Value {
    return runtime.singleReturn(try buildGeneratedModuleFrameValueAlloc(runtime, &.{}));
}

pub fn generatedMwDumpObject(_: ?*anyopaque, _: ?*anyopaque, runtime: *GeneratedRuntime, args: []const Value) anyerror![]Value {
    var out: std.ArrayList(u8) = .empty;
    if (args.len != 0) try appendValueText(&out, runtime.alloc(), args[0]);
    return runtime.singleReturn(.{ .string = try out.toOwnedSlice(runtime.alloc()) });
}

pub fn generatedContentLanguageUcfirst(_: ?*anyopaque, _: ?*anyopaque, runtime: *GeneratedRuntime, args: []const Value) anyerror![]Value {
    const text_value = if (args.len <= 1) Value{ .string = "" } else args[1];
    if (text_value != .string) return error.TypeError;
    if (text_value.string.len == 0) return runtime.singleReturn(.{ .string = "" });
    const out = try runtime.alloc().dupe(u8, text_value.string);
    out[0] = std.ascii.toUpper(out[0]);
    return runtime.singleReturn(.{ .string = out });
}

pub fn generatedTableConcat(runtime: *GeneratedRuntime, table_value: Value, sep_value: ?Value) !Value {
    if (table_value != .table) return error.TypeError;
    const sep = if (sep_value) |value|
        switch (value) {
            .string => |text| text,
            else => "",
        }
    else
        "";
    var out: std.ArrayList(u8) = .empty;
    for (table_value.table.array.items, 0..) |item, idx| {
        if (idx != 0) try out.appendSlice(runtime.alloc(), sep);
        try appendValueText(&out, runtime.alloc(), item);
    }
    return .{ .string = try out.toOwnedSlice(runtime.alloc()) };
}

const GeneratedBuiltinKind = enum {
    print,
    tostring,
    tonumber,
    type_,
    unpack,
    pairs,
    ipairs,
    string_len,
    string_lower,
    string_upper,
    string_sub,
    string_gsub,
    math_floor,
    math_ceil,
    math_abs,
    table_insert,
    table_remove,
    table_sort,
    table_unpack,
    table_concat,
};

pub const generated_callable_id_builtin_print: u32 = 0xFF00_0000;
pub const generated_callable_id_local_base: u32 = 0x0100_0000;
pub const generated_callable_id_builtin_tostring: u32 = generated_callable_id_builtin_print + 1;
pub const generated_callable_id_builtin_tonumber: u32 = generated_callable_id_builtin_print + 2;
pub const generated_callable_id_builtin_type: u32 = generated_callable_id_builtin_print + 3;
pub const generated_callable_id_builtin_unpack: u32 = generated_callable_id_builtin_print + 4;
pub const generated_callable_id_builtin_pairs: u32 = generated_callable_id_builtin_print + 5;
pub const generated_callable_id_builtin_ipairs: u32 = generated_callable_id_builtin_print + 6;
pub const generated_callable_id_builtin_string_len: u32 = generated_callable_id_builtin_print + 7;
pub const generated_callable_id_builtin_string_lower: u32 = generated_callable_id_builtin_print + 8;
pub const generated_callable_id_builtin_string_upper: u32 = generated_callable_id_builtin_print + 9;
pub const generated_callable_id_builtin_string_sub: u32 = generated_callable_id_builtin_print + 10;
pub const generated_callable_id_builtin_string_gsub: u32 = generated_callable_id_builtin_print + 11;
pub const generated_callable_id_builtin_math_floor: u32 = generated_callable_id_builtin_print + 12;
pub const generated_callable_id_builtin_math_ceil: u32 = generated_callable_id_builtin_print + 13;
pub const generated_callable_id_builtin_math_abs: u32 = generated_callable_id_builtin_print + 14;
pub const generated_callable_id_builtin_table_insert: u32 = generated_callable_id_builtin_print + 15;
pub const generated_callable_id_builtin_table_remove: u32 = generated_callable_id_builtin_print + 16;
pub const generated_callable_id_builtin_table_sort: u32 = generated_callable_id_builtin_print + 17;
pub const generated_callable_id_builtin_table_unpack: u32 = generated_callable_id_builtin_print + 18;
pub const generated_callable_id_builtin_table_concat: u32 = generated_callable_id_builtin_print + 19;
pub const generated_callable_id_frame_get_parent: u32 = generated_callable_id_builtin_print + 20;
pub const generated_callable_id_frame_expand_template: u32 = generated_callable_id_builtin_print + 21;
pub const generated_callable_id_frame_preprocess: u32 = generated_callable_id_builtin_print + 22;
pub const generated_callable_id_module_require: u32 = generated_callable_id_builtin_print + 23;
pub const generated_callable_id_module_load_data: u32 = generated_callable_id_builtin_print + 24;
pub const generated_callable_id_mw_get_current_frame: u32 = generated_callable_id_builtin_print + 25;
pub const generated_callable_id_mw_get_content_language: u32 = generated_callable_id_builtin_print + 26;
pub const generated_callable_id_mw_dump_object: u32 = generated_callable_id_builtin_print + 27;
pub const generated_callable_id_content_language_ucfirst: u32 = generated_callable_id_builtin_print + 28;

pub fn generatedLocalCallableId(function_id: u32) u32 {
    return generated_callable_id_local_base + function_id;
}

fn stateGeneratedCallableId(state: *const DirectModuleState, function_id: u32) u32 {
    return state.options.callable_id_base + function_id;
}

const generated_builtin_print = GeneratedBuiltinKind.print;
const generated_builtin_tostring = GeneratedBuiltinKind.tostring;
const generated_builtin_tonumber = GeneratedBuiltinKind.tonumber;
const generated_builtin_type = GeneratedBuiltinKind.type_;
const generated_builtin_unpack = GeneratedBuiltinKind.unpack;
const generated_builtin_pairs = GeneratedBuiltinKind.pairs;
const generated_builtin_ipairs = GeneratedBuiltinKind.ipairs;
const generated_builtin_string_len = GeneratedBuiltinKind.string_len;
const generated_builtin_string_lower = GeneratedBuiltinKind.string_lower;
const generated_builtin_string_upper = GeneratedBuiltinKind.string_upper;
const generated_builtin_string_sub = GeneratedBuiltinKind.string_sub;
const generated_builtin_string_gsub = GeneratedBuiltinKind.string_gsub;
const generated_builtin_math_floor = GeneratedBuiltinKind.math_floor;
const generated_builtin_math_ceil = GeneratedBuiltinKind.math_ceil;
const generated_builtin_math_abs = GeneratedBuiltinKind.math_abs;
const generated_builtin_table_insert = GeneratedBuiltinKind.table_insert;
const generated_builtin_table_remove = GeneratedBuiltinKind.table_remove;
const generated_builtin_table_sort = GeneratedBuiltinKind.table_sort;
const generated_builtin_table_unpack = GeneratedBuiltinKind.table_unpack;
const generated_builtin_table_concat = GeneratedBuiltinKind.table_concat;

pub fn generatedBuiltinPrintValue(runtime: *GeneratedRuntime, globals: ?*anyopaque) !Value {
    return try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_print);
}

pub fn generatedBuiltinTostringValue(runtime: *GeneratedRuntime, globals: ?*anyopaque) !Value {
    return try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_tostring);
}

pub fn generatedBuiltinTonumberValue(runtime: *GeneratedRuntime, globals: ?*anyopaque) !Value {
    return try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_tonumber);
}

pub fn generatedBuiltinTypeValue(runtime: *GeneratedRuntime, globals: ?*anyopaque) !Value {
    return try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_type);
}

pub fn generatedBuiltinUnpackValue(runtime: *GeneratedRuntime, globals: ?*anyopaque) !Value {
    return try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_unpack);
}

pub fn generatedBuiltinPairsValue(runtime: *GeneratedRuntime, globals: ?*anyopaque) !Value {
    return try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_pairs);
}

pub fn generatedBuiltinIpairsValue(runtime: *GeneratedRuntime, globals: ?*anyopaque) !Value {
    return try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_ipairs);
}

pub fn generatedBuiltinStringTableValue(runtime: *GeneratedRuntime, globals: ?*anyopaque) !Value {
    const table = try Table.init(runtime.alloc());
    const len_value = try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_string_len);
    const lower_value = try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_string_lower);
    const upper_value = try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_string_upper);
    const sub_value = try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_string_sub);
    const gsub_value = try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_string_gsub);
    try table.putString("len", len_value);
    try table.putString("lower", lower_value);
    try table.putString("upper", upper_value);
    try table.putString("sub", sub_value);
    try table.putString("gsub", gsub_value);
    return .{ .table = table };
}

pub fn generatedBuiltinMathTableValue(runtime: *GeneratedRuntime, globals: ?*anyopaque) !Value {
    const table = try Table.init(runtime.alloc());
    const floor_value = try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_math_floor);
    const ceil_value = try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_math_ceil);
    const abs_value = try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_math_abs);
    try table.putString("floor", floor_value);
    try table.putString("ceil", ceil_value);
    try table.putString("abs", abs_value);
    return .{ .table = table };
}

pub fn generatedBuiltinTableTableValue(runtime: *GeneratedRuntime, globals: ?*anyopaque) !Value {
    const table = try Table.init(runtime.alloc());
    const insert_value = try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_table_insert);
    const remove_value = try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_table_remove);
    const sort_value = try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_table_sort);
    const unpack_value = try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_table_unpack);
    const concat_value = try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_table_concat);
    try table.putString("insert", insert_value);
    try table.putString("remove", remove_value);
    try table.putString("sort", sort_value);
    try table.putString("unpack", unpack_value);
    try table.putString("concat", concat_value);
    return .{ .table = table };
}

fn generatedBuiltinFunctionValue(
    runtime: *GeneratedRuntime,
    globals: ?*anyopaque,
    kind: *const GeneratedBuiltinKind,
) !Value {
    return runtime.generatedCallableValue(generatedBuiltinId(kind.*), @constCast(kind), globals);
}

fn generatedBuiltinId(kind: GeneratedBuiltinKind) u32 {
    return switch (kind) {
        .print => generated_callable_id_builtin_print,
        .tostring => generated_callable_id_builtin_tostring,
        .tonumber => generated_callable_id_builtin_tonumber,
        .type_ => generated_callable_id_builtin_type,
        .unpack => generated_callable_id_builtin_unpack,
        .pairs => generated_callable_id_builtin_pairs,
        .ipairs => generated_callable_id_builtin_ipairs,
        .string_len => generated_callable_id_builtin_string_len,
        .string_lower => generated_callable_id_builtin_string_lower,
        .string_upper => generated_callable_id_builtin_string_upper,
        .string_sub => generated_callable_id_builtin_string_sub,
        .string_gsub => generated_callable_id_builtin_string_gsub,
        .math_floor => generated_callable_id_builtin_math_floor,
        .math_ceil => generated_callable_id_builtin_math_ceil,
        .math_abs => generated_callable_id_builtin_math_abs,
        .table_insert => generated_callable_id_builtin_table_insert,
        .table_remove => generated_callable_id_builtin_table_remove,
        .table_sort => generated_callable_id_builtin_table_sort,
        .table_unpack => generated_callable_id_builtin_table_unpack,
        .table_concat => generated_callable_id_builtin_table_concat,
    };
}

fn generatedBuiltinInvokeById(
    id: u32,
    runtime: *GeneratedRuntime,
    args: []const Value,
) anyerror![]Value {
    return switch (id) {
        generated_callable_id_builtin_print => blk: {
            _ = try generatedPrint(runtime, args);
            break :blk &.{};
        },
        generated_callable_id_builtin_tostring => try runtime.singleReturn(try generatedTostring(runtime, if (args.len == 0) .nil else args[0])),
        generated_callable_id_builtin_tonumber => try runtime.singleReturn(if (args.len == 0) .nil else try generatedTonumber(args[0])),
        generated_callable_id_builtin_type => try runtime.singleReturn(generatedType(if (args.len == 0) .nil else args[0])),
        generated_callable_id_builtin_unpack => try generatedTableUnpack(runtime, if (args.len == 0) .nil else args[0]),
        generated_callable_id_builtin_pairs => try runtime.singleReturn(.{ .iterator = try generatedPairsIterator(if (args.len == 0) .nil else args[0]) }),
        generated_callable_id_builtin_ipairs => try runtime.singleReturn(.{ .iterator = try generatedIpairsIterator(if (args.len == 0) .nil else args[0]) }),
        generated_callable_id_builtin_string_len => try runtime.singleReturn(try generatedStringLen(if (args.len == 0) .nil else args[0])),
        generated_callable_id_builtin_string_lower => try runtime.singleReturn(try generatedStringLower(runtime, if (args.len == 0) .nil else args[0])),
        generated_callable_id_builtin_string_upper => try runtime.singleReturn(try generatedStringUpper(runtime, if (args.len == 0) .nil else args[0])),
        generated_callable_id_builtin_string_sub => try runtime.singleReturn(try generatedStringSub(
            runtime,
            if (args.len == 0) .nil else args[0],
            if (args.len <= 1) .nil else args[1],
            if (args.len <= 2) null else args[2],
        )),
        generated_callable_id_builtin_string_gsub => try runtime.singleReturn(try generatedStringGsub(
            runtime,
            if (args.len == 0) .nil else args[0],
            if (args.len <= 1) .nil else args[1],
            if (args.len <= 2) .nil else args[2],
        )),
        generated_callable_id_builtin_math_floor => try runtime.singleReturn(try generatedMathFloor(if (args.len == 0) .nil else args[0])),
        generated_callable_id_builtin_math_ceil => try runtime.singleReturn(try generatedMathCeil(if (args.len == 0) .nil else args[0])),
        generated_callable_id_builtin_math_abs => try runtime.singleReturn(try generatedMathAbs(if (args.len == 0) .nil else args[0])),
        generated_callable_id_builtin_table_insert => blk: {
            _ = try generatedTableInsert(if (args.len == 0) .nil else args[0], if (args.len <= 1) .nil else args[1]);
            break :blk &.{};
        },
        generated_callable_id_builtin_table_remove => try runtime.singleReturn(try generatedTableRemove(
            if (args.len == 0) .nil else args[0],
            if (args.len <= 1) null else args[1],
        )),
        generated_callable_id_builtin_table_sort => blk: {
            _ = try generatedTableSort(if (args.len == 0) .nil else args[0]);
            break :blk &.{};
        },
        generated_callable_id_builtin_table_unpack => try generatedTableUnpack(runtime, if (args.len == 0) .nil else args[0]),
        generated_callable_id_builtin_table_concat => try runtime.singleReturn(try generatedTableConcat(
            runtime,
            if (args.len == 0) .nil else args[0],
            if (args.len <= 1) null else args[1],
        )),
        generated_callable_id_frame_get_parent => try generatedFrameGetParent(null, null, runtime, args),
        generated_callable_id_frame_expand_template => try generatedFrameExpandTemplate(null, null, runtime, args),
        generated_callable_id_frame_preprocess => try generatedFramePreprocess(null, null, runtime, args),
        generated_callable_id_mw_get_current_frame => try generatedMwGetCurrentFrame(null, null, runtime, args),
        generated_callable_id_mw_get_content_language => try generatedMwGetContentLanguage(null, null, runtime, args),
        generated_callable_id_mw_dump_object => try generatedMwDumpObject(null, null, runtime, args),
        generated_callable_id_content_language_ucfirst => try generatedContentLanguageUcfirst(null, null, runtime, args),
        else => error.InvalidCall,
    };
}

fn generatedBuiltinInvoke(
    capture: ?*anyopaque,
    _: ?*anyopaque,
    runtime: *GeneratedRuntime,
    args: []const Value,
) anyerror![]Value {
    const kind: *const GeneratedBuiltinKind = @ptrCast(@alignCast(capture.?));
    return switch (kind.*) {
        .print => blk: {
            _ = try generatedPrint(runtime, args);
            break :blk &.{};
        },
        .tostring => try runtime.singleReturn(try generatedTostring(runtime, if (args.len == 0) .nil else args[0])),
        .tonumber => try runtime.singleReturn(if (args.len == 0) .nil else try generatedTonumber(args[0])),
        .type_ => try runtime.singleReturn(generatedType(if (args.len == 0) .nil else args[0])),
        .unpack => try generatedTableUnpack(runtime, if (args.len == 0) .nil else args[0]),
        .pairs => try runtime.singleReturn(.{ .iterator = try generatedPairsIterator(if (args.len == 0) .nil else args[0]) }),
        .ipairs => try runtime.singleReturn(.{ .iterator = try generatedIpairsIterator(if (args.len == 0) .nil else args[0]) }),
        .string_len => try runtime.singleReturn(try generatedStringLen(if (args.len == 0) .nil else args[0])),
        .string_lower => try runtime.singleReturn(try generatedStringLower(runtime, if (args.len == 0) .nil else args[0])),
        .string_upper => try runtime.singleReturn(try generatedStringUpper(runtime, if (args.len == 0) .nil else args[0])),
        .string_sub => try runtime.singleReturn(try generatedStringSub(
            runtime,
            if (args.len == 0) .nil else args[0],
            if (args.len <= 1) .nil else args[1],
            if (args.len <= 2) null else args[2],
        )),
        .string_gsub => try runtime.singleReturn(try generatedStringGsub(
            runtime,
            if (args.len == 0) .nil else args[0],
            if (args.len <= 1) .nil else args[1],
            if (args.len <= 2) .nil else args[2],
        )),
        .math_floor => try runtime.singleReturn(try generatedMathFloor(if (args.len == 0) .nil else args[0])),
        .math_ceil => try runtime.singleReturn(try generatedMathCeil(if (args.len == 0) .nil else args[0])),
        .math_abs => try runtime.singleReturn(try generatedMathAbs(if (args.len == 0) .nil else args[0])),
        .table_insert => blk: {
            _ = try generatedTableInsert(if (args.len == 0) .nil else args[0], if (args.len <= 1) .nil else args[1]);
            break :blk &.{};
        },
        .table_remove => try runtime.singleReturn(try generatedTableRemove(
            if (args.len == 0) .nil else args[0],
            if (args.len <= 1) null else args[1],
        )),
        .table_sort => blk: {
            _ = try generatedTableSort(if (args.len == 0) .nil else args[0]);
            break :blk &.{};
        },
        .table_unpack => try generatedTableUnpack(runtime, if (args.len == 0) .nil else args[0]),
        .table_concat => try runtime.singleReturn(try generatedTableConcat(
            runtime,
            if (args.len == 0) .nil else args[0],
            if (args.len <= 1) null else args[1],
        )),
    };
}

pub const EmitZigModuleOptions = struct {
    enable_direct_module_dispatch: bool = false,
    // Canonical module names in the shared generated-runtime dispatch order.
    // When present, emitted require/loadData calls lower to numeric indices
    // instead of string-name dispatch helpers.
    direct_module_dispatch_names: []const []const u8 = &.{},
    // Export tables for the shared generated-runtime module index space. When
    // present, known module export calls lower to numeric export ids instead
    // of embedding export-name strings in the generated Zig.
    direct_module_export_tables: []const DirectModuleExportTable = &.{},
    call_dispatch_helper_name: []const u8 = "generatedDispatchFirst",
    emit_local_dispatch_helper: bool = true,
    emit_run_entry_points: bool = true,
    callable_id_base: u32 = 0,
};

pub const GeneratedModuleExportInfo = struct {
    export_id: u16,
    name: []const u8,
    callable_id: u32,
    fn_id: u32,
};

pub const DirectModuleExportTable = struct {
    exports: []const GeneratedModuleExportInfo = &.{},
};

pub const EmittedZigModule = struct {
    source: []u8,
    exports: []const GeneratedModuleExportInfo,
    top_id: u32,
    function_count: u32,

    pub fn deinit(self: *EmittedZigModule, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        for (self.exports) |export_info| allocator.free(export_info.name);
        allocator.free(self.exports);
        self.* = undefined;
    }
};

pub fn emitZigModuleAlloc(allocator: std.mem.Allocator, chunk: *const Chunk) ![]u8 {
    return try emitZigModuleWithOptionsAlloc(allocator, chunk, .{});
}

pub fn emitZigModuleWithOptionsAlloc(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    options: EmitZigModuleOptions,
) ![]u8 {
    const emitted = try emitZigModuleResultWithOptionsAlloc(allocator, chunk, options);
    defer {
        for (emitted.exports) |export_info| allocator.free(export_info.name);
        allocator.free(emitted.exports);
    }
    return emitted.source;
}

pub fn emitZigModuleResultAlloc(allocator: std.mem.Allocator, chunk: *const Chunk) !EmittedZigModule {
    return try emitZigModuleResultWithOptionsAlloc(allocator, chunk, .{});
}

pub fn emitBytecodeModuleAlloc(
    allocator: std.mem.Allocator,
    module_name: []const u8,
    chunk: *const Chunk,
) ![]u8 {
    const emitted = try emitBytecodeModuleResultAlloc(allocator, module_name, chunk);
    defer {
        for (emitted.exports) |export_info| allocator.free(export_info.name);
        allocator.free(emitted.exports);
    }
    return emitted.source;
}

const emitBytecodeModuleSourceAlloc = emitBytecodeModuleSourceAllocImpl;

pub fn emitBytecodeModuleResultAlloc(
    allocator: std.mem.Allocator,
    module_name: []const u8,
    chunk: *const Chunk,
) !EmittedZigModule {
    var exported = try emitZigModuleResultWithOptionsAlloc(allocator, chunk, .{
        .emit_run_entry_points = false,
    });
    errdefer exported.deinit(allocator);

    const source = try emitBytecodeModuleSourceAlloc(allocator, module_name, chunk, exported.exports);
    allocator.free(exported.source);
    exported.source = source;
    exported.top_id = 0;
    exported.function_count = 0;
    return exported;
}

pub fn emitZigModuleResultWithOptionsAlloc(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    options: EmitZigModuleOptions,
) !EmittedZigModule {
    return try emitDirectZigModuleResultAlloc(allocator, chunk, options);
}

pub fn emitJsonModuleAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var parsed = try std.json.parseFromSlice(std.json.Value, arena_allocator, source, .{});
    defer parsed.deinit();

    const root_value = try jsonValueToLuaValueAlloc(arena_allocator, parsed.value);

    var state = TableSeedState.init(arena_allocator);
    defer state.deinit();
    if (root_value == .table) _ = try state.collectTable(root_value.table);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    try writer.writeAll(
        \\const std = @import("std");
        \\const lua = @import("lua");
        \\
        \\// Generated from a JSON-backed module page.
        \\
    );

    for (state.tables.items) |table| try emitDirectConstTableSeed(writer, table, &state);

    try writer.writeAll(
        \\pub fn run(allocator: std.mem.Allocator) !lua.GeneratedRunResult {
        \\    var runtime = lua.GeneratedRuntime.init(allocator);
        \\    errdefer runtime.deinit();
        \\    const returns = try runtime.alloc().alloc(lua.Value, 1);
        \\    returns[0] = 
    );
    try emitStaticRuntimeValue(writer, root_value, &state);
    try writer.writeAll(
        \\;
        \\    return .{
        \\        .runtime = runtime,
        \\        .returns = returns,
        \\    };
        \\}
        \\
    );

    return out.toOwnedSlice();
}

fn jsonValueToLuaValueAlloc(allocator: std.mem.Allocator, json_value: std.json.Value) !Value {
    return switch (json_value) {
        .null => .nil,
        .bool => |flag| .{ .boolean = flag },
        .integer => |number| .{ .number = @floatFromInt(number) },
        .float => |number| .{ .number = number },
        .number_string => |text| .{ .number = try std.fmt.parseFloat(f64, text) },
        .string => |text| .{ .string = try allocator.dupe(u8, text) },
        .array => |items| blk: {
            const table = try Table.init(allocator);
            for (items.items) |item| try table.array.append(allocator, try jsonValueToLuaValueAlloc(allocator, item));
            break :blk .{ .table = table };
        },
        .object => |object| blk: {
            const Entry = struct {
                key: []const u8,
                value: std.json.Value,
            };

            const table = try Table.init(allocator);
            const entries = try allocator.alloc(Entry, object.count());
            var entry_index: usize = 0;
            var it = object.iterator();
            while (it.next()) |entry| : (entry_index += 1) {
                entries[entry_index] = .{
                    .key = entry.key_ptr.*,
                    .value = entry.value_ptr.*,
                };
            }
            std.mem.sort(Entry, entries, {}, struct {
                fn lessThan(_: void, lhs: Entry, rhs: Entry) bool {
                    return std.mem.order(u8, lhs.key, rhs.key) == .lt;
                }
            }.lessThan);
            for (entries) |entry| {
                try table.putString(entry.key, try jsonValueToLuaValueAlloc(allocator, entry.value));
            }
            break :blk .{ .table = table };
        },
    };
}

fn emitStaticRuntimeValue(writer: anytype, value: Value, state: *const TableSeedState) anyerror!void {
    switch (value) {
        .nil => try writer.writeAll("lua.Value.nil"),
        .boolean => |flag| try writer.print("lua.Value{{ .boolean = {} }}", .{flag}),
        .number => |number| {
            try writer.writeAll("lua.Value{ .number = ");
            try emitZigNumberLiteral(writer, number);
            try writer.writeAll(" }");
        },
        .string => |text| {
            try writer.writeAll("lua.Value{ .string = ");
            try writeZigStringLiteral(writer, text);
            try writer.writeAll(" }");
        },
        .table => |table| try writer.print("lua.Value{{ .table = try lua.cloneConstTableSeedAlloc(runtime.alloc(), &const_table_{d}) }}", .{state.tableId(table).?}),
        .generated_callable, .function, .iterator => return error.UnsupportedSyntax,
    }
}

const TableSeedState = struct {
    allocator: std.mem.Allocator,
    table_ids: std.AutoHashMapUnmanaged(usize, u32) = .empty,
    table_signature_ids: std.StringHashMapUnmanaged(u32) = .empty,
    tables: std.ArrayList(*const Table) = .empty,

    fn init(allocator: std.mem.Allocator) TableSeedState {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *TableSeedState) void {
        self.table_ids.deinit(self.allocator);
        var signature_it = self.table_signature_ids.iterator();
        while (signature_it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.table_signature_ids.deinit(self.allocator);
        self.tables.deinit(self.allocator);
        self.* = undefined;
    }

    fn collectTable(self: *TableSeedState, table: *const Table) !u32 {
        const key = @intFromPtr(table);
        if (self.table_ids.get(key)) |existing| return existing;
        for (table.array.items) |value| {
            if (value == .table) _ = try self.collectTable(value.table);
        }
        var string_it = table.string_fields.iterator();
        while (string_it.next()) |entry| {
            if (entry.value_ptr.* == .table) _ = try self.collectTable(entry.value_ptr.*.table);
        }
        var int_it = table.int_fields.iterator();
        while (int_it.next()) |entry| {
            if (entry.value_ptr.* == .table) _ = try self.collectTable(entry.value_ptr.*.table);
        }
        const signature = try self.tableSignatureAlloc(table);
        errdefer self.allocator.free(signature);

        const gop = try self.table_signature_ids.getOrPut(self.allocator, signature);
        if (gop.found_existing) {
            self.allocator.free(signature);
            try self.table_ids.put(self.allocator, key, gop.value_ptr.*);
            return gop.value_ptr.*;
        }

        const id: u32 = @intCast(self.tables.items.len);
        gop.key_ptr.* = signature;
        gop.value_ptr.* = id;
        try self.table_ids.put(self.allocator, key, id);
        try self.tables.append(self.allocator, table);
        return id;
    }

    fn tableSignatureAlloc(self: *const TableSeedState, table: *const Table) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);

        try out.appendSlice(self.allocator, "a");
        try appendUnsignedSignature(&out, self.allocator, table.array.items.len);
        try out.append(self.allocator, ':');
        for (table.array.items) |value| try self.appendConstValueSignature(&out, value);

        var string_entries: std.ArrayList(struct {
            key: []const u8,
            value: Value,
        }) = .empty;
        defer string_entries.deinit(self.allocator);
        var string_it = table.string_fields.iterator();
        while (string_it.next()) |entry| {
            try string_entries.append(self.allocator, .{
                .key = entry.key_ptr.*,
                .value = entry.value_ptr.*,
            });
        }
        std.mem.sort(@TypeOf(string_entries.items[0]), string_entries.items, {}, struct {
            fn lessThan(_: void, lhs: @TypeOf(string_entries.items[0]), rhs: @TypeOf(string_entries.items[0])) bool {
                return std.mem.order(u8, lhs.key, rhs.key) == .lt;
            }
        }.lessThan);

        try out.appendSlice(self.allocator, "s");
        try appendUnsignedSignature(&out, self.allocator, string_entries.items.len);
        try out.append(self.allocator, ':');
        for (string_entries.items) |entry| {
            try appendBytesSignature(&out, self.allocator, entry.key);
            try self.appendConstValueSignature(&out, entry.value);
        }

        var int_entries: std.ArrayList(struct {
            key: i64,
            value: Value,
        }) = .empty;
        defer int_entries.deinit(self.allocator);
        var int_it = table.int_fields.iterator();
        while (int_it.next()) |entry| {
            try int_entries.append(self.allocator, .{
                .key = entry.key_ptr.*,
                .value = entry.value_ptr.*,
            });
        }
        std.mem.sort(@TypeOf(int_entries.items[0]), int_entries.items, {}, struct {
            fn lessThan(_: void, lhs: @TypeOf(int_entries.items[0]), rhs: @TypeOf(int_entries.items[0])) bool {
                return lhs.key < rhs.key;
            }
        }.lessThan);

        try out.appendSlice(self.allocator, "i");
        try appendUnsignedSignature(&out, self.allocator, int_entries.items.len);
        try out.append(self.allocator, ':');
        for (int_entries.items) |entry| {
            try out.appendSlice(self.allocator, "k");
            try appendSignedSignature(&out, self.allocator, entry.key);
            try out.append(self.allocator, ';');
            try self.appendConstValueSignature(&out, entry.value);
        }

        return out.toOwnedSlice(self.allocator);
    }

    fn appendConstValueSignature(
        self: *const TableSeedState,
        out: *std.ArrayList(u8),
        value: Value,
    ) !void {
        switch (value) {
            .nil => try out.appendSlice(self.allocator, "n;"),
            .boolean => |flag| try out.appendSlice(self.allocator, if (flag) "b1;" else "b0;"),
            .number => |number| {
                const bits: u64 = @bitCast(number);
                try out.appendSlice(self.allocator, "d");
                try appendHexSignature(out, self.allocator, bits);
                try out.append(self.allocator, ';');
            },
            .string => |text| {
                try out.appendSlice(self.allocator, "q");
                try appendBytesSignature(out, self.allocator, text);
            },
            .table => |child| {
                try out.appendSlice(self.allocator, "t");
                try appendUnsignedSignature(out, self.allocator, self.tableId(child).?);
                try out.append(self.allocator, ';');
            },
            .generated_callable, .function, .iterator => return error.UnsupportedSyntax,
        }
    }

    fn collectStmt(self: *TableSeedState, stmt: *const Stmt) anyerror!void {
        switch (stmt.*) {
            .local_assign => |op| for (op.exprs) |expr| try self.collectExpr(expr),
            .assign => |op| {
                for (op.targets) |target| try self.collectLValue(target);
                for (op.exprs) |expr| try self.collectExpr(expr);
            },
            .function_def => |op| {
                try self.collectLValue(op.target);
                for (op.body) |child| try self.collectStmt(child);
            },
            .if_stmt => |op| {
                for (op.branches) |branch| {
                    try self.collectExpr(branch.condition);
                    for (branch.body) |child| try self.collectStmt(child);
                }
                for (op.else_body) |child| try self.collectStmt(child);
            },
            .do_block => |body| for (body) |child| try self.collectStmt(child),
            .while_stmt => |op| {
                try self.collectExpr(op.condition);
                for (op.body) |child| try self.collectStmt(child);
            },
            .repeat_stmt => |op| {
                for (op.body) |child| try self.collectStmt(child);
                try self.collectExpr(op.condition);
            },
            .numeric_for => |op| {
                try self.collectExpr(op.start);
                try self.collectExpr(op.finish);
                if (op.step) |step| try self.collectExpr(step);
                for (op.body) |child| try self.collectStmt(child);
            },
            .generic_for => |op| {
                for (op.iterator_exprs) |expr| try self.collectExpr(expr);
                for (op.body) |child| try self.collectStmt(child);
            },
            .return_stmt => |op| for (op.exprs) |expr| try self.collectExpr(expr),
            .break_stmt => {},
            .expr_stmt => |expr| try self.collectExpr(expr),
        }
    }

    fn collectLValue(self: *TableSeedState, lvalue: LValue) anyerror!void {
        switch (lvalue) {
            .name => {},
            .field => |field| try self.collectExpr(field.object),
            .index => |index| {
                try self.collectExpr(index.object);
                try self.collectExpr(index.key);
            },
        }
    }

    fn collectExpr(self: *TableSeedState, expr: *const Expr) anyerror!void {
        switch (expr.*) {
            .unary => |op| try self.collectExpr(op.expr),
            .binary => |op| {
                try self.collectExpr(op.lhs);
                try self.collectExpr(op.rhs);
            },
            .table_ctor => |fields| {
                for (fields) |field| switch (field) {
                    .array => |child| try self.collectExpr(child),
                    .named => |named| try self.collectExpr(named.value),
                    .indexed => |indexed| {
                        try self.collectExpr(indexed.key);
                        try self.collectExpr(indexed.value);
                    },
                };
            },
            .const_table => |table| _ = try self.collectTable(table),
            .field => |field| try self.collectExpr(field.object),
            .index => |index| {
                try self.collectExpr(index.object);
                try self.collectExpr(index.key);
            },
            .call => |call| {
                try self.collectExpr(call.callee);
                for (call.args) |arg| try self.collectExpr(arg);
            },
            .function_lit => |func| for (func.body) |child| try self.collectStmt(child),
            .nil_lit, .bool_lit, .number_lit, .string_lit, .variable, .varargs => {},
        }
    }

    fn tableId(self: *const TableSeedState, table: *const Table) ?u32 {
        return self.table_ids.get(@intFromPtr(table));
    }
};

fn appendUnsignedSignature(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: usize) !void {
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}", .{value});
    try out.appendSlice(allocator, text);
}

fn appendBytesSignature(out: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try appendUnsignedSignature(out, allocator, bytes.len);
    try out.append(allocator, ':');
    try out.appendSlice(allocator, bytes);
    try out.append(allocator, ';');
}

fn appendSignedSignature(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i64) !void {
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}", .{value});
    try out.appendSlice(allocator, text);
}

fn appendHexSignature(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{x}", .{value});
    try out.appendSlice(allocator, text);
}

const DirectCaptureOrigin = enum {
    parent_local,
    parent_capture,
};

const DirectCaptureInfo = struct {
    name: []const u8,
    origin: DirectCaptureOrigin,
    mutable: bool,
};

const DirectCaptureBinding = struct {
    name: []const u8,
    origin: DirectCaptureOrigin,
    mutable: bool,
};

const DirectStmtFunctionRef = struct {
    stmt_ptr: usize,
    function_id: u32,
};

const DirectExprFunctionRef = struct {
    expr_ptr: usize,
    function_id: u32,
};

const DirectFunctionInfo = struct {
    id: u32,
    name: []const u8,
    params: []const []const u8,
    body: []const *Stmt,
    is_vararg: bool,
    captures: []const DirectCaptureInfo,
};

const ChildAccessKind = enum {
    local,
    capture,
};

const DirectModuleState = struct {
    allocator: std.mem.Allocator,
    options: EmitZigModuleOptions,
    tables: TableSeedState,
    functions: std.ArrayList(DirectFunctionInfo) = .empty,
    stmt_function_refs: std.ArrayList(DirectStmtFunctionRef) = .empty,
    expr_function_refs: std.ArrayList(DirectExprFunctionRef) = .empty,
    globals: std.ArrayList([]const u8) = .empty,
    method_names: std.ArrayList([]const u8) = .empty,
    method_callable_ids: std.ArrayList(?u32) = .empty,
    top_id: u32 = 0,

    fn init(allocator: std.mem.Allocator, options: EmitZigModuleOptions) DirectModuleState {
        return .{
            .allocator = allocator,
            .options = options,
            .tables = TableSeedState.init(allocator),
        };
    }

    fn deinit(self: *DirectModuleState) void {
        for (self.functions.items) |info| self.allocator.free(info.captures);
        self.functions.deinit(self.allocator);
        self.stmt_function_refs.deinit(self.allocator);
        self.expr_function_refs.deinit(self.allocator);
        self.globals.deinit(self.allocator);
        self.method_names.deinit(self.allocator);
        self.method_callable_ids.deinit(self.allocator);
        self.tables.deinit();
        self.* = undefined;
    }

    fn addFunction(
        self: *DirectModuleState,
        name: []const u8,
        params: []const []const u8,
        body: []const *Stmt,
        is_vararg: bool,
    ) !u32 {
        const id: u32 = @intCast(self.functions.items.len);
        try self.functions.append(self.allocator, .{
            .id = id,
            .name = name,
            .params = params,
            .body = body,
            .is_vararg = is_vararg,
            .captures = &.{},
        });
        return id;
    }

    fn addStmtFunctionRef(self: *DirectModuleState, stmt: *const Stmt, function_id: u32) !void {
        try self.stmt_function_refs.append(self.allocator, .{
            .stmt_ptr = @intFromPtr(stmt),
            .function_id = function_id,
        });
    }

    fn addExprFunctionRef(self: *DirectModuleState, expr: *const Expr, function_id: u32) !void {
        try self.expr_function_refs.append(self.allocator, .{
            .expr_ptr = @intFromPtr(expr),
            .function_id = function_id,
        });
    }

    fn stmtFunctionId(self: *const DirectModuleState, stmt: *const Stmt) ?u32 {
        const stmt_ptr = @intFromPtr(stmt);
        for (self.stmt_function_refs.items) |entry| {
            if (entry.stmt_ptr == stmt_ptr) return entry.function_id;
        }
        return null;
    }

    fn exprFunctionId(self: *const DirectModuleState, expr: *const Expr) ?u32 {
        const expr_ptr = @intFromPtr(expr);
        for (self.expr_function_refs.items) |entry| {
            if (entry.expr_ptr == expr_ptr) return entry.function_id;
        }
        return null;
    }

    // The direct analyzer can encounter the same AST node more than once when
    // shared pointers are threaded through helper rewrites. Reusing the same
    // function id keeps emitted functions/capture structs linear in the actual
    // source instead of exploding exponentially.
    fn ensureStmtFunction(
        self: *DirectModuleState,
        stmt: *const Stmt,
        name: []const u8,
        params: []const []const u8,
        body: []const *Stmt,
        is_vararg: bool,
    ) !struct { id: u32, is_new: bool } {
        if (self.stmtFunctionId(stmt)) |existing| return .{ .id = existing, .is_new = false };
        const function_id = try self.addFunction(name, params, body, is_vararg);
        try self.addStmtFunctionRef(stmt, function_id);
        return .{ .id = function_id, .is_new = true };
    }

    fn ensureExprFunction(
        self: *DirectModuleState,
        expr: *const Expr,
        name: []const u8,
        params: []const []const u8,
        body: []const *Stmt,
        is_vararg: bool,
    ) !struct { id: u32, is_new: bool } {
        if (self.exprFunctionId(expr)) |existing| return .{ .id = existing, .is_new = false };
        const function_id = try self.addFunction(name, params, body, is_vararg);
        try self.addExprFunctionRef(expr, function_id);
        return .{ .id = function_id, .is_new = true };
    }

    fn addGlobal(self: *DirectModuleState, name: []const u8) !u32 {
        if (self.globalId(name)) |existing| return existing;
        const id: u32 = @intCast(self.globals.items.len);
        try self.globals.append(self.allocator, name);
        return id;
    }

    fn globalId(self: *const DirectModuleState, name: []const u8) ?u32 {
        for (self.globals.items, 0..) |existing, idx| {
            if (std.mem.eql(u8, existing, name)) return @intCast(idx);
        }
        return null;
    }

    fn globalFieldName(self: *const DirectModuleState, name: []const u8) []const u8 {
        _ = self;
        return name;
    }

    // Method ids are collected lazily while emitting direct Zig code. The
    // emitter passes the shared module state around as const, so this helper
    // performs the narrow internal mutation needed to intern the method name.
    fn methodId(self: *const DirectModuleState, name: []const u8) !u32 {
        if (self.methodIdConst(name)) |existing| return existing;
        const mutable = @constCast(self);
        const id: u32 = @intCast(mutable.method_names.items.len);
        try mutable.method_names.append(mutable.allocator, name);
        try mutable.method_callable_ids.append(mutable.allocator, null);
        return id;
    }

    fn methodIdConst(self: *const DirectModuleState, name: []const u8) ?u32 {
        for (self.method_names.items, 0..) |existing, idx| {
            if (std.mem.eql(u8, existing, name)) return @intCast(idx);
        }
        return null;
    }

    fn recordMethodCallableId(self: *const DirectModuleState, name: []const u8, callable_id: u32) !u32 {
        const method_id = try self.methodId(name);
        const mutable = @constCast(self);
        if (mutable.method_callable_ids.items[method_id]) |existing| {
            if (existing != callable_id) mutable.method_callable_ids.items[method_id] = null;
        } else {
            mutable.method_callable_ids.items[method_id] = callable_id;
        }
        return method_id;
    }

    fn moduleDispatchIndex(self: *const DirectModuleState, canonical_name: []const u8) ?u16 {
        for (self.options.direct_module_dispatch_names, 0..) |known_name, idx| {
            if (std.mem.eql(u8, known_name, canonical_name)) return @intCast(idx);
        }
        return null;
    }

    fn moduleExportId(self: *const DirectModuleState, module_index: u16, function_name: []const u8) ?u16 {
        if (module_index >= self.options.direct_module_export_tables.len) return null;
        for (self.options.direct_module_export_tables[module_index].exports) |entry| {
            if (std.mem.eql(u8, entry.name, function_name)) return entry.export_id;
        }
        return null;
    }
};

const DirectAnalyzeContext = struct {
    state: *DirectModuleState,
    parent: ?*DirectAnalyzeContext,
    function_id: u32,
    locals: std.ArrayList([]const u8) = .empty,
    scope_marks: std.ArrayList(usize) = .empty,
    captures: std.ArrayList(DirectCaptureBinding) = .empty,

    fn init(state: *DirectModuleState, parent: ?*DirectAnalyzeContext, function_id: u32) DirectAnalyzeContext {
        return .{
            .state = state,
            .parent = parent,
            .function_id = function_id,
        };
    }

    fn deinit(self: *DirectAnalyzeContext) void {
        self.locals.deinit(self.state.allocator);
        self.scope_marks.deinit(self.state.allocator);
        self.captures.deinit(self.state.allocator);
        self.* = undefined;
    }

    fn beginScope(self: *DirectAnalyzeContext) !void {
        try self.scope_marks.append(self.state.allocator, self.locals.items.len);
    }

    fn endScope(self: *DirectAnalyzeContext) void {
        const mark = self.scope_marks.pop().?;
        self.locals.items.len = mark;
    }

    fn declareLocal(self: *DirectAnalyzeContext, name: []const u8) !void {
        try self.locals.append(self.state.allocator, name);
    }

    fn hasLocal(self: *const DirectAnalyzeContext, name: []const u8) bool {
        var idx = self.locals.items.len;
        while (idx != 0) {
            idx -= 1;
            if (std.mem.eql(u8, self.locals.items[idx], name)) return true;
        }
        return false;
    }

    fn captureIndex(self: *const DirectAnalyzeContext, name: []const u8) ?usize {
        for (self.captures.items, 0..) |capture, idx| {
            if (std.mem.eql(u8, capture.name, name)) return idx;
        }
        return null;
    }

    fn addCapture(self: *DirectAnalyzeContext, name: []const u8, origin: DirectCaptureOrigin, mutable: bool) !void {
        if (self.captureIndex(name)) |idx| {
            if (mutable) self.captures.items[idx].mutable = true;
            return;
        }
        try self.captures.append(self.state.allocator, .{
            .name = name,
            .origin = origin,
            .mutable = mutable,
        });
    }

    fn ensureChildAccessible(self: *DirectAnalyzeContext, name: []const u8, mutable: bool) !?ChildAccessKind {
        if (self.hasLocal(name)) return .local;
        if (self.captureIndex(name)) |idx| {
            if (mutable) self.captures.items[idx].mutable = true;
            return .capture;
        }
        const parent = self.parent orelse return null;
        const parent_kind = try parent.ensureChildAccessible(name, mutable) orelse return null;
        try self.addCapture(name, switch (parent_kind) {
            .local => .parent_local,
            .capture => .parent_capture,
        }, mutable);
        return .capture;
    }

    fn resolveOwnReference(self: *DirectAnalyzeContext, name: []const u8, mutable: bool) !void {
        if (self.hasLocal(name)) return;
        if (self.captureIndex(name)) |idx| {
            if (mutable) self.captures.items[idx].mutable = true;
            return;
        }
        const parent = self.parent orelse {
            _ = try self.state.addGlobal(name);
            return;
        };
        const parent_kind = try parent.ensureChildAccessible(name, mutable) orelse {
            _ = try self.state.addGlobal(name);
            return;
        };
        try self.addCapture(name, switch (parent_kind) {
            .local => .parent_local,
            .capture => .parent_capture,
        }, mutable);
    }

    fn finish(self: *DirectAnalyzeContext) !void {
        const info = &self.state.functions.items[self.function_id];
        info.captures = try capturesToOwnedSlice(self.state.allocator, &self.captures);
    }
};

fn capturesToOwnedSlice(
    allocator: std.mem.Allocator,
    captures: *const std.ArrayList(DirectCaptureBinding),
) ![]const DirectCaptureInfo {
    const out = try allocator.alloc(DirectCaptureInfo, captures.items.len);
    for (captures.items, 0..) |capture, idx| {
        out[idx] = .{
            .name = capture.name,
            .origin = capture.origin,
            .mutable = capture.mutable,
        };
    }
    std.mem.sort(DirectCaptureInfo, out, {}, struct {
        fn lessThan(_: void, lhs: DirectCaptureInfo, rhs: DirectCaptureInfo) bool {
            return std.mem.order(u8, lhs.name, rhs.name) == .lt;
        }
    }.lessThan);
    return out;
}

fn analyzeDirectModule(state: *DirectModuleState, body: []const *Stmt) anyerror!void {
    for (body) |stmt| try state.tables.collectStmt(stmt);
    const top_id = try state.addFunction("chunk", &.{}, body, blockContainsVarargs(body));
    state.top_id = top_id;
    var ctx = DirectAnalyzeContext.init(state, null, top_id);
    defer ctx.deinit();
    try analyzeStmtSlice(&ctx, body);
    try ctx.finish();
}

fn analyzeStmtSlice(ctx: *DirectAnalyzeContext, stmts: []const *Stmt) std.mem.Allocator.Error!void {
    for (stmts) |stmt| try analyzeStmt(ctx, stmt);
}

fn analyzeStmt(ctx: *DirectAnalyzeContext, stmt: *const Stmt) std.mem.Allocator.Error!void {
    switch (stmt.*) {
        .local_assign => |op| {
            for (op.exprs) |expr| try analyzeExpr(ctx, expr);
            for (op.names) |name| try ctx.declareLocal(name);
        },
        .assign => |op| {
            for (op.exprs) |expr| try analyzeExpr(ctx, expr);
            for (op.targets) |target| try analyzeLValue(ctx, target);
        },
        .function_def => |op| {
            const ensured = try ctx.state.ensureStmtFunction(
                stmt,
                switch (op.target) {
                    .name => |name| name,
                    .field => |field| field.name,
                    .index => "anonymous",
                },
                op.params,
                op.body,
                op.is_vararg,
            );
            if (!ensured.is_new) return;
            if (op.is_local and op.target == .name) try ctx.declareLocal(op.target.name);
            var child_ctx = DirectAnalyzeContext.init(ctx.state, ctx, ensured.id);
            defer child_ctx.deinit();
            for (op.params) |param| try child_ctx.declareLocal(param);
            try analyzeStmtSlice(&child_ctx, op.body);
            try child_ctx.finish();
            if (!op.is_local or op.target != .name) try analyzeLValue(ctx, op.target);
        },
        .if_stmt => |op| {
            for (op.branches) |branch| {
                try analyzeExpr(ctx, branch.condition);
                try ctx.beginScope();
                try analyzeStmtSlice(ctx, branch.body);
                ctx.endScope();
            }
            try ctx.beginScope();
            try analyzeStmtSlice(ctx, op.else_body);
            ctx.endScope();
        },
        .do_block => |body| {
            try ctx.beginScope();
            try analyzeStmtSlice(ctx, body);
            ctx.endScope();
        },
        .while_stmt => |op| {
            try analyzeExpr(ctx, op.condition);
            try ctx.beginScope();
            try analyzeStmtSlice(ctx, op.body);
            ctx.endScope();
        },
        .repeat_stmt => |op| {
            try ctx.beginScope();
            try analyzeStmtSlice(ctx, op.body);
            try analyzeExpr(ctx, op.condition);
            ctx.endScope();
        },
        .numeric_for => |op| {
            try analyzeExpr(ctx, op.start);
            try analyzeExpr(ctx, op.finish);
            if (op.step) |step| try analyzeExpr(ctx, step);
            try ctx.beginScope();
            try ctx.declareLocal(op.name);
            try analyzeStmtSlice(ctx, op.body);
            ctx.endScope();
        },
        .generic_for => |op| {
            for (op.iterator_exprs) |expr| try analyzeExpr(ctx, expr);
            try ctx.beginScope();
            for (op.names) |name| try ctx.declareLocal(name);
            try analyzeStmtSlice(ctx, op.body);
            ctx.endScope();
        },
        .return_stmt => |op| for (op.exprs) |expr| try analyzeExpr(ctx, expr),
        .break_stmt => {},
        .expr_stmt => |expr| try analyzeExpr(ctx, expr),
    }
}

fn analyzeLValue(ctx: *DirectAnalyzeContext, lvalue: LValue) std.mem.Allocator.Error!void {
    switch (lvalue) {
        .name => |name| try ctx.resolveOwnReference(name, true),
        .field => |field| try analyzeExpr(ctx, field.object),
        .index => |index| {
            try analyzeExpr(ctx, index.object);
            try analyzeExpr(ctx, index.key);
        },
    }
}

fn analyzeExpr(ctx: *DirectAnalyzeContext, expr: *const Expr) std.mem.Allocator.Error!void {
    switch (expr.*) {
        .variable => |name| try ctx.resolveOwnReference(name, false),
        .unary => |op| try analyzeExpr(ctx, op.expr),
        .binary => |op| {
            try analyzeExpr(ctx, op.lhs);
            try analyzeExpr(ctx, op.rhs);
        },
        .table_ctor => |fields| {
            for (fields) |field| switch (field) {
                .array => |child| try analyzeExpr(ctx, child),
                .named => |named| try analyzeExpr(ctx, named.value),
                .indexed => |indexed| {
                    try analyzeExpr(ctx, indexed.key);
                    try analyzeExpr(ctx, indexed.value);
                },
            };
        },
        .field => |field| try analyzeExpr(ctx, field.object),
        .index => |index| {
            try analyzeExpr(ctx, index.object);
            try analyzeExpr(ctx, index.key);
        },
        .call => |call| {
            try analyzeExpr(ctx, call.callee);
            for (call.args) |arg| try analyzeExpr(ctx, arg);
        },
        .function_lit => |func| {
            const ensured = try ctx.state.ensureExprFunction(expr, "anonymous", func.params, func.body, func.is_vararg);
            if (!ensured.is_new) return;
            var child_ctx = DirectAnalyzeContext.init(ctx.state, ctx, ensured.id);
            defer child_ctx.deinit();
            for (func.params) |param| try child_ctx.declareLocal(param);
            try analyzeStmtSlice(&child_ctx, func.body);
            try child_ctx.finish();
        },
        .nil_lit, .bool_lit, .number_lit, .string_lit, .varargs, .const_table => {},
    }
}

const DirectEmitLocalBinding = struct {
    name: []const u8,
    id: u32,
};

const DirectLocalUseContext = struct {
    state: *const DirectModuleState,
    info: *const DirectFunctionInfo,
    locals: std.ArrayList(DirectEmitLocalBinding) = .empty,
    scope_marks: std.ArrayList(usize) = .empty,
    used_locals: std.ArrayList(bool) = .empty,
    local_requires_var: std.ArrayList(bool) = .empty,
    pending_local_function_captures: std.ArrayList(PendingLocalFunctionCaptures) = .empty,

    fn init(state: *const DirectModuleState, info: *const DirectFunctionInfo) DirectLocalUseContext {
        return .{ .state = state, .info = info };
    }

    fn deinit(self: *DirectLocalUseContext) void {
        for (self.pending_local_function_captures.items) |pending| self.state.allocator.free(pending.captured_locals);
        self.locals.deinit(self.state.allocator);
        self.scope_marks.deinit(self.state.allocator);
        self.used_locals.deinit(self.state.allocator);
        self.local_requires_var.deinit(self.state.allocator);
        self.pending_local_function_captures.deinit(self.state.allocator);
        self.* = undefined;
    }

    fn beginScope(self: *DirectLocalUseContext) !void {
        try self.scope_marks.append(self.state.allocator, self.locals.items.len);
    }

    fn endScope(self: *DirectLocalUseContext) void {
        const mark = self.scope_marks.pop().?;
        self.locals.items.len = mark;
    }

    fn declareLocal(self: *DirectLocalUseContext, name: []const u8) !u32 {
        const id: u32 = @intCast(self.used_locals.items.len);
        try self.locals.append(self.state.allocator, .{ .name = name, .id = id });
        try self.used_locals.append(self.state.allocator, false);
        try self.local_requires_var.append(self.state.allocator, false);
        return id;
    }

    fn lookupLocal(self: *const DirectLocalUseContext, name: []const u8) ?u32 {
        var idx = self.locals.items.len;
        while (idx != 0) {
            idx -= 1;
            const local = self.locals.items[idx];
            if (std.mem.eql(u8, local.name, name)) return local.id;
        }
        return null;
    }

    fn markLocalUsed(self: *DirectLocalUseContext, local_id: u32) void {
        self.used_locals.items[local_id] = true;
    }

    fn markLocalRequiresVar(self: *DirectLocalUseContext, local_id: u32) void {
        self.local_requires_var.items[local_id] = true;
    }
};

const PendingCapturedLocal = struct {
    local_id: u32,
    mutable: bool,
};

const PendingLocalFunctionCaptures = struct {
    local_id: u32,
    captured_locals: []const PendingCapturedLocal,
};

const DirectLocalAnalysis = struct {
    used: []bool,
    requires_var: []bool,

    fn deinit(self: *DirectLocalAnalysis, allocator: std.mem.Allocator) void {
        allocator.free(self.used);
        allocator.free(self.requires_var);
        self.* = undefined;
    }
};

const DirectBuiltinCall = enum {
    print,
    tostring,
    tonumber,
    type_,
    unpack,
    pairs,
    ipairs,
    string_len,
    string_lower,
    string_upper,
    string_sub,
    string_gsub,
    math_floor,
    math_ceil,
    math_abs,
    table_insert,
    table_remove,
    table_sort,
    table_unpack,
    table_concat,
};

const DirectMethodCall = struct {
    receiver: *const Expr,
    name: []const u8,
    args: []const *Expr,
};

const DirectModuleDispatchCall = enum {
    require,
    mw_load_data,
    safe_require,
    safe_mw_load_data,
};

const DirectHelperDispatchCall = enum {
    require_when_needed,
    utilities_require_when_needed,
};

const KnownModuleExportCall = struct {
    module_values: KnownStringValues,
    function_name: []const u8,
};

const BuiltinTableKind = enum {
    string,
    math,
    table,
    frame,
    content_language,
};

const DirectInvokeLowering = union(enum) {
    module_dispatch: DirectModuleDispatchCall,
    helper_dispatch: DirectHelperDispatchCall,
    module_export: KnownModuleExportCall,
};

const max_known_string_values = 8;

const KnownStringValues = struct {
    len: usize = 0,
    items: [max_known_string_values][]const u8 = [_][]const u8{""} ** max_known_string_values,

    fn fromSingle(value: []const u8) KnownStringValues {
        var out: KnownStringValues = .{};
        out.items[0] = value;
        out.len = 1;
        return out;
    }

    fn slice(self: *const KnownStringValues) []const []const u8 {
        return self.items[0..self.len];
    }

    fn contains(self: *const KnownStringValues, value: []const u8) bool {
        for (self.slice()) |item| {
            if (std.mem.eql(u8, item, value)) return true;
        }
        return false;
    }

    fn append(self: *KnownStringValues, value: []const u8) bool {
        if (self.contains(value)) return true;
        if (self.len >= self.items.len) return false;
        self.items[self.len] = value;
        self.len += 1;
        return true;
    }
};

fn singleKnownStringValue(values: KnownStringValues) ?[]const u8 {
    return if (values.len == 1) values.items[0] else null;
}

const KnownValueFact = union(enum) {
    unknown,
    string_values: KnownStringValues,
    loaded_module_values: KnownStringValues,
    dispatch_fn: DirectModuleDispatchCall,
    helper_fn: DirectHelperDispatchCall,
    module_export: KnownModuleExportCall,
    direct_function_id: u32,
    static_callable_id: u32,
    generated_callable_id: u32,
    builtin_table: BuiltinTableKind,
    mw_table,
};

const KnownFactSnapshot = struct {
    local_facts: []KnownValueFact,
    capture_facts: []KnownValueFact,

    fn deinit(self: *KnownFactSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.local_facts);
        allocator.free(self.capture_facts);
        self.* = undefined;
    }
};

const DirectMethodBindingOwner = union(enum) {
    local: u32,
    capture: u32,
    global: u32,
};

const DirectMethodBindingSource = union(enum) {
    temp: u32,
    local: u32,
    capture: u32,
    global: u32,
};

const DirectMethodBinding = struct {
    owner: DirectMethodBindingOwner,
    name: []const u8,
    fact: KnownValueFact,
    source: DirectMethodBindingSource,
};

const DirectMethodBindingSeed = struct {
    capture_index: u32,
    name: []const u8,
    fact: KnownValueFact,
};

const DirectEmitFunctionContext = struct {
    state: *const DirectModuleState,
    info: *const DirectFunctionInfo,
    uses_return_block: bool,
    local_used: []const bool,
    local_requires_var: []const bool,
    locals: std.ArrayList(DirectEmitLocalBinding) = .empty,
    local_source_names: std.ArrayList([]const u8) = .empty,
    local_facts: std.ArrayList(KnownValueFact) = .empty,
    capture_facts: []KnownValueFact = &.{},
    scope_marks: std.ArrayList(usize) = .empty,
    method_bindings: std.ArrayList(DirectMethodBinding) = .empty,
    method_binding_marks: std.ArrayList(usize) = .empty,
    capture_fact_seeds: []?[]KnownValueFact = &.{},
    capture_method_binding_seeds: []?[]DirectMethodBindingSeed = &.{},
    next_local_id: u32 = 0,
    next_temp_id: u32 = 0,

    fn init(
        state: *const DirectModuleState,
        info: *const DirectFunctionInfo,
        uses_return_block: bool,
        local_used: []const bool,
        local_requires_var: []const bool,
        capture_fact_seeds: []?[]KnownValueFact,
        capture_method_binding_seeds: []?[]DirectMethodBindingSeed,
    ) DirectEmitFunctionContext {
        return .{
            .state = state,
            .info = info,
            .uses_return_block = uses_return_block,
            .local_used = local_used,
            .local_requires_var = local_requires_var,
            .capture_fact_seeds = capture_fact_seeds,
            .capture_method_binding_seeds = capture_method_binding_seeds,
        };
    }

    fn deinit(self: *DirectEmitFunctionContext) void {
        self.locals.deinit(self.state.allocator);
        self.local_source_names.deinit(self.state.allocator);
        self.local_facts.deinit(self.state.allocator);
        self.state.allocator.free(self.capture_facts);
        self.scope_marks.deinit(self.state.allocator);
        self.method_bindings.deinit(self.state.allocator);
        self.method_binding_marks.deinit(self.state.allocator);
        self.* = undefined;
    }

    fn beginScope(self: *DirectEmitFunctionContext) !void {
        try self.scope_marks.append(self.state.allocator, self.locals.items.len);
        try self.method_binding_marks.append(self.state.allocator, self.method_bindings.items.len);
    }

    fn endScope(self: *DirectEmitFunctionContext) void {
        const mark = self.scope_marks.pop().?;
        self.locals.items.len = mark;
        const binding_mark = self.method_binding_marks.pop().?;
        self.method_bindings.items.len = binding_mark;
    }

    fn declareLocal(self: *DirectEmitFunctionContext, name: []const u8) !u32 {
        const id = self.next_local_id;
        self.next_local_id += 1;
        try self.locals.append(self.state.allocator, .{ .name = name, .id = id });
        try self.local_source_names.append(self.state.allocator, name);
        try self.local_facts.append(self.state.allocator, .unknown);
        return id;
    }

    fn lookupLocal(self: *const DirectEmitFunctionContext, name: []const u8) ?u32 {
        var idx = self.locals.items.len;
        while (idx != 0) {
            idx -= 1;
            const local = self.locals.items[idx];
            if (std.mem.eql(u8, local.name, name)) return local.id;
        }
        return null;
    }

    fn lookupCapture(self: *const DirectEmitFunctionContext, name: []const u8) ?u32 {
        for (self.info.captures, 0..) |capture, idx| {
            if (std.mem.eql(u8, capture.name, name)) return @intCast(idx);
        }
        return null;
    }

    fn nextTemp(self: *DirectEmitFunctionContext) u32 {
        const id = self.next_temp_id;
        self.next_temp_id += 1;
        return id;
    }

    fn localSourceName(self: *const DirectEmitFunctionContext, local_id: u32) []const u8 {
        if (local_id >= self.local_source_names.items.len) return "value";
        return self.local_source_names.items[local_id];
    }

    fn localFact(self: *const DirectEmitFunctionContext, local_id: u32) KnownValueFact {
        if (local_id >= self.local_facts.items.len) return .unknown;
        return self.local_facts.items[local_id];
    }

    fn setLocalFact(self: *DirectEmitFunctionContext, local_id: u32, fact: KnownValueFact) void {
        if (local_id >= self.local_facts.items.len) return;
        self.local_facts.items[local_id] = fact;
    }

    fn captureFact(self: *const DirectEmitFunctionContext, capture_id: u32) KnownValueFact {
        if (capture_id >= self.capture_facts.len) return .unknown;
        return self.capture_facts[capture_id];
    }

    fn setCaptureFact(self: *DirectEmitFunctionContext, capture_id: u32, fact: KnownValueFact) void {
        if (capture_id >= self.capture_facts.len) return;
        self.capture_facts[capture_id] = fact;
    }

    fn snapshotFactsAlloc(self: *const DirectEmitFunctionContext) !KnownFactSnapshot {
        const local_facts = try self.state.allocator.alloc(KnownValueFact, self.local_facts.items.len);
        errdefer self.state.allocator.free(local_facts);
        for (self.local_facts.items, 0..) |fact, idx| local_facts[idx] = fact;

        const capture_facts = try self.state.allocator.alloc(KnownValueFact, self.capture_facts.len);
        errdefer self.state.allocator.free(capture_facts);
        for (self.capture_facts, 0..) |fact, idx| capture_facts[idx] = fact;

        return .{
            .local_facts = local_facts,
            .capture_facts = capture_facts,
        };
    }

    fn restoreFacts(self: *DirectEmitFunctionContext, snapshot: *const KnownFactSnapshot) !void {
        try self.local_facts.ensureTotalCapacity(self.state.allocator, snapshot.local_facts.len);
        self.local_facts.items.len = snapshot.local_facts.len;
        for (snapshot.local_facts, 0..) |fact, idx| self.local_facts.items[idx] = fact;
        if (self.capture_facts.len != snapshot.capture_facts.len) return error.InvalidCall;
        for (snapshot.capture_facts, 0..) |fact, idx| self.capture_facts[idx] = fact;
    }

    fn bindingOwnerForExpr(self: *const DirectEmitFunctionContext, expr: *const Expr) ?DirectMethodBindingOwner {
        return switch (expr.*) {
            .variable => |name| blk: {
                if (self.lookupLocal(name)) |local_id| break :blk .{ .local = local_id };
                if (self.lookupCapture(name)) |capture_id| break :blk .{ .capture = capture_id };
                if (self.state.globalId(name)) |global_id| break :blk .{ .global = global_id };
                break :blk null;
            },
            else => null,
        };
    }

    fn clearMethodBindingsForOwner(self: *DirectEmitFunctionContext, owner: DirectMethodBindingOwner) void {
        var write_index: usize = 0;
        for (self.method_bindings.items) |binding| {
            if (directMethodBindingOwnerEql(binding.owner, owner)) continue;
            if (write_index != self.method_bindings.items.len) {
                self.method_bindings.items[write_index] = binding;
            }
            write_index += 1;
        }
        self.method_bindings.items.len = write_index;
    }

    fn setMethodBinding(
        self: *DirectEmitFunctionContext,
        owner: DirectMethodBindingOwner,
        name: []const u8,
        fact: KnownValueFact,
        source: DirectMethodBindingSource,
    ) !void {
        var idx = self.method_bindings.items.len;
        while (idx != 0) {
            idx -= 1;
            if (!directMethodBindingOwnerEql(self.method_bindings.items[idx].owner, owner)) continue;
            if (!std.mem.eql(u8, self.method_bindings.items[idx].name, name)) continue;
            self.method_bindings.items[idx] = .{
                .owner = owner,
                .name = name,
                .fact = fact,
                .source = source,
            };
            return;
        }
        try self.method_bindings.append(self.state.allocator, .{
            .owner = owner,
            .name = name,
            .fact = fact,
            .source = source,
        });
    }

    fn removeMethodBinding(self: *DirectEmitFunctionContext, owner: DirectMethodBindingOwner, name: []const u8) void {
        var write_index: usize = 0;
        for (self.method_bindings.items) |binding| {
            if (directMethodBindingOwnerEql(binding.owner, owner) and std.mem.eql(u8, binding.name, name)) continue;
            if (write_index != self.method_bindings.items.len) {
                self.method_bindings.items[write_index] = binding;
            }
            write_index += 1;
        }
        self.method_bindings.items.len = write_index;
    }

    fn lookupMethodBinding(
        self: *const DirectEmitFunctionContext,
        object_expr: *const Expr,
        name: []const u8,
    ) ?DirectMethodBinding {
        const owner = self.bindingOwnerForExpr(object_expr) orelse return null;
        var idx = self.method_bindings.items.len;
        while (idx != 0) {
            idx -= 1;
            const binding = self.method_bindings.items[idx];
            if (!directMethodBindingOwnerEql(binding.owner, owner)) continue;
            if (!std.mem.eql(u8, binding.name, name)) continue;
            return binding;
        }
        return null;
    }
};

fn debugEmitUnknownVariable(ctx: *const DirectEmitFunctionContext, kind: []const u8, name: []const u8) error{UnknownVariable} {
    std.debug.print(
        "lua emit unknown {s}: {s} in function {s} (id={d})\n",
        .{ kind, name, ctx.info.name, ctx.info.id },
    );
    return error.UnknownVariable;
}

fn directMethodBindingOwnerEql(lhs: DirectMethodBindingOwner, rhs: DirectMethodBindingOwner) bool {
    return switch (lhs) {
        .local => |lhs_id| switch (rhs) {
            .local => |rhs_id| lhs_id == rhs_id,
            else => false,
        },
        .capture => |lhs_id| switch (rhs) {
            .capture => |rhs_id| lhs_id == rhs_id,
            else => false,
        },
        .global => |lhs_id| switch (rhs) {
            .global => |rhs_id| lhs_id == rhs_id,
            else => false,
        },
    };
}

fn mergeKnownValueFacts(lhs: KnownValueFact, rhs: KnownValueFact) KnownValueFact {
    return switch (lhs) {
        .unknown => .unknown,
        .builtin_table => |lhs_table| switch (rhs) {
            .builtin_table => |rhs_table| if (lhs_table == rhs_table)
                .{ .builtin_table = lhs_table }
            else
                .unknown,
            else => .unknown,
        },
        .mw_table => switch (rhs) {
            .mw_table => .mw_table,
            else => .unknown,
        },
        .generated_callable_id => |lhs_id| switch (rhs) {
            .generated_callable_id => |rhs_id| if (lhs_id == rhs_id)
                .{ .generated_callable_id = lhs_id }
            else
                .unknown,
            else => .unknown,
        },
        .direct_function_id => |lhs_id| switch (rhs) {
            .direct_function_id => |rhs_id| if (lhs_id == rhs_id)
                .{ .direct_function_id = lhs_id }
            else
                .unknown,
            else => .unknown,
        },
        .static_callable_id => |lhs_id| switch (rhs) {
            .static_callable_id => |rhs_id| if (lhs_id == rhs_id)
                .{ .static_callable_id = lhs_id }
            else
                .unknown,
            else => .unknown,
        },
        .loaded_module_values => |lhs_values| switch (rhs) {
            .loaded_module_values => |rhs_values| blk: {
                var merged = lhs_values;
                for (rhs_values.slice()) |value| {
                    if (!merged.append(value)) break :blk .unknown;
                }
                break :blk .{ .loaded_module_values = merged };
            },
            else => .unknown,
        },
        .dispatch_fn => |lhs_dispatch| switch (rhs) {
            .dispatch_fn => |rhs_dispatch| if (lhs_dispatch == rhs_dispatch)
                .{ .dispatch_fn = lhs_dispatch }
            else
                .unknown,
            else => .unknown,
        },
        .helper_fn => |lhs_helper| switch (rhs) {
            .helper_fn => |rhs_helper| if (lhs_helper == rhs_helper)
                .{ .helper_fn = lhs_helper }
            else
                .unknown,
            else => .unknown,
        },
        .module_export => |lhs_export| switch (rhs) {
            .module_export => |rhs_export| if (std.mem.eql(u8, lhs_export.function_name, rhs_export.function_name)) blk: {
                var merged = lhs_export.module_values;
                for (rhs_export.module_values.slice()) |value| {
                    if (!merged.append(value)) break :blk .unknown;
                }
                break :blk .{ .module_export = .{
                    .module_values = merged,
                    .function_name = lhs_export.function_name,
                } };
            } else .unknown,
            else => .unknown,
        },
        .string_values => |lhs_values| switch (rhs) {
            .string_values => |rhs_values| blk: {
                var merged = lhs_values;
                for (rhs_values.slice()) |value| {
                    if (!merged.append(value)) break :blk .unknown;
                }
                break :blk .{ .string_values = merged };
            },
            else => .unknown,
        },
    };
}

fn concatKnownStringValues(
    allocator: std.mem.Allocator,
    lhs: KnownStringValues,
    rhs: KnownStringValues,
) !KnownValueFact {
    var merged: KnownStringValues = .{};
    for (lhs.slice()) |lhs_value| {
        for (rhs.slice()) |rhs_value| {
            const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ lhs_value, rhs_value });
            if (!merged.append(combined)) return .unknown;
        }
    }
    return .{ .string_values = merged };
}

fn mergeSnapshotFactsAlloc(
    allocator: std.mem.Allocator,
    base: *const KnownFactSnapshot,
    paths: []const KnownFactSnapshot,
) !KnownFactSnapshot {
    var merged = KnownFactSnapshot{
        .local_facts = try allocator.alloc(KnownValueFact, base.local_facts.len),
        .capture_facts = try allocator.alloc(KnownValueFact, base.capture_facts.len),
    };
    errdefer merged.deinit(allocator);
    for (base.local_facts, 0..) |fact, idx| merged.local_facts[idx] = fact;
    for (base.capture_facts, 0..) |fact, idx| merged.capture_facts[idx] = fact;

    for (paths) |path| {
        const local_len = @min(merged.local_facts.len, path.local_facts.len);
        for (0..local_len) |idx| {
            merged.local_facts[idx] = mergeKnownValueFacts(merged.local_facts[idx], path.local_facts[idx]);
        }
        const capture_len = @min(merged.capture_facts.len, path.capture_facts.len);
        for (0..capture_len) |idx| {
            merged.capture_facts[idx] = mergeKnownValueFacts(merged.capture_facts[idx], path.capture_facts[idx]);
        }
    }
    return merged;
}

fn builtinKnownValueFact(state: *const DirectModuleState, name: []const u8) KnownValueFact {
    if (!state.options.enable_direct_module_dispatch) return .unknown;
    if (std.mem.eql(u8, name, "require")) return .{ .dispatch_fn = .require };
    if (std.mem.eql(u8, name, "unpack")) return .{ .static_callable_id = generated_callable_id_builtin_unpack };
    if (std.mem.eql(u8, name, "mw")) return .mw_table;
    if (std.mem.eql(u8, name, "string")) return .{ .builtin_table = .string };
    if (std.mem.eql(u8, name, "math")) return .{ .builtin_table = .math };
    if (std.mem.eql(u8, name, "table")) return .{ .builtin_table = .table };
    return .unknown;
}

fn generatedCallableIdForBuiltinMethod(kind: BuiltinTableKind, field_name: []const u8) ?u32 {
    return switch (kind) {
        .string => if (std.mem.eql(u8, field_name, "len"))
            generated_callable_id_builtin_string_len
        else if (std.mem.eql(u8, field_name, "lower"))
            generated_callable_id_builtin_string_lower
        else if (std.mem.eql(u8, field_name, "upper"))
            generated_callable_id_builtin_string_upper
        else if (std.mem.eql(u8, field_name, "sub"))
            generated_callable_id_builtin_string_sub
        else if (std.mem.eql(u8, field_name, "gsub"))
            generated_callable_id_builtin_string_gsub
        else
            null,
        .math => if (std.mem.eql(u8, field_name, "floor"))
            generated_callable_id_builtin_math_floor
        else if (std.mem.eql(u8, field_name, "ceil"))
            generated_callable_id_builtin_math_ceil
        else if (std.mem.eql(u8, field_name, "abs"))
            generated_callable_id_builtin_math_abs
        else
            null,
        .table => if (std.mem.eql(u8, field_name, "insert"))
            generated_callable_id_builtin_table_insert
        else if (std.mem.eql(u8, field_name, "remove"))
            generated_callable_id_builtin_table_remove
        else if (std.mem.eql(u8, field_name, "sort"))
            generated_callable_id_builtin_table_sort
        else if (std.mem.eql(u8, field_name, "unpack"))
            generated_callable_id_builtin_table_unpack
        else if (std.mem.eql(u8, field_name, "concat"))
            generated_callable_id_builtin_table_concat
        else
            null,
        .frame => if (std.mem.eql(u8, field_name, "getParent"))
            generated_callable_id_frame_get_parent
        else if (std.mem.eql(u8, field_name, "expandTemplate"))
            generated_callable_id_frame_expand_template
        else if (std.mem.eql(u8, field_name, "preprocess"))
            generated_callable_id_frame_preprocess
        else
            null,
        .content_language => if (std.mem.eql(u8, field_name, "ucfirst"))
            generated_callable_id_content_language_ucfirst
        else
            null,
    };
}

fn genericStringMethodCallableId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "gsub")) return generated_callable_id_builtin_string_gsub;
    return null;
}

fn callableIdForKnownFact(state: *const DirectModuleState, fact: KnownValueFact) ?u32 {
    return switch (fact) {
        .direct_function_id => |function_id| stateGeneratedCallableId(state, function_id),
        .static_callable_id => |callable_id| callable_id,
        .generated_callable_id => |callable_id| callable_id,
        else => null,
    };
}

fn forwardedCallableFact(fact: KnownValueFact) KnownValueFact {
    return switch (fact) {
        .dispatch_fn, .helper_fn, .module_export => fact,
        else => .unknown,
    };
}

fn rawModuleNameMatchesCanonical(raw_value: []const u8, canonical_name: []const u8) bool {
    var text = std.mem.trim(u8, raw_value, " \t\r\n");
    if (text.len >= "Module:".len and std.ascii.eqlIgnoreCase(text[0.."Module:".len], "Module:")) {
        text = text["Module:".len..];
    }
    return std.ascii.eqlIgnoreCase(text, canonical_name);
}

fn singleKnownHelperModule(values: KnownStringValues) ?DirectHelperDispatchCall {
    var helper: ?DirectHelperDispatchCall = null;
    for (values.slice()) |value| {
        const candidate: DirectHelperDispatchCall = if (rawModuleNameMatchesCanonical(value, "require when needed"))
            .require_when_needed
        else if (rawModuleNameMatchesCanonical(value, "utilities/require when needed"))
            .utilities_require_when_needed
        else
            return null;
        if (helper) |existing| {
            if (existing != candidate) return null;
        } else {
            helper = candidate;
        }
    }
    return helper;
}

fn allKnownModuleNamesMatchCanonical(values: KnownStringValues, canonical_name: []const u8) bool {
    if (values.len == 0) return false;
    for (values.slice()) |value| {
        if (!rawModuleNameMatchesCanonical(value, canonical_name)) return false;
    }
    return true;
}

fn knownModuleExportFact(values: KnownStringValues, field_name: []const u8) KnownValueFact {
    if (allKnownModuleNamesMatchCanonical(values, "load")) {
        if (std.mem.eql(u8, field_name, "load_data")) return .{ .dispatch_fn = .mw_load_data };
        if (std.mem.eql(u8, field_name, "safe_load_data")) return .{ .dispatch_fn = .safe_mw_load_data };
        if (std.mem.eql(u8, field_name, "safe_require")) return .{ .dispatch_fn = .safe_require };
    }
    if (field_name.len == 0) return .unknown;
    return .{ .module_export = .{
        .module_values = values,
        .function_name = field_name,
    } };
}

fn knownReturnFactForCallableId(callable_id: u32) KnownValueFact {
    return switch (callable_id) {
        generated_callable_id_mw_get_current_frame => .{ .builtin_table = .frame },
        generated_callable_id_mw_get_content_language => .{ .builtin_table = .content_language },
        else => .unknown,
    };
}

fn knownValueFactForExpr(ctx: *const DirectEmitFunctionContext, expr: *const Expr) KnownValueFact {
    return knownValueFactForExprWithDepth(ctx, expr, 8);
}

const KnownFactStmtResult = union(enum) {
    continue_,
    returned: KnownValueFact,
    abort,
};

fn initKnownFactChildContext(parent_ctx: *const DirectEmitFunctionContext, info: *const DirectFunctionInfo) !DirectEmitFunctionContext {
    var child = DirectEmitFunctionContext.init(
        parent_ctx.state,
        info,
        false,
        &.{},
        &.{},
        &.{},
        &.{},
    );
    errdefer child.deinit();

    if (info.captures.len != 0) {
        child.capture_facts = try parent_ctx.state.allocator.alloc(KnownValueFact, info.captures.len);
        for (info.captures, 0..) |capture, idx| {
            child.capture_facts[idx] = switch (capture.origin) {
                .parent_local => if (parent_ctx.lookupLocal(capture.name)) |local_id|
                    parent_ctx.localFact(local_id)
                else
                    .unknown,
                .parent_capture => if (parent_ctx.lookupCapture(capture.name)) |capture_id|
                    parent_ctx.captureFact(capture_id)
                else
                    .unknown,
            };
        }
    }

    for (info.params) |param| {
        const local_id = try child.declareLocal(param);
        child.setLocalFact(local_id, if (std.mem.eql(u8, param, "frame"))
            .{ .builtin_table = .frame }
        else
            .unknown);
    }
    return child;
}

fn applyKnownFactToTarget(ctx: *DirectEmitFunctionContext, target: LValue, fact: KnownValueFact) void {
    switch (target) {
        .name => |name| {
            if (ctx.lookupLocal(name)) |local_id| {
                ctx.setLocalFact(local_id, fact);
            } else if (ctx.lookupCapture(name)) |capture_id| {
                ctx.setCaptureFact(capture_id, fact);
            }
        },
        else => {},
    }
}

fn isIdentityForwardArg(ctx: *const DirectEmitFunctionContext, expr: *const Expr) bool {
    return switch (expr.*) {
        .variable => |name| ctx.info.params.len != 0 and std.mem.eql(u8, name, ctx.info.params[0]),
        .varargs => ctx.info.is_vararg and ctx.info.params.len == 0,
        else => false,
    };
}

fn knownForwardedCallableFact(
    ctx: *const DirectEmitFunctionContext,
    expr: *const Expr,
    remaining_depth: u8,
) KnownValueFact {
    if (remaining_depth == 0) return .unknown;
    return switch (expr.*) {
        .call => |call| blk: {
            const lowering = knownInvokeLoweringForExpr(ctx, call.callee) orelse break :blk .unknown;
            if (call.args.len != 1 or !isIdentityForwardArg(ctx, call.args[0])) break :blk .unknown;
            break :blk switch (lowering) {
                .module_dispatch => |dispatch| .{ .dispatch_fn = dispatch },
                .helper_dispatch => |helper| .{ .helper_fn = helper },
                .module_export => |module_export| .{ .module_export = module_export },
            };
        },
        else => .unknown,
    };
}

fn knownFunctionValueFact(ctx: *const DirectEmitFunctionContext, info: *const DirectFunctionInfo, remaining_depth: u8) KnownValueFact {
    if (remaining_depth == 0) return .unknown;

    var child = initKnownFactChildContext(ctx, info) catch return .unknown;
    defer child.deinit();

    for (info.body) |stmt| switch (analyzeKnownFactStmt(&child, stmt, remaining_depth - 1)) {
        .continue_ => {},
        .returned => |fact| return fact,
        .abort => return .unknown,
    };

    return .unknown;
}

fn analyzeKnownFactStmt(ctx: *DirectEmitFunctionContext, stmt: *const Stmt, remaining_depth: u8) KnownFactStmtResult {
    switch (stmt.*) {
        .local_assign => |op| {
            const value_count = @max(op.names.len, op.exprs.len);
            const value_facts = ctx.state.allocator.alloc(KnownValueFact, value_count) catch return .abort;
            defer ctx.state.allocator.free(value_facts);

            for (0..value_count) |idx| {
                value_facts[idx] = if (idx < op.exprs.len)
                    knownValueFactForExprWithDepth(ctx, op.exprs[idx], remaining_depth)
                else
                    .unknown;
            }

            for (op.names, 0..) |name, idx| {
                const local_id = ctx.declareLocal(name) catch return .abort;
                ctx.setLocalFact(local_id, value_facts[idx]);
            }
            return .continue_;
        },
        .assign => |op| {
            const value_count = @max(op.targets.len, op.exprs.len);
            const value_facts = ctx.state.allocator.alloc(KnownValueFact, value_count) catch return .abort;
            defer ctx.state.allocator.free(value_facts);

            for (0..value_count) |idx| {
                value_facts[idx] = if (idx < op.exprs.len)
                    knownValueFactForExprWithDepth(ctx, op.exprs[idx], remaining_depth)
                else
                    .unknown;
            }

            for (op.targets, 0..) |target, idx| applyKnownFactToTarget(ctx, target, value_facts[idx]);
            return .continue_;
        },
        .function_def => |op| {
            const child_id = ctx.state.stmtFunctionId(stmt) orelse return .abort;
            const child_info = &ctx.state.functions.items[child_id];
            const direct_fact = forwardedCallableFact(knownFunctionValueFact(ctx, child_info, remaining_depth));
            const fact: KnownValueFact = if (direct_fact != .unknown)
                direct_fact
            else
                .{ .direct_function_id = child_id };

            if (op.is_local and op.target == .name) {
                const local_id = ctx.declareLocal(op.target.name) catch return .abort;
                ctx.setLocalFact(local_id, fact);
            } else {
                applyKnownFactToTarget(ctx, op.target, fact);
            }
            return .continue_;
        },
        .expr_stmt => return .continue_,
        // Callable facts are only valid for true forwarding wrappers. A
        // function that merely returns another callable is still not itself
        // equivalent to calling that callable.
        .return_stmt => |op| return .{ .returned = if (op.exprs.len == 1)
            knownForwardedCallableFact(ctx, op.exprs[0], remaining_depth)
        else
            .unknown },
        .if_stmt, .do_block, .while_stmt, .repeat_stmt, .numeric_for, .generic_for, .break_stmt => return .abort,
    }
}

fn knownValueFactForExprWithDepth(ctx: *const DirectEmitFunctionContext, expr: *const Expr, remaining_depth: u8) KnownValueFact {
    if (remaining_depth == 0) return .unknown;
    return switch (expr.*) {
        .string_lit => |value| .{ .string_values = KnownStringValues.fromSingle(value) },
        .variable => |name| blk: {
            if (ctx.lookupLocal(name)) |local_id| break :blk ctx.localFact(local_id);
            if (ctx.lookupCapture(name)) |capture_id| break :blk ctx.captureFact(capture_id);
            break :blk builtinKnownValueFact(ctx.state, name);
        },
        .field => |field| blk: {
            const object_fact = knownValueFactForExpr(ctx, field.object);
            break :blk switch (object_fact) {
                .builtin_table => |kind| if (generatedCallableIdForBuiltinMethod(kind, field.name)) |callable_id|
                    .{ .static_callable_id = callable_id }
                else
                    .unknown,
                .loaded_module_values => |values| knownModuleExportFact(values, field.name),
                .mw_table => if (std.mem.eql(u8, field.name, "loadData"))
                    .{ .dispatch_fn = .mw_load_data }
                else if (std.mem.eql(u8, field.name, "getCurrentFrame"))
                    .{ .static_callable_id = generated_callable_id_mw_get_current_frame }
                else if (std.mem.eql(u8, field.name, "getContentLanguage"))
                    .{ .static_callable_id = generated_callable_id_mw_get_content_language }
                else if (std.mem.eql(u8, field.name, "dumpObject"))
                    .{ .static_callable_id = generated_callable_id_mw_dump_object }
                else
                    .unknown,
                else => .unknown,
            };
        },
        .index => |index| blk: {
            const object_fact = knownValueFactForExpr(ctx, index.object);
            const key_values = knownStringValuesForExpr(ctx, index.key) orelse break :blk .unknown;
            const key = singleKnownStringValue(key_values) orelse break :blk .unknown;
            break :blk switch (object_fact) {
                .builtin_table => |kind| if (generatedCallableIdForBuiltinMethod(kind, key)) |callable_id|
                    .{ .static_callable_id = callable_id }
                else
                    .unknown,
                .loaded_module_values => |values| knownModuleExportFact(values, key),
                .mw_table => if (std.mem.eql(u8, key, "loadData"))
                    .{ .dispatch_fn = .mw_load_data }
                else if (std.mem.eql(u8, key, "getCurrentFrame"))
                    .{ .static_callable_id = generated_callable_id_mw_get_current_frame }
                else if (std.mem.eql(u8, key, "getContentLanguage"))
                    .{ .static_callable_id = generated_callable_id_mw_get_content_language }
                else if (std.mem.eql(u8, key, "dumpObject"))
                    .{ .static_callable_id = generated_callable_id_mw_dump_object }
                else
                    .unknown,
                else => .unknown,
            };
        },
        .binary => |op| switch (op.op) {
            .concat => blk: {
                const lhs_fact = knownValueFactForExprWithDepth(ctx, op.lhs, remaining_depth - 1);
                const rhs_fact = knownValueFactForExprWithDepth(ctx, op.rhs, remaining_depth - 1);
                break :blk switch (lhs_fact) {
                    .string_values => |lhs_values| switch (rhs_fact) {
                        .string_values => |rhs_values| concatKnownStringValues(ctx.state.allocator, lhs_values, rhs_values) catch .unknown,
                        else => .unknown,
                    },
                    else => .unknown,
                };
            },
            .or_, .and_ => blk: {
                const lhs_fact = knownValueFactForExprWithDepth(ctx, op.lhs, remaining_depth - 1);
                const rhs_fact = knownValueFactForExprWithDepth(ctx, op.rhs, remaining_depth - 1);
                break :blk mergeKnownValueFacts(lhs_fact, rhs_fact);
            },
            else => .unknown,
        },
        .call => |call| blk: {
            const callee_fact = knownValueFactForExprWithDepth(ctx, call.callee, remaining_depth - 1);
            break :blk switch (callee_fact) {
                .dispatch_fn => |dispatch| switch (dispatch) {
                    .require => if (call.args.len != 0)
                        if (knownStringValuesForExpr(ctx, call.args[0])) |values|
                            if (singleKnownHelperModule(values)) |helper|
                                .{ .helper_fn = helper }
                            else
                                .{ .loaded_module_values = values }
                        else
                            .unknown
                    else
                        .unknown,
                    .mw_load_data, .safe_require, .safe_mw_load_data => if (call.args.len != 0)
                        if (knownStringValuesForExpr(ctx, call.args[0])) |values|
                            .{ .loaded_module_values = values }
                        else
                            .unknown
                    else
                        .unknown,
                },
                .static_callable_id => |callable_id| knownReturnFactForCallableId(callable_id),
                .generated_callable_id => |callable_id| knownReturnFactForCallableId(callable_id),
                else => .unknown,
            };
        },
        .function_lit => {
            const child_id = ctx.state.exprFunctionId(expr) orelse return .unknown;
            const direct_fact = forwardedCallableFact(knownFunctionValueFact(ctx, &ctx.state.functions.items[child_id], remaining_depth - 1));
            return if (direct_fact != .unknown)
                direct_fact
            else
                .{ .direct_function_id = child_id };
        },
        else => .unknown,
    };
}

fn knownStringValuesForExpr(ctx: *const DirectEmitFunctionContext, expr: *const Expr) ?KnownStringValues {
    return switch (knownValueFactForExpr(ctx, expr)) {
        .string_values => |values| values,
        else => null,
    };
}

fn knownInvokeLoweringForExpr(ctx: *const DirectEmitFunctionContext, expr: *const Expr) ?DirectInvokeLowering {
    return switch (knownValueFactForExpr(ctx, expr)) {
        .dispatch_fn => |dispatch| .{ .module_dispatch = dispatch },
        .helper_fn => |helper| .{ .helper_dispatch = helper },
        .module_export => |module_export| .{ .module_export = module_export },
        else => null,
    };
}

fn seedChildCaptureFacts(ctx: *DirectEmitFunctionContext, info: *const DirectFunctionInfo) !void {
    if (info.id >= ctx.capture_fact_seeds.len or info.captures.len == 0) return;

    const next_facts = try ctx.state.allocator.alloc(KnownValueFact, info.captures.len);
    errdefer ctx.state.allocator.free(next_facts);
    for (info.captures, 0..) |capture, idx| {
        next_facts[idx] = switch (capture.origin) {
            .parent_local => if (ctx.lookupLocal(capture.name)) |local_id|
                ctx.localFact(local_id)
            else
                .unknown,
            .parent_capture => if (ctx.lookupCapture(capture.name)) |capture_id|
                ctx.captureFact(capture_id)
            else
                .unknown,
        };
    }

    if (ctx.capture_fact_seeds[info.id]) |existing| {
        if (existing.len != next_facts.len) return error.InvalidCall;
        for (next_facts, 0..) |*fact, idx| {
            fact.* = mergeKnownValueFacts(existing[idx], fact.*);
        }
        ctx.state.allocator.free(existing);
    }
    ctx.capture_fact_seeds[info.id] = next_facts;
}

fn seedChildCaptureMethodBindings(ctx: *DirectEmitFunctionContext, info: *const DirectFunctionInfo) !void {
    if (info.id >= ctx.capture_method_binding_seeds.len or info.captures.len == 0) return;

    var next_bindings: std.ArrayList(DirectMethodBindingSeed) = .empty;
    defer next_bindings.deinit(ctx.state.allocator);

    for (info.captures, 0..) |capture, capture_idx| {
        const parent_owner: DirectMethodBindingOwner = switch (capture.origin) {
            .parent_local => if (ctx.lookupLocal(capture.name)) |local_id|
                .{ .local = local_id }
            else
                continue,
            .parent_capture => if (ctx.lookupCapture(capture.name)) |capture_id|
                .{ .capture = capture_id }
            else
                continue,
        };

        for (ctx.method_bindings.items) |binding| {
            if (!directMethodBindingOwnerEql(binding.owner, parent_owner)) continue;
            try next_bindings.append(ctx.state.allocator, .{
                .capture_index = @intCast(capture_idx),
                .name = binding.name,
                .fact = binding.fact,
            });
        }
    }

    if (ctx.capture_method_binding_seeds[info.id]) |existing| {
        var merged: std.ArrayList(DirectMethodBindingSeed) = .empty;
        defer merged.deinit(ctx.state.allocator);

        for (existing) |binding| try merged.append(ctx.state.allocator, binding);
        for (next_bindings.items) |binding| {
            var updated = false;
            for (merged.items) |*existing_binding| {
                if (existing_binding.capture_index != binding.capture_index) continue;
                if (!std.mem.eql(u8, existing_binding.name, binding.name)) continue;
                existing_binding.fact = mergeKnownValueFacts(existing_binding.fact, binding.fact);
                updated = true;
                break;
            }
            if (!updated) try merged.append(ctx.state.allocator, binding);
        }

        ctx.state.allocator.free(existing);
        ctx.capture_method_binding_seeds[info.id] = try merged.toOwnedSlice(ctx.state.allocator);
    } else {
        ctx.capture_method_binding_seeds[info.id] = try next_bindings.toOwnedSlice(ctx.state.allocator);
    }
}

fn analyzeDirectFunctionLocalAnalysisAlloc(
    allocator: std.mem.Allocator,
    state: *const DirectModuleState,
    info: *const DirectFunctionInfo,
) AnalyzeDirectUseError!DirectLocalAnalysis {
    var ctx = DirectLocalUseContext.init(state, info);
    defer ctx.deinit();
    for (info.params) |param| _ = try ctx.declareLocal(param);
    try analyzeDirectUseStmtSlice(&ctx, info.body);
    var mutation_ctx = DirectLocalUseContext.init(state, info);
    defer mutation_ctx.deinit();
    for (info.params) |param| _ = try mutation_ctx.declareLocal(param);
    try analyzeDirectMutationsStmtSlice(&mutation_ctx, info.body);
    if (mutation_ctx.local_requires_var.items.len != ctx.local_requires_var.items.len) return error.UnsupportedSyntax;
    for (mutation_ctx.local_requires_var.items, 0..) |requires_var, idx| {
        if (requires_var) ctx.local_requires_var.items[idx] = true;
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (ctx.pending_local_function_captures.items) |pending| {
            if (!ctx.used_locals.items[pending.local_id]) continue;
            const used_before = countTrue(ctx.used_locals.items);
            const var_before = countTrue(ctx.local_requires_var.items);
            markPendingCapturedLocalsUsed(&ctx, pending.captured_locals);
            if (used_before != countTrue(ctx.used_locals.items) or var_before != countTrue(ctx.local_requires_var.items)) {
                changed = true;
            }
        }
    }
    return .{
        .used = try ctx.used_locals.toOwnedSlice(allocator),
        .requires_var = try ctx.local_requires_var.toOwnedSlice(allocator),
    };
}

fn countTrue(values: []const bool) usize {
    var count: usize = 0;
    for (values) |value| {
        if (value) count += 1;
    }
    return count;
}

const AnalyzeDirectUseError = std.mem.Allocator.Error || error{UnsupportedSyntax};

fn analyzeDirectUseStmtSlice(ctx: *DirectLocalUseContext, stmts: []const *Stmt) AnalyzeDirectUseError!void {
    for (stmts) |stmt| try analyzeDirectUseStmt(ctx, stmt);
}

fn analyzeDirectMutationsStmtSlice(ctx: *DirectLocalUseContext, stmts: []const *Stmt) AnalyzeDirectUseError!void {
    for (stmts) |stmt| try analyzeDirectMutationStmt(ctx, stmt);
}

fn markCapturedParentLocalsUsed(ctx: *DirectLocalUseContext, info: *const DirectFunctionInfo) void {
    for (info.captures) |capture| {
        if (capture.origin != .parent_local) continue;
        const local_id = ctx.lookupLocal(capture.name) orelse continue;
        ctx.markLocalUsed(local_id);
        if (capture.mutable) ctx.markLocalRequiresVar(local_id);
    }
}

fn markPendingCapturedLocalsUsed(ctx: *DirectLocalUseContext, captures: []const PendingCapturedLocal) void {
    for (captures) |capture| {
        ctx.markLocalUsed(capture.local_id);
        if (capture.mutable) ctx.markLocalRequiresVar(capture.local_id);
    }
}

fn collectPendingCapturedLocalsAlloc(
    allocator: std.mem.Allocator,
    ctx: *const DirectLocalUseContext,
    info: *const DirectFunctionInfo,
) ![]const PendingCapturedLocal {
    var pending: std.ArrayList(PendingCapturedLocal) = .empty;
    errdefer pending.deinit(allocator);
    for (info.captures) |capture| {
        if (capture.origin != .parent_local) continue;
        const local_id = ctx.lookupLocal(capture.name) orelse continue;
        try pending.append(allocator, .{
            .local_id = local_id,
            .mutable = capture.mutable,
        });
    }
    return pending.toOwnedSlice(allocator);
}

fn analyzeDirectUseLValueExprs(ctx: *DirectLocalUseContext, target: LValue) AnalyzeDirectUseError!void {
    switch (target) {
        .name => {},
        .field => |field| try analyzeDirectUseExpr(ctx, field.object),
        .index => |index| {
            try analyzeDirectUseExpr(ctx, index.object);
            try analyzeDirectUseExpr(ctx, index.key);
        },
    }
}

fn analyzeDirectMutationStmt(ctx: *DirectLocalUseContext, stmt: *const Stmt) AnalyzeDirectUseError!void {
    switch (stmt.*) {
        .local_assign => |op| {
            for (op.exprs) |expr| try analyzeDirectMutationExpr(ctx, expr);
            for (op.names) |name| _ = try ctx.declareLocal(name);
        },
        .assign => |op| {
            for (op.exprs) |expr| try analyzeDirectMutationExpr(ctx, expr);
            for (op.targets) |target| {
                if (target == .name) {
                    if (ctx.lookupLocal(target.name)) |local_id| ctx.markLocalRequiresVar(local_id);
                }
                try analyzeDirectMutationLValueExprs(ctx, target);
            }
        },
        .function_def => |op| {
            if (op.is_local and op.target == .name) {
                const local_id = try ctx.declareLocal(op.target.name);
                // Local function definitions emit an initial nil binding and then
                // assign the generated closure value, so they always need `var`.
                ctx.markLocalRequiresVar(local_id);
            } else {
                if (op.target == .name) {
                    if (ctx.lookupLocal(op.target.name)) |local_id| ctx.markLocalRequiresVar(local_id);
                }
                try analyzeDirectMutationLValueExprs(ctx, op.target);
            }
        },
        .if_stmt => |op| {
            for (op.branches) |branch| {
                try analyzeDirectMutationExpr(ctx, branch.condition);
                try ctx.beginScope();
                try analyzeDirectMutationsStmtSlice(ctx, branch.body);
                ctx.endScope();
            }
            try ctx.beginScope();
            try analyzeDirectMutationsStmtSlice(ctx, op.else_body);
            ctx.endScope();
        },
        .do_block => |body| {
            try ctx.beginScope();
            try analyzeDirectMutationsStmtSlice(ctx, body);
            ctx.endScope();
        },
        .while_stmt => |op| {
            try analyzeDirectMutationExpr(ctx, op.condition);
            try ctx.beginScope();
            try analyzeDirectMutationsStmtSlice(ctx, op.body);
            ctx.endScope();
        },
        .repeat_stmt => |op| {
            try ctx.beginScope();
            try analyzeDirectMutationsStmtSlice(ctx, op.body);
            try analyzeDirectMutationExpr(ctx, op.condition);
            ctx.endScope();
        },
        .numeric_for => |op| {
            try analyzeDirectMutationExpr(ctx, op.start);
            try analyzeDirectMutationExpr(ctx, op.finish);
            if (op.step) |step| try analyzeDirectMutationExpr(ctx, step);
            try ctx.beginScope();
            const local_id = try ctx.declareLocal(op.name);
            ctx.markLocalRequiresVar(local_id);
            try analyzeDirectMutationsStmtSlice(ctx, op.body);
            ctx.endScope();
        },
        .generic_for => |op| {
            for (op.iterator_exprs) |expr| try analyzeDirectMutationExpr(ctx, expr);
            try ctx.beginScope();
            for (op.names) |name| _ = try ctx.declareLocal(name);
            try analyzeDirectMutationsStmtSlice(ctx, op.body);
            ctx.endScope();
        },
        .return_stmt => |op| for (op.exprs) |expr| try analyzeDirectMutationExpr(ctx, expr),
        .expr_stmt => |expr| try analyzeDirectMutationExpr(ctx, expr),
        .break_stmt => {},
    }
}

fn analyzeDirectMutationExpr(ctx: *DirectLocalUseContext, expr: *const Expr) AnalyzeDirectUseError!void {
    switch (expr.*) {
        .nil_lit, .bool_lit, .number_lit, .string_lit, .variable, .varargs, .const_table => {},
        .unary => |op| try analyzeDirectMutationExpr(ctx, op.expr),
        .binary => |op| {
            try analyzeDirectMutationExpr(ctx, op.lhs);
            try analyzeDirectMutationExpr(ctx, op.rhs);
        },
        .table_ctor => |fields| {
            for (fields) |field| switch (field) {
                .array => |value| try analyzeDirectMutationExpr(ctx, value),
                .named => |named| try analyzeDirectMutationExpr(ctx, named.value),
                .indexed => |indexed| {
                    try analyzeDirectMutationExpr(ctx, indexed.key);
                    try analyzeDirectMutationExpr(ctx, indexed.value);
                },
            };
        },
        .field => |field| try analyzeDirectMutationExpr(ctx, field.object),
        .index => |index| {
            try analyzeDirectMutationExpr(ctx, index.object);
            try analyzeDirectMutationExpr(ctx, index.key);
        },
        .call => |call| {
            try analyzeDirectMutationExpr(ctx, call.callee);
            for (call.args) |arg| try analyzeDirectMutationExpr(ctx, arg);
        },
        .function_lit => {},
    }
}

fn analyzeDirectMutationLValueExprs(ctx: *DirectLocalUseContext, target: LValue) AnalyzeDirectUseError!void {
    switch (target) {
        .name => {},
        .field => |field| try analyzeDirectMutationExpr(ctx, field.object),
        .index => |index| {
            try analyzeDirectMutationExpr(ctx, index.object);
            try analyzeDirectMutationExpr(ctx, index.key);
        },
    }
}

fn analyzeDirectUseStmt(ctx: *DirectLocalUseContext, stmt: *const Stmt) AnalyzeDirectUseError!void {
    switch (stmt.*) {
        .local_assign => |op| {
            const deferred = try ctx.state.allocator.alloc(?[]const PendingCapturedLocal, @min(op.names.len, op.exprs.len));
            defer {
                for (deferred) |captures_opt| {
                    if (captures_opt) |captures| ctx.state.allocator.free(captures);
                }
                ctx.state.allocator.free(deferred);
            }
            @memset(deferred, null);

            for (op.exprs, 0..) |expr, idx| {
                if (idx < deferred.len and expr.* == .function_lit) {
                    const child_id = ctx.state.exprFunctionId(expr) orelse return error.UnsupportedSyntax;
                    const captures = try collectPendingCapturedLocalsAlloc(ctx.state.allocator, ctx, &ctx.state.functions.items[child_id]);
                    markPendingCapturedLocalsUsed(ctx, captures);
                    deferred[idx] = captures;
                    continue;
                }
                try analyzeDirectUseExpr(ctx, expr);
            }

            const local_ids = try ctx.state.allocator.alloc(u32, op.names.len);
            defer ctx.state.allocator.free(local_ids);
            for (op.names, 0..) |name, idx| {
                local_ids[idx] = try ctx.declareLocal(name);
            }
            for (deferred, 0..) |captures_opt, idx| {
                if (captures_opt) |captures| {
                    try ctx.pending_local_function_captures.append(ctx.state.allocator, .{
                        .local_id = local_ids[idx],
                        .captured_locals = try ctx.state.allocator.dupe(PendingCapturedLocal, captures),
                    });
                }
            }
        },
        .assign => |op| {
            for (op.exprs, 0..) |expr, idx| {
                if (idx < op.targets.len and expr.* == .function_lit and op.targets[idx] == .name) {
                    if (ctx.lookupLocal(op.targets[idx].name)) |local_id| {
                        const child_id = ctx.state.exprFunctionId(expr) orelse return error.UnsupportedSyntax;
                        const captures = try collectPendingCapturedLocalsAlloc(
                            ctx.state.allocator,
                            ctx,
                            &ctx.state.functions.items[child_id],
                        );
                        markPendingCapturedLocalsUsed(ctx, captures);
                        try ctx.pending_local_function_captures.append(ctx.state.allocator, .{
                            .local_id = local_id,
                            .captured_locals = captures,
                        });
                        continue;
                    }
                }
                try analyzeDirectUseExpr(ctx, expr);
            }
            for (op.targets) |target| {
                if (target == .name) {
                    if (ctx.lookupLocal(target.name)) |local_id| ctx.markLocalRequiresVar(local_id);
                }
                try analyzeDirectUseLValueExprs(ctx, target);
            }
        },
        .function_def => |op| {
            const child_id = ctx.state.stmtFunctionId(stmt) orelse return error.UnsupportedSyntax;
            const child_info = &ctx.state.functions.items[child_id];
            if (op.is_local and op.target == .name) {
                const local_id = try ctx.declareLocal(op.target.name);
                ctx.markLocalRequiresVar(local_id);
                var pending_captures: std.ArrayList(PendingCapturedLocal) = .empty;
                errdefer pending_captures.deinit(ctx.state.allocator);
                for (child_info.captures) |capture| {
                    if (capture.origin != .parent_local) continue;
                    const captured_local_id = ctx.lookupLocal(capture.name) orelse continue;
                    try pending_captures.append(ctx.state.allocator, .{
                        .local_id = captured_local_id,
                        .mutable = capture.mutable,
                    });
                }
                try ctx.pending_local_function_captures.append(ctx.state.allocator, .{
                    .local_id = local_id,
                    .captured_locals = try pending_captures.toOwnedSlice(ctx.state.allocator),
                });
            } else {
                if (op.target == .name) {
                    if (ctx.lookupLocal(op.target.name)) |local_id| ctx.markLocalRequiresVar(local_id);
                }
                try analyzeDirectUseLValueExprs(ctx, op.target);
                markCapturedParentLocalsUsed(ctx, child_info);
            }
        },
        .if_stmt => |op| {
            for (op.branches) |branch| {
                try analyzeDirectUseExpr(ctx, branch.condition);
                try ctx.beginScope();
                try analyzeDirectUseStmtSlice(ctx, branch.body);
                ctx.endScope();
            }
            try ctx.beginScope();
            try analyzeDirectUseStmtSlice(ctx, op.else_body);
            ctx.endScope();
        },
        .do_block => |body| {
            try ctx.beginScope();
            try analyzeDirectUseStmtSlice(ctx, body);
            ctx.endScope();
        },
        .while_stmt => |op| {
            try analyzeDirectUseExpr(ctx, op.condition);
            try ctx.beginScope();
            try analyzeDirectUseStmtSlice(ctx, op.body);
            ctx.endScope();
        },
        .repeat_stmt => |op| {
            try ctx.beginScope();
            try analyzeDirectUseStmtSlice(ctx, op.body);
            try analyzeDirectUseExpr(ctx, op.condition);
            ctx.endScope();
        },
        .numeric_for => |op| {
            try analyzeDirectUseExpr(ctx, op.start);
            try analyzeDirectUseExpr(ctx, op.finish);
            if (op.step) |step| try analyzeDirectUseExpr(ctx, step);
            try ctx.beginScope();
            const local_id = try ctx.declareLocal(op.name);
            ctx.markLocalRequiresVar(local_id);
            try analyzeDirectUseStmtSlice(ctx, op.body);
            ctx.endScope();
        },
        .generic_for => |op| {
            for (op.iterator_exprs) |expr| try analyzeDirectUseExpr(ctx, expr);
            try ctx.beginScope();
            for (op.names) |name| _ = try ctx.declareLocal(name);
            try analyzeDirectUseStmtSlice(ctx, op.body);
            ctx.endScope();
        },
        .return_stmt => |op| for (op.exprs) |expr| try analyzeDirectUseExpr(ctx, expr),
        .expr_stmt => |expr| try analyzeDirectUseExpr(ctx, expr),
        .break_stmt => {},
    }
}

fn analyzeDirectUseExpr(ctx: *DirectLocalUseContext, expr: *const Expr) AnalyzeDirectUseError!void {
    switch (expr.*) {
        .nil_lit, .bool_lit, .number_lit, .string_lit, .varargs, .const_table => {},
        .variable => |name| {
            const local_id = ctx.lookupLocal(name) orelse return;
            ctx.markLocalUsed(local_id);
        },
        .unary => |op| try analyzeDirectUseExpr(ctx, op.expr),
        .binary => |op| {
            try analyzeDirectUseExpr(ctx, op.lhs);
            try analyzeDirectUseExpr(ctx, op.rhs);
        },
        .table_ctor => |fields| {
            for (fields) |field| switch (field) {
                .array => |value| try analyzeDirectUseExpr(ctx, value),
                .named => |named| try analyzeDirectUseExpr(ctx, named.value),
                .indexed => |indexed| {
                    try analyzeDirectUseExpr(ctx, indexed.key);
                    try analyzeDirectUseExpr(ctx, indexed.value);
                },
            };
        },
        .field => |field| try analyzeDirectUseExpr(ctx, field.object),
        .index => |index| {
            try analyzeDirectUseExpr(ctx, index.object);
            try analyzeDirectUseExpr(ctx, index.key);
        },
        .call => |call| {
            try analyzeDirectUseExpr(ctx, call.callee);
            for (call.args) |arg| try analyzeDirectUseExpr(ctx, arg);
        },
        .function_lit => {
            const child_id = ctx.state.exprFunctionId(expr) orelse return error.UnsupportedSyntax;
            markCapturedParentLocalsUsed(ctx, &ctx.state.functions.items[child_id]);
        },
    }
}

fn localBindingKeyword(ctx: *const DirectEmitFunctionContext, local_id: u32) []const u8 {
    return if (ctx.local_requires_var[local_id]) "var" else "const";
}

fn localShouldEmit(ctx: *const DirectEmitFunctionContext, local_id: u32) bool {
    return ctx.local_used[local_id];
}

fn emitDirectZigModuleResultAlloc(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    options: EmitZigModuleOptions,
) anyerror!EmittedZigModule {
    var state = DirectModuleState.init(allocator, options);
    defer state.deinit();
    try analyzeDirectModule(&state, chunk.body);

    const function_capture_fact_seeds = try allocator.alloc(?[]KnownValueFact, state.functions.items.len);
    defer {
        for (function_capture_fact_seeds) |facts_opt| {
            if (facts_opt) |facts| allocator.free(facts);
        }
        allocator.free(function_capture_fact_seeds);
    }
    @memset(function_capture_fact_seeds, null);

    const function_capture_method_binding_seeds = try allocator.alloc(?[]DirectMethodBindingSeed, state.functions.items.len);
    defer {
        for (function_capture_method_binding_seeds) |bindings_opt| {
            if (bindings_opt) |bindings| allocator.free(bindings);
        }
        allocator.free(function_capture_method_binding_seeds);
    }
    @memset(function_capture_method_binding_seeds, null);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    try writer.writeAll(
        \\const std = @import("std");
        \\const lua = @import("lua");
        \\
        \\// Generated from the parsed Lua AST. Const tables are hoisted and function bodies are lowered directly to Zig.
        \\
    );

    for (state.tables.tables.items) |table| try emitDirectConstTableSeed(writer, table, &state.tables);
    try emitDirectGlobals(writer, &state);
    for (state.functions.items) |info| {
        if (info.captures.len != 0) try emitDirectCaptureStruct(writer, &info);
    }
    for (state.functions.items) |info| try emitDirectFunction(
        writer,
        &state,
        &info,
        function_capture_fact_seeds,
        function_capture_method_binding_seeds,
    );
    if (state.options.emit_local_dispatch_helper) try emitDirectDispatchHelper(writer, &state);
    try emitDirectRun(writer, &state);
    const raw_source = try out.toOwnedSlice();
    errdefer allocator.free(raw_source);
    const source = try stripUnusedGeneratedArtifactsAlloc(allocator, raw_source);
    errdefer allocator.free(source);

    var exports: std.ArrayList(GeneratedModuleExportInfo) = .empty;
    errdefer {
        for (exports.items) |export_info| allocator.free(export_info.name);
        exports.deinit(allocator);
    }
    for (state.method_names.items, 0..) |name, idx| {
        const callable_id = state.method_callable_ids.items[idx] orelse continue;
        if (callable_id < state.options.callable_id_base) continue;
        try exports.append(allocator, .{
            .export_id = @intCast(idx),
            .name = try allocator.dupe(u8, name),
            .callable_id = callable_id,
            .fn_id = callable_id - state.options.callable_id_base,
        });
    }

    return .{
        .source = source,
        .exports = try exports.toOwnedSlice(allocator),
        .top_id = state.top_id,
        .function_count = @intCast(state.functions.items.len),
    };
}

fn emitDirectGlobals(writer: anytype, state: *const DirectModuleState) anyerror!void {
    try writer.writeAll("const Globals = struct {\n");
    for (state.globals.items, 0..) |name, idx| {
        try writer.writeAll("    // Lua global: ");
        try writer.writeAll(name);
        try writer.writeAll("\n    ");
        try emitGlobalFieldIdentifier(writer, state, @intCast(idx));
        try writer.writeAll(": lua.Value = lua.Value.nil,\n");
    }
    try writer.writeAll("};\n\n");
}

fn emitDirectCaptureStruct(writer: anytype, info: *const DirectFunctionInfo) anyerror!void {
    try writer.print("const Capture_{d} = struct {{\n", .{info.id});
    for (info.captures, 0..) |capture, idx| {
        try writer.writeAll("    // Lua capture: ");
        try writer.writeAll(capture.name);
        try writer.writeAll("\n    ");
        try emitGeneratedIdentifier(writer, "lua_capture_", capture.name, idx);
        try writer.print(": *{s}lua.Value,\n", .{if (capture.mutable) "" else "const "});
    }
    try writer.writeAll("};\n\n");
}

fn emitDirectRun(writer: anytype, state: *const DirectModuleState) anyerror!void {
    try writer.writeAll(
        \\pub fn initRuntimeGlobals(runtime: *lua.GeneratedRuntime) !*Globals {
        \\    const globals = try runtime.alloc().create(Globals);
        \\    globals.* = .{};
        \\
    );
    for (state.globals.items, 0..) |name, idx| {
        _ = try emitBuiltinGlobalInit(writer, state, name, idx);
    }
    try writer.writeAll(
        \\    return globals;
        \\}
        \\
    );
    if (!state.options.emit_run_entry_points) return;
    try writer.writeAll(
        \\pub fn runInRuntimeWithGlobals(runtime: *lua.GeneratedRuntime, globals: *Globals) ![]lua.Value {
        \\    return try fn_
    );
    try writer.print("{d}", .{state.top_id});
    try writer.writeAll(
        \\(null, globals, runtime, &.{});
        \\}
        \\
        \\pub fn runInRuntime(runtime: *lua.GeneratedRuntime) ![]lua.Value {
        \\    const globals = try initRuntimeGlobals(runtime);
        \\    return try runInRuntimeWithGlobals(runtime, globals);
        \\}
        \\
        \\pub fn run(allocator: std.mem.Allocator) !lua.GeneratedRunResult {
        \\    var runtime = lua.GeneratedRuntime.init(allocator);
        \\    errdefer runtime.deinit();
        \\    const returns = try runInRuntime(&runtime);
        \\    return .{
        \\        .runtime = runtime,
        \\        .returns = returns,
        \\    };
        \\}
        \\
    );
}

const KnownCallableSource = union(enum) {
    none,
    temp: u32,
    binding: DirectMethodBindingSource,
    expr: *const Expr,
};

fn localFunctionIdForGeneratedCallable(state: *const DirectModuleState, callable_id: u32) ?u32 {
    const base = state.options.callable_id_base;
    if (callable_id < base) return null;
    const function_id = callable_id - base;
    if (function_id >= state.functions.items.len) return null;
    return function_id;
}

fn generatedCallableNeedsSource(state: *const DirectModuleState, callable_id: u32) bool {
    const function_id = localFunctionIdForGeneratedCallable(state, callable_id) orelse return false;
    return state.functions.items[function_id].captures.len != 0;
}

fn uniqueMethodCallableId(state: *const DirectModuleState, name: []const u8) ?u32 {
    const method_id = state.methodIdConst(name) orelse return null;
    return state.method_callable_ids.items[method_id];
}

fn canDirectCallFunctionFromContext(ctx: *const DirectEmitFunctionContext, function_id: u32) bool {
    const info = &ctx.state.functions.items[function_id];
    for (info.captures) |capture| switch (capture.origin) {
        .parent_local => if (ctx.lookupLocal(capture.name) == null) return false,
        .parent_capture => if (ctx.lookupCapture(capture.name) == null) return false,
    };
    return true;
}

fn emitKnownCallableSourceExpr(
    writer: anytype,
    ctx: *DirectEmitFunctionContext,
    source: KnownCallableSource,
    depth: usize,
) !void {
    switch (source) {
        .none => try writer.writeAll("lua.Value.nil"),
        .temp => |temp_id| try writer.print("tmp_{d}", .{temp_id}),
        .binding => |binding| try emitMethodBindingSourceExpr(writer, ctx, binding),
        .expr => |expr| try emitExpr(writer, ctx, expr, depth),
    }
}

fn emitKnownCallableArgsList(
    writer: anytype,
    ctx: *DirectEmitFunctionContext,
    receiver_temp_id: ?u32,
    args: []const *Expr,
    depth: usize,
) !void {
    try writer.writeAll("&.{");
    if (receiver_temp_id) |temp_id| {
        try writer.print(" tmp_{d}", .{temp_id});
        if (args.len != 0) try writer.writeAll(",");
    }
    for (args, 0..) |arg, idx| {
        if (idx != 0 or receiver_temp_id != null) try writer.writeAll(" ");
        try emitExpr(writer, ctx, arg, depth);
        if (idx + 1 != args.len) try writer.writeAll(",");
    }
    try writer.writeAll(" }");
}

fn emitDirectKnownCallableFirst(
    writer: anytype,
    ctx: *DirectEmitFunctionContext,
    callable_id: u32,
    source: KnownCallableSource,
    receiver_temp_id: ?u32,
    args: []const *Expr,
    depth: usize,
) !void {
    if (localFunctionIdForGeneratedCallable(ctx.state, callable_id)) |function_id| {
        if (source == .none) {
            try emitDirectFunctionCall(writer, ctx, function_id, receiver_temp_id, args, depth);
            return;
        }
        const label_id = ctx.nextTemp();
        const generated_id = ctx.nextTemp();
        try writer.print("blk_{d}: {{ const tmp_{d}: lua.GeneratedCallable = switch (", .{
            label_id,
            generated_id,
        });
        try emitKnownCallableSourceExpr(writer, ctx, source, depth);
        try writer.writeAll(") { .generated_callable => |value| value, else => return error.InvalidCall, }; break :blk_");
        try writer.print("{d}", .{label_id});
        try writer.writeAll(" lua.generatedResultsFirst(try fn_");
        try writer.print("{d}", .{function_id});
        try writer.print("(tmp_{d}.capture, tmp_{d}.globals, runtime, ", .{
            generated_id,
            generated_id,
        });
        try emitKnownCallableArgsList(writer, ctx, receiver_temp_id, args, depth);
        try writer.writeAll(")); }");
        return;
    }

    if (callable_id == generated_callable_id_builtin_print) {
        const label_id = ctx.nextTemp();
        try writer.print("blk_{d}: {{ _ = try lua.generatedPrint(runtime, ", .{label_id});
        try emitKnownCallableArgsList(writer, ctx, receiver_temp_id, args, depth);
        try writer.print("); break :blk_{d} lua.Value.nil; }}", .{label_id});
        return;
    }
    if (callable_id == generated_callable_id_builtin_tostring) {
        try writer.writeAll("try lua.generatedTostring(runtime, ");
        if (receiver_temp_id) |temp_id| {
            try writer.print("tmp_{d}", .{temp_id});
        } else if (args.len != 0) {
            try emitExpr(writer, ctx, args[0], depth);
        } else {
            try writer.writeAll("lua.Value.nil");
        }
        try writer.writeAll(")");
        return;
    }
    if (callable_id == generated_callable_id_builtin_tonumber) {
        if (receiver_temp_id) |temp_id| {
            try writer.print("try lua.generatedTonumber(tmp_{d})", .{temp_id});
        } else if (args.len != 0) {
            try writer.writeAll("try lua.generatedTonumber(");
            try emitExpr(writer, ctx, args[0], depth);
            try writer.writeAll(")");
        } else {
            try writer.writeAll("lua.Value.nil");
        }
        return;
    }
    if (callable_id == generated_callable_id_builtin_type) {
        try writer.writeAll("lua.generatedType(");
        if (receiver_temp_id) |temp_id| {
            try writer.print("tmp_{d}", .{temp_id});
        } else if (args.len != 0) {
            try emitExpr(writer, ctx, args[0], depth);
        } else {
            try writer.writeAll("lua.Value.nil");
        }
        try writer.writeAll(")");
        return;
    }
    if (callable_id == generated_callable_id_builtin_unpack) {
        try writer.writeAll("lua.generatedResultsFirst(try lua.generatedTableUnpack(runtime, ");
        if (receiver_temp_id) |temp_id| {
            try writer.print("tmp_{d}", .{temp_id});
        } else if (args.len != 0) {
            try emitExpr(writer, ctx, args[0], depth);
        } else {
            try writer.writeAll("lua.Value.nil");
        }
        try writer.writeAll("))");
        return;
    }
    if (callable_id == generated_callable_id_builtin_pairs) {
        try writer.writeAll(".{ .iterator = try lua.generatedPairsIterator(");
        if (receiver_temp_id) |temp_id| {
            try writer.print("tmp_{d}", .{temp_id});
        } else if (args.len != 0) {
            try emitExpr(writer, ctx, args[0], depth);
        } else {
            try writer.writeAll("lua.Value.nil");
        }
        try writer.writeAll(") }");
        return;
    }
    if (callable_id == generated_callable_id_builtin_ipairs) {
        try writer.writeAll(".{ .iterator = try lua.generatedIpairsIterator(");
        if (receiver_temp_id) |temp_id| {
            try writer.print("tmp_{d}", .{temp_id});
        } else if (args.len != 0) {
            try emitExpr(writer, ctx, args[0], depth);
        } else {
            try writer.writeAll("lua.Value.nil");
        }
        try writer.writeAll(") }");
        return;
    }
    if (callable_id == generated_callable_id_builtin_string_len) {
        try writer.writeAll("try lua.generatedStringLen(");
        if (receiver_temp_id) |temp_id| {
            try writer.print("tmp_{d}", .{temp_id});
        } else if (args.len != 0) {
            try emitExpr(writer, ctx, args[0], depth);
        } else {
            try writer.writeAll("lua.Value.nil");
        }
        try writer.writeAll(")");
        return;
    }
    if (callable_id == generated_callable_id_builtin_string_lower) {
        try writer.writeAll("try lua.generatedStringLower(runtime, ");
        if (receiver_temp_id) |temp_id| {
            try writer.print("tmp_{d}", .{temp_id});
        } else if (args.len != 0) {
            try emitExpr(writer, ctx, args[0], depth);
        } else {
            try writer.writeAll("lua.Value.nil");
        }
        try writer.writeAll(")");
        return;
    }
    if (callable_id == generated_callable_id_builtin_string_upper) {
        try writer.writeAll("try lua.generatedStringUpper(runtime, ");
        if (receiver_temp_id) |temp_id| {
            try writer.print("tmp_{d}", .{temp_id});
        } else if (args.len != 0) {
            try emitExpr(writer, ctx, args[0], depth);
        } else {
            try writer.writeAll("lua.Value.nil");
        }
        try writer.writeAll(")");
        return;
    }
    if (callable_id == generated_callable_id_builtin_string_sub) {
        try writer.writeAll("try lua.generatedStringSub(runtime, ");
        if (receiver_temp_id) |temp_id| {
            try writer.print("tmp_{d}", .{temp_id});
        } else if (args.len != 0) {
            try emitExpr(writer, ctx, args[0], depth);
        } else {
            try writer.writeAll("lua.Value.nil");
        }
        try writer.writeAll(", ");
        if (args.len > 1) {
            try emitExpr(writer, ctx, args[1], depth);
        } else {
            try writer.writeAll("lua.Value.nil");
        }
        try writer.writeAll(", ");
        if (args.len > 2) {
            try emitExpr(writer, ctx, args[2], depth);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(")");
        return;
    }
    if (callable_id == generated_callable_id_builtin_string_gsub) {
        try writer.writeAll("try lua.generatedStringGsub(runtime, ");
        if (receiver_temp_id) |temp_id| {
            try writer.print("tmp_{d}", .{temp_id});
        } else if (args.len != 0) {
            try emitExpr(writer, ctx, args[0], depth);
        } else {
            try writer.writeAll("lua.Value.nil");
        }
        try writer.writeAll(", ");
        if (args.len > 1) {
            try emitExpr(writer, ctx, args[1], depth);
        } else {
            try writer.writeAll("lua.Value.nil");
        }
        try writer.writeAll(", ");
        if (args.len > 2) {
            try emitExpr(writer, ctx, args[2], depth);
        } else {
            try writer.writeAll("lua.Value.nil");
        }
        try writer.writeAll(")");
        return;
    }
    if (callable_id == generated_callable_id_builtin_math_floor) {
        try writer.writeAll("try lua.generatedMathFloor(");
        if (receiver_temp_id) |temp_id| {
            try writer.print("tmp_{d}", .{temp_id});
        } else if (args.len != 0) {
            try emitExpr(writer, ctx, args[0], depth);
        } else {
            try writer.writeAll("lua.Value.nil");
        }
        try writer.writeAll(")");
        return;
    }
    if (callable_id == generated_callable_id_builtin_math_ceil) {
        try writer.writeAll("try lua.generatedMathCeil(");
        if (receiver_temp_id) |temp_id| {
            try writer.print("tmp_{d}", .{temp_id});
        } else if (args.len != 0) {
            try emitExpr(writer, ctx, args[0], depth);
        } else {
            try writer.writeAll("lua.Value.nil");
        }
        try writer.writeAll(")");
        return;
    }
    if (callable_id == generated_callable_id_builtin_math_abs) {
        try writer.writeAll("try lua.generatedMathAbs(");
        if (receiver_temp_id) |temp_id| {
            try writer.print("tmp_{d}", .{temp_id});
        } else if (args.len != 0) {
            try emitExpr(writer, ctx, args[0], depth);
        } else {
            try writer.writeAll("lua.Value.nil");
        }
        try writer.writeAll(")");
        return;
    }
    if (callable_id == generated_callable_id_builtin_table_insert) {
        try writer.writeAll("try lua.generatedTableInsert(");
        if (receiver_temp_id) |temp_id| {
            try writer.print("tmp_{d}", .{temp_id});
        } else if (args.len != 0) {
            try emitExpr(writer, ctx, args[0], depth);
        } else {
            try writer.writeAll("lua.Value.nil");
        }
        try writer.writeAll(", ");
        if (args.len > 1) {
            try emitExpr(writer, ctx, args[1], depth);
        } else {
            try writer.writeAll("lua.Value.nil");
        }
        try writer.writeAll(")");
        return;
    }
    if (callable_id == generated_callable_id_builtin_table_remove) {
        try writer.writeAll("try lua.generatedTableRemove(");
        if (receiver_temp_id) |temp_id| {
            try writer.print("tmp_{d}", .{temp_id});
        } else if (args.len != 0) {
            try emitExpr(writer, ctx, args[0], depth);
        } else {
            try writer.writeAll("lua.Value.nil");
        }
        try writer.writeAll(", ");
        if (args.len > 1) {
            try emitExpr(writer, ctx, args[1], depth);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(")");
        return;
    }
    if (callable_id == generated_callable_id_builtin_table_sort) {
        try writer.writeAll("blk: { _ = try lua.generatedTableSort(");
        if (receiver_temp_id) |temp_id| {
            try writer.print("tmp_{d}", .{temp_id});
        } else if (args.len != 0) {
            try emitExpr(writer, ctx, args[0], depth);
        } else {
            try writer.writeAll("lua.Value.nil");
        }
        try writer.writeAll("); break :blk lua.Value.nil; }");
        return;
    }
    if (callable_id == generated_callable_id_builtin_table_unpack) {
        try writer.writeAll("lua.generatedResultsFirst(try lua.generatedTableUnpack(runtime, ");
        if (receiver_temp_id) |temp_id| {
            try writer.print("tmp_{d}", .{temp_id});
        } else if (args.len != 0) {
            try emitExpr(writer, ctx, args[0], depth);
        } else {
            try writer.writeAll("lua.Value.nil");
        }
        try writer.writeAll("))");
        return;
    }
    if (callable_id == generated_callable_id_builtin_table_concat) {
        try writer.writeAll("try lua.generatedTableConcat(runtime, ");
        if (receiver_temp_id) |temp_id| {
            try writer.print("tmp_{d}", .{temp_id});
        } else if (args.len != 0) {
            try emitExpr(writer, ctx, args[0], depth);
        } else {
            try writer.writeAll("lua.Value.nil");
        }
        try writer.writeAll(", ");
        if (args.len > 1) {
            try emitExpr(writer, ctx, args[1], depth);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(")");
        return;
    }
    if (callable_id == generated_callable_id_frame_get_parent) {
        try writer.writeAll("lua.generatedResultsFirst(try lua.generatedFrameGetParent(null, null, runtime, ");
        try emitKnownCallableArgsList(writer, ctx, receiver_temp_id, args, depth);
        try writer.writeAll("))");
        return;
    }
    if (callable_id == generated_callable_id_frame_expand_template) {
        try writer.writeAll("lua.generatedResultsFirst(try lua.generatedFrameExpandTemplate(null, null, runtime, ");
        try emitKnownCallableArgsList(writer, ctx, receiver_temp_id, args, depth);
        try writer.writeAll("))");
        return;
    }
    if (callable_id == generated_callable_id_frame_preprocess) {
        try writer.writeAll("lua.generatedResultsFirst(try lua.generatedFramePreprocess(null, null, runtime, ");
        try emitKnownCallableArgsList(writer, ctx, receiver_temp_id, args, depth);
        try writer.writeAll("))");
        return;
    }
    if (ctx.state.options.enable_direct_module_dispatch and callable_id == generated_callable_id_module_require) {
        try writer.writeAll("lua.generatedResultsFirst(try generatedModuleRequireFn(null, null, runtime, ");
        try emitKnownCallableArgsList(writer, ctx, receiver_temp_id, args, depth);
        try writer.writeAll("))");
        return;
    }
    if (ctx.state.options.enable_direct_module_dispatch and callable_id == generated_callable_id_module_load_data) {
        try writer.writeAll("lua.generatedResultsFirst(try generatedModuleLoadDataFn(null, null, runtime, ");
        try emitKnownCallableArgsList(writer, ctx, receiver_temp_id, args, depth);
        try writer.writeAll("))");
        return;
    }
    if (callable_id == generated_callable_id_mw_get_current_frame) {
        try writer.writeAll("lua.generatedResultsFirst(try lua.generatedMwGetCurrentFrame(null, null, runtime, ");
        try emitKnownCallableArgsList(writer, ctx, receiver_temp_id, args, depth);
        try writer.writeAll("))");
        return;
    }
    if (callable_id == generated_callable_id_mw_get_content_language) {
        try writer.writeAll("lua.generatedResultsFirst(try lua.generatedMwGetContentLanguage(null, null, runtime, ");
        try emitKnownCallableArgsList(writer, ctx, receiver_temp_id, args, depth);
        try writer.writeAll("))");
        return;
    }
    if (callable_id == generated_callable_id_mw_dump_object) {
        try writer.writeAll("lua.generatedResultsFirst(try lua.generatedMwDumpObject(null, null, runtime, ");
        try emitKnownCallableArgsList(writer, ctx, receiver_temp_id, args, depth);
        try writer.writeAll("))");
        return;
    }
    if (callable_id == generated_callable_id_content_language_ucfirst) {
        try writer.writeAll("lua.generatedResultsFirst(try lua.generatedContentLanguageUcfirst(null, null, runtime, ");
        try emitKnownCallableArgsList(writer, ctx, receiver_temp_id, args, depth);
        try writer.writeAll("))");
        return;
    }
    return error.InvalidCall;
}

fn emitDirectDispatchHelper(writer: anytype, state: *const DirectModuleState) anyerror!void {
    try writer.writeAll("fn ");
    try writer.writeAll(state.options.call_dispatch_helper_name);
    try writer.writeAll(
        \\(runtime: *lua.GeneratedRuntime, callee: lua.Value, args: []const lua.Value) !lua.Value {
        \\    const generated = switch (callee) {
        \\        .generated_callable => |value| value,
        \\        else => return error.InvalidCall,
        \\    };
        \\    return switch (generated.id) {
        \\
    );
    for (state.functions.items) |info| {
        try writer.writeAll("        ");
        try emitGeneratedCallableIdLiteral(writer, state, info.id, .function);
        try writer.writeAll(" => lua.generatedResultsFirst(try fn_");
        try writer.print("{d}", .{info.id});
        try writer.writeAll("(generated.capture, generated.globals, runtime, args)),\n");
    }
    if (state.options.enable_direct_module_dispatch) {
        try writer.writeAll("        ");
        try emitGeneratedCallableIdLiteral(writer, state, 0, .require);
        try writer.writeAll(
            \\ => lua.generatedResultsFirst(try generatedModuleRequireFn(
            \\            generated.capture,
            \\            generated.globals,
            \\            runtime,
            \\            args,
            \\        )),
            \\
        );
        try writer.writeAll("        ");
        try emitGeneratedCallableIdLiteral(writer, state, 0, .load_data);
        try writer.writeAll(
            \\ => lua.generatedResultsFirst(try generatedModuleLoadDataFn(
            \\            generated.capture,
            \\            generated.globals,
            \\            runtime,
            \\            args,
            \\        )),
            \\
        );
    }
    try writer.writeAll(
        \\        else => if (try lua.generatedDispatchKnownRuntimeFirst(runtime, callee, args)) |first| first else error.InvalidCall,
        \\    };
        \\}
        \\
    );
}

fn emitBuiltinGlobalInit(writer: anytype, state: *const DirectModuleState, name: []const u8, idx: usize) anyerror!bool {
    if (state.options.enable_direct_module_dispatch and std.mem.eql(u8, name, "require")) {
        try writer.writeAll("    globals.");
        try emitGlobalFieldIdentifier(writer, state, @intCast(idx));
        try writer.writeAll(" = runtime.generatedCallableValue(");
        try emitGeneratedCallableIdLiteral(writer, state, 0, .require);
        try writer.writeAll(", null, globals);\n");
        return true;
    }
    if (state.options.enable_direct_module_dispatch and std.mem.eql(u8, name, "mw")) {
        try writer.writeAll("    globals.");
        try emitGlobalFieldIdentifier(writer, state, @intCast(idx));
        try writer.writeAll(" = try generatedModuleMwTableValue(runtime, globals);\n");
        return true;
    }
    if (std.mem.eql(u8, name, "print")) {
        try writer.writeAll("    globals.");
        try emitGlobalFieldIdentifier(writer, state, @intCast(idx));
        try writer.writeAll(" = try lua.generatedBuiltinPrintValue(runtime, globals);\n");
        return true;
    }
    if (std.mem.eql(u8, name, "tostring")) {
        try writer.writeAll("    globals.");
        try emitGlobalFieldIdentifier(writer, state, @intCast(idx));
        try writer.writeAll(" = try lua.generatedBuiltinTostringValue(runtime, globals);\n");
        return true;
    }
    if (std.mem.eql(u8, name, "tonumber")) {
        try writer.writeAll("    globals.");
        try emitGlobalFieldIdentifier(writer, state, @intCast(idx));
        try writer.writeAll(" = try lua.generatedBuiltinTonumberValue(runtime, globals);\n");
        return true;
    }
    if (std.mem.eql(u8, name, "type")) {
        try writer.writeAll("    globals.");
        try emitGlobalFieldIdentifier(writer, state, @intCast(idx));
        try writer.writeAll(" = try lua.generatedBuiltinTypeValue(runtime, globals);\n");
        return true;
    }
    if (std.mem.eql(u8, name, "unpack")) {
        try writer.writeAll("    globals.");
        try emitGlobalFieldIdentifier(writer, state, @intCast(idx));
        try writer.writeAll(" = try lua.generatedBuiltinUnpackValue(runtime, globals);\n");
        return true;
    }
    if (std.mem.eql(u8, name, "pairs")) {
        try writer.writeAll("    globals.");
        try emitGlobalFieldIdentifier(writer, state, @intCast(idx));
        try writer.writeAll(" = try lua.generatedBuiltinPairsValue(runtime, globals);\n");
        return true;
    }
    if (std.mem.eql(u8, name, "ipairs")) {
        try writer.writeAll("    globals.");
        try emitGlobalFieldIdentifier(writer, state, @intCast(idx));
        try writer.writeAll(" = try lua.generatedBuiltinIpairsValue(runtime, globals);\n");
        return true;
    }
    if (std.mem.eql(u8, name, "string")) {
        try writer.writeAll("    globals.");
        try emitGlobalFieldIdentifier(writer, state, @intCast(idx));
        try writer.writeAll(" = try lua.generatedBuiltinStringTableValue(runtime, globals);\n");
        return true;
    }
    if (std.mem.eql(u8, name, "math")) {
        try writer.writeAll("    globals.");
        try emitGlobalFieldIdentifier(writer, state, @intCast(idx));
        try writer.writeAll(" = try lua.generatedBuiltinMathTableValue(runtime, globals);\n");
        return true;
    }
    if (std.mem.eql(u8, name, "table")) {
        try writer.writeAll("    globals.");
        try emitGlobalFieldIdentifier(writer, state, @intCast(idx));
        try writer.writeAll(" = try lua.generatedBuiltinTableTableValue(runtime, globals);\n");
        return true;
    }
    return false;
}

fn emitDirectConstTableSeed(writer: anytype, table: *const Table, state: *const TableSeedState) anyerror!void {
    const id = state.tableId(table) orelse return error.UnsupportedSyntax;
    try writer.print("const const_table_{d}_array = [_]lua.ConstValueSeed{{\n", .{id});
    for (table.array.items) |value| {
        try writer.writeAll("    ");
        try emitDirectConstValueSeed(writer, value, state);
        try writer.writeAll(",\n");
    }
    try writer.writeAll("};\n");

    try writer.print("const const_table_{d}_string_fields = [_]lua.ConstTableStringFieldSeed{{\n", .{id});
    var string_it = table.string_fields.iterator();
    while (string_it.next()) |entry| {
        try writer.writeAll("    .{ .key = ");
        try writeZigStringLiteral(writer, entry.key_ptr.*);
        try writer.writeAll(", .value = ");
        try emitDirectConstValueSeed(writer, entry.value_ptr.*, state);
        try writer.writeAll(" },\n");
    }
    try writer.writeAll("};\n");

    try writer.print("const const_table_{d}_int_fields = [_]lua.ConstTableIntFieldSeed{{\n", .{id});
    var int_it = table.int_fields.iterator();
    while (int_it.next()) |entry| {
        try writer.print("    .{{ .key = {d}, .value = ", .{entry.key_ptr.*});
        try emitDirectConstValueSeed(writer, entry.value_ptr.*, state);
        try writer.writeAll(" },\n");
    }
    try writer.writeAll("};\n");
    try writer.print(
        "const const_table_{d} = lua.ConstTableSeed{{ .array = &const_table_{d}_array, .string_fields = &const_table_{d}_string_fields, .int_fields = &const_table_{d}_int_fields }};\n\n",
        .{ id, id, id, id },
    );
}

fn emitDirectConstValueSeed(writer: anytype, value: Value, state: *const TableSeedState) anyerror!void {
    switch (value) {
        .nil => try writer.writeAll(".nil"),
        .boolean => |flag| try writer.print(".{{ .boolean = {} }}", .{flag}),
        .number => |number| {
            try writer.writeAll(".{ .number = ");
            try emitZigNumberLiteral(writer, number);
            try writer.writeAll(" }");
        },
        .string => |text| {
            try writer.writeAll(".{ .string = ");
            try writeZigStringLiteral(writer, text);
            try writer.writeAll(" }");
        },
        .table => |table| try writer.print(".{{ .table = &const_table_{d} }}", .{state.tableId(table).?}),
        .generated_callable, .function, .iterator => return error.UnsupportedSyntax,
    }
}

fn emitBytecodeModuleSourceAllocImpl(
    allocator: std.mem.Allocator,
    module_name: []const u8,
    chunk: *const Chunk,
    exports: []const GeneratedModuleExportInfo,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    var tables = TableSeedState.init(allocator);
    defer tables.deinit();
    for (chunk.body) |stmt| try tables.collectStmt(stmt);
    for (tables.tables.items) |table| try emitDirectConstTableSeed(writer, table, &tables);

    try writer.writeAll(
        \\// Generated from the parsed Lua AST. This bytecode mode keeps the Lua
        \\// module in a compiled tree form and executes it through the shared VM.
        \\
        \\pub fn renderExport(
        \\    out: *std.ArrayList(u8),
        \\    allocator: std.mem.Allocator,
        \\    comptime export_id: u16,
        \\    args: *const support.TemplateArgs,
        \\) !void {
        \\    const function_name = switch (comptime export_id) {
        \\
    );
    for (exports) |export_info| {
        try writer.writeAll("        ");
        try writer.print("{d}", .{export_info.export_id});
        try writer.writeAll(" => ");
        try writeZigStringLiteral(writer, export_info.name);
        try writer.writeAll(",\n");
    }
    try writer.writeAll(
        \\        else => return,
        \\    };
        \\    var chunk = try buildChunk(allocator);
        \\    defer chunk.deinit();
        \\    const lua_args = try support.templateArgsToLuaArgsAlloc(allocator, args);
        \\    defer allocator.free(lua_args);
        \\    const rendered = lua.runCompiledModuleFunctionAlloc(allocator, &chunk, function_name, lua_args) catch return;
        \\    defer allocator.free(rendered);
        \\    try support.appendText(out, allocator, rendered);
        \\}
        \\
        \\fn buildChunk(allocator: std.mem.Allocator) !lua.Chunk {
        \\    var arena = std.heap.ArenaAllocator.init(allocator);
        \\    errdefer arena.deinit();
        \\    const a = arena.allocator();
        \\
    );

    var state = BytecodeAstEmitState.init(allocator, &tables);
    defer state.deinit();
    const body_name = try emitBytecodeStmtSliceAlloc(writer, &state, chunk.body);
    defer allocator.free(body_name);

    try writer.writeAll("    return .{ .arena = arena, .source = ");
    try writeZigStringLiteral(writer, module_name);
    try writer.writeAll(", .body = ");
    try writer.writeAll(body_name);
    try writer.writeAll(" };\n}\n");

    return out.toOwnedSlice();
}

const BytecodeAstEmitState = struct {
    allocator: std.mem.Allocator,
    tables: *const TableSeedState,
    next_id: usize = 0,

    fn init(allocator: std.mem.Allocator, tables: *const TableSeedState) BytecodeAstEmitState {
        return .{ .allocator = allocator, .tables = tables };
    }

    fn deinit(_: *BytecodeAstEmitState) void {}

    fn nextName(self: *BytecodeAstEmitState, prefix: []const u8) ![]u8 {
        defer self.next_id += 1;
        return std.fmt.allocPrint(self.allocator, "{s}_{d}", .{ prefix, self.next_id });
    }
};

fn emitBytecodeStringSliceAlloc(
    writer: anytype,
    state: *BytecodeAstEmitState,
    values: []const []const u8,
) anyerror![]u8 {
    const name = try state.nextName("strings");
    errdefer state.allocator.free(name);
    try writer.writeAll("    const ");
    try writer.writeAll(name);
    try writer.print(" = try a.alloc([]const u8, {d});\n", .{values.len});
    for (values, 0..) |value, idx| {
        try writer.writeAll("    ");
        try writer.writeAll(name);
        try writer.print("[{d}] = ", .{idx});
        try writeZigStringLiteral(writer, value);
        try writer.writeAll(";\n");
    }
    return name;
}

fn emitBytecodeExprAlloc(
    writer: anytype,
    state: *BytecodeAstEmitState,
    expr: *const Expr,
) anyerror![]u8 {
    const name = try state.nextName("expr");
    errdefer state.allocator.free(name);
    try writer.writeAll("    const ");
    try writer.writeAll(name);
    try writer.writeAll(" = try a.create(lua.Expr);\n");
    switch (expr.*) {
        .nil_lit => {
            try writer.writeAll("    ");
            try writer.writeAll(name);
            try writer.writeAll(".* = .nil_lit;\n");
        },
        .bool_lit => |value| {
            try writer.writeAll("    ");
            try writer.writeAll(name);
            try writer.writeAll(".* = .{ .bool_lit = ");
            try writer.print("{}", .{value});
            try writer.writeAll(" };\n");
        },
        .number_lit => |value| {
            try writer.writeAll("    ");
            try writer.writeAll(name);
            try writer.writeAll(".* = .{ .number_lit = ");
            try emitZigNumberLiteral(writer, value);
            try writer.writeAll(" };\n");
        },
        .string_lit => |value| {
            try writer.writeAll("    ");
            try writer.writeAll(name);
            try writer.writeAll(".* = .{ .string_lit = ");
            try writeZigStringLiteral(writer, value);
            try writer.writeAll(" };\n");
        },
        .variable => |value| {
            try writer.writeAll("    ");
            try writer.writeAll(name);
            try writer.writeAll(".* = .{ .variable = ");
            try writeZigStringLiteral(writer, value);
            try writer.writeAll(" };\n");
        },
        .varargs => {
            try writer.writeAll("    ");
            try writer.writeAll(name);
            try writer.writeAll(".* = .varargs;\n");
        },
        .unary => |op| {
            const child = try emitBytecodeExprAlloc(writer, state, op.expr);
            defer state.allocator.free(child);
            try writer.writeAll("    ");
            try writer.writeAll(name);
            try writer.writeAll(".* = .{ .unary = .{ .op = .");
            try writer.writeAll(@tagName(op.op));
            try writer.writeAll(", .expr = ");
            try writer.writeAll(child);
            try writer.writeAll(" } };\n");
        },
        .binary => |op| {
            const lhs = try emitBytecodeExprAlloc(writer, state, op.lhs);
            defer state.allocator.free(lhs);
            const rhs = try emitBytecodeExprAlloc(writer, state, op.rhs);
            defer state.allocator.free(rhs);
            try writer.writeAll("    ");
            try writer.writeAll(name);
            try writer.writeAll(".* = .{ .binary = .{ .op = .");
            try writer.writeAll(@tagName(op.op));
            try writer.writeAll(", .lhs = ");
            try writer.writeAll(lhs);
            try writer.writeAll(", .rhs = ");
            try writer.writeAll(rhs);
            try writer.writeAll(" } };\n");
        },
        .table_ctor => |fields| {
            const fields_name = try state.nextName("fields");
            defer state.allocator.free(fields_name);
            try writer.writeAll("    const ");
            try writer.writeAll(fields_name);
            try writer.print(" = try a.alloc(lua.TableField, {d});\n", .{fields.len});
            for (fields, 0..) |field, idx| switch (field) {
                .array => |child| {
                    const child_name = try emitBytecodeExprAlloc(writer, state, child);
                    defer state.allocator.free(child_name);
                    try writer.writeAll("    ");
                    try writer.writeAll(fields_name);
                    try writer.print("[{d}] = .{{ .array = {s} }};\n", .{ idx, child_name });
                },
                .named => |named| {
                    const value_name = try emitBytecodeExprAlloc(writer, state, named.value);
                    defer state.allocator.free(value_name);
                    try writer.writeAll("    ");
                    try writer.writeAll(fields_name);
                    try writer.print("[{d}] = .{{ .named = .{{ .name = ", .{idx});
                    try writeZigStringLiteral(writer, named.name);
                    try writer.writeAll(", .value = ");
                    try writer.writeAll(value_name);
                    try writer.writeAll(" } } };\n");
                },
                .indexed => |indexed| {
                    const key_name = try emitBytecodeExprAlloc(writer, state, indexed.key);
                    defer state.allocator.free(key_name);
                    const value_name = try emitBytecodeExprAlloc(writer, state, indexed.value);
                    defer state.allocator.free(value_name);
                    try writer.writeAll("    ");
                    try writer.writeAll(fields_name);
                    try writer.print("[{d}] = .{{ .indexed = .{{ .key = {s}, .value = {s} }} }};\n", .{ idx, key_name, value_name });
                },
            };
            try writer.writeAll("    ");
            try writer.writeAll(name);
            try writer.writeAll(".* = .{ .table_ctor = ");
            try writer.writeAll(fields_name);
            try writer.writeAll(" };\n");
        },
        .const_table => |table| {
            try writer.writeAll("    ");
            try writer.writeAll(name);
            try writer.writeAll(".* = .{ .const_table = try lua.cloneConstTableSeedAlloc(a, &const_table_");
            try writer.print("{d}", .{state.tables.tableId(table).?});
            try writer.writeAll(") };\n");
        },
        .field => |field| {
            const object_name = try emitBytecodeExprAlloc(writer, state, field.object);
            defer state.allocator.free(object_name);
            try writer.writeAll("    ");
            try writer.writeAll(name);
            try writer.writeAll(".* = .{ .field = .{ .object = ");
            try writer.writeAll(object_name);
            try writer.writeAll(", .name = ");
            try writeZigStringLiteral(writer, field.name);
            try writer.writeAll(" } };\n");
        },
        .index => |index| {
            const object_name = try emitBytecodeExprAlloc(writer, state, index.object);
            defer state.allocator.free(object_name);
            const key_name = try emitBytecodeExprAlloc(writer, state, index.key);
            defer state.allocator.free(key_name);
            try writer.writeAll("    ");
            try writer.writeAll(name);
            try writer.writeAll(".* = .{ .index = .{ .object = ");
            try writer.writeAll(object_name);
            try writer.writeAll(", .key = ");
            try writer.writeAll(key_name);
            try writer.writeAll(" } };\n");
        },
        .call => |call| {
            const callee_name = try emitBytecodeExprAlloc(writer, state, call.callee);
            defer state.allocator.free(callee_name);
            const args_name = try emitBytecodeExprSliceAlloc(writer, state, call.args);
            defer state.allocator.free(args_name);
            try writer.writeAll("    ");
            try writer.writeAll(name);
            try writer.writeAll(".* = .{ .call = .{ .callee = ");
            try writer.writeAll(callee_name);
            try writer.writeAll(", .args = ");
            try writer.writeAll(args_name);
            try writer.writeAll(" } };\n");
        },
        .function_lit => |func| {
            const params_name = try emitBytecodeStringSliceAlloc(writer, state, func.params);
            defer state.allocator.free(params_name);
            const body_name = try emitBytecodeStmtSliceAlloc(writer, state, func.body);
            defer state.allocator.free(body_name);
            try writer.writeAll("    ");
            try writer.writeAll(name);
            try writer.writeAll(".* = .{ .function_lit = .{ .params = ");
            try writer.writeAll(params_name);
            try writer.writeAll(", .body = ");
            try writer.writeAll(body_name);
            try writer.writeAll(", .is_vararg = ");
            try writer.print("{}", .{func.is_vararg});
            try writer.writeAll(" } };\n");
        },
    }
    return name;
}

fn emitBytecodeExprSliceAlloc(
    writer: anytype,
    state: *BytecodeAstEmitState,
    exprs: []const *Expr,
) anyerror![]u8 {
    const name = try state.nextName("exprs");
    errdefer state.allocator.free(name);
    try writer.writeAll("    const ");
    try writer.writeAll(name);
    try writer.print(" = try a.alloc(*lua.Expr, {d});\n", .{exprs.len});
    for (exprs, 0..) |expr, idx| {
        const expr_name = try emitBytecodeExprAlloc(writer, state, expr);
        defer state.allocator.free(expr_name);
        try writer.writeAll("    ");
        try writer.writeAll(name);
        try writer.print("[{d}] = {s};\n", .{ idx, expr_name });
    }
    return name;
}

fn emitBytecodeLValueAlloc(
    writer: anytype,
    state: *BytecodeAstEmitState,
    lvalue: LValue,
) anyerror![]u8 {
    const name = try state.nextName("lvalue");
    errdefer state.allocator.free(name);
    try writer.writeAll("    const ");
    try writer.writeAll(name);
    try writer.writeAll(": lua.LValue = ");
    switch (lvalue) {
        .name => |value| {
            try writer.writeAll(".{ .name = ");
            try writeZigStringLiteral(writer, value);
            try writer.writeAll(" }");
        },
        .field => |field| {
            const object_name = try emitBytecodeExprAlloc(writer, state, field.object);
            defer state.allocator.free(object_name);
            try writer.writeAll(".{ .field = .{ .object = ");
            try writer.writeAll(object_name);
            try writer.writeAll(", .name = ");
            try writeZigStringLiteral(writer, field.name);
            try writer.writeAll(" } }");
        },
        .index => |index| {
            const object_name = try emitBytecodeExprAlloc(writer, state, index.object);
            defer state.allocator.free(object_name);
            const key_name = try emitBytecodeExprAlloc(writer, state, index.key);
            defer state.allocator.free(key_name);
            try writer.writeAll(".{ .index = .{ .object = ");
            try writer.writeAll(object_name);
            try writer.writeAll(", .key = ");
            try writer.writeAll(key_name);
            try writer.writeAll(" } }");
        },
    }
    try writer.writeAll(";\n");
    return name;
}

fn emitBytecodeLValueSliceAlloc(
    writer: anytype,
    state: *BytecodeAstEmitState,
    lvalues: []const LValue,
) anyerror![]u8 {
    const name = try state.nextName("lvalues");
    errdefer state.allocator.free(name);
    try writer.writeAll("    const ");
    try writer.writeAll(name);
    try writer.print(" = try a.alloc(lua.LValue, {d});\n", .{lvalues.len});
    for (lvalues, 0..) |lvalue, idx| {
        const lvalue_name = try emitBytecodeLValueAlloc(writer, state, lvalue);
        defer state.allocator.free(lvalue_name);
        try writer.writeAll("    ");
        try writer.writeAll(name);
        try writer.print("[{d}] = {s};\n", .{ idx, lvalue_name });
    }
    return name;
}

fn emitBytecodeStmtAlloc(
    writer: anytype,
    state: *BytecodeAstEmitState,
    stmt: *const Stmt,
) anyerror![]u8 {
    const name = try state.nextName("stmt");
    errdefer state.allocator.free(name);
    try writer.writeAll("    const ");
    try writer.writeAll(name);
    try writer.writeAll(" = try a.create(lua.Stmt);\n");
    switch (stmt.*) {
        .local_assign => |op| {
            const names_name = try emitBytecodeStringSliceAlloc(writer, state, op.names);
            defer state.allocator.free(names_name);
            const exprs_name = try emitBytecodeExprSliceAlloc(writer, state, op.exprs);
            defer state.allocator.free(exprs_name);
            try writer.writeAll("    ");
            try writer.writeAll(name);
            try writer.writeAll(".* = .{ .local_assign = .{ .names = ");
            try writer.writeAll(names_name);
            try writer.writeAll(", .exprs = ");
            try writer.writeAll(exprs_name);
            try writer.writeAll(" } };\n");
        },
        .assign => |op| {
            const targets_name = try emitBytecodeLValueSliceAlloc(writer, state, op.targets);
            defer state.allocator.free(targets_name);
            const exprs_name = try emitBytecodeExprSliceAlloc(writer, state, op.exprs);
            defer state.allocator.free(exprs_name);
            try writer.writeAll("    ");
            try writer.writeAll(name);
            try writer.writeAll(".* = .{ .assign = .{ .targets = ");
            try writer.writeAll(targets_name);
            try writer.writeAll(", .exprs = ");
            try writer.writeAll(exprs_name);
            try writer.writeAll(" } };\n");
        },
        .function_def => |op| {
            const target_name = try emitBytecodeLValueAlloc(writer, state, op.target);
            defer state.allocator.free(target_name);
            const params_name = try emitBytecodeStringSliceAlloc(writer, state, op.params);
            defer state.allocator.free(params_name);
            const body_name = try emitBytecodeStmtSliceAlloc(writer, state, op.body);
            defer state.allocator.free(body_name);
            try writer.writeAll("    ");
            try writer.writeAll(name);
            try writer.writeAll(".* = .{ .function_def = .{ .target = ");
            try writer.writeAll(target_name);
            try writer.writeAll(", .params = ");
            try writer.writeAll(params_name);
            try writer.writeAll(", .body = ");
            try writer.writeAll(body_name);
            try writer.writeAll(", .is_vararg = ");
            try writer.print("{}", .{op.is_vararg});
            try writer.writeAll(", .is_local = ");
            try writer.print("{}", .{op.is_local});
            try writer.writeAll(" } };\n");
        },
        .if_stmt => |op| {
            const branches_name = try state.nextName("branches");
            defer state.allocator.free(branches_name);
            try writer.writeAll("    const ");
            try writer.writeAll(branches_name);
            try writer.print(" = try a.alloc(lua.IfBranch, {d});\n", .{op.branches.len});
            for (op.branches, 0..) |branch, idx| {
                const cond_name = try emitBytecodeExprAlloc(writer, state, branch.condition);
                defer state.allocator.free(cond_name);
                const body_name = try emitBytecodeStmtSliceAlloc(writer, state, branch.body);
                defer state.allocator.free(body_name);
                try writer.writeAll("    ");
                try writer.writeAll(branches_name);
                try writer.print("[{d}] = .{{ .condition = {s}, .body = {s} }};\n", .{ idx, cond_name, body_name });
            }
            const else_name = try emitBytecodeStmtSliceAlloc(writer, state, op.else_body);
            defer state.allocator.free(else_name);
            try writer.writeAll("    ");
            try writer.writeAll(name);
            try writer.writeAll(".* = .{ .if_stmt = .{ .branches = ");
            try writer.writeAll(branches_name);
            try writer.writeAll(", .else_body = ");
            try writer.writeAll(else_name);
            try writer.writeAll(" } };\n");
        },
        .do_block => |body| {
            const body_name = try emitBytecodeStmtSliceAlloc(writer, state, body);
            defer state.allocator.free(body_name);
            try writer.writeAll("    ");
            try writer.writeAll(name);
            try writer.writeAll(".* = .{ .do_block = ");
            try writer.writeAll(body_name);
            try writer.writeAll(" };\n");
        },
        .while_stmt => |op| {
            const cond_name = try emitBytecodeExprAlloc(writer, state, op.condition);
            defer state.allocator.free(cond_name);
            const body_name = try emitBytecodeStmtSliceAlloc(writer, state, op.body);
            defer state.allocator.free(body_name);
            try writer.writeAll("    ");
            try writer.writeAll(name);
            try writer.writeAll(".* = .{ .while_stmt = .{ .condition = ");
            try writer.writeAll(cond_name);
            try writer.writeAll(", .body = ");
            try writer.writeAll(body_name);
            try writer.writeAll(" } };\n");
        },
        .repeat_stmt => |op| {
            const body_name = try emitBytecodeStmtSliceAlloc(writer, state, op.body);
            defer state.allocator.free(body_name);
            const cond_name = try emitBytecodeExprAlloc(writer, state, op.condition);
            defer state.allocator.free(cond_name);
            try writer.writeAll("    ");
            try writer.writeAll(name);
            try writer.writeAll(".* = .{ .repeat_stmt = .{ .body = ");
            try writer.writeAll(body_name);
            try writer.writeAll(", .condition = ");
            try writer.writeAll(cond_name);
            try writer.writeAll(" } };\n");
        },
        .numeric_for => |op| {
            const start_name = try emitBytecodeExprAlloc(writer, state, op.start);
            defer state.allocator.free(start_name);
            const finish_name = try emitBytecodeExprAlloc(writer, state, op.finish);
            defer state.allocator.free(finish_name);
            var step_name_opt: ?[]u8 = null;
            if (op.step) |step| step_name_opt = try emitBytecodeExprAlloc(writer, state, step);
            defer if (step_name_opt) |step_name| state.allocator.free(step_name);
            const body_name = try emitBytecodeStmtSliceAlloc(writer, state, op.body);
            defer state.allocator.free(body_name);
            try writer.writeAll("    ");
            try writer.writeAll(name);
            try writer.writeAll(".* = .{ .numeric_for = .{ .name = ");
            try writeZigStringLiteral(writer, op.name);
            try writer.writeAll(", .start = ");
            try writer.writeAll(start_name);
            try writer.writeAll(", .finish = ");
            try writer.writeAll(finish_name);
            try writer.writeAll(", .step = ");
            if (step_name_opt) |step_name| try writer.writeAll(step_name) else try writer.writeAll("null");
            try writer.writeAll(", .body = ");
            try writer.writeAll(body_name);
            try writer.writeAll(" } };\n");
        },
        .generic_for => |op| {
            const names_name = try emitBytecodeStringSliceAlloc(writer, state, op.names);
            defer state.allocator.free(names_name);
            const iterator_name = try emitBytecodeExprSliceAlloc(writer, state, op.iterator_exprs);
            defer state.allocator.free(iterator_name);
            const body_name = try emitBytecodeStmtSliceAlloc(writer, state, op.body);
            defer state.allocator.free(body_name);
            try writer.writeAll("    ");
            try writer.writeAll(name);
            try writer.writeAll(".* = .{ .generic_for = .{ .names = ");
            try writer.writeAll(names_name);
            try writer.writeAll(", .iterator_exprs = ");
            try writer.writeAll(iterator_name);
            try writer.writeAll(", .body = ");
            try writer.writeAll(body_name);
            try writer.writeAll(" } };\n");
        },
        .return_stmt => |op| {
            const exprs_name = try emitBytecodeExprSliceAlloc(writer, state, op.exprs);
            defer state.allocator.free(exprs_name);
            try writer.writeAll("    ");
            try writer.writeAll(name);
            try writer.writeAll(".* = .{ .return_stmt = .{ .exprs = ");
            try writer.writeAll(exprs_name);
            try writer.writeAll(" } };\n");
        },
        .break_stmt => {
            try writer.writeAll("    ");
            try writer.writeAll(name);
            try writer.writeAll(".* = .break_stmt;\n");
        },
        .expr_stmt => |expr| {
            const expr_name = try emitBytecodeExprAlloc(writer, state, expr);
            defer state.allocator.free(expr_name);
            try writer.writeAll("    ");
            try writer.writeAll(name);
            try writer.writeAll(".* = .{ .expr_stmt = ");
            try writer.writeAll(expr_name);
            try writer.writeAll(" };\n");
        },
    }
    return name;
}

fn emitBytecodeStmtSliceAlloc(
    writer: anytype,
    state: *BytecodeAstEmitState,
    stmts: []const *Stmt,
) anyerror![]u8 {
    const name = try state.nextName("stmts");
    errdefer state.allocator.free(name);
    try writer.writeAll("    const ");
    try writer.writeAll(name);
    try writer.print(" = try a.alloc(*lua.Stmt, {d});\n", .{stmts.len});
    for (stmts, 0..) |stmt, idx| {
        const stmt_name = try emitBytecodeStmtAlloc(writer, state, stmt);
        defer state.allocator.free(stmt_name);
        try writer.writeAll("    ");
        try writer.writeAll(name);
        try writer.print("[{d}] = {s};\n", .{ idx, stmt_name });
    }
    return name;
}

fn emitIndent(writer: anytype, depth: usize) anyerror!void {
    for (0..depth) |_| try writer.writeAll("    ");
}

fn writeSanitizedIdentifierBody(writer: anytype, source_name: []const u8) anyerror!void {
    var wrote_any = false;
    var last_was_underscore = true;
    for (source_name) |byte| {
        if (std.ascii.isAlphanumeric(byte)) {
            try writer.writeByte(byte);
            wrote_any = true;
            last_was_underscore = false;
        } else if (!last_was_underscore) {
            try writer.writeByte('_');
            last_was_underscore = true;
        }
    }
    if (!wrote_any) try writer.writeAll("value");
}

fn emitGeneratedIdentifier(
    writer: anytype,
    prefix: []const u8,
    source_name: []const u8,
    id: usize,
) anyerror!void {
    try writer.writeAll(prefix);
    try writeSanitizedIdentifierBody(writer, source_name);
    try writer.print("_{d}", .{id});
}

fn emitLocalIdentifier(writer: anytype, ctx: *const DirectEmitFunctionContext, local_id: u32) anyerror!void {
    try emitGeneratedIdentifier(writer, "lua_local_", ctx.localSourceName(local_id), local_id);
}

fn emitCaptureFieldIdentifier(writer: anytype, ctx: *const DirectEmitFunctionContext, capture_id: u32) anyerror!void {
    const capture = ctx.info.captures[capture_id];
    try emitGeneratedIdentifier(writer, "lua_capture_", capture.name, capture_id);
}

fn emitGlobalFieldIdentifier(writer: anytype, state: *const DirectModuleState, global_id: u32) anyerror!void {
    try emitGeneratedIdentifier(writer, "lua_global_", state.globals.items[global_id], global_id);
}

fn stripUnusedGeneratedArtifactsAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var current: []u8 = @constCast(source);
    while (true) {
        const stripped_captures = try stripUnusedGeneratedCaptureFieldsAlloc(allocator, current);
        const captures_changed = !std.mem.eql(u8, stripped_captures, current);
        allocator.free(current);
        current = stripped_captures;

        const stripped_bindings = try stripUnusedGeneratedLocalsAlloc(allocator, current);
        const bindings_changed = !std.mem.eql(u8, stripped_bindings, current);
        allocator.free(current);
        current = stripped_bindings;

        if (!captures_changed and !bindings_changed) return current;
    }
}

fn stripUnusedGeneratedCaptureFieldsAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var in_capture_struct = false;
    var line_start: usize = 0;
    while (line_start < source.len) {
        const line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
        const line = source[line_start..line_end];
        const trimmed = std.mem.trim(u8, line, " ");

        if (std.mem.startsWith(u8, trimmed, "const Capture_") and std.mem.endsWith(u8, trimmed, " = struct {")) {
            in_capture_struct = true;
        } else if (in_capture_struct and std.mem.eql(u8, trimmed, "};")) {
            in_capture_struct = false;
        }

        if (try shouldStripGeneratedCaptureLine(source, line, trimmed, in_capture_struct)) {
            line_start = if (line_end < source.len) line_end + 1 else source.len;
            continue;
        }

        try out.appendSlice(allocator, line);
        if (line_end < source.len) try out.append(allocator, '\n');
        line_start = if (line_end < source.len) line_end + 1 else source.len;
    }

    return out.toOwnedSlice(allocator);
}

fn shouldStripGeneratedCaptureLine(
    source: []const u8,
    line: []const u8,
    trimmed: []const u8,
    in_capture_struct: bool,
) !bool {
    _ = line;
    if (in_capture_struct and std.mem.startsWith(u8, trimmed, "lua_capture_")) {
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return false;
        const token = trimmed[0..colon];
        return countGeneratedIdentifierOccurrences(source, token) == 2;
    }

    if (std.mem.startsWith(u8, trimmed, ".lua_capture_")) {
        const eq = std.mem.indexOf(u8, trimmed, " = ") orelse return false;
        const token = trimmed[1..eq];
        return countGeneratedIdentifierOccurrences(source, token) == 2;
    }

    return false;
}

fn stripUnusedGeneratedLocalsAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var line_start: usize = 0;
    while (line_start < source.len) {
        const line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
        const line = source[line_start..line_end];
        if (try rewriteUnusedGeneratedLocalLineAlloc(allocator, source, line, line_start, &out)) {
            if (line_end < source.len) try out.append(allocator, '\n');
            line_start = if (line_end < source.len) line_end + 1 else source.len;
            continue;
        }
        try out.appendSlice(allocator, line);
        if (line_end < source.len) try out.append(allocator, '\n');
        line_start = if (line_end < source.len) line_end + 1 else source.len;
    }
    return out.toOwnedSlice(allocator);
}

fn rewriteUnusedGeneratedLocalLineAlloc(
    allocator: std.mem.Allocator,
    source: []const u8,
    line: []const u8,
    line_start: usize,
    out: *std.ArrayList(u8),
) !bool {
    const prefix_len = std.mem.indexOfNone(u8, line, " ") orelse line.len;
    const trimmed = line[prefix_len..];
    const binding = parseGeneratedBindingLine(trimmed) orelse return false;
    if (countGeneratedLocalOccurrencesInFunction(source, line_start, binding.token) != 1) return false;

    if (generatedBindingExprIsPureLiteral(binding.expr)) {
        return true;
    }

    try out.appendNTimes(allocator, ' ', prefix_len);
    try out.appendSlice(allocator, "_ = ");
    try out.appendSlice(allocator, binding.expr);
    try out.appendSlice(allocator, ";");
    return true;
}

const ParsedGeneratedBindingLine = struct {
    token: []const u8,
    expr: []const u8,
};

fn parseGeneratedBindingLine(trimmed: []const u8) ?ParsedGeneratedBindingLine {
    const keyword_len: usize = if (std.mem.startsWith(u8, trimmed, "const lua_local_"))
        "const ".len
    else if (std.mem.startsWith(u8, trimmed, "var lua_local_"))
        "var ".len
    else if (std.mem.startsWith(u8, trimmed, "const tmp_"))
        "const ".len
    else if (std.mem.startsWith(u8, trimmed, "var tmp_"))
        "var ".len
    else
        return null;
    if (trimmed.len == 0 or trimmed[trimmed.len - 1] != ';') return null;

    if (std.mem.indexOf(u8, trimmed, ": lua.Value = ")) |marker_index| {
        return .{
            .token = trimmed[keyword_len..marker_index],
            .expr = trimmed[marker_index + ": lua.Value = ".len .. trimmed.len - 1],
        };
    }
    if (std.mem.indexOf(u8, trimmed, " = ")) |marker_index| {
        return .{
            .token = trimmed[keyword_len..marker_index],
            .expr = trimmed[marker_index + " = ".len .. trimmed.len - 1],
        };
    }
    return null;
}

fn generatedBindingExprIsPureLiteral(expr: []const u8) bool {
    return std.mem.eql(u8, expr, "lua.Value.nil") or
        std.mem.startsWith(u8, expr, "lua.Value{ .string = ") or
        std.mem.startsWith(u8, expr, "lua.Value{ .number = ") or
        std.mem.startsWith(u8, expr, "lua.Value{ .boolean = ");
}

fn countGeneratedLocalOccurrencesInFunction(source: []const u8, line_start: usize, token: []const u8) usize {
    const fn_marker = "\nfn fn_";
    const fn_start = if (line_start == 0 or std.mem.startsWith(u8, source, "fn fn_"))
        0
    else if (std.mem.lastIndexOf(u8, source[0..line_start], fn_marker)) |idx|
        idx + 1
    else
        0;
    const fn_end = std.mem.indexOfPos(u8, source, line_start, fn_marker) orelse source.len;

    var count: usize = 0;
    var index = fn_start;
    while (index < fn_end) : (index += 1) {
        if (!std.mem.startsWith(u8, source[index..fn_end], token)) continue;
        if (index != fn_start and isGeneratedIdentifierChar(source[index - 1])) continue;
        const end = index + token.len;
        if (end < fn_end and isGeneratedIdentifierChar(source[end])) continue;
        count += 1;
    }
    return count;
}

fn countGeneratedIdentifierOccurrences(source: []const u8, token: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < source.len) : (index += 1) {
        if (!std.mem.startsWith(u8, source[index..], token)) continue;
        if (index != 0 and isGeneratedIdentifierChar(source[index - 1])) continue;
        const end = index + token.len;
        if (end < source.len and isGeneratedIdentifierChar(source[end])) continue;
        count += 1;
    }
    return count;
}

fn isGeneratedIdentifierChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn formatTagName(comptime T: type, value: T) []const u8 {
    return @tagName(value);
}

fn blockContainsReturn(stmts: []const *Stmt) bool {
    for (stmts) |stmt| {
        if (stmtContainsReturn(stmt)) return true;
    }
    return false;
}

fn stmtContainsReturn(stmt: *const Stmt) bool {
    return switch (stmt.*) {
        .if_stmt => |op| blk: {
            for (op.branches) |branch| {
                if (blockContainsReturn(branch.body)) break :blk true;
            }
            break :blk blockContainsReturn(op.else_body);
        },
        .do_block => |body| blockContainsReturn(body),
        .while_stmt => |op| blockContainsReturn(op.body),
        .repeat_stmt => |op| blockContainsReturn(op.body),
        .numeric_for => |op| blockContainsReturn(op.body),
        .generic_for => |op| blockContainsReturn(op.body),
        .return_stmt => true,
        .local_assign, .assign, .function_def, .break_stmt, .expr_stmt => false,
    };
}

fn blockContainsVarargs(stmts: []const *Stmt) bool {
    for (stmts) |stmt| {
        if (stmtContainsVarargs(stmt)) return true;
    }
    return false;
}

fn stmtContainsVarargs(stmt: *const Stmt) bool {
    return switch (stmt.*) {
        .local_assign => |op| blk: {
            for (op.exprs) |expr| if (exprContainsVarargs(expr)) break :blk true;
            break :blk false;
        },
        .assign => |op| blk: {
            for (op.exprs) |expr| if (exprContainsVarargs(expr)) break :blk true;
            break :blk false;
        },
        .if_stmt => |op| blk: {
            for (op.branches) |branch| {
                if (exprContainsVarargs(branch.condition) or blockContainsVarargs(branch.body)) break :blk true;
            }
            break :blk blockContainsVarargs(op.else_body);
        },
        .do_block => |body| blockContainsVarargs(body),
        .while_stmt => |op| exprContainsVarargs(op.condition) or blockContainsVarargs(op.body),
        .repeat_stmt => |op| blockContainsVarargs(op.body) or exprContainsVarargs(op.condition),
        .numeric_for => |op| blk: {
            if (exprContainsVarargs(op.start) or exprContainsVarargs(op.finish)) break :blk true;
            if (op.step) |step| if (exprContainsVarargs(step)) break :blk true;
            break :blk blockContainsVarargs(op.body);
        },
        .generic_for => |op| blk: {
            for (op.iterator_exprs) |expr| if (exprContainsVarargs(expr)) break :blk true;
            break :blk blockContainsVarargs(op.body);
        },
        .return_stmt => |op| blk: {
            for (op.exprs) |expr| if (exprContainsVarargs(expr)) break :blk true;
            break :blk false;
        },
        .expr_stmt => |expr| exprContainsVarargs(expr),
        .function_def, .break_stmt => false,
    };
}

fn exprContainsVarargs(expr: *const Expr) bool {
    return switch (expr.*) {
        .varargs => true,
        .unary => |op| exprContainsVarargs(op.expr),
        .binary => |op| exprContainsVarargs(op.lhs) or exprContainsVarargs(op.rhs),
        .table_ctor => |fields| blk: {
            for (fields) |field| switch (field) {
                .array => |child| if (exprContainsVarargs(child)) break :blk true,
                .named => |named| if (exprContainsVarargs(named.value)) break :blk true,
                .indexed => |indexed| if (exprContainsVarargs(indexed.key) or exprContainsVarargs(indexed.value)) break :blk true,
            };
            break :blk false;
        },
        .field => |field| exprContainsVarargs(field.object),
        .index => |index| exprContainsVarargs(index.object) or exprContainsVarargs(index.key),
        .call => |call| blk: {
            if (exprContainsVarargs(call.callee)) break :blk true;
            for (call.args) |arg| if (exprContainsVarargs(arg)) break :blk true;
            break :blk false;
        },
        .function_lit => false,
        .nil_lit, .bool_lit, .number_lit, .string_lit, .variable, .const_table => false,
    };
}

fn emitDirectFunction(
    writer: anytype,
    state: *const DirectModuleState,
    info: *const DirectFunctionInfo,
    capture_fact_seeds: []?[]KnownValueFact,
    capture_method_binding_seeds: []?[]DirectMethodBindingSeed,
) anyerror!void {
    try writer.print(
        "fn fn_{d}(capture_ptr: ?*anyopaque, globals_ptr: ?*anyopaque, runtime: *lua.GeneratedRuntime, args: []const lua.Value) anyerror![]lua.Value {{\n",
        .{info.id},
    );
    try emitIndent(writer, 1);
    try writer.writeAll("const globals: *Globals = @ptrCast(@alignCast(globals_ptr.?));\n");
    try emitIndent(writer, 1);
    try writer.writeAll("if (@intFromPtr(globals) == 0) unreachable;\n");
    try emitIndent(writer, 1);
    try writer.writeAll("if (args.len == std.math.maxInt(usize)) unreachable;\n");
    if (info.captures.len != 0) {
        try emitIndent(writer, 1);
        try writer.print("const capture: *Capture_{d} = @ptrCast(@alignCast(capture_ptr.?));\n", .{info.id});
        try emitIndent(writer, 1);
        try writer.writeAll("if (@intFromPtr(capture) == 0) unreachable;\n");
    } else {
        try emitIndent(writer, 1);
        try writer.writeAll("_ = capture_ptr;\n");
    }

    const uses_return_block = blockContainsReturn(info.body);
    var local_analysis = try analyzeDirectFunctionLocalAnalysisAlloc(state.allocator, state, info);
    defer local_analysis.deinit(state.allocator);
    var ctx = DirectEmitFunctionContext.init(
        state,
        info,
        uses_return_block,
        local_analysis.used,
        local_analysis.requires_var,
        capture_fact_seeds,
        capture_method_binding_seeds,
    );
    defer ctx.deinit();
    if (info.captures.len != 0) {
        ctx.capture_facts = try state.allocator.alloc(KnownValueFact, info.captures.len);
        if (info.id < capture_fact_seeds.len) {
            if (capture_fact_seeds[info.id]) |seed| {
                if (seed.len != ctx.capture_facts.len) return error.InvalidCall;
                for (seed, 0..) |fact, idx| ctx.capture_facts[idx] = fact;
            } else {
                for (ctx.capture_facts) |*fact| fact.* = .unknown;
            }
        } else {
            for (ctx.capture_facts) |*fact| fact.* = .unknown;
        }

        if (info.id < capture_method_binding_seeds.len) {
            if (capture_method_binding_seeds[info.id]) |seeds| {
                for (seeds) |seed| {
                    try ctx.method_bindings.append(state.allocator, .{
                        .owner = .{ .capture = seed.capture_index },
                        .name = seed.name,
                        .fact = seed.fact,
                        .source = .{ .capture = seed.capture_index },
                    });
                }
            }
        }
    }

    for (info.params, 0..) |param, idx| {
        const local_id = try ctx.declareLocal(param);
        ctx.setLocalFact(local_id, if (std.mem.eql(u8, param, "frame"))
            .{ .builtin_table = .frame }
        else
            .unknown);
        if (!localShouldEmit(&ctx, local_id)) continue;
        try emitIndent(writer, 1);
        try writer.writeAll(localBindingKeyword(&ctx, local_id));
        try writer.writeByte(' ');
        try emitLocalIdentifier(writer, &ctx, local_id);
        try writer.print(": lua.Value = if (args.len > {d}) args[{d}] else @as(lua.Value, .nil);\n", .{ idx, idx });
    }
    if (info.is_vararg and blockContainsVarargs(info.body)) {
        try emitIndent(writer, 1);
        try writer.print("const varargs = if (args.len > {d}) args[{d}..] else &.{{}};\n", .{ info.params.len, info.params.len });
        try emitIndent(writer, 1);
        try writer.writeAll("lua.generatedTouchValues(varargs);\n");
    }

    if (uses_return_block) {
        try emitIndent(writer, 1);
        try writer.writeAll("var return_result: ?[]lua.Value = null;\n");
        try emitIndent(writer, 1);
        try writer.writeAll("lua_fn: {\n");
        try ctx.beginScope();
        try emitStmtSlice(writer, &ctx, info.body, 2);
        ctx.endScope();
        try emitIndent(writer, 1);
        try writer.writeAll("}\n");
        try emitIndent(writer, 1);
        try writer.writeAll("return return_result orelse try runtime.allocValues(&.{});\n");
    } else {
        try ctx.beginScope();
        try emitStmtSlice(writer, &ctx, info.body, 1);
        ctx.endScope();
        try emitIndent(writer, 1);
        try writer.writeAll("return try runtime.allocValues(&.{});\n");
    }
    try writer.writeAll("}\n\n");
}

fn emitStmtSlice(writer: anytype, ctx: *DirectEmitFunctionContext, stmts: []const *Stmt, depth: usize) anyerror!void {
    for (stmts) |stmt| try emitStmt(writer, ctx, stmt, depth);
}

fn emitStmt(writer: anytype, ctx: *DirectEmitFunctionContext, stmt: *const Stmt, depth: usize) anyerror!void {
    switch (stmt.*) {
        .local_assign => |op| {
            const value_count = @max(op.names.len, op.exprs.len);
            const temp_ids = try ctx.state.allocator.alloc(u32, value_count);
            defer ctx.state.allocator.free(temp_ids);
            const value_facts = try ctx.state.allocator.alloc(KnownValueFact, value_count);
            defer ctx.state.allocator.free(value_facts);

            for (0..value_count) |idx| {
                temp_ids[idx] = ctx.nextTemp();
                value_facts[idx] = if (idx < op.exprs.len) knownValueFactForExpr(ctx, op.exprs[idx]) else .unknown;
                try emitIndent(writer, depth);
                try writer.print("const tmp_{d}: lua.Value = ", .{temp_ids[idx]});
                if (idx < op.exprs.len) {
                    try emitExpr(writer, ctx, op.exprs[idx], depth);
                } else {
                    try writer.writeAll("lua.Value.nil");
                }
                try writer.writeAll(";\n");
            }

            for (op.names, 0..) |name, idx| {
                const local_id = try ctx.declareLocal(name);
                ctx.setLocalFact(local_id, value_facts[idx]);
                try emitIndent(writer, depth);
                if (localShouldEmit(ctx, local_id)) {
                    try writer.writeAll(localBindingKeyword(ctx, local_id));
                    try writer.writeByte(' ');
                    try emitLocalIdentifier(writer, ctx, local_id);
                    try writer.print(": lua.Value = tmp_{d};\n", .{temp_ids[idx]});
                } else {
                    try writer.print("_ = tmp_{d};\n", .{temp_ids[idx]});
                }
            }
            if (op.exprs.len > op.names.len) {
                for (temp_ids[op.names.len..op.exprs.len]) |temp_id| {
                    try emitIndent(writer, depth);
                    try writer.print("_ = tmp_{d};\n", .{temp_id});
                }
            }
        },
        .assign => |op| {
            const value_count = @max(op.targets.len, op.exprs.len);
            const temp_ids = try ctx.state.allocator.alloc(u32, value_count);
            defer ctx.state.allocator.free(temp_ids);
            const value_facts = try ctx.state.allocator.alloc(KnownValueFact, value_count);
            defer ctx.state.allocator.free(value_facts);

            for (0..value_count) |idx| {
                temp_ids[idx] = ctx.nextTemp();
                value_facts[idx] = if (idx < op.exprs.len) knownValueFactForExpr(ctx, op.exprs[idx]) else .unknown;
                try emitIndent(writer, depth);
                try writer.print("const tmp_{d}: lua.Value = ", .{temp_ids[idx]});
                if (idx < op.exprs.len) {
                    try emitExpr(writer, ctx, op.exprs[idx], depth);
                } else {
                    try writer.writeAll("lua.Value.nil");
                }
                try writer.writeAll(";\n");
            }

            var idx = op.targets.len;
            while (idx != 0) {
                idx -= 1;
                try emitStoreTarget(writer, ctx, op.targets[idx], temp_ids[idx], value_facts[idx], depth);
                switch (op.targets[idx]) {
                    .name => |name| {
                        if (ctx.lookupLocal(name)) |local_id| {
                            ctx.setLocalFact(local_id, value_facts[idx]);
                        } else if (ctx.lookupCapture(name)) |capture_id| {
                            ctx.setCaptureFact(capture_id, value_facts[idx]);
                        }
                    },
                    else => {},
                }
            }
            if (op.exprs.len > op.targets.len) {
                for (temp_ids[op.targets.len..op.exprs.len]) |temp_id| {
                    try emitIndent(writer, depth);
                    try writer.print("_ = tmp_{d};\n", .{temp_id});
                }
            }
        },
        .function_def => |op| {
            const child_id = ctx.state.stmtFunctionId(stmt) orelse return error.UnsupportedSyntax;
            const child_info = &ctx.state.functions.items[child_id];
            const direct_fact = forwardedCallableFact(knownFunctionValueFact(ctx, child_info, 8));
            const function_fact: KnownValueFact = if (direct_fact != .unknown)
                direct_fact
            else
                .{ .direct_function_id = child_id };
            if (op.is_local and op.target == .name) {
                const local_id = try ctx.declareLocal(op.target.name);
                ctx.setLocalFact(local_id, function_fact);
                try seedChildCaptureFacts(ctx, child_info);
                try seedChildCaptureMethodBindings(ctx, child_info);
                if (!localShouldEmit(ctx, local_id)) return;
                try emitIndent(writer, depth);
                try writer.writeAll(localBindingKeyword(ctx, local_id));
                try writer.writeByte(' ');
                try emitLocalIdentifier(writer, ctx, local_id);
                try writer.writeAll(": lua.Value = lua.Value.nil;\n");
                try emitIndent(writer, depth);
                try emitLocalIdentifier(writer, ctx, local_id);
                try writer.writeAll(" = ");
                try emitFunctionValueExpr(writer, ctx, child_info, depth);
                try writer.writeAll(";\n");
            } else {
                const temp_id = ctx.nextTemp();
                try emitIndent(writer, depth);
                try writer.print("const tmp_{d}: lua.Value = ", .{temp_id});
                try emitFunctionValueExpr(writer, ctx, child_info, depth);
                try writer.writeAll(";\n");
                try emitStoreTarget(writer, ctx, op.target, temp_id, function_fact, depth);
                switch (op.target) {
                    .name => |name| {
                        if (ctx.lookupLocal(name)) |local_id| {
                            ctx.setLocalFact(local_id, function_fact);
                        } else if (ctx.lookupCapture(name)) |capture_id| {
                            ctx.setCaptureFact(capture_id, function_fact);
                        }
                    },
                    else => {},
                }
            }
        },
        .if_stmt => |op| {
            var original_facts = try ctx.snapshotFactsAlloc();
            defer original_facts.deinit(ctx.state.allocator);
            var path_facts: std.ArrayList(KnownFactSnapshot) = .empty;
            defer {
                for (path_facts.items) |*snapshot| snapshot.deinit(ctx.state.allocator);
                path_facts.deinit(ctx.state.allocator);
            }
            for (op.branches, 0..) |branch, idx| {
                try ctx.restoreFacts(&original_facts);
                try emitIndent(writer, depth);
                if (idx == 0) {
                    try writer.writeAll("if ((");
                } else {
                    try writer.writeAll("else if ((");
                }
                try emitExpr(writer, ctx, branch.condition, depth);
                try writer.writeAll(").truthy()) {\n");
                try ctx.beginScope();
                try emitStmtSlice(writer, ctx, branch.body, depth + 1);
                ctx.endScope();
                try path_facts.append(ctx.state.allocator, try ctx.snapshotFactsAlloc());
                try emitIndent(writer, depth);
                try writer.writeAll("}");
                if (idx + 1 == op.branches.len and op.else_body.len == 0) try writer.writeAll("\n");
            }
            if (op.else_body.len != 0) {
                try ctx.restoreFacts(&original_facts);
                if (op.branches.len == 0) {
                    try emitIndent(writer, depth);
                    try writer.writeAll("{\n");
                } else {
                    try writer.writeAll(" else {\n");
                }
                try ctx.beginScope();
                try emitStmtSlice(writer, ctx, op.else_body, depth + 1);
                ctx.endScope();
                try path_facts.append(ctx.state.allocator, try ctx.snapshotFactsAlloc());
                try emitIndent(writer, depth);
                try writer.writeAll("}\n");
            } else {
                try ctx.restoreFacts(&original_facts);
                try path_facts.append(ctx.state.allocator, try ctx.snapshotFactsAlloc());
            }
            var merged_facts = if (op.else_body.len != 0 or op.branches.len == 0)
                try mergeSnapshotFactsAlloc(ctx.state.allocator, &path_facts.items[0], path_facts.items[1..])
            else
                try mergeSnapshotFactsAlloc(ctx.state.allocator, &original_facts, path_facts.items);
            defer merged_facts.deinit(ctx.state.allocator);
            try ctx.restoreFacts(&merged_facts);
        },
        .do_block => |body| {
            try emitIndent(writer, depth);
            try writer.writeAll("{\n");
            try ctx.beginScope();
            try emitStmtSlice(writer, ctx, body, depth + 1);
            ctx.endScope();
            try emitIndent(writer, depth);
            try writer.writeAll("}\n");
        },
        .while_stmt => |op| {
            var original_facts = try ctx.snapshotFactsAlloc();
            defer original_facts.deinit(ctx.state.allocator);
            try emitIndent(writer, depth);
            try writer.writeAll("while ((");
            try emitExpr(writer, ctx, op.condition, depth);
            try writer.writeAll(").truthy()) {\n");
            try ctx.beginScope();
            try emitStmtSlice(writer, ctx, op.body, depth + 1);
            var loop_path = try ctx.snapshotFactsAlloc();
            defer loop_path.deinit(ctx.state.allocator);
            ctx.endScope();
            try emitIndent(writer, depth);
            try writer.writeAll("}\n");
            var merged_facts = try mergeSnapshotFactsAlloc(ctx.state.allocator, &original_facts, &.{loop_path});
            defer merged_facts.deinit(ctx.state.allocator);
            try ctx.restoreFacts(&merged_facts);
        },
        .repeat_stmt => |op| {
            var original_facts = try ctx.snapshotFactsAlloc();
            defer original_facts.deinit(ctx.state.allocator);
            try emitIndent(writer, depth);
            try writer.writeAll("while (true) {\n");
            try ctx.beginScope();
            try emitStmtSlice(writer, ctx, op.body, depth + 1);
            try emitIndent(writer, depth + 1);
            try writer.writeAll("if ((");
            try emitExpr(writer, ctx, op.condition, depth + 1);
            try writer.writeAll(").truthy()) break;\n");
            var loop_path = try ctx.snapshotFactsAlloc();
            defer loop_path.deinit(ctx.state.allocator);
            ctx.endScope();
            try emitIndent(writer, depth);
            try writer.writeAll("}\n");
            var merged_facts = try mergeSnapshotFactsAlloc(ctx.state.allocator, &original_facts, &.{loop_path});
            defer merged_facts.deinit(ctx.state.allocator);
            try ctx.restoreFacts(&merged_facts);
        },
        .numeric_for => |op| {
            var original_facts = try ctx.snapshotFactsAlloc();
            defer original_facts.deinit(ctx.state.allocator);
            const start_temp = ctx.nextTemp();
            const limit_temp = ctx.nextTemp();
            const step_temp = ctx.nextTemp();
            const step_num_temp = ctx.nextTemp();

            try emitIndent(writer, depth);
            try writer.print("const tmp_{d}: lua.Value = ", .{start_temp});
            try emitExpr(writer, ctx, op.start, depth);
            try writer.writeAll(";\n");

            try emitIndent(writer, depth);
            try writer.print("const tmp_{d}: lua.Value = ", .{limit_temp});
            try emitExpr(writer, ctx, op.finish, depth);
            try writer.writeAll(";\n");

            try emitIndent(writer, depth);
            try writer.print("const tmp_{d}: lua.Value = ", .{step_temp});
            if (op.step) |step| {
                try emitExpr(writer, ctx, step, depth);
            } else {
                try writer.writeAll("lua.Value{ .number = 1 }");
            }
            try writer.writeAll(";\n");

            try emitIndent(writer, depth);
            try writer.print("const tmp_{d} = try lua.valueToNumberAlloc(tmp_{d});\n", .{ step_num_temp, step_temp });
            try emitIndent(writer, depth);
            try writer.writeAll("if ((tmp_");
            try writer.print("{d} >= 0 and try lua.valueToNumberAlloc(tmp_{d}) <= try lua.valueToNumberAlloc(tmp_{d})) or (tmp_{d} < 0 and try lua.valueToNumberAlloc(tmp_{d}) >= try lua.valueToNumberAlloc(tmp_{d}))) {{\n", .{
                step_num_temp, start_temp, limit_temp, step_num_temp, start_temp, limit_temp,
            });

            try ctx.beginScope();
            const loop_local = try ctx.declareLocal(op.name);
            ctx.setLocalFact(loop_local, .unknown);
            try emitIndent(writer, depth + 1);
            try writer.writeAll(localBindingKeyword(ctx, loop_local));
            try writer.writeByte(' ');
            try emitLocalIdentifier(writer, ctx, loop_local);
            try writer.print(": lua.Value = tmp_{d};\n", .{start_temp});
            try emitIndent(writer, depth + 1);
            try writer.writeAll("while (true) {\n");
            try ctx.beginScope();
            try emitStmtSlice(writer, ctx, op.body, depth + 2);
            ctx.endScope();
            try emitIndent(writer, depth + 2);
            try writer.writeAll("const next_num = try lua.valueToNumberAlloc(");
            try emitLocalIdentifier(writer, ctx, loop_local);
            try writer.print(") + tmp_{d};\n", .{step_num_temp});
            try emitIndent(writer, depth + 2);
            try emitLocalIdentifier(writer, ctx, loop_local);
            try writer.writeAll(" = lua.Value{ .number = next_num };\n");
            try emitIndent(writer, depth + 2);
            try writer.print("if (!((tmp_{d} >= 0 and next_num <= try lua.valueToNumberAlloc(tmp_{d})) or (tmp_{d} < 0 and next_num >= try lua.valueToNumberAlloc(tmp_{d})))) break;\n", .{
                step_num_temp, limit_temp, step_num_temp, limit_temp,
            });
            try emitIndent(writer, depth + 1);
            try writer.writeAll("}\n");
            var loop_path = try ctx.snapshotFactsAlloc();
            defer loop_path.deinit(ctx.state.allocator);
            ctx.endScope();
            try emitIndent(writer, depth);
            try writer.writeAll("}\n");
            var merged_facts = try mergeSnapshotFactsAlloc(ctx.state.allocator, &original_facts, &.{loop_path});
            defer merged_facts.deinit(ctx.state.allocator);
            try ctx.restoreFacts(&merged_facts);
        },
        .generic_for => |op| {
            var original_facts = try ctx.snapshotFactsAlloc();
            defer original_facts.deinit(ctx.state.allocator);
            const iter_temp = ctx.nextTemp();
            const pair_temp = ctx.nextTemp();
            const local_ids = try ctx.state.allocator.alloc(u32, op.names.len);
            defer ctx.state.allocator.free(local_ids);
            try emitIndent(writer, depth);
            try writer.print("var tmp_{d}: lua.Iterator = undefined;\n", .{iter_temp});
            try emitIndent(writer, depth);
            try writer.print("tmp_{d} = ", .{iter_temp});
            try emitIteratorInit(writer, ctx, op.iterator_exprs, depth);
            try writer.writeAll(";\n");
            try ctx.beginScope();
            var uses_pair_capture = false;
            for (op.names, 0..) |name, idx| {
                const local_id = try ctx.declareLocal(name);
                local_ids[idx] = local_id;
                ctx.setLocalFact(local_id, .unknown);
                if (localShouldEmit(ctx, local_id)) uses_pair_capture = true;
            }
            try emitIndent(writer, depth);
            try writer.writeAll("while (try lua.generatedIteratorNext(&tmp_");
            try writer.print("{d}", .{iter_temp});
            if (uses_pair_capture) {
                try writer.print(")) |pair_{d}| {{\n", .{pair_temp});
            } else {
                try writer.writeAll(")) |_| {\n");
            }
            for (op.names, 0..) |_, idx| {
                const local_id = local_ids[idx];
                if (!localShouldEmit(ctx, local_id)) continue;
                try emitIndent(writer, depth + 1);
                if (idx == 0) {
                    try writer.writeAll(localBindingKeyword(ctx, local_id));
                    try writer.writeByte(' ');
                    try emitLocalIdentifier(writer, ctx, local_id);
                    try writer.print(": lua.Value = pair_{d}[0];\n", .{pair_temp});
                } else if (idx == 1) {
                    try writer.writeAll(localBindingKeyword(ctx, local_id));
                    try writer.writeByte(' ');
                    try emitLocalIdentifier(writer, ctx, local_id);
                    try writer.print(": lua.Value = pair_{d}[1];\n", .{pair_temp});
                } else {
                    try writer.writeAll(localBindingKeyword(ctx, local_id));
                    try writer.writeByte(' ');
                    try emitLocalIdentifier(writer, ctx, local_id);
                    try writer.writeAll(": lua.Value = lua.Value.nil;\n");
                }
            }
            try emitStmtSlice(writer, ctx, op.body, depth + 1);
            var loop_path = try ctx.snapshotFactsAlloc();
            defer loop_path.deinit(ctx.state.allocator);
            ctx.endScope();
            try emitIndent(writer, depth);
            try writer.writeAll("}\n");
            var merged_facts = try mergeSnapshotFactsAlloc(ctx.state.allocator, &original_facts, &.{loop_path});
            defer merged_facts.deinit(ctx.state.allocator);
            try ctx.restoreFacts(&merged_facts);
        },
        .return_stmt => |op| {
            try emitIndent(writer, depth);
            if (ctx.uses_return_block) {
                if (op.exprs.len == 0) {
                    try writer.writeAll("return_result = &.{};\n");
                    try emitIndent(writer, depth);
                    try writer.writeAll("break :lua_fn;\n");
                } else {
                    try writer.writeAll("return_result = try runtime.allocValues(&.{ ");
                    for (op.exprs, 0..) |expr, idx| {
                        if (idx != 0) try writer.writeAll(", ");
                        try emitExpr(writer, ctx, expr, depth);
                    }
                    try writer.writeAll(" });\n");
                    try emitIndent(writer, depth);
                    try writer.writeAll("break :lua_fn;\n");
                }
            } else {
                if (op.exprs.len == 0) {
                    try writer.writeAll("return try runtime.allocValues(&.{});\n");
                } else {
                    try writer.writeAll("return try runtime.allocValues(&.{ ");
                    for (op.exprs, 0..) |expr, idx| {
                        if (idx != 0) try writer.writeAll(", ");
                        try emitExpr(writer, ctx, expr, depth);
                    }
                    try writer.writeAll(" });\n");
                }
            }
        },
        .break_stmt => {
            try emitIndent(writer, depth);
            try writer.writeAll("break;\n");
        },
        .expr_stmt => |expr| {
            try emitIndent(writer, depth);
            try writer.writeAll("_ = ");
            try emitExpr(writer, ctx, expr, depth);
            try writer.writeAll(";\n");
        },
    }
}

fn emitStoreTarget(
    writer: anytype,
    ctx: *DirectEmitFunctionContext,
    target: LValue,
    temp_id: u32,
    fact: KnownValueFact,
    depth: usize,
) anyerror!void {
    switch (target) {
        .name => |name| {
            if (ctx.lookupLocal(name)) |local_id| {
                ctx.clearMethodBindingsForOwner(.{ .local = local_id });
                if (!ctx.local_used[local_id]) {
                    try emitIndent(writer, depth);
                    try writer.print("_ = tmp_{d};\n", .{temp_id});
                    return;
                }
                try emitIndent(writer, depth);
                try emitLocalIdentifier(writer, ctx, local_id);
                try writer.print(" = tmp_{d};\n", .{temp_id});
                return;
            }
            if (ctx.lookupCapture(name)) |capture_id| {
                ctx.clearMethodBindingsForOwner(.{ .capture = capture_id });
                try emitIndent(writer, depth);
                try writer.writeAll("capture.");
                try emitCaptureFieldIdentifier(writer, ctx, capture_id);
                try writer.print(".* = tmp_{d};\n", .{temp_id});
                return;
            }
            const global_id = ctx.state.globalId(name) orelse return debugEmitUnknownVariable(ctx, "global", name);
            ctx.clearMethodBindingsForOwner(.{ .global = global_id });
            try emitIndent(writer, depth);
            try writer.writeAll("globals.");
            try emitGlobalFieldIdentifier(writer, ctx.state, global_id);
            try writer.print(" = tmp_{d};\n", .{temp_id});
        },
        .field => |field| {
            const object_tmp = ctx.nextTemp();
            try emitIndent(writer, depth);
            try writer.print("const tmp_{d}: lua.Value = ", .{object_tmp});
            try emitExpr(writer, ctx, field.object, depth);
            try writer.writeAll(";\n");
            try emitIndent(writer, depth);
            try writer.print("if (tmp_{d} != .table) return error.InvalidIndex;\n", .{object_tmp});
            try emitIndent(writer, depth);
            try writer.print("try tmp_{d}.table.putString(", .{object_tmp});
            try writeZigStringLiteral(writer, field.name);
            try writer.print(", tmp_{d});\n", .{temp_id});
            if (callableIdForKnownFact(ctx.state, fact)) |callable_id| {
                _ = try ctx.state.recordMethodCallableId(field.name, callable_id);
            }
            if (ctx.bindingOwnerForExpr(field.object)) |owner| {
                switch (fact) {
                    .direct_function_id, .static_callable_id, .generated_callable_id => try ctx.setMethodBinding(owner, field.name, fact, .{ .temp = temp_id }),
                    else => ctx.removeMethodBinding(owner, field.name),
                }
            }
        },
        .index => |index| {
            const object_tmp = ctx.nextTemp();
            const key_tmp = ctx.nextTemp();
            try emitIndent(writer, depth);
            try writer.print("const tmp_{d}: lua.Value = ", .{object_tmp});
            try emitExpr(writer, ctx, index.object, depth);
            try writer.writeAll(";\n");
            try emitIndent(writer, depth);
            try writer.print("const tmp_{d}: lua.Value = ", .{key_tmp});
            try emitExpr(writer, ctx, index.key, depth);
            try writer.writeAll(";\n");
            try emitIndent(writer, depth);
            try writer.print("if (tmp_{d} != .table) return error.InvalidIndex;\n", .{object_tmp});
            try emitIndent(writer, depth);
            try writer.print("try tmp_{d}.table.set(tmp_{d}, tmp_{d});\n", .{ object_tmp, key_tmp, temp_id });
        },
    }
}

fn emitIteratorInit(writer: anytype, ctx: *DirectEmitFunctionContext, exprs: []const *Expr, depth: usize) anyerror!void {
    if (exprs.len != 0 and exprs[0].* == .call) {
        const call = exprs[0].call;
        if (matchBuiltinCall(call)) |builtin| switch (builtin) {
            .pairs => {
                try writer.writeAll("try lua.generatedPairsIterator(");
                if (call.args.len != 0) {
                    try emitExpr(writer, ctx, call.args[0], depth);
                } else {
                    try writer.writeAll("lua.Value.nil");
                }
                try writer.writeAll(")");
                return;
            },
            .ipairs => {
                try writer.writeAll("try lua.generatedIpairsIterator(");
                if (call.args.len != 0) {
                    try emitExpr(writer, ctx, call.args[0], depth);
                } else {
                    try writer.writeAll("lua.Value.nil");
                }
                try writer.writeAll(")");
                return;
            },
            else => {},
        };
    }
    const label_id = ctx.nextTemp();
    const iter_id = ctx.nextTemp();
    try writer.print("blk_{d}: {{ const tmp_{d} = ", .{ label_id, iter_id });
    if (exprs.len != 0) {
        try emitExpr(writer, ctx, exprs[0], depth);
    } else {
        try writer.writeAll("lua.Value.nil");
    }
    try writer.print("; if (tmp_{d} != .iterator) return error.UnsupportedGenericFor; break :blk_{d} tmp_{d}.iterator; }}", .{ iter_id, label_id, iter_id });
}

fn emitFunctionValueExpr(writer: anytype, ctx: *DirectEmitFunctionContext, info: *const DirectFunctionInfo, depth: usize) anyerror!void {
    try seedChildCaptureFacts(ctx, info);
    try seedChildCaptureMethodBindings(ctx, info);
    const label_id = ctx.nextTemp();
    try writer.print("blk_{d}: {{\n", .{label_id});
    if (info.captures.len != 0) {
        try emitIndent(writer, depth + 1);
        try writer.print("const capture_obj = try runtime.alloc().create(Capture_{d});\n", .{info.id});
        try emitIndent(writer, depth + 1);
        try writer.writeAll("capture_obj.* = .{\n");
        for (info.captures, 0..) |capture, idx| {
            try emitIndent(writer, depth + 2);
            try writer.writeByte('.');
            try emitGeneratedIdentifier(writer, "lua_capture_", capture.name, idx);
            try writer.writeAll(" = ");
            switch (capture.origin) {
                .parent_local => {
                    const local_id = ctx.lookupLocal(capture.name) orelse return debugEmitUnknownVariable(ctx, "capture parent_local", capture.name);
                    try writer.writeByte('&');
                    try emitLocalIdentifier(writer, ctx, local_id);
                    try writer.writeAll(",\n");
                },
                .parent_capture => {
                    const capture_id = ctx.lookupCapture(capture.name) orelse return debugEmitUnknownVariable(ctx, "capture parent_capture", capture.name);
                    try writer.writeAll("capture.");
                    try emitCaptureFieldIdentifier(writer, ctx, capture_id);
                    try writer.writeAll(",\n");
                },
            }
        }
        try emitIndent(writer, depth + 1);
        try writer.writeAll("};\n");
        try emitIndent(writer, depth + 1);
        try writer.print("break :blk_{d} runtime.generatedCallableValue(", .{label_id});
        try emitGeneratedCallableIdLiteral(writer, ctx.state, info.id, .function);
        try writer.writeAll(", capture_obj, globals);\n");
    } else {
        try emitIndent(writer, depth + 1);
        try writer.print("break :blk_{d} runtime.generatedCallableValue(", .{label_id});
        try emitGeneratedCallableIdLiteral(writer, ctx.state, info.id, .function);
        try writer.writeAll(", null, globals);\n");
    }
    try emitIndent(writer, depth);
    try writer.writeAll("}");
}

const GeneratedCallableIdKind = enum {
    function,
    require,
    load_data,
};

fn emitGeneratedCallableIdLiteral(
    writer: anytype,
    state: *const DirectModuleState,
    function_id: u32,
    comptime kind: GeneratedCallableIdKind,
) !void {
    const base = state.options.callable_id_base;
    const value: u32 = switch (kind) {
        .function => base + function_id,
        .require => generated_callable_id_module_require,
        .load_data => generated_callable_id_module_load_data,
    };
    try writer.print("{d}", .{value});
}

fn emitMethodBindingSourceExpr(
    writer: anytype,
    ctx: *DirectEmitFunctionContext,
    source: DirectMethodBindingSource,
) !void {
    switch (source) {
        .temp => |temp_id| try writer.print("tmp_{d}", .{temp_id}),
        .local => |local_id| try emitLocalIdentifier(writer, ctx, local_id),
        .capture => |capture_id| {
            try writer.writeAll("capture.");
            try emitCaptureFieldIdentifier(writer, ctx, capture_id);
            try writer.writeAll(".*");
        },
        .global => |global_id| {
            try writer.writeAll("globals.");
            try emitGlobalFieldIdentifier(writer, ctx.state, global_id);
        },
    }
}

fn emitDirectFunctionCall(
    writer: anytype,
    ctx: *DirectEmitFunctionContext,
    function_id: u32,
    receiver_temp_id: ?u32,
    args: []const *Expr,
    depth: usize,
) !void {
    const info = &ctx.state.functions.items[function_id];
    if (info.captures.len == 0) {
        try writer.writeAll("lua.generatedResultsFirst(try fn_");
        try writer.print("{d}", .{function_id});
        try writer.writeAll("(null, globals, runtime, &.{");
        if (receiver_temp_id) |temp_id| {
            try writer.print(" tmp_{d}", .{temp_id});
            if (args.len != 0) try writer.writeAll(",");
        }
        for (args, 0..) |arg, idx| {
            if (idx != 0 or receiver_temp_id != null) try writer.writeAll(" ");
            try emitExpr(writer, ctx, arg, depth);
            if (idx + 1 != args.len) try writer.writeAll(",");
        }
        try writer.writeAll(" }))");
        return;
    }

    const label_id = ctx.nextTemp();
    const capture_temp_id = ctx.nextTemp();
    try writer.print("blk_{d}: {{ var tmp_{d}: Capture_{d} = .{{\n", .{
        label_id,
        capture_temp_id,
        function_id,
    });
    for (info.captures, 0..) |capture, capture_idx| {
        try emitIndent(writer, depth + 1);
        try writer.writeByte('.');
        try emitGeneratedIdentifier(writer, "lua_capture_", capture.name, capture_idx);
        try writer.writeAll(" = ");
        switch (capture.origin) {
            .parent_local => {
                const local_id = ctx.lookupLocal(capture.name) orelse return debugEmitUnknownVariable(ctx, "direct-call parent_local", capture.name);
                try writer.writeAll("&");
                try emitLocalIdentifier(writer, ctx, local_id);
            },
            .parent_capture => {
                const capture_id = ctx.lookupCapture(capture.name) orelse return debugEmitUnknownVariable(ctx, "direct-call parent_capture", capture.name);
                try writer.writeAll("capture.");
                try emitCaptureFieldIdentifier(writer, ctx, capture_id);
            },
        }
        try writer.writeAll(",\n");
    }
    try emitIndent(writer, depth);
    try writer.writeAll("}; break :blk_");
    try writer.print("{d}", .{label_id});
    try writer.writeAll(" lua.generatedResultsFirst(try fn_");
    try writer.print("{d}", .{function_id});
    try writer.print("(&tmp_{d}, globals, runtime, &.{{", .{capture_temp_id});
    if (receiver_temp_id) |temp_id| {
        try writer.print(" tmp_{d}", .{temp_id});
        if (args.len != 0) try writer.writeAll(",");
    }
    for (args, 0..) |arg, idx| {
        if (idx != 0 or receiver_temp_id != null) try writer.writeAll(" ");
        try emitExpr(writer, ctx, arg, depth);
        if (idx + 1 != args.len) try writer.writeAll(",");
    }
    try writer.writeAll(" })); }");
}

fn emitExpr(writer: anytype, ctx: *DirectEmitFunctionContext, expr: *const Expr, depth: usize) anyerror!void {
    switch (expr.*) {
        .nil_lit => try writer.writeAll("lua.Value.nil"),
        .bool_lit => |value| try writer.print("lua.Value{{ .boolean = {} }}", .{value}),
        .number_lit => |value| {
            try writer.writeAll("lua.Value{ .number = ");
            try emitZigNumberLiteral(writer, value);
            try writer.writeAll(" }");
        },
        .string_lit => |value| {
            try writer.writeAll("lua.Value{ .string = ");
            try writeZigStringLiteral(writer, value);
            try writer.writeAll(" }");
        },
        .variable => |name| {
            if (ctx.lookupLocal(name)) |local_id| {
                try emitLocalIdentifier(writer, ctx, local_id);
            } else if (ctx.lookupCapture(name)) |capture_id| {
                try writer.writeAll("capture.");
                try emitCaptureFieldIdentifier(writer, ctx, capture_id);
                try writer.writeAll(".*");
            } else {
                const global_id = ctx.state.globalId(name) orelse return debugEmitUnknownVariable(ctx, "expr global", name);
                try writer.writeAll("globals.");
                try emitGlobalFieldIdentifier(writer, ctx.state, global_id);
            }
        },
        .varargs => try writer.writeAll("(if (varargs.len != 0) varargs[0] else @as(lua.Value, .nil))"),
        .unary => |op| {
            try writer.print("try lua.executeUnaryValueAlloc(.{s}, ", .{formatTagName(UnaryOp, op.op)});
            try emitExpr(writer, ctx, op.expr, depth);
            try writer.writeAll(")");
        },
        .binary => |op| switch (op.op) {
            .and_ => {
                const label_id = ctx.nextTemp();
                const lhs_id = ctx.nextTemp();
                try writer.print("blk_{d}: {{ const tmp_{d} = ", .{ label_id, lhs_id });
                try emitExpr(writer, ctx, op.lhs, depth);
                try writer.print("; if (!tmp_{d}.truthy()) break :blk_{d} tmp_{d}; break :blk_{d} ", .{ lhs_id, label_id, lhs_id, label_id });
                try emitExpr(writer, ctx, op.rhs, depth);
                try writer.writeAll("; }");
            },
            .or_ => {
                const label_id = ctx.nextTemp();
                const lhs_id = ctx.nextTemp();
                try writer.print("blk_{d}: {{ const tmp_{d} = ", .{ label_id, lhs_id });
                try emitExpr(writer, ctx, op.lhs, depth);
                try writer.print("; if (tmp_{d}.truthy()) break :blk_{d} tmp_{d}; break :blk_{d} ", .{ lhs_id, label_id, lhs_id, label_id });
                try emitExpr(writer, ctx, op.rhs, depth);
                try writer.writeAll("; }");
            },
            else => {
                const label_id = ctx.nextTemp();
                const lhs_id = ctx.nextTemp();
                const rhs_id = ctx.nextTemp();
                try writer.print("blk_{d}: {{ const tmp_{d} = ", .{ label_id, lhs_id });
                try emitExpr(writer, ctx, op.lhs, depth);
                try writer.print("; const tmp_{d} = ", .{rhs_id});
                try emitExpr(writer, ctx, op.rhs, depth);
                try writer.print("; break :blk_{d} try lua.executeBinaryValueAlloc(runtime.alloc(), .", .{label_id});
                try writer.print("{s}", .{formatTagName(BinaryOp, op.op)});
                try writer.print(", tmp_{d}, tmp_{d}); }}", .{ lhs_id, rhs_id });
            },
        },
        .table_ctor => |fields| {
            const label_id = ctx.nextTemp();
            const table_id = ctx.nextTemp();
            try writer.print("blk_{d}: {{\n", .{label_id});
            try emitIndent(writer, depth + 1);
            try writer.print("const tmp_{d} = try lua.Table.init(runtime.alloc());\n", .{table_id});
            for (fields) |field| switch (field) {
                .array => |value| {
                    try emitIndent(writer, depth + 1);
                    try writer.print("try tmp_{d}.array.append(runtime.alloc(), ", .{table_id});
                    try emitExpr(writer, ctx, value, depth + 1);
                    try writer.writeAll(");\n");
                },
                .named => |named| {
                    const value_temp = ctx.nextTemp();
                    try emitIndent(writer, depth + 1);
                    try writer.print("const tmp_{d}: lua.Value = ", .{value_temp});
                    try emitExpr(writer, ctx, named.value, depth + 1);
                    try writer.writeAll(";\n");
                    try emitIndent(writer, depth + 1);
                    try writer.print("try tmp_{d}.putString(", .{table_id});
                    try writeZigStringLiteral(writer, named.name);
                    try writer.print(", tmp_{d});\n", .{value_temp});
                    const fact = knownValueFactForExpr(ctx, named.value);
                    if (callableIdForKnownFact(ctx.state, fact)) |callable_id| {
                        _ = try @constCast(ctx.state).recordMethodCallableId(named.name, callable_id);
                    }
                },
                .indexed => |indexed| {
                    try emitIndent(writer, depth + 1);
                    try writer.print("try tmp_{d}.set(", .{table_id});
                    try emitExpr(writer, ctx, indexed.key, depth + 1);
                    try writer.writeAll(", ");
                    try emitExpr(writer, ctx, indexed.value, depth + 1);
                    try writer.writeAll(");\n");
                },
            };
            try emitIndent(writer, depth + 1);
            try writer.print("break :blk_{d} lua.Value{{ .table = tmp_{d} }};\n", .{ label_id, table_id });
            try emitIndent(writer, depth);
            try writer.writeAll("}");
        },
        .const_table => |table| try writer.print("lua.Value{{ .table = try lua.cloneConstTableSeedAlloc(runtime.alloc(), &const_table_{d}) }}", .{ctx.state.tables.tableId(table).?}),
        .field => |field| {
            switch (knownValueFactForExpr(ctx, expr)) {
                .static_callable_id => |callable_id| {
                    try writer.writeAll("runtime.generatedCallableValue(");
                    try writer.print("{d}", .{callable_id});
                    try writer.writeAll(", null, globals)");
                    return;
                },
                .generated_callable_id => |callable_id| {
                    const label_id = ctx.nextTemp();
                    const object_id = ctx.nextTemp();
                    try writer.print("blk_{d}: {{ const tmp_{d} = ", .{ label_id, object_id });
                    try emitExpr(writer, ctx, field.object, depth);
                    _ = callable_id;
                    try writer.print("; if (tmp_{d} != .table) return error.InvalidIndex; break :blk_{d} tmp_{d}.table.getString(", .{
                        object_id,
                        label_id,
                        object_id,
                    });
                    try writeZigStringLiteral(writer, field.name);
                    try writer.writeAll("); }");
                    return;
                },
                .dispatch_fn => |dispatch| switch (dispatch) {
                    .mw_load_data => {
                        try writer.writeAll("runtime.generatedCallableValue(");
                        try emitGeneratedCallableIdLiteral(writer, ctx.state, 0, .load_data);
                        try writer.writeAll(", null, globals)");
                        return;
                    },
                    else => {},
                },
                .module_export => |module_export| {
                    if (try singleKnownCanonicalModuleIndex(ctx.state, ctx.state.allocator, module_export.module_values)) |module_index| {
                        const export_id = ctx.state.moduleExportId(module_index, module_export.function_name) orelse return error.UnknownVariable;
                        try writer.writeAll("try generatedModuleExportValueByIndex(runtime, ");
                        try writer.print("{d}", .{module_index});
                        try writer.writeAll(", ");
                        try writer.print("{d}", .{export_id});
                        try writer.writeAll(")");
                    } else {
                        try emitStaticUnknownModuleNameExpr(writer, ctx);
                    }
                    return;
                },
                else => {},
            }
            const label_id = ctx.nextTemp();
            const object_id = ctx.nextTemp();
            try writer.print("blk_{d}: {{ const tmp_{d} = ", .{ label_id, object_id });
            try emitExpr(writer, ctx, field.object, depth);
            try writer.print("; if (tmp_{d} != .table) return error.InvalidIndex; break :blk_{d} tmp_{d}.table.getString(", .{ object_id, label_id, object_id });
            try writeZigStringLiteral(writer, field.name);
            try writer.writeAll("); }");
        },
        .index => |index| {
            switch (knownValueFactForExpr(ctx, expr)) {
                .static_callable_id => |callable_id| {
                    try writer.writeAll("runtime.generatedCallableValue(");
                    try writer.print("{d}", .{callable_id});
                    try writer.writeAll(", null, globals)");
                    return;
                },
                .dispatch_fn => |dispatch| switch (dispatch) {
                    .mw_load_data => {
                        try writer.writeAll("runtime.generatedCallableValue(");
                        try emitGeneratedCallableIdLiteral(writer, ctx.state, 0, .load_data);
                        try writer.writeAll(", null, globals)");
                        return;
                    },
                    else => {},
                },
                .module_export => |module_export| {
                    if (try singleKnownCanonicalModuleIndex(ctx.state, ctx.state.allocator, module_export.module_values)) |module_index| {
                        const export_id = ctx.state.moduleExportId(module_index, module_export.function_name) orelse return error.UnknownVariable;
                        try writer.writeAll("try generatedModuleExportValueByIndex(runtime, ");
                        try writer.print("{d}", .{module_index});
                        try writer.writeAll(", ");
                        try writer.print("{d}", .{export_id});
                        try writer.writeAll(")");
                    } else {
                        try emitStaticUnknownModuleNameExpr(writer, ctx);
                    }
                    return;
                },
                else => {},
            }
            const label_id = ctx.nextTemp();
            const object_id = ctx.nextTemp();
            const key_id = ctx.nextTemp();
            try writer.print("blk_{d}: {{ const tmp_{d} = ", .{ label_id, object_id });
            try emitExpr(writer, ctx, index.object, depth);
            try writer.print("; const tmp_{d} = ", .{key_id});
            try emitExpr(writer, ctx, index.key, depth);
            try writer.print("; if (tmp_{d} != .table) return error.InvalidIndex; break :blk_{d} tmp_{d}.table.get(tmp_{d}); }}", .{ object_id, label_id, object_id, key_id });
        },
        .call => |call| {
            if (matchBuiltinCall(call)) |builtin| {
                try emitBuiltinCall(writer, ctx, builtin, call.args, depth);
            } else if (matchMethodCall(call)) |method| {
                try emitMethodCall(writer, ctx, method, depth);
            } else {
                if (ctx.state.options.enable_direct_module_dispatch) {
                    if (knownInvokeLoweringForExpr(ctx, call.callee)) |dispatch| {
                        try emitDirectInvokeLoweringCall(writer, ctx, dispatch, call.callee, call.args, depth);
                        return;
                    }
                }
                if (call.callee.* == .field) {
                    const field = call.callee.field;
                    if (ctx.lookupMethodBinding(field.object, field.name)) |binding| {
                        const label_id = ctx.nextTemp();
                        switch (binding.fact) {
                            .direct_function_id => |function_id| {
                                try writer.print("blk_{d}: {{ break :blk_{d} ", .{ label_id, label_id });
                                if (canDirectCallFunctionFromContext(ctx, function_id)) {
                                    try emitDirectFunctionCall(writer, ctx, function_id, null, call.args, depth);
                                } else {
                                    try emitDirectKnownCallableFirst(
                                        writer,
                                        ctx,
                                        stateGeneratedCallableId(ctx.state, function_id),
                                        .{ .binding = binding.source },
                                        null,
                                        call.args,
                                        depth,
                                    );
                                }
                                try writer.writeAll("; }");
                            },
                            .static_callable_id => |callable_id| {
                                try writer.print("blk_{d}: {{ break :blk_{d} ", .{ label_id, label_id });
                                try emitDirectKnownCallableFirst(writer, ctx, callable_id, .none, null, call.args, depth);
                                try writer.writeAll("; }");
                            },
                            .generated_callable_id => |callable_id| {
                                try writer.print("blk_{d}: {{ break :blk_{d} ", .{ label_id, label_id });
                                try emitDirectKnownCallableFirst(
                                    writer,
                                    ctx,
                                    callable_id,
                                    if (generatedCallableNeedsSource(ctx.state, callable_id))
                                        .{ .binding = binding.source }
                                    else
                                        .none,
                                    null,
                                    call.args,
                                    depth,
                                );
                                try writer.writeAll("; }");
                            },
                            else => return error.InvalidCall,
                        }
                        return;
                    }
                    const label_id = ctx.nextTemp();
                    const object_id = ctx.nextTemp();
                    try writer.print("blk_{d}: {{ const tmp_{d} = ", .{ label_id, object_id });
                    try emitExpr(writer, ctx, field.object, depth);
                    try writer.print("; if (tmp_{d} != .table) return error.InvalidIndex;", .{object_id});
                    switch (knownValueFactForExpr(ctx, call.callee)) {
                        .static_callable_id => |callable_id| {
                            try writer.print(" break :blk_{d} ", .{label_id});
                            try emitDirectKnownCallableFirst(writer, ctx, callable_id, .none, null, call.args, depth);
                            try writer.writeAll("; }");
                            return;
                        },
                        .generated_callable_id => |callable_id| {
                            if (generatedCallableNeedsSource(ctx.state, callable_id)) {
                                const callee_id = ctx.nextTemp();
                                try writer.print(" const tmp_{d} = tmp_{d}.table.getString(", .{
                                    callee_id,
                                    object_id,
                                });
                                try writeZigStringLiteral(writer, field.name);
                                try writer.print("); break :blk_{d} ", .{label_id});
                                try emitDirectKnownCallableFirst(writer, ctx, callable_id, .{ .temp = callee_id }, null, call.args, depth);
                            } else {
                                try writer.print(" break :blk_{d} ", .{label_id});
                                try emitDirectKnownCallableFirst(writer, ctx, callable_id, .none, null, call.args, depth);
                            }
                            try writer.writeAll("; }");
                            return;
                        },
                        .dispatch_fn => |dispatch| switch (dispatch) {
                            .mw_load_data => {
                                try writer.print(" break :blk_{d} ", .{label_id});
                                try emitDirectKnownCallableFirst(writer, ctx, generated_callable_id_module_load_data, .none, null, call.args, depth);
                                try writer.writeAll("; }");
                                return;
                            },
                            else => {
                                const callee_id = ctx.nextTemp();
                                try writer.print(" const tmp_{d} = tmp_{d}.table.getString(", .{
                                    callee_id,
                                    object_id,
                                });
                                try writeZigStringLiteral(writer, field.name);
                                try writer.print("); break :blk_{d} try ", .{label_id});
                                try writer.writeAll(ctx.state.options.call_dispatch_helper_name);
                                try writer.print("(runtime, tmp_{d}, &.{{ ", .{callee_id});
                            },
                        },
                        else => {
                            const callee_id = ctx.nextTemp();
                            try writer.print(" const tmp_{d} = tmp_{d}.table.getString(", .{
                                callee_id,
                                object_id,
                            });
                            try writeZigStringLiteral(writer, field.name);
                            try writer.print("); break :blk_{d} try ", .{label_id});
                            try writer.writeAll(ctx.state.options.call_dispatch_helper_name);
                            try writer.print("(runtime, tmp_{d}, &.{{ ", .{callee_id});
                        },
                    }
                    for (call.args, 0..) |arg, idx| {
                        if (idx != 0) try writer.writeAll(", ");
                        try emitExpr(writer, ctx, arg, depth);
                    }
                    try writer.writeAll(" }); }");
                    return;
                }
                const callee_fact = knownValueFactForExpr(ctx, call.callee);
                switch (callee_fact) {
                    .direct_function_id => |function_id| {
                        const label_id = ctx.nextTemp();
                        try writer.print("blk_{d}: {{ break :blk_{d} ", .{ label_id, label_id });
                        if (canDirectCallFunctionFromContext(ctx, function_id)) {
                            try emitDirectFunctionCall(writer, ctx, function_id, null, call.args, depth);
                        } else {
                            try emitDirectKnownCallableFirst(
                                writer,
                                ctx,
                                stateGeneratedCallableId(ctx.state, function_id),
                                .{ .expr = call.callee },
                                null,
                                call.args,
                                depth,
                            );
                        }
                        try writer.writeAll("; }");
                        return;
                    },
                    .static_callable_id => |callable_id| {
                        const label_id = ctx.nextTemp();
                        try writer.print("blk_{d}: {{ break :blk_{d} ", .{ label_id, label_id });
                        try emitDirectKnownCallableFirst(writer, ctx, callable_id, .none, null, call.args, depth);
                        try writer.writeAll("; }");
                        return;
                    },
                    .generated_callable_id => |callable_id| {
                        if (!generatedCallableNeedsSource(ctx.state, callable_id)) {
                            const label_id = ctx.nextTemp();
                            try writer.print("blk_{d}: {{ break :blk_{d} ", .{ label_id, label_id });
                            try emitDirectKnownCallableFirst(writer, ctx, callable_id, .none, null, call.args, depth);
                            try writer.writeAll("; }");
                            return;
                        }
                    },
                    else => {},
                }

                const label_id = ctx.nextTemp();
                const callee_id = ctx.nextTemp();
                try writer.print("blk_{d}: {{ const tmp_{d} = ", .{ label_id, callee_id });
                try emitExpr(writer, ctx, call.callee, depth);
                switch (callee_fact) {
                    .direct_function_id => |function_id| {
                        try writer.writeAll("; break :blk_");
                        try writer.print("{d}", .{label_id});
                        try writer.writeAll(" ");
                        if (canDirectCallFunctionFromContext(ctx, function_id)) {
                            try emitDirectFunctionCall(writer, ctx, function_id, null, call.args, depth);
                        } else {
                            try emitDirectKnownCallableFirst(
                                writer,
                                ctx,
                                stateGeneratedCallableId(ctx.state, function_id),
                                .{ .temp = callee_id },
                                null,
                                call.args,
                                depth,
                            );
                        }
                        try writer.writeAll("; }");
                        return;
                    },
                    .static_callable_id => |callable_id| {
                        try writer.writeAll("; break :blk_");
                        try writer.print("{d}", .{label_id});
                        try writer.writeAll(" ");
                        try emitDirectKnownCallableFirst(writer, ctx, callable_id, .none, null, call.args, depth);
                        try writer.writeAll("; }");
                        return;
                    },
                    .generated_callable_id => |callable_id| {
                        try writer.writeAll("; break :blk_");
                        try writer.print("{d}", .{label_id});
                        try writer.writeAll(" ");
                        try emitDirectKnownCallableFirst(writer, ctx, callable_id, .{ .temp = callee_id }, null, call.args, depth);
                        try writer.writeAll("; }");
                        return;
                    },
                    else => {
                        try writer.writeAll("; break :blk_");
                        try writer.print("{d}", .{label_id});
                        try writer.writeAll(" try ");
                        try writer.writeAll(ctx.state.options.call_dispatch_helper_name);
                        try writer.print("(runtime, tmp_{d}, &.{{ ", .{callee_id});
                    },
                }
                for (call.args, 0..) |arg, idx| {
                    if (idx != 0) try writer.writeAll(", ");
                    try emitExpr(writer, ctx, arg, depth);
                }
                try writer.writeAll(" }); }");
            }
        },
        .function_lit => {
            const child_id = ctx.state.exprFunctionId(expr) orelse return error.UnsupportedSyntax;
            const child_info = &ctx.state.functions.items[child_id];
            try emitFunctionValueExpr(writer, ctx, child_info, depth);
        },
    }
}

fn emitZigNumberLiteral(writer: anytype, value: f64) !void {
    if (std.math.isNan(value)) {
        try writer.writeAll("std.math.nan(f64)");
        return;
    }
    if (std.math.isInf(value)) {
        try writer.writeAll(if (value < 0) "-std.math.inf(f64)" else "std.math.inf(f64)");
        return;
    }
    if (value == 0 and std.math.signbit(value)) {
        try writer.writeAll("-0.0");
        return;
    }
    var buf: [128]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buf, "{d}", .{value});
    try writer.writeAll(rendered);
    // Zig treats digit-only literals as integers. Force integer-looking floats
    // back into float syntax so large rounded values still compile as `f64`.
    if (std.mem.indexOfAny(u8, rendered, ".eEpP") == null) {
        try writer.writeAll(".0");
    }
}

fn matchMethodCall(call: @FieldType(Expr, "call")) ?DirectMethodCall {
    if (call.callee.* != .field or call.args.len == 0) return null;
    const field = call.callee.field;
    if (!exprStructurallyEquals(call.args[0], field.object)) return null;
    return .{
        .receiver = field.object,
        .name = field.name,
        .args = call.args[1..],
    };
}

fn exprStructurallyEquals(lhs: *const Expr, rhs: *const Expr) bool {
    if (lhs == rhs) return true;
    if (@intFromEnum(lhs.*) != @intFromEnum(rhs.*)) return false;
    return switch (lhs.*) {
        .nil_lit => true,
        .bool_lit => |value| value == rhs.bool_lit,
        .number_lit => |value| value == rhs.number_lit,
        .string_lit => |value| std.mem.eql(u8, value, rhs.string_lit),
        .variable => |value| std.mem.eql(u8, value, rhs.variable),
        .varargs => true,
        .unary => |value| value.op == rhs.unary.op and exprStructurallyEquals(value.expr, rhs.unary.expr),
        .binary => |value| value.op == rhs.binary.op and exprStructurallyEquals(value.lhs, rhs.binary.lhs) and exprStructurallyEquals(value.rhs, rhs.binary.rhs),
        .field => |value| std.mem.eql(u8, value.name, rhs.field.name) and exprStructurallyEquals(value.object, rhs.field.object),
        .index => |value| exprStructurallyEquals(value.object, rhs.index.object) and exprStructurallyEquals(value.key, rhs.index.key),
        else => false,
    };
}

fn matchBuiltinCall(call: @FieldType(Expr, "call")) ?DirectBuiltinCall {
    switch (call.callee.*) {
        .variable => |name| {
            if (std.mem.eql(u8, name, "print")) return .print;
            if (std.mem.eql(u8, name, "tostring")) return .tostring;
            if (std.mem.eql(u8, name, "tonumber")) return .tonumber;
            if (std.mem.eql(u8, name, "type")) return .type_;
            if (std.mem.eql(u8, name, "unpack")) return .unpack;
            if (std.mem.eql(u8, name, "pairs")) return .pairs;
            if (std.mem.eql(u8, name, "ipairs")) return .ipairs;
        },
        .field => |field| switch (field.object.*) {
            .variable => |object_name| {
                if (std.mem.eql(u8, object_name, "string")) {
                    if (std.mem.eql(u8, field.name, "len")) return .string_len;
                    if (std.mem.eql(u8, field.name, "lower")) return .string_lower;
                    if (std.mem.eql(u8, field.name, "upper")) return .string_upper;
                    if (std.mem.eql(u8, field.name, "sub")) return .string_sub;
                    if (std.mem.eql(u8, field.name, "gsub")) return .string_gsub;
                }
                if (std.mem.eql(u8, object_name, "math")) {
                    if (std.mem.eql(u8, field.name, "floor")) return .math_floor;
                    if (std.mem.eql(u8, field.name, "ceil")) return .math_ceil;
                    if (std.mem.eql(u8, field.name, "abs")) return .math_abs;
                }
                if (std.mem.eql(u8, object_name, "table")) {
                    if (std.mem.eql(u8, field.name, "insert")) return .table_insert;
                    if (std.mem.eql(u8, field.name, "remove")) return .table_remove;
                    if (std.mem.eql(u8, field.name, "sort")) return .table_sort;
                    if (std.mem.eql(u8, field.name, "unpack")) return .table_unpack;
                    if (std.mem.eql(u8, field.name, "concat")) return .table_concat;
                }
            },
            else => {},
        },
        else => {},
    }
    return null;
}

fn emitKnownCanonicalModuleIndicesLiteral(
    writer: anytype,
    state: *const DirectModuleState,
    allocator: std.mem.Allocator,
    values: KnownStringValues,
) !void {
    var owned: [max_known_string_values][]u8 = undefined;
    var owned_len: usize = 0;
    var canonical_indices: [max_known_string_values]u16 = undefined;
    var canonical_indices_len: usize = 0;
    defer {
        for (owned[0..owned_len]) |value| allocator.free(value);
    }

    for (values.slice()) |raw_value| {
        const canonical_owned = try canonicalModuleNameAlloc(allocator, raw_value);
        owned[owned_len] = canonical_owned;
        owned_len += 1;
        const canonical_value = if (std.mem.startsWith(u8, canonical_owned, "module:"))
            canonical_owned["module:".len..]
        else
            canonical_owned;
        const module_index = state.moduleDispatchIndex(canonical_value) orelse {
            std.debug.print("lua emit unknown direct module index: {s}\n", .{canonical_value});
            return error.UnknownVariable;
        };
        var duplicate = false;
        for (canonical_indices[0..canonical_indices_len]) |existing| {
            if (existing == module_index) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) {
            canonical_indices[canonical_indices_len] = module_index;
            canonical_indices_len += 1;
        }
    }

    try writer.writeAll("&.{ ");
    for (canonical_indices[0..canonical_indices_len], 0..) |value, idx| {
        if (idx != 0) try writer.writeAll(", ");
        try writer.print("{d}", .{value});
    }
    try writer.writeAll(" }");
}

fn singleKnownCanonicalModuleIndex(
    state: *const DirectModuleState,
    allocator: std.mem.Allocator,
    values: KnownStringValues,
) !?u16 {
    var owned: [max_known_string_values][]u8 = undefined;
    var owned_len: usize = 0;
    defer {
        for (owned[0..owned_len]) |value| allocator.free(value);
    }

    var single_index: ?u16 = null;
    for (values.slice()) |raw_value| {
        const canonical_owned = try canonicalModuleNameAlloc(allocator, raw_value);
        owned[owned_len] = canonical_owned;
        owned_len += 1;
        const canonical_value = if (std.mem.startsWith(u8, canonical_owned, "module:"))
            canonical_owned["module:".len..]
        else
            canonical_owned;
        const module_index = state.moduleDispatchIndex(canonical_value) orelse {
            std.debug.print("lua emit unknown direct module index: {s}\n", .{canonical_value});
            return error.UnknownVariable;
        };
        if (single_index) |existing| {
            if (existing != module_index) return null;
        } else {
            single_index = module_index;
        }
    }
    return single_index;
}

fn emitStaticUnknownModuleNameExpr(
    writer: anytype,
    ctx: *DirectEmitFunctionContext,
) !void {
    const label_id = ctx.nextTemp();
    try writer.print("blk_{d}: {{ return error.UnknownVariable; }}", .{label_id});
}

fn emitDirectModuleDispatchCall(
    writer: anytype,
    ctx: *DirectEmitFunctionContext,
    dispatch: DirectModuleDispatchCall,
    args: []const *Expr,
    depth: usize,
) anyerror!void {
    const known_values = if (args.len != 0) knownStringValuesForExpr(ctx, args[0]) else null;
    if (known_values) |values| {
        if (try singleKnownCanonicalModuleIndex(ctx.state, ctx.state.allocator, values)) |module_index| {
            try writer.writeAll("try generatedLoadCompiledModuleByIndex(runtime, ");
            try writer.print("{d}", .{module_index});
            try writer.writeAll(")");
            return;
        }
        try emitStaticUnknownModuleNameExpr(writer, ctx);
        return;
    }
    _ = dispatch;
    _ = depth;
    try emitStaticUnknownModuleNameExpr(writer, ctx);
}

fn emitDirectHelperDispatchCall(
    writer: anytype,
    ctx: *DirectEmitFunctionContext,
    helper: DirectHelperDispatchCall,
    args: []const *Expr,
    depth: usize,
) anyerror!void {
    _ = helper;
    if (args.len != 0) {
        const known_values = knownStringValuesForExpr(ctx, args[0]);
        if (known_values) |values| {
            if (try singleKnownCanonicalModuleIndex(ctx.state, ctx.state.allocator, values) == null) {
                try emitStaticUnknownModuleNameExpr(writer, ctx);
                return;
            }
        } else {
            try emitStaticUnknownModuleNameExpr(writer, ctx);
            return;
        }
    }

    const label_id = ctx.nextTemp();
    const module_id = ctx.nextTemp();
    try writer.print("blk_{d}: {{ const tmp_{d}: lua.Value = ", .{ label_id, module_id });
    if (args.len != 0) {
        const module_index = (try singleKnownCanonicalModuleIndex(ctx.state, ctx.state.allocator, knownStringValuesForExpr(ctx, args[0]).?)).?;
        try writer.writeAll("try generatedLoadCompiledModuleByIndex(runtime, ");
        try writer.print("{d}", .{module_index});
        try writer.writeAll(")");
    } else {
        try writer.writeAll("lua.Value.nil");
    }

    if (args.len <= 1) {
        try writer.print("; break :blk_{d} tmp_{d}; }}", .{ label_id, module_id });
        return;
    }

    var current_id = module_id;
    for (args[1..]) |arg| {
        const next_id = ctx.nextTemp();
        try writer.print("; if (tmp_{d} != .table) return error.InvalidIndex; const tmp_{d}: lua.Value = tmp_{d}.table.get(", .{
            current_id,
            next_id,
            current_id,
        });
        try emitExpr(writer, ctx, arg, depth);
        try writer.writeAll(")");
        current_id = next_id;
    }
    try writer.print("; break :blk_{d} tmp_{d}; }}", .{ label_id, current_id });
}

fn emitKnownModuleExportDispatchCall(
    writer: anytype,
    ctx: *DirectEmitFunctionContext,
    module_export: KnownModuleExportCall,
    callee_expr: *const Expr,
    args: []const *Expr,
    depth: usize,
) anyerror!void {
    _ = callee_expr;
    if (try singleKnownCanonicalModuleIndex(ctx.state, ctx.state.allocator, module_export.module_values)) |module_index| {
        const export_id = ctx.state.moduleExportId(module_index, module_export.function_name) orelse return error.UnknownVariable;
        try writer.writeAll("try generatedCallModuleExportByIndexFirst(runtime, ");
        try writer.print("{d}", .{module_index});
        try writer.writeAll(", ");
        try writer.print("{d}", .{export_id});
        try writer.writeAll(", &.{ ");
        for (args, 0..) |arg, idx| {
            if (idx != 0) try writer.writeAll(", ");
            try emitExpr(writer, ctx, arg, depth);
        }
        try writer.writeAll(" })");
        return;
    }
    try emitStaticUnknownModuleNameExpr(writer, ctx);
}

fn emitDirectInvokeLoweringCall(
    writer: anytype,
    ctx: *DirectEmitFunctionContext,
    lowering: DirectInvokeLowering,
    callee_expr: *const Expr,
    args: []const *Expr,
    depth: usize,
) anyerror!void {
    switch (lowering) {
        .module_dispatch => |dispatch| try emitDirectModuleDispatchCall(writer, ctx, dispatch, args, depth),
        .helper_dispatch => |helper| try emitDirectHelperDispatchCall(writer, ctx, helper, args, depth),
        .module_export => |module_export| try emitKnownModuleExportDispatchCall(writer, ctx, module_export, callee_expr, args, depth),
    }
}

fn emitMethodCall(
    writer: anytype,
    ctx: *DirectEmitFunctionContext,
    method: DirectMethodCall,
    depth: usize,
) anyerror!void {
    if (ctx.lookupMethodBinding(method.receiver, method.name)) |binding| {
        const label_id = ctx.nextTemp();
        const receiver_id = ctx.nextTemp();
        try writer.print("blk_{d}: {{ const tmp_{d} = ", .{ label_id, receiver_id });
        try emitExpr(writer, ctx, method.receiver, depth);
        switch (binding.fact) {
            .direct_function_id => |function_id| {
                try writer.print("; break :blk_{d} ", .{label_id});
                if (canDirectCallFunctionFromContext(ctx, function_id)) {
                    try emitDirectFunctionCall(writer, ctx, function_id, receiver_id, method.args, depth);
                } else {
                    try emitDirectKnownCallableFirst(
                        writer,
                        ctx,
                        stateGeneratedCallableId(ctx.state, function_id),
                        .{ .binding = binding.source },
                        receiver_id,
                        method.args,
                        depth,
                    );
                }
                try writer.writeAll("; }");
            },
            .static_callable_id => |callable_id| {
                try writer.print("; break :blk_{d} ", .{label_id});
                try emitDirectKnownCallableFirst(writer, ctx, callable_id, .none, receiver_id, method.args, depth);
                try writer.writeAll("; }");
            },
            .generated_callable_id => |callable_id| {
                try writer.print("; break :blk_{d} ", .{label_id});
                try emitDirectKnownCallableFirst(
                    writer,
                    ctx,
                    callable_id,
                    if (generatedCallableNeedsSource(ctx.state, callable_id))
                        .{ .binding = binding.source }
                    else
                        .none,
                    receiver_id,
                    method.args,
                    depth,
                );
                try writer.writeAll("; }");
            },
            else => return error.InvalidCall,
        }
        return;
    }

    if (genericStringMethodCallableId(method.name)) |callable_id| {
        const label_id = ctx.nextTemp();
        const receiver_id = ctx.nextTemp();
        try writer.print("blk_{d}: {{ const tmp_{d} = ", .{ label_id, receiver_id });
        try emitExpr(writer, ctx, method.receiver, depth);
        try writer.print("; break :blk_{d} ", .{label_id});
        try emitDirectKnownCallableFirst(writer, ctx, callable_id, .none, receiver_id, method.args, depth);
        try writer.writeAll("; }");
        return;
    }

    if (uniqueMethodCallableId(ctx.state, method.name)) |callable_id| {
        if (!generatedCallableNeedsSource(ctx.state, callable_id)) {
            const label_id = ctx.nextTemp();
            const receiver_id = ctx.nextTemp();
            try writer.print("blk_{d}: {{ const tmp_{d} = ", .{ label_id, receiver_id });
            try emitExpr(writer, ctx, method.receiver, depth);
            try writer.print("; break :blk_{d} ", .{label_id});
            try emitDirectKnownCallableFirst(writer, ctx, callable_id, .none, receiver_id, method.args, depth);
            try writer.writeAll("; }");
            return;
        }
    }

    const label_id = ctx.nextTemp();
    const receiver_id = ctx.nextTemp();

    try writer.print("blk_{d}: {{ const tmp_{d} = ", .{ label_id, receiver_id });
    try emitExpr(writer, ctx, method.receiver, depth);
    try writer.print("; if (tmp_{d} != .table) return error.InvalidIndex;", .{receiver_id});
    const method_field_expr = Expr{
        .field = .{
            .object = @constCast(method.receiver),
            .name = method.name,
        },
    };
    switch (knownValueFactForExpr(ctx, &method_field_expr)) {
        .static_callable_id => |callable_id| {
            try writer.print(" break :blk_{d} ", .{label_id});
            try emitDirectKnownCallableFirst(writer, ctx, callable_id, .none, receiver_id, method.args, depth);
            try writer.writeAll("; }");
            return;
        },
        .generated_callable_id => |callable_id| {
            if (generatedCallableNeedsSource(ctx.state, callable_id)) {
                const callee_id = ctx.nextTemp();
                try writer.print(" const tmp_{d} = tmp_{d}.table.getString(", .{
                    callee_id,
                    receiver_id,
                });
                try writeZigStringLiteral(writer, method.name);
                try writer.print("); break :blk_{d} ", .{label_id});
                try emitDirectKnownCallableFirst(writer, ctx, callable_id, .{ .temp = callee_id }, receiver_id, method.args, depth);
            } else {
                try writer.print(" break :blk_{d} ", .{label_id});
                try emitDirectKnownCallableFirst(writer, ctx, callable_id, .none, receiver_id, method.args, depth);
            }
            try writer.writeAll("; }");
            return;
        },
        .dispatch_fn => |dispatch| switch (dispatch) {
            .mw_load_data => {
                try writer.print(" break :blk_{d} ", .{label_id});
                try emitDirectKnownCallableFirst(writer, ctx, generated_callable_id_module_load_data, .none, receiver_id, method.args, depth);
                try writer.writeAll("; }");
                return;
            },
            else => {
                const callee_id = ctx.nextTemp();
                try writer.print(" const tmp_{d} = tmp_{d}.table.getString(", .{
                    callee_id,
                    receiver_id,
                });
                try writeZigStringLiteral(writer, method.name);
                try writer.print("); break :blk_{d} try ", .{label_id});
                try writer.writeAll(ctx.state.options.call_dispatch_helper_name);
                try writer.print("(runtime, tmp_{d}, &.{{ tmp_{d}", .{ callee_id, receiver_id });
            },
        },
        else => {
            const callee_id = ctx.nextTemp();
            try writer.print(" const tmp_{d} = tmp_{d}.table.getString(", .{
                callee_id,
                receiver_id,
            });
            try writeZigStringLiteral(writer, method.name);
            try writer.print("); break :blk_{d} try ", .{label_id});
            try writer.writeAll(ctx.state.options.call_dispatch_helper_name);
            try writer.print("(runtime, tmp_{d}, &.{{ tmp_{d}", .{ callee_id, receiver_id });
        },
    }
    for (method.args) |arg| {
        try writer.writeAll(", ");
        try emitExpr(writer, ctx, arg, depth);
    }
    try writer.writeAll(" }); }");
}

fn emitBuiltinCall(
    writer: anytype,
    ctx: *DirectEmitFunctionContext,
    builtin: DirectBuiltinCall,
    args: []const *Expr,
    depth: usize,
) anyerror!void {
    switch (builtin) {
        .print => {
            const label_id = ctx.nextTemp();
            try writer.print("blk_{d}: {{ _ = try lua.generatedPrint(runtime, &.{{ ", .{label_id});
            for (args, 0..) |arg, idx| {
                if (idx != 0) try writer.writeAll(", ");
                try emitExpr(writer, ctx, arg, depth);
            }
            try writer.print(" }}); break :blk_{d} lua.Value.nil; }}", .{label_id});
        },
        .tostring => {
            try writer.writeAll("try lua.generatedTostring(runtime, ");
            if (args.len != 0) try emitExpr(writer, ctx, args[0], depth) else try writer.writeAll("lua.Value.nil");
            try writer.writeAll(")");
        },
        .tonumber => {
            const label_id = ctx.nextTemp();
            try writer.print("blk_{d}: {{ ", .{label_id});
            if (args.len == 0) {
                try writer.print("break :blk_{d} lua.Value.nil; }}", .{label_id});
            } else {
                try writer.print("break :blk_{d} try lua.generatedTonumber(", .{label_id});
                try emitExpr(writer, ctx, args[0], depth);
                try writer.writeAll("); }");
            }
        },
        .type_ => {
            try writer.writeAll("lua.generatedType(");
            if (args.len != 0) try emitExpr(writer, ctx, args[0], depth) else try writer.writeAll("lua.Value.nil");
            try writer.writeAll(")");
        },
        .unpack => {
            try writer.writeAll("lua.generatedResultsFirst(try lua.generatedTableUnpack(runtime, ");
            if (args.len != 0) try emitExpr(writer, ctx, args[0], depth) else try writer.writeAll("lua.Value.nil");
            try writer.writeAll("))");
        },
        .pairs => {
            try writer.writeAll("lua.Value{ .iterator = try lua.generatedPairsIterator(");
            if (args.len != 0) try emitExpr(writer, ctx, args[0], depth) else try writer.writeAll("lua.Value.nil");
            try writer.writeAll(") }");
        },
        .ipairs => {
            try writer.writeAll("lua.Value{ .iterator = try lua.generatedIpairsIterator(");
            if (args.len != 0) try emitExpr(writer, ctx, args[0], depth) else try writer.writeAll("lua.Value.nil");
            try writer.writeAll(") }");
        },
        .string_len => {
            try writer.writeAll("try lua.generatedStringLen(");
            if (args.len != 0) try emitExpr(writer, ctx, args[0], depth) else try writer.writeAll("lua.Value.nil");
            try writer.writeAll(")");
        },
        .string_lower => {
            try writer.writeAll("try lua.generatedStringLower(runtime, ");
            if (args.len != 0) try emitExpr(writer, ctx, args[0], depth) else try writer.writeAll("lua.Value.nil");
            try writer.writeAll(")");
        },
        .string_upper => {
            try writer.writeAll("try lua.generatedStringUpper(runtime, ");
            if (args.len != 0) try emitExpr(writer, ctx, args[0], depth) else try writer.writeAll("lua.Value.nil");
            try writer.writeAll(")");
        },
        .string_sub => {
            try writer.writeAll("try lua.generatedStringSub(runtime, ");
            if (args.len != 0) try emitExpr(writer, ctx, args[0], depth) else try writer.writeAll("lua.Value.nil");
            try writer.writeAll(", ");
            if (args.len > 1) try emitExpr(writer, ctx, args[1], depth) else try writer.writeAll("lua.Value.nil");
            try writer.writeAll(", ");
            if (args.len > 2) {
                try emitExpr(writer, ctx, args[2], depth);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll(")");
        },
        .string_gsub => {
            try writer.writeAll("try lua.generatedStringGsub(runtime, ");
            if (args.len != 0) try emitExpr(writer, ctx, args[0], depth) else try writer.writeAll("lua.Value.nil");
            try writer.writeAll(", ");
            if (args.len > 1) try emitExpr(writer, ctx, args[1], depth) else try writer.writeAll("lua.Value.nil");
            try writer.writeAll(", ");
            if (args.len > 2) try emitExpr(writer, ctx, args[2], depth) else try writer.writeAll("lua.Value.nil");
            try writer.writeAll(")");
        },
        .math_floor => {
            try writer.writeAll("try lua.generatedMathFloor(");
            if (args.len != 0) try emitExpr(writer, ctx, args[0], depth) else try writer.writeAll("lua.Value.nil");
            try writer.writeAll(")");
        },
        .math_ceil => {
            try writer.writeAll("try lua.generatedMathCeil(");
            if (args.len != 0) try emitExpr(writer, ctx, args[0], depth) else try writer.writeAll("lua.Value.nil");
            try writer.writeAll(")");
        },
        .math_abs => {
            try writer.writeAll("try lua.generatedMathAbs(");
            if (args.len != 0) try emitExpr(writer, ctx, args[0], depth) else try writer.writeAll("lua.Value.nil");
            try writer.writeAll(")");
        },
        .table_insert => {
            try writer.writeAll("try lua.generatedTableInsert(");
            if (args.len != 0) try emitExpr(writer, ctx, args[0], depth) else try writer.writeAll("lua.Value.nil");
            try writer.writeAll(", ");
            if (args.len > 1) try emitExpr(writer, ctx, args[1], depth) else try writer.writeAll("lua.Value.nil");
            try writer.writeAll(")");
        },
        .table_remove => {
            try writer.writeAll("try lua.generatedTableRemove(");
            if (args.len != 0) try emitExpr(writer, ctx, args[0], depth) else try writer.writeAll("lua.Value.nil");
            try writer.writeAll(", ");
            if (args.len > 1) try emitExpr(writer, ctx, args[1], depth) else try writer.writeAll("null");
            try writer.writeAll(")");
        },
        .table_sort => {
            const label_id = ctx.nextTemp();
            try writer.print("blk_{d}: {{ _ = try lua.generatedTableSort(", .{label_id});
            if (args.len != 0) try emitExpr(writer, ctx, args[0], depth) else try writer.writeAll("lua.Value.nil");
            try writer.print("); break :blk_{d} lua.Value.nil; }}", .{label_id});
        },
        .table_unpack => {
            try writer.writeAll("lua.generatedResultsFirst(try lua.generatedTableUnpack(runtime, ");
            if (args.len != 0) try emitExpr(writer, ctx, args[0], depth) else try writer.writeAll("lua.Value.nil");
            try writer.writeAll("))");
        },
        .table_concat => {
            try writer.writeAll("try lua.generatedTableConcat(runtime, ");
            if (args.len != 0) try emitExpr(writer, ctx, args[0], depth) else try writer.writeAll("lua.Value.nil");
            try writer.writeAll(", ");
            if (args.len > 1) try emitExpr(writer, ctx, args[1], depth) else try writer.writeAll("null");
            try writer.writeAll(")");
        },
    }
}

fn writeZigStringLiteral(writer: anytype, value: []const u8) !void {
    if (containsSensitiveGeneratedName(value)) {
        try writeZigByteSliceLiteral(writer, value);
        return;
    }
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => {
            if (byte >= 0x20 and byte <= 0x7e) {
                try writer.writeByte(byte);
            } else {
                try writer.print("\\x{X:0>2}", .{byte});
            }
        },
    };
    try writer.writeByte('"');
}

fn writeZigByteSliceLiteral(writer: anytype, value: []const u8) !void {
    try writer.writeAll("&.{");
    for (value, 0..) |byte, idx| {
        if (idx != 0) try writer.writeAll(", ");
        try writer.print("0x{X:0>2}", .{byte});
    }
    try writer.writeAll("}");
}

fn containsSensitiveGeneratedName(value: []const u8) bool {
    return std.mem.indexOf(u8, value, "Module:") != null or
        std.mem.indexOf(u8, value, "module:") != null or
        std.mem.indexOf(u8, value, "Template:") != null or
        std.mem.indexOf(u8, value, "template:") != null;
}

fn reportParseError(source: []const u8, parser: *const Parser, err: ParseError) void {
    if (err != error.UnexpectedToken and err != error.UnexpectedEof) return;

    const token = parser.current();
    const start = if (token.lexeme.len != 0)
        @as(usize, @intCast(@intFromPtr(token.lexeme.ptr) - @intFromPtr(source.ptr)))
    else
        source.len;

    var line: usize = 1;
    var column: usize = 1;
    for (source[0..@min(start, source.len)]) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }

    const line_start = if (start == 0)
        0
    else if (std.mem.lastIndexOfScalar(u8, source[0..@min(start, source.len)], '\n')) |idx|
        idx + 1
    else
        0;
    const line_end = std.mem.indexOfScalarPos(u8, source, @min(start, source.len), '\n') orelse source.len;
    const line_text = source[line_start..line_end];
    const caret_col = if (column == 0) 0 else column - 1;

    std.debug.print(
        "lua parse error: {s} at line {d} column {d} token={s} lexeme=\"{s}\"\n{s}\n",
        .{ @errorName(err), line, column, @tagName(token.tag), token.lexeme, line_text },
    );
    for (0..caret_col) |_| std.debug.print(" ", .{});
    std.debug.print("^\n", .{});
}

fn appendIndent(out: *std.ArrayList(u8), allocator: std.mem.Allocator, depth: usize) !void {
    for (0..depth) |_| try out.appendSlice(allocator, "  ");
}

fn formatStmt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, stmt: *const Stmt, depth: usize) !void {
    try appendIndent(out, allocator, depth);
    switch (stmt.*) {
        .local_assign => |op| {
            try out.appendSlice(allocator, "LOCAL ");
            for (op.names, 0..) |name, idx| {
                if (idx != 0) try out.appendSlice(allocator, ", ");
                try out.appendSlice(allocator, name);
            }
            try out.appendSlice(allocator, "\n");
        },
        .assign => |op| {
            try out.appendSlice(allocator, "ASSIGN ");
            for (op.targets, 0..) |target, idx| {
                if (idx != 0) try out.appendSlice(allocator, ", ");
                try formatLValue(out, allocator, target);
            }
            try out.appendSlice(allocator, "\n");
        },
        .function_def => |op| {
            try out.appendSlice(allocator, if (op.is_local) "LOCAL_FUNCTION " else "FUNCTION ");
            try formatLValue(out, allocator, op.target);
            try out.appendSlice(allocator, "\n");
            for (op.body) |child| try formatStmt(out, allocator, child, depth + 1);
        },
        .if_stmt => |op| {
            try out.appendSlice(allocator, "IF\n");
            for (op.branches) |branch| {
                try appendIndent(out, allocator, depth + 1);
                try out.appendSlice(allocator, "BRANCH\n");
                for (branch.body) |child| try formatStmt(out, allocator, child, depth + 2);
            }
            if (op.else_body.len != 0) {
                try appendIndent(out, allocator, depth + 1);
                try out.appendSlice(allocator, "ELSE\n");
                for (op.else_body) |child| try formatStmt(out, allocator, child, depth + 2);
            }
        },
        .do_block => |body| {
            try out.appendSlice(allocator, "DO\n");
            for (body) |child| try formatStmt(out, allocator, child, depth + 1);
        },
        .while_stmt => |op| {
            _ = op;
            try out.appendSlice(allocator, "WHILE\n");
        },
        .repeat_stmt => |op| {
            _ = op;
            try out.appendSlice(allocator, "REPEAT\n");
        },
        .numeric_for => |op| {
            try out.appendSlice(allocator, "FOR ");
            try out.appendSlice(allocator, op.name);
            try out.appendSlice(allocator, "\n");
        },
        .generic_for => |op| {
            try out.appendSlice(allocator, "GENERIC_FOR ");
            for (op.names, 0..) |name, idx| {
                if (idx != 0) try out.appendSlice(allocator, ", ");
                try out.appendSlice(allocator, name);
            }
            try out.appendSlice(allocator, "\n");
        },
        .return_stmt => {
            try out.appendSlice(allocator, "RETURN\n");
        },
        .break_stmt => {
            try out.appendSlice(allocator, "BREAK\n");
        },
        .expr_stmt => {
            try out.appendSlice(allocator, "EXPR\n");
        },
    }
}

fn formatLValue(out: *std.ArrayList(u8), allocator: std.mem.Allocator, lvalue: LValue) !void {
    switch (lvalue) {
        .name => |name| try out.appendSlice(allocator, name),
        .field => |field| {
            try formatExpr(out, allocator, field.object);
            try out.appendSlice(allocator, ".");
            try out.appendSlice(allocator, field.name);
        },
        .index => |index| {
            try formatExpr(out, allocator, index.object);
            try out.appendSlice(allocator, "[");
            try formatExpr(out, allocator, index.key);
            try out.appendSlice(allocator, "]");
        },
    }
}

fn formatExpr(out: *std.ArrayList(u8), allocator: std.mem.Allocator, expr: *const Expr) !void {
    switch (expr.*) {
        .nil_lit => try out.appendSlice(allocator, "nil"),
        .bool_lit => |value| try out.appendSlice(allocator, if (value) "true" else "false"),
        .number_lit => |value| {
            const text = try std.fmt.allocPrint(allocator, "{d}", .{value});
            defer allocator.free(text);
            try out.appendSlice(allocator, text);
        },
        .string_lit => |value| {
            const text = try std.fmt.allocPrint(allocator, "\"{s}\"", .{value});
            defer allocator.free(text);
            try out.appendSlice(allocator, text);
        },
        .variable => |name| try out.appendSlice(allocator, name),
        .varargs => try out.appendSlice(allocator, "..."),
        .field => |field| {
            try formatExpr(out, allocator, field.object);
            try out.appendSlice(allocator, ".");
            try out.appendSlice(allocator, field.name);
        },
        .index => |index| {
            try formatExpr(out, allocator, index.object);
            try out.appendSlice(allocator, "[");
            try formatExpr(out, allocator, index.key);
            try out.appendSlice(allocator, "]");
        },
        .call => |call| {
            try formatExpr(out, allocator, call.callee);
            try out.appendSlice(allocator, "(...)");
        },
        .function_lit => try out.appendSlice(allocator, "function(...) end"),
        .unary => |unary| {
            try out.appendSlice(allocator, @tagName(unary.op));
            try out.appendSlice(allocator, " ");
            try formatExpr(out, allocator, unary.expr);
        },
        .binary => |binary| {
            try formatExpr(out, allocator, binary.lhs);
            try out.appendSlice(allocator, " ");
            try out.appendSlice(allocator, @tagName(binary.op));
            try out.appendSlice(allocator, " ");
            try formatExpr(out, allocator, binary.rhs);
        },
        .table_ctor => try out.appendSlice(allocator, "{...}"),
        .const_table => try out.appendSlice(allocator, "{const-table}"),
    }
}

fn optimizeChunk(allocator: std.mem.Allocator, body: []const *Stmt) OptimizeError!void {
    for (body) |stmt| try optimizeStmt(allocator, stmt);
}

fn optimizeStmt(allocator: std.mem.Allocator, stmt: *Stmt) OptimizeError!void {
    switch (stmt.*) {
        .local_assign => |op| try optimizeExprSlice(allocator, op.exprs),
        .assign => |op| {
            for (op.targets) |*target| try optimizeLValue(allocator, target);
            try optimizeExprSlice(allocator, op.exprs);
        },
        .function_def => |*op| {
            try optimizeLValue(allocator, &op.target);
            try optimizeChunk(allocator, op.body);
        },
        .if_stmt => |op| {
            for (op.branches) |branch| {
                try optimizeExpr(allocator, branch.condition);
                try optimizeChunk(allocator, branch.body);
            }
            try optimizeChunk(allocator, op.else_body);
        },
        .do_block => |body| try optimizeChunk(allocator, body),
        .while_stmt => |op| {
            try optimizeExpr(allocator, op.condition);
            try optimizeChunk(allocator, op.body);
        },
        .repeat_stmt => |op| {
            try optimizeChunk(allocator, op.body);
            try optimizeExpr(allocator, op.condition);
        },
        .numeric_for => |op| {
            try optimizeExpr(allocator, op.start);
            try optimizeExpr(allocator, op.finish);
            if (op.step) |step| try optimizeExpr(allocator, step);
            try optimizeChunk(allocator, op.body);
        },
        .generic_for => |op| {
            try optimizeExprSlice(allocator, op.iterator_exprs);
            try optimizeChunk(allocator, op.body);
        },
        .return_stmt => |op| try optimizeExprSlice(allocator, op.exprs),
        .break_stmt => {},
        .expr_stmt => |expr| try optimizeExpr(allocator, expr),
    }
}

fn optimizeExprSlice(allocator: std.mem.Allocator, exprs: []const *Expr) OptimizeError!void {
    for (exprs) |expr| try optimizeExpr(allocator, expr);
}

fn optimizeLValue(allocator: std.mem.Allocator, lvalue: *const LValue) OptimizeError!void {
    switch (lvalue.*) {
        .name => {},
        .field => |*field| try optimizeExpr(allocator, field.object),
        .index => |*index| {
            try optimizeExpr(allocator, index.object);
            try optimizeExpr(allocator, index.key);
        },
    }
}

fn optimizeExpr(allocator: std.mem.Allocator, expr: *Expr) OptimizeError!void {
    switch (expr.*) {
        .unary => |*op| try optimizeExpr(allocator, op.expr),
        .binary => |*op| {
            try optimizeExpr(allocator, op.lhs);
            try optimizeExpr(allocator, op.rhs);
        },
        .table_ctor => |fields| {
            for (fields) |*field| {
                switch (field.*) {
                    .array => |child| try optimizeExpr(allocator, child),
                    .named => |*named| try optimizeExpr(allocator, named.value),
                    .indexed => |*indexed| {
                        try optimizeExpr(allocator, indexed.key);
                        try optimizeExpr(allocator, indexed.value);
                    },
                }
            }
        },
        .const_table => {},
        .field => |*field| try optimizeExpr(allocator, field.object),
        .index => |*index| {
            try optimizeExpr(allocator, index.object);
            try optimizeExpr(allocator, index.key);
        },
        .call => |*call| {
            try optimizeExpr(allocator, call.callee);
            try optimizeExprSlice(allocator, call.args);
        },
        .function_lit => |*func| try optimizeChunk(allocator, func.body),
        .nil_lit, .bool_lit, .number_lit, .string_lit, .variable, .varargs => {},
    }

    const const_value = try constExprValueAlloc(allocator, expr) orelse return;
    rewriteExprToConst(expr, const_value);
}

fn rewriteExprToConst(expr: *Expr, value: Value) void {
    expr.* = switch (value) {
        .nil => .nil_lit,
        .boolean => |flag| .{ .bool_lit = flag },
        .number => |number| .{ .number_lit = number },
        .string => |text| .{ .string_lit = text },
        .table => |table| .{ .const_table = table },
        else => return,
    };
}

fn constExprValueAlloc(allocator: std.mem.Allocator, expr: *const Expr) OptimizeError!?Value {
    return switch (expr.*) {
        .nil_lit => .nil,
        .bool_lit => |value| .{ .boolean = value },
        .number_lit => |value| .{ .number = value },
        .string_lit => |value| .{ .string = value },
        .const_table => |table| .{ .table = @constCast(table) },
        .unary => |op| try constEvalUnary(op.op, try constExprValueAlloc(allocator, op.expr) orelse return null),
        .binary => |op| try constEvalBinaryAlloc(
            allocator,
            op.op,
            try constExprValueAlloc(allocator, op.lhs) orelse return null,
            op.rhs,
        ),
        .table_ctor => |fields| blk: {
            const table = try buildConstTableTemplateAlloc(allocator, fields) orelse break :blk null;
            break :blk Value{ .table = table };
        },
        .field,
        .index,
        .call,
        .function_lit,
        .variable,
        .varargs,
        => null,
    };
}

fn constEvalUnary(op: UnaryOp, value: Value) OptimizeError!?Value {
    return switch (op) {
        .negate => .{ .number = -(valueToNumber(value) catch return null) },
        .not_ => .{ .boolean = !value.truthy() },
        .length => switch (value) {
            .string => |str| .{ .number = @floatFromInt(str.len) },
            .table => |table| .{ .number = @floatFromInt(table.array.items.len) },
            else => null,
        },
    };
}

fn constEvalBinaryAlloc(
    allocator: std.mem.Allocator,
    op: BinaryOp,
    lhs: Value,
    rhs_expr: *const Expr,
) OptimizeError!?Value {
    if (op == .and_) {
        if (!lhs.truthy()) return lhs;
        return try constExprValueAlloc(allocator, rhs_expr);
    }
    if (op == .or_) {
        if (lhs.truthy()) return lhs;
        return try constExprValueAlloc(allocator, rhs_expr);
    }

    const rhs = try constExprValueAlloc(allocator, rhs_expr) orelse return null;
    return switch (op) {
        .add => .{ .number = (valueToNumber(lhs) catch return null) + (valueToNumber(rhs) catch return null) },
        .sub => .{ .number = (valueToNumber(lhs) catch return null) - (valueToNumber(rhs) catch return null) },
        .mul => .{ .number = (valueToNumber(lhs) catch return null) * (valueToNumber(rhs) catch return null) },
        .div => .{ .number = (valueToNumber(lhs) catch return null) / (valueToNumber(rhs) catch return null) },
        .mod => .{ .number = @mod((valueToNumber(lhs) catch return null), (valueToNumber(rhs) catch return null)) },
        .pow => .{ .number = std.math.pow(f64, (valueToNumber(lhs) catch return null), (valueToNumber(rhs) catch return null)) },
        .concat => .{
            .string = try std.fmt.allocPrint(
                allocator,
                "{s}{s}",
                .{
                    valueToStringAlloc(allocator, lhs) catch return null,
                    valueToStringAlloc(allocator, rhs) catch return null,
                },
            ),
        },
        .eq => .{ .boolean = valueEquals(lhs, rhs) },
        .ne => .{ .boolean = !valueEquals(lhs, rhs) },
        .lt => .{ .boolean = compareValues(lhs, rhs, .lt) catch return null },
        .le => .{ .boolean = compareValues(lhs, rhs, .le) catch return null },
        .gt => .{ .boolean = compareValues(lhs, rhs, .gt) catch return null },
        .ge => .{ .boolean = compareValues(lhs, rhs, .ge) catch return null },
        .and_, .or_ => unreachable,
    };
}

fn buildConstTableTemplateAlloc(allocator: std.mem.Allocator, fields: []const TableField) OptimizeError!?*Table {
    const table = try Table.init(allocator);
    for (fields) |field| {
        switch (field) {
            .array => |expr| {
                const value = try constExprValueAlloc(allocator, expr) orelse return null;
                try table.array.append(allocator, value);
            },
            .named => |named| {
                const value = try constExprValueAlloc(allocator, named.value) orelse return null;
                try table.putString(named.name, value);
            },
            .indexed => |indexed| {
                const key = try constExprValueAlloc(allocator, indexed.key) orelse return null;
                const value = try constExprValueAlloc(allocator, indexed.value) orelse return null;
                switch (key) {
                    .string, .number => table.set(key, value) catch return null,
                    else => return null,
                }
            },
        }
    }
    return table;
}

const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []const Token,
    index: usize = 0,

    fn init(allocator: std.mem.Allocator, source: []const u8, diagnostics: bool) !Parser {
        return .{
            .allocator = allocator,
            .tokens = try lexWithDiagnostics(allocator, source, diagnostics),
        };
    }

    fn parseChunk(self: *Parser) ParseError![]const *Stmt {
        var stmts: std.ArrayList(*Stmt) = .empty;
        while (!self.at(.eof)) {
            if (self.at(.semi)) {
                self.index += 1;
                continue;
            }
            try stmts.append(self.allocator, try self.parseStmt());
        }
        return stmts.toOwnedSlice(self.allocator);
    }

    fn parseBlock(self: *Parser) ParseError![]const *Stmt {
        return self.parseBlockUntil(&.{ .kw_end, .kw_else, .kw_elseif });
    }

    fn parseBlockUntil(self: *Parser, stop_tags: []const TokenTag) ParseError![]const *Stmt {
        var stmts: std.ArrayList(*Stmt) = .empty;
        while (!self.at(.eof) and !self.atAny(stop_tags)) {
            if (self.at(.semi)) {
                self.index += 1;
                continue;
            }
            try stmts.append(self.allocator, try self.parseStmt());
        }
        return stmts.toOwnedSlice(self.allocator);
    }

    fn parseStmt(self: *Parser) ParseError!*Stmt {
        if (self.eat(.kw_local)) {
            if (self.eat(.kw_function)) return self.parseLocalFunction();
            return self.parseLocalAssign();
        }
        if (self.eat(.kw_function)) return self.parseFunctionDef(false);
        if (self.eat(.kw_if)) return self.parseIf();
        if (self.eat(.kw_do)) return self.parseDoBlock();
        if (self.eat(.kw_while)) return self.parseWhile();
        if (self.eat(.kw_repeat)) return self.parseRepeat();
        if (self.eat(.kw_for)) return self.parseFor();
        if (self.eat(.kw_return)) return self.parseReturn();
        if (self.eat(.kw_break)) return try self.allocStmt(.break_stmt);
        return self.parseAssignOrExprStmt();
    }

    fn parseLocalFunction(self: *Parser) ParseError!*Stmt {
        const name = try self.expectIdentifier();
        const func = try self.parseFunctionBody(false);
        return try self.allocStmt(.{
            .function_def = .{
                .target = .{ .name = name },
                .params = func.params,
                .body = func.body,
                .is_vararg = func.is_vararg,
                .is_local = true,
            },
        });
    }

    fn parseFunctionDef(self: *Parser, is_local: bool) ParseError!*Stmt {
        const target = try self.parseFunctionTarget();
        const func = try self.parseFunctionBody(target.insert_self);
        return try self.allocStmt(.{
            .function_def = .{
                .target = target.lvalue,
                .params = func.params,
                .body = func.body,
                .is_vararg = func.is_vararg,
                .is_local = is_local,
            },
        });
    }

    fn parseFunctionTarget(self: *Parser) ParseError!struct { lvalue: LValue, insert_self: bool } {
        var object_expr = try self.allocExpr(.{ .variable = try self.expectIdentifier() });
        var saw_field = false;
        var insert_self = false;
        while (self.eat(.dot)) {
            const field_name = try self.expectIdentifier();
            object_expr = try self.allocExpr(.{ .field = .{
                .object = object_expr,
                .name = field_name,
            } });
            saw_field = true;
        }
        if (self.eat(.colon)) {
            const field_name = try self.expectIdentifier();
            object_expr = try self.allocExpr(.{ .field = .{
                .object = object_expr,
                .name = field_name,
            } });
            saw_field = true;
            insert_self = true;
        }
        return .{
            .lvalue = if (!saw_field) .{ .name = object_expr.variable } else try exprToLValue(object_expr),
            .insert_self = insert_self,
        };
    }

    fn parseFunctionBody(self: *Parser, insert_self: bool) ParseError!struct { params: []const []const u8, body: []const *Stmt, is_vararg: bool } {
        try self.expect(.lparen);
        var params: std.ArrayList([]const u8) = .empty;
        if (insert_self) try params.append(self.allocator, "self");
        var is_vararg = false;
        if (!self.at(.rparen)) {
            while (true) {
                if (self.eat(.ellipsis)) {
                    is_vararg = true;
                    break;
                }
                try params.append(self.allocator, try self.expectIdentifier());
                if (!self.eat(.comma)) break;
            }
        }
        try self.expect(.rparen);
        const body = try self.parseBlock();
        try self.expect(.kw_end);
        return .{
            .params = try params.toOwnedSlice(self.allocator),
            .body = body,
            .is_vararg = is_vararg,
        };
    }

    fn parseLocalAssign(self: *Parser) ParseError!*Stmt {
        var names: std.ArrayList([]const u8) = .empty;
        try names.append(self.allocator, try self.expectIdentifier());
        while (self.eat(.comma)) try names.append(self.allocator, try self.expectIdentifier());
        var exprs: []const *Expr = &.{};
        if (self.eat(.eq)) exprs = try self.parseExprList();
        return try self.allocStmt(.{
            .local_assign = .{
                .names = try names.toOwnedSlice(self.allocator),
                .exprs = exprs,
            },
        });
    }

    fn parseIf(self: *Parser) ParseError!*Stmt {
        var branches: std.ArrayList(IfBranch) = .empty;
        const first_condition = try self.parseExpr();
        try self.expect(.kw_then);
        try branches.append(self.allocator, .{
            .condition = first_condition,
            .body = try self.parseBlock(),
        });
        while (self.eat(.kw_elseif)) {
            const cond = try self.parseExpr();
            try self.expect(.kw_then);
            try branches.append(self.allocator, .{
                .condition = cond,
                .body = try self.parseBlock(),
            });
        }
        var else_body: []const *Stmt = &.{};
        if (self.eat(.kw_else)) else_body = try self.parseBlock();
        try self.expect(.kw_end);
        return try self.allocStmt(.{
            .if_stmt = .{
                .branches = try branches.toOwnedSlice(self.allocator),
                .else_body = else_body,
            },
        });
    }

    fn parseDoBlock(self: *Parser) ParseError!*Stmt {
        const body = try self.parseBlock();
        try self.expect(.kw_end);
        return try self.allocStmt(.{ .do_block = body });
    }

    fn parseWhile(self: *Parser) ParseError!*Stmt {
        const condition = try self.parseExpr();
        try self.expect(.kw_do);
        const body = try self.parseBlock();
        try self.expect(.kw_end);
        return try self.allocStmt(.{
            .while_stmt = .{
                .condition = condition,
                .body = body,
            },
        });
    }

    fn parseRepeat(self: *Parser) ParseError!*Stmt {
        const body = try self.parseBlockUntil(&.{.kw_until});
        try self.expect(.kw_until);
        const condition = try self.parseExpr();
        return try self.allocStmt(.{
            .repeat_stmt = .{
                .body = body,
                .condition = condition,
            },
        });
    }

    fn parseFor(self: *Parser) ParseError!*Stmt {
        const first_name = try self.expectIdentifier();
        if (self.eat(.eq)) {
            const start = try self.parseExpr();
            try self.expect(.comma);
            const finish = try self.parseExpr();
            const step = if (self.eat(.comma)) try self.parseExpr() else null;
            try self.expect(.kw_do);
            const body = try self.parseBlock();
            try self.expect(.kw_end);
            return try self.allocStmt(.{
                .numeric_for = .{
                    .name = first_name,
                    .start = start,
                    .finish = finish,
                    .step = step,
                    .body = body,
                },
            });
        }

        var names: std.ArrayList([]const u8) = .empty;
        try names.append(self.allocator, first_name);
        while (self.eat(.comma)) try names.append(self.allocator, try self.expectIdentifier());
        try self.expect(.kw_in);
        const iterator_exprs = try self.parseExprList();
        try self.expect(.kw_do);
        const body = try self.parseBlock();
        try self.expect(.kw_end);
        return try self.allocStmt(.{
            .generic_for = .{
                .names = try names.toOwnedSlice(self.allocator),
                .iterator_exprs = iterator_exprs,
                .body = body,
            },
        });
    }

    fn parseReturn(self: *Parser) ParseError!*Stmt {
        const exprs = if (self.at(.semi) or self.at(.eof) or self.at(.kw_end) or self.at(.kw_else) or self.at(.kw_elseif))
            &.{}
        else
            try self.parseExprList();
        _ = self.eat(.semi);
        return try self.allocStmt(.{ .return_stmt = .{ .exprs = exprs } });
    }

    fn parseAssignOrExprStmt(self: *Parser) ParseError!*Stmt {
        const prefix = try self.parsePrefixExpr();
        if (self.at(.eq) or self.at(.comma)) {
            var targets: std.ArrayList(LValue) = .empty;
            try targets.append(self.allocator, try exprToLValue(prefix));
            while (self.eat(.comma)) {
                const next_prefix = try self.parsePrefixExpr();
                try targets.append(self.allocator, try exprToLValue(next_prefix));
            }
            try self.expect(.eq);
            const exprs = try self.parseExprList();
            return try self.allocStmt(.{
                .assign = .{
                    .targets = try targets.toOwnedSlice(self.allocator),
                    .exprs = exprs,
                },
            });
        }
        switch (prefix.*) {
            .call => return try self.allocStmt(.{ .expr_stmt = prefix }),
            else => return error.InvalidAssignment,
        }
    }

    fn parseExprList(self: *Parser) ParseError![]const *Expr {
        var exprs: std.ArrayList(*Expr) = .empty;
        try exprs.append(self.allocator, try self.parseExpr());
        while (self.eat(.comma)) try exprs.append(self.allocator, try self.parseExpr());
        return exprs.toOwnedSlice(self.allocator);
    }

    fn parseExpr(self: *Parser) ParseError!*Expr {
        return self.parseBinaryExpr(0);
    }

    fn parseBinaryExpr(self: *Parser, min_prec: u8) ParseError!*Expr {
        var lhs = try self.parseUnaryExpr();
        while (true) {
            const maybe_op = binaryToken(self.current().tag) orelse break;
            const prec = precedence(maybe_op);
            if (prec < min_prec) break;
            self.index += 1;
            const rhs_prec = if (maybe_op == .concat or maybe_op == .pow) prec else prec + 1;
            const rhs = try self.parseBinaryExpr(rhs_prec);
            lhs = try self.allocExpr(.{
                .binary = .{
                    .op = maybe_op,
                    .lhs = lhs,
                    .rhs = rhs,
                },
            });
        }
        return lhs;
    }

    fn parseUnaryExpr(self: *Parser) ParseError!*Expr {
        if (self.eat(.minus)) {
            return try self.allocExpr(.{ .unary = .{ .op = .negate, .expr = try self.parseUnaryExpr() } });
        }
        if (self.eat(.kw_not)) {
            return try self.allocExpr(.{ .unary = .{ .op = .not_, .expr = try self.parseUnaryExpr() } });
        }
        if (self.eat(.hash)) {
            return try self.allocExpr(.{ .unary = .{ .op = .length, .expr = try self.parseUnaryExpr() } });
        }
        return self.parsePrefixExpr();
    }

    fn parsePrefixExpr(self: *Parser) ParseError!*Expr {
        var expr = try self.parsePrimary();
        while (true) {
            if (self.eat(.dot)) {
                expr = try self.allocExpr(.{
                    .field = .{
                        .object = expr,
                        .name = try self.expectIdentifier(),
                    },
                });
                continue;
            }
            if (self.eat(.lbracket)) {
                const key = try self.parseExpr();
                try self.expect(.rbracket);
                expr = try self.allocExpr(.{ .index = .{ .object = expr, .key = key } });
                continue;
            }
            if (self.at(.lparen)) {
                const args = try self.parseCallArgs();
                expr = try self.allocExpr(.{ .call = .{ .callee = expr, .args = args } });
                continue;
            }
            if (self.at(.lbrace) or self.at(.string)) {
                const args = try self.parseSingleCallArg();
                expr = try self.allocExpr(.{ .call = .{ .callee = expr, .args = args } });
                continue;
            }
            if (self.eat(.colon)) {
                const method_name = try self.expectIdentifier();
                const callee = try self.allocExpr(.{
                    .field = .{
                        .object = expr,
                        .name = method_name,
                    },
                });
                const method_args = try self.parseCallArgs();
                const args = try self.allocator.alloc(*Expr, method_args.len + 1);
                args[0] = expr;
                @memcpy(args[1..], method_args);
                expr = try self.allocExpr(.{ .call = .{ .callee = callee, .args = args } });
                continue;
            }
            break;
        }
        return expr;
    }

    fn parseCallArgs(self: *Parser) ParseError![]const *Expr {
        if (self.at(.lbrace) or self.at(.string)) return self.parseSingleCallArg();
        try self.expect(.lparen);
        var args: std.ArrayList(*Expr) = .empty;
        if (!self.at(.rparen)) {
            try args.append(self.allocator, try self.parseExpr());
            while (self.eat(.comma)) try args.append(self.allocator, try self.parseExpr());
        }
        try self.expect(.rparen);
        return args.toOwnedSlice(self.allocator);
    }

    fn parseSingleCallArg(self: *Parser) ParseError![]const *Expr {
        const arg = try self.parsePrimary();
        const args = try self.allocator.alloc(*Expr, 1);
        args[0] = arg;
        return args;
    }

    fn parsePrimary(self: *Parser) ParseError!*Expr {
        const token = self.current();
        switch (token.tag) {
            .kw_nil => {
                self.index += 1;
                return try self.allocExpr(.nil_lit);
            },
            .kw_false => {
                self.index += 1;
                return try self.allocExpr(.{ .bool_lit = false });
            },
            .kw_true => {
                self.index += 1;
                return try self.allocExpr(.{ .bool_lit = true });
            },
            .number => {
                self.index += 1;
                const number = parseLuaNumber(token.lexeme) catch return error.InvalidNumber;
                return try self.allocExpr(.{ .number_lit = number });
            },
            .string => {
                self.index += 1;
                return try self.allocExpr(.{ .string_lit = token.lexeme });
            },
            .identifier => {
                self.index += 1;
                return try self.allocExpr(.{ .variable = token.lexeme });
            },
            .ellipsis => {
                self.index += 1;
                return try self.allocExpr(.varargs);
            },
            .kw_function => {
                self.index += 1;
                const func = try self.parseFunctionBody(false);
                return try self.allocExpr(.{
                    .function_lit = .{
                        .params = func.params,
                        .body = func.body,
                        .is_vararg = func.is_vararg,
                    },
                });
            },
            .lparen => {
                self.index += 1;
                const expr = try self.parseExpr();
                try self.expect(.rparen);
                return expr;
            },
            .lbrace => return self.parseTableCtor(),
            else => return error.UnexpectedToken,
        }
    }

    fn parseTableCtor(self: *Parser) ParseError!*Expr {
        try self.expect(.lbrace);
        var fields: std.ArrayList(TableField) = .empty;
        while (!self.at(.rbrace)) {
            if (self.at(.identifier) and self.peekTag(1) == .eq) {
                const name = self.current().lexeme;
                self.index += 2;
                try fields.append(self.allocator, .{
                    .named = .{
                        .name = name,
                        .value = try self.parseExpr(),
                    },
                });
            } else if (self.eat(.lbracket)) {
                const key = try self.parseExpr();
                try self.expect(.rbracket);
                try self.expect(.eq);
                try fields.append(self.allocator, .{
                    .indexed = .{
                        .key = key,
                        .value = try self.parseExpr(),
                    },
                });
            } else {
                try fields.append(self.allocator, .{ .array = try self.parseExpr() });
            }
            _ = self.eat(.comma) or self.eat(.semi);
        }
        try self.expect(.rbrace);
        return try self.allocExpr(.{ .table_ctor = try fields.toOwnedSlice(self.allocator) });
    }

    fn allocStmt(self: *Parser, stmt: Stmt) std.mem.Allocator.Error!*Stmt {
        const ptr = try self.allocator.create(Stmt);
        ptr.* = stmt;
        return ptr;
    }

    fn allocExpr(self: *Parser, expr: Expr) std.mem.Allocator.Error!*Expr {
        const ptr = try self.allocator.create(Expr);
        ptr.* = expr;
        return ptr;
    }

    fn expect(self: *Parser, tag: TokenTag) ParseError!void {
        if (!self.eat(tag)) return error.UnexpectedToken;
    }

    fn eat(self: *Parser, tag: TokenTag) bool {
        if (self.current().tag != tag) return false;
        self.index += 1;
        return true;
    }

    fn at(self: *const Parser, tag: TokenTag) bool {
        return self.current().tag == tag;
    }

    fn atAny(self: *const Parser, tags: []const TokenTag) bool {
        for (tags) |tag| {
            if (self.at(tag)) return true;
        }
        return false;
    }

    fn peekTag(self: *const Parser, offset: usize) TokenTag {
        const idx = @min(self.index + offset, self.tokens.len - 1);
        return self.tokens[idx].tag;
    }

    fn current(self: *const Parser) Token {
        return self.tokens[@min(self.index, self.tokens.len - 1)];
    }

    fn expectIdentifier(self: *Parser) ParseError![]const u8 {
        const token = self.current();
        if (token.tag != .identifier) return error.UnexpectedToken;
        self.index += 1;
        return token.lexeme;
    }
};

fn exprToLValue(expr: *const Expr) !LValue {
    return switch (expr.*) {
        .variable => |name| .{ .name = name },
        .field => |field| .{ .field = .{
            .object = field.object,
            .name = field.name,
        } },
        .index => |index| .{ .index = .{
            .object = index.object,
            .key = index.key,
        } },
        else => error.InvalidAssignment,
    };
}

fn binaryToken(tag: TokenTag) ?BinaryOp {
    return switch (tag) {
        .plus => .add,
        .minus => .sub,
        .star => .mul,
        .slash => .div,
        .percent => .mod,
        .caret => .pow,
        .dotdot => .concat,
        .eqeq => .eq,
        .ne => .ne,
        .lt => .lt,
        .le => .le,
        .gt => .gt,
        .ge => .ge,
        .kw_and => .and_,
        .kw_or => .or_,
        else => null,
    };
}

fn precedence(op: BinaryOp) u8 {
    return switch (op) {
        .or_ => 1,
        .and_ => 2,
        .eq, .ne, .lt, .le, .gt, .ge => 3,
        .concat => 4,
        .add, .sub => 5,
        .mul, .div, .mod => 6,
        .pow => 7,
    };
}

fn lex(allocator: std.mem.Allocator, source: []const u8) ![]const Token {
    return lexWithDiagnostics(allocator, source, true);
}

fn lexQuiet(allocator: std.mem.Allocator, source: []const u8) ![]const Token {
    return lexWithDiagnostics(allocator, source, false);
}

fn lexWithDiagnostics(allocator: std.mem.Allocator, source: []const u8, diagnostics: bool) ![]const Token {
    var tokens: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    while (i < source.len) {
        const ch = source[i];
        switch (ch) {
            ' ', '\t', '\r', '\n' => i += 1,
            '-' => {
                if (i + 1 < source.len and source[i + 1] == '-') {
                    if (detectLongBracketStart(source, i + 2)) |long_bracket| {
                        const end = findLongBracketEnd(source, long_bracket.content_start, long_bracket.eq_count) orelse {
                            if (diagnostics) reportLexErrorAt(source, i, error.UnexpectedEof);
                            return error.UnexpectedEof;
                        };
                        i = end + long_bracket.eq_count + 2;
                    } else {
                        i += 2;
                        while (i < source.len and source[i] != '\n') : (i += 1) {}
                    }
                } else {
                    try tokens.append(allocator, .{ .tag = .minus, .lexeme = source[i .. i + 1] });
                    i += 1;
                }
            },
            '+' => {
                try tokens.append(allocator, .{ .tag = .plus, .lexeme = source[i .. i + 1] });
                i += 1;
            },
            '*' => {
                try tokens.append(allocator, .{ .tag = .star, .lexeme = source[i .. i + 1] });
                i += 1;
            },
            '/' => {
                try tokens.append(allocator, .{ .tag = .slash, .lexeme = source[i .. i + 1] });
                i += 1;
            },
            '%' => {
                try tokens.append(allocator, .{ .tag = .percent, .lexeme = source[i .. i + 1] });
                i += 1;
            },
            '^' => {
                try tokens.append(allocator, .{ .tag = .caret, .lexeme = source[i .. i + 1] });
                i += 1;
            },
            '#' => {
                try tokens.append(allocator, .{ .tag = .hash, .lexeme = source[i .. i + 1] });
                i += 1;
            },
            '(' => {
                try tokens.append(allocator, .{ .tag = .lparen, .lexeme = source[i .. i + 1] });
                i += 1;
            },
            ')' => {
                try tokens.append(allocator, .{ .tag = .rparen, .lexeme = source[i .. i + 1] });
                i += 1;
            },
            '{' => {
                try tokens.append(allocator, .{ .tag = .lbrace, .lexeme = source[i .. i + 1] });
                i += 1;
            },
            '}' => {
                try tokens.append(allocator, .{ .tag = .rbrace, .lexeme = source[i .. i + 1] });
                i += 1;
            },
            '[' => {
                if (detectLongBracketStart(source, i)) |long_bracket| {
                    const end = findLongBracketEnd(source, long_bracket.content_start, long_bracket.eq_count) orelse {
                        if (diagnostics) reportLexErrorAt(source, i, error.UnexpectedEof);
                        return error.UnexpectedEof;
                    };
                    try tokens.append(allocator, .{
                        .tag = .string,
                        .lexeme = try allocator.dupe(u8, source[long_bracket.content_start..end]),
                    });
                    i = end + long_bracket.eq_count + 2;
                } else {
                    try tokens.append(allocator, .{ .tag = .lbracket, .lexeme = source[i .. i + 1] });
                    i += 1;
                }
            },
            ']' => {
                try tokens.append(allocator, .{ .tag = .rbracket, .lexeme = source[i .. i + 1] });
                i += 1;
            },
            ',' => {
                try tokens.append(allocator, .{ .tag = .comma, .lexeme = source[i .. i + 1] });
                i += 1;
            },
            ';' => {
                try tokens.append(allocator, .{ .tag = .semi, .lexeme = source[i .. i + 1] });
                i += 1;
            },
            ':' => {
                try tokens.append(allocator, .{ .tag = .colon, .lexeme = source[i .. i + 1] });
                i += 1;
            },
            '.' => {
                if (i + 2 < source.len and source[i + 1] == '.' and source[i + 2] == '.') {
                    try tokens.append(allocator, .{ .tag = .ellipsis, .lexeme = source[i .. i + 3] });
                    i += 3;
                } else if (i + 1 < source.len and source[i + 1] == '.') {
                    try tokens.append(allocator, .{ .tag = .dotdot, .lexeme = source[i .. i + 2] });
                    i += 2;
                } else {
                    try tokens.append(allocator, .{ .tag = .dot, .lexeme = source[i .. i + 1] });
                    i += 1;
                }
            },
            '=' => {
                if (i + 1 < source.len and source[i + 1] == '=') {
                    try tokens.append(allocator, .{ .tag = .eqeq, .lexeme = source[i .. i + 2] });
                    i += 2;
                } else {
                    try tokens.append(allocator, .{ .tag = .eq, .lexeme = source[i .. i + 1] });
                    i += 1;
                }
            },
            '~' => {
                if (i + 1 < source.len and source[i + 1] == '=') {
                    try tokens.append(allocator, .{ .tag = .ne, .lexeme = source[i .. i + 2] });
                    i += 2;
                } else {
                    if (diagnostics) reportLexErrorAt(source, i, error.UnexpectedToken);
                    return error.UnexpectedToken;
                }
            },
            '<' => {
                if (i + 1 < source.len and source[i + 1] == '=') {
                    try tokens.append(allocator, .{ .tag = .le, .lexeme = source[i .. i + 2] });
                    i += 2;
                } else {
                    try tokens.append(allocator, .{ .tag = .lt, .lexeme = source[i .. i + 1] });
                    i += 1;
                }
            },
            '>' => {
                if (i + 1 < source.len and source[i + 1] == '=') {
                    try tokens.append(allocator, .{ .tag = .ge, .lexeme = source[i .. i + 2] });
                    i += 2;
                } else {
                    try tokens.append(allocator, .{ .tag = .gt, .lexeme = source[i .. i + 1] });
                    i += 1;
                }
            },
            '\'', '"' => {
                const quote = ch;
                const start = i + 1;
                i += 1;
                while (i < source.len and source[i] != quote) : (i += 1) {
                    if (source[i] == '\\' and i + 1 < source.len) i += 1;
                }
                if (i >= source.len) {
                    if (diagnostics) reportLexErrorAt(source, start - 1, error.UnexpectedEof);
                    return error.UnexpectedEof;
                }
                const decoded = try decodeLuaStringAlloc(allocator, source[start..i]);
                try tokens.append(allocator, .{ .tag = .string, .lexeme = decoded });
                i += 1;
            },
            else => {
                if (std.ascii.isDigit(ch)) {
                    const start = i;
                    i = scanLuaNumber(source, start);
                    try tokens.append(allocator, .{ .tag = .number, .lexeme = source[start..i] });
                } else if (isIdentifierStart(ch)) {
                    const start = i;
                    i += 1;
                    while (i < source.len and isIdentifierContinue(source[i])) : (i += 1) {}
                    const ident = source[start..i];
                    try tokens.append(allocator, .{ .tag = keywordTag(ident) orelse .identifier, .lexeme = ident });
                } else {
                    if (diagnostics) reportLexErrorAt(source, i, error.UnexpectedToken);
                    return error.UnexpectedToken;
                }
            },
        }
    }
    try tokens.append(allocator, .{ .tag = .eof, .lexeme = "" });
    return tokens.toOwnedSlice(allocator);
}

fn freeTokenSlice(allocator: std.mem.Allocator, tokens: []const Token) void {
    for (tokens) |token| {
        if (token.tag == .string) allocator.free(token.lexeme);
    }
    allocator.free(tokens);
}

fn reportLexErrorAt(source: []const u8, pos: usize, err: CompileError) void {
    const clamped = @min(pos, source.len);
    var line: usize = 1;
    var column: usize = 1;
    for (source[0..clamped]) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }

    const line_start = if (clamped == 0)
        0
    else if (std.mem.lastIndexOfScalar(u8, source[0..clamped], '\n')) |idx|
        idx + 1
    else
        0;
    const line_end = std.mem.indexOfScalarPos(u8, source, clamped, '\n') orelse source.len;
    const line_text = source[line_start..line_end];

    std.debug.print(
        "lua lex error: {s} at line {d} column {d}\n{s}\n",
        .{ @errorName(err), line, column, line_text },
    );
    for (0..(if (column == 0) 0 else column - 1)) |_| std.debug.print(" ", .{});
    std.debug.print("^\n", .{});
}

fn decodeLuaStringAlloc(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] != '\\') {
            try out.append(allocator, input[i]);
            continue;
        }
        i += 1;
        if (i >= input.len) break;
        try out.append(allocator, switch (input[i]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            '\\' => '\\',
            '"' => '"',
            '\'' => '\'',
            else => input[i],
        });
    }
    return out.toOwnedSlice(allocator);
}

fn scanLuaNumber(source: []const u8, start: usize) usize {
    var i = start;
    if (i + 1 < source.len and source[i] == '0' and (source[i + 1] == 'x' or source[i + 1] == 'X')) {
        i += 2;
        while (i < source.len and std.ascii.isHex(source[i])) : (i += 1) {}
        if (i < source.len and source[i] == '.' and !(i + 1 < source.len and source[i + 1] == '.')) {
            i += 1;
            while (i < source.len and std.ascii.isHex(source[i])) : (i += 1) {}
        }
        if (i < source.len and (source[i] == 'p' or source[i] == 'P')) {
            i += 1;
            if (i < source.len and (source[i] == '+' or source[i] == '-')) i += 1;
            while (i < source.len and std.ascii.isDigit(source[i])) : (i += 1) {}
        }
        return i;
    }

    while (i < source.len and std.ascii.isDigit(source[i])) : (i += 1) {}
    if (i < source.len and source[i] == '.' and !(i + 1 < source.len and source[i + 1] == '.')) {
        i += 1;
        while (i < source.len and std.ascii.isDigit(source[i])) : (i += 1) {}
    }
    if (i < source.len and (source[i] == 'e' or source[i] == 'E')) {
        var j = i + 1;
        if (j < source.len and (source[j] == '+' or source[j] == '-')) j += 1;
        const exp_start = j;
        while (j < source.len and std.ascii.isDigit(source[j])) : (j += 1) {}
        if (j > exp_start) i = j;
    }
    return i;
}

fn parseLuaNumber(text: []const u8) !f64 {
    if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X")) {
        if (std.mem.indexOfAny(u8, text, ".pP") != null) return try parseHexFloat(text);
        return @floatFromInt(try std.fmt.parseUnsigned(u64, text[2..], 16));
    }
    return std.fmt.parseFloat(f64, text);
}

fn parseHexFloat(text: []const u8) !f64 {
    var i: usize = 2;
    var int_part: f64 = 0;
    while (i < text.len and std.ascii.isHex(text[i])) : (i += 1) {
        int_part = int_part * 16 + @as(f64, @floatFromInt(hexValue(text[i]) orelse return error.InvalidNumber));
    }

    var frac_part: f64 = 0;
    var frac_scale: f64 = 1;
    if (i < text.len and text[i] == '.') {
        i += 1;
        while (i < text.len and std.ascii.isHex(text[i])) : (i += 1) {
            frac_scale *= 16;
            frac_part += @as(f64, @floatFromInt(hexValue(text[i]) orelse return error.InvalidNumber)) / frac_scale;
        }
    }

    var exponent: i32 = 0;
    if (i < text.len and (text[i] == 'p' or text[i] == 'P')) {
        i += 1;
        var sign: i32 = 1;
        if (i < text.len and text[i] == '+') {
            i += 1;
        } else if (i < text.len and text[i] == '-') {
            sign = -1;
            i += 1;
        }
        exponent = sign * (try std.fmt.parseInt(i32, text[i..], 10));
        i = text.len;
    }

    if (i != text.len) return error.InvalidNumber;
    return (int_part + frac_part) * std.math.pow(f64, 2, @floatFromInt(exponent));
}

fn hexValue(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

const LongBracketStart = struct {
    eq_count: usize,
    content_start: usize,
};

fn detectLongBracketStart(source: []const u8, start: usize) ?LongBracketStart {
    if (start >= source.len or source[start] != '[') return null;
    var i = start + 1;
    while (i < source.len and source[i] == '=') : (i += 1) {}
    if (i >= source.len or source[i] != '[') return null;
    return .{
        .eq_count = i - (start + 1),
        .content_start = i + 1,
    };
}

fn findLongBracketEnd(source: []const u8, start: usize, eq_count: usize) ?usize {
    var i = start;
    while (i < source.len) : (i += 1) {
        if (source[i] != ']') continue;
        var j = i + 1;
        var seen_eq: usize = 0;
        while (j < source.len and seen_eq < eq_count and source[j] == '=') : ({
            j += 1;
            seen_eq += 1;
        }) {}
        if (seen_eq == eq_count and j < source.len and source[j] == ']') return i;
    }
    return null;
}

fn keywordTag(ident: []const u8) ?TokenTag {
    if (std.mem.eql(u8, ident, "and")) return .kw_and;
    if (std.mem.eql(u8, ident, "break")) return .kw_break;
    if (std.mem.eql(u8, ident, "do")) return .kw_do;
    if (std.mem.eql(u8, ident, "else")) return .kw_else;
    if (std.mem.eql(u8, ident, "elseif")) return .kw_elseif;
    if (std.mem.eql(u8, ident, "end")) return .kw_end;
    if (std.mem.eql(u8, ident, "false")) return .kw_false;
    if (std.mem.eql(u8, ident, "for")) return .kw_for;
    if (std.mem.eql(u8, ident, "function")) return .kw_function;
    if (std.mem.eql(u8, ident, "if")) return .kw_if;
    if (std.mem.eql(u8, ident, "in")) return .kw_in;
    if (std.mem.eql(u8, ident, "local")) return .kw_local;
    if (std.mem.eql(u8, ident, "nil")) return .kw_nil;
    if (std.mem.eql(u8, ident, "not")) return .kw_not;
    if (std.mem.eql(u8, ident, "or")) return .kw_or;
    if (std.mem.eql(u8, ident, "repeat")) return .kw_repeat;
    if (std.mem.eql(u8, ident, "return")) return .kw_return;
    if (std.mem.eql(u8, ident, "then")) return .kw_then;
    if (std.mem.eql(u8, ident, "true")) return .kw_true;
    if (std.mem.eql(u8, ident, "until")) return .kw_until;
    if (std.mem.eql(u8, ident, "while")) return .kw_while;
    return null;
}

fn isIdentifierStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdentifierContinue(ch: u8) bool {
    return isIdentifierStart(ch) or std.ascii.isDigit(ch);
}

const Env = struct {
    allocator: std.mem.Allocator,
    parent: ?*Env,
    vars: std.StringHashMapUnmanaged(Value) = .empty,
    varargs: []const Value = &.{},
};

const Vm = struct {
    arena: std.heap.ArenaAllocator,

    fn init(allocator: std.mem.Allocator) !Vm {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    fn deinit(self: *Vm) void {
        self.arena.deinit();
    }

    fn alloc(self: *Vm) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn createEnv(self: *Vm, parent: ?*Env) !*Env {
        const env = try self.alloc().create(Env);
        env.* = .{
            .allocator = self.alloc(),
            .parent = parent,
        };
        return env;
    }

    fn installBuiltins(self: *Vm, env: *Env) !void {
        try envSet(env, "print", .{ .function = try self.nativeFunction("print", builtinPrint) });
        try envSet(env, "tostring", .{ .function = try self.nativeFunction("tostring", builtinTostring) });
        try envSet(env, "tonumber", .{ .function = try self.nativeFunction("tonumber", builtinTonumber) });
        try envSet(env, "type", .{ .function = try self.nativeFunction("type", builtinType) });
        try envSet(env, "pairs", .{ .function = try self.nativeFunction("pairs", builtinPairs) });
        try envSet(env, "ipairs", .{ .function = try self.nativeFunction("ipairs", builtinIpairs) });

        const string_table = try Table.init(self.alloc());
        try string_table.putString("len", .{ .function = try self.nativeFunction("string.len", builtinStringLen) });
        try string_table.putString("lower", .{ .function = try self.nativeFunction("string.lower", builtinStringLower) });
        try string_table.putString("upper", .{ .function = try self.nativeFunction("string.upper", builtinStringUpper) });
        try string_table.putString("sub", .{ .function = try self.nativeFunction("string.sub", builtinStringSub) });
        try envSet(env, "string", .{ .table = string_table });

        const math_table = try Table.init(self.alloc());
        try math_table.putString("floor", .{ .function = try self.nativeFunction("math.floor", builtinMathFloor) });
        try math_table.putString("ceil", .{ .function = try self.nativeFunction("math.ceil", builtinMathCeil) });
        try math_table.putString("abs", .{ .function = try self.nativeFunction("math.abs", builtinMathAbs) });
        try envSet(env, "math", .{ .table = math_table });

        const table_table = try Table.init(self.alloc());
        try table_table.putString("insert", .{ .function = try self.nativeFunction("table.insert", builtinTableInsert) });
        try table_table.putString("concat", .{ .function = try self.nativeFunction("table.concat", builtinTableConcat) });
        try envSet(env, "table", .{ .table = table_table });
    }

    fn nativeFunction(self: *Vm, name: []const u8, func: NativeFn) !*Function {
        const out = try self.alloc().create(Function);
        out.* = .{
            .name = try self.alloc().dupe(u8, name),
            .kind = .{ .native = func },
            .env = null,
        };
        return out;
    }

    fn userFunction(self: *Vm, name: []const u8, params: []const []const u8, body: []const *Stmt, is_vararg: bool, env: *Env) !*Function {
        const out = try self.alloc().create(Function);
        out.* = .{
            .name = try self.alloc().dupe(u8, name),
            .kind = .{ .user = .{ .params = params, .body = body, .is_vararg = is_vararg } },
            .env = env,
        };
        return out;
    }

    const ExecResult = union(enum) {
        none,
        returned: []Value,
        break_loop,
    };

    fn executeBlock(self: *Vm, env: *Env, body: []const *Stmt) EvalError!ExecResult {
        for (body) |stmt| {
            const result = try self.executeStmt(env, stmt);
            if (result != .none) return result;
        }
        return .none;
    }

    fn executeStmt(self: *Vm, env: *Env, stmt: *const Stmt) EvalError!ExecResult {
        switch (stmt.*) {
            .local_assign => |op| {
                const values = try self.evalExprs(env, op.exprs);
                for (op.names, 0..) |name, idx| {
                    try envSetLocal(env, name, if (idx < values.len) values[idx] else .nil);
                }
                return .none;
            },
            .assign => |op| {
                const values = try self.evalExprs(env, op.exprs);
                for (op.targets, 0..) |target, idx| {
                    try self.assign(env, target, if (idx < values.len) values[idx] else .nil);
                }
                return .none;
            },
            .function_def => |op| {
                const fn_name = switch (op.target) {
                    .name => |name| name,
                    .field => |field| field.name,
                    .index => "anonymous",
                };
                const function_value: Value = .{ .function = try self.userFunction(fn_name, op.params, op.body, op.is_vararg, env) };
                if (op.is_local) {
                    try envSetLocal(env, fn_name, function_value);
                } else {
                    try self.assign(env, op.target, function_value);
                }
                return .none;
            },
            .if_stmt => |op| {
                for (op.branches) |branch| {
                    if ((try self.evalExpr(env, branch.condition)).truthy()) {
                        const branch_env = try self.createEnv(env);
                        return try self.executeBlock(branch_env, branch.body);
                    }
                }
                if (op.else_body.len != 0) {
                    const else_env = try self.createEnv(env);
                    return try self.executeBlock(else_env, op.else_body);
                }
                return .none;
            },
            .do_block => |body| {
                const block_env = try self.createEnv(env);
                return try self.executeBlock(block_env, body);
            },
            .while_stmt => |op| {
                while ((try self.evalExpr(env, op.condition)).truthy()) {
                    const loop_env = try self.createEnv(env);
                    switch (try self.executeBlock(loop_env, op.body)) {
                        .none => {},
                        .returned => |returns| return .{ .returned = returns },
                        .break_loop => break,
                    }
                }
                return .none;
            },
            .repeat_stmt => |op| {
                while (true) {
                    const loop_env = try self.createEnv(env);
                    switch (try self.executeBlock(loop_env, op.body)) {
                        .none => {},
                        .returned => |returns| return .{ .returned = returns },
                        .break_loop => break,
                    }
                    if ((try self.evalExpr(env, op.condition)).truthy()) break;
                }
                return .none;
            },
            .numeric_for => |op| {
                const start = try valueToNumber(try self.evalExpr(env, op.start));
                const finish = try valueToNumber(try self.evalExpr(env, op.finish));
                const step = if (op.step) |expr| try valueToNumber(try self.evalExpr(env, expr)) else 1.0;
                var current = start;
                while ((step >= 0 and current <= finish) or (step < 0 and current >= finish)) : (current += step) {
                    const loop_env = try self.createEnv(env);
                    try envSetLocal(loop_env, op.name, .{ .number = current });
                    switch (try self.executeBlock(loop_env, op.body)) {
                        .none => {},
                        .returned => |returns| return .{ .returned = returns },
                        .break_loop => break,
                    }
                }
                return .none;
            },
            .generic_for => |op| {
                const iterator_values = try self.evalExprs(env, op.iterator_exprs);
                if (iterator_values.len == 0 or iterator_values[0] != .iterator) return error.UnsupportedGenericFor;
                var iter = iterator_values[0].iterator;
                while (try self.iteratorNext(&iter)) |pair| {
                    const loop_env = try self.createEnv(env);
                    if (op.names.len >= 1) try envSetLocal(loop_env, op.names[0], pair[0]);
                    if (op.names.len >= 2) try envSetLocal(loop_env, op.names[1], pair[1]);
                    switch (try self.executeBlock(loop_env, op.body)) {
                        .none => {},
                        .returned => |returns| return .{ .returned = returns },
                        .break_loop => break,
                    }
                }
                return .none;
            },
            .return_stmt => |op| return .{ .returned = try self.evalExprs(env, op.exprs) },
            .break_stmt => return .break_loop,
            .expr_stmt => |expr| {
                _ = try self.evalExpr(env, expr);
                return .none;
            },
        }
    }

    fn iteratorNext(self: *Vm, iterator: *Iterator) EvalError!?[2]Value {
        _ = self;
        switch (iterator.kind) {
            .pairs => {
                if (iterator.index < iterator.table.array.items.len) {
                    iterator.index += 1;
                    return .{ .{ .number = @floatFromInt(iterator.index) }, iterator.table.array.items[iterator.index - 1] };
                }
                var count: usize = iterator.table.array.items.len;
                var it = iterator.table.string_fields.iterator();
                while (it.next()) |entry| {
                    count += 1;
                    if (count == iterator.index + 1) {
                        iterator.index += 1;
                        return .{ .{ .string = entry.key_ptr.* }, entry.value_ptr.* };
                    }
                }
                return null;
            },
            .ipairs => {
                if (iterator.index >= iterator.table.array.items.len) return null;
                iterator.index += 1;
                return .{ .{ .number = @floatFromInt(iterator.index) }, iterator.table.array.items[iterator.index - 1] };
            },
        }
    }

    fn assign(self: *Vm, env: *Env, target: LValue, value: Value) EvalError!void {
        switch (target) {
            .name => |name| try envAssign(env, name, value),
            .field => |field| {
                const table_value = try self.evalExpr(env, field.object);
                if (table_value != .table) return error.InvalidIndex;
                try table_value.table.putString(field.name, value);
            },
            .index => |index| {
                const table_value = try self.evalExpr(env, index.object);
                const key = try self.evalExpr(env, index.key);
                if (table_value != .table) return error.InvalidIndex;
                try table_value.table.set(key, value);
            },
        }
    }

    fn evalExprs(self: *Vm, env: *Env, exprs: []const *Expr) EvalError![]Value {
        if (exprs.len == 0) return &.{};
        const values = try self.alloc().alloc(Value, exprs.len);
        for (exprs, 0..) |expr, idx| values[idx] = try self.evalExpr(env, expr);
        return values;
    }

    fn evalExpr(self: *Vm, env: *Env, expr: *const Expr) EvalError!Value {
        return switch (expr.*) {
            .nil_lit => .nil,
            .bool_lit => |value| .{ .boolean = value },
            .number_lit => |value| .{ .number = value },
            .string_lit => |value| .{ .string = value },
            .variable => |name| try envLookup(env, name),
            .varargs => if (env.varargs.len != 0) env.varargs[0] else .nil,
            .unary => |op| try self.evalUnary(env, op.op, op.expr),
            .binary => |op| try self.evalBinary(env, op.op, op.lhs, op.rhs),
            .table_ctor => |fields| try self.evalTableCtor(env, fields),
            .const_table => |table| .{ .table = try cloneConstTableTemplateAlloc(self.alloc(), table) },
            .field => |field| blk: {
                const object = try self.evalExpr(env, field.object);
                if (object != .table) return error.InvalidIndex;
                break :blk object.table.getString(field.name);
            },
            .index => |index| blk: {
                const object = try self.evalExpr(env, index.object);
                if (object != .table) return error.InvalidIndex;
                break :blk object.table.get(try self.evalExpr(env, index.key));
            },
            .call => |call| try self.evalCall(env, call.callee, call.args),
            .function_lit => |func| .{ .function = try self.userFunction("anonymous", func.params, func.body, func.is_vararg, env) },
        };
    }

    fn evalUnary(self: *Vm, env: *Env, op: UnaryOp, expr: *Expr) EvalError!Value {
        const value = try self.evalExpr(env, expr);
        return switch (op) {
            .negate => .{ .number = -(try valueToNumber(value)) },
            .not_ => .{ .boolean = !value.truthy() },
            .length => switch (value) {
                .string => |str| .{ .number = @floatFromInt(str.len) },
                .table => |table| .{ .number = @floatFromInt(table.array.items.len) },
                else => return error.TypeError,
            },
        };
    }

    fn evalBinary(self: *Vm, env: *Env, op: BinaryOp, lhs_expr: *Expr, rhs_expr: *Expr) EvalError!Value {
        if (op == .and_) {
            const lhs = try self.evalExpr(env, lhs_expr);
            if (!lhs.truthy()) return lhs;
            return try self.evalExpr(env, rhs_expr);
        }
        if (op == .or_) {
            const lhs = try self.evalExpr(env, lhs_expr);
            if (lhs.truthy()) return lhs;
            return try self.evalExpr(env, rhs_expr);
        }

        const lhs = try self.evalExpr(env, lhs_expr);
        const rhs = try self.evalExpr(env, rhs_expr);
        return switch (op) {
            .add => .{ .number = (try valueToNumber(lhs)) + (try valueToNumber(rhs)) },
            .sub => .{ .number = (try valueToNumber(lhs)) - (try valueToNumber(rhs)) },
            .mul => .{ .number = (try valueToNumber(lhs)) * (try valueToNumber(rhs)) },
            .div => .{ .number = (try valueToNumber(lhs)) / (try valueToNumber(rhs)) },
            .mod => .{ .number = @mod(try valueToNumber(lhs), try valueToNumber(rhs)) },
            .pow => .{ .number = std.math.pow(f64, try valueToNumber(lhs), try valueToNumber(rhs)) },
            .concat => .{ .string = try std.fmt.allocPrint(self.alloc(), "{s}{s}", .{ try valueToStringAlloc(self.alloc(), lhs), try valueToStringAlloc(self.alloc(), rhs) }) },
            .eq => .{ .boolean = valueEquals(lhs, rhs) },
            .ne => .{ .boolean = !valueEquals(lhs, rhs) },
            .lt => .{ .boolean = try compareValues(lhs, rhs, .lt) },
            .le => .{ .boolean = try compareValues(lhs, rhs, .le) },
            .gt => .{ .boolean = try compareValues(lhs, rhs, .gt) },
            .ge => .{ .boolean = try compareValues(lhs, rhs, .ge) },
            .and_, .or_ => unreachable,
        };
    }

    fn evalTableCtor(self: *Vm, env: *Env, fields: []const TableField) EvalError!Value {
        const table = try Table.init(self.alloc());
        for (fields) |field| {
            switch (field) {
                .array => |expr| try table.array.append(self.alloc(), try self.evalExpr(env, expr)),
                .named => |named| try table.putString(named.name, try self.evalExpr(env, named.value)),
                .indexed => |indexed| try table.set(try self.evalExpr(env, indexed.key), try self.evalExpr(env, indexed.value)),
            }
        }
        return .{ .table = table };
    }

    fn cloneConstTableTemplateAlloc(allocator: std.mem.Allocator, template: *const Table) std.mem.Allocator.Error!*Table {
        const table = try Table.init(allocator);
        try table.array.ensureTotalCapacity(allocator, template.array.items.len);
        for (template.array.items) |value| {
            table.array.appendAssumeCapacity(try cloneConstValueAlloc(allocator, value));
        }

        var string_iter = template.string_fields.iterator();
        while (string_iter.next()) |entry| {
            try table.putString(entry.key_ptr.*, try cloneConstValueAlloc(allocator, entry.value_ptr.*));
        }

        var int_iter = template.int_fields.iterator();
        while (int_iter.next()) |entry| {
            try table.int_fields.put(allocator, entry.key_ptr.*, try cloneConstValueAlloc(allocator, entry.value_ptr.*));
        }
        return table;
    }

    fn cloneConstValueAlloc(allocator: std.mem.Allocator, value: Value) std.mem.Allocator.Error!Value {
        return switch (value) {
            .table => |table| .{ .table = try cloneConstTableTemplateAlloc(allocator, table) },
            else => value,
        };
    }

    fn evalCall(self: *Vm, env: *Env, callee_expr: *Expr, args_expr: []const *Expr) EvalError!Value {
        const callee = try self.evalExpr(env, callee_expr);
        if (callee != .function) return error.InvalidCall;
        const args = try self.evalExprs(env, args_expr);
        const results = try self.callFunction(callee.function, args);
        return if (results.len == 0) .nil else results[0];
    }

    fn callFunction(self: *Vm, function: *Function, args: []const Value) EvalError![]Value {
        return switch (function.kind) {
            .native => |native| try native(self, args),
            .generated => error.InvalidCall,
            .user => |user| blk: {
                const call_env = try self.createEnv(function.env);
                for (user.params, 0..) |name, idx| {
                    try envSetLocal(call_env, name, if (idx < args.len) args[idx] else .nil);
                }
                if (user.is_vararg) {
                    const extra_args = if (args.len > user.params.len) args[user.params.len..] else &.{};
                    call_env.varargs = extra_args;
                }
                break :blk switch (try self.executeBlock(call_env, user.body)) {
                    .none, .break_loop => &.{},
                    .returned => |values| values,
                };
            },
        };
    }
};

fn envLookup(env: *Env, name: []const u8) !Value {
    var current: ?*Env = env;
    while (current) |scope| : (current = scope.parent) {
        if (scope.vars.get(name)) |value| return value;
    }
    return error.UnknownVariable;
}

fn envSetLocal(env: *Env, name: []const u8, value: Value) !void {
    const gop = try env.vars.getOrPut(env.allocator, name);
    if (!gop.found_existing) gop.key_ptr.* = try env.allocator.dupe(u8, name);
    gop.value_ptr.* = value;
}

fn envSet(env: *Env, name: []const u8, value: Value) !void {
    try envSetLocal(env, name, value);
}

fn envAssign(env: *Env, name: []const u8, value: Value) !void {
    var current: ?*Env = env;
    while (current) |scope| : (current = scope.parent) {
        if (scope.vars.getPtr(name)) |slot| {
            slot.* = value;
            return;
        }
    }
    try envSetLocal(env, name, value);
}

fn executeUnaryValue(op: UnaryOp, value: Value) !Value {
    return switch (op) {
        .negate => .{ .number = -(try valueToNumber(value)) },
        .not_ => .{ .boolean = !value.truthy() },
        .length => switch (value) {
            .string => |str| .{ .number = @floatFromInt(str.len) },
            .table => |table| .{ .number = @floatFromInt(table.array.items.len) },
            else => error.TypeError,
        },
    };
}

fn executeBinaryValue(allocator: std.mem.Allocator, op: BinaryOp, lhs: Value, rhs: Value) !Value {
    if (op == .and_ or op == .or_) return error.UnsupportedSyntax;
    return switch (op) {
        .add => .{ .number = (try valueToNumber(lhs)) + (try valueToNumber(rhs)) },
        .sub => .{ .number = (try valueToNumber(lhs)) - (try valueToNumber(rhs)) },
        .mul => .{ .number = (try valueToNumber(lhs)) * (try valueToNumber(rhs)) },
        .div => .{ .number = (try valueToNumber(lhs)) / (try valueToNumber(rhs)) },
        .mod => .{ .number = @mod(try valueToNumber(lhs), try valueToNumber(rhs)) },
        .pow => .{ .number = std.math.pow(f64, try valueToNumber(lhs), try valueToNumber(rhs)) },
        .concat => .{ .string = try std.fmt.allocPrint(allocator, "{s}{s}", .{ try valueToStringAlloc(allocator, lhs), try valueToStringAlloc(allocator, rhs) }) },
        .eq => .{ .boolean = valueEquals(lhs, rhs) },
        .ne => .{ .boolean = !valueEquals(lhs, rhs) },
        .lt => .{ .boolean = try compareValues(lhs, rhs, .lt) },
        .le => .{ .boolean = try compareValues(lhs, rhs, .le) },
        .gt => .{ .boolean = try compareValues(lhs, rhs, .gt) },
        .ge => .{ .boolean = try compareValues(lhs, rhs, .ge) },
        .and_, .or_ => unreachable,
    };
}

fn valueToNumber(value: Value) !f64 {
    return switch (value) {
        .number => |num| num,
        .string => |str| std.fmt.parseFloat(f64, str) catch return error.TypeError,
        else => error.TypeError,
    };
}

fn valueToStringAlloc(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    return switch (value) {
        .nil => "nil",
        .boolean => |flag| if (flag) "true" else "false",
        .number => |num| std.fmt.allocPrint(allocator, "{d}", .{num}),
        .string => |str| str,
        .table => "table",
        .generated_callable => "function",
        .function => "function",
        .iterator => "iterator",
    };
}

fn valueEquals(lhs: Value, rhs: Value) bool {
    if (@intFromEnum(lhs) != @intFromEnum(rhs)) return false;
    return switch (lhs) {
        .nil => true,
        .boolean => |value| value == rhs.boolean,
        .number => |value| value == rhs.number,
        .string => |value| std.mem.eql(u8, value, rhs.string),
        .table => |value| value == rhs.table,
        .generated_callable => |value| value.id == rhs.generated_callable.id and value.capture == rhs.generated_callable.capture and value.globals == rhs.generated_callable.globals,
        .function => |value| value == rhs.function,
        .iterator => |value| value.table == rhs.iterator.table and value.index == rhs.iterator.index and value.kind == rhs.iterator.kind,
    };
}

fn compareValues(lhs: Value, rhs: Value, comptime which: enum { lt, le, gt, ge }) !bool {
    return switch (lhs) {
        .number => |num| switch (which) {
            .lt => num < try valueToNumber(rhs),
            .le => num <= try valueToNumber(rhs),
            .gt => num > try valueToNumber(rhs),
            .ge => num >= try valueToNumber(rhs),
        },
        .string => |str| {
            if (rhs != .string) return error.TypeError;
            return switch (which) {
                .lt => std.mem.order(u8, str, rhs.string) == .lt,
                .le => blk: {
                    const order = std.mem.order(u8, str, rhs.string);
                    break :blk order == .lt or order == .eq;
                },
                .gt => std.mem.order(u8, str, rhs.string) == .gt,
                .ge => blk: {
                    const order = std.mem.order(u8, str, rhs.string);
                    break :blk order == .gt or order == .eq;
                },
            };
        },
        else => error.TypeError,
    };
}

fn floatToExactPositiveInt(num: f64) ?usize {
    if (num < 1) return null;
    const int = @as(usize, @intFromFloat(num));
    if (@as(f64, @floatFromInt(int)) != num) return null;
    return int;
}

fn iteratorNextAlloc(iterator: *Iterator) !?[2]Value {
    switch (iterator.kind) {
        .pairs => {
            if (iterator.index < iterator.table.array.items.len) {
                iterator.index += 1;
                return .{ .{ .number = @floatFromInt(iterator.index) }, iterator.table.array.items[iterator.index - 1] };
            }
            var count: usize = iterator.table.array.items.len;
            var it = iterator.table.string_fields.iterator();
            while (it.next()) |entry| {
                count += 1;
                if (count == iterator.index + 1) {
                    iterator.index += 1;
                    return .{ .{ .string = entry.key_ptr.* }, entry.value_ptr.* };
                }
            }
            return null;
        },
        .ipairs => {
            if (iterator.index >= iterator.table.array.items.len) return null;
            iterator.index += 1;
            return .{ .{ .number = @floatFromInt(iterator.index) }, iterator.table.array.items[iterator.index - 1] };
        },
    }
}

fn builtinPrint(vm: *Vm, args: []const Value) ![]Value {
    var out: std.ArrayList(u8) = .empty;
    for (args, 0..) |arg, idx| {
        if (idx != 0) try out.appendSlice(vm.alloc(), "\t");
        try appendValueText(&out, vm.alloc(), arg);
    }
    try out.appendSlice(vm.alloc(), "\n");
    try std.Io.File.stdout().writeStreamingAll(std.Options.debug_io, out.items);
    return emptyReturns();
}

fn builtinTostring(vm: *Vm, args: []const Value) ![]Value {
    return if (args.len == 0)
        try singleReturn(vm, .{ .string = "nil" })
    else
        try singleReturn(vm, .{ .string = try valueToStringAlloc(vm.alloc(), args[0]) });
}

fn builtinTonumber(vm: *Vm, args: []const Value) ![]Value {
    if (args.len == 0) return try singleReturn(vm, .nil);
    return try singleReturn(vm, .{ .number = try valueToNumber(args[0]) });
}

fn builtinType(vm: *Vm, args: []const Value) ![]Value {
    const value = if (args.len == 0) Value.nil else args[0];
    return try singleReturn(vm, .{ .string = switch (value) {
        .nil => "nil",
        .boolean => "boolean",
        .number => "number",
        .string => "string",
        .table => "table",
        .generated_callable => "function",
        .function => "function",
        .iterator => "userdata",
    } });
}

fn builtinPairs(vm: *Vm, args: []const Value) ![]Value {
    if (args.len == 0 or args[0] != .table) return error.TypeError;
    return try singleReturn(vm, .{ .iterator = .{ .kind = .pairs, .table = args[0].table } });
}

fn builtinIpairs(vm: *Vm, args: []const Value) ![]Value {
    if (args.len == 0 or args[0] != .table) return error.TypeError;
    return try singleReturn(vm, .{ .iterator = .{ .kind = .ipairs, .table = args[0].table } });
}

fn builtinStringLen(vm: *Vm, args: []const Value) ![]Value {
    if (args.len == 0 or args[0] != .string) return error.TypeError;
    return try singleReturn(vm, .{ .number = @floatFromInt(args[0].string.len) });
}

fn builtinStringLower(vm: *Vm, args: []const Value) ![]Value {
    if (args.len == 0 or args[0] != .string) return error.TypeError;
    const out = try vm.alloc().dupe(u8, args[0].string);
    for (out) |*byte| byte.* = std.ascii.toLower(byte.*);
    return try singleReturn(vm, .{ .string = out });
}

fn builtinStringUpper(vm: *Vm, args: []const Value) ![]Value {
    if (args.len == 0 or args[0] != .string) return error.TypeError;
    const out = try vm.alloc().dupe(u8, args[0].string);
    for (out) |*byte| byte.* = std.ascii.toUpper(byte.*);
    return try singleReturn(vm, .{ .string = out });
}

fn builtinStringSub(vm: *Vm, args: []const Value) ![]Value {
    if (args.len < 2 or args[0] != .string) return error.TypeError;
    const str = args[0].string;
    const start_num = try valueToNumber(args[1]);
    const finish_num = if (args.len >= 3) try valueToNumber(args[2]) else @as(f64, @floatFromInt(str.len));
    const start = @max(@as(usize, 1), @as(usize, @intFromFloat(start_num)));
    const finish = @min(str.len, @as(usize, @intFromFloat(finish_num)));
    if (start > finish or start > str.len) return try singleReturn(vm, .{ .string = "" });
    return try singleReturn(vm, .{ .string = try vm.alloc().dupe(u8, str[start - 1 .. finish]) });
}

fn builtinMathFloor(vm: *Vm, args: []const Value) ![]Value {
    if (args.len == 0) return error.TypeError;
    return try singleReturn(vm, .{ .number = @floor(try valueToNumber(args[0])) });
}

fn builtinMathCeil(vm: *Vm, args: []const Value) ![]Value {
    if (args.len == 0) return error.TypeError;
    return try singleReturn(vm, .{ .number = @ceil(try valueToNumber(args[0])) });
}

fn builtinMathAbs(vm: *Vm, args: []const Value) ![]Value {
    if (args.len == 0) return error.TypeError;
    return try singleReturn(vm, .{ .number = @abs(try valueToNumber(args[0])) });
}

fn builtinTableInsert(_: *Vm, args: []const Value) ![]Value {
    if (args.len < 2 or args[0] != .table) return error.TypeError;
    try args[0].table.array.append(args[0].table.allocator, args[1]);
    return &.{};
}

fn builtinTableConcat(vm: *Vm, args: []const Value) ![]Value {
    if (args.len == 0 or args[0] != .table) return error.TypeError;
    const sep = if (args.len >= 2 and args[1] == .string) args[1].string else "";
    var out: std.ArrayList(u8) = .empty;
    for (args[0].table.array.items, 0..) |item, idx| {
        if (idx != 0) try out.appendSlice(vm.alloc(), sep);
        try appendValueText(&out, vm.alloc(), item);
    }
    return try singleReturn(vm, .{ .string = try out.toOwnedSlice(vm.alloc()) });
}

fn builtinFrameGetParent(vm: *Vm, args: []const Value) ![]Value {
    if (args.len == 0) return emptyReturns();
    return singleReturn(vm, args[0]);
}

fn builtinFrameExpandTemplate(vm: *Vm, _: []const Value) ![]Value {
    return singleReturn(vm, .{ .string = "" });
}

fn buildModuleFrameTable(vm: *Vm, args: []const ModuleArg) !*Table {
    const frame = try Table.init(vm.alloc());
    const args_table = try Table.init(vm.alloc());

    for (args, 0..) |arg, idx| {
        try args_table.putNumber(@floatFromInt(idx + 1), .{ .string = try vm.alloc().dupe(u8, arg.value) });
        if (arg.name) |name| {
            try args_table.putString(name, .{ .string = try vm.alloc().dupe(u8, arg.value) });
        }
    }

    try frame.putString("args", .{ .table = args_table });
    try frame.putString("getParent", .{ .function = try vm.nativeFunction("frame.getParent", builtinFrameGetParent) });
    try frame.putString("expandTemplate", .{ .function = try vm.nativeFunction("frame.expandTemplate", builtinFrameExpandTemplate) });
    return frame;
}

pub const DependencyReport = struct {
    direct_templates: []const []const u8,
    direct_modules: []const []const u8,
    transitive_modules: []const []const u8,
    missing_modules: []const []const u8,
    compiled_ok: []const []const u8,
    compiled_failed: []const ModuleCompileFailure,
    emitted_consistent: []const []const u8,
    emitted_inconsistent: []const ModuleCompileFailure,
};

pub const TemplateDependencyReport = struct {
    root_templates: []const []const u8,
    reachable_templates: []const []const u8,
    unresolved_templates: []const []const u8,
    direct_modules: []const []const u8,
    transitive_modules: []const []const u8,
    missing_modules: []const []const u8,
    compiled_ok: []const []const u8,
    compiled_failed: []const ModuleCompileFailure,
    emitted_consistent: []const []const u8,
    emitted_inconsistent: []const ModuleCompileFailure,

    pub fn deinit(self: *TemplateDependencyReport, allocator: std.mem.Allocator) void {
        freeStringSlice(allocator, self.root_templates);
        freeStringSlice(allocator, self.reachable_templates);
        freeStringSlice(allocator, self.unresolved_templates);
        freeStringSlice(allocator, self.direct_modules);
        freeStringSlice(allocator, self.transitive_modules);
        freeStringSlice(allocator, self.missing_modules);
        freeStringSlice(allocator, self.compiled_ok);
        freeStringSlice(allocator, self.emitted_consistent);
        for (self.compiled_failed) |failure| {
            allocator.free(failure.name);
            allocator.free(failure.reason);
        }
        allocator.free(self.compiled_failed);
        for (self.emitted_inconsistent) |failure| {
            allocator.free(failure.name);
            allocator.free(failure.reason);
        }
        allocator.free(self.emitted_inconsistent);
        self.* = undefined;
    }
};

pub const TemplateDependencyNode = struct {
    template_deps: []const []const u8 = &.{},
    direct_modules: []const []const u8 = &.{},
};

pub const TemplateDependencyGraph = struct {
    entry_direct_modules: []const []const u8 = &.{},
    template_nodes: *const std.StringHashMap(TemplateDependencyNode),
    module_nodes: *const std.StringHashMap([]const []const u8),
};

pub const ModuleCompileFailure = struct {
    name: []const u8,
    reason: []const u8,
};

const ModuleAudit = struct {
    missing_modules: []const []const u8,
    compiled_ok: []const []const u8,
    compiled_failed: []const ModuleCompileFailure,
    emitted_consistent: []const []const u8,
    emitted_inconsistent: []const ModuleCompileFailure,

    fn deinit(self: *ModuleAudit, allocator: std.mem.Allocator) void {
        freeStringSlice(allocator, self.missing_modules);
        freeStringSlice(allocator, self.compiled_ok);
        freeStringSlice(allocator, self.emitted_consistent);
        for (self.compiled_failed) |failure| {
            allocator.free(failure.name);
            allocator.free(failure.reason);
        }
        allocator.free(self.compiled_failed);
        for (self.emitted_inconsistent) |failure| {
            allocator.free(failure.name);
            allocator.free(failure.reason);
        }
        allocator.free(self.emitted_inconsistent);
        self.* = undefined;
    }
};

pub const ModuleSourceKind = enum {
    lua,
    json,
    non_lua,
    empty,
};

pub fn classifyModuleSource(source: []const u8) ModuleSourceKind {
    return classifyNamedModuleSource("", source);
}

pub fn classifyNamedModuleSource(name: []const u8, source: []const u8) ModuleSourceKind {
    const trimmed = skipLuaLeadingTrivia(source);
    if (trimmed.len == 0) return .empty;
    if (endsWithIgnoreCase(name, ".json")) return .json;
    if (looksLikeNonLuaModuleSource(trimmed)) return .non_lua;
    return .lua;
}

fn skipLuaLeadingTrivia(source: []const u8) []const u8 {
    var index: usize = 0;
    if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) index = 3;
    while (index < source.len) {
        while (index < source.len and std.ascii.isWhitespace(source[index])) : (index += 1) {}
        if (index + 1 >= source.len or source[index] != '-' or source[index + 1] != '-') break;
        index += 2;
        if (index + 1 < source.len and source[index] == '[' and source[index + 1] == '[') {
            index += 2;
            while (index + 1 < source.len and !(source[index] == ']' and source[index + 1] == ']')) : (index += 1) {}
            if (index + 1 >= source.len) return source[source.len..];
            index += 2;
            continue;
        }
        while (index < source.len and source[index] != '\n') : (index += 1) {}
    }
    return source[index..];
}

fn looksLikeNonLuaModuleSource(source: []const u8) bool {
    const non_lua_prefixes = [_][]const u8{
        "{{",
        "{|",
        "|}",
        "==",
        "__",
        "<!--",
        "<div",
        "<includeonly",
        "<noinclude",
        "<nowiki",
        "<onlyinclude",
        "<pre",
        "<templatedata",
        "[[category:",
        "#redirect",
    };
    for (non_lua_prefixes) |prefix| {
        if (std.ascii.startsWithIgnoreCase(source, prefix)) return true;
    }
    if (looksLikeStylesheetModuleSource(source)) return true;
    return looksLikePlaintextModuleDocumentation(source);
}

fn looksLikeStylesheetModuleSource(source: []const u8) bool {
    const first_line_end = std.mem.indexOfScalar(u8, source, '\n') orelse source.len;
    const first_line = std.mem.trim(u8, source[0..@min(first_line_end, 200)], &std.ascii.whitespace);
    if (first_line.len == 0) return false;

    if (std.mem.startsWith(u8, first_line, "/*")) return true;
    if (std.mem.indexOfScalar(u8, first_line, '{') == null) {
        return switch (first_line[0]) {
            '.', '#', '@', ':' => true,
            else => false,
        };
    }

    return switch (first_line[0]) {
        '.', '#', '@', ':', '[', '>', '+', '~', '*' => true,
        else => false,
    };
}

fn looksLikePlaintextModuleDocumentation(source: []const u8) bool {
    const first_line_end = std.mem.indexOfScalar(u8, source, '\n') orelse source.len;
    const first_line = std.mem.trim(u8, source[0..@min(first_line_end, 160)], &std.ascii.whitespace);
    if (first_line.len == 0) return false;

    const lua_prefixes = [_][]const u8{
        "local ",
        "function ",
        "return",
        "if ",
        "for ",
        "while ",
        "repeat",
        "do",
        "break",
        "module(",
        "require(",
    };
    for (lua_prefixes) |prefix| {
        if (std.ascii.startsWithIgnoreCase(first_line, prefix)) return false;
    }
    if (std.mem.indexOfAny(u8, first_line, "=(") != null) return false;

    const has_wiki_markup =
        std.mem.indexOf(u8, source, "[[") != null or
        std.mem.indexOf(u8, source, "{{") != null or
        std.mem.indexOf(u8, source, "==") != null;
    if (!has_wiki_markup) return false;

    var words: usize = 0;
    var in_word = false;
    for (first_line) |char| {
        if (std.ascii.isAlphabetic(char)) {
            if (!in_word) words += 1;
            in_word = true;
        } else {
            in_word = false;
        }
    }
    return words >= 3 and std.mem.indexOfAny(u8, first_line, ".:") != null;
}

const MappedReadOnlyFile = struct {
    mapping: []align(std.heap.page_size_min) const u8,

    fn deinit(self: *MappedReadOnlyFile) void {
        std.posix.munmap(self.mapping);
        self.* = undefined;
    }
};

pub const TemplateSources = struct {
    template_sources: std.StringHashMap([]const u8),
    module_sources: std.StringHashMap([]const u8),

    pub fn deinit(self: *TemplateSources, allocator: std.mem.Allocator) void {
        var template_it = self.template_sources.iterator();
        while (template_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.template_sources.deinit();

        var module_it = self.module_sources.iterator();
        while (module_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.module_sources.deinit();
        self.* = undefined;
    }
};

pub const SourcePageRef = struct {
    name: []const u8,
    page_start: u64,
    page_end: u64,
};

pub const LuaSourceScan = TemplateSources;

pub const ModuleSourceScan = struct {
    module_sources: std.StringHashMap([]const u8),

    pub fn deinit(self: *ModuleSourceScan, allocator: std.mem.Allocator) void {
        var it = self.module_sources.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.module_sources.deinit();
        self.* = undefined;
    }
};

pub fn analyzeDependenciesAlloc(
    allocator: std.mem.Allocator,
    xml_path: []const u8,
    structure_json_path: []const u8,
) !DependencyReport {
    var deps = try structure_report.loadDependencySetAlloc(std.Options.debug_io, allocator, structure_json_path);
    defer deps.deinit(allocator);

    const root_templates = if (deps.root_templates.len != 0)
        deps.root_templates
    else
        try loadStructureTemplateNames(allocator, structure_json_path);
    defer if (root_templates.ptr != deps.root_templates.ptr) freeStringSlice(allocator, root_templates);

    // Use the stored structure refs so dependency analysis does not rescan the
    // full XML dump once the structure report already knows the exact pages.
    var sources = try loadDependencySourcesFromStructureAlloc(allocator, xml_path, structure_json_path);
    defer sources.deinit(allocator);

    var report = try analyzeTemplateDependenciesFromSourcesAlloc(allocator, root_templates, &sources);
    errdefer report.deinit(allocator);

    return .{
        .direct_templates = report.root_templates,
        .direct_modules = report.direct_modules,
        .transitive_modules = report.transitive_modules,
        .missing_modules = report.missing_modules,
        .compiled_ok = report.compiled_ok,
        .compiled_failed = report.compiled_failed,
        .emitted_consistent = report.emitted_consistent,
        .emitted_inconsistent = report.emitted_inconsistent,
    };
}

// Shared structure-driven loader used by the repo's tooling path. The stored
// refs let us mmap the dump and copy only the pages the structure already
// proved are relevant.
pub fn loadDependencySourcesFromStructureAlloc(
    allocator: std.mem.Allocator,
    xml_path: []const u8,
    structure_json_path: []const u8,
) !TemplateSources {
    var deps = try structure_report.loadDependencySetAlloc(std.Options.debug_io, allocator, structure_json_path);
    defer deps.deinit(allocator);

    if (deps.reachable_template_pages.len == 0 and deps.transitive_module_pages.len == 0) {
        return error.MissingStructureDependencies;
    }

    const template_refs = try dupSourcePageRefsAlloc(allocator, deps.reachable_template_pages);
    defer freeSourcePageRefs(allocator, template_refs);
    const module_refs = try dupSourcePageRefsAlloc(allocator, deps.transitive_module_pages);
    defer freeSourcePageRefs(allocator, module_refs);
    return try loadSelectedTemplateAndModuleSourcesByRefsAlloc(allocator, xml_path, template_refs, module_refs);
}

// Full structure-driven source loader used by diagnostics and all-module audits.
pub fn loadAllStructureSourcesAlloc(
    allocator: std.mem.Allocator,
    xml_path: []const u8,
    structure_json_path: []const u8,
) !TemplateSources {
    var deps = try structure_report.loadDependencySetAlloc(std.Options.debug_io, allocator, structure_json_path);
    defer deps.deinit(allocator);

    if (deps.all_template_pages.len == 0 and deps.all_module_pages.len == 0) {
        return error.MissingStructureDependencies;
    }

    const template_refs = try dupSourcePageRefsAlloc(allocator, deps.all_template_pages);
    defer freeSourcePageRefs(allocator, template_refs);
    const module_refs = try dupSourcePageRefsAlloc(allocator, deps.all_module_pages);
    defer freeSourcePageRefs(allocator, module_refs);
    return try loadSelectedTemplateAndModuleSourcesByRefsAlloc(allocator, xml_path, template_refs, module_refs);
}

pub fn loadAllModuleSourcesFromStructureAlloc(
    allocator: std.mem.Allocator,
    xml_path: []const u8,
    structure_json_path: []const u8,
) !ModuleSourceScan {
    var sources = try loadAllStructureSourcesAlloc(allocator, xml_path, structure_json_path);

    // Only module pages are needed here. Move them out and free the template
    // side immediately to keep the all-module audit memory footprint down.
    const modules = sources.module_sources;
    sources.module_sources = std.StringHashMap([]const u8).init(allocator);
    sources.deinit(allocator);
    return .{ .module_sources = modules };
}

pub fn loadModuleSourceFromStructureAlloc(
    allocator: std.mem.Allocator,
    xml_path: []const u8,
    structure_json_path: []const u8,
    module_name: []const u8,
) !?[]u8 {
    var sources = try loadAllStructureSourcesAlloc(allocator, xml_path, structure_json_path);
    defer sources.deinit(allocator);

    const canonical = try canonicalModuleNameAlloc(allocator, module_name);
    defer allocator.free(canonical);

    const source = sources.module_sources.get(canonical) orelse return null;
    return try allocator.dupe(u8, source);
}

pub fn loadModuleSourceAlloc(
    allocator: std.mem.Allocator,
    xml_path: []const u8,
    module_name: []const u8,
) !?[]u8 {
    var sources = try scanTemplateAndModuleSourcesAlloc(allocator, xml_path);
    defer sources.deinit(allocator);

    const canonical = try canonicalModuleNameAlloc(allocator, module_name);
    defer allocator.free(canonical);

    const source = sources.module_sources.get(canonical) orelse return null;
    return try allocator.dupe(u8, source);
}

pub fn findModuleReferrersAlloc(
    allocator: std.mem.Allocator,
    xml_path: []const u8,
    module_name: []const u8,
) ![]const []const u8 {
    var sources = try scanTemplateAndModuleSourcesAlloc(allocator, xml_path);
    defer sources.deinit(allocator);

    const canonical = try canonicalModuleNameAlloc(allocator, module_name);
    defer allocator.free(canonical);

    var matches = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &matches);

    var it = sources.module_sources.iterator();
    while (it.next()) |entry| {
        const deps = try extractModuleDependencies(allocator, entry.value_ptr.*);
        defer freeStringSlice(allocator, deps);
        for (deps) |dep| {
            if (!std.mem.eql(u8, dep, canonical)) continue;
            const gop = try matches.getOrPut(allocator, entry.key_ptr.*);
            if (!gop.found_existing) gop.key_ptr.* = try allocator.dupe(u8, entry.key_ptr.*);
            break;
        }
    }

    return collectStringSet(allocator, &matches);
}

pub fn findModuleReferrersFromSourcesAlloc(
    allocator: std.mem.Allocator,
    sources: *const TemplateSources,
    module_name: []const u8,
) ![]const []const u8 {
    const canonical = try canonicalModuleNameAlloc(allocator, module_name);
    defer allocator.free(canonical);

    var matches = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &matches);

    var it = sources.module_sources.iterator();
    while (it.next()) |entry| {
        const deps = try extractModuleDependencies(allocator, entry.value_ptr.*);
        defer freeStringSlice(allocator, deps);
        for (deps) |dep| {
            if (!std.mem.eql(u8, dep, canonical)) continue;
            const gop = try matches.getOrPut(allocator, entry.key_ptr.*);
            if (!gop.found_existing) gop.key_ptr.* = try allocator.dupe(u8, entry.key_ptr.*);
            break;
        }
    }

    return collectStringSet(allocator, &matches);
}

pub fn findModuleReferrersFromStructureAlloc(
    allocator: std.mem.Allocator,
    xml_path: []const u8,
    structure_json_path: []const u8,
    module_name: []const u8,
) ![]const []const u8 {
    var sources = try loadAllStructureSourcesAlloc(allocator, xml_path, structure_json_path);
    defer sources.deinit(allocator);
    return try findModuleReferrersFromSourcesAlloc(allocator, &sources, module_name);
}

pub fn findTemplateReferrersAlloc(
    allocator: std.mem.Allocator,
    xml_path: []const u8,
    template_name: []const u8,
) ![]const []const u8 {
    var sources = try scanTemplateAndModuleSourcesAlloc(allocator, xml_path);
    defer sources.deinit(allocator);

    const canonical = try canonicalTemplateNameAlloc(allocator, template_name);
    defer allocator.free(canonical);

    var matches = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &matches);

    var it = sources.template_sources.iterator();
    while (it.next()) |entry| {
        const deps = try extractTemplateDependenciesAlloc(allocator, entry.value_ptr.*, entry.key_ptr.*);
        defer freeStringSlice(allocator, deps);
        for (deps) |dep| {
            if (!std.mem.eql(u8, dep, canonical)) continue;
            const gop = try matches.getOrPut(allocator, entry.key_ptr.*);
            if (!gop.found_existing) gop.key_ptr.* = try allocator.dupe(u8, entry.key_ptr.*);
            break;
        }
    }

    return collectStringSet(allocator, &matches);
}

pub fn findTemplateReferrersFromSourcesAlloc(
    allocator: std.mem.Allocator,
    sources: *const TemplateSources,
    template_name: []const u8,
) ![]const []const u8 {
    const canonical = try canonicalTemplateNameAlloc(allocator, template_name);
    defer allocator.free(canonical);

    var matches = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &matches);

    var it = sources.template_sources.iterator();
    while (it.next()) |entry| {
        const deps = try extractTemplateDependenciesAlloc(allocator, entry.value_ptr.*, entry.key_ptr.*);
        defer freeStringSlice(allocator, deps);
        for (deps) |dep| {
            if (!std.mem.eql(u8, dep, canonical)) continue;
            const gop = try matches.getOrPut(allocator, entry.key_ptr.*);
            if (!gop.found_existing) gop.key_ptr.* = try allocator.dupe(u8, entry.key_ptr.*);
            break;
        }
    }

    return collectStringSet(allocator, &matches);
}

pub fn findTemplateReferrersFromStructureAlloc(
    allocator: std.mem.Allocator,
    xml_path: []const u8,
    structure_json_path: []const u8,
    template_name: []const u8,
) ![]const []const u8 {
    var sources = try loadAllStructureSourcesAlloc(allocator, xml_path, structure_json_path);
    defer sources.deinit(allocator);
    return try findTemplateReferrersFromSourcesAlloc(allocator, &sources, template_name);
}

pub fn scanLuaSourcesAlloc(allocator: std.mem.Allocator, xml_path: []const u8) !LuaSourceScan {
    return scanTemplateAndModuleSourcesAlloc(allocator, xml_path);
}

pub fn scanModuleSourcesAlloc(allocator: std.mem.Allocator, xml_path: []const u8) !ModuleSourceScan {
    var module_sources = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = module_sources.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        module_sources.deinit();
    }

    var mapped = try mmapReadOnlyPath(xml_path);
    defer mapped.deinit();

    var current_title: ?[]u8 = null;
    defer if (current_title) |title| allocator.free(title);
    var current_ns: enum { other, module } = .other;
    var capture_text = false;
    var text_accum = std.ArrayList(u8).empty;
    defer text_accum.deinit(allocator);
    var pages_seen: usize = 0;
    var last_progress_pages: usize = 0;
    var cursor: usize = 0;

    while (nextMappedLine(mapped.mapping, &cursor)) |line| {
        if (std.mem.indexOf(u8, line, "<page>") != null) {
            pages_seen += 1;
            if (pages_seen - last_progress_pages >= 250_000) {
                last_progress_pages = pages_seen;
                std.debug.print(
                    "lua module scan: pages={d} module_sources={d}\n",
                    .{ pages_seen, module_sources.count() },
                );
            }
        }
        if (extractTagText(line, "title")) |title| {
            if (current_title) |old| allocator.free(old);
            current_title = try allocator.dupe(u8, title);
        }
        if (extractTagText(line, "ns")) |ns| {
            current_ns = if (std.mem.eql(u8, ns, "828")) .module else .other;
        }

        if (std.mem.indexOf(u8, line, "<text")) |_| {
            capture_text = true;
            text_accum.clearRetainingCapacity();
            if (std.mem.indexOf(u8, line, ">")) |start_tag_end| {
                const rest = line[start_tag_end + 1 ..];
                if (std.mem.indexOf(u8, rest, "</text>")) |end_idx| {
                    try text_accum.appendSlice(allocator, rest[0..end_idx]);
                    capture_text = false;
                    if (current_ns == .module) try maybeStoreModuleSource(allocator, &module_sources, current_title, "828", text_accum.items);
                } else {
                    try text_accum.appendSlice(allocator, rest);
                    try text_accum.append(allocator, '\n');
                }
            }
            continue;
        }

        if (capture_text) {
            if (std.mem.indexOf(u8, line, "</text>")) |end_idx| {
                try text_accum.appendSlice(allocator, line[0..end_idx]);
                capture_text = false;
                if (current_ns == .module) try maybeStoreModuleSource(allocator, &module_sources, current_title, "828", text_accum.items);
            } else {
                try text_accum.appendSlice(allocator, line);
                try text_accum.append(allocator, '\n');
            }
        }
    }

    return .{
        .module_sources = module_sources,
    };
}

pub fn analyzeTemplateDependenciesAlloc(
    allocator: std.mem.Allocator,
    xml_path: []const u8,
    template_names: []const []const u8,
) !TemplateDependencyReport {
    var sources = try scanTemplateAndModuleSourcesAlloc(allocator, xml_path);
    defer sources.deinit(allocator);
    return analyzeTemplateDependenciesFromSourcesAlloc(allocator, template_names, &sources);
}

pub fn analyzeRenderDependenciesAlloc(
    allocator: std.mem.Allocator,
    xml_path: []const u8,
    template_names: []const []const u8,
) !TemplateDependencyReport {
    var sources = try scanTemplateAndModuleSourcesAlloc(allocator, xml_path);
    defer sources.deinit(allocator);

    const direct_entry_modules = try scanDirectInvokeModules(allocator, xml_path);
    defer freeStringSlice(allocator, direct_entry_modules);

    return analyzeRenderDependenciesFromSourcesAlloc(
        allocator,
        template_names,
        direct_entry_modules,
        &sources,
    );
}

pub fn analyzeTemplateDependenciesFromSourcesAlloc(
    allocator: std.mem.Allocator,
    template_names: []const []const u8,
    sources: *const TemplateSources,
) !TemplateDependencyReport {
    var root_templates = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &root_templates);
    for (template_names) |name| {
        if (!isLikelyTemplatePageName(name)) continue;
        if (isIgnoredTemplateMagicName(name)) continue;
        try insertCanonicalTemplateName(&root_templates, allocator, name);
    }

    var reachable_templates = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &reachable_templates);
    var unresolved_templates = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &unresolved_templates);
    var direct_modules = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &direct_modules);

    var template_stack: std.ArrayList([]const u8) = .empty;
    defer template_stack.deinit(allocator);

    var root_it = root_templates.iterator();
    while (root_it.next()) |entry| {
        const key = entry.key_ptr.*;
        const gop = try reachable_templates.getOrPut(allocator, key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try allocator.dupe(u8, key);
            try template_stack.append(allocator, gop.key_ptr.*);
        }
    }

    while (template_stack.pop()) |name| {
        const source = sources.template_sources.get(name) orelse {
            if (!root_templates.contains(name)) {
                const unresolved_gop = try unresolved_templates.getOrPut(allocator, name);
                if (!unresolved_gop.found_existing) unresolved_gop.key_ptr.* = try allocator.dupe(u8, name);
            }
            continue;
        };

        const template_deps = try extractTemplateDependenciesAlloc(allocator, source, name);
        defer freeStringSlice(allocator, template_deps);
        for (template_deps) |dep| {
            if (!sources.template_sources.contains(dep)) {
                const unresolved_gop = try unresolved_templates.getOrPut(allocator, dep);
                if (!unresolved_gop.found_existing) unresolved_gop.key_ptr.* = try allocator.dupe(u8, dep);
                continue;
            }
            const dep_gop = try reachable_templates.getOrPut(allocator, dep);
            if (!dep_gop.found_existing) {
                dep_gop.key_ptr.* = try allocator.dupe(u8, dep);
                try template_stack.append(allocator, dep_gop.key_ptr.*);
            }
        }

        try addInvokeMatches(allocator, &direct_modules, source);
    }

    var transitive_modules = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &transitive_modules);
    var module_stack: std.ArrayList([]const u8) = .empty;
    defer module_stack.deinit(allocator);

    var direct_module_it = direct_modules.iterator();
    while (direct_module_it.next()) |entry| {
        const name = entry.key_ptr.*;
        const gop = try transitive_modules.getOrPut(allocator, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try allocator.dupe(u8, name);
            try module_stack.append(allocator, gop.key_ptr.*);
        }
    }

    while (module_stack.pop()) |name| {
        const source = sources.module_sources.get(name) orelse continue;
        const deps = try extractModuleDependencies(allocator, source);
        defer freeStringSlice(allocator, deps);
        for (deps) |dep| {
            const gop = try transitive_modules.getOrPut(allocator, dep);
            if (!gop.found_existing) {
                gop.key_ptr.* = try allocator.dupe(u8, dep);
                try module_stack.append(allocator, gop.key_ptr.*);
            }
        }
    }

    const transitive_module_names = try collectStringSet(allocator, &transitive_modules);
    errdefer freeStringSlice(allocator, transitive_module_names);
    var audit = try auditModuleNamesAlloc(allocator, &sources.module_sources, transitive_module_names);
    defer audit.deinit(allocator);

    return .{
        .root_templates = try collectStringSet(allocator, &root_templates),
        .reachable_templates = try collectStringSet(allocator, &reachable_templates),
        .unresolved_templates = try collectStringSet(allocator, &unresolved_templates),
        .direct_modules = try collectStringSet(allocator, &direct_modules),
        .transitive_modules = transitive_module_names,
        .missing_modules = try dupStringSliceAlloc(allocator, audit.missing_modules),
        .compiled_ok = try dupStringSliceAlloc(allocator, audit.compiled_ok),
        .compiled_failed = try dupFailureSliceAlloc(allocator, audit.compiled_failed),
        .emitted_consistent = try dupStringSliceAlloc(allocator, audit.emitted_consistent),
        .emitted_inconsistent = try dupFailureSliceAlloc(allocator, audit.emitted_inconsistent),
    };
}

pub fn analyzeRenderDependenciesFromSourcesAlloc(
    allocator: std.mem.Allocator,
    template_names: []const []const u8,
    entry_direct_modules: []const []const u8,
    sources: *const TemplateSources,
) !TemplateDependencyReport {
    var report = try analyzeTemplateDependenciesFromSourcesAlloc(allocator, template_names, sources);
    errdefer report.deinit(allocator);

    if (entry_direct_modules.len == 0) return report;

    const merged_direct_modules = try mergeUniqueStringSlicesAlloc(allocator, &.{
        report.direct_modules,
        entry_direct_modules,
    });
    const transitive_modules = try collectTransitiveModulesFromSourcesAlloc(allocator, &sources.module_sources, merged_direct_modules);
    errdefer freeStringSlice(allocator, transitive_modules);

    var audit = try auditModuleNamesAlloc(allocator, &sources.module_sources, transitive_modules);
    defer audit.deinit(allocator);

    freeStringSlice(allocator, report.direct_modules);
    freeStringSlice(allocator, report.transitive_modules);
    freeStringSlice(allocator, report.missing_modules);
    freeStringSlice(allocator, report.compiled_ok);
    freeStringSlice(allocator, report.emitted_consistent);
    for (report.compiled_failed) |failure| {
        allocator.free(failure.name);
        allocator.free(failure.reason);
    }
    allocator.free(report.compiled_failed);
    for (report.emitted_inconsistent) |failure| {
        allocator.free(failure.name);
        allocator.free(failure.reason);
    }
    allocator.free(report.emitted_inconsistent);

    report.direct_modules = merged_direct_modules;
    report.transitive_modules = transitive_modules;
    report.missing_modules = try dupStringSliceAlloc(allocator, audit.missing_modules);
    report.compiled_ok = try dupStringSliceAlloc(allocator, audit.compiled_ok);
    report.compiled_failed = try dupFailureSliceAlloc(allocator, audit.compiled_failed);
    report.emitted_consistent = try dupStringSliceAlloc(allocator, audit.emitted_consistent);
    report.emitted_inconsistent = try dupFailureSliceAlloc(allocator, audit.emitted_inconsistent);
    return report;
}

pub fn analyzeRenderDependenciesFromGraphAlloc(
    allocator: std.mem.Allocator,
    template_names: []const []const u8,
    graph: TemplateDependencyGraph,
) !TemplateDependencyReport {
    var root_templates = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &root_templates);
    for (template_names) |name| {
        if (!isLikelyTemplatePageName(name)) continue;
        if (isIgnoredTemplateMagicName(name)) continue;
        try insertCanonicalTemplateName(&root_templates, allocator, name);
    }

    var reachable_templates = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &reachable_templates);
    var unresolved_templates = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &unresolved_templates);
    var direct_modules = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &direct_modules);

    var template_stack: std.ArrayList([]const u8) = .empty;
    defer template_stack.deinit(allocator);

    var root_it = root_templates.iterator();
    while (root_it.next()) |entry| {
        const key = entry.key_ptr.*;
        const gop = try reachable_templates.getOrPut(allocator, key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try allocator.dupe(u8, key);
            try template_stack.append(allocator, gop.key_ptr.*);
        }
    }

    while (template_stack.pop()) |name| {
        const node = graph.template_nodes.get(name) orelse {
            if (!root_templates.contains(name)) {
                const unresolved_gop = try unresolved_templates.getOrPut(allocator, name);
                if (!unresolved_gop.found_existing) unresolved_gop.key_ptr.* = try allocator.dupe(u8, name);
            }
            continue;
        };

        for (node.template_deps) |dep| {
            if (!graph.template_nodes.contains(dep)) {
                const unresolved_gop = try unresolved_templates.getOrPut(allocator, dep);
                if (!unresolved_gop.found_existing) unresolved_gop.key_ptr.* = try allocator.dupe(u8, dep);
                continue;
            }
            const dep_gop = try reachable_templates.getOrPut(allocator, dep);
            if (!dep_gop.found_existing) {
                dep_gop.key_ptr.* = try allocator.dupe(u8, dep);
                try template_stack.append(allocator, dep_gop.key_ptr.*);
            }
        }

        for (node.direct_modules) |module_name| {
            if (!isLikelyCodeModulePageName(module_name)) continue;
            try insertCanonicalModuleName(&direct_modules, allocator, module_name);
        }
    }

    for (graph.entry_direct_modules) |module_name| {
        if (!isLikelyCodeModulePageName(module_name)) continue;
        try insertCanonicalModuleName(&direct_modules, allocator, module_name);
    }

    var transitive_modules = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &transitive_modules);
    var missing_modules = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &missing_modules);
    var module_stack: std.ArrayList([]const u8) = .empty;
    defer module_stack.deinit(allocator);

    var direct_module_it = direct_modules.iterator();
    while (direct_module_it.next()) |entry| {
        const name = entry.key_ptr.*;
        const gop = try transitive_modules.getOrPut(allocator, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try allocator.dupe(u8, name);
            try module_stack.append(allocator, gop.key_ptr.*);
        }
    }

    while (module_stack.pop()) |name| {
        const deps = graph.module_nodes.get(name) orelse {
            const missing_gop = try missing_modules.getOrPut(allocator, name);
            if (!missing_gop.found_existing) missing_gop.key_ptr.* = try allocator.dupe(u8, name);
            continue;
        };
        for (deps) |dep| {
            const gop = try transitive_modules.getOrPut(allocator, dep);
            if (!gop.found_existing) {
                gop.key_ptr.* = try allocator.dupe(u8, dep);
                try module_stack.append(allocator, gop.key_ptr.*);
            }
        }
    }

    return .{
        .root_templates = try collectStringSet(allocator, &root_templates),
        .reachable_templates = try collectStringSet(allocator, &reachable_templates),
        .unresolved_templates = try collectStringSet(allocator, &unresolved_templates),
        .direct_modules = try collectStringSet(allocator, &direct_modules),
        .transitive_modules = try collectStringSet(allocator, &transitive_modules),
        .missing_modules = try collectStringSet(allocator, &missing_modules),
        .compiled_ok = try allocator.alloc([]const u8, 0),
        .compiled_failed = try allocator.alloc(ModuleCompileFailure, 0),
        .emitted_consistent = try allocator.alloc([]const u8, 0),
        .emitted_inconsistent = try allocator.alloc(ModuleCompileFailure, 0),
    };
}

fn auditModuleNamesAlloc(
    allocator: std.mem.Allocator,
    module_sources: *const std.StringHashMap([]const u8),
    module_names: []const []const u8,
) !ModuleAudit {
    var missing_modules: std.ArrayList([]const u8) = .empty;
    errdefer freeOwnedStringList(allocator, &missing_modules);

    var compiled_ok: std.ArrayList([]const u8) = .empty;
    errdefer freeOwnedStringList(allocator, &compiled_ok);

    var compiled_failed: std.ArrayList(ModuleCompileFailure) = .empty;
    errdefer freeFailureList(allocator, &compiled_failed);

    var emitted_consistent: std.ArrayList([]const u8) = .empty;
    errdefer freeOwnedStringList(allocator, &emitted_consistent);

    var emitted_inconsistent: std.ArrayList(ModuleCompileFailure) = .empty;
    errdefer freeFailureList(allocator, &emitted_inconsistent);

    for (module_names) |name| {
        const source = module_sources.get(name) orelse {
            try missing_modules.append(allocator, try allocator.dupe(u8, name));
            continue;
        };

        switch (classifyNamedModuleSource(name, source)) {
            .lua => {},
            .json => {
                try compiled_ok.append(allocator, try allocator.dupe(u8, name));
                try emitted_consistent.append(allocator, try allocator.dupe(u8, name));
                continue;
            },
            .non_lua, .empty => continue,
        }

        var first = compileQuiet(allocator, source) catch |err| {
            try appendFailureAlloc(allocator, &compiled_failed, name, @errorName(err));
            continue;
        };
        defer first.deinit();

        var second = compileQuiet(allocator, source) catch |err| {
            const reason = try std.fmt.allocPrint(allocator, "SecondCompile:{s}", .{@errorName(err)});
            errdefer allocator.free(reason);
            try compiled_failed.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .reason = reason,
            });
            continue;
        };
        defer second.deinit();

        try compiled_ok.append(allocator, try allocator.dupe(u8, name));

        const first_zig = emitZigModuleAlloc(allocator, &first) catch |err| {
            const reason = try std.fmt.allocPrint(allocator, "FirstEmit:{s}", .{@errorName(err)});
            errdefer allocator.free(reason);
            try compiled_failed.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .reason = reason,
            });
            continue;
        };
        defer allocator.free(first_zig);

        const second_zig = emitZigModuleAlloc(allocator, &second) catch |err| {
            const reason = try std.fmt.allocPrint(allocator, "SecondEmit:{s}", .{@errorName(err)});
            errdefer allocator.free(reason);
            try compiled_failed.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .reason = reason,
            });
            continue;
        };
        defer allocator.free(second_zig);

        if (!std.mem.eql(u8, first_zig, second_zig)) {
            try appendFailureAlloc(allocator, &emitted_inconsistent, name, "ZigEmissionMismatch");
            continue;
        }

        try emitted_consistent.append(allocator, try allocator.dupe(u8, name));
    }

    return .{
        .missing_modules = try missing_modules.toOwnedSlice(allocator),
        .compiled_ok = try compiled_ok.toOwnedSlice(allocator),
        .compiled_failed = try compiled_failed.toOwnedSlice(allocator),
        .emitted_consistent = try emitted_consistent.toOwnedSlice(allocator),
        .emitted_inconsistent = try emitted_inconsistent.toOwnedSlice(allocator),
    };
}

pub fn collectTransitiveModulesFromSourcesAlloc(
    allocator: std.mem.Allocator,
    module_sources: *const std.StringHashMap([]const u8),
    direct_modules: []const []const u8,
) ![]const []const u8 {
    var transitive = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &transitive);
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(allocator);

    for (direct_modules) |name| {
        const gop = try transitive.getOrPut(allocator, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try allocator.dupe(u8, name);
            try stack.append(allocator, gop.key_ptr.*);
        }
    }

    while (stack.pop()) |name| {
        const source = module_sources.get(name) orelse continue;
        const deps = try extractModuleDependencies(allocator, source);
        defer freeStringSlice(allocator, deps);
        for (deps) |dep| {
            const gop = try transitive.getOrPut(allocator, dep);
            if (!gop.found_existing) {
                gop.key_ptr.* = try allocator.dupe(u8, dep);
                try stack.append(allocator, gop.key_ptr.*);
            }
        }
    }

    return collectStringSet(allocator, &transitive);
}

fn mergeUniqueStringSlicesAlloc(
    allocator: std.mem.Allocator,
    groups: []const []const []const u8,
) ![]const []const u8 {
    var set = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &set);

    for (groups) |group| {
        for (group) |value| {
            const gop = try set.getOrPut(allocator, value);
            if (!gop.found_existing) gop.key_ptr.* = try allocator.dupe(u8, value);
        }
    }

    return collectStringSet(allocator, &set);
}

fn appendFailureAlloc(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(ModuleCompileFailure),
    name: []const u8,
    reason: []const u8,
) !void {
    try list.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .reason = try allocator.dupe(u8, reason),
    });
}

fn freeOwnedStringList(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |value| allocator.free(value);
    list.deinit(allocator);
}

fn freeFailureList(allocator: std.mem.Allocator, list: *std.ArrayList(ModuleCompileFailure)) void {
    for (list.items) |failure| {
        allocator.free(failure.name);
        allocator.free(failure.reason);
    }
    list.deinit(allocator);
}

fn dupStringSliceAlloc(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, values.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |value| allocator.free(value);
        allocator.free(out);
    }
    for (values, 0..) |value, idx| {
        out[idx] = try allocator.dupe(u8, value);
        filled = idx + 1;
    }
    return out;
}

fn dupFailureSliceAlloc(allocator: std.mem.Allocator, failures: []const ModuleCompileFailure) ![]const ModuleCompileFailure {
    const out = try allocator.alloc(ModuleCompileFailure, failures.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |failure| {
            allocator.free(failure.name);
            allocator.free(failure.reason);
        }
        allocator.free(out);
    }
    for (failures, 0..) |failure, idx| {
        out[idx] = .{
            .name = try allocator.dupe(u8, failure.name),
            .reason = try allocator.dupe(u8, failure.reason),
        };
        filled = idx + 1;
    }
    return out;
}

fn loadStaticConstTableAlloc(allocator: std.mem.Allocator, seed: *const ConstTableSeed) std.mem.Allocator.Error!*Table {
    const table = try Table.init(allocator);
    try table.array.ensureTotalCapacity(allocator, seed.array.len);
    for (seed.array) |value| table.array.appendAssumeCapacity(try staticConstValueToValueAlloc(allocator, value));
    for (seed.string_fields) |field| try table.putString(field.key, try staticConstValueToValueAlloc(allocator, field.value));
    for (seed.int_fields) |field| try table.int_fields.put(allocator, field.key, try staticConstValueToValueAlloc(allocator, field.value));
    return table;
}

fn staticConstValueToValueAlloc(allocator: std.mem.Allocator, seed: ConstValueSeed) std.mem.Allocator.Error!Value {
    return switch (seed) {
        .nil => .nil,
        .boolean => |value| .{ .boolean = value },
        .number => |value| .{ .number = value },
        .string => |value| .{ .string = try allocator.dupe(u8, value) },
        .table => |table| .{ .table = try loadStaticConstTableAlloc(allocator, table) },
    };
}

const DumpDependencyScan = struct {
    direct_modules: []const []const u8,
    module_sources: std.StringHashMap([]const u8),

    fn deinit(self: *DumpDependencyScan, allocator: std.mem.Allocator) void {
        freeStringSlice(allocator, self.direct_modules);
        var it = self.module_sources.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.module_sources.deinit();
    }
};

// Shared structure loading goes through the single parser in
// `shared/structure_report.zig` so tooling does not drift into ad hoc JSON
// parsing when the report schema changes.
fn loadStructureDependencySetAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
) !structure_report.DependencySet {
    return structure_report.loadDependencySetAlloc(std.Options.debug_io, allocator, path);
}

fn loadStructureTemplateNames(allocator: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    var deps = try loadStructureDependencySetAlloc(allocator, path);
    defer deps.deinit(allocator);

    if (deps.root_templates.len != 0) {
        return try dupStringSliceAlloc(allocator, deps.root_templates);
    }

    var mappings = try structure_report.loadTemplateMappingsAlloc(std.Options.debug_io, allocator, path);
    defer mappings.deinit(allocator);

    const total = mappings.line_templates.len + mappings.translation_templates.len;
    const out = try allocator.alloc([]const u8, total);
    var idx: usize = 0;
    for (mappings.line_templates) |entry| {
        out[idx] = try allocator.dupe(u8, entry.name);
        idx += 1;
    }
    for (mappings.translation_templates) |entry| {
        out[idx] = try allocator.dupe(u8, entry.name);
        idx += 1;
    }
    return out;
}

fn dupSourcePageRefsAlloc(
    allocator: std.mem.Allocator,
    refs: []const structure_report.SourcePageRef,
) ![]const SourcePageRef {
    const out = try allocator.alloc(SourcePageRef, refs.len);
    errdefer {
        for (out[0..refs.len]) |entry| {
            if (entry.name.len != 0) allocator.free(entry.name);
        }
        allocator.free(out);
    }
    for (refs, 0..) |ref, idx| {
        out[idx] = .{
            .name = try allocator.dupe(u8, ref.name),
            .page_start = ref.page_start,
            .page_end = ref.page_end,
        };
    }
    return out;
}

fn freeSourcePageRefs(allocator: std.mem.Allocator, refs: []const SourcePageRef) void {
    for (refs) |ref| allocator.free(ref.name);
    allocator.free(refs);
}

fn scanDirectInvokeModules(allocator: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    return try scanModulesWithNamespaces(allocator, path, true);
}

fn scanDumpDependenciesAlloc(allocator: std.mem.Allocator, path: []const u8) !DumpDependencyScan {
    var invoke_set = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &invoke_set);

    var module_sources = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = module_sources.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        module_sources.deinit();
    }

    var mapped = try mmapReadOnlyPath(path);
    defer mapped.deinit();

    var current_title: ?[]u8 = null;
    defer if (current_title) |title| allocator.free(title);
    var current_ns: enum { other, ns0, module } = .other;
    var capture_text = false;
    var text_accum = std.ArrayList(u8).empty;
    defer text_accum.deinit(allocator);
    var pages_seen: usize = 0;
    var last_progress_pages: usize = 0;
    var cursor: usize = 0;

    while (nextMappedLine(mapped.mapping, &cursor)) |line| {
        if (std.mem.indexOf(u8, line, "<page>") != null) {
            pages_seen += 1;
            if (pages_seen - last_progress_pages >= 250_000) {
                last_progress_pages = pages_seen;
                std.debug.print(
                    "lua deps scan: pages={d} direct_modules={d} module_sources={d}\n",
                    .{ pages_seen, invoke_set.count(), module_sources.count() },
                );
            }
        }
        if (extractTagText(line, "title")) |title| {
            if (current_title) |old| allocator.free(old);
            current_title = try allocator.dupe(u8, title);
        }
        if (extractTagText(line, "ns")) |ns| {
            current_ns = if (std.mem.eql(u8, ns, "0"))
                .ns0
            else if (std.mem.eql(u8, ns, "828"))
                .module
            else
                .other;
        }

        if (current_ns == .ns0) try addInvokeMatches(allocator, &invoke_set, line);

        if (std.mem.indexOf(u8, line, "<text")) |_| {
            capture_text = true;
            text_accum.clearRetainingCapacity();
            if (std.mem.indexOf(u8, line, ">")) |start_tag_end| {
                const rest = line[start_tag_end + 1 ..];
                if (current_ns == .ns0) try addInvokeMatches(allocator, &invoke_set, rest);
                if (std.mem.indexOf(u8, rest, "</text>")) |end_idx| {
                    try text_accum.appendSlice(allocator, rest[0..end_idx]);
                    capture_text = false;
                    if (current_ns == .module) try maybeStoreModuleSource(allocator, &module_sources, current_title, "828", text_accum.items);
                } else {
                    try text_accum.appendSlice(allocator, rest);
                    try text_accum.append(allocator, '\n');
                }
            }
            continue;
        }

        if (capture_text) {
            if (current_ns == .ns0) try addInvokeMatches(allocator, &invoke_set, line);
            if (std.mem.indexOf(u8, line, "</text>")) |end_idx| {
                try text_accum.appendSlice(allocator, line[0..end_idx]);
                capture_text = false;
                if (current_ns == .module) try maybeStoreModuleSource(allocator, &module_sources, current_title, "828", text_accum.items);
            } else {
                try text_accum.appendSlice(allocator, line);
                try text_accum.append(allocator, '\n');
            }
        }
    }

    return .{
        .direct_modules = try collectStringSet(allocator, &invoke_set),
        .module_sources = module_sources,
    };
}

pub fn scanTemplateAndModuleSourcesAlloc(allocator: std.mem.Allocator, path: []const u8) !TemplateSources {
    return try scanTemplateAndModuleSourcesFilteredAlloc(allocator, path, null, null);
}

pub fn scanSelectedTemplateAndModuleSourcesAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    template_names: []const []const u8,
    module_names: []const []const u8,
) !TemplateSources {
    if (template_names.len == 0 and module_names.len == 0) {
        return .{
            .template_sources = std.StringHashMap([]const u8).init(allocator),
            .module_sources = std.StringHashMap([]const u8).init(allocator),
        };
    }

    var wanted_templates = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &wanted_templates);
    for (template_names) |name| {
        if (!isLikelyTemplatePageName(name)) continue;
        try insertCanonicalTemplateName(&wanted_templates, allocator, name);
    }

    var wanted_modules = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &wanted_modules);
    for (module_names) |name| {
        if (!isLikelyModulePageName(name)) continue;
        try insertCanonicalModuleName(&wanted_modules, allocator, name);
    }

    return try scanTemplateAndModuleSourcesFilteredAlloc(
        allocator,
        path,
        &wanted_templates,
        &wanted_modules,
    );
}

fn loadTemplateOrModuleSourceRefAlloc(
    allocator: std.mem.Allocator,
    mapped: []const u8,
    map: *std.StringHashMap([]const u8),
    ref: SourcePageRef,
    expected_ns: []const u8,
) !void {
    const start = std.math.cast(usize, ref.page_start) orelse return error.FileTooBig;
    const end = std.math.cast(usize, ref.page_end) orelse return error.FileTooBig;
    if (start >= end or end > mapped.len) return error.InvalidDictionaryFile;

    const page_fragment = mapped[start..end];
    const ns = extractPageTagText(page_fragment, "ns") orelse return error.InvalidDictionaryFile;
    if (!std.mem.eql(u8, std.mem.trim(u8, ns, " \t\r\n"), expected_ns)) return error.InvalidDictionaryFile;

    const text_raw = extractPageText(page_fragment) orelse return error.InvalidDictionaryFile;
    const decoded = try xml_decode.decodeSinglePassAlloc(allocator, text_raw);
    errdefer allocator.free(decoded);

    if (std.mem.eql(u8, expected_ns, "10")) {
        try putCanonicalTemplateSource(allocator, map, ref.name, decoded);
    } else {
        try putCanonicalModuleSource(allocator, map, ref.name, decoded);
    }
}

pub fn loadSelectedTemplateAndModuleSourcesByRefsAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    template_refs: []const SourcePageRef,
    module_refs: []const SourcePageRef,
) !TemplateSources {
    var template_sources = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = template_sources.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        template_sources.deinit();
    }

    var module_sources = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = module_sources.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        module_sources.deinit();
    }

    var mapped = try mmapReadOnlyPath(path);
    defer mapped.deinit();

    for (template_refs) |ref| {
        try loadTemplateOrModuleSourceRefAlloc(allocator, mapped.mapping, &template_sources, ref, "10");
    }
    for (module_refs) |ref| {
        try loadTemplateOrModuleSourceRefAlloc(allocator, mapped.mapping, &module_sources, ref, "828");
    }

    try applySourceCompat(allocator, &template_sources, &module_sources);

    return .{
        .template_sources = template_sources,
        .module_sources = module_sources,
    };
}

fn scanTemplateAndModuleSourcesFilteredAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    wanted_templates: ?*const std.StringHashMapUnmanaged(void),
    wanted_modules: ?*const std.StringHashMapUnmanaged(void),
) !TemplateSources {
    var template_sources = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = template_sources.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        template_sources.deinit();
    }

    var module_sources = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = module_sources.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        module_sources.deinit();
    }

    var mapped = try mmapReadOnlyPath(path);
    defer mapped.deinit();

    var current_title: ?[]u8 = null;
    defer if (current_title) |title| allocator.free(title);
    var current_ns: ?[]u8 = null;
    defer if (current_ns) |ns| allocator.free(ns);
    var capture_text = false;
    var text_accum = std.ArrayList(u8).empty;
    defer text_accum.deinit(allocator);
    var pages_seen: usize = 0;
    var last_progress_pages: usize = 0;
    var cursor: usize = 0;

    while (nextMappedLine(mapped.mapping, &cursor)) |line| {
        if (std.mem.indexOf(u8, line, "<page>") != null) {
            pages_seen += 1;
            if (pages_seen - last_progress_pages >= 250_000) {
                last_progress_pages = pages_seen;
                std.debug.print(
                    "lua template scan: pages={d} templates={d} modules={d}\n",
                    .{ pages_seen, template_sources.count(), module_sources.count() },
                );
            }
        }
        if (extractTagText(line, "title")) |title| {
            if (current_title) |old| allocator.free(old);
            current_title = try allocator.dupe(u8, title);
        }
        if (extractTagText(line, "ns")) |ns| {
            if (current_ns) |old| allocator.free(old);
            current_ns = try allocator.dupe(u8, ns);
        }
        if (std.mem.indexOf(u8, line, "<text")) |_| {
            capture_text = true;
            text_accum.clearRetainingCapacity();
            if (std.mem.indexOf(u8, line, ">")) |start_tag_end| {
                const rest = line[start_tag_end + 1 ..];
                if (std.mem.indexOf(u8, rest, "</text>")) |end_idx| {
                    try text_accum.appendSlice(allocator, rest[0..end_idx]);
                    capture_text = false;
                    try maybeStoreLuaSourceFiltered(
                        allocator,
                        &template_sources,
                        &module_sources,
                        current_title,
                        current_ns,
                        text_accum.items,
                        wanted_templates,
                        wanted_modules,
                    );
                    if (scanTemplateSourceTargetsSatisfied(&template_sources, &module_sources, wanted_templates, wanted_modules)) break;
                } else {
                    try text_accum.appendSlice(allocator, rest);
                    try text_accum.append(allocator, '\n');
                }
            }
        } else if (capture_text) {
            if (std.mem.indexOf(u8, line, "</text>")) |end_idx| {
                try text_accum.appendSlice(allocator, line[0..end_idx]);
                capture_text = false;
                try maybeStoreLuaSourceFiltered(
                    allocator,
                    &template_sources,
                    &module_sources,
                    current_title,
                    current_ns,
                    text_accum.items,
                    wanted_templates,
                    wanted_modules,
                );
                if (scanTemplateSourceTargetsSatisfied(&template_sources, &module_sources, wanted_templates, wanted_modules)) break;
            } else {
                try text_accum.appendSlice(allocator, line);
                try text_accum.append(allocator, '\n');
            }
        }
    }
    try applySourceCompat(allocator, &template_sources, &module_sources);
    return .{
        .template_sources = template_sources,
        .module_sources = module_sources,
    };
}

fn scanTemplateSourceTargetsSatisfied(
    template_sources: *const std.StringHashMap([]const u8),
    module_sources: *const std.StringHashMap([]const u8),
    wanted_templates: ?*const std.StringHashMapUnmanaged(void),
    wanted_modules: ?*const std.StringHashMapUnmanaged(void),
) bool {
    const templates_done = if (wanted_templates) |wanted| template_sources.count() >= wanted.count() else true;
    const modules_done = if (wanted_modules) |wanted| module_sources.count() >= wanted.count() else true;
    return templates_done and modules_done;
}

fn applySourceCompat(
    allocator: std.mem.Allocator,
    template_sources: *std.StringHashMap([]const u8),
    module_sources: *std.StringHashMap([]const u8),
) !void {
    // MediaWiki uses Template:! as the escaped pipe primitive inside template
    // arguments. The dump often omits it from the dependency surface, but many
    // high-traffic templates still rely on it transitively.
    try ensureTemplateCompatSource(allocator, template_sources, "!", &.{}, "|");
    try ensureTemplateCompatSource(allocator, template_sources, "an-lite", &.{"an-lite/node"}, "{{{1|}}}");
    try ensureTemplateCompatSource(allocator, template_sources, "check deprecated lang param usage", &.{}, "{{{1|}}}");
    try ensureTemplateCompatSource(allocator, template_sources, "no deprecated lang param usage", &.{}, "{{{1|}}}");
    try ensureModuleCompatSource(allocator, module_sources, "gender and number/templates", &.{"gender and number"},
        \\local export = {}
        \\function export.format_one(frame)
        \\    local args = frame.args
        \\    local first = args[1]
        \\    if first == nil then
        \\        return ""
        \\    end
        \\    return first
        \\end
        \\return export
    );
    try ensureModuleCompatSource(allocator, module_sources, "libraryutil", &.{},
        \\local export = {}
        \\function export.checkType(_, _, value, _, _)
        \\    return value
        \\end
        \\function export.checkTypeForNamedArg(_, _, value, _, _)
        \\    return value
        \\end
        \\function export.checkTypeMulti(_, _, value, _, _)
        \\    return value
        \\end
        \\function export.makeCheckSelfFunction(...)
        \\    return function(...)
        \\        return ...
        \\    end
        \\end
        \\return export
    );
    try ensureModuleCompatSource(allocator, module_sources, "strict", &.{},
        \\return {}
    );
    try ensureModuleCompatSource(allocator, module_sources, "chart/default colors", &.{},
        \\return {}
    );
    try ensureModuleCompatSource(allocator, module_sources, "labels/data", &.{},
        \\return {}
    );
    try ensureModuleCompatSource(allocator, module_sources, "ml-translit", &.{},
        \\local export = {}
        \\function export.tr(text)
        \\    return text or ""
        \\end
        \\function export.translit(text)
        \\    return text or ""
        \\end
        \\return export
    );
    try ensureModuleCompatSource(allocator, module_sources, "pa-translit", &.{},
        \\local export = {}
        \\function export.tr(text)
        \\    return text or ""
        \\end
        \\function export.translit(text)
        \\    return text or ""
        \\end
        \\return export
    );
}

fn ensureTemplateCompatSource(
    allocator: std.mem.Allocator,
    template_sources: *std.StringHashMap([]const u8),
    target: []const u8,
    alias_candidates: []const []const u8,
    fallback_source: []const u8,
) !void {
    if (template_sources.contains(target)) return;
    for (alias_candidates) |alias| {
        const source = template_sources.get(alias) orelse continue;
        try template_sources.put(try allocator.dupe(u8, target), try allocator.dupe(u8, source));
        return;
    }
    try template_sources.put(try allocator.dupe(u8, target), try allocator.dupe(u8, fallback_source));
}

fn ensureModuleCompatSource(
    allocator: std.mem.Allocator,
    module_sources: *std.StringHashMap([]const u8),
    target: []const u8,
    alias_candidates: []const []const u8,
    fallback_source: []const u8,
) !void {
    if (module_sources.contains(target)) return;
    for (alias_candidates) |alias| {
        const source = module_sources.get(alias) orelse continue;
        try module_sources.put(try allocator.dupe(u8, target), try allocator.dupe(u8, source));
        return;
    }
    try module_sources.put(try allocator.dupe(u8, target), try allocator.dupe(u8, fallback_source));
}

fn maybeStoreLuaSource(
    allocator: std.mem.Allocator,
    template_sources: *std.StringHashMap([]const u8),
    module_sources: *std.StringHashMap([]const u8),
    current_title: ?[]u8,
    current_ns: ?[]const u8,
    text: []const u8,
) !void {
    return try maybeStoreLuaSourceFiltered(
        allocator,
        template_sources,
        module_sources,
        current_title,
        current_ns,
        text,
        null,
        null,
    );
}

fn maybeStoreLuaSourceFiltered(
    allocator: std.mem.Allocator,
    template_sources: *std.StringHashMap([]const u8),
    module_sources: *std.StringHashMap([]const u8),
    current_title: ?[]u8,
    current_ns: ?[]const u8,
    text: []const u8,
    wanted_templates: ?*const std.StringHashMapUnmanaged(void),
    wanted_modules: ?*const std.StringHashMapUnmanaged(void),
) !void {
    if (current_title == null or current_ns == null) return;

    if (std.mem.eql(u8, current_ns.?, "10")) {
        if (!std.mem.startsWith(u8, current_title.?, "Template:")) return;
        const name = current_title.?["Template:".len..];
        const canonical = try canonicalTemplateNameAlloc(allocator, name);
        defer allocator.free(canonical);
        if (wanted_templates) |wanted| {
            if (!wanted.contains(canonical)) return;
        }
        const decoded = try xml_decode.decodeSinglePassAlloc(allocator, text);
        try putCanonicalTemplateSource(allocator, template_sources, canonical, decoded);
        return;
    }

    if (!std.mem.eql(u8, current_ns.?, "828")) return;
    if (!std.mem.startsWith(u8, current_title.?, "Module:")) return;
    const name = current_title.?["Module:".len..];
    const canonical = try canonicalModuleNameAlloc(allocator, name);
    defer allocator.free(canonical);
    if (wanted_modules) |wanted| {
        if (!wanted.contains(canonical)) return;
    }
    const decoded = try xml_decode.decodeSinglePassAlloc(allocator, text);
    try putCanonicalModuleSource(allocator, module_sources, canonical, decoded);
}

fn putCanonicalTemplateSource(
    allocator: std.mem.Allocator,
    map: *std.StringHashMap([]const u8),
    name: []const u8,
    decoded: []const u8,
) !void {
    const canonical = try canonicalTemplateNameAlloc(allocator, name);
    errdefer allocator.free(canonical);

    const gop = try map.getOrPut(canonical);
    if (gop.found_existing) {
        allocator.free(canonical);
        allocator.free(decoded);
        return;
    }
    gop.key_ptr.* = canonical;
    gop.value_ptr.* = decoded;
}

fn maybeStoreModuleSource(
    allocator: std.mem.Allocator,
    map: *std.StringHashMap([]const u8),
    current_title: ?[]u8,
    current_ns: ?[]const u8,
    text: []const u8,
) !void {
    if (current_title == null or current_ns == null) return;
    if (!std.mem.eql(u8, current_ns.?, "828")) return;
    if (!std.mem.startsWith(u8, current_title.?, "Module:")) return;
    const name = current_title.?["Module:".len..];
    const decoded = try xml_decode.decodeSinglePassAlloc(allocator, text);
    try putCanonicalModuleSource(allocator, map, name, decoded);
}

fn putCanonicalModuleSource(
    allocator: std.mem.Allocator,
    map: *std.StringHashMap([]const u8),
    name: []const u8,
    decoded: []const u8,
) !void {
    const canonical = try canonicalModuleNameAlloc(allocator, name);
    errdefer allocator.free(canonical);

    const gop = try map.getOrPut(canonical);
    if (gop.found_existing) {
        allocator.free(canonical);
        allocator.free(decoded);
        return;
    }
    gop.key_ptr.* = canonical;
    gop.value_ptr.* = decoded;
}

fn scanModulesWithNamespaces(allocator: std.mem.Allocator, path: []const u8, only_ns0: bool) ![]const []const u8 {
    var set = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &set);

    var mapped = try mmapReadOnlyPath(path);
    defer mapped.deinit();
    var current_ns: ?[]u8 = null;
    defer if (current_ns) |ns| allocator.free(ns);
    var cursor: usize = 0;

    while (nextMappedLine(mapped.mapping, &cursor)) |line| {
        if (extractTagText(line, "ns")) |ns| {
            if (current_ns) |old| allocator.free(old);
            current_ns = try allocator.dupe(u8, ns);
        }
        if (!only_ns0 or (current_ns != null and std.mem.eql(u8, current_ns.?, "0"))) {
            try addInvokeMatches(allocator, &set, line);
        }
    }
    return collectStringSet(allocator, &set);
}

fn extractTagText(line: []const u8, tag: []const u8) ?[]const u8 {
    var start_buf: [32]u8 = undefined;
    var end_buf: [32]u8 = undefined;
    const start = std.fmt.bufPrint(&start_buf, "<{s}>", .{tag}) catch return null;
    const end = std.fmt.bufPrint(&end_buf, "</{s}>", .{tag}) catch return null;
    const start_idx = std.mem.indexOf(u8, line, start) orelse return null;
    const after_start = start_idx + start.len;
    const end_idx = std.mem.indexOfPos(u8, line, after_start, end) orelse return null;
    return line[after_start..end_idx];
}

fn extractPageTagText(page: []const u8, tag: []const u8) ?[]const u8 {
    var start_buf: [32]u8 = undefined;
    var end_buf: [32]u8 = undefined;
    const start = std.fmt.bufPrint(&start_buf, "<{s}>", .{tag}) catch return null;
    const end = std.fmt.bufPrint(&end_buf, "</{s}>", .{tag}) catch return null;
    const start_idx = std.mem.indexOf(u8, page, start) orelse return null;
    const after_start = start_idx + start.len;
    const end_idx = std.mem.indexOfPos(u8, page, after_start, end) orelse return null;
    return page[after_start..end_idx];
}

fn extractPageText(page: []const u8) ?[]const u8 {
    const text_tag_start = std.mem.indexOf(u8, page, "<text") orelse return null;
    const content_start_rel = std.mem.indexOfScalarPos(u8, page, text_tag_start, '>') orelse return null;
    const content_start = content_start_rel + 1;
    const content_end = std.mem.indexOfPos(u8, page, content_start, "</text>") orelse return null;
    return page[content_start..content_end];
}

fn nextMappedLine(mapped: []const u8, cursor: *usize) ?[]const u8 {
    if (cursor.* >= mapped.len) return null;
    const start = cursor.*;
    const end = std.mem.indexOfScalarPos(u8, mapped, start, '\n') orelse mapped.len;
    cursor.* = if (end < mapped.len) end + 1 else end;
    return std.mem.trim(u8, mapped[start..end], "\r");
}

fn addInvokeMatches(allocator: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void), line: []const u8) !void {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, line, cursor, "{{#invoke:")) |start| {
        var name_start = start + "{{#invoke:".len;
        while (name_start < line.len and std.ascii.isWhitespace(line[name_start])) : (name_start += 1) {}
        var name_end = name_start;
        while (name_end < line.len and line[name_end] != '|' and line[name_end] != '}' and line[name_end] != '\n') : (name_end += 1) {}
        const name = std.mem.trim(u8, line[name_start..name_end], " \t");
        if (isLikelyCodeModulePageName(name)) try insertCanonicalModuleName(set, allocator, name);
        cursor = name_end;
    }
}

pub fn extractInvokeModulesAlloc(allocator: std.mem.Allocator, source: []const u8) ![]const []const u8 {
    var set = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &set);
    try addInvokeMatches(allocator, &set, source);
    return collectStringSet(allocator, &set);
}

pub fn extractTemplateDependenciesAlloc(
    allocator: std.mem.Allocator,
    source: []const u8,
    current_template_name: ?[]const u8,
) ![]const []const u8 {
    const filtered = try filterTemplateDependencySourceAlloc(allocator, source);
    defer allocator.free(filtered);

    var set = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &set);

    var i: usize = 0;
    while (i + 2 <= filtered.len) : (i += 1) {
        if (!std.mem.eql(u8, filtered[i .. i + 2], "{{")) continue;
        if ((i > 0 and filtered[i - 1] == '{') or (i + 3 <= filtered.len and filtered[i + 2] == '{')) continue;

        var name_start = i + 2;
        while (name_start < filtered.len and std.ascii.isWhitespace(filtered[name_start])) : (name_start += 1) {}
        var name_end = name_start;
        while (name_end < filtered.len) : (name_end += 1) {
            const byte = filtered[name_end];
            if (byte == '|' or byte == '}' or byte == '\n' or byte == '\r') break;
        }
        if (name_end <= name_start) continue;

        var raw_name = std.mem.trim(u8, filtered[name_start..name_end], " \t");
        raw_name = stripSubstPrefix(raw_name);
        if (raw_name.len == 0) continue;
        if (raw_name[0] == '#') continue;
        if (isIgnoredTemplateMagicName(raw_name)) continue;

        const resolved_name = try resolveTemplateDependencyNameAlloc(allocator, current_template_name, raw_name);
        defer if (resolved_name.owned) allocator.free(resolved_name.name);
        if (resolved_name.name.len == 0) continue;
        if (isIgnoredTemplateMagicName(resolved_name.name)) continue;
        if (!isLikelyTemplatePageName(resolved_name.name)) continue;

        try insertCanonicalTemplateName(&set, allocator, resolved_name.name);
        i = name_end;
    }

    return collectStringSet(allocator, &set);
}

fn collectKnownModuleNamesFromValues(
    set: *std.StringHashMapUnmanaged(void),
    allocator: std.mem.Allocator,
    values: KnownStringValues,
) !void {
    for (values.slice()) |name| {
        if (isLikelyCodeModulePageName(name)) try insertCanonicalModuleName(set, allocator, name);
    }
}

fn collectModuleDependencyLValueExprsAst(
    ctx: *DirectEmitFunctionContext,
    set: *std.StringHashMapUnmanaged(void),
    target: LValue,
) anyerror!void {
    switch (target) {
        .name => {},
        .field => |field| try collectModuleDependenciesFromExprAst(ctx, set, field.object),
        .index => |index| {
            try collectModuleDependenciesFromExprAst(ctx, set, index.object);
            try collectModuleDependenciesFromExprAst(ctx, set, index.key);
        },
    }
}

fn collectModuleDependenciesFromExprAst(
    ctx: *DirectEmitFunctionContext,
    set: *std.StringHashMapUnmanaged(void),
    expr: *const Expr,
) anyerror!void {
    if (expr.* == .call) {
        const call = expr.call;
        if (knownInvokeLoweringForExpr(ctx, call.callee)) |lowering| switch (lowering) {
            .module_dispatch, .helper_dispatch => {
                if (call.args.len != 0) {
                    if (knownStringValuesForExpr(ctx, call.args[0])) |values| {
                        try collectKnownModuleNamesFromValues(set, ctx.state.allocator, values);
                    }
                }
            },
            .module_export => |module_export| try collectKnownModuleNamesFromValues(set, ctx.state.allocator, module_export.module_values),
        };
    }

    switch (expr.*) {
        .nil_lit, .bool_lit, .number_lit, .string_lit, .variable, .varargs, .const_table => {},
        .unary => |op| try collectModuleDependenciesFromExprAst(ctx, set, op.expr),
        .binary => |op| {
            try collectModuleDependenciesFromExprAst(ctx, set, op.lhs);
            try collectModuleDependenciesFromExprAst(ctx, set, op.rhs);
        },
        .table_ctor => |fields| {
            for (fields) |field| switch (field) {
                .array => |value| try collectModuleDependenciesFromExprAst(ctx, set, value),
                .named => |named| try collectModuleDependenciesFromExprAst(ctx, set, named.value),
                .indexed => |indexed| {
                    try collectModuleDependenciesFromExprAst(ctx, set, indexed.key);
                    try collectModuleDependenciesFromExprAst(ctx, set, indexed.value);
                },
            };
        },
        .field => |field| try collectModuleDependenciesFromExprAst(ctx, set, field.object),
        .index => |index| {
            try collectModuleDependenciesFromExprAst(ctx, set, index.object);
            try collectModuleDependenciesFromExprAst(ctx, set, index.key);
        },
        .call => |call| {
            try collectModuleDependenciesFromExprAst(ctx, set, call.callee);
            for (call.args) |arg| try collectModuleDependenciesFromExprAst(ctx, set, arg);
        },
        .function_lit => {
            const child_id = ctx.state.exprFunctionId(expr) orelse return;
            var child = try initKnownFactChildContext(ctx, &ctx.state.functions.items[child_id]);
            defer child.deinit();
            try collectModuleDependenciesFromStmtSliceAst(&child, set, child.info.body);
        },
    }
}

fn collectModuleDependenciesFromStmtSliceAst(
    ctx: *DirectEmitFunctionContext,
    set: *std.StringHashMapUnmanaged(void),
    stmts: []const *Stmt,
) anyerror!void {
    for (stmts) |stmt| try collectModuleDependenciesFromStmtAst(ctx, set, stmt);
}

fn collectModuleDependenciesFromStmtAst(
    ctx: *DirectEmitFunctionContext,
    set: *std.StringHashMapUnmanaged(void),
    stmt: *const Stmt,
) anyerror!void {
    switch (stmt.*) {
        .local_assign => |op| {
            for (op.exprs) |expr| try collectModuleDependenciesFromExprAst(ctx, set, expr);

            const value_count = @max(op.names.len, op.exprs.len);
            const value_facts = try ctx.state.allocator.alloc(KnownValueFact, value_count);
            defer ctx.state.allocator.free(value_facts);

            for (0..value_count) |idx| {
                value_facts[idx] = if (idx < op.exprs.len)
                    knownValueFactForExpr(ctx, op.exprs[idx])
                else
                    .unknown;
            }

            for (op.names, 0..) |name, idx| {
                const local_id = try ctx.declareLocal(name);
                ctx.setLocalFact(local_id, value_facts[idx]);
            }
        },
        .assign => |op| {
            for (op.exprs) |expr| try collectModuleDependenciesFromExprAst(ctx, set, expr);

            const value_count = @max(op.targets.len, op.exprs.len);
            const value_facts = try ctx.state.allocator.alloc(KnownValueFact, value_count);
            defer ctx.state.allocator.free(value_facts);

            for (0..value_count) |idx| {
                value_facts[idx] = if (idx < op.exprs.len)
                    knownValueFactForExpr(ctx, op.exprs[idx])
                else
                    .unknown;
            }

            for (op.targets, 0..) |target, idx| {
                try collectModuleDependencyLValueExprsAst(ctx, set, target);
                applyKnownFactToTarget(ctx, target, value_facts[idx]);
            }
        },
        .function_def => |op| {
            const child_id = ctx.state.stmtFunctionId(stmt) orelse return;
            const child_info = &ctx.state.functions.items[child_id];
            const direct_fact = forwardedCallableFact(knownFunctionValueFact(ctx, child_info, 8));
            const fact: KnownValueFact = if (direct_fact != .unknown)
                direct_fact
            else
                .{ .direct_function_id = child_id };

            if (op.is_local and op.target == .name) {
                const local_id = try ctx.declareLocal(op.target.name);
                ctx.setLocalFact(local_id, fact);
            } else {
                try collectModuleDependencyLValueExprsAst(ctx, set, op.target);
                applyKnownFactToTarget(ctx, op.target, fact);
            }

            var child = try initKnownFactChildContext(ctx, child_info);
            defer child.deinit();
            try collectModuleDependenciesFromStmtSliceAst(&child, set, child.info.body);
        },
        .if_stmt => |op| {
            for (op.branches) |branch| {
                try collectModuleDependenciesFromExprAst(ctx, set, branch.condition);
                var snapshot = try ctx.snapshotFactsAlloc();
                defer snapshot.deinit(ctx.state.allocator);
                try ctx.beginScope();
                try collectModuleDependenciesFromStmtSliceAst(ctx, set, branch.body);
                ctx.endScope();
                try ctx.restoreFacts(&snapshot);
            }
            var snapshot = try ctx.snapshotFactsAlloc();
            defer snapshot.deinit(ctx.state.allocator);
            try ctx.beginScope();
            try collectModuleDependenciesFromStmtSliceAst(ctx, set, op.else_body);
            ctx.endScope();
            try ctx.restoreFacts(&snapshot);
        },
        .do_block => |body| {
            var snapshot = try ctx.snapshotFactsAlloc();
            defer snapshot.deinit(ctx.state.allocator);
            try ctx.beginScope();
            try collectModuleDependenciesFromStmtSliceAst(ctx, set, body);
            ctx.endScope();
            try ctx.restoreFacts(&snapshot);
        },
        .while_stmt => |op| {
            try collectModuleDependenciesFromExprAst(ctx, set, op.condition);
            var snapshot = try ctx.snapshotFactsAlloc();
            defer snapshot.deinit(ctx.state.allocator);
            try ctx.beginScope();
            try collectModuleDependenciesFromStmtSliceAst(ctx, set, op.body);
            ctx.endScope();
            try ctx.restoreFacts(&snapshot);
        },
        .repeat_stmt => |op| {
            var snapshot = try ctx.snapshotFactsAlloc();
            defer snapshot.deinit(ctx.state.allocator);
            try ctx.beginScope();
            try collectModuleDependenciesFromStmtSliceAst(ctx, set, op.body);
            try collectModuleDependenciesFromExprAst(ctx, set, op.condition);
            ctx.endScope();
            try ctx.restoreFacts(&snapshot);
        },
        .numeric_for => |op| {
            try collectModuleDependenciesFromExprAst(ctx, set, op.start);
            try collectModuleDependenciesFromExprAst(ctx, set, op.finish);
            if (op.step) |step| try collectModuleDependenciesFromExprAst(ctx, set, step);
            var snapshot = try ctx.snapshotFactsAlloc();
            defer snapshot.deinit(ctx.state.allocator);
            try ctx.beginScope();
            _ = try ctx.declareLocal(op.name);
            try collectModuleDependenciesFromStmtSliceAst(ctx, set, op.body);
            ctx.endScope();
            try ctx.restoreFacts(&snapshot);
        },
        .generic_for => |op| {
            for (op.iterator_exprs) |expr| try collectModuleDependenciesFromExprAst(ctx, set, expr);
            var snapshot = try ctx.snapshotFactsAlloc();
            defer snapshot.deinit(ctx.state.allocator);
            try ctx.beginScope();
            for (op.names) |name| {
                const local_id = try ctx.declareLocal(name);
                ctx.setLocalFact(local_id, .unknown);
            }
            try collectModuleDependenciesFromStmtSliceAst(ctx, set, op.body);
            ctx.endScope();
            try ctx.restoreFacts(&snapshot);
        },
        .return_stmt => |op| for (op.exprs) |expr| try collectModuleDependenciesFromExprAst(ctx, set, expr),
        .expr_stmt => |expr| try collectModuleDependenciesFromExprAst(ctx, set, expr),
        .break_stmt => {},
    }
}

fn extractModuleDependenciesFromAstInto(
    allocator: std.mem.Allocator,
    set: *std.StringHashMapUnmanaged(void),
    source: []const u8,
) !void {
    var chunk = compileQuiet(allocator, source) catch return;
    defer chunk.deinit();

    var state = DirectModuleState.init(allocator, .{
        .enable_direct_module_dispatch = true,
        .direct_module_dispatch_names = &.{},
    });
    defer state.deinit();
    try analyzeDirectModule(&state, chunk.body);
    if (state.functions.items.len == 0) return;

    var ctx = DirectEmitFunctionContext.init(
        &state,
        &state.functions.items[0],
        false,
        &.{},
        &.{},
        &.{},
        &.{},
    );
    defer ctx.deinit();
    try collectModuleDependenciesFromStmtSliceAst(&ctx, set, state.functions.items[0].body);
}

fn extractModuleDependenciesWithLexInto(
    allocator: std.mem.Allocator,
    set: *std.StringHashMapUnmanaged(void),
    source: []const u8,
) !void {
    const LexDispatchKind = enum {
        require,
        load_data,
    };
    const LexStringAlias = struct {
        name: []const u8,
        module_name: []const u8,
    };
    const LexDispatchAlias = struct {
        name: []const u8,
        kind: LexDispatchKind,
    };
    const LexArgMatch = struct {
        module_name: []const u8,
        next_index: usize,
    };

    const tokens = lexQuiet(allocator, source) catch return;
    defer freeTokenSlice(allocator, tokens);

    var string_aliases: std.ArrayList(LexStringAlias) = .empty;
    defer string_aliases.deinit(allocator);
    var dispatch_aliases: std.ArrayList(LexDispatchAlias) = .empty;
    defer dispatch_aliases.deinit(allocator);

    const upsertStringAlias = struct {
        fn apply(aliases: *std.ArrayList(LexStringAlias), allocator_inner: std.mem.Allocator, name: []const u8, module_name: []const u8) !void {
            for (aliases.items) |*entry| {
                if (!std.mem.eql(u8, entry.name, name)) continue;
                entry.* = .{ .name = name, .module_name = module_name };
                return;
            }
            try aliases.append(allocator_inner, .{ .name = name, .module_name = module_name });
        }
    }.apply;
    const removeStringAlias = struct {
        fn apply(aliases: *std.ArrayList(LexStringAlias), name: []const u8) void {
            var write_index: usize = 0;
            for (aliases.items) |entry| {
                if (std.mem.eql(u8, entry.name, name)) continue;
                aliases.items[write_index] = entry;
                write_index += 1;
            }
            aliases.items.len = write_index;
        }
    }.apply;
    const lookupStringAlias = struct {
        fn apply(aliases: []const LexStringAlias, name: []const u8) ?[]const u8 {
            var idx = aliases.len;
            while (idx != 0) {
                idx -= 1;
                if (std.mem.eql(u8, aliases[idx].name, name)) return aliases[idx].module_name;
            }
            return null;
        }
    }.apply;
    const upsertDispatchAlias = struct {
        fn apply(aliases: *std.ArrayList(LexDispatchAlias), allocator_inner: std.mem.Allocator, name: []const u8, kind: LexDispatchKind) !void {
            for (aliases.items) |*entry| {
                if (!std.mem.eql(u8, entry.name, name)) continue;
                entry.* = .{ .name = name, .kind = kind };
                return;
            }
            try aliases.append(allocator_inner, .{ .name = name, .kind = kind });
        }
    }.apply;
    const removeDispatchAlias = struct {
        fn apply(aliases: *std.ArrayList(LexDispatchAlias), name: []const u8) void {
            var write_index: usize = 0;
            for (aliases.items) |entry| {
                if (std.mem.eql(u8, entry.name, name)) continue;
                aliases.items[write_index] = entry;
                write_index += 1;
            }
            aliases.items.len = write_index;
        }
    }.apply;
    const lookupDispatchAlias = struct {
        fn apply(aliases: []const LexDispatchAlias, name: []const u8) ?LexDispatchKind {
            var idx = aliases.len;
            while (idx != 0) {
                idx -= 1;
                if (std.mem.eql(u8, aliases[idx].name, name)) return aliases[idx].kind;
            }
            return null;
        }
    }.apply;
    const extractArgMatch = struct {
        fn apply(tokens_inner: []const Token, start: usize, aliases: []const LexStringAlias) ?LexArgMatch {
            if (start >= tokens_inner.len) return null;
            var idx = start;
            const has_parens = tokens_inner[idx].tag == .lparen;
            if (has_parens) idx += 1;
            if (idx >= tokens_inner.len) return null;

            const module_name = switch (tokens_inner[idx].tag) {
                .string => blk: {
                    const text = tokens_inner[idx].lexeme;
                    if (!isLikelyModulePageName(text)) return null;
                    break :blk text;
                },
                .identifier => lookupStringAlias(aliases, tokens_inner[idx].lexeme) orelse return null,
                else => return null,
            };
            idx += 1;
            if (has_parens) {
                if (idx >= tokens_inner.len or tokens_inner[idx].tag != .rparen) return null;
                idx += 1;
            }
            return .{ .module_name = module_name, .next_index = idx };
        }
    }.apply;

    try upsertDispatchAlias(&dispatch_aliases, allocator, "require", .require);

    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const token = tokens[i];

        if (token.tag == .kw_local and i + 3 < tokens.len and tokens[i + 1].tag == .identifier and tokens[i + 2].tag == .eq) {
            const name = tokens[i + 1].lexeme;
            const rhs = tokens[i + 3];
            if (rhs.tag == .string) {
                const text = rhs.lexeme;
                if (isLikelyModulePageName(text)) {
                    try upsertStringAlias(&string_aliases, allocator, name, text);
                } else {
                    removeStringAlias(&string_aliases, name);
                }
            } else if (rhs.tag == .identifier) {
                if (extractArgMatch(tokens, i + 4, string_aliases.items)) |arg_match| {
                    if (lookupDispatchAlias(dispatch_aliases.items, rhs.lexeme) == .require and
                        arg_match.next_index + 1 < tokens.len and
                        tokens[arg_match.next_index].tag == .dot and
                        tokens[arg_match.next_index + 1].tag == .identifier and
                        rawModuleNameMatchesCanonical(arg_match.module_name, "load"))
                    {
                        const field_name = tokens[arg_match.next_index + 1].lexeme;
                        if (std.mem.eql(u8, field_name, "load_data")) {
                            try upsertDispatchAlias(&dispatch_aliases, allocator, name, .load_data);
                        } else {
                            removeDispatchAlias(&dispatch_aliases, name);
                        }
                    } else {
                        removeDispatchAlias(&dispatch_aliases, name);
                    }
                } else if (lookupDispatchAlias(dispatch_aliases.items, rhs.lexeme)) |kind| {
                    try upsertDispatchAlias(&dispatch_aliases, allocator, name, kind);
                } else {
                    removeDispatchAlias(&dispatch_aliases, name);
                }
                removeStringAlias(&string_aliases, name);
            } else {
                removeDispatchAlias(&dispatch_aliases, name);
                removeStringAlias(&string_aliases, name);
            }
        }

        if (token.tag == .identifier and i + 2 < tokens.len and tokens[i + 1].tag == .eq) {
            const name = token.lexeme;
            const rhs = tokens[i + 2];
            if (rhs.tag == .string) {
                const text = rhs.lexeme;
                if (isLikelyModulePageName(text)) {
                    try upsertStringAlias(&string_aliases, allocator, name, text);
                } else {
                    removeStringAlias(&string_aliases, name);
                }
            } else if (rhs.tag == .identifier) {
                if (extractArgMatch(tokens, i + 3, string_aliases.items)) |arg_match| {
                    if (lookupDispatchAlias(dispatch_aliases.items, rhs.lexeme) == .require and
                        arg_match.next_index + 1 < tokens.len and
                        tokens[arg_match.next_index].tag == .dot and
                        tokens[arg_match.next_index + 1].tag == .identifier and
                        rawModuleNameMatchesCanonical(arg_match.module_name, "load"))
                    {
                        const field_name = tokens[arg_match.next_index + 1].lexeme;
                        if (std.mem.eql(u8, field_name, "load_data")) {
                            try upsertDispatchAlias(&dispatch_aliases, allocator, name, .load_data);
                        } else {
                            removeDispatchAlias(&dispatch_aliases, name);
                        }
                    } else {
                        removeDispatchAlias(&dispatch_aliases, name);
                    }
                    removeStringAlias(&string_aliases, name);
                } else if (lookupDispatchAlias(dispatch_aliases.items, rhs.lexeme)) |kind| {
                    try upsertDispatchAlias(&dispatch_aliases, allocator, name, kind);
                    removeStringAlias(&string_aliases, name);
                } else {
                    removeDispatchAlias(&dispatch_aliases, name);
                    removeStringAlias(&string_aliases, name);
                }
            } else {
                removeDispatchAlias(&dispatch_aliases, name);
                removeStringAlias(&string_aliases, name);
            }
        }

        if (token.tag == .identifier) {
            if (lookupDispatchAlias(dispatch_aliases.items, token.lexeme) == .require) {
                if (extractArgMatch(tokens, i + 1, string_aliases.items)) |arg_match| {
                    if (rawModuleNameMatchesCanonical(arg_match.module_name, "load") and
                        arg_match.next_index + 1 < tokens.len and
                        tokens[arg_match.next_index].tag == .dot and
                        tokens[arg_match.next_index + 1].tag == .identifier)
                    {
                        const field_name = tokens[arg_match.next_index + 1].lexeme;
                        if (std.mem.eql(u8, field_name, "load_data") or
                            std.mem.eql(u8, field_name, "safe_load_data") or
                            std.mem.eql(u8, field_name, "safe_require"))
                        {
                            if (extractArgMatch(tokens, arg_match.next_index + 2, string_aliases.items)) |nested_arg_match| {
                                if (isLikelyCodeModulePageName(nested_arg_match.module_name)) {
                                    try insertCanonicalModuleName(set, allocator, nested_arg_match.module_name);
                                }
                            }
                        }
                    }
                }
            }
            if (lookupDispatchAlias(dispatch_aliases.items, token.lexeme)) |kind| {
                if (extractArgMatch(tokens, i + 1, string_aliases.items)) |arg_match| {
                    switch (kind) {
                        .require, .load_data => if (isLikelyCodeModulePageName(arg_match.module_name)) {
                            try insertCanonicalModuleName(set, allocator, arg_match.module_name);
                        },
                    }
                }
            }
        }

        if (token.tag == .identifier and std.mem.eql(u8, token.lexeme, "require")) {
            if (extractModuleDependencyArg(tokens, i + 1)) |name| {
                if (isLikelyCodeModulePageName(name)) try insertCanonicalModuleName(set, allocator, name);
            }
            continue;
        }

        if (i + 3 >= tokens.len) continue;
        if (token.tag != .identifier or !std.mem.eql(u8, token.lexeme, "mw")) continue;
        if (tokens[i + 1].tag != .dot) continue;
        if (tokens[i + 2].tag != .identifier or !std.mem.eql(u8, tokens[i + 2].lexeme, "loadData")) continue;
        if (extractModuleDependencyArg(tokens, i + 3)) |name| {
            if (isLikelyCodeModulePageName(name)) try insertCanonicalModuleName(set, allocator, name);
        }
    }
}

pub fn extractModuleDependencies(allocator: std.mem.Allocator, source: []const u8) ![]const []const u8 {
    var set = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &set);

    // Structure building and dependency closure analysis touch every Module:
    // page in the dump, including documentation, CSS, redirects, and JSON.
    // Those pages cannot produce Lua module deps, so skip the expensive parser
    // path entirely instead of emitting noisy diagnostics for each one.
    switch (classifyModuleSource(source)) {
        .lua => {},
        .json, .non_lua, .empty => return collectStringSet(allocator, &set),
    }

    try extractModuleDependenciesFromAstInto(allocator, &set, source);
    try extractModuleDependenciesWithLexInto(allocator, &set, source);

    return collectStringSet(allocator, &set);
}

pub fn collectLikelyModuleStringLiteralsAlloc(
    allocator: std.mem.Allocator,
    source: []const u8,
) ![]const []const u8 {
    var set = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &set);

    const tokens = lexQuiet(allocator, source) catch return collectStringSet(allocator, &set);
    defer freeTokenSlice(allocator, tokens);

    for (tokens) |token| {
        if (token.tag != .string) continue;
        const raw_text = std.mem.trim(u8, token.lexeme, " \t\r\n");
        if (raw_text.len == 0) continue;
        const candidate = if (startsWithIgnoreCase(raw_text, "Module:"))
            raw_text["Module:".len..]
        else
            raw_text;
        if (!isLikelyCodeModulePageName(candidate)) continue;
        try insertCanonicalModuleName(&set, allocator, candidate);
    }

    return collectStringSet(allocator, &set);
}

fn resolveTemplateDependencyNameAlloc(
    allocator: std.mem.Allocator,
    current_template_name: ?[]const u8,
    raw_name: []const u8,
) !struct { name: []const u8, owned: bool } {
    const stripped = std.mem.trim(u8, stripTemplateNamespace(raw_name), " \t\r\n");
    if (stripped.len == 0) return .{ .name = "", .owned = false };
    if (current_template_name == null) return .{ .name = stripped, .owned = false };
    if (!isRelativeTemplateName(stripped)) return .{ .name = stripped, .owned = false };

    const resolved = try resolveRelativeTemplateNameAlloc(allocator, current_template_name.?, stripped);
    return .{ .name = resolved, .owned = true };
}

fn isRelativeTemplateName(name: []const u8) bool {
    return std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, "..") or
        std.mem.startsWith(u8, name, "./") or
        std.mem.startsWith(u8, name, "../") or
        std.mem.startsWith(u8, name, "/");
}

fn resolveRelativeTemplateNameAlloc(
    allocator: std.mem.Allocator,
    current_template_name: []const u8,
    relative_name: []const u8,
) ![]u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(allocator);

    var current_it = std.mem.splitScalar(u8, stripTemplateNamespace(current_template_name), '/');
    while (current_it.next()) |segment| {
        const trimmed = std.mem.trim(u8, segment, " \t\r\n");
        if (trimmed.len == 0) continue;
        try segments.append(allocator, trimmed);
    }

    var cursor = relative_name;
    if (std.mem.startsWith(u8, cursor, "/")) {
        cursor = cursor[1..];
    } else {
        while (std.mem.startsWith(u8, cursor, "../")) {
            if (segments.items.len != 0) _ = segments.pop();
            cursor = cursor[3..];
        }
        if (std.mem.eql(u8, cursor, "..")) {
            if (segments.items.len != 0) _ = segments.pop();
            cursor = "";
        } else if (std.mem.startsWith(u8, cursor, "./")) {
            cursor = cursor[2..];
        } else if (std.mem.eql(u8, cursor, ".")) {
            cursor = "";
        }
    }

    if (cursor.len != 0) {
        var rel_it = std.mem.splitScalar(u8, cursor, '/');
        while (rel_it.next()) |segment| {
            const trimmed = std.mem.trim(u8, segment, " \t\r\n");
            if (trimmed.len == 0 or std.mem.eql(u8, trimmed, ".")) continue;
            if (std.mem.eql(u8, trimmed, "..")) {
                if (segments.items.len != 0) _ = segments.pop();
                continue;
            }
            try segments.append(allocator, trimmed);
        }
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (segments.items, 0..) |segment, idx| {
        if (idx != 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, segment);
    }
    return out.toOwnedSlice(allocator);
}

fn isIgnoredTemplateMagicName(name: []const u8) bool {
    const upper = comptime [_][]const u8{
        "CURRENTDAY",
        "CURRENTMONTH",
        "CURRENTMONTHNAME",
        "CURRENTYEAR",
        "DISPLAYTITLE:",
        "PAGENAME",
        "PAGENAMEE",
        "FULLPAGENAME",
        "FULLPAGENAMEE",
        "BASEPAGENAME",
        "NAMESPACE",
        "NAMESPACENUMBER",
        "REVISIONUSER",
        "REVISIONYEAR",
        "SERVER",
        "SUBPAGENAME",
        "TALKPAGENAME",
        "WIKIMEDIALANGUAGE",
    };
    for (upper) |candidate| {
        if (startsWithCanonicalIgnoreCase(name, candidate)) return true;
    }
    return false;
}

fn startsWithCanonicalIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    var hay_idx: usize = 0;
    var needle_idx: usize = 0;
    while (hay_idx < haystack.len and needle_idx < needle.len) {
        const hay = haystack[hay_idx];
        if (hay == ' ' or hay == '_' or hay == '-') {
            hay_idx += 1;
            continue;
        }
        if (std.ascii.toLower(hay) != std.ascii.toLower(needle[needle_idx])) return false;
        hay_idx += 1;
        needle_idx += 1;
    }
    while (hay_idx < haystack.len) : (hay_idx += 1) {
        const hay = haystack[hay_idx];
        if (hay != ' ' and hay != '_' and hay != '-') break;
    }
    return needle_idx == needle.len;
}

fn filterTemplateDependencySourceAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var cursor: usize = 0;
    while (cursor < source.len) {
        if (std.mem.startsWith(u8, source[cursor..], "<!--")) {
            cursor = skipUntil(source, cursor + 4, "-->") orelse source.len;
            continue;
        }
        if (matchHtmlTagName(source[cursor..], "noinclude")) |tag| {
            if (tag.self_closing) {
                cursor += tag.end_offset;
            } else {
                cursor = skipPastClosingTag(source, cursor + tag.end_offset, "noinclude") orelse source.len;
            }
            continue;
        }
        if (matchHtmlTagName(source[cursor..], "includeonly")) |tag| {
            cursor += tag.end_offset;
            continue;
        }
        if (matchHtmlTagName(source[cursor..], "nowiki")) |tag| {
            if (tag.self_closing) {
                cursor += tag.end_offset;
            } else {
                cursor = skipPastClosingTag(source, cursor + tag.end_offset, "nowiki") orelse source.len;
            }
            continue;
        }
        if (matchHtmlTagName(source[cursor..], "pre")) |tag| {
            if (tag.self_closing) {
                cursor += tag.end_offset;
            } else {
                cursor = skipPastClosingTag(source, cursor + tag.end_offset, "pre") orelse source.len;
            }
            continue;
        }
        if (matchHtmlTagName(source[cursor..], "source")) |tag| {
            if (tag.self_closing) {
                cursor += tag.end_offset;
            } else {
                cursor = skipPastClosingTag(source, cursor + tag.end_offset, "source") orelse source.len;
            }
            continue;
        }
        if (matchHtmlTagName(source[cursor..], "syntaxhighlight")) |tag| {
            if (tag.self_closing) {
                cursor += tag.end_offset;
            } else {
                cursor = skipPastClosingTag(source, cursor + tag.end_offset, "syntaxhighlight") orelse source.len;
            }
            continue;
        }
        if (matchHtmlTagName(source[cursor..], "templatedata")) |tag| {
            if (tag.self_closing) {
                cursor += tag.end_offset;
            } else {
                cursor = skipPastClosingTag(source, cursor + tag.end_offset, "templatedata") orelse source.len;
            }
            continue;
        }
        try out.append(allocator, source[cursor]);
        cursor += 1;
    }

    return out.toOwnedSlice(allocator);
}

const MatchedHtmlTag = struct {
    end_offset: usize,
    self_closing: bool,
};

fn matchHtmlTagName(source: []const u8, name: []const u8) ?MatchedHtmlTag {
    if (source.len < 3 or source[0] != '<') return null;

    var cursor: usize = 1;
    while (cursor < source.len and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}

    var closing = false;
    if (cursor < source.len and source[cursor] == '/') {
        closing = true;
        cursor += 1;
        while (cursor < source.len and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
    }

    if (closing or cursor + name.len > source.len) return null;
    if (!startsWithIgnoreCase(source[cursor..], name)) return null;
    const boundary_idx = cursor + name.len;
    if (boundaryIdxInvalid(source, boundary_idx)) return null;

    const tag_end = std.mem.indexOfScalarPos(u8, source, boundary_idx, '>') orelse return null;
    const inner = source[boundary_idx..tag_end];
    const trimmed = std.mem.trim(u8, inner, " \t\r\n");
    return .{
        .end_offset = tag_end + 1,
        .self_closing = trimmed.len != 0 and trimmed[trimmed.len - 1] == '/',
    };
}

fn boundaryIdxInvalid(source: []const u8, idx: usize) bool {
    if (idx >= source.len) return false;
    const byte = source[idx];
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn skipPastClosingTag(source: []const u8, start: usize, name: []const u8) ?usize {
    var closing_buf: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&closing_buf, "</{s}", .{name}) catch return null;
    var cursor = start;
    while (cursor < source.len) : (cursor += 1) {
        if (!startsWithIgnoreCase(source[cursor..], prefix)) continue;
        const end_idx = std.mem.indexOfScalarPos(u8, source, cursor + prefix.len, '>') orelse return null;
        return end_idx + 1;
    }
    return null;
}

fn skipUntil(source: []const u8, start: usize, needle: []const u8) ?usize {
    const found = std.mem.indexOfPos(u8, source, start, needle) orelse return null;
    return found + needle.len;
}

fn extractModuleDependencyArg(tokens: []const Token, start: usize) ?[]const u8 {
    if (start >= tokens.len) return null;
    var idx = start;
    if (tokens[idx].tag == .lparen) {
        idx += 1;
        if (idx >= tokens.len or tokens[idx].tag != .string) return null;
        const text = tokens[idx].lexeme;
        return if (isLikelyModulePageName(text)) text else null;
    }
    if (tokens[idx].tag == .string) {
        const text = tokens[idx].lexeme;
        return if (isLikelyModulePageName(text)) text else null;
    }
    return null;
}

fn stripSubstPrefix(name: []const u8) []const u8 {
    var current = std.mem.trim(u8, name, " \t");
    while (true) {
        if (startsWithIgnoreCase(current, "subst:")) {
            current = std.mem.trim(u8, current["subst:".len..], " \t");
            continue;
        }
        if (startsWithIgnoreCase(current, "safesubst:")) {
            current = std.mem.trim(u8, current["safesubst:".len..], " \t");
            continue;
        }
        break;
    }
    return current;
}

fn stripTemplateNamespace(name: []const u8) []const u8 {
    if (startsWithIgnoreCase(name, "Template:")) {
        return std.mem.trim(u8, name["Template:".len..], " \t");
    }
    return name;
}

fn stripModuleNamespace(name: []const u8) []const u8 {
    if (startsWithIgnoreCase(name, "Module:")) {
        return std.mem.trim(u8, name["Module:".len..], " \t");
    }
    return name;
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (needle, 0..) |byte, idx| {
        if (std.ascii.toLower(haystack[idx]) != std.ascii.toLower(byte)) return false;
    }
    return true;
}

fn endsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    const offset = haystack.len - needle.len;
    for (needle, 0..) |byte, idx| {
        if (std.ascii.toLower(haystack[offset + idx]) != std.ascii.toLower(byte)) return false;
    }
    return true;
}

fn insertCanonicalTemplateName(set: *std.StringHashMapUnmanaged(void), allocator: std.mem.Allocator, name: []const u8) !void {
    const canonical = try canonicalTemplateNameAlloc(allocator, name);
    errdefer allocator.free(canonical);

    const gop = try set.getOrPut(allocator, canonical);
    if (gop.found_existing) {
        allocator.free(canonical);
        return;
    }
    gop.key_ptr.* = canonical;
}

pub fn canonicalTemplateNameAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const trimmed = std.mem.trim(u8, stripTemplateNamespace(stripSubstPrefix(name)), " \t\r\n");
    for (trimmed) |byte| {
        if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == '_') continue;
        try out.append(allocator, std.ascii.toLower(byte));
    }
    return out.toOwnedSlice(allocator);
}

pub fn canonicalModuleNameAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const trimmed = std.mem.trim(u8, stripModuleNamespace(name), " \t\r\n");
    for (trimmed) |byte| {
        if (byte == '_' or byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') {
            if (out.items.len != 0 and out.items[out.items.len - 1] != ' ') try out.append(allocator, ' ');
            continue;
        }
        try out.append(allocator, std.ascii.toLower(byte));
    }
    if (out.items.len != 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
    return out.toOwnedSlice(allocator);
}

fn isLikelyTemplatePageName(name: []const u8) bool {
    const trimmed = std.mem.trim(u8, stripTemplateNamespace(stripSubstPrefix(name)), " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 128) return false;
    if (std.mem.eql(u8, trimmed, "!") or std.mem.eql(u8, trimmed, "=")) return true;
    if (startsWithIgnoreCase(trimmed, "CURRENTDAY")) return false;
    if (startsWithIgnoreCase(trimmed, "CURRENTMONTH")) return false;
    if (startsWithIgnoreCase(trimmed, "CURRENTMONTHNAME")) return false;
    if (startsWithIgnoreCase(trimmed, "CURRENTYEAR")) return false;
    if (startsWithIgnoreCase(trimmed, "DISPLAYTITLE:")) return false;

    for (trimmed) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            ' ', '_', '-', '/', '\'', '(', ')', '.', ',' => continue,
            else => return false,
        }
    }
    return true;
}

fn isLikelyModulePageName(name: []const u8) bool {
    const trimmed = std.mem.trim(u8, stripModuleNamespace(name), " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 160) return false;
    if (trimmed[trimmed.len - 1] == '/') return false;

    for (trimmed) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            ' ', '_', '-', '/', '\'', '(', ')', '.', ',' => continue,
            else => return false,
        }
    }
    return true;
}

pub fn isLikelyCodeModulePageName(name: []const u8) bool {
    if (!isLikelyModulePageName(name)) return false;
    if (endsWithIgnoreCase(name, ".css")) return false;
    if (std.mem.indexOf(u8, name, ".txt/") != null) return false;
    if (endsWithIgnoreCase(name, "/documentation")) return false;
    if (endsWithIgnoreCase(name, "/doc")) return false;
    if (endsWithIgnoreCase(name, " documentation")) return false;
    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, name, " \t\r\n"), "affix doc")) return false;
    return true;
}

fn insertCanonicalModuleName(set: *std.StringHashMapUnmanaged(void), allocator: std.mem.Allocator, name: []const u8) !void {
    const canonical = try canonicalModuleNameAlloc(allocator, name);
    errdefer allocator.free(canonical);

    const gop = try set.getOrPut(allocator, canonical);
    if (gop.found_existing) {
        allocator.free(canonical);
        return;
    }
    gop.key_ptr.* = canonical;
}

fn collectStringSet(allocator: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void)) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, set.count());
    var it = set.iterator();
    var idx: usize = 0;
    while (it.next()) |entry| : (idx += 1) out[idx] = try allocator.dupe(u8, entry.key_ptr.*);
    std.mem.sort([]const u8, out, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return out;
}

fn deinitOwnedStringSet(allocator: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void)) void {
    var it = set.iterator();
    while (it.next()) |entry| allocator.free(entry.key_ptr.*);
    set.deinit(allocator);
}

fn freeStringSlice(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn renderValuesAlloc(allocator: std.mem.Allocator, values: []const Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (values, 0..) |value, idx| {
        if (idx != 0) try out.appendSlice(allocator, "\t");
        try appendValueText(&out, allocator, value);
    }
    return out.toOwnedSlice(allocator);
}

fn runLuaOracleAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const wrapper = try std.fmt.allocPrint(allocator,
        \\local src = [==[{s}]==]
        \\local chunk, err = load(src, "chunk", "t", _G)
        \\if not chunk then io.write("ERR:" .. err) os.exit(2) end
        \\local vals = {{ chunk() }}
        \\for i, v in ipairs(vals) do
        \\  if i > 1 then io.write("\t") end
        \\  io.write(type(v) == "nil" and "nil" or tostring(v))
        \\end
        \\
    , .{source});
    defer allocator.free(wrapper);
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "lua", "-e", wrapper },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.UnsupportedSyntax,
        else => return error.UnsupportedSyntax,
    }
    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, "\n"));
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

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var mapped = try mmapReadOnlyPath(path);
    defer mapped.deinit();
    return allocator.dupe(u8, mapped.mapping);
}

fn singleReturn(vm: *Vm, value: Value) ![]Value {
    const out = try vm.alloc().alloc(Value, 1);
    out[0] = value;
    return out;
}

fn emptyReturns() []Value {
    return &.{};
}

fn appendValueText(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: Value) !void {
    switch (value) {
        .nil => try out.appendSlice(allocator, "nil"),
        .boolean => |flag| try out.appendSlice(allocator, if (flag) "true" else "false"),
        .number => |num| {
            const text = try std.fmt.allocPrint(allocator, "{d}", .{num});
            defer allocator.free(text);
            try out.appendSlice(allocator, text);
        },
        .string => |text| try out.appendSlice(allocator, text),
        .table => try out.appendSlice(allocator, "table"),
        .generated_callable => try out.appendSlice(allocator, "function"),
        .function => try out.appendSlice(allocator, "function"),
        .iterator => try out.appendSlice(allocator, "iterator"),
    }
}

test "simple lua interpreter matches lua for arithmetic and locals" {
    const source =
        \\local x = 4
        \\local y = 7
        \\return x * y + 3, x < y
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();
    var result = try run(std.testing.allocator, &chunk);
    defer result.deinit();
    const ours = try renderValuesAlloc(std.testing.allocator, result.returns);
    defer std.testing.allocator.free(ours);
    const lua = try runLuaOracleAlloc(std.testing.allocator, source);
    defer std.testing.allocator.free(lua);
    try std.testing.expectEqualStrings(lua, ours);
}

test "simple lua interpreter matches lua for tables functions and loops" {
    const source =
        \\local p = {}
        \\function p.bump(n)
        \\  local sum = 0
        \\  for i = 1, n do
        \\    sum = sum + i
        \\  end
        \\  return sum
        \\end
        \\local t = {a = 3, b = 9}
        \\local total = 0
        \\for k, v in pairs(t) do
        \\  total = total + v
        \\end
        \\return p.bump(4), total, string.upper("ok")
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();
    var result = try run(std.testing.allocator, &chunk);
    defer result.deinit();
    const ours = try renderValuesAlloc(std.testing.allocator, result.returns);
    defer std.testing.allocator.free(ours);
    const lua = try runLuaOracleAlloc(std.testing.allocator, source);
    defer std.testing.allocator.free(lua);
    try std.testing.expectEqualStrings(lua, ours);
}

test "emitZigModuleAlloc is deterministic across repeated compiles" {
    const source =
        \\local outer = 41
        \\local function capture(arg)
        \\  return outer, arg, print
        \\end
        \\return capture
    ;
    var first = try compile(std.testing.allocator, source);
    defer first.deinit();
    const first_zig = try emitZigModuleAlloc(std.testing.allocator, &first);
    defer std.testing.allocator.free(first_zig);

    var second = try compile(std.testing.allocator, source);
    defer second.deinit();
    const second_zig = try emitZigModuleAlloc(std.testing.allocator, &second);
    defer std.testing.allocator.free(second_zig);

    try std.testing.expectEqualStrings(first_zig, second_zig);
}

test "cloneConstTableSeedAlloc clones hoisted const tables" {
    const table_array = [_]ConstValueSeed{};
    const table_string_fields = [_]ConstTableStringFieldSeed{
        .{ .key = "answer", .value = .{ .number = 42 } },
    };
    const table_int_fields = [_]ConstTableIntFieldSeed{};
    const table_seed = ConstTableSeed{
        .array = &table_array,
        .string_fields = &table_string_fields,
        .int_fields = &table_int_fields,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const table = try cloneConstTableSeedAlloc(arena.allocator(), &table_seed);
    try std.testing.expectEqual(@as(f64, 42), table.getString("answer").number);
}

test "emitZigModuleAlloc hoists const tables at file scope" {
    const source =
        \\local function build()
        \\  local map = { answer = 40 + 2, nested = { ok = true } }
        \\  return map
        \\end
        \\return build()
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleAlloc(std.testing.allocator, &chunk);
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, "const const_table_0 = lua.ConstTableSeed") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "const const_table_1 = lua.ConstTableSeed") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "pub fn run(") != null);

    const first_table = std.mem.indexOf(u8, zig_source, "const const_table_0 = lua.ConstTableSeed").?;
    const run_fn = std.mem.indexOf(u8, zig_source, "pub fn run(").?;
    try std.testing.expect(first_table < run_fn);
}

test "emitZigModuleAlloc structurally interns identical const tables" {
    const source =
        \\local first = { nested = { ok = true }, value = "same" }
        \\local second = { nested = { ok = true }, value = "same" }
        \\return first, second
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleAlloc(std.testing.allocator, &chunk);
    defer std.testing.allocator.free(zig_source);

    try std.testing.expectEqual(@as(usize, 8), std.mem.count(u8, zig_source, "const const_table_"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, zig_source, "cloneConstTableSeedAlloc"));
}

test "emitZigModuleAlloc lowers builtin calls into direct Zig helpers" {
    const source =
        \\local values = { "ok", "go" }
        \\local total = 0
        \\local function build(word)
        \\  table.insert(values, string.upper(word))
        \\  total = string.len(word) + math.floor(2.9)
        \\  for k, v in pairs(values) do
        \\    total = total + k
        \\  end
        \\  for i, v in ipairs(values) do
        \\    total = total + i
        \\  end
        \\  return total
        \\end
        \\return build("zig")
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleAlloc(std.testing.allocator, &chunk);
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua.generatedStringUpper") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua.generatedStringLen") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua.generatedMathFloor") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua.generatedTableInsert") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua.generatedPairsIterator") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua.generatedIpairsIterator") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "runStaticProgram") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua.StaticProgram") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua.Instruction") == null);
}

test "emitZigModuleAlloc emits static call dispatcher instead of runtime generic call trampoline" {
    const source =
        \\local function f(x)
        \\  return x
        \\end
        \\return f("ok")
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleAlloc(std.testing.allocator, &chunk);
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(
        std.mem.indexOf(u8, zig_source, "lua.generatedResultsFirst(try fn_") != null or
            std.mem.indexOf(u8, zig_source, "generatedDispatchFirst(runtime, tmp_") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "generatedCallKnownCallableFirst(") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua.generatedCall(") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua.generatedInvoke(") == null);
}

test "emitZigModuleWithOptionsAlloc lowers require into generated module dispatch helper" {
    const source =
        \\local languages = require("Module:languages")
        \\return languages
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleWithOptionsAlloc(std.testing.allocator, &chunk, .{
        .enable_direct_module_dispatch = true,
        .direct_module_dispatch_names = &.{"languages"},
    });
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua_global_require_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "generatedLoadCompiledModuleByIndex(runtime, 0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "generatedModuleRequireFn") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "\"Module:languages\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "Module:languages") == null);
}

test "emitZigModuleResultWithOptionsAlloc can omit module run entry points" {
    const source =
        \\local value = 1
        \\return value
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    var emitted = try emitZigModuleResultWithOptionsAlloc(std.testing.allocator, &chunk, .{
        .emit_run_entry_points = false,
    });
    defer emitted.deinit(std.testing.allocator);

    try std.testing.expect(emitted.function_count >= 1);
    try std.testing.expect(std.mem.indexOf(u8, emitted.source, "pub fn initRuntimeGlobals(") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted.source, "pub fn runInRuntimeWithGlobals(") == null);
    try std.testing.expect(std.mem.indexOf(u8, emitted.source, "pub fn runInRuntime(") == null);
    try std.testing.expect(std.mem.indexOf(u8, emitted.source, "pub fn run(") == null);
}

test "emitZigModuleWithOptionsAlloc lowers mw.loadData into generated module dispatch helper" {
    const source =
        \\local data = mw.loadData("Module:languages/data/2")
        \\return data
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleWithOptionsAlloc(std.testing.allocator, &chunk, .{
        .enable_direct_module_dispatch = true,
        .direct_module_dispatch_names = &.{"languages/data/2"},
    });
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua_global_mw_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "generatedLoadCompiledModuleByIndex(runtime, 0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "generatedModuleMwTableValue") != null);
}

test "emitZigModuleWithOptionsAlloc lowers require aliases into generated module dispatch helper" {
    const source =
        \\local loader = require
        \\local name = "Module:languages"
        \\return loader(name)
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleWithOptionsAlloc(std.testing.allocator, &chunk, .{
        .enable_direct_module_dispatch = true,
        .direct_module_dispatch_names = &.{"languages"},
    });
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, "generatedLoadCompiledModuleByIndex(runtime, 0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua.generatedCall(runtime, lua_local_loader_0") == null);
}

test "emitZigModuleWithOptionsAlloc lowers mw aliases into generated module dispatch helper" {
    const source =
        \\local mw2 = mw
        \\local loader = mw2.loadData
        \\return loader("Module:languages/data/2")
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleWithOptionsAlloc(std.testing.allocator, &chunk, .{
        .enable_direct_module_dispatch = true,
        .direct_module_dispatch_names = &.{"languages/data/2"},
    });
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, "generatedLoadCompiledModuleByIndex(runtime, 0)") != null);
}

test "emitZigModuleWithOptionsAlloc merges branch-local module names into a known dispatch set" {
    const source =
        \\local loader = require
        \\local name
        \\if true then
        \\  name = "Module:foo"
        \\else
        \\  name = "Module:bar"
        \\end
        \\return loader(name)
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleWithOptionsAlloc(std.testing.allocator, &chunk, .{
        .enable_direct_module_dispatch = true,
        .direct_module_dispatch_names = &.{ "foo", "bar" },
    });
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, "generatedLoadCompiledModuleKnownFirst(") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "generatedLoadCompiledModuleFirst(") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "return error.UnknownVariable;") != null);
}

test "emitZigModuleWithOptionsAlloc propagates captured require facts into nested functions" {
    const source =
        \\local loader = require
        \\local function inner(name)
        \\  return loader(name)
        \\end
        \\return inner("Module:languages")
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleWithOptionsAlloc(std.testing.allocator, &chunk, .{
        .enable_direct_module_dispatch = true,
        .direct_module_dispatch_names = &.{"languages"},
    });
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, "generatedLoadCompiledModuleByIndex(runtime, 0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "generatedLoadCompiledModuleFirst(") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua.generatedCall(runtime, capture.lua_capture_loader_0.*") == null);
}

test "emitZigModuleWithOptionsAlloc lowers require when needed helper into direct module dispatch" {
    const source =
        \\local require_when_needed = require("Module:require when needed")
        \\return require_when_needed("Module:parameters", "process")
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleWithOptionsAlloc(std.testing.allocator, &chunk, .{
        .enable_direct_module_dispatch = true,
        .direct_module_dispatch_names = &.{ "require when needed", "parameters" },
    });
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, "generatedLoadCompiledModuleByIndex(runtime, 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, ".table.get(lua.Value{ .string = \"process\" })") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua.generatedCall(runtime, lua_local_require_when_needed_0") == null);
}

test "emitZigModuleWithOptionsAlloc lowers Module:load load_data export into direct module dispatch" {
    const source =
        \\local load = require("Module:load")
        \\local load_data = load.load_data
        \\return load_data("Module:languages/data/2")
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleWithOptionsAlloc(std.testing.allocator, &chunk, .{
        .enable_direct_module_dispatch = true,
        .direct_module_dispatch_names = &.{ "load", "languages/data/2" },
    });
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, "generatedLoadCompiledModuleByIndex(runtime, 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua.generatedCall(runtime, lua_local_load_data_") == null);
}

test "emitZigModuleWithOptionsAlloc lowers Module:load safe_load_data export into direct safe dispatch" {
    const source =
        \\local load = require("Module:load")
        \\local safe_load_data = load.safe_load_data
        \\return safe_load_data("Module:languages/data/2")
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleWithOptionsAlloc(std.testing.allocator, &chunk, .{
        .enable_direct_module_dispatch = true,
        .direct_module_dispatch_names = &.{ "load", "languages/data/2" },
    });
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, "generatedLoadCompiledModuleByIndex(runtime, 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua.generatedCall(runtime, lua_local_safe_load_data_") == null);
}

test "emitZigModuleWithOptionsAlloc lowers Module:load safe_require export into direct safe dispatch" {
    const source =
        \\local load = require("Module:load")
        \\local safe_require = load.safe_require
        \\return safe_require("Module:languages")
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleWithOptionsAlloc(std.testing.allocator, &chunk, .{
        .enable_direct_module_dispatch = true,
        .direct_module_dispatch_names = &.{ "load", "languages" },
    });
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, "generatedLoadCompiledModuleByIndex(runtime, 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua.generatedCall(runtime, lua_local_safe_require_") == null);
}

test "emitZigModuleWithOptionsAlloc lowers identity load_data wrapper functions into direct dispatch" {
    const source =
        \\local load = require("Module:load")
        \\local function load_data(name)
        \\  return load.load_data(name)
        \\end
        \\return load_data("Module:languages/data/2")
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleWithOptionsAlloc(std.testing.allocator, &chunk, .{
        .enable_direct_module_dispatch = true,
        .direct_module_dispatch_names = &.{ "load", "languages/data/2" },
    });
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, "generatedLoadCompiledModuleByIndex(runtime, 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua.generatedCall(runtime, lua_local_load_data_") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua.generatedCall(runtime, capture.lua_capture_load_data_") == null);
}

test "emitZigModuleWithOptionsAlloc lowers identity safe_require wrapper functions into direct dispatch" {
    const source =
        \\local load = require("Module:load")
        \\local function safe_require(name)
        \\  return load.safe_require(name)
        \\end
        \\return safe_require("Module:languages")
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleWithOptionsAlloc(std.testing.allocator, &chunk, .{
        .enable_direct_module_dispatch = true,
        .direct_module_dispatch_names = &.{ "load", "languages" },
    });
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, "generatedLoadCompiledModuleByIndex(runtime, 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua.generatedCall(runtime, lua_local_safe_require_") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua.generatedCall(runtime, capture.lua_capture_safe_require_") == null);
}

test "extractModuleDependencies follows local module-name aliases" {
    const source =
        \\local require = require
        \\local title_make_title_module = "Module:title/makeTitle"
        \\local function make_title(...)
        \\  make_title = require(title_make_title_module)
        \\  return make_title(...)
        \\end
    ;

    const deps = try extractModuleDependencies(std.testing.allocator, source);
    defer freeStringSlice(std.testing.allocator, deps);

    try std.testing.expectEqual(@as(usize, 1), deps.len);
    try std.testing.expectEqualStrings("title/maketitle", deps[0]);
}

test "extractModuleDependencies follows direct load_data wrappers and aliased module names" {
    const source =
        \\local require = require
        \\local load_module = "Module:load"
        \\local pages_module = "Module:pages"
        \\local function load_data(...)
        \\  load_data = require(load_module).load_data
        \\  return load_data(...)
        \\end
        \\return load_data(pages_module)
    ;

    const deps = try extractModuleDependencies(std.testing.allocator, source);
    defer freeStringSlice(std.testing.allocator, deps);

    try std.testing.expectEqual(@as(usize, 2), deps.len);
    try std.testing.expectEqualStrings("load", deps[0]);
    try std.testing.expectEqualStrings("pages", deps[1]);
}

test "extractModuleDependencies follows nested require(load).load_data module constants" {
    const source =
        \\local load_module = "Module:load"
        \\local scribunto_module = "Module:Scribunto"
        \\local title_get_current_namespace_module = "Module:title/getCurrentNamespace"
        \\local title_get_current_title_module = "Module:title/getCurrentTitle"
        \\local title_get_main_page_title_module = "Module:title/getMainPageTitle"
        \\
        \\local function get_current_title(...)
        \\  get_current_title = require(title_get_current_title_module)
        \\  return get_current_title(...)
        \\end
        \\
        \\local function get_main_page_title(...)
        \\  get_main_page_title = require(title_get_main_page_title_module)
        \\  return get_main_page_title(...)
        \\end
        \\
        \\local function php_ltrim(...)
        \\  php_ltrim = require(scribunto_module).php_ltrim
        \\  return php_ltrim(...)
        \\end
        \\
        \\local function get_namespace_has_subpages()
        \\  return require(load_module).load_data(title_get_current_namespace_module).hasSubpages
        \\end
    ;

    const deps = try extractModuleDependencies(std.testing.allocator, source);
    defer freeStringSlice(std.testing.allocator, deps);

    try std.testing.expectEqual(@as(usize, 5), deps.len);
    try std.testing.expectEqualStrings("load", deps[0]);
    try std.testing.expectEqualStrings("scribunto", deps[1]);
    try std.testing.expectEqualStrings("title/getcurrentnamespace", deps[2]);
    try std.testing.expectEqualStrings("title/getcurrenttitle", deps[3]);
    try std.testing.expectEqualStrings("title/getmainpagetitle", deps[4]);
}

test "extractModuleDependencies accepts bare module names and aliases" {
    const source =
        \\local util_module = "libraryUtil"
        \\local strict_module = "strict"
        \\local translit_module = "ml-translit"
        \\local util = require(util_module)
        \\local strict = require(strict_module)
        \\local translit = require(translit_module)
        \\return util.checkType, strict, translit
    ;

    const deps = try extractModuleDependencies(std.testing.allocator, source);
    defer freeStringSlice(std.testing.allocator, deps);

    try std.testing.expectEqual(@as(usize, 3), deps.len);
    try std.testing.expectEqualStrings("libraryutil", deps[0]);
    try std.testing.expectEqualStrings("ml-translit", deps[1]);
    try std.testing.expectEqualStrings("strict", deps[2]);
}

test "extractModuleDependencies keeps Module:-prefixed constants passed through loadData aliases" {
    const source =
        \\local glossary_data_module = "Module:glossary/data"
        \\local load_data = mw.loadData
        \\local data
        \\local function get_data()
        \\  data, get_data = load_data(glossary_data_module), nil
        \\  return data
        \\end
    ;

    const deps = try extractModuleDependencies(std.testing.allocator, source);
    defer freeStringSlice(std.testing.allocator, deps);

    try std.testing.expectEqual(@as(usize, 1), deps.len);
    try std.testing.expectEqualStrings("glossary/data", deps[0]);
}

test "extractModuleDependencies keeps bare require module names without Module: prefix" {
    const source =
        \\local libraryUtil = require("libraryUtil")
        \\local checkType = libraryUtil.checkType
    ;

    const deps = try extractModuleDependencies(std.testing.allocator, source);
    defer freeStringSlice(std.testing.allocator, deps);

    try std.testing.expectEqual(@as(usize, 1), deps.len);
    try std.testing.expectEqualStrings("libraryutil", deps[0]);
}

test "extractModuleDependencies keeps direct loadData module literals with capitalized paths" {
    const source =
        \\local defColors = mw.loadData("Module:Chart/Default colors")
        \\return defColors
    ;

    const deps = try extractModuleDependencies(std.testing.allocator, source);
    defer freeStringSlice(std.testing.allocator, deps);

    try std.testing.expectEqual(@as(usize, 1), deps.len);
    try std.testing.expectEqualStrings("chart/default colors", deps[0]);
}

test "extractModuleDependencies does not treat module values as require aliases" {
    const source =
        \\local debug_track_module = "Module:debug/track"
        \\local function track(page)
        \\  local debug_track = require(debug_track_module)
        \\  debug_track(page)
        \\end
        \\track("Module:utilities/templates/categorize called with variant langcode")
    ;

    const deps = try extractModuleDependencies(std.testing.allocator, source);
    defer freeStringSlice(std.testing.allocator, deps);

    try std.testing.expectEqual(@as(usize, 1), deps.len);
    try std.testing.expectEqualStrings("debug/track", deps[0]);
}

test "extractModuleDependencies skips module documentation markup" {
    const source =
        \\{{documentation needed}}<!-- Replace this with a short description of the purpose of the module, and how to use it. -->
        \\{{module cat|-|Utility}}
    ;

    const deps = try extractModuleDependencies(std.testing.allocator, source);
    defer freeStringSlice(std.testing.allocator, deps);

    try std.testing.expectEqual(@as(usize, 0), deps.len);
}

test "extractModuleDependencies skips json-backed module content" {
    const source =
        \\{
        \\  "foo": "bar"
        \\}
    ;

    const deps = try extractModuleDependencies(std.testing.allocator, source);
    defer freeStringSlice(std.testing.allocator, deps);

    try std.testing.expectEqual(@as(usize, 0), deps.len);
}

test "emitZigModuleAlloc evaluates method-call receivers once" {
    const source =
        \\local alt = "tooltip"
        \\local html = "body"
        \\return tostring(mw.html.create("span"):attr("title", alt):wikitext(html))
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleAlloc(std.testing.allocator, &chunk);
    defer std.testing.allocator.free(zig_source);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, zig_source, "getString(\"html\")"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, zig_source, "getGeneratedMethod("));
    try std.testing.expect(zig_source.len < 16 * 1024);
}

test "emitZigModuleAlloc keeps long method chains linear in size" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "return tostring(mw.html.create(\"div\")");
    for (0..24) |idx| {
        _ = idx;
        try source.appendSlice(std.testing.allocator, ":css(\"width\", \"8px\")");
    }
    try source.appendSlice(std.testing.allocator, ")\n");

    var chunk = try compile(std.testing.allocator, source.items);
    defer chunk.deinit();

    const zig_source = try emitZigModuleAlloc(std.testing.allocator, &chunk);
    defer std.testing.allocator.free(zig_source);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, zig_source, "getString(\"html\")"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, zig_source, "getGeneratedMethod("));
    try std.testing.expect(zig_source.len < 96 * 1024);
}

test "emitZigModuleAlloc supports top-level varargs" {
    const source =
        \\local opts = ...
        \\return opts
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleAlloc(std.testing.allocator, &chunk);
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, "const varargs = if (args.len > 0) args[0..] else &.{};") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "varargs[0]") != null);
}

test "emitZigModuleAlloc preserves captured locals for evaluated dead closures" {
    const source =
        \\local outer = 1
        \\local unused = function()
        \\  return outer
        \\end
        \\return 0
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleAlloc(std.testing.allocator, &chunk);
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, "const lua_local_outer_0: lua.Value = tmp_0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "var lua_local_outer_0: lua.Value = tmp_0;") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "&lua_local_outer_0") != null);
}

test "emitZigModuleAlloc emits negative zero as float literal" {
    const source =
        \\return -0
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleAlloc(std.testing.allocator, &chunk);
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, ".number = -0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, ".number = -0 }") == null);
}

test "emitZigModuleAlloc forces integer-looking float literals to stay floats" {
    const source =
        \\return 18446744073709551616
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleAlloc(std.testing.allocator, &chunk);
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, ".number = 18446744073709552000.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, ".number = 18446744073709552000 }") == null);
}

test "emitZigModuleAlloc emits capture structs for lexical closures" {
    const source =
        \\local outer = 41
        \\local function make()
        \\  local function inner(arg)
        \\    return outer + arg
        \\  end
        \\  return inner
        \\end
        \\return make()
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleAlloc(std.testing.allocator, &chunk);
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, "const Capture_") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua_capture_outer_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, ".lua_capture_outer_0 = &lua_local_outer_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "capture_obj") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "runtime.generatedCallableValue") != null);
}

test "emitZigModuleAlloc sanitizes capture field names in direct calls" {
    const source =
        \\local _r = function(x)
        \\  return x
        \\end
        \\local function call_it(y)
        \\  return _r(y)
        \\end
        \\return call_it("ok")
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleAlloc(std.testing.allocator, &chunk);
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, ".lua_capture_r_0 = ") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, ".lua_capture__r_0 = ") == null);
}

test "analyzeDirectModule dedupes repeated function literal pointers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const fn_expr = try allocator.create(Expr);
    fn_expr.* = .{
        .function_lit = .{
            .params = &.{},
            .body = &.{},
            .is_vararg = false,
        },
    };
    const stmt_a = try allocator.create(Stmt);
    stmt_a.* = .{ .expr_stmt = fn_expr };
    const stmt_b = try allocator.create(Stmt);
    stmt_b.* = .{ .expr_stmt = fn_expr };
    const body = try allocator.dupe(*Stmt, &.{ stmt_a, stmt_b });

    var state = DirectModuleState.init(std.testing.allocator, .{});
    defer state.deinit();
    try analyzeDirectModule(&state, body);

    try std.testing.expectEqual(@as(usize, 2), state.functions.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.expr_function_refs.items.len);
}

test "analyzeDirectModule dedupes repeated function definition pointers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const fn_stmt = try allocator.create(Stmt);
    fn_stmt.* = .{
        .function_def = .{
            .target = .{ .name = "f" },
            .params = &.{},
            .body = &.{},
            .is_vararg = false,
            .is_local = true,
        },
    };
    const body = try allocator.dupe(*Stmt, &.{ fn_stmt, fn_stmt });

    var state = DirectModuleState.init(std.testing.allocator, .{});
    defer state.deinit();
    try analyzeDirectModule(&state, body);

    try std.testing.expectEqual(@as(usize, 2), state.functions.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.stmt_function_refs.items.len);
}

test "emitZigModuleAlloc preserves readable Lua variable names in generated identifiers" {
    const source =
        \\local outer_value = 41
        \\local function make_result(input_value)
        \\  local inner_total = outer_value + input_value
        \\  return inner_total
        \\end
        \\return make_result(1)
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleAlloc(std.testing.allocator, &chunk);
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua_local_outer_value_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua_local_input_value_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua_local_inner_total_1") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "lua_capture_outer_value_0") != null);
}

test "emitZigModuleAlloc gives nested generic-for captures unique names" {
    const source =
        \\local t = { a = 1, b = 2 }
        \\for k, v in pairs(t) do
        \\  for x, y in pairs(t) do
        \\    print(k, v, x, y)
        \\  end
        \\end
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleAlloc(std.testing.allocator, &chunk);
    defer std.testing.allocator.free(zig_source);

    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, zig_source, "|pair|"));
    try std.testing.expect(std.mem.count(u8, zig_source, "|pair_") >= 2);
}

test "emitZigModuleAlloc consumes extra local assignment temporaries" {
    const source =
        \\local a, b = { one = 1 }, { two = 2 }, { three = 3 }
        \\return a, b
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleAlloc(std.testing.allocator, &chunk);
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, "_ = tmp_") != null);
}

test "emitZigModuleAlloc consumes extra assignment temporaries" {
    const source =
        \\local a = nil
        \\a = { one = 1 }, { two = 2 }
        \\return a
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleAlloc(std.testing.allocator, &chunk);
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, "_ = tmp_") != null);
}

test "emitZigModuleAlloc keeps reassigned locals mutable" {
    const source =
        \\local converter = nil
        \\converter = function(value)
        \\  return value
        \\end
        \\return converter
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleAlloc(std.testing.allocator, &chunk);
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, "var lua_local_converter_0: lua.Value = tmp_0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "const lua_local_converter_0: lua.Value = tmp_0;") == null);
}

test "emitZigModuleAlloc keeps rebinding function definitions mutable" {
    const source =
        \\local converter = nil
        \\function converter(value)
        \\  return value
        \\end
        \\return converter
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const zig_source = try emitZigModuleAlloc(std.testing.allocator, &chunk);
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, "var lua_local_converter_0: lua.Value = tmp_0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "const lua_local_converter_0: lua.Value = tmp_0;") == null);
}

fn findFirstConstTableInBody(body: []const *Stmt) ?*const Table {
    for (body) |stmt| {
        if (findFirstConstTableInStmt(stmt)) |table| return table;
    }
    return null;
}

fn findFirstConstTableInStmt(stmt: *const Stmt) ?*const Table {
    return switch (stmt.*) {
        .local_assign => |op| findFirstConstTableInExprs(op.exprs),
        .assign => |op| findFirstConstTableInExprs(op.exprs),
        .function_def => |op| findFirstConstTableInBody(op.body),
        .if_stmt => |op| blk: {
            for (op.branches) |branch| {
                if (findFirstConstTableInExpr(branch.condition)) |table| break :blk table;
                if (findFirstConstTableInBody(branch.body)) |table| break :blk table;
            }
            break :blk findFirstConstTableInBody(op.else_body);
        },
        .do_block => |body| findFirstConstTableInBody(body),
        .while_stmt => |op| findFirstConstTableInExpr(op.condition) orelse findFirstConstTableInBody(op.body),
        .repeat_stmt => |op| findFirstConstTableInBody(op.body) orelse findFirstConstTableInExpr(op.condition),
        .numeric_for => |op| {
            return findFirstConstTableInExpr(op.start) orelse
                findFirstConstTableInExpr(op.finish) orelse
                (if (op.step) |step| findFirstConstTableInExpr(step) else null) orelse
                findFirstConstTableInBody(op.body);
        },
        .generic_for => |op| findFirstConstTableInExprs(op.iterator_exprs) orelse findFirstConstTableInBody(op.body),
        .return_stmt => |op| findFirstConstTableInExprs(op.exprs),
        .break_stmt => null,
        .expr_stmt => |expr| findFirstConstTableInExpr(expr),
    };
}

fn findFirstConstTableInExprs(exprs: []const *Expr) ?*const Table {
    for (exprs) |expr| {
        if (findFirstConstTableInExpr(expr)) |table| return table;
    }
    return null;
}

fn findFirstConstTableInExpr(expr: *const Expr) ?*const Table {
    return switch (expr.*) {
        .const_table => |table| table,
        .unary => |op| findFirstConstTableInExpr(op.expr),
        .binary => |op| findFirstConstTableInExpr(op.lhs) orelse findFirstConstTableInExpr(op.rhs),
        .table_ctor => |fields| blk: {
            for (fields) |field| {
                switch (field) {
                    .array => |child| if (findFirstConstTableInExpr(child)) |table| break :blk table,
                    .named => |named| if (findFirstConstTableInExpr(named.value)) |table| break :blk table,
                    .indexed => |indexed| {
                        if (findFirstConstTableInExpr(indexed.key)) |table| break :blk table;
                        if (findFirstConstTableInExpr(indexed.value)) |table| break :blk table;
                    },
                }
            }
            break :blk null;
        },
        .field => |field| findFirstConstTableInExpr(field.object),
        .index => |index| findFirstConstTableInExpr(index.object) orelse findFirstConstTableInExpr(index.key),
        .call => |call| findFirstConstTableInExpr(call.callee) orelse findFirstConstTableInExprs(call.args),
        .function_lit => |func| findFirstConstTableInBody(func.body),
        .nil_lit, .bool_lit, .number_lit, .string_lit, .variable, .varargs => null,
    };
}

test "lua optimizer hoists fully constant table literals inside functions" {
    const source =
        \\local build = function()
        \\  local map = { answer = 40 + 2, nested = { ok = true, name = "lu" .. "a" }, [5] = -1 }
        \\  return map
        \\end
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    const template = findFirstConstTableInBody(chunk.body) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(f64, 42), template.getString("answer").number);
    const nested = template.getString("nested");
    try std.testing.expect(nested == .table);
    try std.testing.expectEqual(true, nested.table.getString("ok").boolean);
    try std.testing.expectEqualStrings("lua", nested.table.getString("name").string);
    try std.testing.expectEqual(@as(f64, -1), template.getNumber(5).number);
}

test "lua optimizer hoisted tables still produce fresh mutable values per call" {
    const source =
        \\local build = function()
        \\  return { answer = 42, nested = { ok = true } }
        \\end
        \\local left = build()
        \\local right = build()
        \\left.answer = 7
        \\left.nested.ok = false
        \\return left == right, left.answer, right.answer, left.nested == right.nested, left.nested.ok, right.nested.ok
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();
    var result = try run(std.testing.allocator, &chunk);
    defer result.deinit();
    const ours = try renderValuesAlloc(std.testing.allocator, result.returns);
    defer std.testing.allocator.free(ours);
    const lua = try runLuaOracleAlloc(std.testing.allocator, source);
    defer std.testing.allocator.free(lua);
    try std.testing.expectEqualStrings(lua, ours);
}

test "lua optimizer keeps runtime-dependent table literals dynamic" {
    const source =
        \\local x = 3
        \\local build = function()
        \\  return { answer = x }
        \\end
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    try std.testing.expect(findFirstConstTableInBody(chunk.body) == null);
}

test "classifyModuleSource distinguishes Lua from module documentation markup" {
    try std.testing.expectEqual(.lua, classifyModuleSource(
        \\-- comment
        \\local export = {}
        \\function export.main(frame)
        \\  return "ok"
        \\end
        \\return export
    ));
    try std.testing.expectEqual(.non_lua, classifyModuleSource(
        \\{{#invoke:aa-IPA/testcases|run_tests|differs_at=1}}
    ));
    try std.testing.expectEqual(.non_lua, classifyModuleSource(
        \\<noinclude>{{documentation}}</noinclude>
    ));
    try std.testing.expectEqual(.non_lua, classifyModuleSource(
        \\This module generates the phonemic IPA transcription of Afar entries. It runs [[Template:aa-IPA]].
        \\===References===
        \\* {{R:aa:Mahaffy:1979}}
    ));
    try std.testing.expectEqual(.non_lua, classifyModuleSource(
        \\.unicode-header-table {
        \\  display: table;
        \\}
    ));
    try std.testing.expectEqual(.non_lua, classifyModuleSource(
        \\/* The objective of the next few rules is to make CategoryTree's <div> output */
        \\.ts-categoryBreadcrumbs {
        \\  display: block;
        \\}
    ));
    try std.testing.expectEqual(.empty, classifyModuleSource("  \n\t "));
}

test "classifyNamedModuleSource recognizes JSON-backed modules" {
    try std.testing.expectEqual(.json, classifyNamedModuleSource("etymology languages/canonical names.json",
        \\{
        \\  "Arbëresh Albanian": "aae"
        \\}
    ));
    try std.testing.expectEqual(.lua, classifyNamedModuleSource("utilities",
        \\return { ok = true }
    ));
}

test "emitJsonModuleAlloc lowers JSON data modules into a static Zig module" {
    const zig_source = try emitJsonModuleAlloc(std.testing.allocator,
        \\{
        \\  "Arbëresh Albanian": "aae",
        \\  "nested": {
        \\    "codes": ["kea-alu", "alg-abp"]
        \\  }
        \\}
    );
    defer std.testing.allocator.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, "Generated from a JSON-backed module page") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "\"Arb\\xC3\\xABresh Albanian\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "\"kea-alu\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "cloneConstTableSeedAlloc") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "pub fn run(") != null);
}

test "template dependency extraction ignores parser-function and formula garbage" {
    const source =
        \\{{foo|x}}
        \\{{#if:1|{{bar baz}}}}
        \\{{{2ndauthor|}}}
        \\{{{{{1}}}|display}}
        \\{{CURRENTDAY}}
        \\{{#tag:ref|text}}
        \\{{e^x}}
        \\{{Template:quote-news|1}}
        \\{{safesubst:col3|a|b}}
    ;

    const deps = try extractTemplateDependenciesAlloc(std.testing.allocator, source, null);
    defer freeStringSlice(std.testing.allocator, deps);

    try std.testing.expectEqual(@as(usize, 4), deps.len);
    try std.testing.expectEqualStrings("barbaz", deps[0]);
    try std.testing.expectEqualStrings("col3", deps[1]);
    try std.testing.expectEqualStrings("foo", deps[2]);
    try std.testing.expectEqualStrings("quote-news", deps[3]);
}

test "template zig emission audit compiles reachable modules with stable output" {
    var sources = TemplateSources{
        .template_sources = std.StringHashMap([]const u8).init(std.testing.allocator),
        .module_sources = std.StringHashMap([]const u8).init(std.testing.allocator),
    };
    defer sources.deinit(std.testing.allocator);

    try putCanonicalTemplateSource(
        std.testing.allocator,
        &sources.template_sources,
        "demo",
        try std.testing.allocator.dupe(u8,
            \\{{#invoke:demo|main}}
            \\{{helper}}
        ),
    );
    try putCanonicalTemplateSource(
        std.testing.allocator,
        &sources.template_sources,
        "helper",
        try std.testing.allocator.dupe(u8, "plain helper text"),
    );
    try putCanonicalModuleSource(
        std.testing.allocator,
        &sources.module_sources,
        "demo",
        try std.testing.allocator.dupe(u8,
            \\local p = {}
            \\function p.main(frame)
            \\  local outer = 4
            \\  return outer + 1
            \\end
            \\return p
        ),
    );

    const template_names = [_][]const u8{"demo"};
    var report = try analyzeTemplateDependenciesFromSourcesAlloc(std.testing.allocator, &template_names, &sources);
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), report.root_templates.len);
    try std.testing.expectEqual(@as(usize, 2), report.reachable_templates.len);
    try std.testing.expectEqual(@as(usize, 0), report.unresolved_templates.len);
    try std.testing.expectEqual(@as(usize, 1), report.direct_modules.len);
    try std.testing.expectEqual(@as(usize, 1), report.transitive_modules.len);
    try std.testing.expectEqual(@as(usize, 1), report.compiled_ok.len);
    try std.testing.expectEqual(@as(usize, 0), report.compiled_failed.len);
    try std.testing.expectEqual(@as(usize, 1), report.emitted_consistent.len);
    try std.testing.expectEqual(@as(usize, 0), report.emitted_inconsistent.len);
    try std.testing.expectEqualStrings("demo", report.emitted_consistent[0]);
}

test "template zig emission audit separates missing modules from compile failures" {
    var sources = TemplateSources{
        .template_sources = std.StringHashMap([]const u8).init(std.testing.allocator),
        .module_sources = std.StringHashMap([]const u8).init(std.testing.allocator),
    };
    defer sources.deinit(std.testing.allocator);

    try putCanonicalTemplateSource(
        std.testing.allocator,
        &sources.template_sources,
        "broken",
        try std.testing.allocator.dupe(u8,
            \\{{#invoke:missing-module|main}}
            \\{{missing-helper}}
        ),
    );

    const template_names = [_][]const u8{ "broken", "missing-root" };
    var report = try analyzeTemplateDependenciesFromSourcesAlloc(std.testing.allocator, &template_names, &sources);
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), report.unresolved_templates.len);
    try std.testing.expectEqualStrings("missing-helper", report.unresolved_templates[0]);
    try std.testing.expectEqual(@as(usize, 0), report.emitted_consistent.len);
    try std.testing.expectEqual(@as(usize, 1), report.missing_modules.len);
    try std.testing.expectEqualStrings("missing-module", report.missing_modules[0]);
    try std.testing.expectEqual(@as(usize, 0), report.compiled_failed.len);
}

test "template zig emission audit skips non-lua modules without compile failures" {
    var sources = TemplateSources{
        .template_sources = std.StringHashMap([]const u8).init(std.testing.allocator),
        .module_sources = std.StringHashMap([]const u8).init(std.testing.allocator),
    };
    defer sources.deinit(std.testing.allocator);

    try putCanonicalTemplateSource(
        std.testing.allocator,
        &sources.template_sources,
        "docmod",
        try std.testing.allocator.dupe(u8, "\\{{#invoke:docmod|main}}"),
    );
    try putCanonicalModuleSource(
        std.testing.allocator,
        &sources.module_sources,
        "docmod",
        try std.testing.allocator.dupe(u8,
            \\This module is used by {{temp|docmod}}.
            \\==Documentation==
            \\* {{temp|demo}}
        ),
    );

    const template_names = [_][]const u8{"docmod"};
    var report = try analyzeTemplateDependenciesFromSourcesAlloc(std.testing.allocator, &template_names, &sources);
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), report.missing_modules.len);
    try std.testing.expectEqual(@as(usize, 0), report.compiled_failed.len);
    try std.testing.expectEqual(@as(usize, 0), report.emitted_inconsistent.len);
}

test "template zig emission audit still reports real compile failures" {
    var sources = TemplateSources{
        .template_sources = std.StringHashMap([]const u8).init(std.testing.allocator),
        .module_sources = std.StringHashMap([]const u8).init(std.testing.allocator),
    };
    defer sources.deinit(std.testing.allocator);

    try putCanonicalTemplateSource(
        std.testing.allocator,
        &sources.template_sources,
        "broken",
        try std.testing.allocator.dupe(u8, "\\{{#invoke:broken|main}}"),
    );
    try putCanonicalModuleSource(
        std.testing.allocator,
        &sources.module_sources,
        "broken",
        try std.testing.allocator.dupe(u8,
            \\local =
        ),
    );

    const template_names = [_][]const u8{"broken"};
    var report = try analyzeTemplateDependenciesFromSourcesAlloc(std.testing.allocator, &template_names, &sources);
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), report.missing_modules.len);
    try std.testing.expectEqual(@as(usize, 0), report.emitted_consistent.len);
    try std.testing.expectEqual(@as(usize, 1), report.compiled_failed.len);
    try std.testing.expectEqualStrings("broken", report.compiled_failed[0].name);
}

test "graph dependency analysis uses collected nodes without module audit" {
    var template_nodes = std.StringHashMap(TemplateDependencyNode).init(std.testing.allocator);
    defer {
        var it = template_nodes.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            freeStringSlice(std.testing.allocator, entry.value_ptr.template_deps);
            freeStringSlice(std.testing.allocator, entry.value_ptr.direct_modules);
        }
        template_nodes.deinit();
    }

    var module_nodes = std.StringHashMap([]const []const u8).init(std.testing.allocator);
    defer {
        var it = module_nodes.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            freeStringSlice(std.testing.allocator, entry.value_ptr.*);
        }
        module_nodes.deinit();
    }

    const demo_template_deps = try std.testing.allocator.alloc([]const u8, 1);
    demo_template_deps[0] = try std.testing.allocator.dupe(u8, "helper");
    const demo_direct_modules = try std.testing.allocator.alloc([]const u8, 1);
    demo_direct_modules[0] = try std.testing.allocator.dupe(u8, "templatemod");
    try template_nodes.put(
        try std.testing.allocator.dupe(u8, "demo"),
        .{
            .template_deps = demo_template_deps,
            .direct_modules = demo_direct_modules,
        },
    );

    try template_nodes.put(
        try std.testing.allocator.dupe(u8, "helper"),
        .{
            .template_deps = try std.testing.allocator.alloc([]const u8, 0),
            .direct_modules = try std.testing.allocator.alloc([]const u8, 0),
        },
    );

    const template_module_deps = try std.testing.allocator.alloc([]const u8, 1);
    template_module_deps[0] = try std.testing.allocator.dupe(u8, "sharedmod");
    try module_nodes.put(try std.testing.allocator.dupe(u8, "templatemod"), template_module_deps);
    try module_nodes.put(try std.testing.allocator.dupe(u8, "sharedmod"), try std.testing.allocator.alloc([]const u8, 0));

    const entry_direct_modules = try std.testing.allocator.alloc([]const u8, 1);
    defer freeStringSlice(std.testing.allocator, entry_direct_modules);
    entry_direct_modules[0] = try std.testing.allocator.dupe(u8, "entrymod");

    const template_names = [_][]const u8{"demo"};
    var report = try analyzeRenderDependenciesFromGraphAlloc(std.testing.allocator, &template_names, .{
        .entry_direct_modules = entry_direct_modules,
        .template_nodes = &template_nodes,
        .module_nodes = &module_nodes,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), report.root_templates.len);
    try std.testing.expectEqual(@as(usize, 2), report.reachable_templates.len);
    try std.testing.expectEqual(@as(usize, 0), report.unresolved_templates.len);
    try std.testing.expectEqual(@as(usize, 2), report.direct_modules.len);
    try std.testing.expectEqual(@as(usize, 3), report.transitive_modules.len);
    try std.testing.expectEqual(@as(usize, 1), report.missing_modules.len);
    try std.testing.expectEqualStrings("entrymod", report.missing_modules[0]);
    try std.testing.expectEqual(@as(usize, 0), report.compiled_failed.len);
    try std.testing.expectEqual(@as(usize, 0), report.emitted_inconsistent.len);
}

test "loadSelectedTemplateAndModuleSourcesByRefsAlloc loads only referenced pages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const xml_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/lua-source-refs.xml", .{tmp.sub_path});
    defer std.testing.allocator.free(xml_path);

    const xml =
        \\<mediawiki>
        \\<page><title>Template:demo</title><ns>10</ns><revision><text xml:space="preserve">{{helper}}</text></revision></page>
        \\<page><title>Template:unused</title><ns>10</ns><revision><text xml:space="preserve">unused</text></revision></page>
        \\<page><title>Module:demo</title><ns>828</ns><revision><text xml:space="preserve">return {}</text></revision></page>
        \\<page><title>Module:unused</title><ns>828</ns><revision><text xml:space="preserve">return { unused = true }</text></revision></page>
        \\</mediawiki>
    ;

    var file = try std.Io.Dir.cwd().createFile(std.testing.io, xml_path, .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, xml);

    const template_start = std.mem.indexOf(u8, xml, "<page><title>Template:demo</title>") orelse unreachable;
    const module_start = std.mem.indexOf(u8, xml, "<page><title>Module:demo</title>") orelse unreachable;
    const first_page_end = (std.mem.indexOfPos(u8, xml, template_start, "</page>") orelse unreachable) + "</page>".len;
    const second_page_end = (std.mem.indexOfPos(u8, xml, module_start, "</page>") orelse unreachable) + "</page>".len;

    var sources = try loadSelectedTemplateAndModuleSourcesByRefsAlloc(
        std.testing.allocator,
        xml_path,
        &.{.{ .name = "demo", .page_start = template_start, .page_end = first_page_end }},
        &.{.{ .name = "demo", .page_start = module_start, .page_end = second_page_end }},
    );
    defer sources.deinit(std.testing.allocator);

    // The loader appends a small synthetic compat set after loading the
    // requested pages, so the stable invariant is that requested XML pages are
    // present and unrequested XML pages are absent.
    try std.testing.expect(sources.template_sources.count() >= 1);
    try std.testing.expect(sources.module_sources.count() >= 1);
    try std.testing.expect(std.mem.indexOf(u8, sources.template_sources.get("demo").?, "{{helper}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, sources.module_sources.get("demo").?, "return {}") != null);
    try std.testing.expect(!sources.template_sources.contains("unused"));
    try std.testing.expect(!sources.module_sources.contains("unused"));
}

test "likely template page name filter keeps real titles and drops magic-like names" {
    try std.testing.expect(isLikelyTemplatePageName("quote-news"));
    try std.testing.expect(isLikelyTemplatePageName("Template:col3"));
    try std.testing.expect(!isLikelyTemplatePageName("#tag:ref"));
    try std.testing.expect(!isLikelyTemplatePageName("DISPLAYTITLE:<sup>x</sup>"));
    try std.testing.expect(!isLikelyTemplatePageName("e^x"));
}

test "likely code module page name filter excludes documentation pages" {
    try std.testing.expect(isLikelyCodeModulePageName("akk-conj/g/stem/testcases"));
    try std.testing.expect(!isLikelyCodeModulePageName("font list/style.css"));
    try std.testing.expect(!isLikelyCodeModulePageName("unicode data/raw/unicodedata.txt/bmp"));
    try std.testing.expect(!isLikelyCodeModulePageName("accel/documentation"));
    try std.testing.expect(!isLikelyCodeModulePageName("affix doc"));
}

test "template magic-name matcher ignores separators" {
    try std.testing.expect(isIgnoredTemplateMagicName("wikimedia language"));
    try std.testing.expect(isIgnoredTemplateMagicName("Wikimedia_language"));
    try std.testing.expect(isIgnoredTemplateMagicName("wikimedia-language"));
}

test "loadStructureTemplateNames prefers stored dependency roots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const structure_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/structure.json", .{tmp.sub_path});
    defer std.testing.allocator.free(structure_path);
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, structure_path, .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io,
        \\{
        \\  "dependencies": {
        \\    "root_templates": ["from-deps"]
        \\  },
        \\  "build": {
        \\    "line_templates": [{ "code": 1, "name": "from-build" }]
        \\  }
        \\}
    );

    const names = try loadStructureTemplateNames(std.testing.allocator, structure_path);
    defer freeStringSlice(std.testing.allocator, names);

    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("from-deps", names[0]);
}
