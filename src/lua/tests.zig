test {
    _ = @import("parser/root.zig");
    _ = @import("direct/analysis.zig");
    _ = @import("direct/emitter.zig");
    _ = @import("direct/numbers.zig");
    _ = @import("direct/module_model.zig");
    _ = @import("direct/shapes.zig");
    _ = @import("extract/modules.zig");
    _ = @import("wikitext/expression.zig");
    _ = @import("wikitext/preprocess.zig");
    _ = @import("runtime/pattern.zig");
    _ = @import("runtime/format_core.zig");
}

const std = @import("std");
const llvm_parser = @import("parser/root.zig");
const llvm_analysis = @import("direct/analysis.zig");
const llvm_emitter = @import("direct/emitter.zig");
const llvm_shapes = @import("direct/shapes.zig");
const llvm_module_model = @import("direct/module_model.zig");

test "direct LLVM emitter covers Lua control and closure surface" {
    const source =
        \\local x = 1
        \\local function f(a, ...)
        \\  local t = {a, x = 2, [a] = 3}
        \\  while a < 3 do a = a + 1; if a == 2 then break end end
        \\  repeat a = a - 1 until a <= 0
        \\  for i = 1, 3 do t[i] = i end
        \\  for k,v in pairs(t) do t[k] = v end
        \\  return t[a], ...
        \\end
        \\return f
    ;
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    const generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer std.testing.allocator.free(generated.source);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "define %FunctionResult @lua_f_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "fadd double") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "dict_lua_make_function") != null);
}

test "immutable numeric locals stay native LLVM SSA" {
    const source = "local x=2; local y=x+3; return y*4";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    const generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer std.testing.allocator.free(generated.source);

    try std.testing.expect(std.mem.indexOf(u8, generated.source, "fadd double") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "fmul double") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, generated.source, "call void @dict_lua_value_number"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, generated.source, "call i32 @dict_lua_require_number"));
}

test "mutable proven scalar locals stay native LLVM storage" {
    const source =
        \\local n = 1
        \\n = n + 2
        \\local ok = true
        \\ok = n > 1
        \\return n, ok
    ;
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    const generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer std.testing.allocator.free(generated.source);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "alloca double") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "alloca i1") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "call i32 @dict_lua_binary") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "call i32 @dict_lua_require_number") == null);
}

test "mutable logical results use generic storage" {
    const source =
        \\local ok = false
        \\ok = ok or not not value
        \\return ok
    ;
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var saw_ok = false;
    for (module.root.bindings) |binding| if (std.mem.eql(u8, binding.name, "ok")) {
        saw_ok = true;
        try std.testing.expectEqual(llvm_analysis.StaticType.unknown, binding.static_type);
    };
    try std.testing.expect(saw_ok);
    const generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer std.testing.allocator.free(generated.source);
}

test "loop-carried scalar dependencies invalidate stale aliases" {
    const source =
        \\local state = true
        \\local copy = true
        \\local count = 0
        \\for i = 1, 3 do
        \\  copy = state
        \\  state = maybe and maybe.flag or false
        \\  count = count + 1
        \\end
        \\return state, copy, count
    ;
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var state_type: ?llvm_analysis.StaticType = null;
    var copy_type: ?llvm_analysis.StaticType = null;
    var count_type: ?llvm_analysis.StaticType = null;
    for (module.root.bindings) |binding| {
        if (std.mem.eql(u8, binding.name, "state")) state_type = binding.static_type;
        if (std.mem.eql(u8, binding.name, "copy")) copy_type = binding.static_type;
        if (std.mem.eql(u8, binding.name, "count")) count_type = binding.static_type;
    }
    try std.testing.expectEqual(llvm_analysis.StaticType.unknown, state_type.?);
    try std.testing.expectEqual(llvm_analysis.StaticType.unknown, copy_type.?);
    try std.testing.expectEqual(llvm_analysis.StaticType.number, count_type.?);
    const generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer std.testing.allocator.free(generated.source);
}

test "late capture invalidates native scalar aliases" {
    const source =
        \\local value = 1
        \\local copy = 0
        \\copy = value
        \\local function capture() return value end
        \\return copy, capture
    ;
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var value_type: ?llvm_analysis.StaticType = null;
    var copy_type: ?llvm_analysis.StaticType = null;
    for (module.root.bindings) |binding| {
        if (std.mem.eql(u8, binding.name, "value")) value_type = binding.static_type;
        if (std.mem.eql(u8, binding.name, "copy")) copy_type = binding.static_type;
    }
    try std.testing.expectEqual(llvm_analysis.StaticType.unknown, value_type.?);
    try std.testing.expectEqual(llvm_analysis.StaticType.unknown, copy_type.?);
    const generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer std.testing.allocator.free(generated.source);
}

test "constant require lowers to module id only when global is stable" {
    var ids: llvm_emitter.ModuleIdMap = .empty;
    defer ids.deinit(std.testing.allocator);
    try ids.put(std.testing.allocator, "Module:Alias", 7);
    const facts = llvm_emitter.ProgramFacts{ .module_ids = &ids };
    const compile = struct {
        fn run(source: []const u8, program_facts: llvm_emitter.ProgramFacts) ![]u8 {
            var chunk = try llvm_parser.parse(std.testing.allocator, source);
            defer chunk.deinit();
            var globals = try llvm_analysis.Globals.init(std.testing.allocator);
            defer globals.deinit();
            var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
            defer module.deinit();
            return (try llvm_emitter.generate(std.testing.allocator, &globals, &module, program_facts)).source;
        }
    }.run;

    const direct = try compile("local x=require('Module:Alias'); return x", facts);
    defer std.testing.allocator.free(direct);
    try std.testing.expect(std.mem.indexOf(u8, direct, "call i32 @dict_lua_require_module_id(ptr %ctx, i32 7") != null);

    const rebound = try compile("require=function() return 1 end; return require('Module:Alias')", facts);
    defer std.testing.allocator.free(rebound);
    try std.testing.expect(std.mem.indexOf(u8, rebound, "call i32 @dict_lua_require_module_id") == null);

    const escaped = try compile("local globals=_G; local x=require('Module:Alias'); return x", facts);
    defer std.testing.allocator.free(escaped);
    try std.testing.expect(std.mem.indexOf(u8, escaped, "call i32 @dict_lua_require_module_id") == null);
}

test "pure string keyed tables lower to process shapes" {
    const source = "return { foo = 1, ['bar'] = 2 }";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var registry = llvm_shapes.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.collect(0, chunk.body);
    try std.testing.expectEqual(@as(usize, 1), registry.count());
    var shape_facts = try registry.moduleFacts(std.testing.allocator, 0);
    defer shape_facts.deinit(std.testing.allocator);
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    const generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{ .table_shapes = &shape_facts });
    defer std.testing.allocator.free(generated.source);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "call i32 @dict_lua_new_shaped_table(ptr %ctx, i32 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "call i32 @dict_lua_set_shape_slot(ptr %ctx") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, " = call i32 @dict_lua_set_field") == null);
}

test "mixed list tables keep generic dense array semantics" {
    const source = "return { 1, foo = 2 }";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var registry = llvm_shapes.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.collect(0, chunk.body);
    try std.testing.expectEqual(@as(usize, 0), registry.count());
}

test "computed-key module exports stay generic" {
    const source =
        \\local keywords = { bar = 'bar' }
        \\local function render() return 1 end
        \\return { fixed = render, [keywords.bar] = render }
    ;
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var model = llvm_module_model.Builder{
        .allocator = std.testing.allocator,
        .source = chunk.source,
    };
    defer model.deinit();
    try model.build(chunk.body);
    try std.testing.expect(!model.dynamic_top_level);
    const table = switch (model.return_binding) {
        .table => |value| value,
        else => return error.ExpectedTableModel,
    };
    try std.testing.expect(!table.shape_eligible);
    try std.testing.expect(table.fields.contains("fixed"));
}

test "module model promotes incremental exports to guarded shape slots" {
    const source =
        \\local export = {}
        \\function export.foo() return 1 end
        \\local copy = export.foo
        \\return export
    ;
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var registry = llvm_shapes.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.collect(0, chunk.body);
    try std.testing.expectEqual(@as(usize, 0), registry.count());

    var model = llvm_module_model.Builder{
        .allocator = std.testing.allocator,
        .source = chunk.source,
    };
    defer model.deinit();
    try model.build(chunk.body);
    try std.testing.expect(!model.dynamic_top_level);
    const table = switch (model.return_binding) {
        .table => |value| value,
        else => return error.ExpectedTableModel,
    };
    try std.testing.expect(table.shape_eligible);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(std.testing.allocator);
    var keys = table.fields.keyIterator();
    while (keys.next()) |key| try names.append(std.testing.allocator, key.*);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);
    _ = try registry.promote(0, table.span_start, names.items);
    var shape_facts = try registry.moduleFacts(std.testing.allocator, 0);
    defer shape_facts.deinit(std.testing.allocator);

    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    const generated = try llvm_emitter.generate(
        std.testing.allocator,
        &globals,
        &module,
        .{ .table_shapes = &shape_facts },
    );
    defer std.testing.allocator.free(generated.source);
    try std.testing.expect(std.mem.indexOf(
        u8,
        generated.source,
        "call i32 @dict_lua_new_shaped_table",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        generated.source,
        "call i32 @dict_lua_set_known_shape_field",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        generated.source,
        "call i32 @dict_lua_get_known_shape_field",
    ) != null);
}

test "immutable parameters borrow argument slots without Value copies" {
    const source = "return function(a, b) return a end";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    const generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer std.testing.allocator.free(generated.source);
    try std.testing.expect(std.mem.count(u8, generated.source, "call ptr @dict_lua_arg_ptr") >= 2);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, generated.source, "call void @dict_lua_arg_get"));
}

test "whole-corpus stable globals borrow their Context slot" {
    const compile = struct {
        fn run(source: []const u8) ![]u8 {
            var chunk = try llvm_parser.parse(std.testing.allocator, source);
            defer chunk.deinit();
            var globals = try llvm_analysis.Globals.init(std.testing.allocator);
            defer globals.deinit();
            var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
            defer module.deinit();
            return (try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{})).source;
        }
    }.run;
    const stable = try compile("return math");
    defer std.testing.allocator.free(stable);
    try std.testing.expect(std.mem.indexOf(u8, stable, "call ptr @dict_lua_global_ptr") != null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, stable, "call void @dict_lua_global_get"));

    const mutated = try compile("math = 1; return math");
    defer std.testing.allocator.free(mutated);
    try std.testing.expect(std.mem.indexOf(u8, mutated, "call void @dict_lua_global_get") != null);
}

test "call-only local functions bypass callable boxing and dynamic dispatch" {
    const source = "local f = function(a) return a end; return f(2)";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    const generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer std.testing.allocator.free(generated.source);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "define internal %FunctionResult @lua_f_1") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "call %FunctionResult @lua_f_") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "call i32 @dict_lua_enter_static_call") != null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, generated.source, " = call i32 @dict_lua_make_function"));
}

test "call-only captured closures pass cells without materializing callable identity" {
    const source = "local x = 4; local f = function(a) return x end; return f(2)";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    const generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer std.testing.allocator.free(generated.source);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "call %CallResult @dict_lua_call_static_multi") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "_cap, ptr") != null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, generated.source, " = call i32 @dict_lua_make_function"));
}

test "escaping local functions keep Lua callable identity" {
    const source = "local f = function() return 1 end; local g = f; return f == g";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    const generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer std.testing.allocator.free(generated.source);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, " = call i32 @dict_lua_make_function") != null);
}

test "stable native namespaces use compile-time field slots" {
    const source = "math.floor = math.ceil; return math.floor(1.5)";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    const generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer std.testing.allocator.free(generated.source);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "call i32 @dict_lua_get_native_slot") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "call i32 @dict_lua_set_native_slot") != null);
}

test "global table escape disables native namespace slot assumptions" {
    const source = "local env = _G; return math.floor(1.5)";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    const generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer std.testing.allocator.free(generated.source);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, generated.source, "call i32 @dict_lua_get_native_slot"));
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "call i32 @dict_lua_get_field") != null);
}

test "length and dynamic comparison stay native scalar values" {
    const source =
        \\local t = { 1 }
        \\local n = 0
        \\n = #t
        \\local ok = false
        \\ok = t == t
        \\return n, ok
    ;
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    const generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer std.testing.allocator.free(generated.source);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "call i32 @dict_lua_len_number") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "call i32 @dict_lua_compare_bool") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "store double") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "store i1") != null);
}

test "nonrecursive local function syntax uses direct static call" {
    const source = "local function f(a) return a end; return f(3)";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    const generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer std.testing.allocator.free(generated.source);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "define internal %FunctionResult @lua_f_1") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "call i32 @dict_lua_enter_static_call") != null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, generated.source, " = call i32 @dict_lua_make_function"));
}

test "recursive local function keeps callable self cell" {
    const source = "local function f(n) if n == 0 then return 0 end return f(n-1) end; return f";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    const generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer std.testing.allocator.free(generated.source);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, " = call i32 @dict_lua_make_function") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "call i32 @dict_lua_cell_new") != null);
}
