test {
    _ = @import("parser/root.zig");
    _ = @import("direct/analysis.zig");
    _ = @import("direct/emitter.zig");
    _ = @import("direct/program.zig");
    _ = @import("direct/numbers.zig");
    _ = @import("direct/module_model.zig");
    _ = @import("direct/shapes.zig");
    _ = @import("usage.zig");
    _ = @import("direct/usage_profile.zig");
    _ = @import("llvm_build_main.zig");
    _ = @import("program_metadata.zig");
    _ = @import("extract/modules.zig");
    _ = @import("wikitext/expression.zig");
    _ = @import("wikitext/preprocess.zig");
    _ = @import("runtime/pattern.zig");
    _ = @import("runtime/format_core.zig");
    _ = @import("runtime/request_allocator.zig");
}

const std = @import("std");
const llvm_parser = @import("parser/root.zig");
const llvm_analysis = @import("direct/analysis.zig");
const llvm_emitter = @import("direct/emitter.zig");
const llvm_shapes = @import("direct/shapes.zig");
const llvm_module_model = @import("direct/module_model.zig");
const llvm_program = @import("direct/program.zig");

test "static module root table omits generated root symbol" {
    const records = [_]llvm_program.ModuleRecord{
        .{
            .title = "Module:Static",
            .path = "modules/static.lua",
            .source_bytes = 10,
            .source_index = 0,
            .function_base = 40,
            .function_count = 1,
            .root_function = 40,
            .export_shape_id = null,
            .static_root = true,
        },
        .{
            .title = "Module:Dynamic",
            .path = "modules/dynamic.lua",
            .source_bytes = 10,
            .source_index = 1,
            .function_base = 41,
            .function_count = 1,
            .root_function = 41,
            .export_shape_id = null,
        },
    };
    var generated = try llvm_program.generate(std.testing.allocator, &records);
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "@dict_lua_static_module_root_unreachable") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "@lua_f_40") == null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "@lua_f_41") != null);
}

test "synthesized export module omits root body but keeps export function" {
    const source =
        \\local export = {}
        \\function export.run(x) return x end
        \\return export
    ;
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 2), module.functions.items.len);
    var generated = try llvm_emitter.generate(
        std.testing.allocator,
        &globals,
        &module,
        .{ .synth_root = true },
    );
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "define %FunctionResult @lua_f_0") == null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "define %FunctionResult @lua_f_1") != null);
}

test "LLVM batch planning omits roots with no emitted function body" {
    const base = llvm_program.ModuleRecord{
        .title = "Module:Base",
        .path = "modules/base.lua",
        .source_bytes = 1,
        .source_index = 0,
        .function_base = 0,
        .function_count = 1,
        .root_function = 0,
        .export_shape_id = null,
    };
    var static_root = base;
    static_root.static_root = true;
    try std.testing.expect(!llvm_program.needsLlvmBatch(static_root));

    var empty_synth = base;
    empty_synth.synth_root = true;
    try std.testing.expect(!llvm_program.needsLlvmBatch(empty_synth));

    var function_synth = empty_synth;
    function_synth.function_count = 2;
    try std.testing.expect(llvm_program.needsLlvmBatch(function_synth));
    try std.testing.expect(llvm_program.needsLlvmBatch(base));
}

test "program root table stubs synthesized root and retains export entry" {
    const exports = [_]llvm_emitter.DirectExport{
        .{ .name = "run", .function_id = 41 },
    };
    const records = [_]llvm_program.ModuleRecord{.{
        .title = "Module:Synth",
        .path = "modules/synth.lua",
        .source_bytes = 42,
        .source_index = 0,
        .function_base = 40,
        .function_count = 2,
        .root_function = 40,
        .export_shape_id = 0,
        .root_pure = true,
        .root_bootstrap_safe = true,
        .eager_order = 0,
        .direct_exports = &exports,
        .synth_root = true,
    }};
    var generated = try llvm_program.generate(std.testing.allocator, &records);
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "@dict_lua_static_module_root_unreachable") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "@dict_lua_program_synth_export_entries") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "@lua_f_40") == null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "@lua_f_41") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "@dict_lua_preinitialize_special_module") != null);
}

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
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const generated_source = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(generated_source);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "define %FunctionResult @lua_f_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "fadd double") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "dict_lua_make_function") != null);
}

test "large static string lists lower to compact static literal data" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "return {");
    for (0..130) |index| {
        if (index != 0) try source.append(std.testing.allocator, ',');
        try source.appendSlice(std.testing.allocator, "\"item\"");
    }
    try source.append(std.testing.allocator, '}');

    var chunk = try llvm_parser.parse(std.testing.allocator, source.items);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const generated_source = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(generated_source);

    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, generated_source, "call i32 @dict_lua_decode_static_literal("),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, generated_source, "call i32 @dict_lua_table_append("),
    );
}

test "large static string rows lower to compact static literal data" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "return {");
    for (0..130) |index| {
        if (index != 0) try source.append(std.testing.allocator, ',');
        try source.appendSlice(std.testing.allocator, "{\"a\",\"b\",\"c\"}");
    }
    try source.append(std.testing.allocator, '}');

    var chunk = try llvm_parser.parse(std.testing.allocator, source.items);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const generated_source = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(generated_source);

    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, generated_source, "call i32 @dict_lua_decode_static_literal("),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, generated_source, "call i32 @lua_sth_"),
    );
}

test "large nested static tables lower to compact static literal data" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "return {");
    for (0..130) |index| {
        if (index != 0) try source.append(std.testing.allocator, ',');
        try source.appendSlice(std.testing.allocator, "{1,\"item\"}");
    }
    try source.append(std.testing.allocator, '}');

    var chunk = try llvm_parser.parse(std.testing.allocator, source.items);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const generated_source = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(generated_source);

    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, generated_source, "call i32 @dict_lua_decode_static_literal("),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, generated_source, "call i32 @lua_sth_"),
    );
}

test "immutable numeric locals stay native LLVM SSA" {
    const source = "local x=2; local y=x+3; return y*4";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const generated_source = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(generated_source);
    // LLVM's builder may constant-fold the native scalar arithmetic immediately.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, generated_source, "call void @dict_lua_value_number"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, generated_source, "call i32 @dict_lua_require_number"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, generated_source, "call i32 @dict_lua_binary"));
}

test "undeclared stable globals use checked access for global metatable semantics" {
    const source = "return definitely_undeclared";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const generated_source = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(generated_source);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, generated_source, " = call i32 @dict_lua_global_get("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, generated_source, " = call ptr @dict_lua_native_global_ptr("));
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
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const generated_source = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(generated_source);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "alloca double") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "alloca i1") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "call i32 @dict_lua_binary") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "call i32 @dict_lua_require_number") == null);
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
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const generated_source = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(generated_source);
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
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const generated_source = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(generated_source);
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
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const generated_source = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(generated_source);
}

test "constant require lowers to module id only when global is stable" {
    var ids: llvm_emitter.ModuleIdMap = .empty;
    defer ids.deinit(std.testing.allocator);
    try ids.put(std.testing.allocator, "Module:Alias", 7);
    try ids.put(std.testing.allocator, "Module:require when needed", 8);
    try ids.put(std.testing.allocator, "Module:utilities/require when needed", 9);
    const facts = llvm_emitter.ProgramFacts{ .module_ids = &ids };
    const compile = struct {
        fn run(source: []const u8, program_facts: llvm_emitter.ProgramFacts) ![]u8 {
            var chunk = try llvm_parser.parse(std.testing.allocator, source);
            defer chunk.deinit();
            var globals = try llvm_analysis.Globals.init(std.testing.allocator);
            defer globals.deinit();
            var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
            defer module.deinit();
            var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, program_facts);
            defer generated.deinit();
            return generated.toText(std.testing.allocator);
        }
    }.run;

    const direct = try compile("local x=require('Module:Alias'); return x", facts);
    defer std.testing.allocator.free(direct);
    try std.testing.expect(std.mem.indexOf(u8, direct, "call i32 @dict_lua_require_module_id(ptr %ctx, i32 7") != null);

    const aliased = try compile("local req=require; local x=req('Module:Alias'); return x", facts);
    defer std.testing.allocator.free(aliased);
    try std.testing.expect(std.mem.indexOf(u8, aliased, "call i32 @dict_lua_require_module_id(ptr %ctx, i32 7") != null);

    const captured_alias = try compile(
        "local req=require; local function f() return req('Module:Alias') end; return f()",
        facts,
    );
    defer std.testing.allocator.free(captured_alias);
    try std.testing.expect(std.mem.indexOf(u8, captured_alias, "call i32 @dict_lua_require_module_id(ptr %ctx, i32 7") != null);

    const lazy_captured = try compile(
        "local r=require('Module:require when needed'); local m=r('Module:Alias'); local function f() return m.foo end; return f()",
        facts,
    );
    defer std.testing.allocator.free(lazy_captured);
    try std.testing.expect(std.mem.indexOf(u8, lazy_captured, "call i32 @dict_lua_require_module_id(ptr %ctx, i32 7") == null);

    const lazy_direct = try compile(
        "local m=require('Module:require when needed')('Module:Alias'); return m.foo",
        facts,
    );
    defer std.testing.allocator.free(lazy_direct);
    try std.testing.expect(std.mem.indexOf(u8, lazy_direct, "call i32 @dict_lua_require_module_id(ptr %ctx, i32 7") != null);

    const lazy_utility = try compile(
        "local m=require('Module:utilities/require when needed')('Module:Alias'); return m.foo",
        facts,
    );
    defer std.testing.allocator.free(lazy_utility);
    try std.testing.expect(std.mem.indexOf(u8, lazy_utility, "call i32 @dict_lua_require_module_id(ptr %ctx, i32 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazy_utility, "call i32 @dict_lua_require_module_id(ptr %ctx, i32 9") == null);

    const lazy_unsafe = try compile(
        "local r=require('Module:require when needed'); local m=r('Module:Alias'); return getmetatable(m)",
        facts,
    );
    defer std.testing.allocator.free(lazy_unsafe);
    try std.testing.expect(std.mem.indexOf(u8, lazy_unsafe, "call i32 @dict_lua_require_module_id(ptr %ctx, i32 7") == null);

    const mutated_alias = try compile(
        "local req=require; req=function() return 1 end; return req('Module:Alias')",
        facts,
    );
    defer std.testing.allocator.free(mutated_alias);
    try std.testing.expect(std.mem.indexOf(u8, mutated_alias, "call i32 @dict_lua_require_module_id") == null);

    const rebound = try compile("require=function() return 1 end; return require('Module:Alias')", facts);
    defer std.testing.allocator.free(rebound);
    try std.testing.expect(std.mem.indexOf(u8, rebound, "call i32 @dict_lua_require_module_id") == null);

    const escaped = try compile("local globals=_G; local x=require('Module:Alias'); return x", facts);
    defer std.testing.allocator.free(escaped);
    try std.testing.expect(std.mem.indexOf(u8, escaped, "call i32 @dict_lua_require_module_id") == null);
}

test "known module export shapes survive boxed require semantics" {
    const source = "local m = require('Module:Shaped'); return m.foo";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();

    var ids: llvm_emitter.ModuleIdMap = .empty;
    defer ids.deinit(std.testing.allocator);
    try ids.put(std.testing.allocator, "Module:Shaped", 0);
    var registry = llvm_shapes.Registry.init(std.testing.allocator);
    defer registry.deinit();
    const shape_id = (try registry.promote(0, 0, &.{"foo"})).?;
    const module_facts = [_]llvm_emitter.ModuleFact{.{
        .canonical_name = "Module:Shaped",
        .export_shape_id = shape_id,
    }};
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{
        .module_ids = &ids,
        .module_facts = &module_facts,
        .shape_registry = &registry,
    });
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_require_module_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_get_known_shape_field") != null);
}

test "eager canonical require uses prepared module fast path with semantic fallback" {
    var ids: llvm_emitter.ModuleIdMap = .empty;
    defer ids.deinit(std.testing.allocator);
    try ids.put(std.testing.allocator, "Module:Prepared", 0);
    const modules = [_]llvm_emitter.ModuleFact{.{
        .eager_prepared = true,
        .canonical_name = "Module:Prepared",
    }};
    const facts = llvm_emitter.ProgramFacts{
        .module_ids = &ids,
        .module_facts = &modules,
    };

    const compile = struct {
        fn run(source: []const u8, program_facts: llvm_emitter.ProgramFacts) ![]u8 {
            var chunk = try llvm_parser.parse(std.testing.allocator, source);
            defer chunk.deinit();
            var globals = try llvm_analysis.Globals.init(std.testing.allocator);
            defer globals.deinit();
            var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
            defer module.deinit();
            var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, program_facts);
            defer generated.deinit();
            return generated.toText(std.testing.allocator);
        }
    }.run;

    const ir = try compile("return require('Module:Prepared')", facts);
    defer std.testing.allocator.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "@dict_lua_defer_require_module_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "require_prepared") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "@dict_lua_require_module_id") != null);

    const alias_ir = try compile("return require('Prepared')", facts);
    defer std.testing.allocator.free(alias_ir);
    try std.testing.expect(std.mem.indexOf(u8, alias_ir, "require_prepared") == null);
}

test "reading package or global environment flushes deferred require visibility" {
    const compile = struct {
        fn run(source: []const u8) ![]u8 {
            var chunk = try llvm_parser.parse(std.testing.allocator, source);
            defer chunk.deinit();
            var globals = try llvm_analysis.Globals.init(std.testing.allocator);
            defer globals.deinit();
            var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
            defer module.deinit();
            var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
            defer generated.deinit();
            return generated.toText(std.testing.allocator);
        }
    }.run;

    const package_ir = try compile("return package");
    defer std.testing.allocator.free(package_ir);
    try std.testing.expect(std.mem.indexOf(u8, package_ir, "@dict_lua_observe_package") != null);
    const env_ir = try compile("return _G");
    defer std.testing.allocator.free(env_ir);
    try std.testing.expect(std.mem.indexOf(u8, env_ir, "@dict_lua_observe_package") != null);
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
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{ .table_shapes = &shape_facts });
    defer generated.deinit();
    const generated_source = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(generated_source);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "call i32 @dict_lua_new_shaped_table(ptr %ctx, i32 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "call i32 @dict_lua_set_shape_slot(ptr %ctx") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, " = call i32 @dict_lua_set_field") == null);
}

test "static table shapes survive captured and shape-stable mutable locals" {
    const compile = struct {
        fn run(source: []const u8) ![]u8 {
            var chunk = try llvm_parser.parse(std.testing.allocator, source);
            defer chunk.deinit();
            var registry = llvm_shapes.Registry.init(std.testing.allocator);
            defer registry.deinit();
            try registry.collect(0, chunk.body);
            var shape_facts = try registry.moduleFacts(std.testing.allocator, 0);
            defer shape_facts.deinit(std.testing.allocator);
            var globals = try llvm_analysis.Globals.init(std.testing.allocator);
            defer globals.deinit();
            var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
            defer module.deinit();
            var generated = try llvm_emitter.generate(
                std.testing.allocator,
                &globals,
                &module,
                .{ .table_shapes = &shape_facts },
            );
            defer generated.deinit();
            return generated.toText(std.testing.allocator);
        }
    }.run;

    const captured = try compile(
        "local t={foo=1}; local function read() return t.foo end; return read()",
    );
    defer std.testing.allocator.free(captured);
    try std.testing.expect(std.mem.indexOf(
        u8,
        captured,
        "call i32 @dict_lua_get_known_shape_field",
    ) != null);

    const mutable = try compile("local t={foo=1}; t=t; return t.foo");
    defer std.testing.allocator.free(mutable);
    try std.testing.expect(std.mem.indexOf(
        u8,
        mutable,
        "call i32 @dict_lua_get_known_shape_field",
    ) != null);

    const changed = try compile("local t={foo=1}; t={bar=2}; return t.foo");
    defer std.testing.allocator.free(changed);
    try std.testing.expect(std.mem.indexOf(
        u8,
        changed,
        "call i32 @dict_lua_get_known_shape_field",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        changed,
        "call i32 @dict_lua_get_struct_field",
    ) != null);

    const through_param = try compile(
        "local function read(t) return t.foo end; local s={foo=1}; return read(s)",
    );
    defer std.testing.allocator.free(through_param);
    try std.testing.expect(std.mem.indexOf(
        u8,
        through_param,
        "call i32 @dict_lua_get_known_shape_field",
    ) != null);
}

test "list and numeric table keys lower to fixed shape slots" {
    const source = "local t = { 1, 2, foo = 3, [true] = 4 }; t[2] = 5; return t[2], t[true]";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var registry = llvm_shapes.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.collect(0, chunk.body);
    try std.testing.expectEqual(@as(usize, 1), registry.count());
    var shape_facts = try registry.moduleFacts(std.testing.allocator, 0);
    defer shape_facts.deinit(std.testing.allocator);
    const shape = shape_facts.get(chunk.body[0].local_assign.values[0].table.span.start).?;
    try std.testing.expectEqual(@as(usize, 4), shape.keys.len);
    try std.testing.expect(shape.keys[0] == .number and shape.keys[0].number == 1);
    try std.testing.expect(shape.keys[1] == .number and shape.keys[1].number == 2);
    try std.testing.expect(shape.keys[2] == .string and std.mem.eql(u8, shape.keys[2].string, "foo"));
    try std.testing.expect(shape.keys[3] == .boolean and shape.keys[3].boolean);

    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(
        std.testing.allocator,
        &globals,
        &module,
        .{ .table_shapes = &shape_facts },
    );
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_new_shaped_table") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_get_known_shape_index") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_set_known_shape_index") != null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ir, "call i32 @dict_lua_get_index("));
}

test "dynamic keys on known table shapes stay structural" {
    const source =
        \\local t = { foo = 1, bar = 2 }
        \\local k = "foo"
        \\local w = "bar"
        \\local value = t[k]
        \\t[w] = 7
        \\return value, t.bar
    ;
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var registry = llvm_shapes.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.collect(0, chunk.body);
    var shape_facts = try registry.moduleFacts(std.testing.allocator, 0);
    defer shape_facts.deinit(std.testing.allocator);
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(
        std.testing.allocator,
        &globals,
        &module,
        .{ .table_shapes = &shape_facts },
    );
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_get_shape_dynamic") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_set_shape_dynamic") != null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ir, "call i32 @dict_lua_get_index("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ir, "call i32 @dict_lua_set_index("));
}

test "dense numeric accesses and len-plus-one appends bypass generic table indexing" {
    const source =
        \\local values = {}
        \\local function add(value)
        \\  values[#values + 1] = value
        \\end
        \\add(4)
        \\add(5)
        \\return values[1], values[2]
    ;
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_set_len_plus_one") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_get_typed_array_index") != null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ir, "call i32 @dict_lua_get_struct_index("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ir, "call i32 @dict_lua_set_struct_index("));
}

test "non-escaping index-only tables lower dynamic keys to linear struct cells" {
    const source =
        \\local seen = {}
        \\local first = {}
        \\local second = {}
        \\local key = first
        \\local before = seen[key]
        \\seen[key] = true
        \\key = second
        \\local after = seen[key]
        \\seen[key] = true
        \\return before, after
    ;
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_get_linear_index") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_set_linear_index") != null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ir, "call i32 @dict_lua_get_struct_index("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ir, "call i32 @dict_lua_set_struct_index("));
}

test "metamethod parameters retain guarded receiver struct shapes" {
    const source =
        \\local mt = { __lt = function(a, b) return a.n < b.n end }
        \\local a = setmetatable({ n = 1 }, mt)
        \\local b = setmetatable({ n = 2 }, mt)
        \\return a < b
    ;
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var registry = llvm_shapes.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.collect(0, chunk.body);
    var shape_facts = try registry.moduleFacts(std.testing.allocator, 0);
    defer shape_facts.deinit(std.testing.allocator);
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(
        std.testing.allocator,
        &globals,
        &module,
        .{ .table_shapes = &shape_facts },
    );
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);
    try std.testing.expect(std.mem.count(u8, ir, "call i32 @dict_lua_get_known_shape_field") >= 2);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ir, "call i32 @dict_lua_get_struct_field("));
}

test "nested table fields retain child struct shapes" {
    const source = "local t = { foo = { bar = { baz = 7 } } }; return t.foo.bar.baz";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var registry = llvm_shapes.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.collect(0, chunk.body);
    var shape_facts = try registry.moduleFacts(std.testing.allocator, 0);
    defer shape_facts.deinit(std.testing.allocator);
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(
        std.testing.allocator,
        &globals,
        &module,
        .{ .table_shapes = &shape_facts, .shape_registry = &registry },
    );
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);
    try std.testing.expect(std.mem.count(u8, ir, "call i32 @dict_lua_get_known_shape_field") >= 3);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ir, "call i32 @dict_lua_get_field_hashed("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ir, "call i32 @dict_lua_get_field_cached("));
}

test "local function returns retain table struct shapes" {
    const source =
        \\local function make()
        \\  return { foo = { bar = 9 } }
        \\end
        \\return make().foo.bar
    ;
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var registry = llvm_shapes.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.collect(0, chunk.body);
    var shape_facts = try registry.moduleFacts(std.testing.allocator, 0);
    defer shape_facts.deinit(std.testing.allocator);
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(
        std.testing.allocator,
        &globals,
        &module,
        .{ .table_shapes = &shape_facts, .shape_registry = &registry },
    );
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);
    try std.testing.expect(std.mem.count(u8, ir, "call i32 @dict_lua_get_known_shape_field") >= 2);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ir, "call i32 @dict_lua_get_field_hashed("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ir, "call i32 @dict_lua_get_field_cached("));
}

test "incrementally populated local tables promote to fixed shapes" {
    const source =
        \\local t = {}
        \\t.foo = 1
        \\t[2] = 2
        \\local alias = t
        \\alias.bar = 3
        \\local function captured() t.baz = 4; return t.baz end
        \\return t.foo, t[2], alias.bar, captured()
    ;
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var registry = llvm_shapes.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.collect(0, chunk.body);
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    for (module.table_shape_writes.items) |write| {
        if (llvm_shapes.staticKey(write.key)) |key|
            _ = try registry.extendKey(0, write.table_span.start, key);
    }
    var shape_facts = try registry.moduleFacts(std.testing.allocator, 0);
    defer shape_facts.deinit(std.testing.allocator);
    const table_span = chunk.body[0].local_assign.values[0].table.span;
    const shape = shape_facts.get(table_span.start).?;
    try std.testing.expectEqual(@as(usize, 4), shape.keys.len);

    var generated = try llvm_emitter.generate(
        std.testing.allocator,
        &globals,
        &module,
        .{ .table_shapes = &shape_facts },
    );
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_new_shaped_table") != null);
    try std.testing.expect(std.mem.count(u8, ir, "call i32 @dict_lua_set_known_shape_field") >= 3);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_set_known_shape_index") != null);
    try std.testing.expect(std.mem.count(u8, ir, "call i32 @dict_lua_get_known_shape_field") >= 3);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_get_known_shape_index") != null);
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
    var generated = try llvm_emitter.generate(
        std.testing.allocator,
        &globals,
        &module,
        .{ .table_shapes = &shape_facts },
    );
    defer generated.deinit();
    const generated_source = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(generated_source);
    try std.testing.expect(std.mem.indexOf(
        u8,
        generated_source,
        "call i32 @dict_lua_new_shaped_table",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        generated_source,
        "call i32 @dict_lua_set_known_shape_field",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        generated_source,
        "call i32 @dict_lua_get_known_shape_field",
    ) != null);
}

test "fixed LLVM results use the audited 24-byte Value stride" {
    const source = "return function(a, b) return a, b end";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);
    // Runtime and shared-leaf checks independently audit @sizeOf(Value).
    // This checks the compiler's actual array element type at a fixed return.
    try std.testing.expect(std.mem.indexOf(u8, ir, "[2 x [24 x i8]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "[32 x i8]") == null);
}

test "literal field reads carry exact hashes while dynamic keys retain generic lookup" {
    const source = "return function(t, key) return t.current_layer, t[key] end";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);
    const needle = "call i32 @dict_lua_get_struct_field(";
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ir, needle));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ir, "call i32 @dict_lua_get_struct_index("));
    const start = std.mem.indexOf(u8, ir, needle).?;
    const end = std.mem.indexOfScalarPos(u8, ir, start, '\n') orelse ir.len;
    const hash = @import("abi/static_fields.zig").hashStringKey("current_layer");
    const argument = try std.fmt.allocPrint(std.testing.allocator, "i64 {d}, i64", .{@as(i64, @bitCast(hash))});
    defer std.testing.allocator.free(argument);
    try std.testing.expect(std.mem.indexOf(u8, ir[start..end], argument) != null);
}

test "immutable parameters borrow argument slots without Value copies" {
    const source = "return function(a, b) return a end";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const generated_source = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(generated_source);
    try std.testing.expect(std.mem.count(u8, generated_source, "call ptr @dict_lua_arg_ptr") >= 2);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, generated_source, "call void @dict_lua_arg_get"));
}

test "stable ABI globals borrow their Context slot while mutable globals stay checked" {
    const compile = struct {
        fn run(source: []const u8) ![]u8 {
            var chunk = try llvm_parser.parse(std.testing.allocator, source);
            defer chunk.deinit();
            var globals = try llvm_analysis.Globals.init(std.testing.allocator);
            defer globals.deinit();
            var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
            defer module.deinit();
            var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
            defer generated.deinit();
            return generated.toText(std.testing.allocator);
        }
    }.run;
    const stable = try compile("return math");
    defer std.testing.allocator.free(stable);
    try std.testing.expect(std.mem.indexOf(u8, stable, "call ptr @dict_lua_native_global_ptr") != null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, stable, " = call i32 @dict_lua_global_get("));

    const mutated = try compile("math = 1; return math");
    defer std.testing.allocator.free(mutated);
    try std.testing.expect(std.mem.indexOf(u8, mutated, " = call i32 @dict_lua_global_get(") != null);
}

test "call-only local functions bypass callable boxing and dynamic dispatch" {
    const source = "local f = function(a) return a end; return f(2)";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const generated_source = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(generated_source);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "define internal %FunctionResult @lua_f_1") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "call %FunctionResult @lua_f_") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "call i32 @dict_lua_enter_local_static_call(ptr %ctx)") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "call i32 @dict_lua_enter_static_call(") == null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, generated_source, " = call i32 @dict_lua_make_function"));
}

test "call-only captured closures pass cells without materializing callable identity" {
    const source = "local x = 4; local f = function(a) return x end; return f(2)";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const generated_source = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(generated_source);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "call i32 @dict_lua_init_direct_captures") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, generated_source, "call i32 @dict_lua_direct_capture_cells"));
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "@dict_lua_capture_cell") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "call i32 @dict_lua_enter_local_static_call(ptr %ctx)") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "call %FunctionResult @lua_f_1") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "call %CallResult @dict_lua_call_static_multi") == null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, generated_source, " = call i32 @dict_lua_make_function"));
}

test "escaping local functions keep Lua callable identity" {
    const source = "local f = function() return 1 end; local g = f; return f == g";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const generated_source = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(generated_source);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, " = call i32 @dict_lua_make_function") != null);
}

test "stable native namespaces use compile-time field slots" {
    const source = "math.floor = math.ceil; return math.floor(1.5)";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const generated_source = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(generated_source);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "call i32 @dict_lua_get_native_slot") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "call i32 @dict_lua_set_native_slot") != null);
}

test "native namespace fields and returns retain structural types" {
    const source =
        \\local title = mw.title.new("rat")
        \\local language = mw.getLanguage("en")
        \\local node = mw.html.create("div"):tag("span")
        \\local uri = mw.uri.new("https://example.test/path")
        \\local batch = mw.title.newBatch({"rat"}):lookupExistence()
        \\local titles = batch:getTitles()
        \\local template_ns = mw.site.namespaces.Template
        \\local bits = require("bit32")
        \\local libraryUtil = require("libraryUtil")
        \\return title.prefixedText, title.contentModel, language:getCode(), node:allDone(), uri.protocol, titles[1].prefixedText, os.date("!%Y", 0), template_ns.isCapitalized, package.loaded, bits.band, libraryUtil.checkType, debug.getinfo
    ;
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_get_native_slot") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_get_known_native_slot") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_get_typed_array_index") != null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ir, "call i32 @dict_lua_get_field_cached("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ir, "call i32 @dict_lua_get_field_hashed("));
}

test "captured native results retain structural types" {
    const source = "local media=mw.title.new('Media:Remote.svg'); return function() return media.exists end";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_get_known_native_slot") != null);
}

test "exported Scribunto entry first argument is a guarded frame struct" {
    const source = "local function run(frame) return frame:preprocess('x') end; return {run=run}";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    const run_id = module.functions.items[1].id;
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{
        .frame_entry_functions = &.{run_id},
    });
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_get_known_native_slot") != null);
}

test "global table escape disables native namespace slot assumptions" {
    const source = "local env = _G; return math.floor(1.5)";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const generated_source = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(generated_source);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, generated_source, "call i32 @dict_lua_get_native_slot"));
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "call i32 @dict_lua_get_struct_field") != null);
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
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const generated_source = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(generated_source);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "call i32 @dict_lua_len_number") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "call i32 @dict_lua_compare_bool") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "store double") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "store i1") != null);
}

test "nil and known boolean equality avoid dynamic comparison" {
    const source =
        \\local function unknown() return nil end
        \\local t = {}
        \\local a = unknown()
        \\return nil == nil, nil ~= false, nil == t, a == nil, nil ~= a,
        \\       true == false, true ~= false, (0/0) == (0/0), t == t
    ;
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, ir, "call i8 @dict_lua_value_is_nil"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ir, "call i32 @dict_lua_compare_bool"));
}

test "nil equality emits both operand calls in source order" {
    const source =
        \\local order = ""
        \\local function left() order = order .. "L"; return nil end
        \\local function right() order = order .. "R"; return nil end
        \\return left() == nil, nil ~= right(), order
    ;
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);
    const left = std.mem.indexOf(u8, ir, "call %FunctionResult @lua_f_1(") orelse return error.MissingLeftCall;
    const right = std.mem.indexOf(u8, ir, "call %FunctionResult @lua_f_2(") orelse return error.MissingRightCall;
    try std.testing.expect(left < right);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, ir, "call i8 @dict_lua_value_is_nil"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ir, "call i32 @dict_lua_compare_bool"));
}

test "fixed returns expose clipped caller buffers and retain owned fallback" {
    var chunk = try llvm_parser.parse(std.testing.allocator, "return nil, false, 7");
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);

    try std.testing.expect(std.mem.indexOf(u8, ir, "icmp ne ptr %result_ptr, null") != null);
    for (0..3) |index| {
        const guard = try std.fmt.allocPrint(std.testing.allocator, "icmp ugt i64 %result_len, {d}", .{index});
        defer std.testing.allocator.free(guard);
        try std.testing.expect(std.mem.indexOf(u8, ir, guard) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, ir, "icmp ult i64 %result_len, 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "insertvalue %FunctionResult zeroinitializer") != null);
    const owned_start = std.mem.indexOf(u8, ir, "return_owned:") orelse return error.MissingOwnedReturn;
    const owned_rest = ir[owned_start..];
    const owned_end = std.mem.indexOf(u8, owned_rest, "\n\n") orelse return error.MissingOwnedReturnEnd;
    try std.testing.expect(std.mem.indexOf(u8, owned_rest[0..owned_end], "call %FunctionResult @dict_lua_return_values") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ir, "call %FunctionResult @dict_lua_return_values"));
}

test "empty returns construct a constant result without allocation" {
    var chunk = try llvm_parser.parse(std.testing.allocator, "return");
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "ret %FunctionResult zeroinitializer") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call %FunctionResult @dict_lua_return_values") == null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "return_buffered") == null);
}

test "fixed return evaluates all operands before testing caller capacity" {
    const source =
        \\local order = ""
        \\local function left() order = order .. "L"; return nil end
        \\local function right() order = order .. "R"; return false end
        \\return left(), right(), order
    ;
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);
    const left = std.mem.indexOf(u8, ir, "call %FunctionResult @lua_f_1(") orelse return error.MissingLeftCall;
    const right = std.mem.indexOf(u8, ir, "call %FunctionResult @lua_f_2(") orelse return error.MissingRightCall;
    const capacity = std.mem.indexOf(u8, ir, "icmp ne ptr %result_ptr, null") orelse return error.MissingReturnBufferGuard;
    try std.testing.expect(left < right and right < capacity);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ir, "call %FunctionResult @lua_f_1("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ir, "call %FunctionResult @lua_f_2("));
}

test "direct call success bypasses error-name helper" {
    const source = "local function f(a) return a end; local x = f(3); return x";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);
    const failed_start = std.mem.indexOf(u8, ir, "function_status_error:") orelse return error.MissingFunctionFailure;
    const failed_rest = ir[failed_start..];
    const failed_end = std.mem.indexOf(u8, failed_rest, "\n\n") orelse return error.MissingFunctionFailureEnd;
    const failed = failed_rest[0..failed_end];
    try std.testing.expect(std.mem.indexOf(u8, failed, "call i32 @dict_lua_function_status") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed, "br label %error") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ir, "call i32 @dict_lua_function_status"));
    const leave = std.mem.indexOf(u8, ir, "call void @dict_lua_leave_local_static_call") orelse return error.MissingStaticCallLeave;
    const status_branch = std.mem.indexOf(u8, ir, "label %function_status_ok, label %function_status_error") orelse return error.MissingStatusBranch;
    try std.testing.expect(leave < status_branch);
}

test "nonrecursive local function syntax uses direct static call" {
    const source = "local function f(a) return a end; return f(3)";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const generated_source = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(generated_source);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "define internal %FunctionResult @lua_f_1") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "call i32 @dict_lua_enter_local_static_call(ptr %ctx)") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "call i32 @dict_lua_enter_static_call(") == null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, generated_source, " = call i32 @dict_lua_make_function"));
}

test "recursive local function keeps callable self cell" {
    const source = "local function f(n) if n == 0 then return 0 end return f(n-1) end; return f";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const generated_source = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(generated_source);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, " = call i32 @dict_lua_make_function") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "call i32 @dict_lua_cell_new") != null);
}

test "captured local calls guard analyzed function and use live closure captures" {
    const source =
        \\local function factory(x)
        \\  local function target(y) return x + y end
        \\  local function replace(other) target = other end
        \\  local function middle()
        \\    local function invoke(y)
        \\      local result = target(y)
        \\      return result
        \\    end
        \\    return invoke
        \\  end
        \\  return middle(), replace
        \\end
        \\return factory
    ;
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);

    // `target` is declared in factory and read through middle/invoke upvalues.
    // The analyzed ID chooses the direct entry, while the loaded callable's
    // current captures and ID guard preserve factory instances and rebinding.
    const target_id = module.functions.items[2].id;
    const direct_call = try std.fmt.allocPrint(std.testing.allocator, "call %FunctionResult @lua_f_{d}(", .{target_id});
    defer std.testing.allocator.free(direct_call);
    try std.testing.expect(std.mem.indexOf(u8, ir, direct_call) != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call ptr @dict_lua_value_function_captures") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i8 @dict_lua_value_is_function_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "direct_export:") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "dynamic_export:") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_call_fixed(") != null);
}

test "known module export emits guarded direct LLVM call" {
    var ids: llvm_emitter.ModuleIdMap = .empty;
    defer ids.deinit(std.testing.allocator);
    try ids.put(std.testing.allocator, "Module:Target", 0);
    const exports = [_]llvm_emitter.DirectExport{
        .{ .name = "run", .function_id = 99 },
    };
    const modules = [_]llvm_emitter.ModuleFact{
        .{ .root_pure = false, .exports = &exports },
    };
    const facts = llvm_emitter.ProgramFacts{
        .module_ids = &ids,
        .module_facts = &modules,
        .current_module_id = 1,
    };

    var chunk = try llvm_parser.parse(
        std.testing.allocator,
        "local target=require('Module:Target'); return target.run(4)",
    );
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, facts);
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);

    try std.testing.expect(std.mem.indexOf(u8, ir, "@dict_lua_require_module_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "@dict_lua_value_is_function_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call %FunctionResult @lua_f_99") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_enter_static_call(ptr %ctx, i32 0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_enter_static_call(ptr %ctx, i32 99)") == null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "return_export_direct:") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "return_export_fallback:") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call %FunctionResult @dict_lua_return_call(") != null);
}

test "known module function returns retain table struct shapes" {
    var ids: llvm_emitter.ModuleIdMap = .empty;
    defer ids.deinit(std.testing.allocator);
    try ids.put(std.testing.allocator, "Module:Target", 0);
    var registry = llvm_shapes.Registry.init(std.testing.allocator);
    defer registry.deinit();
    const return_shape = (try registry.promote(0, 200, &.{"foo"})).?;
    const exports = [_]llvm_emitter.DirectExport{
        .{ .name = "make", .function_id = 99, .return_shape_id = return_shape },
    };
    const modules = [_]llvm_emitter.ModuleFact{
        .{ .root_pure = false, .exports = &exports },
    };
    const facts = llvm_emitter.ProgramFacts{
        .module_ids = &ids,
        .module_facts = &modules,
        .shape_registry = &registry,
        .current_module_id = 1,
    };
    var chunk = try llvm_parser.parse(
        std.testing.allocator,
        "local target=require('Module:Target'); return target.make().foo",
    );
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, facts);
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call %FunctionResult @lua_f_99") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_get_known_shape_field") != null);
}

test "eager pristine module export bypasses field lookup on direct branch" {
    var ids: llvm_emitter.ModuleIdMap = .empty;
    defer ids.deinit(std.testing.allocator);
    try ids.put(std.testing.allocator, "Module:Target", 0);
    const exports = [_]llvm_emitter.DirectExport{
        .{ .name = "run", .function_id = 99 },
    };
    const modules = [_]llvm_emitter.ModuleFact{.{
        .eager_prepared = true,
        .canonical_name = "Module:Target",
        .exports = &exports,
    }};
    const facts = llvm_emitter.ProgramFacts{
        .module_ids = &ids,
        .module_facts = &modules,
    };

    var chunk = try llvm_parser.parse(
        std.testing.allocator,
        "local target=require('Module:Target'); return target.run(4)",
    );
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, facts);
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);

    try std.testing.expect(std.mem.indexOf(u8, ir, "@dict_lua_defer_require_module_ref") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "@dict_lua_module_export_pristine") == null);
    const start = std.mem.indexOf(u8, ir, "return_pristine_direct:") orelse return error.MissingPristineExportBlock;
    const rest = ir[start..];
    const end = std.mem.indexOf(u8, rest, "return_pristine_fallback:") orelse return error.MissingPristineFallbackBlock;
    const block = rest[0..end];
    try std.testing.expect(std.mem.indexOf(u8, block, "@dict_lua_get_field") == null);
    try std.testing.expect(std.mem.indexOf(u8, block, "@dict_lua_value_is_function_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call %FunctionResult @lua_f_99") != null);
    const fallback_start = std.mem.indexOf(u8, ir, "export_callee_fallback:") orelse return error.MissingExportFallbackBlock;
    try std.testing.expect(std.mem.indexOf(u8, ir[fallback_start..], "@dict_lua_get_struct_field") != null);
}

test "captured eager module value keeps mutation-guarded direct export call" {
    var ids: llvm_emitter.ModuleIdMap = .empty;
    defer ids.deinit(std.testing.allocator);
    try ids.put(std.testing.allocator, "Module:Target", 0);
    const exports = [_]llvm_emitter.DirectExport{
        .{ .name = "run", .function_id = 99 },
    };
    const modules = [_]llvm_emitter.ModuleFact{.{
        .eager_prepared = true,
        .canonical_name = "Module:Target",
        .exports = &exports,
    }};
    const facts = llvm_emitter.ProgramFacts{
        .module_ids = &ids,
        .module_facts = &modules,
    };

    var chunk = try llvm_parser.parse(
        std.testing.allocator,
        "local target=require('Module:Target'); return function() return target.run(4) end",
    );
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, facts);
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);

    try std.testing.expect(std.mem.indexOf(u8, ir, "@dict_lua_module_value_sentinel") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call %FunctionResult @lua_f_99") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "export_callee_check_pristine") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "export_callee_fallback") != null);
}

test "captured static module export keeps guarded direct target" {
    var ids: llvm_emitter.ModuleIdMap = .empty;
    defer ids.deinit(std.testing.allocator);
    try ids.put(std.testing.allocator, "Module:Target", 0);
    const exports = [_]llvm_emitter.DirectExport{
        .{ .name = "run", .function_id = 99, .capture_count = 1 },
    };
    const modules = [_]llvm_emitter.ModuleFact{
        .{ .exports = &exports },
    };
    const facts = llvm_emitter.ProgramFacts{
        .module_ids = &ids,
        .module_facts = &modules,
    };

    var chunk = try llvm_parser.parse(
        std.testing.allocator,
        "local target=require('Module:Target'); return function() return target.run(4) end",
    );
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, facts);
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);

    try std.testing.expect(std.mem.indexOf(u8, ir, "call %FunctionResult @lua_f_99") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "@dict_lua_value_is_function_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "@dict_lua_value_function_captures") != null);
}

test "module model preserves static literal export fields and rejects untracked list roots" {
    const source =
        \\local answer = 42
        \\local export = { kind = 'mixed', nested = { ok = true } }
        \\local alias = export
        \\alias.answer = answer
        \\function alias.run(x) return x end
        \\return export
    ;
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var model = llvm_module_model.Builder{ .allocator = std.testing.allocator, .source = chunk.source };
    defer model.deinit();
    try model.build(chunk.body);
    try std.testing.expect(model.root_pure);
    try std.testing.expect(!model.dynamic_top_level);
    const table = switch (model.return_binding) {
        .table => |value| value,
        else => return error.ExpectedTableModel,
    };
    try std.testing.expect(table.shape_eligible);
    try std.testing.expect(table.fields.get("kind").? == .literal);
    try std.testing.expect(table.fields.get("nested").? == .literal);
    try std.testing.expect(table.fields.get("answer").? == .literal);
    try std.testing.expect(table.fields.get("run").? == .function);

    var list_chunk = try llvm_parser.parse(
        std.testing.allocator,
        "local export={11,22}; return export",
    );
    defer list_chunk.deinit();
    var list_model = llvm_module_model.Builder{
        .allocator = std.testing.allocator,
        .source = list_chunk.source,
    };
    defer list_model.deinit();
    try list_model.build(list_chunk.body);
    const list_table = switch (list_model.return_binding) {
        .table => |value| value,
        else => return error.ExpectedTableModel,
    };
    try std.testing.expect(!list_table.shape_eligible);
}

test "module root purity only accepts context-free local construction" {
    const pure_source =
        \\local export = {}
        \\function export.run(x) return x end
        \\return export
    ;
    var pure_chunk = try llvm_parser.parse(std.testing.allocator, pure_source);
    defer pure_chunk.deinit();
    var pure = llvm_module_model.Builder{ .allocator = std.testing.allocator, .source = pure_chunk.source };
    defer pure.deinit();
    try pure.build(pure_chunk.body);
    try std.testing.expect(pure.root_pure);

    var require_chunk = try llvm_parser.parse(std.testing.allocator, "local m=require('Module:X'); return m");
    defer require_chunk.deinit();
    var require_model = llvm_module_model.Builder{ .allocator = std.testing.allocator, .source = require_chunk.source };
    defer require_model.deinit();
    try require_model.build(require_chunk.body);
    try std.testing.expect(!require_model.root_pure);

    var global_chunk = try llvm_parser.parse(std.testing.allocator, "local x=mw; return x");
    defer global_chunk.deinit();
    var global_model = llvm_module_model.Builder{ .allocator = std.testing.allocator, .source = global_chunk.source };
    defer global_model.deinit();
    try global_model.build(global_chunk.body);
    try std.testing.expect(!global_model.root_pure);
}

test "module bootstrap safety admits literal require chains but rejects dynamic loads" {
    const safe_source =
        \\local dep = require('Module:Dependency')
        \\local export = { dep = dep }
        \\return export
    ;
    var safe_chunk = try llvm_parser.parse(std.testing.allocator, safe_source);
    defer safe_chunk.deinit();
    var safe = llvm_module_model.Builder{
        .allocator = std.testing.allocator,
        .source = safe_chunk.source,
    };
    defer safe.deinit();
    try safe.build(safe_chunk.body);
    try std.testing.expect(!safe.root_pure);
    try std.testing.expect(safe.root_bootstrap_safe);
    try std.testing.expectEqual(@as(usize, 1), safe.root_requires.items.len);
    try std.testing.expectEqualStrings("Module:Dependency", safe.root_requires.items[0]);

    const aliased_source =
        \\local require = require
        \\local dependency_module = 'Module:Dependency'
        \\local dep = require(dependency_module)
        \\return dep
    ;
    var aliased_chunk = try llvm_parser.parse(std.testing.allocator, aliased_source);
    defer aliased_chunk.deinit();
    var aliased = llvm_module_model.Builder{
        .allocator = std.testing.allocator,
        .source = aliased_chunk.source,
    };
    defer aliased.deinit();
    try aliased.build(aliased_chunk.body);
    try std.testing.expect(aliased.root_bootstrap_safe);
    try std.testing.expectEqual(@as(usize, 1), aliased.root_requires.items.len);
    try std.testing.expectEqualStrings("Module:Dependency", aliased.root_requires.items[0]);

    var dynamic_chunk = try llvm_parser.parse(
        std.testing.allocator,
        "local name=tostring(1); local dep=require(name); return dep",
    );
    defer dynamic_chunk.deinit();
    var dynamic = llvm_module_model.Builder{
        .allocator = std.testing.allocator,
        .source = dynamic_chunk.source,
    };
    defer dynamic.deinit();
    try dynamic.build(dynamic_chunk.body);
    try std.testing.expect(!dynamic.root_bootstrap_safe);
}

test "saved method local uses exact callable guard at fixed and return arities" {
    const source =
        \\local offset = 1
        \\local object = {}
        \\function object.consume(x) return x + offset, x + offset + 1 end
        \\local consume = object.consume
        \\local one = consume(1)
        \\consume(2)
        \\local first, second = consume(3)
        \\local values = { consume(4) }
        \\return consume(5)
    ;
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    const target = module.functions.items[1];
    const candidates = [_]llvm_emitter.MethodCandidate{.{
        .name = "consume",
        .function_id = target.id,
        .module_id = 0,
        .capture_count = @intCast(target.upvalues.len),
    }};
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{
        .method_candidates = &candidates,
        .current_module_id = 0,
    });
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);

    const entry = try std.fmt.allocPrint(std.testing.allocator, "call %FunctionResult @lua_f_{d}(", .{target.id});
    defer std.testing.allocator.free(entry);
    try std.testing.expect(std.mem.indexOf(u8, ir, entry) != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i8 @dict_lua_value_is_function_id") != null);
    try std.testing.expect(target.upvalues.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call ptr @dict_lua_value_function_captures") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_call_fixed(") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_call_discard(") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call %CallResult @dict_lua_call_multi(") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call %FunctionResult @dict_lua_return_call(") != null);
}

test "reassigned saved method local retains ordinary dynamic call" {
    const source =
        \\local object = {}
        \\function object.consume(x) return x end
        \\local consume = object.consume
        \\consume = object.other
        \\return consume(1)
    ;
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    const candidates = [_]llvm_emitter.MethodCandidate{.{
        .name = "consume",
        .function_id = module.functions.items[1].id,
        .module_id = 0,
        .capture_count = 0,
    }};
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{
        .method_candidates = &candidates,
        .current_module_id = 0,
    });
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i8 @dict_lua_value_is_function_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call %FunctionResult @dict_lua_return_call(") != null);
}

test "guarded numeric continuations keep proven local results native after one normal call" {
    const compile = struct {
        fn run(source: []const u8) ![]u8 {
            var chunk = try llvm_parser.parse(std.testing.allocator, source);
            defer chunk.deinit();
            var globals = try llvm_analysis.Globals.init(std.testing.allocator);
            defer globals.deinit();
            var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
            defer module.deinit();
            var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
            defer generated.deinit();
            return generated.toText(std.testing.allocator);
        }
    }.run;
    const eligible = try compile(
        "return function(find, text, head) " ++
            "local a, b, capture; a, b, capture = find(text, '(.)', head); " ++
            "if not a then capture, a = '', #text + 1; b = a - 1 end; " ++
            "return b - a + head, capture end",
    );
    defer std.testing.allocator.free(eligible);
    try std.testing.expect(std.mem.indexOf(u8, eligible, "numeric_continuation_fast") != null);
    try std.testing.expect(std.mem.indexOf(u8, eligible, "numeric_continuation_generic") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, eligible, "call i32 @dict_lua_call_fixed("));
    const fast = std.mem.indexOf(u8, eligible, "\nnumeric_continuation_fast:").?;
    const end = std.mem.indexOfPos(u8, eligible, fast + 1, "\nnumeric_continuation_generic:").?;
    // Only the checked branch extracts doubles; the generic branch retains
    // arbitrary values, coercion, metamethods and the no-match nil case.
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, eligible[fast..end], "call double @dict_lua_value_number_unchecked("));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, eligible[fast..end], "store double"));

    const unsafe_sources = [_][]const u8{
        // The second assignment can change the numeric representation.
        "return function(find, text, head) local a,b,c; a,b,c=find(text,'',head); if not a then a,b=1,0 end; a='changed'; return a,b,c end",
        // A closure must continue observing the same mutable boxed cell.
        "return function(find,text,head) local a,b,c; local observe=function() return a end; a,b,c=find(text,'',head); if not a then a,b=1,0 end; return observe(),b,c end",
        // A callback may mutate a captured head during the original call.
        "return function(find,text,head) local mutate=function() head=2 end; local a,b,c; a,b,c=find(text,mutate(),head); if not a then a,b=1,0 end; return a,b,c end",
        // A later shadowing declaration would require a separate lexical proof.
        "return function(find,text,head) local a,b,c; a,b,c=find(text,'',head); if not a then a,b=1,0 end; local a='shadow'; return a,b,c end",
    };
    for (unsafe_sources) |source| {
        const generic = try compile(source);
        defer std.testing.allocator.free(generic);
        try std.testing.expect(std.mem.indexOf(u8, generic, "numeric_continuation_fast") == null);
    }
}

test "bounded scalar regions retain immutable snapshots across callbacks and loops" {
    const compile = struct {
        fn run(source: []const u8) ![]u8 {
            var chunk = try llvm_parser.parse(std.testing.allocator, source);
            defer chunk.deinit();
            var globals = try llvm_analysis.Globals.init(std.testing.allocator);
            defer globals.deinit();
            var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
            defer module.deinit();
            var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
            defer generated.deinit();
            return generated.toText(std.testing.allocator);
        }
    }.run;
    const eligible_sources = [_][]const u8{
        "return function(x) return (x + 1) * (x - 1) + x end",
        // Snapshot is taken once before the callback; later table writes do not
        // change it. Duplicated local and loop binding IDs must remain valid.
        "return function(t, callback) local x=t.x; callback(t); local sum=0; " ++
            "for i=1,2 do local part=x+i; sum=sum+part end; return sum+x*2+x end",
        // Independent nested scopes and control-flow joins share the snapshot.
        "return function(x, flag) if flag then local y=x+1; use(y) " ++
            "else local y=x-1; use(y) end; return x*2 end",
    };
    for (eligible_sources) |source| {
        const ir = try compile(source);
        defer std.testing.allocator.free(ir);
        try std.testing.expect(std.mem.indexOf(u8, ir, "scalar_region_fast") != null);
        try std.testing.expect(std.mem.indexOf(u8, ir, "scalar_region_generic") != null);
        const fast = std.mem.indexOf(u8, ir, "\nscalar_region_fast:").?;
        const generic = std.mem.indexOfPos(u8, ir, fast + 1, "\nscalar_region_generic:").?;
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(
            u8,
            ir[fast..generic],
            "call double @dict_lua_value_number_unchecked(",
        ));
    }
    const ineligible_sources = [_][]const u8{
        "return function(x) x=other(); return x+x+x end",
        "return function(x) local change=function() x=other() end; change(); return x+x+x end",
        "return function(x) do local x=other(); use(x+x+x) end; return x end",
        "return function(x) return x+x end",
    };
    for (ineligible_sources) |source| {
        const ir = try compile(source);
        defer std.testing.allocator.free(ir);
        try std.testing.expect(std.mem.indexOf(u8, ir, "scalar_region_fast") == null);
    }
}

test "closed numeric loop preserves guarded recurrence and rejects unknown writes" {
    const compile = struct {
        fn run(source: []const u8) ![]u8 {
            var chunk = try llvm_parser.parse(std.testing.allocator, source);
            defer chunk.deinit();
            var globals = try llvm_analysis.Globals.init(std.testing.allocator);
            defer globals.deinit();
            var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
            defer module.deinit();
            var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{ .closed_numeric_loops = true });
            defer generated.deinit();
            return generated.toText(std.testing.allocator);
        }
    }.run;
    const eligible = [_][]const u8{
        "return function(sum, pieces, cb) local i=1; while i<=#pieces do " ++
            "local width=#pieces[i]; sum=sum+width; cb(i); i=i+1 end; return sum+sum+sum end",
        "return function(sum,n) for i=1,n do sum=sum+i end; return sum+sum+sum end",
        "return function(i,n,t) while i<n do i=i+1; use(t[i],t[i+1]) end; return i end",
        "return function(x) repeat x=x+1 until x>10; return x+x end",
    };
    for (eligible) |source| {
        const ir = try compile(source);
        defer std.testing.allocator.free(ir);
        try std.testing.expect(std.mem.indexOf(u8, ir, "closed_numeric_loop_fast") != null);
        try std.testing.expect(std.mem.indexOf(u8, ir, "closed_numeric_loop_generic") != null);
        try std.testing.expect(std.mem.indexOf(u8, ir, " fadd ") != null);
        try std.testing.expect(std.mem.indexOf(u8, ir, "@dict_lua_binary(") != null);
    }
    const rejected = [_][]const u8{
        "return function(x,n) while n>0 do x=other(); n=n-1 end; return x+x+x end",
        "return function(x,n) while n>0 do if flag then x='bad' else x=x+1 end; n=n-1 end; return x+x+x end",
        "return function(x,n) local f=function() x=other() end; while n>0 do x=x+1; f(); n=n-1 end; return x+x+x end",
        "return function(x,n) while n>0 do local x=3; use(x+x+x); n=n-1 end; return x end",
        "return function(x,n,t) while n>0 do local width=#t; width=other(); x=x+width; n=n-1 end; return x+x+x end",
        "return function(x,n) while n>0 do local f=function() return 1 end; x=x+f(); n=n-1 end; return x+x+x end",
    };
    for (rejected) |source| {
        const ir = try compile(source);
        defer std.testing.allocator.free(ir);
        try std.testing.expect(std.mem.indexOf(u8, ir, "closed_numeric_loop_fast") == null);
    }
}

test "optimized field reads snapshot imported positive hits before later effects" {
    const source = "return function(t, callback) local value=t.x; callback(t); return value,t.x end";
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    for ([_]bool{ false, true }) |enabled| {
        var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{ .inline_field_hits = enabled });
        defer generated.deinit();
        const ir = try generated.toText(std.testing.allocator);
        defer std.testing.allocator.free(ir);
        try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_get_struct_field(") != null);
        try std.testing.expect(std.mem.indexOf(u8, ir, "call ptr @dict_lua_value_field_hit(") == null);
    }
}

test "deferred numeric joins keep chained arithmetic unboxed and promote numeric fallbacks" {
    const compile = struct {
        fn run(source: []const u8, enabled: bool) ![]u8 {
            var chunk = try llvm_parser.parse(std.testing.allocator, source);
            defer chunk.deinit();
            var globals = try llvm_analysis.Globals.init(std.testing.allocator);
            defer globals.deinit();
            var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
            defer module.deinit();
            var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{ .deferred_numeric_ssa = enabled });
            defer generated.deinit();
            try generated.module.verify(std.testing.allocator);
            return generated.toText(std.testing.allocator);
        }
    }.run;
    const source = "return function(a,b) return (a+b)*(a-b) end";
    const baseline = try compile(source, false);
    defer std.testing.allocator.free(baseline);
    try std.testing.expect(std.mem.indexOf(u8, baseline, "deferred_number_fast") == null);
    const ir = try compile(source, true);
    defer std.testing.allocator.free(ir);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, ir, "call i32 @dict_lua_binary("));
    const fast = std.mem.lastIndexOf(u8, ir, "\ndeferred_number_fast") orelse return error.MissingDeferredFast;
    const end = std.mem.indexOfPos(u8, ir, fast + 1, "\ndeferred_number_fallback") orelse return error.MissingDeferredFallback;
    const body = ir[fast..end];
    // The final multiplication consumes scalar results of both earlier sums;
    // no Value materialization, tag reload or generic operation occurs here.
    try std.testing.expect(std.mem.indexOf(u8, body, "fmul double") != null);
    for ([_][]const u8{ "@dict_lua_value_number(", "@dict_lua_value_copy(", "@dict_lua_value_is_number(", "@dict_lua_value_number_unchecked(", "@dict_lua_binary(" }) |helper|
        try std.testing.expect(std.mem.indexOf(u8, body, helper) == null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "deferred_number_promote") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "store double 0.000000e+00") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "deferred_box_number") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "deferred_box_generic") != null);

    const escaping_sources = [_][]const u8{
        "return function(a,b) local v=a+b; return v==nil,v~=nil,not v,v and 5,v or 6 end",
        "return function(a,b,t,f) local v=a+b; t.x=v; t[v]=v; return f(v),v end",
        "return function(a,b) local v=a+b; local capture=function() return v end; v=v*2; return capture() end",
        "return function(a,b) local v; v=a+b; v=v*2; return v end",
        "return function(a,b) return (a+b).x,-(a+b),#(a+b) end",
        "return function(a,b) return (a+b)<(a-b),(a+b)==false end",
        "return function(a,b) return tostring(a+b)..'x' end",
        "return function(a,b) local v=a+b; return function() return v end end",
    };
    for (escaping_sources) |text| {
        const checked = try compile(text, true);
        defer std.testing.allocator.free(checked);
        try std.testing.expect(std.mem.indexOf(u8, checked, "deferred_number_fast") != null);
        try std.testing.expect(std.mem.indexOf(u8, checked, "deferred_box_generic") != null);
    }
}

test "reviewed guarded methods admit bounded one-argument demanded-result entries" {
    const source =
        \\local offset = 2
        \\local object = {}
        \\function object.consume(x, missing)
        \\  if missing ~= nil then error("missing argument changed") end
        \\  return x.value + offset, x.value + offset + 1
        \\end
        \\function object.early(self)
        \\  local consume = self.consume
        \\  local one = consume(self)
        \\  return one
        \\end
        \\function object.walk(self)
        \\  local consume = self.consume
        \\  local one
        \\  for i = 1, 1 do
        \\    one = consume(self)
        \\    consume(self)
        \\  end
        \\  return one
        \\end
        \\return object
    ;
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    const target = module.functions.items[1];
    const candidates = [_]llvm_emitter.MethodCandidate{.{
        .name = "consume",
        .function_id = target.id,
        .module_id = 0,
        .capture_count = @intCast(target.upvalues.len),
    }};
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{
        .method_candidates = &candidates,
        .current_module_id = 0,
        .demanded_entries = true,
    });
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);
    for (0..2) |count| {
        const definition = try std.fmt.allocPrint(std.testing.allocator, "define internal %FunctionResult @lua_demand_{d}_a1_r{d}(", .{ target.id, count });
        defer std.testing.allocator.free(definition);
        const start = std.mem.indexOf(u8, ir, definition) orelse return error.MissingDemandedEntry;
        const end = std.mem.indexOfPos(u8, ir, start, "\n}") orelse return error.UnterminatedDemandedEntry;
        const first_site = (@as(u64, target.id) << 32) | (@as(u64, count + 1) << 30);
        const site_argument = try std.fmt.allocPrint(std.testing.allocator, "i64 {d}, ptr", .{first_site});
        defer std.testing.allocator.free(site_argument);
        try std.testing.expect(std.mem.indexOf(u8, ir[start..end], site_argument) != null);
    }
    const public_definition = try std.fmt.allocPrint(std.testing.allocator, "define %FunctionResult @lua_f_{d}(", .{target.id});
    defer std.testing.allocator.free(public_definition);
    const public_start = std.mem.indexOf(u8, ir, public_definition) orelse return error.MissingPublicEntry;
    const public_end = std.mem.indexOfPos(u8, ir, public_start, "\n}") orelse return error.UnterminatedPublicEntry;
    const public_site = try std.fmt.allocPrint(std.testing.allocator, "i64 {d}, ptr", .{@as(u64, target.id) << 32});
    defer std.testing.allocator.free(public_site);
    try std.testing.expect(std.mem.indexOf(u8, ir[public_start..public_end], public_site) != null);
    const early_definition = "define %FunctionResult @lua_f_2(";
    const early_start = std.mem.indexOf(u8, ir, early_definition) orelse return error.MissingEarlyCaller;
    const early_end = std.mem.indexOfPos(u8, ir, early_start, "\n}") orelse return error.UnterminatedEarlyCaller;
    try std.testing.expect(std.mem.indexOf(u8, ir[early_start..early_end], "@lua_demand_") == null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "alwaysinline") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i8 @dict_lua_value_is_function_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call ptr @dict_lua_value_function_captures") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_call_fixed(") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_call_discard(") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_enter_local_static_call(") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call void @dict_lua_leave_local_static_call(") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "i64 1, i64 1)") != null);
}

test "guarded native find retains scalar positions through captured aliases" {
    const compile = struct {
        fn run(source: []const u8, enabled: bool) ![]u8 {
            var chunk = try llvm_parser.parse(std.testing.allocator, source);
            defer chunk.deinit();
            var globals = try llvm_analysis.Globals.init(std.testing.allocator);
            defer globals.deinit();
            var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
            defer module.deinit();
            var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{ .native_find_three = enabled });
            defer generated.deinit();
            return generated.toText(std.testing.allocator);
        }
    }.run;
    const sources = [_][]const u8{
        "local find=string.find; return function(text, head) local a,b,c; " ++
            "a,b,c=find(text,'(.)',head); if not a then c,a='',#text+1; b=a-1 end; return b-a+head,c end",
        "local find=string.find; return function() return function(text,head) " ++
            "local a,b,c=find(text,'(.)',head); return a,b,c end end",
        "return function(text,head) local a,b,c=string.find(text,'(.)',head); return a,b,c end",
        "local find=string.find; return function(text,head) find=other; " ++
            "local a,b,c=find(text,'(.)',head); return a,b,c end",
    };
    for (sources) |source| {
        const ir = try compile(source, true);
        defer std.testing.allocator.free(ir);
        try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_string_find_three(") != null);
        try std.testing.expect(std.mem.indexOf(u8, ir, "native_find_three_fallback") != null);
        try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_call_fixed(") != null);
        try std.testing.expect(std.mem.indexOf(u8, ir, "load double") != null);
    }
    const continuation = try compile(sources[0], true);
    defer std.testing.allocator.free(continuation);
    try std.testing.expect(std.mem.indexOf(u8, continuation, "numeric_continuation_fast") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, continuation, "call i32 @dict_lua_string_find_three("));
    const disabled = try compile(sources[0], false);
    defer std.testing.allocator.free(disabled);
    try std.testing.expect(std.mem.indexOf(u8, disabled, "call i32 @dict_lua_string_find_three(") == null);
    for ([_][]const u8{
        "return function(find,text,head) local a,b,c=find(text,'(.)',head); return a,b,c end",
        "local find=string.find; local a,b,c=find('abc','(.)',tail()); return a,b,c",
        "local find=string.find; local a,b=find('abc','(.)',1); return a,b",
        "local find=string.find; local a,b,c=find('abc','(.)',1,true); return a,b,c",
    }) |source| {
        const ir = try compile(source, true);
        defer std.testing.allocator.free(ir);
        try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @dict_lua_string_find_three(") == null);
    }
}

test "structural callable table entries use bounded fixed pointer ABI" {
    const source =
        \\local meta = {}
        \\do
        \\  function meta.__call(receiver, arg, key)
        \\    return (receiver[key] or receiver[false])(arg, key)
        \\  end
        \\end
        \\local export = {}
        \\function export.apply(holder, arg, key)
        \\  local result = holder.handler(arg, key)
        \\  local second = holder.handler(arg, key)
        \\  return result, second
        \\end
        \\return export
    ;
    var chunk = try llvm_parser.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try llvm_analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try llvm_analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{
        .fixed_callable_entries = true,
    });
    defer generated.deinit();
    const ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "dict_lua_guard_table_call.") == null);
    const start = std.mem.indexOf(u8, ir, "define internal i32 @lua_fixed_callable_") orelse return error.MissingFixedCallableEntry;
    const end = std.mem.indexOfPos(u8, ir, start, "\n}") orelse return error.UnterminatedFixedCallableEntry;
    const body = ir[start..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "@dict_lua_arg_ptr") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "@dict_lua_return_call") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "@dict_lua_call_fixed") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "@dict_lua_get_struct_index") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i8 @dict_lua_guard_table_call") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "@dict_lua_enter_local_static_call") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "@dict_lua_leave_local_static_call") != null);

    var disabled = try llvm_emitter.generate(std.testing.allocator, &globals, &module, .{});
    defer disabled.deinit();
    const off_ir = try disabled.toText(std.testing.allocator);
    defer std.testing.allocator.free(off_ir);
    try std.testing.expect(std.mem.indexOf(u8, off_ir, "lua_fixed_callable_") == null);
}
