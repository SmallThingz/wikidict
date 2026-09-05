const std = @import("std");
const lua = @import("root.zig");
const model = @import("module_model.zig");

const Truth = enum { no, yes, maybe };
const Flow = enum { continues, terminates };
const finite_value_cap: usize = 4096;

const FrameKind = enum { current, parent };
const ArgsKind = enum { current, parent };

const Scalar = struct {
    unknown: bool = false,
    any_string: bool = false,
    may_nil: bool = false,
    may_false: bool = false,
    may_true: bool = false,
    strings: []const []const u8 = &.{},
    patterns: []const []const u8 = &.{},
    numbers: []const f64 = &.{},
};

const Builtin = enum { parameters_process, languages_get_by_code };
const ExternalFunction = struct { module: []const u8, name: []const u8 };

const AbsTable = struct {
    fields: std.StringHashMapUnmanaged(Value) = .empty,
};

const Value = union(enum) {
    unknown,
    scalar: Scalar,
    frame: FrameKind,
    args: ArgsKind,
    function_ref: *const lua.Expr,
    table_ref: *AbsTable,
    builtin: Builtin,
    module_ref: []const u8,
    external_function: ExternalFunction,
};

const ParamDomain = struct {
    top: bool = false,
    missing: bool = false,
    values: std.ArrayList([]const u8) = .empty,
};

const Entry = struct {
    page_id: u64,
    fn_start: u32,
    module: []const u8,
    function: []const u8,
    current: std.StringHashMapUnmanaged(*ParamDomain) = .empty,
    parent: std.StringHashMapUnmanaged(*ParamDomain) = .empty,
    current_dynamic_keys: bool = false,
    parent_dynamic_keys: bool = false,
};

const Env = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(Value) = .empty,

    fn clone(self: *const Env) !Env {
        return .{ .allocator = self.allocator, .map = try self.map.clone(self.allocator) };
    }

    fn put(self: *Env, name: []const u8, value: Value) !void {
        try self.map.put(self.allocator, name, value);
    }

    fn get(self: *const Env, name: []const u8) Value {
        return self.map.get(name) orelse .unknown;
    }
};


fn mergeEnvInto(dst: *Env, src: *const Env) !void {
    var sit = src.map.iterator();
    while (sit.next()) |entry| {
        const gop = try dst.map.getOrPut(dst.allocator, entry.key_ptr.*);
        if (gop.found_existing) gop.value_ptr.* = mergeValues(dst.allocator, gop.value_ptr.*, entry.value_ptr.*)
        else gop.value_ptr.* = mergeValues(dst.allocator, nilValue(), entry.value_ptr.*);
    }
    var dit = dst.map.iterator();
    while (dit.next()) |entry| {
        if (!src.map.contains(entry.key_ptr.*)) entry.value_ptr.* = mergeValues(dst.allocator, entry.value_ptr.*, nilValue());
    }
}

const Stats = struct {
    sites: u64 = 0,
    yes: u64 = 0,
    no: u64 = 0,
    maybe: u64 = 0,
    dependency_sites: u64 = 0,
    dependency_resolved: u64 = 0,
    dependency_unknown: u64 = 0,
};

const Evaluator = struct {
    allocator: std.mem.Allocator,
    entry: *const Entry,
    source: []const u8,
    writer: *std.Io.Writer,
    stats: *Stats,
    unstable_names: std.StringHashMapUnmanaged(void) = .empty,
    module_env: *const Env,
    active_functions: *std.AutoHashMapUnmanaged(u32, void),
    current_fn_start: u32 = 0,
    return_values: ?[]const Value = null,
    module_titles: *const std.ArrayList([]const u8),

    fn run(self: *Evaluator, f: lua.FunctionExpr) anyerror!void {
        try collectNestedWrites(self.allocator, f.body, &self.unstable_names);
        if (self.entry.page_id == 6884586) {
            std.debug.print("PALI_UNSTABLE passages={} frame={} count={d}", .{ self.unstable_names.contains("passages"), self.unstable_names.contains("frame"), self.unstable_names.count() });
            var uit = self.unstable_names.iterator(); while (uit.next()) |ue| std.debug.print(" {s}", .{ue.key_ptr.*}); std.debug.print("\n", .{});
        }
        var env = try self.module_env.clone();
        if (f.params.len != 0) {
            try env.put(f.params[0], .{ .frame = .current });
            for (f.params[1..]) |param| try env.put(param, .unknown);
        }
        self.current_fn_start = f.span.start;
        try self.active_functions.put(self.allocator, f.span.start, {});
        defer _ = self.active_functions.remove(f.span.start);
        _ = try self.walkBlock(f.body, &env, true);
    }

    fn walkBlock(self: *Evaluator, body: lua.Block, env: *Env, allow_proof: bool) anyerror!Flow {
        var local_names: std.ArrayList([]const u8) = .empty;
        var old_values: std.ArrayList(?Value) = .empty;
        defer local_names.deinit(self.allocator);
        defer old_values.deinit(self.allocator);
        var flow: Flow = .continues;
        for (body) |stmt| {
            flow = try self.walkStmt(stmt, env, allow_proof, &local_names, &old_values);
            if (flow == .terminates) break;
        }
        var i = local_names.items.len;
        while (i != 0) {
            i -= 1;
            const name = local_names.items[i];
            if (old_values.items[i]) |old| try env.put(name, old) else _ = env.map.remove(name);
        }
        return flow;
    }

    fn declareLocal(self: *Evaluator, env: *Env, name: []const u8, value: Value, names: *std.ArrayList([]const u8), olds: *std.ArrayList(?Value)) !void {
        try names.append(self.allocator, name);
        try olds.append(self.allocator, env.map.get(name));
        try env.put(name, value);
    }

    fn walkStmt(self: *Evaluator, stmt: *const lua.Stmt, env: *Env, allow_proof: bool, locals: *std.ArrayList([]const u8), olds: *std.ArrayList(?Value)) anyerror!Flow {
        return switch (stmt.*) {
            .empty => .continues,
            .break_stmt => .terminates,
            .local_assign => |s| blk: {
                const values = try self.evalValueList(s.values, s.names.len, env);
                for (s.names, 0..) |name, i| {
                    const value = if (self.unstable_names.contains(name)) Value.unknown else values[i];
                    try self.declareLocal(env, name, value, locals, olds);
                }
                break :blk .continues;
            },
            .assign => |s| blk: {
                const values = try self.evalValueList(s.values, s.targets.len, env);
                for (s.targets, 0..) |target, i| switch (target) {
                    .name => |name| try env.put(name, if (self.unstable_names.contains(name)) .unknown else values[i]),
                    .index => {},
                };
                break :blk .continues;
            },
            .call => |s| blk: { _ = try self.eval(s.expr, env); break :blk .continues; },
            .do_block => |s| try self.walkBlock(s.body, env, allow_proof),
            .if_stmt => |s| try self.walkIf(s, env, allow_proof),
            .while_loop => |s| blk: {
                try self.reportBranch(s.cond, @intCast(s.span.start), false, env, "while");
                var inner = try env.clone();
                _ = try self.walkBlock(s.body, &inner, false);
                try self.invalidateAssigned(s.body, env);
                break :blk .continues;
            },
            .repeat_loop => |s| blk: {
                var inner = try env.clone();
                _ = try self.walkBlock(s.body, &inner, false);
                try self.reportBranch(s.cond, @intCast(s.span.start), false, &inner, "repeat");
                try self.invalidateAssigned(s.body, env);
                break :blk .continues;
            },
            .numeric_for => |s| blk: {
                var inner = try env.clone();
                try inner.put(s.name, .unknown);
                _ = try self.walkBlock(s.body, &inner, false);
                try self.invalidateAssigned(s.body, env);
                break :blk .continues;
            },
            .generic_for => |s| blk: {
                var inner = try env.clone();
                for (s.names) |name| try inner.put(name, .unknown);
                _ = try self.walkBlock(s.body, &inner, false);
                try self.invalidateAssigned(s.body, env);
                break :blk .continues;
            },
            .function_assign => |s| blk: { switch (s.target) { .name => |name| try env.put(name, .{ .function_ref = s.function }), .index => {}, }
                break :blk .continues; },
            .local_function => |s| blk: { try self.declareLocal(env, s.name, .{ .function_ref = s.function }, locals, olds); break :blk .continues; },
            .return_stmt => |s| blk: {
                const values = if (s.values.len == 0) blk2: {
                    const one = try self.allocator.alloc(Value, 1); one[0] = nilValue(); break :blk2 one;
                } else try self.evalValueList(s.values, null, env);
                self.return_values = if (self.return_values) |old| try mergeValueLists(self.allocator, old, values) else values;
                break :blk .terminates;
            },
        };
    }

    fn walkIf(self: *Evaluator, st: anytype, env: *Env, allow_proof: bool) anyerror!Flow {
        const base = try env.clone();
        var joined: ?Env = null;
        var fallthrough = true;
        var prior_maybe = false;

        for (st.branches, 0..) |branch, i| {
            if (!fallthrough) break;
            const result = if (allow_proof and !prior_maybe) truth(try self.eval(branch.cond, &base)) else .maybe;
            try self.reportBranchResult(branch.cond, @intCast(st.span.start), result, if (i == 0) "if" else "elseif");
            switch (result) {
                .no => continue,
                .yes => {
                    var branch_env = try base.clone();
                    const branch_flow = try self.walkBlock(branch.body, &branch_env, allow_proof and !prior_maybe);
                    if (branch_flow == .continues) {
                        if (joined) |*acc| try mergeEnvInto(acc, &branch_env) else joined = branch_env;
                    }
                    fallthrough = false;
                },
                .maybe => {
                    prior_maybe = true;
                    var branch_env = try base.clone();
                    const branch_flow = try self.walkBlock(branch.body, &branch_env, false);
                    if (branch_flow == .continues) {
                        if (joined) |*acc| try mergeEnvInto(acc, &branch_env) else joined = branch_env;
                    }
                },
            }
        }

        if (fallthrough) {
            if (st.else_body) |body| {
                var else_env = try base.clone();
                const else_flow = try self.walkBlock(body, &else_env, allow_proof and !prior_maybe);
                if (else_flow == .continues) {
                    if (joined) |*acc| try mergeEnvInto(acc, &else_env) else joined = else_env;
                }
            } else {
                if (joined) |*acc| try mergeEnvInto(acc, &base) else joined = base;
            }
        }
        if (joined) |result_env| {
            env.map.deinit(self.allocator);
            env.map = result_env.map;
            return .continues;
        }
        return .terminates;
    }

    fn invalidateAssigned(self: *Evaluator, body: lua.Block, env: *Env) anyerror!void {
        for (body) |stmt| switch (stmt.*) {
            .assign => |s| for (s.targets) |target| switch (target) { .name => |name| if (env.map.contains(name)) try env.put(name, .unknown), .index => {} },
            .do_block => |s| try self.invalidateAssigned(s.body, env),
            .if_stmt => |s| {
                for (s.branches) |b| try self.invalidateAssigned(b.body, env);
                if (s.else_body) |b| try self.invalidateAssigned(b, env);
            },
            .while_loop => |s| try self.invalidateAssigned(s.body, env),
            .repeat_loop => |s| try self.invalidateAssigned(s.body, env),
            .numeric_for => |s| try self.invalidateAssigned(s.body, env),
            .generic_for => |s| try self.invalidateAssigned(s.body, env),
            .function_assign => |s| switch (s.target) { .name => |name| if (env.map.contains(name)) try env.put(name, .unknown), .index => {} },
            else => {},
        };
    }

    fn reportBranch(self: *Evaluator, cond: *const lua.Expr, stmt_start: u32, allow_proof: bool, env: *const Env, kind: []const u8) !void {
        const result = if (allow_proof) truth(try self.eval(cond, env)) else .maybe;
        try self.reportBranchResult(cond, stmt_start, result, kind);
    }

    fn reportBranchResult(self: *Evaluator, cond: *const lua.Expr, stmt_start: u32, result: Truth, kind: []const u8) !void {
        self.stats.sites += 1;
        switch (result) { .yes => self.stats.yes += 1, .no => self.stats.no += 1, .maybe => self.stats.maybe += 1 }
        if (result == .maybe) return;
        const span = cond.span();
        try self.writer.print("B\t{d}\t{d}\t{d}\t{d}\t{s}\t{s}\t", .{ self.entry.page_id, self.current_fn_start, stmt_start, span.start, kind, if (result == .yes) "true" else "false" });
        try writeField(self.writer, std.mem.trim(u8, self.source[span.start..span.end], " \t\r\n"));
        try self.writer.writeByte('\n');
    }

    fn eval(self: *Evaluator, expr: *const lua.Expr, env: *const Env) anyerror!Value {
        return switch (expr.*) {
            .nil_lit => nilValue(),
            .bool_lit => |b| if (b.value) trueValue() else falseValue(),
            .number => |n| numberValue(self.allocator, std.fmt.parseFloat(f64, n.raw) catch return .unknown),
            .string => |s| stringValueScalar(self.allocator, s.value),
            .name => |n| if (self.unstable_names.contains(n.value)) .unknown else env.get(n.value),
            .paren => |pval| try self.eval(pval.expr, env),
            .vararg => .unknown,
            .function => .{ .function_ref = expr },
            .table => |t| try self.evalTable(t.fields, env),
            .index => |idx| try self.evalIndex(idx.object, idx.key, env),
            .method_call => |call| try self.evalMethod(call.object, call.method, call.args, env),
            .call => |call| try self.evalCall(expr, call.callee, call.args, env),
            .unary => |u| try self.evalUnary(u.op, u.expr, env),
            .binary => |b| try self.evalBinary(b.op, b.lhs, b.rhs, env),
        };
    }

    fn evalIndex(self: *Evaluator, object_expr: *const lua.Expr, key_expr: *const lua.Expr, env: *const Env) !Value {
        if (isHeadwordPagename(object_expr, key_expr)) return .{ .scalar = .{ .any_string = true } };
        if (requiredMemberBuiltin(object_expr, key_expr)) |builtin| return .{ .builtin = builtin };
        const object = try self.eval(object_expr, env);
        const key = try self.eval(key_expr, env);
        if (self.entry.page_id == 6884586) {
            const os = object_expr.span(); const ks = key_expr.span();
            const ot = std.mem.trim(u8,self.source[os.start..os.end]," \t\r\n");
            if (std.mem.indexOf(u8, ot, "frame") != null) std.debug.print("PALI_INDEX object={s} tag={s} key={s} keytag={s}\n", .{ot,@tagName(object),std.mem.trim(u8,self.source[ks.start..ks.end]," \t\r\n"),@tagName(key)});
        }
        return switch (object) {
            .frame => |frame| blk: {
                const key_text = keyText(self.allocator, key) orelse break :blk .unknown;
                break :blk if (std.mem.eql(u8, key_text, "args")) .{ .args = if (frame == .current) .current else .parent } else .unknown;
            },
            .args => |which| blk: {
                const key_text = keyText(self.allocator, key) orelse break :blk .unknown;
                break :blk self.lookupArg(which, key_text);
            },
            .table_ref => |table| self.lookupTable(table, key),
            .module_ref => |module| blk: {
                const member = keyText(self.allocator, key) orelse break :blk .unknown;
                if (std.mem.eql(u8, module, "Module:parameters") and std.mem.eql(u8, member, "process")) break :blk .{ .builtin = .parameters_process };
                if (std.mem.eql(u8, module, "Module:languages") and std.mem.eql(u8, member, "getByCode")) break :blk .{ .builtin = .languages_get_by_code };
                break :blk .{ .external_function = .{ .module = module, .name = member } };
            },
            else => .unknown,
        };
    }

    fn lookupTable(self: *Evaluator, table: *AbsTable, key: Value) Value {
        if (key != .scalar or key.scalar.unknown or key.scalar.any_string or key.scalar.may_false or key.scalar.may_true) return .unknown;
        var out: ?Value = if (key.scalar.may_nil) nilValue() else null;
        for (key.scalar.strings) |text| {
            const value = table.fields.get(text) orelse nilValue();
            out = if (out) |old| mergeValues(self.allocator, old, value) else value;
        }
        for (key.scalar.numbers) |num| {
            if (@floor(num) != num) return .unknown;
            const text = std.fmt.allocPrint(self.allocator, "{d}", .{@as(i64, @intFromFloat(num))}) catch return .unknown;
            const value = table.fields.get(text) orelse nilValue();
            out = if (out) |old| mergeValues(self.allocator, old, value) else value;
        }
        return out orelse .unknown;
    }

    fn lookupArg(self: *Evaluator, which: ArgsKind, key: []const u8) Value {
        const map = if (which == .current) &self.entry.current else &self.entry.parent;
        const dynamic_keys = if (which == .current) self.entry.current_dynamic_keys else self.entry.parent_dynamic_keys;
        const domain = map.get(key) orelse {
            if (self.entry.page_id == 6884586) std.debug.print("PALI_LOOKUP miss which={s} key={s} dyn={} count={d}\n", .{@tagName(which),key,dynamic_keys,map.count()});
            return if (dynamic_keys) .unknown else nilValue();
        };
        if (self.entry.page_id == 6884586 and std.mem.eql(u8,key,"passages")) std.debug.print("PALI_LOOKUP hit top={} missing={} vals={d}\n", .{domain.top,domain.missing,domain.values.items.len});
        const strings = self.allocator.alloc([]const u8, domain.values.items.len) catch return .unknown;
        @memcpy(strings, domain.values.items);
        return .{ .scalar = .{ .any_string = domain.top, .may_nil = domain.missing, .strings = strings } };
    }


    fn evalTable(self: *Evaluator, fields: []const lua.TableField, env: *const Env) anyerror!Value {
        const table = try self.allocator.create(AbsTable);
        table.* = .{};
        var list_index: usize = 1;
        for (fields) |field| switch (field) {
            .list => |value| {
                const key = try std.fmt.allocPrint(self.allocator, "{d}", .{list_index});
                try table.fields.put(self.allocator, key, try self.eval(value, env));
                list_index += 1;
            },
            .named => |value| try table.fields.put(self.allocator, value.name, try self.eval(value.value, env)),
            .keyed => |value| {
                const key = keyText(self.allocator, try self.eval(value.key, env)) orelse continue;
                try table.fields.put(self.allocator, key, try self.eval(value.value, env));
            },
        };
        return .{ .table_ref = table };
    }

    fn evalMethod(self: *Evaluator, object_expr: *const lua.Expr, method: []const u8, args: []const *lua.Expr, env: *const Env) !Value {
        const object = try self.eval(object_expr, env);
        if (object == .frame and object.frame == .current and std.mem.eql(u8, method, "getParent") and args.len == 0)
            return .{ .frame = .parent };
        if (object == .scalar and std.mem.eql(u8, method, "getCode") and args.len == 0) return object;
        if (object == .scalar and std.mem.eql(u8, method, "sub") and args.len >= 1) {
            const start_v = try self.eval(args[0], env);
            const start = singletonNumber(start_v) orelse return .unknown;
            const end: ?f64 = if (args.len >= 2) singletonNumber(try self.eval(args[1], env)) else null;
            return substringValue(self.allocator, object.scalar, start, end);
        }
        return .unknown;
    }

    fn evalCall(self: *Evaluator, whole: *const lua.Expr, callee: *const lua.Expr, args: []const *lua.Expr, env: *const Env) anyerror!Value {
        const callee_value = try self.eval(callee, env);
        if (callee_value == .function_ref) return try self.evalLocalFunction(callee_value.function_ref, args, env);
        if (callee_value == .external_function) return .unknown;
        if (callee_value == .builtin) return switch (callee_value.builtin) {
            .parameters_process => if (args.len != 0) try self.eval(args[0], env) else .unknown,
            .languages_get_by_code => if (args.len != 0) try self.eval(args[0], env) else .unknown,
        };
        const name = exprPath(callee) orelse return .unknown;
        if ((std.mem.eql(u8, name, "require") or std.mem.eql(u8, name, "mw.loadData")) and args.len != 0) {
            var module_value = try self.eval(args[0], env);
            if (module_value == .unknown) module_value = dependencyPatternValue(self.allocator, args[0]);
            const is_require = std.mem.eql(u8, name, "require");
            try self.reportDependency(whole.span(), if (is_require) "require" else "loadData", module_value);
            if (is_require) if (singletonString(module_value)) |module| return .{ .module_ref = module };
            return .unknown;
        }
        if (std.mem.eql(u8, name, "type") and args.len != 0) return typeValue(self.allocator, try self.eval(args[0], env));
        if (std.mem.eql(u8, name, "tonumber") and args.len != 0) return tonumberValue(self.allocator, try self.eval(args[0], env));
        if (std.mem.eql(u8, name, "tostring") and args.len != 0) return tostringValue(self.allocator, try self.eval(args[0], env));
        return .unknown;
    }


    fn evalValueList(self: *Evaluator, exprs: []const *lua.Expr, desired: ?usize, env: *const Env) anyerror![]const Value {
        var out: std.ArrayList(Value) = .empty;
        if (exprs.len != 0) {
            for (exprs, 0..) |expr, i| {
                if (i + 1 == exprs.len) {
                    const tail = try self.evalMulti(expr, env);
                    try out.appendSlice(self.allocator, tail);
                } else {
                    try out.append(self.allocator, try self.eval(expr, env));
                }
            }
        }
        if (desired) |n| {
            while (out.items.len < n) try out.append(self.allocator, nilValue());
            if (out.items.len > n) out.shrinkRetainingCapacity(n);
        }
        return try out.toOwnedSlice(self.allocator);
    }

    fn evalMulti(self: *Evaluator, expr: *const lua.Expr, env: *const Env) anyerror![]const Value {
        if (expr.* == .call) {
            const callee_value = try self.eval(expr.call.callee, env);
            if (callee_value == .function_ref) return try self.evalLocalFunctionReturns(callee_value.function_ref, expr.call.args, env);
        }
        const one = try self.allocator.alloc(Value, 1);
        one[0] = try self.eval(expr, env);
        return one;
    }

    fn evalLocalFunction(self: *Evaluator, fn_expr: *const lua.Expr, args: []const *lua.Expr, caller_env: *const Env) anyerror!Value {
        const values = try self.evalLocalFunctionReturns(fn_expr, args, caller_env);
        return if (values.len == 0) nilValue() else values[0];
    }

    fn evalLocalFunctionReturns(self: *Evaluator, fn_expr: *const lua.Expr, args: []const *lua.Expr, caller_env: *const Env) anyerror![]const Value {
        if (fn_expr.* != .function) return &.{Value.unknown};
        const f = fn_expr.function;
        const start = f.span.start;
        if (self.active_functions.contains(start)) return &.{Value.unknown};

        const arg_values = try self.evalValueList(args, f.params.len, caller_env);
        var child = try self.module_env.clone();
        for (f.params, 0..) |param, i| try child.put(param, arg_values[i]);
        try collectNestedWrites(self.allocator, f.body, &self.unstable_names);

        const saved_start = self.current_fn_start;
        const saved_returns = self.return_values;
        self.current_fn_start = start;
        self.return_values = null;
        try self.active_functions.put(self.allocator, start, {});
        defer {
            _ = self.active_functions.remove(start);
            self.current_fn_start = saved_start;
            self.return_values = saved_returns;
        }
        _ = try self.walkBlock(f.body, &child, true);
        if (self.return_values) |values| return values;
        const one = try self.allocator.alloc(Value, 1); one[0] = nilValue(); return one;
    }

    fn reportDependency(self: *Evaluator, span: lua.Span, kind: []const u8, value: Value) !void {
        self.stats.dependency_sites += 1;
        if (value != .scalar or value.scalar.unknown or value.scalar.any_string or value.scalar.may_true or value.scalar.may_false or value.scalar.numbers.len != 0 or (value.scalar.strings.len == 0 and value.scalar.patterns.len == 0)) {
            self.stats.dependency_unknown += 1;
            std.debug.print("UNKNOWN_DEP pid={d} fn={d} kind={s} expr={s} tag={s}", .{ self.entry.page_id, self.current_fn_start, kind, std.mem.trim(u8, self.source[span.start..span.end], " \t\r\n"), @tagName(value) });
            if (value == .scalar) std.debug.print(" any={} nil={} str={d} pat={d} num={d}", .{ value.scalar.any_string, value.scalar.may_nil, value.scalar.strings.len, value.scalar.patterns.len, value.scalar.numbers.len });
            std.debug.print("\n", .{});
            try self.writer.print("L\t{d}\t{d}\t{d}\t{d}\t{s}\tunknown\n", .{ self.entry.page_id, self.current_fn_start, span.start, span.end, kind });
            return;
        }
        var modules: std.StringHashMapUnmanaged(void) = .empty;
        for (value.scalar.strings) |module| try modules.put(self.allocator, module, {});
        for (value.scalar.patterns) |pattern| {
            if (!usefulPattern(pattern)) {
                self.stats.dependency_unknown += 1;
                try self.writer.print("L\t{d}\t{d}\t{d}\t{d}\t{s}\tunknown\n", .{ self.entry.page_id, self.current_fn_start, span.start, span.end, kind });
                return;
            }
            for (self.module_titles.items) |title| {
                if (wildcardMatch(pattern, title)) {
                    try modules.put(self.allocator, title, {});
                    if (modules.count() > finite_value_cap) {
                        self.stats.dependency_unknown += 1;
                        try self.writer.print("L\t{d}\t{d}\t{d}\t{d}\t{s}\tunknown\n", .{ self.entry.page_id, self.current_fn_start, span.start, span.end, kind });
                        return;
                    }
                }
            }
        }
        self.stats.dependency_resolved += 1;
        try self.writer.print("L\t{d}\t{d}\t{d}\t{d}\t{s}\tfinite", .{ self.entry.page_id, self.current_fn_start, span.start, span.end, kind });
        var it = modules.iterator();
        while (it.next()) |entry| {
            try self.writer.writeByte('\t');
            try writeField(self.writer, entry.key_ptr.*);
        }
        if (value.scalar.may_nil) try self.writer.writeAll("\t<nil>");
        try self.writer.writeByte('\n');
    }

    fn evalUnary(self: *Evaluator, op: lua.UnaryOp, operand: *const lua.Expr, env: *const Env) !Value {
        const v = try self.eval(operand, env);
        return switch (op) {
            .not_ => switch (truth(v)) { .yes => falseValue(), .no => trueValue(), .maybe => boolValue() },
            else => .unknown,
        };
    }

    fn evalBinary(self: *Evaluator, op: lua.BinaryOp, lhs_expr: *const lua.Expr, rhs_expr: *const lua.Expr, env: *const Env) !Value {
        const lhs = try self.eval(lhs_expr, env);
        const rhs = try self.eval(rhs_expr, env);
        return switch (op) {
            .eq => boolFromTruth(compareEq(lhs, rhs)),
            .ne => boolFromTruth(invert(compareEq(lhs, rhs))),
            .concat => blk: {
                if (self.entry.page_id == 6884586) {
                    const ls = lhs_expr.span(); const rs = rhs_expr.span();
                    std.debug.print("PALI_CONCAT lhs={s} tag={s} rhs={s} tag={s}\n", .{ std.mem.trim(u8, self.source[ls.start..ls.end], " \t\r\n"), @tagName(lhs), std.mem.trim(u8, self.source[rs.start..rs.end], " \t\r\n"), @tagName(rhs) });
                    if (rhs == .scalar) std.debug.print(" PALI_R any={} nil={} strings={d} pats={d}\n", .{rhs.scalar.any_string,rhs.scalar.may_nil,rhs.scalar.strings.len,rhs.scalar.patterns.len});
                }
                break :blk concatValue(self.allocator, lhs, rhs);
            },
            .and_ => switch (truth(lhs)) { .yes => rhs, .no => lhs, .maybe => mergeValues(self.allocator, falsyPart(lhs), rhs) },
            .or_ => blk: {
                if (self.entry.page_id == 6884586) {
                    const bs = lhs_expr.span();
                    const text = std.mem.trim(u8, self.source[bs.start..bs.end], " \t\r\n");
                    if (std.mem.indexOf(u8, text, "passages") != null) {
                        std.debug.print("PALI_OR lhs={s} tag={s} truth={s} rhs_tag={s}\n", .{text,@tagName(lhs),@tagName(truth(lhs)),@tagName(rhs)});
                        if (lhs == .scalar) std.debug.print(" PALI_L any={} nil={} str={d} pat={d}\n", .{lhs.scalar.any_string,lhs.scalar.may_nil,lhs.scalar.strings.len,lhs.scalar.patterns.len});
                    }
                }
                break :blk switch (truth(lhs)) { .yes => lhs, .no => rhs, .maybe => mergeValues(self.allocator, truthyPart(lhs), rhs) };
            },
            .lt, .le, .gt, .ge => compareNumbers(op, lhs, rhs),
            else => .unknown,
        };
    }
};

fn collectNestedWrites(a: std.mem.Allocator, body: lua.Block, out: *std.StringHashMapUnmanaged(void)) anyerror!void {
    for (body) |stmt| try collectNestedWritesStmt(a, stmt, out, false);
}

fn collectNestedWritesStmt(a: std.mem.Allocator, stmt: *const lua.Stmt, out: *std.StringHashMapUnmanaged(void), in_nested: bool) anyerror!void {
    switch (stmt.*) {
        .empty, .break_stmt => {},
        .assign => |s| {
            if (in_nested) for (s.targets) |target| switch (target) {
                .name => |name| try out.put(a, name, {}),
                .index => {},
            };
            for (s.values) |value| try collectNestedWritesExpr(a, value, out, in_nested);
        },
        .local_assign => |s| {
            if (in_nested) for (s.names) |name| try out.put(a, name, {});
            for (s.values) |value| try collectNestedWritesExpr(a, value, out, in_nested);
        },
        .call => |s| try collectNestedWritesExpr(a, s.expr, out, in_nested),
        .do_block => |s| for (s.body) |child| try collectNestedWritesStmt(a, child, out, in_nested),
        .while_loop => |s| {
            try collectNestedWritesExpr(a, s.cond, out, in_nested);
            for (s.body) |child| try collectNestedWritesStmt(a, child, out, in_nested);
        },
        .repeat_loop => |s| {
            for (s.body) |child| try collectNestedWritesStmt(a, child, out, in_nested);
            try collectNestedWritesExpr(a, s.cond, out, in_nested);
        },
        .if_stmt => |s| {
            for (s.branches) |branch| {
                try collectNestedWritesExpr(a, branch.cond, out, in_nested);
                for (branch.body) |child| try collectNestedWritesStmt(a, child, out, in_nested);
            }
            if (s.else_body) |else_body| for (else_body) |child| try collectNestedWritesStmt(a, child, out, in_nested);
        },
        .numeric_for => |s| {
            if (in_nested) try out.put(a, s.name, {});
            try collectNestedWritesExpr(a, s.start, out, in_nested);
            try collectNestedWritesExpr(a, s.limit, out, in_nested);
            if (s.step) |step| try collectNestedWritesExpr(a, step, out, in_nested);
            for (s.body) |child| try collectNestedWritesStmt(a, child, out, in_nested);
        },
        .generic_for => |s| {
            if (in_nested) for (s.names) |name| try out.put(a, name, {});
            for (s.values) |value| try collectNestedWritesExpr(a, value, out, in_nested);
            for (s.body) |child| try collectNestedWritesStmt(a, child, out, in_nested);
        },
        .function_assign => |s| {
            if (in_nested) switch (s.target) { .name => |name| try out.put(a, name, {}), .index => {} };
            try collectNestedWritesExpr(a, s.function, out, true);
        },
        .local_function => |s| {
            if (in_nested) try out.put(a, s.name, {});
            try collectNestedWritesExpr(a, s.function, out, true);
        },
        .return_stmt => |s| for (s.values) |value| try collectNestedWritesExpr(a, value, out, in_nested),
    }
}

fn collectNestedWritesExpr(a: std.mem.Allocator, expr: *const lua.Expr, out: *std.StringHashMapUnmanaged(void), in_nested: bool) anyerror!void {
    switch (expr.*) {
        .function => |f| for (f.body) |stmt| try collectNestedWritesStmt(a, stmt, out, true),
        .paren => |pval| try collectNestedWritesExpr(a, pval.expr, out, in_nested),
        .index => |e| {
            try collectNestedWritesExpr(a, e.object, out, in_nested);
            try collectNestedWritesExpr(a, e.key, out, in_nested);
        },
        .call => |e| {
            try collectNestedWritesExpr(a, e.callee, out, in_nested);
            for (e.args) |arg| try collectNestedWritesExpr(a, arg, out, in_nested);
        },
        .method_call => |e| {
            try collectNestedWritesExpr(a, e.object, out, in_nested);
            for (e.args) |arg| try collectNestedWritesExpr(a, arg, out, in_nested);
        },
        .table => |t| for (t.fields) |field| switch (field) {
            .list => |v| try collectNestedWritesExpr(a, v, out, in_nested),
            .named => |v| try collectNestedWritesExpr(a, v.value, out, in_nested),
            .keyed => |v| {
                try collectNestedWritesExpr(a, v.key, out, in_nested);
                try collectNestedWritesExpr(a, v.value, out, in_nested);
            },
        },
        .unary => |u| try collectNestedWritesExpr(a, u.expr, out, in_nested),
        .binary => |b| {
            try collectNestedWritesExpr(a, b.lhs, out, in_nested);
            try collectNestedWritesExpr(a, b.rhs, out, in_nested);
        },
        else => {},
    }
}

fn nilValue() Value { return .{ .scalar = .{ .may_nil = true } }; }
fn trueValue() Value { return .{ .scalar = .{ .may_true = true } }; }
fn falseValue() Value { return .{ .scalar = .{ .may_false = true } }; }
fn boolValue() Value { return .{ .scalar = .{ .may_false = true, .may_true = true } }; }
fn boolFromTruth(t: Truth) Value { return switch (t) { .yes => trueValue(), .no => falseValue(), .maybe => boolValue() }; }
fn numberValue(a: std.mem.Allocator, n: f64) Value { const out = a.alloc(f64, 1) catch return .unknown; out[0] = n; return .{ .scalar = .{ .numbers = out } }; }
fn stringValueScalar(a: std.mem.Allocator, s: []const u8) Value { const out = a.alloc([]const u8, 1) catch return .unknown; out[0] = s; return .{ .scalar = .{ .strings = out } }; }

fn truth(v: Value) Truth {
    if (v == .unknown or v == .frame or v == .args) return .maybe;
    if (v == .function_ref or v == .table_ref or v == .builtin or v == .module_ref or v == .external_function) return .yes;
    const s = v.scalar;
    if (s.unknown) return .maybe;
    const can_false = s.may_nil or s.may_false;
    const can_true = s.may_true or s.any_string or s.strings.len != 0 or s.patterns.len != 0 or s.numbers.len != 0;
    if (can_true and !can_false) return .yes;
    if (!can_true and can_false) return .no;
    return .maybe;
}

fn invert(t: Truth) Truth { return switch (t) { .yes => .no, .no => .yes, .maybe => .maybe }; }
fn singletonString(v: Value) ?[]const u8 { return if (v == .scalar and !v.scalar.unknown and !v.scalar.any_string and !v.scalar.may_nil and !v.scalar.may_false and !v.scalar.may_true and v.scalar.numbers.len == 0 and v.scalar.patterns.len == 0 and v.scalar.strings.len == 1) v.scalar.strings[0] else null; }
fn singletonNumber(v: Value) ?f64 { return if (v == .scalar and !v.scalar.unknown and !v.scalar.any_string and !v.scalar.may_nil and !v.scalar.may_false and !v.scalar.may_true and v.scalar.strings.len == 0 and v.scalar.patterns.len == 0 and v.scalar.numbers.len == 1) v.scalar.numbers[0] else null; }

fn keyText(a: std.mem.Allocator, v: Value) ?[]const u8 {
    if (singletonString(v)) |s| return s;
    if (singletonNumber(v)) |n| {
        if (@floor(n) != n) return null;
        return std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(n))}) catch null;
    }
    return null;
}

fn truthyPart(v: Value) Value {
    if (v != .scalar) return .unknown;
    var s = v.scalar;
    s.may_nil = false;
    s.may_false = false;
    return .{ .scalar = s };
}

fn falsyPart(v: Value) Value {
    if (v != .scalar) return .unknown;
    const s = v.scalar;
    if (s.unknown) return .unknown;
    return .{ .scalar = .{ .may_nil = s.may_nil, .may_false = s.may_false } };
}

fn typeMask(s: Scalar) u8 {
    if (s.unknown) return 0xff;
    var mask: u8 = 0;
    if (s.may_nil) mask |= 1;
    if (s.may_false or s.may_true) mask |= 2;
    if (s.any_string or s.strings.len != 0 or s.patterns.len != 0) mask |= 4;
    if (s.numbers.len != 0) mask |= 8;
    return mask;
}

fn compareEq(a: Value, b: Value) Truth {
    if (a != .scalar or b != .scalar) return .maybe;
    const x = a.scalar; const y = b.scalar;
    if (x.unknown or y.unknown) return .maybe;
    if ((typeMask(x) & typeMask(y)) == 0) return .no;
    if (singletonString(a)) |xs| if (singletonString(b)) |ys| return if (std.mem.eql(u8, xs, ys)) .yes else .no;
    if (singletonNumber(a)) |xn| if (singletonNumber(b)) |yn| return if (xn == yn) .yes else .no;
    if (x.may_nil and typeMask(x) == 1 and y.may_nil and typeMask(y) == 1) return .yes;
    if (x.may_true and !x.may_false and typeMask(x) == 2 and y.may_true and !y.may_false and typeMask(y) == 2) return .yes;
    if (x.may_false and !x.may_true and typeMask(x) == 2 and y.may_false and !y.may_true and typeMask(y) == 2) return .yes;
    if (!x.any_string and !y.any_string and typeMask(x) == 4 and typeMask(y) == 4) {
        var overlap = false;
        for (x.strings) |xs| for (y.strings) |ys| if (std.mem.eql(u8, xs, ys)) { overlap = true; break; };
        if (!overlap) return .no;
    }
    return .maybe;
}

fn compareNumbers(op: lua.BinaryOp, a: Value, b: Value) Value {
    const x = singletonNumber(a) orelse return boolValue();
    const y = singletonNumber(b) orelse return boolValue();
    const result = switch (op) { .lt => x < y, .le => x <= y, .gt => x > y, .ge => x >= y, else => unreachable };
    return if (result) trueValue() else falseValue();
}

fn scalarToStringsOnly(v: Value) ?Scalar {
    if (v != .scalar) return null;
    const s = v.scalar;
    if (s.unknown or s.may_nil or s.may_false or s.may_true or s.numbers.len != 0) return null;
    return s;
}

fn concatValue(a: std.mem.Allocator, lhs: Value, rhs: Value) Value {
    const l = scalarToStringsOnly(lhs) orelse return .unknown;
    const r = scalarToStringsOnly(rhs) orelse return .unknown;
    var exact: std.ArrayList([]const u8) = .empty;
    var patterns: std.ArrayList([]const u8) = .empty;

    for (l.strings) |ls| for (r.strings) |rs| addUniqueString(a, &exact, std.fmt.allocPrint(a, "{s}{s}", .{ ls, rs }) catch return .unknown) catch return .unknown;
    for (l.strings) |ls| for (r.patterns) |rp| addUniqueString(a, &patterns, std.fmt.allocPrint(a, "{s}{s}", .{ ls, rp }) catch return .unknown) catch return .unknown;
    for (l.patterns) |lp| for (r.strings) |rs| addUniqueString(a, &patterns, std.fmt.allocPrint(a, "{s}{s}", .{ lp, rs }) catch return .unknown) catch return .unknown;
    for (l.patterns) |lp| for (r.patterns) |rp| addUniqueString(a, &patterns, std.fmt.allocPrint(a, "{s}{s}", .{ lp, rp }) catch return .unknown) catch return .unknown;
    if (l.any_string) {
        for (r.strings) |rs| addUniqueString(a, &patterns, std.fmt.allocPrint(a, "*{s}", .{rs}) catch return .unknown) catch return .unknown;
        for (r.patterns) |rp| addUniqueString(a, &patterns, std.fmt.allocPrint(a, "*{s}", .{rp}) catch return .unknown) catch return .unknown;
    }
    if (r.any_string) {
        for (l.strings) |ls| addUniqueString(a, &patterns, std.fmt.allocPrint(a, "{s}*", .{ls}) catch return .unknown) catch return .unknown;
        for (l.patterns) |lp| addUniqueString(a, &patterns, std.fmt.allocPrint(a, "{s}*", .{lp}) catch return .unknown) catch return .unknown;
    }
    if (l.any_string and r.any_string) return .{ .scalar = .{ .any_string = true } };
    if (exact.items.len + patterns.items.len > finite_value_cap) return .{ .scalar = .{ .any_string = true } };
    return .{ .scalar = .{
        .strings = exact.toOwnedSlice(a) catch return .unknown,
        .patterns = patterns.toOwnedSlice(a) catch return .unknown,
    } };
}

fn mergeValueLists(a: std.mem.Allocator, lhs: []const Value, rhs: []const Value) ![]const Value {
    const n = @max(lhs.len, rhs.len);
    const out = try a.alloc(Value, n);
    for (0..n) |i| out[i] = mergeValues(a, if (i < lhs.len) lhs[i] else nilValue(), if (i < rhs.len) rhs[i] else nilValue());
    return out;
}

fn mergeValues(a: std.mem.Allocator, lhs: Value, rhs: Value) Value {
    if (lhs == .frame and rhs == .frame) return if (lhs.frame == rhs.frame) lhs else .unknown;
    if (lhs == .args and rhs == .args) return if (lhs.args == rhs.args) lhs else .unknown;
    if (lhs == .function_ref and rhs == .function_ref) return if (lhs.function_ref == rhs.function_ref) lhs else .unknown;
    if (lhs == .table_ref and rhs == .table_ref) {
        if (lhs.table_ref == rhs.table_ref) return lhs;
        const joined = a.create(AbsTable) catch return .unknown;
        joined.* = .{};
        var lit = lhs.table_ref.fields.iterator();
        while (lit.next()) |entry| {
            const rv = rhs.table_ref.fields.get(entry.key_ptr.*) orelse nilValue();
            joined.fields.put(a, entry.key_ptr.*, mergeValues(a, entry.value_ptr.*, rv)) catch return .unknown;
        }
        var rit = rhs.table_ref.fields.iterator();
        while (rit.next()) |entry| {
            if (lhs.table_ref.fields.contains(entry.key_ptr.*)) continue;
            joined.fields.put(a, entry.key_ptr.*, mergeValues(a, nilValue(), entry.value_ptr.*)) catch return .unknown;
        }
        return .{ .table_ref = joined };
    }
    if (lhs == .builtin and rhs == .builtin) return if (lhs.builtin == rhs.builtin) lhs else .unknown;
    if (lhs == .module_ref and rhs == .module_ref) return if (std.mem.eql(u8, lhs.module_ref, rhs.module_ref)) lhs else .unknown;
    if (lhs == .external_function and rhs == .external_function) return if (std.mem.eql(u8, lhs.external_function.module, rhs.external_function.module) and std.mem.eql(u8, lhs.external_function.name, rhs.external_function.name)) lhs else .unknown;
    if (lhs != .scalar or rhs != .scalar) return .unknown;
    const l = lhs.scalar; const r = rhs.scalar;
    if (l.unknown or r.unknown) return .unknown;
    var strings: std.ArrayList([]const u8) = .empty;
    var patterns: std.ArrayList([]const u8) = .empty;
    for (l.strings) |v| addUniqueString(a, &strings, v) catch return .unknown;
    for (r.strings) |v| addUniqueString(a, &strings, v) catch return .unknown;
    for (l.patterns) |v| addUniqueString(a, &patterns, v) catch return .unknown;
    for (r.patterns) |v| addUniqueString(a, &patterns, v) catch return .unknown;
    if (strings.items.len + patterns.items.len > finite_value_cap) return .{ .scalar = .{ .any_string = true, .may_nil = l.may_nil or r.may_nil, .may_false = l.may_false or r.may_false, .may_true = l.may_true or r.may_true } };
    return .{ .scalar = .{ .any_string = l.any_string or r.any_string, .may_nil = l.may_nil or r.may_nil, .may_false = l.may_false or r.may_false, .may_true = l.may_true or r.may_true, .strings = strings.toOwnedSlice(a) catch return .unknown, .patterns = patterns.toOwnedSlice(a) catch return .unknown } };
}

fn typeValue(a: std.mem.Allocator, v: Value) Value {
    return switch (v) {
        .frame, .args => stringValueScalar(a, "table"),
        .function_ref => stringValueScalar(a, "function"),
        .table_ref => stringValueScalar(a, "table"),
        .builtin => stringValueScalar(a, "function"),
        .module_ref, .external_function => stringValueScalar(a, "table"),
        .unknown => .unknown,
        .scalar => |s| blk: {
            const mask = typeMask(s);
            var out: std.ArrayList([]const u8) = .empty;
            if (mask & 1 != 0) out.append(a, "nil") catch return .unknown;
            if (mask & 2 != 0) out.append(a, "boolean") catch return .unknown;
            if (mask & 4 != 0) out.append(a, "string") catch return .unknown;
            if (mask & 8 != 0) out.append(a, "number") catch return .unknown;
            break :blk .{ .scalar = .{ .strings = out.toOwnedSlice(a) catch return .unknown } };
        },
    };
}

fn tonumberValue(a: std.mem.Allocator, v: Value) Value {
    const s = scalarToStringsOnly(v) orelse return .unknown;
    if (s.any_string) return .unknown;
    var nums: std.ArrayList(f64) = .empty;
    var may_nil = false;
    for (s.strings) |text| {
        const n = std.fmt.parseFloat(f64, std.mem.trim(u8, text, " \t\r\n")) catch { may_nil = true; continue; };
        nums.append(a, n) catch return .unknown;
    }
    return .{ .scalar = .{ .may_nil = may_nil, .numbers = nums.toOwnedSlice(a) catch return .unknown } };
}

fn tostringValue(a: std.mem.Allocator, v: Value) Value {
    if (v != .scalar or v.scalar.unknown or v.scalar.any_string or v.scalar.patterns.len != 0 or v.scalar.may_nil) return .unknown;
    if (v.scalar.strings.len != 0 and v.scalar.numbers.len == 0 and !v.scalar.may_false and !v.scalar.may_true) return v;
    var out: std.ArrayList([]const u8) = .empty;
    for (v.scalar.strings) |s| out.append(a, s) catch return .unknown;
    for (v.scalar.numbers) |n| out.append(a, std.fmt.allocPrint(a, "{d}", .{n}) catch return .unknown) catch return .unknown;
    if (v.scalar.may_false) out.append(a, "false") catch return .unknown;
    if (v.scalar.may_true) out.append(a, "true") catch return .unknown;
    return .{ .scalar = .{ .strings = out.toOwnedSlice(a) catch return .unknown } };
}

fn substringValue(a: std.mem.Allocator, s: Scalar, start_num: f64, end_num: ?f64) Value {
    if (s.unknown or s.any_string or s.patterns.len != 0 or s.may_nil or s.may_false or s.may_true or s.numbers.len != 0) return .unknown;
    var out: std.ArrayList([]const u8) = .empty;
    const start_i: isize = @intFromFloat(start_num);
    const end_i: ?isize = if (end_num) |e| @intFromFloat(e) else null;
    for (s.strings) |text| {
        const len: isize = @intCast(text.len);
        var lo = if (start_i > 0) start_i - 1 else len + start_i;
        var hi = if (end_i) |e| (if (e > 0) e else len + e + 1) else len;
        lo = @max(0, @min(lo, len)); hi = @max(lo, @min(hi, len));
        const piece = text[@intCast(lo)..@intCast(hi)];
        var exists = false;
        for (out.items) |old| if (std.mem.eql(u8, old, piece)) { exists = true; break; };
        if (!exists) out.append(a, piece) catch return .unknown;
    }
    return .{ .scalar = .{ .strings = out.toOwnedSlice(a) catch return .unknown } };
}



fn addUniqueString(a: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    for (list.items) |old| if (std.mem.eql(u8, old, value)) return;
    if (list.items.len >= finite_value_cap) return error.OutOfMemory;
    try list.append(a, value);
}

fn usefulPattern(pattern: []const u8) bool {
    var literals: usize = 0;
    for (pattern) |c| if (c != '*') { literals += 1; };
    return literals >= 8 and std.mem.indexOfScalar(u8, pattern, '*') != null;
}

fn wildcardMatch(pattern: []const u8, text: []const u8) bool {
    var pi: usize = 0; var ti: usize = 0; var star: ?usize = null; var retry: usize = 0;
    while (ti < text.len) {
        if (pi < pattern.len and pattern[pi] == '*') { star = pi; pi += 1; retry = ti; continue; }
        if (pi < pattern.len and pattern[pi] == text[ti]) { pi += 1; ti += 1; continue; }
        if (star) |sp| { retry += 1; ti = retry; pi = sp + 1; continue; }
        return false;
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}


fn dependencyPatternValue(a: std.mem.Allocator, expr: *const lua.Expr) Value {
    const pattern = dependencyPatternAlloc(a, expr) orelse return .unknown;
    if (std.mem.indexOfScalar(u8, pattern, '*') == null) return stringValueScalar(a, pattern);
    const pats = a.alloc([]const u8, 1) catch return .unknown;
    pats[0] = pattern;
    return .{ .scalar = .{ .patterns = pats } };
}

fn dependencyPatternAlloc(a: std.mem.Allocator, expr: *const lua.Expr) ?[]const u8 {
    return switch (expr.*) {
        .string => |v| v.value,
        .paren => |pval| dependencyPatternAlloc(a, pval.expr),
        .binary => |b| if (b.op == .concat) blk: {
            const lhs = dependencyPatternAlloc(a, b.lhs) orelse "*";
            const rhs = dependencyPatternAlloc(a, b.rhs) orelse "*";
            break :blk std.fmt.allocPrint(a, "{s}{s}", .{ lhs, rhs }) catch null;
        } else "*",
        else => "*",
    };
}

fn isHeadwordPagename(object: *const lua.Expr, key: *const lua.Expr) bool {
    if (key.* != .string or !std.mem.eql(u8, key.string.value, "pagename")) return false;
    if (object.* != .call or object.call.args.len == 0) return false;
    const callee = exprPath(object.call.callee) orelse return false;
    if (!std.mem.eql(u8, callee, "mw.loadData")) return false;
    return object.call.args[0].* == .string and std.mem.eql(u8, object.call.args[0].string.value, "Module:headword/data");
}

fn requiredMemberBuiltin(object: *const lua.Expr, key: *const lua.Expr) ?Builtin {
    if (key.* != .string or !std.mem.eql(u8, key.string.value, "process")) return null;
    if (object.* != .call or object.call.args.len == 0) return null;
    const callee = exprPath(object.call.callee) orelse return null;
    if (!std.mem.eql(u8, callee, "require")) return null;
    if (object.call.args[0].* != .string) return null;
    return if (std.mem.eql(u8, object.call.args[0].string.value, "Module:parameters")) .parameters_process else null;
}

fn exprPath(expr: *const lua.Expr) ?[]const u8 {
    return switch (expr.*) {
        .name => |n| n.value,
        .paren => |pval| exprPath(pval.expr),
        .index => |idx| blk: {
            if (idx.object.* == .name and idx.key.* == .string) {
                const base = idx.object.name.value; const key = idx.key.string.value;
                if (std.mem.eql(u8, base, "mw") and std.mem.eql(u8, key, "text")) break :blk "mw.text";
                if (std.mem.eql(u8, base, "mw") and std.mem.eql(u8, key, "loadData")) break :blk "mw.loadData";
            }
            break :blk null;
        },
        else => null,
    };
}


fn evalModuleInit(a: std.mem.Allocator, expr: *const lua.Expr, env: *const Env) anyerror!Value {
    return switch (expr.*) {
        .nil_lit => nilValue(),
        .bool_lit => |b| if (b.value) trueValue() else falseValue(),
        .number => |n| numberValue(a, std.fmt.parseFloat(f64, n.raw) catch return .unknown),
        .string => |v| stringValueScalar(a, v.value),
        .name => |n| env.get(n.value),
        .paren => |pval| try evalModuleInit(a, pval.expr, env),
        .function => .{ .function_ref = expr },
        .index => |idx| blk: {
            if (requiredMemberBuiltin(idx.object, idx.key)) |builtin| break :blk .{ .builtin = builtin };
            const object = try evalModuleInit(a, idx.object, env);
            const key = keyText(a, try evalModuleInit(a, idx.key, env)) orelse break :blk .unknown;
            break :blk switch (object) {
                .table_ref => |table| table.fields.get(key) orelse nilValue(),
                .module_ref => |module| if (std.mem.eql(u8, module, "Module:parameters") and std.mem.eql(u8, key, "process"))
                    .{ .builtin = .parameters_process }
                else if (std.mem.eql(u8, module, "Module:languages") and std.mem.eql(u8, key, "getByCode"))
                    .{ .builtin = .languages_get_by_code }
                else .{ .external_function = .{ .module = module, .name = key } },
                else => .unknown,
            };
        },
        .table => |t| try evalModuleTable(a, t.fields, env),
        .call => |c| blk: {
            const name = exprPath(c.callee) orelse break :blk .unknown;
            if (std.mem.eql(u8, name, "require") and c.args.len != 0 and c.args[0].* == .string) break :blk .{ .module_ref = c.args[0].string.value };
            break :blk .unknown;
        },
        .binary => |b| switch (b.op) {
            .concat => concatValue(a, try evalModuleInit(a, b.lhs, env), try evalModuleInit(a, b.rhs, env)),
            .or_ => blk: {
                const lhs = try evalModuleInit(a, b.lhs, env);
                break :blk switch (truth(lhs)) { .yes => lhs, .no => try evalModuleInit(a, b.rhs, env), .maybe => mergeValues(a, truthyPart(lhs), try evalModuleInit(a, b.rhs, env)) };
            },
            .and_ => blk: {
                const lhs = try evalModuleInit(a, b.lhs, env);
                break :blk switch (truth(lhs)) { .yes => try evalModuleInit(a, b.rhs, env), .no => lhs, .maybe => mergeValues(a, falsyPart(lhs), try evalModuleInit(a, b.rhs, env)) };
            },
            else => .unknown,
        },
        else => .unknown,
    };
}


fn evalModuleTable(a: std.mem.Allocator, fields: []const lua.TableField, env: *const Env) anyerror!Value {
    const table = try a.create(AbsTable);
    table.* = .{};
    var list_index: usize = 1;
    for (fields) |field| switch (field) {
        .list => |value| {
            const key = try std.fmt.allocPrint(a, "{d}", .{list_index});
            try table.fields.put(a, key, try evalModuleInit(a, value, env));
            list_index += 1;
        },
        .named => |value| try table.fields.put(a, value.name, try evalModuleInit(a, value.value, env)),
        .keyed => |value| {
            const key = keyText(a, try evalModuleInit(a, value.key, env)) orelse continue;
            try table.fields.put(a, key, try evalModuleInit(a, value.value, env));
        },
    };
    return .{ .table_ref = table };
}

fn invalidateModuleWrites(block: lua.Block, env: *Env) anyerror!void {
    for (block) |stmt| switch (stmt.*) {
        .assign => |v| for (v.targets) |target| switch (target) { .name => |name| if (env.map.contains(name)) try env.put(name, .unknown), .index => {} },
        .function_assign => |v| switch (v.target) { .name => |name| if (env.map.contains(name)) try env.put(name, .unknown), .index => {} },
        .do_block => |v| try invalidateModuleWrites(v.body, env),
        .while_loop => |v| try invalidateModuleWrites(v.body, env),
        .repeat_loop => |v| try invalidateModuleWrites(v.body, env),
        .if_stmt => |v| { for (v.branches) |b| try invalidateModuleWrites(b.body, env); if (v.else_body) |b| try invalidateModuleWrites(b, env); },
        .numeric_for => |v| try invalidateModuleWrites(v.body, env),
        .generic_for => |v| try invalidateModuleWrites(v.body, env),
        else => {},
    };
}

fn buildModuleEnv(a: std.mem.Allocator, body: lua.Block) anyerror!Env {
    var env = Env{ .allocator = a };
    for (body) |stmt| switch (stmt.*) {
        .local_assign => |v| {
            const values = try a.alloc(Value, v.names.len);
            for (v.names, 0..) |_, i| values[i] = if (i < v.values.len) try evalModuleInit(a, v.values[i], &env) else nilValue();
            for (v.names, 0..) |name, i| try env.put(name, values[i]);
        },
        .assign => |v| {
            const values = try a.alloc(Value, v.targets.len);
            for (v.targets, 0..) |_, i| values[i] = if (i < v.values.len) try evalModuleInit(a, v.values[i], &env) else nilValue();
            for (v.targets, 0..) |target, i| switch (target) { .name => |name| try env.put(name, values[i]), .index => {} };
        },
        .local_function => |v| try env.put(v.name, .{ .function_ref = v.function }),
        .function_assign => |v| switch (v.target) {
            .name => |name| try env.put(name, .{ .function_ref = v.function }),
            .index => |idx| {
                const object = try evalModuleInit(a, idx.object, &env);
                const key = keyText(a, try evalModuleInit(a, idx.key, &env));
                if (object == .table_ref and key != null) try object.table_ref.fields.put(a, key.?, .{ .function_ref = v.function });
            },
        },
        .do_block => |v| try invalidateModuleWrites(v.body, &env),
        .while_loop => |v| try invalidateModuleWrites(v.body, &env),
        .repeat_loop => |v| try invalidateModuleWrites(v.body, &env),
        .if_stmt => |v| { for (v.branches) |b| try invalidateModuleWrites(b.body, &env); if (v.else_body) |b| try invalidateModuleWrites(b, &env); },
        .numeric_for => |v| try invalidateModuleWrites(v.body, &env),
        .generic_for => |v| try invalidateModuleWrites(v.body, &env),
        else => {},
    };
    return env;
}

fn parseBool(s: []const u8) bool { return std.mem.eql(u8, s, "true"); }

fn entryKeyAlloc(a: std.mem.Allocator, module: []const u8, function: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}\x1f{s}", .{ module, function });
}

fn parseFields(a: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, line, '\t');
    while (it.next()) |field| try out.append(a, field);
    return out.toOwnedSlice(a);
}

fn unescape(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '\\' or i + 1 >= s.len) { try out.append(a, s[i]); i += 1; continue; }
        switch (s[i + 1]) { 't' => try out.append(a, '\t'), 'n' => try out.append(a, '\n'), 'r' => try out.append(a, '\r'), '\\' => try out.append(a, '\\'), else => { try out.append(a, '\\'); try out.append(a, s[i + 1]); } }
        i += 2;
    }
    return out.toOwnedSlice(a);
}

fn writeField(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) { '\\' => try w.writeAll("\\\\"), '\t' => try w.writeAll("\\t"), '\n' => try w.writeAll("\\n"), '\r' => try w.writeAll("\\r"), else => try w.writeByte(c) };
}

fn readAll(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]u8 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{}); defer f.close(io);
    const st = try f.stat(io); const n = std.math.cast(usize, st.size) orelse return error.FileTooBig;
    const out = try a.alloc(u8, n); _ = try f.readPositionalAll(io, out, 0); return out;
}

fn parseReach(a: std.mem.Allocator, bytes: []const u8, entries: *std.StringHashMapUnmanaged(*Entry), groups: *std.AutoHashMapUnmanaged(u64, std.ArrayList(*Entry)), module_titles: *std.ArrayList([]const u8)) !void {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len < 3 or line[1] != '\t') continue;
        if (line[0] == 'K' or line[0] == 'N') {
            const mf = try parseFields(a, line);
            if (mf.len >= 3) try module_titles.append(a, try unescape(a, mf[2]));
            continue;
        }
        if (line[0] != 'F') continue;
        const f = try parseFields(a, line); if (f.len < 5) continue;
        const page_id = std.fmt.parseInt(u64, f[1], 10) catch continue;
        const fn_start = std.fmt.parseInt(u32, f[2], 10) catch continue;
        const module = try unescape(a, f[3]); const function = try unescape(a, f[4]);
        const entry = try a.create(Entry); entry.* = .{ .page_id = page_id, .fn_start = fn_start, .module = module, .function = function };
        const key = try entryKeyAlloc(a, module, function); try entries.put(a, key, entry);
        const g = try groups.getOrPut(a, page_id); if (!g.found_existing) g.value_ptr.* = .empty; try g.value_ptr.append(a, entry);
    }
}

fn parseUsage(a: std.mem.Allocator, bytes: []const u8, entries: *std.StringHashMapUnmanaged(*Entry)) !void {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len < 2 or line[1] != '\t') continue;
        if (line[0] == 'W') {
            const f = try parseFields(a, line); if (f.len < 5) continue;
            const module = try unescape(a, f[1]); const function = try unescape(a, f[2]);
            const key = try entryKeyAlloc(a, module, function); const entry = entries.get(key) orelse continue;
            entry.current_dynamic_keys = parseBool(f[3]);
            entry.parent_dynamic_keys = parseBool(f[4]);
            continue;
        }
        if (line[0] != 'P' and line[0] != 'Q') continue;
        const f = try parseFields(a, line); if (f.len < 7) continue;
        const module = try unescape(a, f[1]); const function = try unescape(a, f[2]);
        const key = try entryKeyAlloc(a, module, function); const entry = entries.get(key) orelse continue;
        const name = try unescape(a, f[3]);
        const domain = try a.create(ParamDomain); domain.* = .{ .top = parseBool(f[4]), .missing = parseBool(f[5]) };
        for (f[6..]) |raw| try domain.values.append(a, try unescape(a, raw));
        if (line[0] == 'P') try entry.current.put(a, name, domain) else try entry.parent.put(a, name, domain);
    }
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4) return error.MissingInput;
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator); defer arena.deinit(); const a = arena.allocator();
    const reach = try readAll(init.io, a, args[1]); const usage = try readAll(init.io, a, args[2]);
    var entries: std.StringHashMapUnmanaged(*Entry) = .empty;
    var groups: std.AutoHashMapUnmanaged(u64, std.ArrayList(*Entry)) = .empty;
    var module_titles: std.ArrayList([]const u8) = .empty;
    try parseReach(a, reach, &entries, &groups, &module_titles); try parseUsage(a, usage, &entries);
    var out_buf: [1024 * 1024]u8 = undefined; var stdout = std.Io.File.stdout().writer(init.io, &out_buf); const w = &stdout.interface;
    var stats = Stats{}; var git = groups.iterator();
    while (git.next()) |g| {
        var page_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator); defer page_arena.deinit(); const pa = page_arena.allocator();
        const path = try std.fmt.allocPrint(pa, "{s}/{d}.lua", .{ args[3], g.key_ptr.* });
        const source = readAll(init.io, pa, path) catch continue;
        var chunk = lua.parse(pa, source) catch continue;
        var b = model.Builder{ .allocator = pa, .source = chunk.source }; try b.build(chunk.body);
        var module_env = try buildModuleEnv(pa, chunk.body);
        var active_functions: std.AutoHashMapUnmanaged(u32, void) = .empty;
        for (g.value_ptr.items) |entry| {
            const fn_expr = b.functions.get(entry.fn_start) orelse continue;
            if (fn_expr.* != .function) continue;
            var ev = Evaluator{ .allocator = pa, .entry = entry, .source = chunk.source, .writer = w, .stats = &stats, .module_env = &module_env, .active_functions = &active_functions, .module_titles = &module_titles };
            try ev.run(fn_expr.function);
        }
        b.deinit(); chunk.deinit();
    }
    try w.print("S\tentrypoints\t{d}\nS\tbranch_sites\t{d}\nS\tproven_true\t{d}\nS\tproven_false\t{d}\nS\tunknown\t{d}\nS\tdependency_sites_observed\t{d}\nS\tdependency_sites_finite\t{d}\nS\tdependency_sites_unknown\t{d}\n", .{ entries.count(), stats.sites, stats.yes, stats.no, stats.maybe, stats.dependency_sites, stats.dependency_resolved, stats.dependency_unknown });
    try w.flush();
}
