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

    fn getNumber(self: *const Table, num: f64) Value {
        const int = floatToExactPositiveInt(num) orelse return .nil;
        if (int >= 1 and int <= self.array.items.len) return self.array.items[int - 1];
        return if (self.int_fields.get(@intCast(int))) |value| value else .nil;
    }

    fn putNumber(self: *Table, num: f64, value: Value) !void {
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

pub const Constant = union(enum) {
    number: f64,
    string: []const u8,
};

pub const UpvalueBinding = union(enum) {
    parent_local: u16,
    parent_upvalue: u16,
};

pub const Instruction = union(enum) {
    push_nil,
    push_bool: bool,
    push_const: u16,
    push_const_table: u16,
    load_local: u16,
    store_local: u16,
    load_upvalue: u16,
    store_upvalue: u16,
    load_global: u16,
    store_global: u16,
    load_vararg0,
    dup,
    pop,
    unary: UnaryOp,
    binary: BinaryOp,
    jump: u32,
    jump_if_false: u32,
    jump_if_true: u32,
    new_table,
    table_append,
    table_set_name: u16,
    table_set_dynamic,
    load_field_name: u16,
    store_field_name: u16,
    load_index,
    store_index,
    make_closure: u16,
    call: u16,
    return_: u16,
    iter_next: struct {
        iter_slot: u16,
        first_slot: u16,
        slot_count: u16,
        target: u32,
    },
    numeric_for_prep: struct {
        var_slot: u16,
        limit_slot: u16,
        step_slot: u16,
        target: u32,
    },
    numeric_for_loop: struct {
        var_slot: u16,
        limit_slot: u16,
        step_slot: u16,
        target: u32,
    },
};

const Prototype = struct {
    name: []const u8,
    params: u16,
    // Number of local slots reserved for parameters and block locals.
    local_count: u16,
    // Maximum operand stack depth required by this prototype.
    stack_size: u16,
    is_vararg: bool,
    code: []const Instruction,
    constants: []const Constant,
    // Hoisted constant table templates cloned on demand at runtime.
    const_tables: []const *const Table,
    child_protos: []const *Prototype,
    // Captured bindings resolved against the parent frame during compilation.
    upvalues: []const UpvalueBinding,
};

const Closure = struct {
    prototype: *const Prototype,
    upvalues: []const *Value,
};

pub const BuiltinGlobalSlots = struct {
    print: ?u16 = null,
    tostring: ?u16 = null,
    tonumber: ?u16 = null,
    type_: ?u16 = null,
    pairs: ?u16 = null,
    ipairs: ?u16 = null,
    string: ?u16 = null,
    math: ?u16 = null,
    table: ?u16 = null,
};

const BytecodeProgram = struct {
    top: *const Prototype,
    // Global slot count after compile-time name resolution.
    global_count: u16,
    builtins: BuiltinGlobalSlots,
};

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

pub const StaticPrototype = struct {
    name: []const u8,
    params: u16,
    local_count: u16,
    stack_size: u16,
    is_vararg: bool,
    code: []const Instruction,
    constants: []const Constant,
    const_tables: []const *const ConstTableSeed,
    child_protos: []const *const StaticPrototype,
    upvalues: []const UpvalueBinding,
};

pub const StaticProgram = struct {
    top: *const StaticPrototype,
    global_count: u16,
    builtins: BuiltinGlobalSlots,
};

const GlobalState = struct {
    values: []Value,
};

pub const FunctionKind = union(enum) {
    user: UserFunction,
    native: NativeFn,
    bytecode: *Closure,
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
            .name = try self.alloc().dupe(u8, name),
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
const BytecodeCompileError = CompileError || std.mem.Allocator.Error;

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
    stmt_function_ids: std.AutoHashMapUnmanaged(usize, u32) = .empty,
    expr_function_ids: std.AutoHashMapUnmanaged(usize, u32) = .empty,
    global_ids: std.StringHashMapUnmanaged(u32) = .empty,
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
        self.stmt_function_ids.deinit(self.allocator);
        self.expr_function_ids.deinit(self.allocator);
        self.global_ids.deinit(self.allocator);
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

    fn addGlobal(self: *DirectModuleState, name: []const u8) !u32 {
        if (self.global_ids.get(name)) |existing| return existing;
        const id: u32 = @intCast(self.globals.items.len);
        try self.global_ids.put(self.allocator, name, id);
        try self.globals.append(self.allocator, name);
        return id;
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
    captures: std.StringHashMapUnmanaged(DirectCaptureOrigin) = .empty,

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

    fn hasCapture(self: *const DirectAnalyzeContext, name: []const u8) bool {
        return self.captures.contains(name);
    }

    fn addCapture(self: *DirectAnalyzeContext, name: []const u8, origin: DirectCaptureOrigin) !void {
        const gop = try self.captures.getOrPut(self.state.allocator, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = name;
            gop.value_ptr.* = origin;
        }
    }

    fn ensureChildAccessible(self: *DirectAnalyzeContext, name: []const u8) !?ChildAccessKind {
        if (self.hasLocal(name)) return .local;
        if (self.hasCapture(name)) return .capture;
        const parent = self.parent orelse return null;
        const parent_kind = try parent.ensureChildAccessible(name) orelse return null;
        try self.addCapture(name, switch (parent_kind) {
            .local => .parent_local,
            .capture => .parent_capture,
        });
        return .capture;
    }

    fn resolveOwnReference(self: *DirectAnalyzeContext, name: []const u8) !void {
        if (self.hasLocal(name) or self.hasCapture(name)) return;
        const parent = self.parent orelse {
            _ = try self.state.addGlobal(name);
            return;
        };
        const parent_kind = try parent.ensureChildAccessible(name) orelse {
            _ = try self.state.addGlobal(name);
            return;
        };
        try self.addCapture(name, switch (parent_kind) {
            .local => .parent_local,
            .capture => .parent_capture,
        });
    }

    fn finish(self: *DirectAnalyzeContext) !void {
        const info = &self.state.functions.items[self.function_id];
        info.captures = try capturesToOwnedSlice(self.state.allocator, &self.captures);
    }
};

fn capturesToOwnedSlice(
    allocator: std.mem.Allocator,
    captures: *const std.StringHashMapUnmanaged(DirectCaptureOrigin),
) ![]const DirectCaptureInfo {
    const out = try allocator.alloc(DirectCaptureInfo, captures.count());
    var idx: usize = 0;
    var it = captures.iterator();
    while (it.next()) |entry| {
        out[idx] = .{
            .name = entry.key_ptr.*,
            .origin = entry.value_ptr.*,
        };
        idx += 1;
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
            try ctx.state.stmt_function_ids.put(ctx.state.allocator, @intFromPtr(stmt), child_id);
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
        .name => |name| try ctx.resolveOwnReference(name),
        .field => |field| try analyzeExpr(ctx, field.object),
        .index => |index| {
            try analyzeExpr(ctx, index.object);
            try analyzeExpr(ctx, index.key);
        },
    }
}

fn analyzeExpr(ctx: *DirectAnalyzeContext, expr: *const Expr) std.mem.Allocator.Error!void {
    switch (expr.*) {
        .variable => |name| try ctx.resolveOwnReference(name),
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
            try ctx.state.expr_function_ids.put(ctx.state.allocator, @intFromPtr(expr), child_id);
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
    locals: std.ArrayList(DirectEmitLocalBinding) = .empty,
    scope_marks: std.ArrayList(usize) = .empty,
    next_local_id: u32 = 0,
    next_temp_id: u32 = 0,

    fn init(state: *const DirectModuleState, info: *const DirectFunctionInfo, uses_return_block: bool) DirectEmitFunctionContext {
        return .{ .state = state, .info = info, .uses_return_block = uses_return_block };
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
    return out.toOwnedSlice();
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
        try writer.print("    // captures {s}\n    capture_{d}: *lua.Value,\n", .{ capture.name, idx });
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
    var ctx = DirectEmitFunctionContext.init(state, info, uses_return_block);
    defer ctx.deinit();

    for (info.params, 0..) |param, idx| {
        const local_id = try ctx.declareLocal(param);
        try emitIndent(writer, 1);
        try writer.print("var local_{d}: lua.Value = if (args.len > {d}) args[{d}] else @as(lua.Value, .nil);\n", .{ local_id, idx, idx });
        try emitIndent(writer, 1);
        try writer.print("local_{d} = local_{d};\n", .{ local_id, local_id });
    }
    if (info.is_vararg) {
        try emitIndent(writer, 1);
        try writer.print("const varargs = if (args.len > {d}) args[{d}..] else &.{{}};\n", .{ info.params.len, info.params.len });
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
                try writer.print("var local_{d}: lua.Value = tmp_{d};\n", .{ local_id, temp_ids[idx] });
                try emitIndent(writer, depth);
                try writer.print("local_{d} = local_{d};\n", .{ local_id, local_id });
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
            const child_id = ctx.state.stmt_function_ids.get(@intFromPtr(stmt)) orelse return error.UnsupportedSyntax;
            const child_info = &ctx.state.functions.items[child_id];
            if (op.is_local and op.target == .name) {
                const local_id = try ctx.declareLocal(op.target.name);
                try emitIndent(writer, depth);
                try writer.print("var local_{d}: lua.Value = lua.Value.nil;\n", .{local_id});
                try emitIndent(writer, depth);
                try writer.print("local_{d} = local_{d};\n", .{ local_id, local_id });
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
            try writer.print("var local_{d}: lua.Value = tmp_{d};\n", .{ loop_local, start_temp });
            try emitIndent(writer, depth + 1);
            try writer.print("local_{d} = local_{d};\n", .{ loop_local, loop_local });
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
            try emitIndent(writer, depth);
            try writer.print("var tmp_{d}: lua.Iterator = ", .{iter_temp});
            try emitIteratorInit(writer, ctx, op.iterator_exprs, depth);
            try writer.writeAll(";\n");
            try emitIndent(writer, depth);
            try writer.writeAll("while (try lua.generatedIteratorNext(&tmp_");
            try writer.print("{d}", .{iter_temp});
            try writer.print(")) |pair_{d}| {{\n", .{pair_temp});
            try ctx.beginScope();
            for (op.names, 0..) |name, idx| {
                const local_id = try ctx.declareLocal(name);
                try emitIndent(writer, depth + 1);
                if (idx == 0) {
                    try writer.print("var local_{d}: lua.Value = pair_{d}[0];\n", .{ local_id, pair_temp });
                } else if (idx == 1) {
                    try writer.print("var local_{d}: lua.Value = pair_{d}[1];\n", .{ local_id, pair_temp });
                } else {
                    try writer.print("var local_{d}: lua.Value = lua.Value.nil;\n", .{local_id});
                }
                try emitIndent(writer, depth + 1);
                try writer.print("local_{d} = local_{d};\n", .{ local_id, local_id });
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
                try emitIndent(writer, depth);
                try writer.print("local_{d} = tmp_{d};\n", .{ local_id, temp_id });
                return;
            }
            if (ctx.lookupCapture(name)) |capture_id| {
                try emitIndent(writer, depth);
                try writer.print("capture.capture_{d}.* = tmp_{d};\n", .{ capture_id, temp_id });
                return;
            }
            const global_id = ctx.state.global_ids.get(name) orelse return error.UnknownVariable;
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
                const global_id = ctx.state.global_ids.get(name) orelse return error.UnknownVariable;
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
            const child_id = ctx.state.expr_function_ids.get(@intFromPtr(expr)) orelse return error.UnsupportedSyntax;
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

const ZigEmitState = struct {
    allocator: std.mem.Allocator,
    table_ids: std.AutoHashMapUnmanaged(usize, u32) = .empty,
    tables: std.ArrayList(*const Table) = .empty,
    proto_ids: std.AutoHashMapUnmanaged(usize, u32) = .empty,
    protos: std.ArrayList(*const Prototype) = .empty,

    fn init(allocator: std.mem.Allocator) ZigEmitState {
        return .{ .allocator = allocator };
    }

    fn collectPrototype(self: *ZigEmitState, proto: *const Prototype) !u32 {
        const key = @intFromPtr(proto);
        if (self.proto_ids.get(key)) |existing| return existing;
        for (proto.const_tables) |table| _ = try self.collectTable(table);
        for (proto.child_protos) |child| _ = try self.collectPrototype(child);
        const id: u32 = @intCast(self.protos.items.len);
        try self.proto_ids.put(self.allocator, key, id);
        try self.protos.append(self.allocator, proto);
        return id;
    }

    fn collectTable(self: *ZigEmitState, table: *const Table) !u32 {
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

    fn tableId(self: *const ZigEmitState, table: *const Table) ?u32 {
        return self.table_ids.get(@intFromPtr(table));
    }

    fn prototypeId(self: *const ZigEmitState, proto: *const Prototype) ?u32 {
        return self.proto_ids.get(@intFromPtr(proto));
    }
};

fn emitConstTableSeed(writer: anytype, table: *const Table, state: *const ZigEmitState) !void {
    const id = state.tableId(table).?;
    try writer.print("const const_table_{d}_array = [_]lua.ConstValueSeed{{\n", .{id});
    for (table.array.items) |value| {
        try writer.writeAll("    ");
        try emitConstValueSeed(writer, value, state);
        try writer.writeAll(",\n");
    }
    try writer.writeAll("};\n");

    try writer.print("const const_table_{d}_string_fields = [_]lua.ConstTableStringFieldSeed{{\n", .{id});
    var string_it = table.string_fields.iterator();
    while (string_it.next()) |entry| {
        try writer.writeAll("    .{ .key = ");
        try writeZigStringLiteral(writer, entry.key_ptr.*);
        try writer.writeAll(", .value = ");
        try emitConstValueSeed(writer, entry.value_ptr.*, state);
        try writer.writeAll(" },\n");
    }
    try writer.writeAll("};\n");

    try writer.print("const const_table_{d}_int_fields = [_]lua.ConstTableIntFieldSeed{{\n", .{id});
    var int_it = table.int_fields.iterator();
    while (int_it.next()) |entry| {
        try writer.print("    .{{ .key = {d}, .value = ", .{entry.key_ptr.*});
        try emitConstValueSeed(writer, entry.value_ptr.*, state);
        try writer.writeAll(" },\n");
    }
    try writer.writeAll("};\n");

    try writer.print(
        "const const_table_{d} = lua.ConstTableSeed{{ .array = &const_table_{d}_array, .string_fields = &const_table_{d}_string_fields, .int_fields = &const_table_{d}_int_fields }};\n\n",
        .{ id, id, id, id },
    );
}

fn emitConstValueSeed(writer: anytype, value: Value, state: *const ZigEmitState) !void {
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

fn emitStaticPrototype(writer: anytype, proto: *const Prototype, state: *const ZigEmitState) !void {
    const id = state.prototypeId(proto).?;
    try writer.print("const proto_{d}_code = [_]lua.Instruction{{\n", .{id});
    for (proto.code) |inst| {
        try writer.writeAll("    ");
        try emitInstructionLiteral(writer, inst);
        try writer.writeAll(",\n");
    }
    try writer.writeAll("};\n");

    try writer.print("const proto_{d}_constants = [_]lua.Constant{{\n", .{id});
    for (proto.constants) |constant| {
        try writer.writeAll("    ");
        try emitConstantLiteral(writer, constant);
        try writer.writeAll(",\n");
    }
    try writer.writeAll("};\n");

    try writer.print("const proto_{d}_const_tables = [_]*const lua.ConstTableSeed{{\n", .{id});
    for (proto.const_tables) |table| try writer.print("    &const_table_{d},\n", .{state.tableId(table).?});
    try writer.writeAll("};\n");

    try writer.print("const proto_{d}_child_protos = [_]*const lua.StaticPrototype{{\n", .{id});
    for (proto.child_protos) |child| try writer.print("    &proto_{d},\n", .{state.prototypeId(child).?});
    try writer.writeAll("};\n");

    try writer.print("const proto_{d}_upvalues = [_]lua.UpvalueBinding{{\n", .{id});
    for (proto.upvalues) |binding| {
        try writer.writeAll("    ");
        try emitUpvalueBindingLiteral(writer, binding);
        try writer.writeAll(",\n");
    }
    try writer.writeAll("};\n");

    try writer.print("pub const proto_{d} = lua.StaticPrototype{{\n", .{id});
    try writer.writeAll("    .name = ");
    try writeZigStringLiteral(writer, proto.name);
    try writer.writeAll(",\n");
    try writer.print("    .params = {d},\n", .{proto.params});
    try writer.print("    .local_count = {d},\n", .{proto.local_count});
    try writer.print("    .stack_size = {d},\n", .{proto.stack_size});
    try writer.print("    .is_vararg = {},\n", .{proto.is_vararg});
    try writer.print("    .code = &proto_{d}_code,\n", .{id});
    try writer.print("    .constants = &proto_{d}_constants,\n", .{id});
    try writer.print("    .const_tables = &proto_{d}_const_tables,\n", .{id});
    try writer.print("    .child_protos = &proto_{d}_child_protos,\n", .{id});
    try writer.print("    .upvalues = &proto_{d}_upvalues,\n", .{id});
    try writer.writeAll("};\n\n");
}

fn emitConstantLiteral(writer: anytype, constant: Constant) !void {
    switch (constant) {
        .number => |value| try writer.print(".{{ .number = {d} }}", .{value}),
        .string => |value| {
            try writer.writeAll(".{ .string = ");
            try writeZigStringLiteral(writer, value);
            try writer.writeAll(" }");
        },
    }
}

fn emitUpvalueBindingLiteral(writer: anytype, binding: UpvalueBinding) !void {
    switch (binding) {
        .parent_local => |slot| try writer.print(".{{ .parent_local = {d} }}", .{slot}),
        .parent_upvalue => |slot| try writer.print(".{{ .parent_upvalue = {d} }}", .{slot}),
    }
}

fn emitInstructionLiteral(writer: anytype, inst: Instruction) !void {
    switch (inst) {
        .push_nil => try writer.writeAll(".push_nil"),
        .push_bool => |value| try writer.print(".{{ .push_bool = {} }}", .{value}),
        .push_const => |value| try writer.print(".{{ .push_const = {d} }}", .{value}),
        .push_const_table => |value| try writer.print(".{{ .push_const_table = {d} }}", .{value}),
        .load_local => |value| try writer.print(".{{ .load_local = {d} }}", .{value}),
        .store_local => |value| try writer.print(".{{ .store_local = {d} }}", .{value}),
        .load_upvalue => |value| try writer.print(".{{ .load_upvalue = {d} }}", .{value}),
        .store_upvalue => |value| try writer.print(".{{ .store_upvalue = {d} }}", .{value}),
        .load_global => |value| try writer.print(".{{ .load_global = {d} }}", .{value}),
        .store_global => |value| try writer.print(".{{ .store_global = {d} }}", .{value}),
        .load_vararg0 => try writer.writeAll(".load_vararg0"),
        .dup => try writer.writeAll(".dup"),
        .pop => try writer.writeAll(".pop"),
        .unary => |op| try writer.print(".{{ .unary = .{s} }}", .{@tagName(op)}),
        .binary => |op| try writer.print(".{{ .binary = .{s} }}", .{@tagName(op)}),
        .jump => |target| try writer.print(".{{ .jump = {d} }}", .{target}),
        .jump_if_false => |target| try writer.print(".{{ .jump_if_false = {d} }}", .{target}),
        .jump_if_true => |target| try writer.print(".{{ .jump_if_true = {d} }}", .{target}),
        .new_table => try writer.writeAll(".new_table"),
        .table_append => try writer.writeAll(".table_append"),
        .table_set_name => |value| try writer.print(".{{ .table_set_name = {d} }}", .{value}),
        .table_set_dynamic => try writer.writeAll(".table_set_dynamic"),
        .load_field_name => |value| try writer.print(".{{ .load_field_name = {d} }}", .{value}),
        .store_field_name => |value| try writer.print(".{{ .store_field_name = {d} }}", .{value}),
        .load_index => try writer.writeAll(".load_index"),
        .store_index => try writer.writeAll(".store_index"),
        .make_closure => |value| try writer.print(".{{ .make_closure = {d} }}", .{value}),
        .call => |value| try writer.print(".{{ .call = {d} }}", .{value}),
        .return_ => |value| try writer.print(".{{ .return_ = {d} }}", .{value}),
        .iter_next => |op| try writer.print(
            ".{{ .iter_next = .{{ .iter_slot = {d}, .first_slot = {d}, .slot_count = {d}, .target = {d} }} }}",
            .{ op.iter_slot, op.first_slot, op.slot_count, op.target },
        ),
        .numeric_for_prep => |op| try writer.print(
            ".{{ .numeric_for_prep = .{{ .var_slot = {d}, .limit_slot = {d}, .step_slot = {d}, .target = {d} }} }}",
            .{ op.var_slot, op.limit_slot, op.step_slot, op.target },
        ),
        .numeric_for_loop => |op| try writer.print(
            ".{{ .numeric_for_loop = .{{ .var_slot = {d}, .limit_slot = {d}, .step_slot = {d}, .target = {d} }} }}",
            .{ op.var_slot, op.limit_slot, op.step_slot, op.target },
        ),
    }
}

fn emitBuiltinSlots(writer: anytype, slots: BuiltinGlobalSlots) !void {
    try writer.writeAll(".{");
    if (slots.print) |slot| try writer.print(" .print = {d},", .{slot});
    if (slots.tostring) |slot| try writer.print(" .tostring = {d},", .{slot});
    if (slots.tonumber) |slot| try writer.print(" .tonumber = {d},", .{slot});
    if (slots.type_) |slot| try writer.print(" .type_ = {d},", .{slot});
    if (slots.pairs) |slot| try writer.print(" .pairs = {d},", .{slot});
    if (slots.ipairs) |slot| try writer.print(" .ipairs = {d},", .{slot});
    if (slots.string) |slot| try writer.print(" .string = {d},", .{slot});
    if (slots.math) |slot| try writer.print(" .math = {d},", .{slot});
    if (slots.table) |slot| try writer.print(" .table = {d},", .{slot});
    try writer.writeAll(" }");
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

const ResolvedRef = union(enum) {
    local: u16,
    upvalue: u16,
    global: u16,
};

const LocalBinding = struct {
    name: []const u8,
    slot: u16,
    depth: usize,
};

const LoopContext = struct {
    break_patches: std.ArrayList(usize) = .empty,
};

const ProgramBuilder = struct {
    allocator: std.mem.Allocator,
    globals: std.ArrayList([]const u8) = .empty,
    global_map: std.StringHashMapUnmanaged(u16) = .empty,
    builtins: BuiltinGlobalSlots = .{},

    fn init(allocator: std.mem.Allocator) ProgramBuilder {
        return .{ .allocator = allocator };
    }

    fn globalSlot(self: *ProgramBuilder, name: []const u8) BytecodeCompileError!u16 {
        if (self.global_map.get(name)) |slot| return slot;
        const slot = try castU16(self.globals.items.len);
        const gop = try self.global_map.getOrPut(self.allocator, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = name;
            gop.value_ptr.* = slot;
            try self.globals.append(self.allocator, name);
            self.recordBuiltinSlot(name, slot);
        }
        return gop.value_ptr.*;
    }

    fn recordBuiltinSlot(self: *ProgramBuilder, name: []const u8, slot: u16) void {
        if (std.mem.eql(u8, name, "print")) self.builtins.print = slot;
        if (std.mem.eql(u8, name, "tostring")) self.builtins.tostring = slot;
        if (std.mem.eql(u8, name, "tonumber")) self.builtins.tonumber = slot;
        if (std.mem.eql(u8, name, "type")) self.builtins.type_ = slot;
        if (std.mem.eql(u8, name, "pairs")) self.builtins.pairs = slot;
        if (std.mem.eql(u8, name, "ipairs")) self.builtins.ipairs = slot;
        if (std.mem.eql(u8, name, "string")) self.builtins.string = slot;
        if (std.mem.eql(u8, name, "math")) self.builtins.math = slot;
        if (std.mem.eql(u8, name, "table")) self.builtins.table = slot;
    }
};

const ProtoBuilder = struct {
    allocator: std.mem.Allocator,
    program: *ProgramBuilder,
    parent: ?*ProtoBuilder,
    name: []const u8,
    params: u16,
    is_vararg: bool,
    code: std.ArrayList(Instruction) = .empty,
    constants: std.ArrayList(Constant) = .empty,
    const_tables: std.ArrayList(*const Table) = .empty,
    child_protos: std.ArrayList(*Prototype) = .empty,
    upvalues: std.ArrayList(UpvalueBinding) = .empty,
    string_consts: std.StringHashMapUnmanaged(u16) = .empty,
    locals: std.ArrayList(LocalBinding) = .empty,
    loop_stack: std.ArrayList(LoopContext) = .empty,
    scope_depth: usize = 0,
    next_slot: u16 = 0,
    max_slot: u16 = 0,
    stack_depth: i32 = 0,
    max_stack: u16 = 0,

    fn init(allocator: std.mem.Allocator, program: *ProgramBuilder, parent: ?*ProtoBuilder, name: []const u8, params: u16, is_vararg: bool) ProtoBuilder {
        return .{
            .allocator = allocator,
            .program = program,
            .parent = parent,
            .name = name,
            .params = params,
            .is_vararg = is_vararg,
        };
    }

    fn declareLocal(self: *ProtoBuilder, name: []const u8) BytecodeCompileError!u16 {
        const slot = self.next_slot;
        self.next_slot = try castU16(@as(usize, slot) + 1);
        if (self.next_slot > self.max_slot) self.max_slot = self.next_slot;
        try self.locals.append(self.allocator, .{
            .name = name,
            .slot = slot,
            .depth = self.scope_depth,
        });
        return slot;
    }

    fn beginScope(self: *ProtoBuilder) void {
        self.scope_depth += 1;
    }

    fn endScope(self: *ProtoBuilder) void {
        const next_depth = self.scope_depth - 1;
        while (self.locals.items.len != 0 and self.locals.items[self.locals.items.len - 1].depth > next_depth) {
            _ = self.locals.pop();
        }
        self.scope_depth = next_depth;
    }

    fn emit(self: *ProtoBuilder, inst: Instruction, stack_delta: i32) BytecodeCompileError!usize {
        try self.code.append(self.allocator, inst);
        self.stack_depth += stack_delta;
        if (self.stack_depth < 0) return error.UnsupportedSyntax;
        if (self.stack_depth > self.max_stack) self.max_stack = try castU16(@intCast(self.stack_depth));
        return self.code.items.len - 1;
    }

    fn patchJump(self: *ProtoBuilder, pc: usize, target: usize) BytecodeCompileError!void {
        const cast_target = try castU32(target);
        switch (self.code.items[pc]) {
            .jump => self.code.items[pc] = .{ .jump = cast_target },
            .jump_if_false => self.code.items[pc] = .{ .jump_if_false = cast_target },
            .jump_if_true => self.code.items[pc] = .{ .jump_if_true = cast_target },
            .iter_next => |op| self.code.items[pc] = .{ .iter_next = .{
                .iter_slot = op.iter_slot,
                .first_slot = op.first_slot,
                .slot_count = op.slot_count,
                .target = cast_target,
            } },
            .numeric_for_prep => |op| self.code.items[pc] = .{ .numeric_for_prep = .{
                .var_slot = op.var_slot,
                .limit_slot = op.limit_slot,
                .step_slot = op.step_slot,
                .target = cast_target,
            } },
            .numeric_for_loop => |op| self.code.items[pc] = .{ .numeric_for_loop = .{
                .var_slot = op.var_slot,
                .limit_slot = op.limit_slot,
                .step_slot = op.step_slot,
                .target = cast_target,
            } },
            else => return error.UnsupportedSyntax,
        }
    }

    fn stringConst(self: *ProtoBuilder, text: []const u8) BytecodeCompileError!u16 {
        if (self.string_consts.get(text)) |idx| return idx;
        const idx = try castU16(self.constants.items.len);
        try self.constants.append(self.allocator, .{ .string = text });
        const gop = try self.string_consts.getOrPut(self.allocator, text);
        if (!gop.found_existing) {
            gop.key_ptr.* = text;
            gop.value_ptr.* = idx;
        }
        return idx;
    }

    fn numberConst(self: *ProtoBuilder, number: f64) BytecodeCompileError!u16 {
        const idx = try castU16(self.constants.items.len);
        try self.constants.append(self.allocator, .{ .number = number });
        return idx;
    }

    fn constTable(self: *ProtoBuilder, table: *const Table) BytecodeCompileError!u16 {
        const idx = try castU16(self.const_tables.items.len);
        try self.const_tables.append(self.allocator, table);
        return idx;
    }

    fn addChildProto(self: *ProtoBuilder, proto: *Prototype) BytecodeCompileError!u16 {
        const idx = try castU16(self.child_protos.items.len);
        try self.child_protos.append(self.allocator, proto);
        return idx;
    }

    fn resolveName(self: *ProtoBuilder, name: []const u8) BytecodeCompileError!ResolvedRef {
        var idx = self.locals.items.len;
        while (idx != 0) {
            idx -= 1;
            const local = self.locals.items[idx];
            if (std.mem.eql(u8, local.name, name)) return .{ .local = local.slot };
        }
        if (self.parent != null) {
            if (try self.resolveUpvalue(name)) |slot| return .{ .upvalue = slot };
        }
        return .{ .global = try self.program.globalSlot(name) };
    }

    fn resolveUpvalue(self: *ProtoBuilder, name: []const u8) BytecodeCompileError!?u16 {
        const parent = self.parent orelse return null;
        var idx = parent.locals.items.len;
        while (idx != 0) {
            idx -= 1;
            const local = parent.locals.items[idx];
            if (std.mem.eql(u8, local.name, name)) return try self.addUpvalue(.{ .parent_local = local.slot });
        }
        if (try parent.resolveUpvalue(name)) |slot| return try self.addUpvalue(.{ .parent_upvalue = slot });
        return null;
    }

    fn addUpvalue(self: *ProtoBuilder, binding: UpvalueBinding) BytecodeCompileError!u16 {
        for (self.upvalues.items, 0..) |existing, idx| {
            switch (existing) {
                .parent_local => |slot| switch (binding) {
                    .parent_local => |other| if (slot == other) return try castU16(idx),
                    else => {},
                },
                .parent_upvalue => |slot| switch (binding) {
                    .parent_upvalue => |other| if (slot == other) return try castU16(idx),
                    else => {},
                },
            }
        }
        const idx = try castU16(self.upvalues.items.len);
        try self.upvalues.append(self.allocator, binding);
        return idx;
    }

    fn pushLoop(self: *ProtoBuilder) BytecodeCompileError!void {
        try self.loop_stack.append(self.allocator, .{});
    }

    fn recordBreak(self: *ProtoBuilder, pc: usize) BytecodeCompileError!void {
        if (self.loop_stack.items.len == 0) return error.UnsupportedSyntax;
        try self.loop_stack.items[self.loop_stack.items.len - 1].break_patches.append(self.allocator, pc);
    }

    fn patchLoopBreaks(self: *ProtoBuilder, target: usize) BytecodeCompileError!void {
        const ctx = self.loop_stack.pop().?;
        for (ctx.break_patches.items) |pc| try self.patchJump(pc, target);
    }

    fn finish(self: *ProtoBuilder) BytecodeCompileError!*Prototype {
        const proto = try self.allocator.create(Prototype);
        proto.* = .{
            .name = self.name,
            .params = self.params,
            .local_count = self.max_slot,
            .stack_size = self.max_stack,
            .is_vararg = self.is_vararg,
            .code = try self.code.toOwnedSlice(self.allocator),
            .constants = try self.constants.toOwnedSlice(self.allocator),
            .const_tables = try self.const_tables.toOwnedSlice(self.allocator),
            .child_protos = try self.child_protos.toOwnedSlice(self.allocator),
            .upvalues = try self.upvalues.toOwnedSlice(self.allocator),
        };
        return proto;
    }
};

fn compileBytecodeProgram(allocator: std.mem.Allocator, body: []const *Stmt) BytecodeCompileError!*BytecodeProgram {
    var program_builder = ProgramBuilder.init(allocator);
    var builder = ProtoBuilder.init(allocator, &program_builder, null, "chunk", 0, false);
    try compileStmtSlice(&builder, body);
    _ = try builder.emit(.{ .return_ = 0 }, 0);
    const top = try builder.finish();
    const program = try allocator.create(BytecodeProgram);
    program.* = .{
        .top = top,
        .global_count = try castU16(program_builder.globals.items.len),
        .builtins = program_builder.builtins,
    };
    return program;
}

fn compileChildPrototype(
    allocator: std.mem.Allocator,
    program: *ProgramBuilder,
    parent: *ProtoBuilder,
    name: []const u8,
    params: []const []const u8,
    body: []const *Stmt,
    is_vararg: bool,
) BytecodeCompileError!*Prototype {
    var builder = ProtoBuilder.init(allocator, program, parent, name, try castU16(params.len), is_vararg);
    for (params) |param| _ = try builder.declareLocal(param);
    try compileStmtSlice(&builder, body);
    _ = try builder.emit(.{ .return_ = 0 }, 0);
    return builder.finish();
}

fn compileStmtSlice(builder: *ProtoBuilder, stmts: []const *Stmt) BytecodeCompileError!void {
    for (stmts) |stmt| try compileStmtBytecode(builder, stmt);
}

fn compileStmtBytecode(builder: *ProtoBuilder, stmt: *const Stmt) BytecodeCompileError!void {
    switch (stmt.*) {
        .local_assign => |op| {
            try compileExprList(builder, op.exprs);
            if (op.exprs.len > op.names.len) {
                for (0..op.exprs.len - op.names.len) |_| _ = try builder.emit(.pop, -1);
            } else if (op.exprs.len < op.names.len) {
                for (0..op.names.len - op.exprs.len) |_| _ = try builder.emit(.push_nil, 1);
            }
            const slots = try builder.allocator.alloc(u16, op.names.len);
            for (op.names, 0..) |name, idx| slots[idx] = try builder.declareLocal(name);
            var idx = op.names.len;
            while (idx != 0) {
                idx -= 1;
                _ = try builder.emit(.{ .store_local = slots[idx] }, -1);
            }
        },
        .assign => |op| {
            try compileExprList(builder, op.exprs);
            if (op.exprs.len > op.targets.len) {
                for (0..op.exprs.len - op.targets.len) |_| _ = try builder.emit(.pop, -1);
            } else if (op.exprs.len < op.targets.len) {
                for (0..op.targets.len - op.exprs.len) |_| _ = try builder.emit(.push_nil, 1);
            }
            var idx = op.targets.len;
            while (idx != 0) {
                idx -= 1;
                try compileStoreTarget(builder, op.targets[idx]);
            }
        },
        .function_def => |op| {
            const fn_name = switch (op.target) {
                .name => |name| name,
                .field => |field| field.name,
                .index => "anonymous",
            };
            if (op.is_local and op.target == .name) {
                const slot = try builder.declareLocal(op.target.name);
                const proto = try compileChildPrototype(builder.allocator, builder.program, builder, fn_name, op.params, op.body, op.is_vararg);
                const child_idx = try builder.addChildProto(proto);
                _ = try builder.emit(.{ .make_closure = child_idx }, 1);
                _ = try builder.emit(.{ .store_local = slot }, -1);
            } else {
                const proto = try compileChildPrototype(builder.allocator, builder.program, builder, fn_name, op.params, op.body, op.is_vararg);
                const child_idx = try builder.addChildProto(proto);
                _ = try builder.emit(.{ .make_closure = child_idx }, 1);
                try compileStoreTarget(builder, op.target);
            }
        },
        .if_stmt => |op| {
            var end_jumps: std.ArrayList(usize) = .empty;
            for (op.branches) |branch| {
                try compileExprBytecode(builder, branch.condition);
                const branch_skip = try builder.emit(.{ .jump_if_false = 0 }, -1);
                builder.beginScope();
                try compileStmtSlice(builder, branch.body);
                builder.endScope();
                try end_jumps.append(builder.allocator, try builder.emit(.{ .jump = 0 }, 0));
                try builder.patchJump(branch_skip, builder.code.items.len);
            }
            builder.beginScope();
            try compileStmtSlice(builder, op.else_body);
            builder.endScope();
            for (end_jumps.items) |jump_pc| try builder.patchJump(jump_pc, builder.code.items.len);
        },
        .do_block => |body| {
            builder.beginScope();
            try compileStmtSlice(builder, body);
            builder.endScope();
        },
        .while_stmt => |op| {
            const loop_start = builder.code.items.len;
            try compileExprBytecode(builder, op.condition);
            const exit_jump = try builder.emit(.{ .jump_if_false = 0 }, -1);
            try builder.pushLoop();
            builder.beginScope();
            try compileStmtSlice(builder, op.body);
            builder.endScope();
            _ = try builder.emit(.{ .jump = try castU32(loop_start) }, 0);
            const end_pc = builder.code.items.len;
            try builder.patchJump(exit_jump, end_pc);
            try builder.patchLoopBreaks(end_pc);
        },
        .repeat_stmt => |op| {
            const loop_start = builder.code.items.len;
            try builder.pushLoop();
            builder.beginScope();
            try compileStmtSlice(builder, op.body);
            builder.endScope();
            try compileExprBytecode(builder, op.condition);
            _ = try builder.emit(.{ .jump_if_false = try castU32(loop_start) }, -1);
            try builder.patchLoopBreaks(builder.code.items.len);
        },
        .numeric_for => |op| {
            try compileExprBytecode(builder, op.start);
            try compileExprBytecode(builder, op.finish);
            if (op.step) |step| {
                try compileExprBytecode(builder, step);
            } else {
                const one_idx = try builder.numberConst(1);
                _ = try builder.emit(.{ .push_const = one_idx }, 1);
            }
            builder.beginScope();
            const loop_var = try builder.declareLocal(op.name);
            const limit_slot = try builder.declareLocal("__limit");
            const step_slot = try builder.declareLocal("__step");
            _ = try builder.emit(.{ .store_local = step_slot }, -1);
            _ = try builder.emit(.{ .store_local = limit_slot }, -1);
            _ = try builder.emit(.{ .store_local = loop_var }, -1);
            const prep_jump = try builder.emit(.{ .numeric_for_prep = .{
                .var_slot = loop_var,
                .limit_slot = limit_slot,
                .step_slot = step_slot,
                .target = 0,
            } }, 0);
            const loop_body = builder.code.items.len;
            try builder.pushLoop();
            builder.beginScope();
            try compileStmtSlice(builder, op.body);
            builder.endScope();
            _ = try builder.emit(.{ .numeric_for_loop = .{
                .var_slot = loop_var,
                .limit_slot = limit_slot,
                .step_slot = step_slot,
                .target = try castU32(loop_body),
            } }, 0);
            const end_pc = builder.code.items.len;
            try builder.patchJump(prep_jump, end_pc);
            try builder.patchLoopBreaks(end_pc);
            builder.endScope();
        },
        .generic_for => |op| {
            try compileExprList(builder, op.iterator_exprs);
            if (op.iterator_exprs.len > 1) {
                for (0..op.iterator_exprs.len - 1) |_| _ = try builder.emit(.pop, -1);
            } else if (op.iterator_exprs.len == 0) {
                _ = try builder.emit(.push_nil, 1);
            }
            builder.beginScope();
            const iter_slot = try builder.declareLocal("__iter");
            _ = try builder.emit(.{ .store_local = iter_slot }, -1);
            const first_slot = if (op.names.len == 0) try builder.declareLocal("__iter_tmp") else try builder.declareLocal(op.names[0]);
            if (op.names.len > 1) {
                for (op.names[1..]) |name| _ = try builder.declareLocal(name);
            }
            const loop_pc = builder.code.items.len;
            const iter_jump = try builder.emit(.{ .iter_next = .{
                .iter_slot = iter_slot,
                .first_slot = first_slot,
                .slot_count = if (op.names.len == 0) 0 else try castU16(op.names.len),
                .target = 0,
            } }, 0);
            try builder.pushLoop();
            builder.beginScope();
            try compileStmtSlice(builder, op.body);
            builder.endScope();
            _ = try builder.emit(.{ .jump = try castU32(loop_pc) }, 0);
            const end_pc = builder.code.items.len;
            try builder.patchJump(iter_jump, end_pc);
            try builder.patchLoopBreaks(end_pc);
            builder.endScope();
        },
        .return_stmt => |op| {
            try compileExprList(builder, op.exprs);
            _ = try builder.emit(.{ .return_ = try castU16(op.exprs.len) }, -@as(i32, @intCast(op.exprs.len)));
        },
        .break_stmt => {
            const break_pc = try builder.emit(.{ .jump = 0 }, 0);
            try builder.recordBreak(break_pc);
        },
        .expr_stmt => |expr| {
            try compileExprBytecode(builder, expr);
            _ = try builder.emit(.pop, -1);
        },
    }
}

fn compileExprList(builder: *ProtoBuilder, exprs: []const *Expr) BytecodeCompileError!void {
    for (exprs) |expr| try compileExprBytecode(builder, expr);
}

fn compileExprBytecode(builder: *ProtoBuilder, expr: *const Expr) BytecodeCompileError!void {
    switch (expr.*) {
        .nil_lit => _ = try builder.emit(.push_nil, 1),
        .bool_lit => |value| _ = try builder.emit(.{ .push_bool = value }, 1),
        .number_lit => |value| {
            const idx = try builder.numberConst(value);
            _ = try builder.emit(.{ .push_const = idx }, 1);
        },
        .string_lit => |value| {
            const idx = try builder.stringConst(value);
            _ = try builder.emit(.{ .push_const = idx }, 1);
        },
        .variable => |name| {
            switch (try builder.resolveName(name)) {
                .local => |slot| _ = try builder.emit(.{ .load_local = slot }, 1),
                .upvalue => |slot| _ = try builder.emit(.{ .load_upvalue = slot }, 1),
                .global => |slot| _ = try builder.emit(.{ .load_global = slot }, 1),
            }
        },
        .varargs => _ = try builder.emit(.load_vararg0, 1),
        .unary => |op| {
            try compileExprBytecode(builder, op.expr);
            _ = try builder.emit(.{ .unary = op.op }, 0);
        },
        .binary => |op| switch (op.op) {
            .and_ => {
                try compileExprBytecode(builder, op.lhs);
                _ = try builder.emit(.dup, 1);
                const short_jump = try builder.emit(.{ .jump_if_false = 0 }, -1);
                _ = try builder.emit(.pop, -1);
                try compileExprBytecode(builder, op.rhs);
                try builder.patchJump(short_jump, builder.code.items.len);
            },
            .or_ => {
                try compileExprBytecode(builder, op.lhs);
                _ = try builder.emit(.dup, 1);
                const short_jump = try builder.emit(.{ .jump_if_true = 0 }, -1);
                _ = try builder.emit(.pop, -1);
                try compileExprBytecode(builder, op.rhs);
                try builder.patchJump(short_jump, builder.code.items.len);
            },
            else => {
                try compileExprBytecode(builder, op.lhs);
                try compileExprBytecode(builder, op.rhs);
                _ = try builder.emit(.{ .binary = op.op }, -1);
            },
        },
        .table_ctor => |fields| {
            _ = try builder.emit(.new_table, 1);
            for (fields) |field| {
                switch (field) {
                    .array => |value| {
                        try compileExprBytecode(builder, value);
                        _ = try builder.emit(.table_append, -1);
                    },
                    .named => |named| {
                        try compileExprBytecode(builder, named.value);
                        const name_idx = try builder.stringConst(named.name);
                        _ = try builder.emit(.{ .table_set_name = name_idx }, -1);
                    },
                    .indexed => |indexed| {
                        try compileExprBytecode(builder, indexed.key);
                        try compileExprBytecode(builder, indexed.value);
                        _ = try builder.emit(.table_set_dynamic, -2);
                    },
                }
            }
        },
        .const_table => |table| {
            const idx = try builder.constTable(table);
            _ = try builder.emit(.{ .push_const_table = idx }, 1);
        },
        .field => |field| {
            try compileExprBytecode(builder, field.object);
            const name_idx = try builder.stringConst(field.name);
            _ = try builder.emit(.{ .load_field_name = name_idx }, 0);
        },
        .index => |index| {
            try compileExprBytecode(builder, index.object);
            try compileExprBytecode(builder, index.key);
            _ = try builder.emit(.load_index, -1);
        },
        .call => |call| {
            try compileExprBytecode(builder, call.callee);
            try compileExprList(builder, call.args);
            _ = try builder.emit(.{ .call = try castU16(call.args.len) }, -@as(i32, @intCast(call.args.len)));
        },
        .function_lit => |func| {
            const proto = try compileChildPrototype(builder.allocator, builder.program, builder, "anonymous", func.params, func.body, func.is_vararg);
            const child_idx = try builder.addChildProto(proto);
            _ = try builder.emit(.{ .make_closure = child_idx }, 1);
        },
    }
}

fn compileStoreTarget(builder: *ProtoBuilder, target: LValue) BytecodeCompileError!void {
    switch (target) {
        .name => |name| switch (try builder.resolveName(name)) {
            .local => |slot| _ = try builder.emit(.{ .store_local = slot }, -1),
            .upvalue => |slot| _ = try builder.emit(.{ .store_upvalue = slot }, -1),
            .global => |slot| _ = try builder.emit(.{ .store_global = slot }, -1),
        },
        .field => |field| {
            try compileExprBytecode(builder, field.object);
            const name_idx = try builder.stringConst(field.name);
            _ = try builder.emit(.{ .store_field_name = name_idx }, -2);
        },
        .index => |index| {
            try compileExprBytecode(builder, index.object);
            try compileExprBytecode(builder, index.key);
            _ = try builder.emit(.store_index, -3);
        },
    }
}

fn castU16(value: usize) BytecodeCompileError!u16 {
    if (value > std.math.maxInt(u16)) return error.UnsupportedSyntax;
    return @intCast(value);
}

fn castU32(value: usize) BytecodeCompileError!u32 {
    if (value > std.math.maxInt(u32)) return error.UnsupportedSyntax;
    return @intCast(value);
}

fn formatBytecodeAlloc(allocator: std.mem.Allocator, program: *const BytecodeProgram) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try formatPrototypeBytecode(&out, allocator, program.top, 0);
    return out.toOwnedSlice(allocator);
}

fn formatPrototypeBytecode(out: *std.ArrayList(u8), allocator: std.mem.Allocator, proto: *const Prototype, depth: usize) !void {
    try appendIndent(out, allocator, depth);
    try out.print(allocator, "prototype {s} params={} locals={} stack={}\n", .{
        proto.name,
        proto.params,
        proto.local_count,
        proto.stack_size,
    });
    for (proto.code, 0..) |inst, pc| {
        try appendIndent(out, allocator, depth + 1);
        try out.print(allocator, "{d:>4} {s}", .{ pc, @tagName(inst) });
        switch (inst) {
            .push_bool => |value| try out.print(allocator, " {}", .{value}),
            .push_const,
            .push_const_table,
            .load_local,
            .store_local,
            .load_upvalue,
            .store_upvalue,
            .load_global,
            .store_global,
            .jump,
            .jump_if_false,
            .jump_if_true,
            .table_set_name,
            .load_field_name,
            .store_field_name,
            .make_closure,
            .call,
            .return_,
            => |value| try out.print(allocator, " {}", .{value}),
            .unary => |op| try out.print(allocator, " {s}", .{@tagName(op)}),
            .binary => |op| try out.print(allocator, " {s}", .{@tagName(op)}),
            .iter_next => |op| try out.print(allocator, " iter={} first={} count={} target={}", .{
                op.iter_slot,
                op.first_slot,
                op.slot_count,
                op.target,
            }),
            .numeric_for_prep => |op| try out.print(allocator, " var={} limit={} step={} target={}", .{
                op.var_slot,
                op.limit_slot,
                op.step_slot,
                op.target,
            }),
            .numeric_for_loop => |op| try out.print(allocator, " var={} limit={} step={} target={}", .{
                op.var_slot,
                op.limit_slot,
                op.step_slot,
                op.target,
            }),
            else => {},
        }
        try out.appendSlice(allocator, "\n");
    }
    for (proto.child_protos) |child| try formatPrototypeBytecode(out, allocator, child, depth + 1);
}

fn appendIndent(out: *std.ArrayList(u8), allocator: std.mem.Allocator, depth: usize) !void {
    for (0..depth) |_| try out.appendSlice(allocator, "  ");
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
                            reportLexErrorAt(source, i, error.UnexpectedEof);
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
            '+' => { try tokens.append(allocator, .{ .tag = .plus, .lexeme = source[i .. i + 1] }); i += 1; },
            '*' => { try tokens.append(allocator, .{ .tag = .star, .lexeme = source[i .. i + 1] }); i += 1; },
            '/' => { try tokens.append(allocator, .{ .tag = .slash, .lexeme = source[i .. i + 1] }); i += 1; },
            '%' => { try tokens.append(allocator, .{ .tag = .percent, .lexeme = source[i .. i + 1] }); i += 1; },
            '^' => { try tokens.append(allocator, .{ .tag = .caret, .lexeme = source[i .. i + 1] }); i += 1; },
            '#' => { try tokens.append(allocator, .{ .tag = .hash, .lexeme = source[i .. i + 1] }); i += 1; },
            '(' => { try tokens.append(allocator, .{ .tag = .lparen, .lexeme = source[i .. i + 1] }); i += 1; },
            ')' => { try tokens.append(allocator, .{ .tag = .rparen, .lexeme = source[i .. i + 1] }); i += 1; },
            '{' => { try tokens.append(allocator, .{ .tag = .lbrace, .lexeme = source[i .. i + 1] }); i += 1; },
            '}' => { try tokens.append(allocator, .{ .tag = .rbrace, .lexeme = source[i .. i + 1] }); i += 1; },
            '[' => {
                if (detectLongBracketStart(source, i)) |long_bracket| {
                    const end = findLongBracketEnd(source, long_bracket.content_start, long_bracket.eq_count) orelse {
                        reportLexErrorAt(source, i, error.UnexpectedEof);
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
            ']' => { try tokens.append(allocator, .{ .tag = .rbracket, .lexeme = source[i .. i + 1] }); i += 1; },
            ',' => { try tokens.append(allocator, .{ .tag = .comma, .lexeme = source[i .. i + 1] }); i += 1; },
            ';' => { try tokens.append(allocator, .{ .tag = .semi, .lexeme = source[i .. i + 1] }); i += 1; },
            ':' => { try tokens.append(allocator, .{ .tag = .colon, .lexeme = source[i .. i + 1] }); i += 1; },
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
                    reportLexErrorAt(source, i, error.UnexpectedToken);
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
                    reportLexErrorAt(source, start - 1, error.UnexpectedEof);
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
                    reportLexErrorAt(source, i, error.UnexpectedToken);
                    return error.UnexpectedToken;
                }
            },
        }
    }
    try tokens.append(allocator, .{ .tag = .eof, .lexeme = "" });
    return tokens.toOwnedSlice(allocator);
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

const Frame = struct {
    closure: *Closure,
    locals: []Value,
    stack: []Value,
    sp: usize = 0,
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

    fn createGlobalState(self: *Vm, program: *const BytecodeProgram) !*GlobalState {
        const globals = try self.alloc().create(GlobalState);
        globals.* = .{
            .values = try self.alloc().alloc(Value, program.global_count),
        };
        for (globals.values) |*slot| slot.* = .nil;
        return globals;
    }

    fn installBuiltinGlobals(self: *Vm, globals: *GlobalState, slots: BuiltinGlobalSlots) !void {
        if (slots.print) |slot| globals.values[slot] = .{ .function = try self.nativeFunction("print", builtinPrint) };
        if (slots.tostring) |slot| globals.values[slot] = .{ .function = try self.nativeFunction("tostring", builtinTostring) };
        if (slots.tonumber) |slot| globals.values[slot] = .{ .function = try self.nativeFunction("tonumber", builtinTonumber) };
        if (slots.type_) |slot| globals.values[slot] = .{ .function = try self.nativeFunction("type", builtinType) };
        if (slots.pairs) |slot| globals.values[slot] = .{ .function = try self.nativeFunction("pairs", builtinPairs) };
        if (slots.ipairs) |slot| globals.values[slot] = .{ .function = try self.nativeFunction("ipairs", builtinIpairs) };

        if (slots.string) |slot| {
            const string_table = try Table.init(self.alloc());
            try string_table.putString("len", .{ .function = try self.nativeFunction("string.len", builtinStringLen) });
            try string_table.putString("lower", .{ .function = try self.nativeFunction("string.lower", builtinStringLower) });
            try string_table.putString("upper", .{ .function = try self.nativeFunction("string.upper", builtinStringUpper) });
            try string_table.putString("sub", .{ .function = try self.nativeFunction("string.sub", builtinStringSub) });
            globals.values[slot] = .{ .table = string_table };
        }

        if (slots.math) |slot| {
            const math_table = try Table.init(self.alloc());
            try math_table.putString("floor", .{ .function = try self.nativeFunction("math.floor", builtinMathFloor) });
            try math_table.putString("ceil", .{ .function = try self.nativeFunction("math.ceil", builtinMathCeil) });
            try math_table.putString("abs", .{ .function = try self.nativeFunction("math.abs", builtinMathAbs) });
            globals.values[slot] = .{ .table = math_table };
        }

        if (slots.table) |slot| {
            const table_table = try Table.init(self.alloc());
            try table_table.putString("insert", .{ .function = try self.nativeFunction("table.insert", builtinTableInsert) });
            try table_table.putString("concat", .{ .function = try self.nativeFunction("table.concat", builtinTableConcat) });
            globals.values[slot] = .{ .table = table_table };
        }
    }

    fn createTopClosure(self: *Vm, proto: *const Prototype) !*Closure {
        const closure = try self.alloc().create(Closure);
        closure.* = .{
            .prototype = proto,
            .upvalues = try self.alloc().alloc(*Value, 0),
        };
        return closure;
    }

    fn createChildClosure(self: *Vm, proto: *const Prototype, parent_closure: *Closure, parent_frame: *Frame) !*Closure {
        const closure = try self.alloc().create(Closure);
        const upvalues = try self.alloc().alloc(*Value, proto.upvalues.len);
        for (proto.upvalues, 0..) |binding, idx| {
            upvalues[idx] = switch (binding) {
                .parent_local => |slot| &parent_frame.locals[slot],
                .parent_upvalue => |slot| parent_closure.upvalues[slot],
            };
        }
        closure.* = .{
            .prototype = proto,
            .upvalues = upvalues,
        };
        return closure;
    }

    fn bytecodeFunction(self: *Vm, name: []const u8, closure: *Closure) !*Function {
        const function = try self.alloc().create(Function);
        function.* = .{
            .name = try self.alloc().dupe(u8, name),
            .kind = .{ .bytecode = closure },
            .env = null,
        };
        return function;
    }

    fn pushFrameValue(self: *Vm, frame: *Frame, value: Value) !void {
        _ = self;
        if (frame.sp >= frame.stack.len) return error.UnsupportedSyntax;
        frame.stack[frame.sp] = value;
        frame.sp += 1;
    }

    fn popFrameValue(self: *Vm, frame: *Frame) !Value {
        _ = self;
        if (frame.sp == 0) return error.UnsupportedSyntax;
        frame.sp -= 1;
        return frame.stack[frame.sp];
    }

    fn executeClosure(self: *Vm, globals: *GlobalState, closure: *Closure, args: []const Value) EvalError![]Value {
        const proto = closure.prototype;
        const frame = try self.alloc().create(Frame);
        frame.* = .{
            .closure = closure,
            .locals = try self.alloc().alloc(Value, proto.local_count),
            .stack = try self.alloc().alloc(Value, proto.stack_size),
            .varargs = if (proto.is_vararg and args.len > proto.params)
                try self.alloc().dupe(Value, args[proto.params..])
            else
                &.{},
        };
        for (frame.locals) |*slot| slot.* = .nil;
        for (0..proto.params) |idx| {
            frame.locals[idx] = if (idx < args.len) args[idx] else .nil;
        }

        var pc: usize = 0;
        while (pc < proto.code.len) {
            const inst = proto.code[pc];
            pc += 1;
            switch (inst) {
                .push_nil => try self.pushFrameValue(frame, .nil),
                .push_bool => |value| try self.pushFrameValue(frame, .{ .boolean = value }),
                .push_const => |idx| try self.pushFrameValue(frame, constantToValue(proto.constants[idx])),
                .push_const_table => |idx| try self.pushFrameValue(frame, .{ .table = try cloneConstTableTemplateAlloc(self.alloc(), proto.const_tables[idx]) }),
                .load_local => |slot| try self.pushFrameValue(frame, frame.locals[slot]),
                .store_local => |slot| frame.locals[slot] = try self.popFrameValue(frame),
                .load_upvalue => |slot| try self.pushFrameValue(frame, frame.closure.upvalues[slot].*),
                .store_upvalue => |slot| frame.closure.upvalues[slot].* = try self.popFrameValue(frame),
                .load_global => |slot| try self.pushFrameValue(frame, globals.values[slot]),
                .store_global => |slot| globals.values[slot] = try self.popFrameValue(frame),
                .load_vararg0 => try self.pushFrameValue(frame, if (frame.varargs.len != 0) frame.varargs[0] else .nil),
                .dup => {
                    if (frame.sp == 0) return error.UnsupportedSyntax;
                    try self.pushFrameValue(frame, frame.stack[frame.sp - 1]);
                },
                .pop => _ = try self.popFrameValue(frame),
                .unary => |op| {
                    const value = try self.popFrameValue(frame);
                    try self.pushFrameValue(frame, try executeUnaryValue(op, value));
                },
                .binary => |op| {
                    const rhs = try self.popFrameValue(frame);
                    const lhs = try self.popFrameValue(frame);
                    try self.pushFrameValue(frame, try executeBinaryValue(self.alloc(), op, lhs, rhs));
                },
                .jump => |target| pc = target,
                .jump_if_false => |target| {
                    const value = try self.popFrameValue(frame);
                    if (!value.truthy()) pc = target;
                },
                .jump_if_true => |target| {
                    const value = try self.popFrameValue(frame);
                    if (value.truthy()) pc = target;
                },
                .new_table => try self.pushFrameValue(frame, .{ .table = try Table.init(self.alloc()) }),
                .table_append => {
                    const value = try self.popFrameValue(frame);
                    if (frame.sp == 0 or frame.stack[frame.sp - 1] != .table) return error.InvalidIndex;
                    try frame.stack[frame.sp - 1].table.array.append(self.alloc(), value);
                },
                .table_set_name => |name_idx| {
                    const value = try self.popFrameValue(frame);
                    if (frame.sp == 0 or frame.stack[frame.sp - 1] != .table) return error.InvalidIndex;
                    try frame.stack[frame.sp - 1].table.putString(constantString(proto.constants[name_idx]), value);
                },
                .table_set_dynamic => {
                    const value = try self.popFrameValue(frame);
                    const key = try self.popFrameValue(frame);
                    if (frame.sp == 0 or frame.stack[frame.sp - 1] != .table) return error.InvalidIndex;
                    try frame.stack[frame.sp - 1].table.set(key, value);
                },
                .load_field_name => |name_idx| {
                    const object = try self.popFrameValue(frame);
                    if (object != .table) return error.InvalidIndex;
                    try self.pushFrameValue(frame, object.table.getString(constantString(proto.constants[name_idx])));
                },
                .store_field_name => |name_idx| {
                    const object = try self.popFrameValue(frame);
                    const value = try self.popFrameValue(frame);
                    if (object != .table) return error.InvalidIndex;
                    try object.table.putString(constantString(proto.constants[name_idx]), value);
                },
                .load_index => {
                    const key = try self.popFrameValue(frame);
                    const object = try self.popFrameValue(frame);
                    if (object != .table) return error.InvalidIndex;
                    try self.pushFrameValue(frame, object.table.get(key));
                },
                .store_index => {
                    const key = try self.popFrameValue(frame);
                    const object = try self.popFrameValue(frame);
                    const value = try self.popFrameValue(frame);
                    if (object != .table) return error.InvalidIndex;
                    try object.table.set(key, value);
                },
                .make_closure => |child_idx| {
                    const child_closure = try self.createChildClosure(proto.child_protos[child_idx], frame.closure, frame);
                    try self.pushFrameValue(frame, .{ .function = try self.bytecodeFunction(proto.child_protos[child_idx].name, child_closure) });
                },
                .call => |arg_count| {
                    if (frame.sp < arg_count + 1) return error.UnsupportedSyntax;
                    const callee = frame.stack[frame.sp - arg_count - 1];
                    const call_args = frame.stack[frame.sp - arg_count .. frame.sp];
                    const results = try self.invokeResolvedFunction(globals, callee, call_args);
                    frame.sp -= arg_count + 1;
                    try self.pushFrameValue(frame, if (results.len == 0) .nil else results[0]);
                },
                .return_ => |count| {
                    if (count == 0) return &.{};
                    if (frame.sp < count) return error.UnsupportedSyntax;
                    const out = try self.alloc().alloc(Value, count);
                    @memcpy(out, frame.stack[frame.sp - count .. frame.sp]);
                    return out;
                },
                .iter_next => |op| {
                    const iterator_value = frame.locals[op.iter_slot];
                    if (iterator_value != .iterator) return error.UnsupportedGenericFor;
                    var iterator = iterator_value.iterator;
                    const pair = try self.iteratorNext(&iterator);
                    frame.locals[op.iter_slot] = .{ .iterator = iterator };
                    if (pair == null) {
                        pc = op.target;
                    } else {
                        for (0..op.slot_count) |idx| frame.locals[op.first_slot + idx] = .nil;
                        if (op.slot_count >= 1) frame.locals[op.first_slot] = pair.?[0];
                        if (op.slot_count >= 2) frame.locals[op.first_slot + 1] = pair.?[1];
                    }
                },
                .numeric_for_prep => |op| {
                    const current = try valueToNumber(frame.locals[op.var_slot]);
                    const limit = try valueToNumber(frame.locals[op.limit_slot]);
                    const step = try valueToNumber(frame.locals[op.step_slot]);
                    if ((step >= 0 and current > limit) or (step < 0 and current < limit)) pc = op.target;
                },
                .numeric_for_loop => |op| {
                    const current = try valueToNumber(frame.locals[op.var_slot]) + try valueToNumber(frame.locals[op.step_slot]);
                    const limit = try valueToNumber(frame.locals[op.limit_slot]);
                    const step = try valueToNumber(frame.locals[op.step_slot]);
                    frame.locals[op.var_slot] = .{ .number = current };
                    if ((step >= 0 and current <= limit) or (step < 0 and current >= limit)) pc = op.target;
                },
            }
        }
        return &.{};
    }

    fn invokeResolvedFunction(self: *Vm, globals: *GlobalState, callee: Value, args: []const Value) EvalError![]Value {
        if (callee != .function) return error.InvalidCall;
        return switch (callee.function.kind) {
            .native => |native| try native(self, args),
            .bytecode => |closure| try self.executeClosure(globals, closure, args),
            .generated => error.InvalidCall,
            .user => error.InvalidCall,
        };
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
            .bytecode => error.InvalidCall,
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

fn constantToValue(constant: Constant) Value {
    return switch (constant) {
        .number => |number| .{ .number = number },
        .string => |text| .{ .string = text },
    };
}

fn constantString(constant: Constant) []const u8 {
    return switch (constant) {
        .string => |text| text,
        else => unreachable,
    };
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

pub const DependencyReport = struct {
    direct_templates: []const []const u8,
    direct_modules: []const []const u8,
    transitive_modules: []const []const u8,
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
    compiled_ok: []const []const u8,
    compiled_failed: []const ModuleCompileFailure,
    emitted_consistent: []const []const u8,
    emitted_inconsistent: []const ModuleCompileFailure,

    fn deinit(self: *ModuleAudit, allocator: std.mem.Allocator) void {
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
    non_lua,
    empty,
};

pub fn classifyModuleSource(source: []const u8) ModuleSourceKind {
    const trimmed = skipLuaLeadingTrivia(source);
    if (trimmed.len == 0) return .empty;
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
    return looksLikePlaintextModuleDocumentation(source);
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

const TemplateSources = struct {
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

fn analyzeTemplateDependenciesFromSourcesAlloc(
    allocator: std.mem.Allocator,
    template_names: []const []const u8,
    sources: *const TemplateSources,
) !TemplateDependencyReport {

    var root_templates = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &root_templates);
    for (template_names) |name| {
        if (!isLikelyTemplatePageName(name)) continue;
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
            const unresolved_gop = try unresolved_templates.getOrPut(allocator, name);
            if (!unresolved_gop.found_existing) unresolved_gop.key_ptr.* = try allocator.dupe(u8, name);
            continue;
        };

        const template_deps = try extractTemplateDependenciesAlloc(allocator, source);
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
            try appendFailureAlloc(allocator, &compiled_failed, name, "SourceMissing");
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

fn loadStaticProgramAlloc(allocator: std.mem.Allocator, program: *const StaticProgram) !*BytecodeProgram {
    const loaded = try allocator.create(BytecodeProgram);
    loaded.* = .{
        .top = try loadStaticPrototypeAlloc(allocator, program.top),
        .global_count = program.global_count,
        .builtins = program.builtins,
    };
    return loaded;
}

fn loadStaticPrototypeAlloc(allocator: std.mem.Allocator, proto: *const StaticPrototype) !*Prototype {
    const loaded = try allocator.create(Prototype);
    const child_protos = try allocator.alloc(*Prototype, proto.child_protos.len);
    for (proto.child_protos, 0..) |child, idx| child_protos[idx] = try loadStaticPrototypeAlloc(allocator, child);

    const const_tables = try allocator.alloc(*const Table, proto.const_tables.len);
    for (proto.const_tables, 0..) |table_seed, idx| const_tables[idx] = try loadStaticConstTableAlloc(allocator, table_seed);

    loaded.* = .{
        .name = try allocator.dupe(u8, proto.name),
        .params = proto.params,
        .local_count = proto.local_count,
        .stack_size = proto.stack_size,
        .is_vararg = proto.is_vararg,
        .code = try allocator.dupe(Instruction, proto.code),
        .constants = try dupConstantsAlloc(allocator, proto.constants),
        .const_tables = const_tables,
        .child_protos = child_protos,
        .upvalues = try allocator.dupe(UpvalueBinding, proto.upvalues),
    };
    return loaded;
}

fn dupConstantsAlloc(allocator: std.mem.Allocator, constants: []const Constant) ![]const Constant {
    const out = try allocator.alloc(Constant, constants.len);
    for (constants, 0..) |constant, idx| {
        out[idx] = switch (constant) {
            .number => |value| .{ .number = value },
            .string => |value| .{ .string = try allocator.dupe(u8, value) },
        };
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

fn bytecodeProgramEqual(lhs: *const BytecodeProgram, rhs: *const BytecodeProgram) bool {
    return lhs.global_count == rhs.global_count and
        std.meta.eql(lhs.builtins, rhs.builtins) and
        prototypeEqual(lhs.top, rhs.top);
}

fn prototypeEqual(lhs: *const Prototype, rhs: *const Prototype) bool {
    if (!std.mem.eql(u8, lhs.name, rhs.name)) return false;
    if (lhs.params != rhs.params or lhs.local_count != rhs.local_count or lhs.stack_size != rhs.stack_size or lhs.is_vararg != rhs.is_vararg) return false;
    if (lhs.code.len != rhs.code.len or lhs.constants.len != rhs.constants.len or lhs.const_tables.len != rhs.const_tables.len or lhs.child_protos.len != rhs.child_protos.len or lhs.upvalues.len != rhs.upvalues.len) return false;

    for (lhs.code, rhs.code) |lhs_inst, rhs_inst| {
        if (!std.meta.eql(lhs_inst, rhs_inst)) return false;
    }
    for (lhs.constants, rhs.constants) |lhs_const, rhs_const| {
        if (!constantEqual(lhs_const, rhs_const)) return false;
    }
    for (lhs.const_tables, rhs.const_tables) |lhs_table, rhs_table| {
        if (!constTableEqual(lhs_table, rhs_table)) return false;
    }
    for (lhs.child_protos, rhs.child_protos) |lhs_child, rhs_child| {
        if (!prototypeEqual(lhs_child, rhs_child)) return false;
    }
    for (lhs.upvalues, rhs.upvalues) |lhs_upvalue, rhs_upvalue| {
        if (!std.meta.eql(lhs_upvalue, rhs_upvalue)) return false;
    }
    return true;
}

fn constantEqual(lhs: Constant, rhs: Constant) bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .number => |value| value == rhs.number,
        .string => |value| std.mem.eql(u8, value, rhs.string),
    };
}

fn constTableEqual(lhs: *const Table, rhs: *const Table) bool {
    if (lhs.array.items.len != rhs.array.items.len or lhs.string_fields.count() != rhs.string_fields.count() or lhs.int_fields.count() != rhs.int_fields.count()) return false;

    for (lhs.array.items, rhs.array.items) |lhs_value, rhs_value| {
        if (!constValueEqual(lhs_value, rhs_value)) return false;
    }

    var string_it = lhs.string_fields.iterator();
    while (string_it.next()) |entry| {
        const rhs_value = rhs.string_fields.get(entry.key_ptr.*) orelse return false;
        if (!constValueEqual(entry.value_ptr.*, rhs_value)) return false;
    }

    var int_it = lhs.int_fields.iterator();
    while (int_it.next()) |entry| {
        const rhs_value = rhs.int_fields.get(entry.key_ptr.*) orelse return false;
        if (!constValueEqual(entry.value_ptr.*, rhs_value)) return false;
    }

    return true;
}

fn constValueEqual(lhs: Value, rhs: Value) bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .nil => true,
        .boolean => |value| value == rhs.boolean,
        .number => |value| value == rhs.number,
        .string => |value| std.mem.eql(u8, value, rhs.string),
        .table => |table| constTableEqual(table, rhs.table),
        .function, .iterator => false,
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

fn scanTemplateAndModuleSourcesAlloc(allocator: std.mem.Allocator, path: []const u8) !TemplateSources {
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
    return .{
        .template_sources = template_sources,
        .module_sources = module_sources,
    };
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

fn extractTemplateDependenciesAlloc(allocator: std.mem.Allocator, source: []const u8) ![]const []const u8 {
    var set = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &set);

    var i: usize = 0;
    while (i + 2 <= source.len) : (i += 1) {
        if (!std.mem.eql(u8, source[i .. i + 2], "{{")) continue;
        if ((i > 0 and source[i - 1] == '{') or (i + 3 <= source.len and source[i + 2] == '{')) continue;

        var name_start = i + 2;
        while (name_start < source.len and std.ascii.isWhitespace(source[name_start])) : (name_start += 1) {}
        var name_end = name_start;
        while (name_end < source.len) : (name_end += 1) {
            const byte = source[name_end];
            if (byte == '|' or byte == '}' or byte == '\n' or byte == '\r') break;
        }
        if (name_end <= name_start) continue;

        var raw_name = std.mem.trim(u8, source[name_start..name_end], " \t");
        raw_name = stripSubstPrefix(raw_name);
        raw_name = stripTemplateNamespace(raw_name);
        if (raw_name.len == 0) continue;
        if (raw_name[0] == '#') continue;
        if (!isLikelyTemplatePageName(raw_name)) continue;

        try insertCanonicalTemplateName(&set, allocator, raw_name);
        i = name_end;
    }

    return collectStringSet(allocator, &set);
}

fn extractModuleDependencies(allocator: std.mem.Allocator, source: []const u8) ![]const []const u8 {
    var set = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &set);
    const patterns = [_][]const u8{
        "require(\"Module:",
        "require('Module:",
        "mw.loadData(\"Module:",
        "mw.loadData('Module:",
    };
    for (patterns) |pattern| {
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, source, cursor, pattern)) |start| {
            const name_start = start + pattern.len;
            var name_end = name_start;
            while (name_end < source.len and source[name_end] != '"' and source[name_end] != '\'') : (name_end += 1) {}
            const name = source[name_start..name_end];
            if (isLikelyModulePageName(name)) try insertCanonicalModuleName(&set, allocator, name);
            cursor = name_end;
        }
    }
    return collectStringSet(allocator, &set);
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

fn canonicalTemplateNameAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const trimmed = std.mem.trim(u8, stripTemplateNamespace(stripSubstPrefix(name)), " \t\r\n");
    for (trimmed) |byte| {
        if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == '_') continue;
        try out.append(allocator, std.ascii.toLower(byte));
    }
    return out.toOwnedSlice(allocator);
}

fn canonicalModuleNameAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
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
    const wrapper = try std.fmt.allocPrint(
        allocator,
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
    try std.testing.expectEqual(.empty, classifyModuleSource("  \n\t "));
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

    const deps = try extractTemplateDependenciesAlloc(std.testing.allocator, source);
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

test "template zig emission audit reports missing templates and compile failures" {
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
            \\{{#invoke:broken|main}}
            \\{{missing-helper}}
        ),
    );
    try putCanonicalModuleSource(
        std.testing.allocator,
        &sources.module_sources,
        "broken",
        try std.testing.allocator.dupe(u8,
            \\local =
        ),
    );

    const template_names = [_][]const u8{ "broken", "missing-root" };
    var report = try analyzeTemplateDependenciesFromSourcesAlloc(std.testing.allocator, &template_names, &sources);
    defer report.deinit(std.testing.allocator);

    try std.testing.expect(report.unresolved_templates.len >= 2);
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
    try std.testing.expect(!isLikelyCodeModulePageName("accel/documentation"));
    try std.testing.expect(!isLikelyCodeModulePageName("affix doc"));
}
