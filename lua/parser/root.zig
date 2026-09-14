const std = @import("std");

pub const Error = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidLongString,
    InvalidString,
    InvalidNumber,
    InvalidAssignment,
} || std.mem.Allocator.Error;

pub const Span = struct { start: u32, end: u32 };

pub const UnaryOp = enum { neg, not_, len };
pub const BinaryOp = enum { or_, and_, lt, le, gt, ge, eq, ne, concat, add, sub, mul, div, mod, pow };

pub const Expr = union(enum) {
    nil_lit: Span,
    bool_lit: struct { value: bool, span: Span },
    number: struct { raw: []const u8, span: Span },
    string: struct { value: []const u8, span: Span },
    vararg: Span,
    name: struct { value: []const u8, span: Span },
    paren: struct { expr: *Expr, span: Span },
    index: struct { object: *Expr, key: *Expr, span: Span },
    call: struct { callee: *Expr, args: []const *Expr, span: Span },
    method_call: struct { object: *Expr, method: []const u8, args: []const *Expr, span: Span },
    function: FunctionExpr,
    table: struct { fields: []const TableField, span: Span },
    unary: struct { op: UnaryOp, expr: *Expr, span: Span },
    binary: struct { op: BinaryOp, lhs: *Expr, rhs: *Expr, span: Span },

    pub fn span(self: *const Expr) Span {
        return switch (self.*) {
            .nil_lit => |v| v,
            .bool_lit => |v| v.span,
            .number => |v| v.span,
            .string => |v| v.span,
            .vararg => |v| v,
            .name => |v| v.span,
            .paren => |v| v.span,
            .index => |v| v.span,
            .call => |v| v.span,
            .method_call => |v| v.span,
            .function => |v| v.span,
            .table => |v| v.span,
            .unary => |v| v.span,
            .binary => |v| v.span,
        };
    }
};

pub const FunctionExpr = struct {
    params: []const []const u8,
    is_vararg: bool,
    body: Block,
    span: Span,
};

pub const TableField = union(enum) {
    list: *Expr,
    named: struct { name: []const u8, value: *Expr },
    keyed: struct { key: *Expr, value: *Expr },
};

pub const LValue = union(enum) {
    name: []const u8,
    index: struct { object: *Expr, key: *Expr },
};

pub const IfBranch = struct { cond: *Expr, body: Block };
pub const Block = []const *Stmt;

pub const Stmt = union(enum) {
    empty: Span,
    assign: struct { targets: []const LValue, values: []const *Expr, span: Span },
    local_assign: struct { names: []const []const u8, values: []const *Expr, span: Span },
    call: struct { expr: *Expr, span: Span },
    do_block: struct { body: Block, span: Span },
    while_loop: struct { cond: *Expr, body: Block, span: Span },
    repeat_loop: struct { body: Block, cond: *Expr, span: Span },
    if_stmt: struct { branches: []const IfBranch, else_body: ?Block, span: Span },
    numeric_for: struct { name: []const u8, start: *Expr, limit: *Expr, step: ?*Expr, body: Block, span: Span },
    generic_for: struct { names: []const []const u8, values: []const *Expr, body: Block, span: Span },
    function_assign: struct { target: LValue, function: *Expr, span: Span },
    local_function: struct { name: []const u8, function: *Expr, span: Span },
    return_stmt: struct { values: []const *Expr, span: Span },
    break_stmt: Span,
};

pub const Chunk = struct {
    arena: std.heap.ArenaAllocator,
    source: []const u8,
    body: Block,

    pub fn deinit(self: *Chunk) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const Tag = enum {
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
    tag: Tag,
    text: []const u8,
    decoded: ?[]const u8 = null,
    span: Span,
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) Error!Chunk {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const owned = try a.dupe(u8, source);
    var lex = Lexer{ .allocator = a, .source = owned };
    const tokens = try lex.all();
    var p = Parser{ .allocator = a, .source = owned, .tokens = tokens };
    const body = try p.block(&.{.eof});
    _ = try p.expect(.eof);
    return .{ .arena = arena, .source = owned, .body = body };
}

const Lexer = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    pos: usize = 0,

    fn all(self: *Lexer) Error![]const Token {
        var out: std.ArrayList(Token) = .empty;
        while (true) {
            const tok = try self.next();
            try out.append(self.allocator, tok);
            if (tok.tag == .eof) break;
        }
        return try out.toOwnedSlice(self.allocator);
    }

    fn next(self: *Lexer) Error!Token {
        try self.skipTrivia();
        if (self.pos >= self.source.len) return .{ .tag = .eof, .text = "", .span = self.mkSpan(self.pos, self.pos) };
        const start = self.pos;
        const c = self.source[self.pos];

        if (isIdentStart(c)) {
            self.pos += 1;
            while (self.pos < self.source.len and isIdentContinue(self.source[self.pos])) self.pos += 1;
            const text = self.source[start..self.pos];
            return .{ .tag = keyword(text) orelse .identifier, .text = text, .span = self.mkSpan(start, self.pos) };
        }

        if (isDigit(c) or (c == '.' and self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1]))) {
            return self.number(start);
        }

        if (c == '\'' or c == '"') return try self.shortString(start, c);
        if (c == '[') {
            if (longOpen(self.source, self.pos)) |open| return try self.longString(start, open);
        }

        self.pos += 1;
        const single = struct {
            fn t(tag: Tag, text: []const u8, span: Span) Token {
                return .{ .tag = tag, .text = text, .span = span };
            }
        }.t;
        switch (c) {
            '+' => return single(.plus, self.source[start..self.pos], self.mkSpan(start, self.pos)),
            '-' => return single(.minus, self.source[start..self.pos], self.mkSpan(start, self.pos)),
            '*' => return single(.star, self.source[start..self.pos], self.mkSpan(start, self.pos)),
            '/' => return single(.slash, self.source[start..self.pos], self.mkSpan(start, self.pos)),
            '%' => return single(.percent, self.source[start..self.pos], self.mkSpan(start, self.pos)),
            '^' => return single(.caret, self.source[start..self.pos], self.mkSpan(start, self.pos)),
            '#' => return single(.hash, self.source[start..self.pos], self.mkSpan(start, self.pos)),
            ',' => return single(.comma, self.source[start..self.pos], self.mkSpan(start, self.pos)),
            ';' => return single(.semi, self.source[start..self.pos], self.mkSpan(start, self.pos)),
            ':' => return single(.colon, self.source[start..self.pos], self.mkSpan(start, self.pos)),
            '(' => return single(.lparen, self.source[start..self.pos], self.mkSpan(start, self.pos)),
            ')' => return single(.rparen, self.source[start..self.pos], self.mkSpan(start, self.pos)),
            '{' => return single(.lbrace, self.source[start..self.pos], self.mkSpan(start, self.pos)),
            '}' => return single(.rbrace, self.source[start..self.pos], self.mkSpan(start, self.pos)),
            ']' => return single(.rbracket, self.source[start..self.pos], self.mkSpan(start, self.pos)),
            '=' => {
                if (self.take('=')) return single(.eqeq, self.source[start..self.pos], self.mkSpan(start, self.pos));
                return single(.eq, self.source[start..self.pos], self.mkSpan(start, self.pos));
            },
            '~' => {
                if (self.take('=')) return single(.ne, self.source[start..self.pos], self.mkSpan(start, self.pos));
                return error.UnexpectedToken;
            },
            '<' => {
                if (self.take('=')) return single(.le, self.source[start..self.pos], self.mkSpan(start, self.pos));
                return single(.lt, self.source[start..self.pos], self.mkSpan(start, self.pos));
            },
            '>' => {
                if (self.take('=')) return single(.ge, self.source[start..self.pos], self.mkSpan(start, self.pos));
                return single(.gt, self.source[start..self.pos], self.mkSpan(start, self.pos));
            },
            '.' => {
                if (self.take('.')) {
                    if (self.take('.')) return single(.ellipsis, self.source[start..self.pos], self.mkSpan(start, self.pos));
                    return single(.dotdot, self.source[start..self.pos], self.mkSpan(start, self.pos));
                }
                return single(.dot, self.source[start..self.pos], self.mkSpan(start, self.pos));
            },
            '[' => return single(.lbracket, self.source[start..self.pos], self.mkSpan(start, self.pos)),
            else => return error.UnexpectedToken,
        }
    }

    fn skipTrivia(self: *Lexer) Error!void {
        while (true) {
            while (self.pos < self.source.len and isSpace(self.source[self.pos])) self.pos += 1;
            if (self.pos + 1 >= self.source.len or self.source[self.pos] != '-' or self.source[self.pos + 1] != '-') return;
            self.pos += 2;
            if (self.pos < self.source.len and self.source[self.pos] == '[') {
                if (longOpen(self.source, self.pos)) |open| {
                    _ = try self.consumeLong(open);
                    continue;
                }
            }
            while (self.pos < self.source.len and self.source[self.pos] != '\n' and self.source[self.pos] != '\r') self.pos += 1;
        }
    }

    fn number(self: *Lexer, start: usize) Token {
        if (self.source[start] == '0' and start + 1 < self.source.len and (self.source[start + 1] == 'x' or self.source[start + 1] == 'X')) {
            self.pos = start + 2;
            while (self.pos < self.source.len and isHex(self.source[self.pos])) self.pos += 1;
            if (self.pos < self.source.len and self.source[self.pos] == '.') {
                self.pos += 1;
                while (self.pos < self.source.len and isHex(self.source[self.pos])) self.pos += 1;
            }
            // MediaWiki's Lua 5.1 build accepts hexadecimal floating-point
            // literals (0x1p53, 0x1.8p+2), so treat p/P as the exponent marker.
            if (self.pos < self.source.len and (self.source[self.pos] == 'p' or self.source[self.pos] == 'P')) {
                const save = self.pos;
                self.pos += 1;
                if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) self.pos += 1;
                const digits = self.pos;
                while (self.pos < self.source.len and isDigit(self.source[self.pos])) self.pos += 1;
                if (digits == self.pos) self.pos = save;
            }
        } else {
            self.pos = start;
            while (self.pos < self.source.len and isDigit(self.source[self.pos])) self.pos += 1;
            if (self.pos < self.source.len and self.source[self.pos] == '.' and !(self.pos + 1 < self.source.len and self.source[self.pos + 1] == '.')) {
                self.pos += 1;
                while (self.pos < self.source.len and isDigit(self.source[self.pos])) self.pos += 1;
            }
            if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
                const save = self.pos;
                self.pos += 1;
                if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) self.pos += 1;
                const digits = self.pos;
                while (self.pos < self.source.len and isDigit(self.source[self.pos])) self.pos += 1;
                if (digits == self.pos) self.pos = save;
            }
        }
        return .{ .tag = .number, .text = self.source[start..self.pos], .span = self.mkSpan(start, self.pos) };
    }

    fn shortString(self: *Lexer, start: usize, quote: u8) Error!Token {
        self.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == quote) {
                self.pos += 1;
                return .{ .tag = .string, .text = self.source[start..self.pos], .decoded = try out.toOwnedSlice(self.allocator), .span = self.mkSpan(start, self.pos) };
            }
            if (c == '\n' or c == '\r') return error.InvalidString;
            if (c != '\\') {
                try out.append(self.allocator, c);
                self.pos += 1;
                continue;
            }
            self.pos += 1;
            if (self.pos >= self.source.len) return error.UnexpectedEof;
            const e = self.source[self.pos];
            self.pos += 1;
            switch (e) {
                'a' => try out.append(self.allocator, 0x07),
                'b' => try out.append(self.allocator, 0x08),
                'f' => try out.append(self.allocator, 0x0c),
                'n' => try out.append(self.allocator, '\n'),
                'r' => try out.append(self.allocator, '\r'),
                't' => try out.append(self.allocator, '\t'),
                'v' => try out.append(self.allocator, 0x0b),
                '\\' => try out.append(self.allocator, '\\'),
                '\'' => try out.append(self.allocator, '\''),
                '"' => try out.append(self.allocator, '"'),
                '\n' => try out.append(self.allocator, '\n'),
                '\r' => {
                    if (self.pos < self.source.len and self.source[self.pos] == '\n') self.pos += 1;
                    try out.append(self.allocator, '\n');
                },
                '0'...'9' => {
                    var value: u16 = e - '0';
                    var n: u8 = 1;
                    while (n < 3 and self.pos < self.source.len and isDigit(self.source[self.pos])) : (n += 1) {
                        value = value * 10 + (self.source[self.pos] - '0');
                        self.pos += 1;
                    }
                    if (value > 255) return error.InvalidString;
                    try out.append(self.allocator, @intCast(value));
                },
                // Lua 5.1 accepts an otherwise unknown escape by discarding the
                // backslash. This differs from newer Lua and current LuaJIT.
                else => try out.append(self.allocator, e),
            }
        }
        return error.UnexpectedEof;
    }

    fn longString(self: *Lexer, start: usize, open: LongOpen) Error!Token {
        const decoded = try self.consumeLong(open);
        return .{ .tag = .string, .text = self.source[start..self.pos], .decoded = decoded, .span = self.mkSpan(start, self.pos) };
    }

    fn consumeLong(self: *Lexer, open: LongOpen) Error![]const u8 {
        self.pos += open.width;
        var content_start = self.pos;
        if (self.pos < self.source.len and self.source[self.pos] == '\r') {
            self.pos += 1;
            if (self.pos < self.source.len and self.source[self.pos] == '\n') self.pos += 1;
            content_start = self.pos;
        } else if (self.pos < self.source.len and self.source[self.pos] == '\n') {
            self.pos += 1;
            content_start = self.pos;
        }
        while (self.pos < self.source.len) {
            if (self.source[self.pos] == ']') {
                var i = self.pos + 1;
                var eqs: usize = 0;
                while (i < self.source.len and self.source[i] == '=') : (i += 1) eqs += 1;
                if (eqs == open.eqs and i < self.source.len and self.source[i] == ']') {
                    const raw = self.source[content_start..self.pos];
                    self.pos = i + 1;
                    return try normalizeNewlines(self.allocator, raw);
                }
            }
            self.pos += 1;
        }
        return error.InvalidLongString;
    }

    fn take(self: *Lexer, c: u8) bool {
        if (self.pos < self.source.len and self.source[self.pos] == c) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn mkSpan(_: *const Lexer, a: usize, b: usize) Span {
        return .{ .start = @intCast(a), .end = @intCast(b) };
    }
};

const LongOpen = struct { eqs: usize, width: usize };
fn longOpen(source: []const u8, pos: usize) ?LongOpen {
    if (pos >= source.len or source[pos] != '[') return null;
    var i = pos + 1;
    var eqs: usize = 0;
    while (i < source.len and source[i] == '=') : (i += 1) eqs += 1;
    if (i < source.len and source[i] == '[') return .{ .eqs = eqs, .width = i - pos + 1 };
    return null;
}

fn normalizeNewlines(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\r') == null) return try a.dupe(u8, raw);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\r') {
            try out.append(a, '\n');
            i += 1;
            if (i < raw.len and raw[i] == '\n') i += 1;
        } else {
            try out.append(a, raw[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice(a);
}

const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const Token,
    pos: usize = 0,

    fn block(self: *Parser, stops: []const Tag) Error!Block {
        var out: std.ArrayList(*Stmt) = .empty;
        while (!containsTag(stops, self.peek().tag)) {
            if (self.peek().tag == .eof) {
                if (containsTag(stops, .eof)) break;
                return error.UnexpectedEof;
            }
            const s = try self.statement();
            try out.append(self.allocator, s);
            if (s.* == .return_stmt or s.* == .break_stmt) {
                _ = self.match(.semi);
                // Lua's grammar requires return/break to be the last statement
                // in a block. Let the enclosing stop token follow directly.
                break;
            }
        }
        return try out.toOwnedSlice(self.allocator);
    }

    fn statement(self: *Parser) Error!*Stmt {
        const start = self.peek().span.start;
        return switch (self.peek().tag) {
            .semi => blk: {
                const t = self.advance();
                break :blk try self.newStmt(.{ .empty = t.span });
            },
            .kw_do => self.doStmt(start),
            .kw_while => self.whileStmt(start),
            .kw_repeat => self.repeatStmt(start),
            .kw_if => self.ifStmt(start),
            .kw_for => self.forStmt(start),
            .kw_function => self.functionStmt(start),
            .kw_local => self.localStmt(start),
            .kw_return => self.returnStmt(start),
            .kw_break => blk: {
                const t = self.advance();
                break :blk try self.newStmt(.{ .break_stmt = t.span });
            },
            else => self.assignOrCallStmt(start),
        };
    }

    fn doStmt(self: *Parser, start: u32) Error!*Stmt {
        _ = try self.expect(.kw_do);
        const body = try self.block(&.{.kw_end});
        const end = try self.expect(.kw_end);
        return self.newStmt(.{ .do_block = .{ .body = body, .span = .{ .start = start, .end = end.span.end } } });
    }

    fn whileStmt(self: *Parser, start: u32) Error!*Stmt {
        _ = try self.expect(.kw_while);
        const cond = try self.expr(1);
        _ = try self.expect(.kw_do);
        const body = try self.block(&.{.kw_end});
        const end = try self.expect(.kw_end);
        return self.newStmt(.{ .while_loop = .{ .cond = cond, .body = body, .span = .{ .start = start, .end = end.span.end } } });
    }

    fn repeatStmt(self: *Parser, start: u32) Error!*Stmt {
        _ = try self.expect(.kw_repeat);
        const body = try self.block(&.{.kw_until});
        _ = try self.expect(.kw_until);
        const cond = try self.expr(1);
        return self.newStmt(.{ .repeat_loop = .{ .body = body, .cond = cond, .span = .{ .start = start, .end = cond.span().end } } });
    }

    fn ifStmt(self: *Parser, start: u32) Error!*Stmt {
        _ = try self.expect(.kw_if);
        var branches: std.ArrayList(IfBranch) = .empty;
        var cond = try self.expr(1);
        _ = try self.expect(.kw_then);
        var body = try self.block(&.{ .kw_elseif, .kw_else, .kw_end });
        try branches.append(self.allocator, .{ .cond = cond, .body = body });
        while (self.match(.kw_elseif)) {
            cond = try self.expr(1);
            _ = try self.expect(.kw_then);
            body = try self.block(&.{ .kw_elseif, .kw_else, .kw_end });
            try branches.append(self.allocator, .{ .cond = cond, .body = body });
        }
        var else_body: ?Block = null;
        if (self.match(.kw_else)) else_body = try self.block(&.{.kw_end});
        const end = try self.expect(.kw_end);
        return self.newStmt(.{ .if_stmt = .{ .branches = try branches.toOwnedSlice(self.allocator), .else_body = else_body, .span = .{ .start = start, .end = end.span.end } } });
    }

    fn forStmt(self: *Parser, start: u32) Error!*Stmt {
        _ = try self.expect(.kw_for);
        const first = try self.expect(.identifier);
        if (self.match(.eq)) {
            const begin = try self.expr(1);
            _ = try self.expect(.comma);
            const limit = try self.expr(1);
            var step: ?*Expr = null;
            if (self.match(.comma)) step = try self.expr(1);
            _ = try self.expect(.kw_do);
            const body = try self.block(&.{.kw_end});
            const end = try self.expect(.kw_end);
            return self.newStmt(.{ .numeric_for = .{ .name = first.text, .start = begin, .limit = limit, .step = step, .body = body, .span = .{ .start = start, .end = end.span.end } } });
        }
        var names: std.ArrayList([]const u8) = .empty;
        try names.append(self.allocator, first.text);
        while (self.match(.comma)) try names.append(self.allocator, (try self.expect(.identifier)).text);
        _ = try self.expect(.kw_in);
        const values = try self.exprList();
        _ = try self.expect(.kw_do);
        const body = try self.block(&.{.kw_end});
        const end = try self.expect(.kw_end);
        return self.newStmt(.{ .generic_for = .{ .names = try names.toOwnedSlice(self.allocator), .values = values, .body = body, .span = .{ .start = start, .end = end.span.end } } });
    }

    fn functionStmt(self: *Parser, start: u32) Error!*Stmt {
        _ = try self.expect(.kw_function);
        var target: LValue = .{ .name = (try self.expect(.identifier)).text };
        while (self.match(.dot)) {
            const field = try self.expect(.identifier);
            const object = try self.lvalueAsExpr(target, start, field.span.start);
            const key = try self.stringExpr(field.text, field.span);
            target = .{ .index = .{ .object = object, .key = key } };
        }
        var insert_self = false;
        if (self.match(.colon)) {
            const field = try self.expect(.identifier);
            const object = try self.lvalueAsExpr(target, start, field.span.start);
            const key = try self.stringExpr(field.text, field.span);
            target = .{ .index = .{ .object = object, .key = key } };
            insert_self = true;
        }
        const fn_expr = try self.functionBody(start, insert_self);
        return self.newStmt(.{ .function_assign = .{ .target = target, .function = fn_expr, .span = .{ .start = start, .end = fn_expr.span().end } } });
    }

    fn localStmt(self: *Parser, start: u32) Error!*Stmt {
        _ = try self.expect(.kw_local);
        if (self.match(.kw_function)) {
            const name = try self.expect(.identifier);
            const fn_expr = try self.functionBody(start, false);
            return self.newStmt(.{ .local_function = .{ .name = name.text, .function = fn_expr, .span = .{ .start = start, .end = fn_expr.span().end } } });
        }
        var names: std.ArrayList([]const u8) = .empty;
        try names.append(self.allocator, (try self.expect(.identifier)).text);
        while (self.match(.comma)) try names.append(self.allocator, (try self.expect(.identifier)).text);
        var values: []const *Expr = &.{};
        var end = self.prev().span.end;
        if (self.match(.eq)) {
            values = try self.exprList();
            if (values.len != 0) end = values[values.len - 1].span().end;
        }
        return self.newStmt(.{ .local_assign = .{ .names = try names.toOwnedSlice(self.allocator), .values = values, .span = .{ .start = start, .end = end } } });
    }

    fn returnStmt(self: *Parser, start: u32) Error!*Stmt {
        const kw = try self.expect(.kw_return);
        var values: []const *Expr = &.{};
        var end = kw.span.end;
        if (!isBlockEnd(self.peek().tag) and self.peek().tag != .semi) {
            values = try self.exprList();
            end = values[values.len - 1].span().end;
        }
        return self.newStmt(.{ .return_stmt = .{ .values = values, .span = .{ .start = start, .end = end } } });
    }

    fn assignOrCallStmt(self: *Parser, start: u32) Error!*Stmt {
        const first_expr = try self.prefixExpr();
        if (isCall(first_expr) and self.peek().tag != .eq and self.peek().tag != .comma) {
            return self.newStmt(.{ .call = .{ .expr = first_expr, .span = .{ .start = start, .end = first_expr.span().end } } });
        }
        var targets: std.ArrayList(LValue) = .empty;
        try targets.append(self.allocator, try exprToLValue(first_expr));
        while (self.match(.comma)) {
            const e = try self.prefixExpr();
            try targets.append(self.allocator, try exprToLValue(e));
        }
        _ = try self.expect(.eq);
        const values = try self.exprList();
        return self.newStmt(.{ .assign = .{ .targets = try targets.toOwnedSlice(self.allocator), .values = values, .span = .{ .start = start, .end = values[values.len - 1].span().end } } });
    }

    fn exprList(self: *Parser) Error![]const *Expr {
        var out: std.ArrayList(*Expr) = .empty;
        try out.append(self.allocator, try self.expr(1));
        while (self.match(.comma)) try out.append(self.allocator, try self.expr(1));
        return try out.toOwnedSlice(self.allocator);
    }

    fn expr(self: *Parser, min_prec: u8) Error!*Expr {
        var lhs = try self.unaryExpr();
        while (binaryInfo(self.peek().tag)) |info| {
            if (info.prec < min_prec) break;
            _ = self.advance();
            const next_min: u8 = if (info.right_assoc) info.prec else info.prec + 1;
            const rhs = try self.expr(next_min);
            const node = try self.allocator.create(Expr);
            node.* = .{ .binary = .{ .op = info.op, .lhs = lhs, .rhs = rhs, .span = .{ .start = lhs.span().start, .end = rhs.span().end } } };
            lhs = node;
        }
        return lhs;
    }

    fn unaryExpr(self: *Parser) Error!*Expr {
        const op: ?UnaryOp = switch (self.peek().tag) {
            .minus => .neg,
            .kw_not => .not_,
            .hash => .len,
            else => null,
        };
        if (op) |u| {
            const start = self.advance().span.start;
            const inner = try self.expr(7);
            const node = try self.allocator.create(Expr);
            node.* = .{ .unary = .{ .op = u, .expr = inner, .span = .{ .start = start, .end = inner.span().end } } };
            return node;
        }
        return self.simpleExpr();
    }

    fn simpleExpr(self: *Parser) Error!*Expr {
        const t = self.peek();
        switch (t.tag) {
            .kw_nil => {
                _ = self.advance();
                return self.newExpr(.{ .nil_lit = t.span });
            },
            .kw_false, .kw_true => {
                _ = self.advance();
                return self.newExpr(.{ .bool_lit = .{ .value = t.tag == .kw_true, .span = t.span } });
            },
            .number => {
                _ = self.advance();
                return self.newExpr(.{ .number = .{ .raw = t.text, .span = t.span } });
            },
            .string => {
                _ = self.advance();
                return self.newExpr(.{ .string = .{ .value = t.decoded.?, .span = t.span } });
            },
            .ellipsis => {
                _ = self.advance();
                return self.newExpr(.{ .vararg = t.span });
            },
            .kw_function => {
                _ = self.advance();
                return self.functionBody(t.span.start, false);
            },
            .lbrace => return self.tableCtor(),
            .identifier, .lparen => return self.prefixExpr(),
            else => return error.UnexpectedToken,
        }
    }

    fn prefixExpr(self: *Parser) Error!*Expr {
        var base: *Expr = undefined;
        if (self.peek().tag == .identifier) {
            const t = self.advance();
            base = try self.newExpr(.{ .name = .{ .value = t.text, .span = t.span } });
        } else if (self.peek().tag == .lparen) {
            const open = self.advance();
            const inner = try self.expr(1);
            const close = try self.expect(.rparen);
            base = try self.newExpr(.{ .paren = .{ .expr = inner, .span = .{ .start = open.span.start, .end = close.span.end } } });
        } else return error.UnexpectedToken;

        while (true) switch (self.peek().tag) {
            .lbracket => {
                const start = base.span().start;
                _ = self.advance();
                const key = try self.expr(1);
                const close = try self.expect(.rbracket);
                base = try self.newExpr(.{ .index = .{ .object = base, .key = key, .span = .{ .start = start, .end = close.span.end } } });
            },
            .dot => {
                const start = base.span().start;
                _ = self.advance();
                const name = try self.expect(.identifier);
                const key = try self.stringExpr(name.text, name.span);
                base = try self.newExpr(.{ .index = .{ .object = base, .key = key, .span = .{ .start = start, .end = name.span.end } } });
            },
            .colon => {
                const start = base.span().start;
                _ = self.advance();
                const method = try self.expect(.identifier);
                const call_args = try self.args();
                const end = if (call_args.len == 0) self.prev().span.end else call_args[call_args.len - 1].span().end;
                base = try self.newExpr(.{ .method_call = .{ .object = base, .method = method.text, .args = call_args, .span = .{ .start = start, .end = end } } });
            },
            .lparen, .lbrace, .string => {
                const start = base.span().start;
                const call_args = try self.args();
                const end = self.prev().span.end;
                base = try self.newExpr(.{ .call = .{ .callee = base, .args = call_args, .span = .{ .start = start, .end = end } } });
            },
            else => break,
        };
        return base;
    }

    fn args(self: *Parser) Error![]const *Expr {
        if (self.match(.lparen)) {
            if (self.match(.rparen)) return &.{};
            const values = try self.exprList();
            _ = try self.expect(.rparen);
            return values;
        }
        if (self.peek().tag == .lbrace) {
            const one = try self.allocator.alloc(*Expr, 1);
            one[0] = try self.tableCtor();
            return one;
        }
        if (self.peek().tag == .string) {
            const t = self.advance();
            const one = try self.allocator.alloc(*Expr, 1);
            one[0] = try self.newExpr(.{ .string = .{ .value = t.decoded.?, .span = t.span } });
            return one;
        }
        return error.UnexpectedToken;
    }

    fn tableCtor(self: *Parser) Error!*Expr {
        const open = try self.expect(.lbrace);
        var fields: std.ArrayList(TableField) = .empty;
        while (self.peek().tag != .rbrace) {
            var field: TableField = undefined;
            if (self.match(.lbracket)) {
                const key = try self.expr(1);
                _ = try self.expect(.rbracket);
                _ = try self.expect(.eq);
                field = .{ .keyed = .{ .key = key, .value = try self.expr(1) } };
            } else if (self.peek().tag == .identifier and self.peekN(1).tag == .eq) {
                const name = self.advance();
                _ = self.advance();
                field = .{ .named = .{ .name = name.text, .value = try self.expr(1) } };
            } else {
                field = .{ .list = try self.expr(1) };
            }
            try fields.append(self.allocator, field);
            if (!(self.match(.comma) or self.match(.semi))) break;
            if (self.peek().tag == .rbrace) break;
        }
        const close = try self.expect(.rbrace);
        return self.newExpr(.{ .table = .{ .fields = try fields.toOwnedSlice(self.allocator), .span = .{ .start = open.span.start, .end = close.span.end } } });
    }

    fn functionBody(self: *Parser, start: u32, insert_self: bool) Error!*Expr {
        _ = try self.expect(.lparen);
        var params: std.ArrayList([]const u8) = .empty;
        if (insert_self) try params.append(self.allocator, "self");
        var is_vararg = false;
        if (!self.match(.rparen)) {
            while (true) {
                if (self.match(.ellipsis)) {
                    is_vararg = true;
                    break;
                }
                try params.append(self.allocator, (try self.expect(.identifier)).text);
                if (!self.match(.comma)) break;
                if (self.peek().tag == .ellipsis) {
                    _ = self.advance();
                    is_vararg = true;
                    break;
                }
            }
            _ = try self.expect(.rparen);
        }
        const body = try self.block(&.{.kw_end});
        const end = try self.expect(.kw_end);
        return self.newExpr(.{ .function = .{ .params = try params.toOwnedSlice(self.allocator), .is_vararg = is_vararg, .body = body, .span = .{ .start = start, .end = end.span.end } } });
    }

    fn lvalueAsExpr(self: *Parser, value: LValue, start: u32, end: u32) Error!*Expr {
        return switch (value) {
            .name => |name| self.newExpr(.{ .name = .{ .value = name, .span = .{ .start = start, .end = end } } }),
            .index => |idx| self.newExpr(.{ .index = .{ .object = idx.object, .key = idx.key, .span = .{ .start = start, .end = end } } }),
        };
    }

    fn stringExpr(self: *Parser, value: []const u8, span: Span) Error!*Expr {
        return self.newExpr(.{ .string = .{ .value = value, .span = span } });
    }

    fn newExpr(self: *Parser, value: Expr) Error!*Expr {
        const p = try self.allocator.create(Expr);
        p.* = value;
        return p;
    }
    fn newStmt(self: *Parser, value: Stmt) Error!*Stmt {
        const p = try self.allocator.create(Stmt);
        p.* = value;
        return p;
    }

    fn peek(self: *const Parser) Token {
        return self.tokens[@min(self.pos, self.tokens.len - 1)];
    }
    fn peekN(self: *const Parser, n: usize) Token {
        return self.tokens[@min(self.pos + n, self.tokens.len - 1)];
    }
    fn prev(self: *const Parser) Token {
        return self.tokens[self.pos - 1];
    }
    fn advance(self: *Parser) Token {
        const t = self.peek();
        if (self.pos < self.tokens.len) self.pos += 1;
        return t;
    }
    fn match(self: *Parser, tag: Tag) bool {
        if (self.peek().tag != tag) return false;
        _ = self.advance();
        return true;
    }
    fn expect(self: *Parser, tag: Tag) Error!Token {
        if (self.peek().tag != tag) return if (self.peek().tag == .eof) error.UnexpectedEof else error.UnexpectedToken;
        return self.advance();
    }
};

fn exprToLValue(expr: *Expr) Error!LValue {
    return switch (expr.*) {
        .name => |n| .{ .name = n.value },
        .index => |i| .{ .index = .{ .object = i.object, .key = i.key } },
        else => error.InvalidAssignment,
    };
}
fn isCall(expr: *const Expr) bool {
    return switch (expr.*) {
        .call, .method_call => true,
        else => false,
    };
}
fn isBlockEnd(tag: Tag) bool {
    return switch (tag) {
        .eof, .kw_end, .kw_else, .kw_elseif, .kw_until => true,
        else => false,
    };
}
fn containsTag(tags: []const Tag, tag: Tag) bool {
    for (tags) |t| if (t == tag) return true;
    return false;
}

const BinInfo = struct { op: BinaryOp, prec: u8, right_assoc: bool = false };
fn binaryInfo(tag: Tag) ?BinInfo {
    return switch (tag) {
        .kw_or => .{ .op = .or_, .prec = 1 },
        .kw_and => .{ .op = .and_, .prec = 2 },
        .lt => .{ .op = .lt, .prec = 3 },
        .le => .{ .op = .le, .prec = 3 },
        .gt => .{ .op = .gt, .prec = 3 },
        .ge => .{ .op = .ge, .prec = 3 },
        .eqeq => .{ .op = .eq, .prec = 3 },
        .ne => .{ .op = .ne, .prec = 3 },
        .dotdot => .{ .op = .concat, .prec = 4, .right_assoc = true },
        .plus => .{ .op = .add, .prec = 5 },
        .minus => .{ .op = .sub, .prec = 5 },
        .star => .{ .op = .mul, .prec = 6 },
        .slash => .{ .op = .div, .prec = 6 },
        .percent => .{ .op = .mod, .prec = 6 },
        .caret => .{ .op = .pow, .prec = 8, .right_assoc = true },
        else => null,
    };
}

fn keyword(s: []const u8) ?Tag {
    const pairs = [_]struct { []const u8, Tag }{
        .{ "and", .kw_and }, .{ "break", .kw_break }, .{ "do", .kw_do }, .{ "else", .kw_else }, .{ "elseif", .kw_elseif }, .{ "end", .kw_end }, .{ "false", .kw_false }, .{ "for", .kw_for }, .{ "function", .kw_function }, .{ "if", .kw_if }, .{ "in", .kw_in }, .{ "local", .kw_local }, .{ "nil", .kw_nil }, .{ "not", .kw_not }, .{ "or", .kw_or }, .{ "repeat", .kw_repeat }, .{ "return", .kw_return }, .{ "then", .kw_then }, .{ "true", .kw_true }, .{ "until", .kw_until }, .{ "while", .kw_while },
    };
    inline for (pairs) |p| if (std.mem.eql(u8, s, p[0])) return p[1];
    return null;
}
fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}
fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}
fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isHex(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}
fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

test "Lua 5.1 unknown escapes are accepted" {
    var chunk = try parse(std.testing.allocator, "return '\\q\\['");
    defer chunk.deinit();
    const ret = chunk.body[0].return_stmt;
    try std.testing.expectEqualStrings("q[", ret.values[0].string.value);
}

test "parses representative Lua 5.1 syntax" {
    const src =
        \\local x, y = 1, 2
        \\local function f(a, ...)
        \\  if a < 2 then return a elseif a == 2 then return ... else return a + 1 end
        \\end
        \\function M.foo:bar(z) self[z] = {x, y; k = f(z)} end
        \\for k, v in pairs(M) do print(k, v) end
        \\for i = 1, 10, 2 do x = x + i end
        \\repeat x = x - 1 until x == 0
        \\return M
    ;
    var chunk = try parse(std.testing.allocator, src);
    defer chunk.deinit();
    try std.testing.expect(chunk.body.len >= 7);
}

test "parentheses preserve single-result semantics" {
    var chunk = try parse(std.testing.allocator, "return (f())");
    defer chunk.deinit();
    const e = chunk.body[0].return_stmt.values[0];
    try std.testing.expect(e.* == .paren);
    try std.testing.expect(e.paren.expr.* == .call);
}
