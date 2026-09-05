const std = @import("std");

pub const Error = error{
    UnexpectedNumber,
    UnexpectedOperator,
    UnrecognisedWord,
    UnrecognisedPunctuation,
    UnexpectedClosingBracket,
    UnclosedBracket,
    MissingOperand,
    DivisionByZero,
    InvalidArgument,
    StackExhausted,
    InvalidNumber,
};

const Op = enum {
    negative, positive, plus, minus, times, divide, mod, fmod,
    open, and_, or_, not_, equality, less, greater, less_eq, greater_eq, not_eq,
    round, exponent, sine, cosine, tangens, arcsine, arccos, arctan, exp, ln,
    abs, floor, trunc, ceil, pow, pi, sqrt,
};

fn precedence(op: Op) i8 {
    return switch (op) {
        .negative, .positive, .exponent => 10,
        .sine, .cosine, .tangens, .arcsine, .arccos, .arctan, .exp, .ln,
        .abs, .floor, .trunc, .ceil, .not_, .sqrt => 9,
        .pow => 8,
        .times, .divide, .mod, .fmod => 7,
        .plus, .minus => 6,
        .round => 5,
        .equality, .less, .greater, .less_eq, .greater_eq, .not_eq => 4,
        .and_ => 3,
        .or_ => 2,
        .pi => 0,
        .open => -1,
    };
}

fn wordOp(word: []const u8) ?Op {
    const words = .{
        .{ "mod", Op.mod }, .{ "fmod", Op.fmod }, .{ "and", Op.and_ }, .{ "or", Op.or_ },
        .{ "not", Op.not_ }, .{ "round", Op.round }, .{ "div", Op.divide }, .{ "e", Op.exponent },
        .{ "sin", Op.sine }, .{ "cos", Op.cosine }, .{ "tan", Op.tangens }, .{ "asin", Op.arcsine },
        .{ "acos", Op.arccos }, .{ "atan", Op.arctan }, .{ "exp", Op.exp }, .{ "ln", Op.ln },
        .{ "abs", Op.abs }, .{ "trunc", Op.trunc }, .{ "floor", Op.floor }, .{ "ceil", Op.ceil },
        .{ "pi", Op.pi }, .{ "sqrt", Op.sqrt },
    };
    inline for (words) |entry| if (std.ascii.eqlIgnoreCase(word, entry[0])) return entry[1];
    return null;
}

fn isUnary(op: Op) bool {
    return switch (op) {
        .negative, .positive, .not_, .sine, .cosine, .tangens, .arcsine, .arccos, .arctan,
        .exp, .ln, .abs, .floor, .trunc, .ceil, .sqrt => true,
        else => false,
    };
}

fn pop(stack: *std.ArrayList(f64)) !f64 {
    if (stack.items.len == 0) return Error.MissingOperand;
    return stack.pop().?;
}

fn phpInt(v: f64) i64 {
    if (!std.math.isFinite(v)) return 0;
    const t = @trunc(v);
    if (t >= @as(f64, @floatFromInt(std.math.maxInt(i64)))) return std.math.maxInt(i64);
    if (t <= @as(f64, @floatFromInt(std.math.minInt(i64)))) return std.math.minInt(i64);
    return @intFromFloat(t);
}

fn phpRound(value: f64, digits: i64) f64 {
    if (digits == 0) return std.math.round(value);
    if (digits > 308 or digits < -308) return value;
    const factor = std.math.pow(f64, 10.0, @floatFromInt(if (digits < 0) -digits else digits));
    if (digits > 0) return std.math.round(value * factor) / factor;
    return std.math.round(value / factor) * factor;
}

fn apply(a: std.mem.Allocator, op: Op, stack: *std.ArrayList(f64)) !void {
    if (isUnary(op)) {
        const x = try pop(stack);
        const result: f64 = switch (op) {
            .negative => -x,
            .positive => x,
            .not_ => if (x == 0) 1 else 0,
            .sine => @sin(x),
            .cosine => @cos(x),
            .tangens => @tan(x),
            .arcsine => if (x < -1 or x > 1) return Error.InvalidArgument else std.math.asin(x),
            .arccos => if (x < -1 or x > 1) return Error.InvalidArgument else std.math.acos(x),
            .arctan => std.math.atan(x),
            .exp => @exp(x),
            .ln => if (x <= 0) return Error.InvalidArgument else @log(x),
            .abs => @abs(x),
            .floor => @floor(x),
            .trunc => @trunc(x),
            .ceil => @ceil(x),
            .sqrt => if (x < 0) return Error.InvalidArgument else @sqrt(x),
            else => unreachable,
        };
        try stack.append(a, result);
        return;
    }
    if (op == .open or op == .pi) return Error.UnexpectedOperator;
    const right = try pop(stack);
    const left = try pop(stack);
    const result: f64 = switch (op) {
        .times => left * right,
        .divide => if (right == 0) return Error.DivisionByZero else left / right,
        .mod => blk: {
            const r = phpInt(right);
            if (r == 0) return Error.DivisionByZero;
            break :blk @floatFromInt(@rem(phpInt(left), r));
        },
        .fmod => if (right == 0) return Error.DivisionByZero else @rem(left, right),
        .plus => left + right,
        .minus => left - right,
        .and_ => if (left != 0 and right != 0) 1 else 0,
        .or_ => if (left != 0 or right != 0) 1 else 0,
        .equality => if (left == right) 1 else 0,
        .less => if (left < right) 1 else 0,
        .greater => if (left > right) 1 else 0,
        .less_eq => if (left <= right) 1 else 0,
        .greater_eq => if (left >= right) 1 else 0,
        .not_eq => if (left != right) 1 else 0,
        .round => phpRound(left, phpInt(right)),
        .exponent => left * std.math.pow(f64, 10.0, right),
        .pow => std.math.pow(f64, left, right),
        else => unreachable,
    };
    try stack.append(a, result);
}

fn parsePhpFloat(raw: []const u8) !f64 {
    var end: usize = 0;
    var seen_dot = false;
    while (end < raw.len) : (end += 1) {
        const c = raw[end];
        if (c >= '0' and c <= '9') continue;
        if (c == '.' and !seen_dot) { seen_dot = true; continue; }
        break;
    }
    if (end == 0 or (end == 1 and raw[0] == '.')) return Error.InvalidNumber;
    return std.fmt.parseFloat(f64, raw[0..end]) catch Error.InvalidNumber;
}

fn appendNormalized(a: std.mem.Allocator, out: *std.ArrayList(u8), raw: []const u8) !void {
    var i: usize = 0;
    while (i < raw.len) {
        if (std.mem.startsWith(u8, raw[i..], "&lt;")) { try out.append(a, '<'); i += 4; continue; }
        if (std.mem.startsWith(u8, raw[i..], "&gt;")) { try out.append(a, '>'); i += 4; continue; }
        if (std.mem.startsWith(u8, raw[i..], "&minus;")) { try out.append(a, '-'); i += 7; continue; }
        if (std.mem.startsWith(u8, raw[i..], "−")) { try out.append(a, '-'); i += "−".len; continue; }
        try out.append(a, raw[i]);
        i += 1;
    }
}

pub fn eval(a: std.mem.Allocator, raw: []const u8) !f64 {
    var normalized: std.ArrayList(u8) = .empty;
    defer normalized.deinit(a);
    try appendNormalized(a, &normalized, raw);
    const expr = normalized.items;
    var operands: std.ArrayList(f64) = .empty;
    defer operands.deinit(a);
    var operators: std.ArrayList(Op) = .empty;
    defer operators.deinit(a);
    var p: usize = 0;
    var expecting_expression = true;
    while (p < expr.len) {
        if (operands.items.len > 100 or operators.items.len > 100) return Error.StackExhausted;
        const c = expr[p];
        if (std.ascii.isWhitespace(c)) { p += 1; continue; }
        if ((c >= '0' and c <= '9') or c == '.') {
            if (!expecting_expression) return Error.UnexpectedNumber;
            var n = p;
            while (n < expr.len and ((expr[n] >= '0' and expr[n] <= '9') or expr[n] == '.')) : (n += 1) {}
            try operands.append(a, try parsePhpFloat(expr[p..n]));
            p = n;
            expecting_expression = false;
            continue;
        }
        var op: Op = undefined;
        if (std.ascii.isAlphabetic(c)) {
            var n = p + 1;
            while (n < expr.len and std.ascii.isAlphabetic(expr[n])) : (n += 1) {}
            const word = expr[p..n];
            op = wordOp(word) orelse return Error.UnrecognisedWord;
            p = n;
            if (op == .exponent and expecting_expression) {
                try operands.append(a, std.math.e);
                expecting_expression = false;
                continue;
            }
            if (op == .pi) {
                if (!expecting_expression) return Error.UnexpectedNumber;
                try operands.append(a, std.math.pi);
                expecting_expression = false;
                continue;
            }
            if (isUnary(op)) {
                if (!expecting_expression) return Error.UnexpectedOperator;
                try operators.append(a, op);
                continue;
            }
        } else if (p + 1 < expr.len and std.mem.eql(u8, expr[p..p+2], "<=")) { op = .less_eq; p += 2;
        } else if (p + 1 < expr.len and std.mem.eql(u8, expr[p..p+2], ">=")) { op = .greater_eq; p += 2;
        } else if (p + 1 < expr.len and (std.mem.eql(u8, expr[p..p+2], "<>") or std.mem.eql(u8, expr[p..p+2], "!="))) { op = .not_eq; p += 2;
        } else {
            switch (c) {
            '+' => { p += 1; if (expecting_expression) { try operators.append(a, .positive); continue; } else op = .plus; },
            '-' => { p += 1; if (expecting_expression) { try operators.append(a, .negative); continue; } else op = .minus; },
            '*' => { op = .times; p += 1; }, '/' => { op = .divide; p += 1; }, '^' => { op = .pow; p += 1; },
            '(' => { if (!expecting_expression) return Error.UnexpectedOperator; try operators.append(a, .open); p += 1; continue; },
            ')' => {
                var found_open = false;
                while (operators.items.len != 0) {
                    const top = operators.items[operators.items.len - 1];
                    if (top == .open) { _ = operators.pop(); found_open = true; break; }
                    _ = operators.pop(); try apply(a, top, &operands);
                }
                if (!found_open) return Error.UnexpectedClosingBracket;
                expecting_expression = false; p += 1; continue;
            },
            '=' => { op = .equality; p += 1; }, '<' => { op = .less; p += 1; }, '>' => { op = .greater; p += 1; },
                else => return Error.UnrecognisedPunctuation,
            }
        }
        if (expecting_expression) return Error.UnexpectedOperator;
        while (operators.items.len != 0) {
            const top = operators.items[operators.items.len - 1];
            if (precedence(op) > precedence(top)) break;
            _ = operators.pop();
            try apply(a, top, &operands);
        }
        try operators.append(a, op);
        expecting_expression = true;
    }
    while (operators.items.len != 0) {
        const op = operators.pop().?;
        if (op == .open) return Error.UnclosedBracket;
        try apply(a, op, &operands);
    }
    if (operands.items.len != 1) return Error.MissingOperand;
    return operands.items[0];
}

pub fn format(a: std.mem.Allocator, value: f64) ![]const u8 {
    if (value == 0) return "0";
    if (std.math.isNan(value) or std.math.isInf(value)) return Error.InvalidArgument;
    return std.fmt.allocPrint(a, "{d}", .{value});
}

test "MediaWiki ExprParser precedence and functions" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(f64, 335), try eval(a, "6+329"));
    try std.testing.expectEqual(@as(f64, 4), try eval(a, "-2^2"));
    try std.testing.expectEqual(@as(f64, 1000), try eval(a, "1e3"));
    try std.testing.expectEqual(@as(f64, 1), try eval(a, "2 < 3 and not 0"));
    try std.testing.expectEqual(@as(f64, 3), try eval(a, "sqrt 9"));
    try std.testing.expectEqual(@as(f64, 3.14), try eval(a, "3.14159 round 2"));
}
