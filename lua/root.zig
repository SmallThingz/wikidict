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

    fn getString(self: *const Table, key: []const u8) Value {
        return self.string_fields.get(key) orelse .nil;
    }

    fn putString(self: *Table, key: []const u8, value: Value) !void {
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

const Constant = union(enum) {
    number: f64,
    string: []const u8,
};

const UpvalueBinding = union(enum) {
    parent_local: u16,
    parent_upvalue: u16,
};

const Instruction = union(enum) {
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
    load_method_name: u16,
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

const BuiltinGlobalSlots = struct {
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

const GlobalState = struct {
    values: []Value,
};

pub const FunctionKind = union(enum) {
    user: UserFunction,
    native: NativeFn,
    bytecode: *Closure,
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
    program: *const BytecodeProgram,

    pub fn deinit(self: *Chunk) void {
        self.arena.deinit();
    }
};

pub const RunResult = struct {
    vm: Vm,
    returns: []const Value,
    globals: *GlobalState,

    pub fn deinit(self: *RunResult) void {
        self.vm.deinit();
        self.* = undefined;
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
    method_call: struct {
        object: *Expr,
        name: []const u8,
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
    const program = try compileBytecodeProgram(a, body);
    return .{
        .arena = arena,
        .source = owned_source,
        .body = body,
        .program = program,
    };
}

pub fn run(allocator: std.mem.Allocator, chunk: *const Chunk) !RunResult {
    var vm = try Vm.init(allocator);
    const globals = try vm.createGlobalState(chunk.program);
    try vm.installBuiltinGlobals(globals, chunk.program.builtins);
    const entry = try vm.createTopClosure(chunk.program.top);
    const returns = try vm.executeClosure(globals, entry, &.{});
    return .{
        .vm = vm,
        .returns = returns,
        .globals = globals,
    };
}

pub const ModuleArg = struct {
    name: ?[]const u8 = null,
    value: []const u8,
};

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

    const globals = try vm.createGlobalState(chunk.program);
    try vm.installBuiltinGlobals(globals, chunk.program.builtins);

    const entry = try vm.createTopClosure(chunk.program.top);
    const module_returns = try vm.executeClosure(globals, entry, &.{});
    if (module_returns.len == 0 or module_returns[0] != .table) return allocator.dupe(u8, "");

    const function_value = module_returns[0].table.getString(function_name);
    if (function_value != .function) return allocator.dupe(u8, "");

    const frame_table = try buildModuleFrameTable(&vm, args);
    const results = try vm.invokeResolvedFunction(globals, function_value, &.{.{ .table = frame_table }});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    if (results.len != 0) try appendValueText(&out, allocator, results[0]);
    return out.toOwnedSlice(allocator);
}

pub fn formatOpcodesAlloc(allocator: std.mem.Allocator, chunk: *const Chunk) ![]u8 {
    return formatBytecodeAlloc(allocator, chunk.program);
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
        .method_call => |call| {
            try formatExpr(out, allocator, call.object);
            try out.appendSlice(allocator, ":");
            try out.appendSlice(allocator, call.name);
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
        .method_call => |*call| {
            try optimizeExpr(allocator, call.object);
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
        .method_call,
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
        .method_call => |call| {
            try compileExprBytecode(builder, call.object);
            const name_idx = try builder.stringConst(call.name);
            _ = try builder.emit(.{ .load_method_name = name_idx }, 1);
            try compileExprList(builder, call.args);
            _ = try builder.emit(.{ .call = try castU16(call.args.len + 1) }, -@as(i32, @intCast(call.args.len + 1)));
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
            const proto = try compileChildPrototype(
                builder.allocator,
                builder.program,
                builder,
                "anonymous",
                func.params,
                func.body,
                func.is_vararg,
            );
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
            .load_method_name,
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
            .call, .method_call => return try self.allocStmt(.{ .expr_stmt = prefix }),
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
                const method_args = try self.parseCallArgs();
                expr = try self.allocExpr(.{ .method_call = .{
                    .object = expr,
                    .name = method_name,
                    .args = method_args,
                } });
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
                .load_method_name => |name_idx| {
                    const object = try self.popFrameValue(frame);
                    if (object != .table) return error.InvalidIndex;
                    try self.pushFrameValue(frame, object.table.getString(constantString(proto.constants[name_idx])));
                    try self.pushFrameValue(frame, object);
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
            .method_call => |call| blk: {
                const object = try self.evalExpr(env, call.object);
                if (object != .table) return error.InvalidIndex;
                const callee = object.table.getString(call.name);
                if (callee != .function) return error.InvalidCall;
                const other_args = try self.evalExprs(env, call.args);
                const args = try self.alloc().alloc(Value, other_args.len + 1);
                args[0] = object;
                @memcpy(args[1..], other_args);
                const results = try self.callFunction(callee.function, args);
                break :blk if (results.len == 0) .nil else results[0];
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
    bytecode_consistent: []const []const u8,
    bytecode_inconsistent: []const ModuleCompileFailure,
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
    bytecode_consistent: []const []const u8,
    bytecode_inconsistent: []const ModuleCompileFailure,

    pub fn deinit(self: *TemplateDependencyReport, allocator: std.mem.Allocator) void {
        freeStringSlice(allocator, self.root_templates);
        freeStringSlice(allocator, self.reachable_templates);
        freeStringSlice(allocator, self.unresolved_templates);
        freeStringSlice(allocator, self.direct_modules);
        freeStringSlice(allocator, self.transitive_modules);
        freeStringSlice(allocator, self.missing_modules);
        freeStringSlice(allocator, self.compiled_ok);
        freeStringSlice(allocator, self.bytecode_consistent);
        for (self.compiled_failed) |failure| {
            allocator.free(failure.name);
            allocator.free(failure.reason);
        }
        allocator.free(self.compiled_failed);
        for (self.bytecode_inconsistent) |failure| {
            allocator.free(failure.name);
            allocator.free(failure.reason);
        }
        allocator.free(self.bytecode_inconsistent);
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
    bytecode_consistent: []const []const u8,
    bytecode_inconsistent: []const ModuleCompileFailure,

    fn deinit(self: *ModuleAudit, allocator: std.mem.Allocator) void {
        freeStringSlice(allocator, self.missing_modules);
        freeStringSlice(allocator, self.compiled_ok);
        freeStringSlice(allocator, self.bytecode_consistent);
        for (self.compiled_failed) |failure| {
            allocator.free(failure.name);
            allocator.free(failure.reason);
        }
        allocator.free(self.compiled_failed);
        for (self.bytecode_inconsistent) |failure| {
            allocator.free(failure.name);
            allocator.free(failure.reason);
        }
        allocator.free(self.bytecode_inconsistent);
        self.* = undefined;
    }
};

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
        .bytecode_consistent = try dupStringSliceAlloc(allocator, audit.bytecode_consistent),
        .bytecode_inconsistent = try dupFailureSliceAlloc(allocator, audit.bytecode_inconsistent),
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
        .bytecode_consistent = try dupStringSliceAlloc(allocator, audit.bytecode_consistent),
        .bytecode_inconsistent = try dupFailureSliceAlloc(allocator, audit.bytecode_inconsistent),
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

    var bytecode_consistent: std.ArrayList([]const u8) = .empty;
    errdefer freeOwnedStringList(allocator, &bytecode_consistent);

    var bytecode_inconsistent: std.ArrayList(ModuleCompileFailure) = .empty;
    errdefer freeFailureList(allocator, &bytecode_inconsistent);

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

        if (!bytecodeProgramEqual(first.program, second.program)) {
            try appendFailureAlloc(allocator, &bytecode_inconsistent, name, "BytecodeMismatch");
            continue;
        }

        try bytecode_consistent.append(allocator, try allocator.dupe(u8, name));
    }

    return .{
        .missing_modules = try missing_modules.toOwnedSlice(allocator),
        .compiled_ok = try compiled_ok.toOwnedSlice(allocator),
        .compiled_failed = try compiled_failed.toOwnedSlice(allocator),
        .bytecode_consistent = try bytecode_consistent.toOwnedSlice(allocator),
        .bytecode_inconsistent = try bytecode_inconsistent.toOwnedSlice(allocator),
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

test "simple lua opcode VM matches lua for arithmetic and locals" {
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

test "simple lua opcode VM matches lua for tables functions and loops" {
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

fn codeContainsInstruction(code: []const Instruction, comptime tag: std.meta.Tag(Instruction)) bool {
    for (code) |inst| {
        if (std.meta.activeTag(inst) == tag) return true;
    }
    return false;
}

test "lua bytecode resolves names to slots during compilation" {
    const source =
        \\local outer = 41
        \\local function capture(arg)
        \\  return outer, arg, print
        \\end
        \\return capture
    ;
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    try std.testing.expectEqual(@as(usize, 1), chunk.program.top.child_protos.len);
    const proto = chunk.program.top.child_protos[0];
    try std.testing.expect(codeContainsInstruction(proto.code, .load_upvalue));
    try std.testing.expect(codeContainsInstruction(proto.code, .load_local));
    try std.testing.expect(codeContainsInstruction(proto.code, .load_global));

    const opcodes = try formatOpcodesAlloc(std.testing.allocator, &chunk);
    defer std.testing.allocator.free(opcodes);
    try std.testing.expect(std.mem.indexOf(u8, opcodes, "outer") == null);
    try std.testing.expect(std.mem.indexOf(u8, opcodes, "arg") == null);
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
        .method_call => |call| findFirstConstTableInExpr(call.object) orelse findFirstConstTableInExprs(call.args),
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
        \\<noinclude>{{documentation}}{{server}}{{/doc-example}}</noinclude>
        \\<!-- {{comment-only}} -->
        \\<nowiki>{{nowiki-example}}</nowiki>
    ;

    const deps = try extractTemplateDependenciesAlloc(std.testing.allocator, source, "demo/doc");
    defer freeStringSlice(std.testing.allocator, deps);

    try std.testing.expectEqual(@as(usize, 4), deps.len);
    try std.testing.expectEqualStrings("barbaz", deps[0]);
    try std.testing.expectEqualStrings("col3", deps[1]);
    try std.testing.expectEqualStrings("foo", deps[2]);
    try std.testing.expectEqualStrings("quote-news", deps[3]);
}

test "module dependency extraction ignores comments and unrelated strings" {
    const source =
        \\local ok = require("Module:real")
        \\local also = require 'Module:also real'
        \\local data = mw.loadData("Module:data")
        \\-- require("Module:commented")
        \\local text = "require(\"Module:not a dependency\")"
        \\local sample = 'mw.loadData("Module:not data")'
    ;

    const deps = try extractModuleDependencies(std.testing.allocator, source);
    defer freeStringSlice(std.testing.allocator, deps);

    try std.testing.expectEqual(@as(usize, 3), deps.len);
    try std.testing.expectEqualStrings("also real", deps[0]);
    try std.testing.expectEqualStrings("data", deps[1]);
    try std.testing.expectEqualStrings("real", deps[2]);
}

test "template bytecode audit compiles reachable modules with stable bytecode" {
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
    try std.testing.expectEqual(@as(usize, 0), report.missing_modules.len);
    try std.testing.expectEqual(@as(usize, 1), report.compiled_ok.len);
    try std.testing.expectEqual(@as(usize, 0), report.compiled_failed.len);
    try std.testing.expectEqual(@as(usize, 1), report.bytecode_consistent.len);
    try std.testing.expectEqual(@as(usize, 0), report.bytecode_inconsistent.len);
    try std.testing.expectEqualStrings("demo", report.bytecode_consistent[0]);
}

test "template bytecode audit separates missing modules from compile failures" {
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
    try std.testing.expectEqual(@as(usize, 0), report.bytecode_consistent.len);
    try std.testing.expectEqual(@as(usize, 1), report.missing_modules.len);
    try std.testing.expectEqualStrings("missing-module", report.missing_modules[0]);
    try std.testing.expectEqual(@as(usize, 0), report.compiled_failed.len);
}

test "template bytecode audit still reports real compile failures" {
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
        try std.testing.allocator.dupe(u8, "local ="),
    );

    const template_names = [_][]const u8{"broken"};
    var report = try analyzeTemplateDependenciesFromSourcesAlloc(std.testing.allocator, &template_names, &sources);
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), report.missing_modules.len);
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

test "template magic-name matcher ignores separators" {
    try std.testing.expect(isIgnoredTemplateMagicName("wikimedia language"));
    try std.testing.expect(isIgnoredTemplateMagicName("Wikimedia_language"));
    try std.testing.expect(isIgnoredTemplateMagicName("wikimedia-language"));
}
