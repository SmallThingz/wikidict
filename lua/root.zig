const std = @import("std");
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

    pub fn init(allocator: std.mem.Allocator) GeneratedRuntime {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
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
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const owned_source = try a.dupe(u8, source);
    var parser = try Parser.init(a, owned_source);
    const body = parser.parseChunk() catch |err| {
        reportParseError(owned_source, &parser, err);
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

    try frame.putStringBorrowed("args", .{ .table = args_table });
    try frame.putStringBorrowed("getParent", try runtime.functionValue("frame.getParent", null, null, generatedFrameGetParent));
    try frame.putStringBorrowed("expandTemplate", try runtime.functionValue("frame.expandTemplate", null, null, generatedFrameExpandTemplate));
    return .{ .table = frame };
}

pub fn generatedInvoke(runtime: *GeneratedRuntime, callee: Value, args: []const Value) ![]Value {
    if (callee != .function) return error.InvalidCall;
    return switch (callee.function.kind) {
        .generated => |generated| try generated.invoke(generated.capture, generated.globals, runtime, args),
        else => error.InvalidCall,
    };
}

pub fn generatedCallFirst(runtime: *GeneratedRuntime, callee: Value, args: []const Value) !Value {
    const results = try generatedInvoke(runtime, callee, args);
    return if (results.len == 0) .nil else results[0];
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
    pairs,
    ipairs,
    string_len,
    string_lower,
    string_upper,
    string_sub,
    math_floor,
    math_ceil,
    math_abs,
    table_insert,
    table_concat,
};

const generated_builtin_print = GeneratedBuiltinKind.print;
const generated_builtin_tostring = GeneratedBuiltinKind.tostring;
const generated_builtin_tonumber = GeneratedBuiltinKind.tonumber;
const generated_builtin_type = GeneratedBuiltinKind.type_;
const generated_builtin_pairs = GeneratedBuiltinKind.pairs;
const generated_builtin_ipairs = GeneratedBuiltinKind.ipairs;
const generated_builtin_string_len = GeneratedBuiltinKind.string_len;
const generated_builtin_string_lower = GeneratedBuiltinKind.string_lower;
const generated_builtin_string_upper = GeneratedBuiltinKind.string_upper;
const generated_builtin_string_sub = GeneratedBuiltinKind.string_sub;
const generated_builtin_math_floor = GeneratedBuiltinKind.math_floor;
const generated_builtin_math_ceil = GeneratedBuiltinKind.math_ceil;
const generated_builtin_math_abs = GeneratedBuiltinKind.math_abs;
const generated_builtin_table_insert = GeneratedBuiltinKind.table_insert;
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

pub fn generatedBuiltinPairsValue(runtime: *GeneratedRuntime, globals: ?*anyopaque) !Value {
    return try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_pairs);
}

pub fn generatedBuiltinIpairsValue(runtime: *GeneratedRuntime, globals: ?*anyopaque) !Value {
    return try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_ipairs);
}

pub fn generatedBuiltinStringTableValue(runtime: *GeneratedRuntime, globals: ?*anyopaque) !Value {
    const table = try Table.init(runtime.alloc());
    try table.putString("len", try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_string_len));
    try table.putString("lower", try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_string_lower));
    try table.putString("upper", try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_string_upper));
    try table.putString("sub", try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_string_sub));
    return .{ .table = table };
}

pub fn generatedBuiltinMathTableValue(runtime: *GeneratedRuntime, globals: ?*anyopaque) !Value {
    const table = try Table.init(runtime.alloc());
    try table.putString("floor", try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_math_floor));
    try table.putString("ceil", try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_math_ceil));
    try table.putString("abs", try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_math_abs));
    return .{ .table = table };
}

pub fn generatedBuiltinTableTableValue(runtime: *GeneratedRuntime, globals: ?*anyopaque) !Value {
    const table = try Table.init(runtime.alloc());
    try table.putString("insert", try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_table_insert));
    try table.putString("concat", try generatedBuiltinFunctionValue(runtime, globals, &generated_builtin_table_concat));
    return .{ .table = table };
}

fn generatedBuiltinFunctionValue(
    runtime: *GeneratedRuntime,
    globals: ?*anyopaque,
    kind: *const GeneratedBuiltinKind,
) !Value {
    return try runtime.functionValue(@tagName(kind.*), @constCast(kind), globals, generatedBuiltinInvoke);
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
        .math_floor => try runtime.singleReturn(try generatedMathFloor(if (args.len == 0) .nil else args[0])),
        .math_ceil => try runtime.singleReturn(try generatedMathCeil(if (args.len == 0) .nil else args[0])),
        .math_abs => try runtime.singleReturn(try generatedMathAbs(if (args.len == 0) .nil else args[0])),
        .table_insert => blk: {
            _ = try generatedTableInsert(if (args.len == 0) .nil else args[0], if (args.len <= 1) .nil else args[1]);
            break :blk &.{};
        },
        .table_concat => try runtime.singleReturn(try generatedTableConcat(
            runtime,
            if (args.len == 0) .nil else args[0],
            if (args.len <= 1) null else args[1],
        )),
    };
}

pub fn emitZigModuleAlloc(allocator: std.mem.Allocator, chunk: *const Chunk) ![]u8 {
    return try emitDirectZigModuleAlloc(allocator, chunk);
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
        .number => |number| try writer.print("lua.Value{{ .number = {d} }}", .{number}),
        .string => |text| {
            try writer.writeAll("lua.Value{ .string = ");
            try writeZigStringLiteral(writer, text);
            try writer.writeAll(" }");
        },
        .table => |table| try writer.print("lua.Value{{ .table = try lua.cloneConstTableSeedAlloc(runtime.alloc(), &const_table_{d}) }}", .{state.tableId(table).?}),
        .function, .iterator => return error.UnsupportedSyntax,
    }
}

const TableSeedState = struct {
    allocator: std.mem.Allocator,
    table_ids: std.AutoHashMapUnmanaged(usize, u32) = .empty,
    tables: std.ArrayList(*const Table) = .empty,

    fn init(allocator: std.mem.Allocator) TableSeedState {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *TableSeedState) void {
        self.table_ids.deinit(self.allocator);
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
        const id: u32 = @intCast(self.tables.items.len);
        try self.table_ids.put(self.allocator, key, id);
        try self.tables.append(self.allocator, table);
        return id;
    }

    fn collectStmt(self: *TableSeedState, stmt: *const Stmt) std.mem.Allocator.Error!void {
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

    fn collectLValue(self: *TableSeedState, lvalue: LValue) std.mem.Allocator.Error!void {
        switch (lvalue) {
            .name => {},
            .field => |field| try self.collectExpr(field.object),
            .index => |index| {
                try self.collectExpr(index.object);
                try self.collectExpr(index.key);
            },
        }
    }

    fn collectExpr(self: *TableSeedState, expr: *const Expr) std.mem.Allocator.Error!void {
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
    tables: TableSeedState,
    functions: std.ArrayList(DirectFunctionInfo) = .empty,
    stmt_function_refs: std.ArrayList(DirectStmtFunctionRef) = .empty,
    expr_function_refs: std.ArrayList(DirectExprFunctionRef) = .empty,
    globals: std.ArrayList([]const u8) = .empty,
    top_id: u32 = 0,

    fn init(allocator: std.mem.Allocator) DirectModuleState {
        return .{
            .allocator = allocator,
            .tables = TableSeedState.init(allocator),
        };
    }

    fn deinit(self: *DirectModuleState) void {
        for (self.functions.items) |info| self.allocator.free(info.captures);
        self.functions.deinit(self.allocator);
        self.stmt_function_refs.deinit(self.allocator);
        self.expr_function_refs.deinit(self.allocator);
        self.globals.deinit(self.allocator);
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

fn analyzeDirectModule(state: *DirectModuleState, body: []const *Stmt) std.mem.Allocator.Error!void {
    for (body) |stmt| try state.tables.collectStmt(stmt);
    const top_id = try state.addFunction("chunk", &.{}, body, false);
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
            if (op.is_local and op.target == .name) try ctx.declareLocal(op.target.name);
            const child_id = try ctx.state.addFunction(switch (op.target) {
                .name => |name| name,
                .field => |field| field.name,
                .index => "anonymous",
            }, op.params, op.body, op.is_vararg);
            try ctx.state.addStmtFunctionRef(stmt, child_id);
            var child_ctx = DirectAnalyzeContext.init(ctx.state, ctx, child_id);
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
            const child_id = try ctx.state.addFunction("anonymous", func.params, func.body, func.is_vararg);
            try ctx.state.addExprFunctionRef(expr, child_id);
            var child_ctx = DirectAnalyzeContext.init(ctx.state, ctx, child_id);
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
    pairs,
    ipairs,
    string_len,
    string_lower,
    string_upper,
    string_sub,
    math_floor,
    math_ceil,
    math_abs,
    table_insert,
    table_concat,
};

const DirectEmitFunctionContext = struct {
    state: *const DirectModuleState,
    info: *const DirectFunctionInfo,
    uses_return_block: bool,
    local_used: []const bool,
    local_requires_var: []const bool,
    locals: std.ArrayList(DirectEmitLocalBinding) = .empty,
    scope_marks: std.ArrayList(usize) = .empty,
    next_local_id: u32 = 0,
    next_temp_id: u32 = 0,

    fn init(
        state: *const DirectModuleState,
        info: *const DirectFunctionInfo,
        uses_return_block: bool,
        local_used: []const bool,
        local_requires_var: []const bool,
    ) DirectEmitFunctionContext {
        return .{
            .state = state,
            .info = info,
            .uses_return_block = uses_return_block,
            .local_used = local_used,
            .local_requires_var = local_requires_var,
        };
    }

    fn deinit(self: *DirectEmitFunctionContext) void {
        self.locals.deinit(self.state.allocator);
        self.scope_marks.deinit(self.state.allocator);
        self.* = undefined;
    }

    fn beginScope(self: *DirectEmitFunctionContext) !void {
        try self.scope_marks.append(self.state.allocator, self.locals.items.len);
    }

    fn endScope(self: *DirectEmitFunctionContext) void {
        const mark = self.scope_marks.pop().?;
        self.locals.items.len = mark;
    }

    fn declareLocal(self: *DirectEmitFunctionContext, name: []const u8) !u32 {
        const id = self.next_local_id;
        self.next_local_id += 1;
        try self.locals.append(self.state.allocator, .{ .name = name, .id = id });
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
};

fn analyzeDirectFunctionLocalAnalysisAlloc(
    allocator: std.mem.Allocator,
    state: *const DirectModuleState,
    info: *const DirectFunctionInfo,
) AnalyzeDirectUseError!DirectLocalAnalysis {
    var ctx = DirectLocalUseContext.init(state, info);
    defer ctx.deinit();
    for (info.params) |param| _ = try ctx.declareLocal(param);
    try analyzeDirectUseStmtSlice(&ctx, info.body);
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
                    deferred[idx] = try collectPendingCapturedLocalsAlloc(ctx.state.allocator, ctx, &ctx.state.functions.items[child_id]);
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
                        try ctx.pending_local_function_captures.append(ctx.state.allocator, .{
                            .local_id = local_id,
                            .captured_locals = try collectPendingCapturedLocalsAlloc(
                                ctx.state.allocator,
                                ctx,
                                &ctx.state.functions.items[child_id],
                            ),
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

fn emitDirectZigModuleAlloc(allocator: std.mem.Allocator, chunk: *const Chunk) anyerror![]u8 {
    var state = DirectModuleState.init(allocator);
    defer state.deinit();
    try analyzeDirectModule(&state, chunk.body);

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
    for (state.functions.items) |info| try emitDirectFunction(writer, &state, &info);
    try emitDirectRun(writer, &state);
    const raw_source = try out.toOwnedSlice();
    errdefer allocator.free(raw_source);
    return stripUnusedGeneratedLocalsAlloc(allocator, raw_source);
}

fn emitDirectGlobals(writer: anytype, state: *const DirectModuleState) anyerror!void {
    try writer.writeAll("const Globals = struct {\n");
    for (state.globals.items, 0..) |name, idx| {
        try writer.print("    // global {s}\n    global_{d}: lua.Value = lua.Value.nil,\n", .{ name, idx });
    }
    try writer.writeAll("};\n\n");
}

fn emitDirectCaptureStruct(writer: anytype, info: *const DirectFunctionInfo) anyerror!void {
    try writer.print("const Capture_{d} = struct {{\n", .{info.id});
    for (info.captures, 0..) |capture, idx| {
        try writer.print("    // captures {s}\n    capture_{d}: *{s}lua.Value,\n", .{
            capture.name,
            idx,
            if (capture.mutable) "" else "const ",
        });
    }
    try writer.writeAll("};\n\n");
}

fn emitDirectRun(writer: anytype, state: *const DirectModuleState) anyerror!void {
    try writer.writeAll(
        \\pub fn run(allocator: std.mem.Allocator) !lua.GeneratedRunResult {
        \\    var runtime = lua.GeneratedRuntime.init(allocator);
        \\    errdefer runtime.deinit();
        \\    const globals = try runtime.alloc().create(Globals);
        \\    globals.* = .{};
        \\
    );
    for (state.globals.items, 0..) |name, idx| {
        _ = try emitBuiltinGlobalInit(writer, name, idx);
    }
    try writer.print("    const returns = try fn_{d}(null, globals, &runtime, &.{{}});\n", .{state.top_id});
    try writer.writeAll(
        \\    return .{
        \\        .runtime = runtime,
        \\        .returns = returns,
        \\    };
        \\}
        \\
    );
}

fn emitBuiltinGlobalInit(writer: anytype, name: []const u8, idx: usize) anyerror!bool {
    if (std.mem.eql(u8, name, "print")) {
        try writer.print("    globals.global_{d} = try lua.generatedBuiltinPrintValue(&runtime, globals);\n", .{idx});
        return true;
    }
    if (std.mem.eql(u8, name, "tostring")) {
        try writer.print("    globals.global_{d} = try lua.generatedBuiltinTostringValue(&runtime, globals);\n", .{idx});
        return true;
    }
    if (std.mem.eql(u8, name, "tonumber")) {
        try writer.print("    globals.global_{d} = try lua.generatedBuiltinTonumberValue(&runtime, globals);\n", .{idx});
        return true;
    }
    if (std.mem.eql(u8, name, "type")) {
        try writer.print("    globals.global_{d} = try lua.generatedBuiltinTypeValue(&runtime, globals);\n", .{idx});
        return true;
    }
    if (std.mem.eql(u8, name, "pairs")) {
        try writer.print("    globals.global_{d} = try lua.generatedBuiltinPairsValue(&runtime, globals);\n", .{idx});
        return true;
    }
    if (std.mem.eql(u8, name, "ipairs")) {
        try writer.print("    globals.global_{d} = try lua.generatedBuiltinIpairsValue(&runtime, globals);\n", .{idx});
        return true;
    }
    if (std.mem.eql(u8, name, "string")) {
        try writer.print("    globals.global_{d} = try lua.generatedBuiltinStringTableValue(&runtime, globals);\n", .{idx});
        return true;
    }
    if (std.mem.eql(u8, name, "math")) {
        try writer.print("    globals.global_{d} = try lua.generatedBuiltinMathTableValue(&runtime, globals);\n", .{idx});
        return true;
    }
    if (std.mem.eql(u8, name, "table")) {
        try writer.print("    globals.global_{d} = try lua.generatedBuiltinTableTableValue(&runtime, globals);\n", .{idx});
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
        .number => |number| try writer.print(".{{ .number = {d} }}", .{number}),
        .string => |text| {
            try writer.writeAll(".{ .string = ");
            try writeZigStringLiteral(writer, text);
            try writer.writeAll(" }");
        },
        .table => |table| try writer.print(".{{ .table = &const_table_{d} }}", .{state.tableId(table).?}),
        .function, .iterator => return error.UnsupportedSyntax,
    }
}

fn emitIndent(writer: anytype, depth: usize) anyerror!void {
    for (0..depth) |_| try writer.writeAll("    ");
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
    allocator.free(source);
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
    if (!std.mem.startsWith(u8, trimmed, "const local_")) return false;
    const type_marker = ": lua.Value = ";
    const marker_index = std.mem.indexOf(u8, trimmed, type_marker) orelse return false;
    if (trimmed.len == 0 or trimmed[trimmed.len - 1] != ';') return false;

    const token = trimmed["const ".len..marker_index];
    if (countGeneratedLocalOccurrencesInFunction(source, line_start, token) != 1) return false;

    try out.appendNTimes(allocator, ' ', prefix_len);
    try out.appendSlice(allocator, "_ = ");
    try out.appendSlice(allocator, trimmed[marker_index + type_marker.len .. trimmed.len - 1]);
    try out.appendSlice(allocator, ";");
    return true;
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

fn emitDirectFunction(writer: anytype, state: *const DirectModuleState, info: *const DirectFunctionInfo) anyerror!void {
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
    );
    defer ctx.deinit();

    for (info.params, 0..) |param, idx| {
        const local_id = try ctx.declareLocal(param);
        if (!localShouldEmit(&ctx, local_id)) continue;
        try emitIndent(writer, 1);
        try writer.print("{s} local_{d}: lua.Value = if (args.len > {d}) args[{d}] else @as(lua.Value, .nil);\n", .{
            localBindingKeyword(&ctx, local_id),
            local_id,
            idx,
            idx,
        });
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

            for (0..value_count) |idx| {
                temp_ids[idx] = ctx.nextTemp();
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
                try emitIndent(writer, depth);
                if (localShouldEmit(ctx, local_id)) {
                    try writer.print("{s} local_{d}: lua.Value = tmp_{d};\n", .{
                        localBindingKeyword(ctx, local_id),
                        local_id,
                        temp_ids[idx],
                    });
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

            for (0..value_count) |idx| {
                temp_ids[idx] = ctx.nextTemp();
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
                try emitStoreTarget(writer, ctx, op.targets[idx], temp_ids[idx], depth);
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
            if (op.is_local and op.target == .name) {
                const local_id = try ctx.declareLocal(op.target.name);
                if (!localShouldEmit(ctx, local_id)) return;
                try emitIndent(writer, depth);
                try writer.print("{s} local_{d}: lua.Value = lua.Value.nil;\n", .{
                    localBindingKeyword(ctx, local_id),
                    local_id,
                });
                try emitIndent(writer, depth);
                try writer.print("local_{d} = ", .{local_id});
                try emitFunctionValueExpr(writer, ctx, child_info, depth);
                try writer.writeAll(";\n");
            } else {
                const temp_id = ctx.nextTemp();
                try emitIndent(writer, depth);
                try writer.print("const tmp_{d}: lua.Value = ", .{temp_id});
                try emitFunctionValueExpr(writer, ctx, child_info, depth);
                try writer.writeAll(";\n");
                try emitStoreTarget(writer, ctx, op.target, temp_id, depth);
            }
        },
        .if_stmt => |op| {
            for (op.branches, 0..) |branch, idx| {
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
                try emitIndent(writer, depth);
                try writer.writeAll("}");
                if (idx + 1 == op.branches.len and op.else_body.len == 0) try writer.writeAll("\n");
            }
            if (op.else_body.len != 0) {
                if (op.branches.len == 0) {
                    try emitIndent(writer, depth);
                    try writer.writeAll("{\n");
                } else {
                    try writer.writeAll(" else {\n");
                }
                try ctx.beginScope();
                try emitStmtSlice(writer, ctx, op.else_body, depth + 1);
                ctx.endScope();
                try emitIndent(writer, depth);
                try writer.writeAll("}\n");
            }
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
            try emitIndent(writer, depth);
            try writer.writeAll("while ((");
            try emitExpr(writer, ctx, op.condition, depth);
            try writer.writeAll(").truthy()) {\n");
            try ctx.beginScope();
            try emitStmtSlice(writer, ctx, op.body, depth + 1);
            ctx.endScope();
            try emitIndent(writer, depth);
            try writer.writeAll("}\n");
        },
        .repeat_stmt => |op| {
            try emitIndent(writer, depth);
            try writer.writeAll("while (true) {\n");
            try ctx.beginScope();
            try emitStmtSlice(writer, ctx, op.body, depth + 1);
            try emitIndent(writer, depth + 1);
            try writer.writeAll("if ((");
            try emitExpr(writer, ctx, op.condition, depth + 1);
            try writer.writeAll(").truthy()) break;\n");
            ctx.endScope();
            try emitIndent(writer, depth);
            try writer.writeAll("}\n");
        },
        .numeric_for => |op| {
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
            try emitIndent(writer, depth + 1);
            try writer.print("{s} local_{d}: lua.Value = tmp_{d};\n", .{
                localBindingKeyword(ctx, loop_local),
                loop_local,
                start_temp,
            });
            try emitIndent(writer, depth + 1);
            try writer.writeAll("while (true) {\n");
            try ctx.beginScope();
            try emitStmtSlice(writer, ctx, op.body, depth + 2);
            ctx.endScope();
            try emitIndent(writer, depth + 2);
            try writer.print("const next_num = try lua.valueToNumberAlloc(local_{d}) + tmp_{d};\n", .{ loop_local, step_num_temp });
            try emitIndent(writer, depth + 2);
            try writer.print("local_{d} = lua.Value{{ .number = next_num }};\n", .{loop_local});
            try emitIndent(writer, depth + 2);
            try writer.print("if (!((tmp_{d} >= 0 and next_num <= try lua.valueToNumberAlloc(tmp_{d})) or (tmp_{d} < 0 and next_num >= try lua.valueToNumberAlloc(tmp_{d})))) break;\n", .{
                step_num_temp, limit_temp, step_num_temp, limit_temp,
            });
            try emitIndent(writer, depth + 1);
            try writer.writeAll("}\n");
            ctx.endScope();
            try emitIndent(writer, depth);
            try writer.writeAll("}\n");
        },
        .generic_for => |op| {
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
                    try writer.print("{s} local_{d}: lua.Value = pair_{d}[0];\n", .{
                        localBindingKeyword(ctx, local_id),
                        local_id,
                        pair_temp,
                    });
                } else if (idx == 1) {
                    try writer.print("{s} local_{d}: lua.Value = pair_{d}[1];\n", .{
                        localBindingKeyword(ctx, local_id),
                        local_id,
                        pair_temp,
                    });
                } else {
                    try writer.print("{s} local_{d}: lua.Value = lua.Value.nil;\n", .{
                        localBindingKeyword(ctx, local_id),
                        local_id,
                    });
                }
            }
            try emitStmtSlice(writer, ctx, op.body, depth + 1);
            ctx.endScope();
            try emitIndent(writer, depth);
            try writer.writeAll("}\n");
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

fn emitStoreTarget(writer: anytype, ctx: *DirectEmitFunctionContext, target: LValue, temp_id: u32, depth: usize) anyerror!void {
    switch (target) {
        .name => |name| {
            if (ctx.lookupLocal(name)) |local_id| {
                if (!ctx.local_used[local_id]) {
                    try emitIndent(writer, depth);
                    try writer.print("_ = tmp_{d};\n", .{temp_id});
                    return;
                }
                try emitIndent(writer, depth);
                try writer.print("local_{d} = tmp_{d};\n", .{ local_id, temp_id });
                return;
            }
            if (ctx.lookupCapture(name)) |capture_id| {
                try emitIndent(writer, depth);
                try writer.print("capture.capture_{d}.* = tmp_{d};\n", .{ capture_id, temp_id });
                return;
            }
            const global_id = ctx.state.globalId(name) orelse return error.UnknownVariable;
            try emitIndent(writer, depth);
            try writer.print("globals.global_{d} = tmp_{d};\n", .{ global_id, temp_id });
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
    const label_id = ctx.nextTemp();
    try writer.print("blk_{d}: {{\n", .{label_id});
    if (info.captures.len != 0) {
        try emitIndent(writer, depth + 1);
        try writer.print("const capture_obj = try runtime.alloc().create(Capture_{d});\n", .{info.id});
        try emitIndent(writer, depth + 1);
        try writer.writeAll("capture_obj.* = .{\n");
        for (info.captures, 0..) |capture, idx| {
            try emitIndent(writer, depth + 2);
            try writer.print(".capture_{d} = ", .{idx});
            switch (capture.origin) {
                .parent_local => {
                    const local_id = ctx.lookupLocal(capture.name) orelse return error.UnknownVariable;
                    try writer.print("&local_{d},\n", .{local_id});
                },
                .parent_capture => {
                    const capture_id = ctx.lookupCapture(capture.name) orelse return error.UnknownVariable;
                    try writer.print("capture.capture_{d},\n", .{capture_id});
                },
            }
        }
        try emitIndent(writer, depth + 1);
        try writer.writeAll("};\n");
        try emitIndent(writer, depth + 1);
        try writer.print("break :blk_{d} try runtime.functionValue(", .{label_id});
        try writeZigStringLiteral(writer, info.name);
        try writer.print(", capture_obj, globals, fn_{d});\n", .{info.id});
    } else {
        try emitIndent(writer, depth + 1);
        try writer.print("break :blk_{d} try runtime.functionValue(", .{label_id});
        try writeZigStringLiteral(writer, info.name);
        try writer.print(", null, globals, fn_{d});\n", .{info.id});
    }
    try emitIndent(writer, depth);
    try writer.writeAll("}");
}

fn emitExpr(writer: anytype, ctx: *DirectEmitFunctionContext, expr: *const Expr, depth: usize) anyerror!void {
    switch (expr.*) {
        .nil_lit => try writer.writeAll("lua.Value.nil"),
        .bool_lit => |value| try writer.print("lua.Value{{ .boolean = {} }}", .{value}),
        .number_lit => |value| try writer.print("lua.Value{{ .number = {d} }}", .{value}),
        .string_lit => |value| {
            try writer.writeAll("lua.Value{ .string = ");
            try writeZigStringLiteral(writer, value);
            try writer.writeAll(" }");
        },
        .variable => |name| {
            if (ctx.lookupLocal(name)) |local_id| {
                try writer.print("local_{d}", .{local_id});
            } else if (ctx.lookupCapture(name)) |capture_id| {
                try writer.print("capture.capture_{d}.*", .{capture_id});
            } else {
                const global_id = ctx.state.globalId(name) orelse return error.UnknownVariable;
                try writer.print("globals.global_{d}", .{global_id});
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
                    try emitIndent(writer, depth + 1);
                    try writer.print("try tmp_{d}.putString(", .{table_id});
                    try writeZigStringLiteral(writer, named.name);
                    try writer.writeAll(", ");
                    try emitExpr(writer, ctx, named.value, depth + 1);
                    try writer.writeAll(");\n");
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
            const label_id = ctx.nextTemp();
            const object_id = ctx.nextTemp();
            try writer.print("blk_{d}: {{ const tmp_{d} = ", .{ label_id, object_id });
            try emitExpr(writer, ctx, field.object, depth);
            try writer.print("; if (tmp_{d} != .table) return error.InvalidIndex; break :blk_{d} tmp_{d}.table.getString(", .{ object_id, label_id, object_id });
            try writeZigStringLiteral(writer, field.name);
            try writer.writeAll("); }");
        },
        .index => |index| {
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
            } else {
                const label_id = ctx.nextTemp();
                const callee_id = ctx.nextTemp();
                const results_id = ctx.nextTemp();
                try writer.print("blk_{d}: {{ const tmp_{d} = ", .{ label_id, callee_id });
                try emitExpr(writer, ctx, call.callee, depth);
                try writer.print("; const tmp_{d} = try lua.generatedInvoke(runtime, tmp_{d}, &.{{ ", .{ results_id, callee_id });
                for (call.args, 0..) |arg, idx| {
                    if (idx != 0) try writer.writeAll(", ");
                    try emitExpr(writer, ctx, arg, depth);
                }
                try writer.print(" }}); break :blk_{d} if (tmp_{d}.len == 0) @as(lua.Value, .nil) else tmp_{d}[0]; }}", .{ label_id, results_id, results_id });
            }
        },
        .function_lit => {
            const child_id = ctx.state.exprFunctionId(expr) orelse return error.UnsupportedSyntax;
            const child_info = &ctx.state.functions.items[child_id];
            try emitFunctionValueExpr(writer, ctx, child_info, depth);
        },
    }
}

fn matchBuiltinCall(call: @FieldType(Expr, "call")) ?DirectBuiltinCall {
    switch (call.callee.*) {
        .variable => |name| {
            if (std.mem.eql(u8, name, "print")) return .print;
            if (std.mem.eql(u8, name, "tostring")) return .tostring;
            if (std.mem.eql(u8, name, "tonumber")) return .tonumber;
            if (std.mem.eql(u8, name, "type")) return .type_;
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
                }
                if (std.mem.eql(u8, object_name, "math")) {
                    if (std.mem.eql(u8, field.name, "floor")) return .math_floor;
                    if (std.mem.eql(u8, field.name, "ceil")) return .math_ceil;
                    if (std.mem.eql(u8, field.name, "abs")) return .math_abs;
                }
                if (std.mem.eql(u8, object_name, "table")) {
                    if (std.mem.eql(u8, field.name, "insert")) return .table_insert;
                    if (std.mem.eql(u8, field.name, "concat")) return .table_concat;
                }
            },
            else => {},
        },
        else => {},
    }
    return null;
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

    fn init(allocator: std.mem.Allocator, source: []const u8) !Parser {
        return .{
            .allocator = allocator,
            .tokens = try lex(allocator, source),
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
    const template_names = try loadStructureTemplateNames(allocator, structure_json_path);
    var dump_scan = try scanDumpDependenciesAlloc(allocator, xml_path);
    defer dump_scan.deinit(allocator);
    const direct_modules = dump_scan.direct_modules;
    const module_sources = dump_scan.module_sources;

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

    const transitive_modules = try collectStringSet(allocator, &transitive);
    errdefer freeStringSlice(allocator, transitive_modules);
    var audit = try auditModuleNamesAlloc(allocator, &module_sources, transitive_modules);
    defer audit.deinit(allocator);

    dump_scan.direct_modules = &.{};
    dump_scan.module_sources = std.StringHashMap([]const u8).init(allocator);
    return .{
        .direct_templates = template_names,
        .direct_modules = direct_modules,
        .transitive_modules = transitive_modules,
        .missing_modules = try dupStringSliceAlloc(allocator, audit.missing_modules),
        .compiled_ok = try dupStringSliceAlloc(allocator, audit.compiled_ok),
        .compiled_failed = try dupFailureSliceAlloc(allocator, audit.compiled_failed),
        .emitted_consistent = try dupStringSliceAlloc(allocator, audit.emitted_consistent),
        .emitted_inconsistent = try dupFailureSliceAlloc(allocator, audit.emitted_inconsistent),
    };
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

        var first = compile(allocator, source) catch |err| {
            try appendFailureAlloc(allocator, &compiled_failed, name, @errorName(err));
            continue;
        };
        defer first.deinit();

        var second = compile(allocator, source) catch |err| {
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

fn loadStructureTemplateNames(allocator: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    const bytes = try readFileAlloc(allocator, path);
    defer allocator.free(bytes);
    const Report = struct {
        build: struct {
            line_templates: []const struct {
                name: []const u8,
            },
        },
    };
    var parsed = try std.json.parseFromSlice(Report, allocator, bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const out = try allocator.alloc([]const u8, parsed.value.build.line_templates.len);
    for (parsed.value.build.line_templates, 0..) |entry, idx| out[idx] = try allocator.dupe(u8, entry.name);
    return out;
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
                    try maybeStoreLuaSource(allocator, &template_sources, &module_sources, current_title, current_ns, text_accum.items);
                } else {
                    try text_accum.appendSlice(allocator, rest);
                    try text_accum.append(allocator, '\n');
                }
            }
        } else if (capture_text) {
            if (std.mem.indexOf(u8, line, "</text>")) |end_idx| {
                try text_accum.appendSlice(allocator, line[0..end_idx]);
                capture_text = false;
                try maybeStoreLuaSource(allocator, &template_sources, &module_sources, current_title, current_ns, text_accum.items);
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

fn applySourceCompat(
    allocator: std.mem.Allocator,
    template_sources: *std.StringHashMap([]const u8),
    module_sources: *std.StringHashMap([]const u8),
) !void {
    try ensureTemplateCompatSource(allocator, template_sources, "an-lite", &.{"an-lite/node"}, "{{{1|}}}");
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
    if (current_title == null or current_ns == null) return;
    const decoded = try xml_decode.decodeSinglePassAlloc(allocator, text);
    errdefer allocator.free(decoded);

    if (std.mem.eql(u8, current_ns.?, "10")) {
        if (!std.mem.startsWith(u8, current_title.?, "Template:")) return;
        const name = current_title.?["Template:".len..];
        try putCanonicalTemplateSource(allocator, template_sources, name, decoded);
        return;
    }

    if (!std.mem.eql(u8, current_ns.?, "828")) return;
    if (!std.mem.startsWith(u8, current_title.?, "Module:")) return;
    const name = current_title.?["Module:".len..];
    try putCanonicalModuleSource(allocator, module_sources, name, decoded);
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
        if (isLikelyModulePageName(name)) try insertCanonicalModuleName(set, allocator, name);
        cursor = name_end;
    }
}

fn extractTemplateDependenciesAlloc(
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

fn extractModuleDependencies(allocator: std.mem.Allocator, source: []const u8) ![]const []const u8 {
    var set = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &set);

    const tokens = lexQuiet(allocator, source) catch return allocator.alloc([]const u8, 0);
    defer freeTokenSlice(allocator, tokens);

    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const token = tokens[i];
        if (token.tag == .identifier and std.mem.eql(u8, token.lexeme, "require")) {
            if (extractModuleDependencyArg(tokens, i + 1)) |name| {
                if (isLikelyModulePageName(name)) try insertCanonicalModuleName(&set, allocator, name);
            }
            continue;
        }

        if (i + 3 >= tokens.len) continue;
        if (token.tag != .identifier or !std.mem.eql(u8, token.lexeme, "mw")) continue;
        if (tokens[i + 1].tag != .dot) continue;
        if (tokens[i + 2].tag != .identifier or !std.mem.eql(u8, tokens[i + 2].lexeme, "loadData")) continue;
        if (extractModuleDependencyArg(tokens, i + 3)) |name| {
            if (isLikelyModulePageName(name)) try insertCanonicalModuleName(&set, allocator, name);
        }
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
        "FULLPAGENAME",
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
        return if (startsWithIgnoreCase(text, "Module:")) text["Module:".len..] else null;
    }
    if (tokens[idx].tag == .string) {
        const text = tokens[idx].lexeme;
        return if (startsWithIgnoreCase(text, "Module:")) text["Module:".len..] else null;
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

    const trimmed = std.mem.trim(u8, name, " \t\r\n");
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
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
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
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "capture_obj") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "runtime.functionValue") != null);
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
    try std.testing.expect(!isLikelyCodeModulePageName("accel/documentation"));
    try std.testing.expect(!isLikelyCodeModulePageName("affix doc"));
}

test "template magic-name matcher ignores separators" {
    try std.testing.expect(isIgnoredTemplateMagicName("wikimedia language"));
    try std.testing.expect(isIgnoredTemplateMagicName("Wikimedia_language"));
    try std.testing.expect(isIgnoredTemplateMagicName("wikimedia-language"));
}
