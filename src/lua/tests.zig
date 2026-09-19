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
    _ = @import("program_metadata.zig");
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
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, generated_source, " = call ptr @dict_lua_global_ptr("));
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

    const rebound = try compile("require=function() return 1 end; return require('Module:Alias')", facts);
    defer std.testing.allocator.free(rebound);
    try std.testing.expect(std.mem.indexOf(u8, rebound, "call i32 @dict_lua_require_module_id") == null);

    const escaped = try compile("local globals=_G; local x=require('Module:Alias'); return x", facts);
    defer std.testing.allocator.free(escaped);
    try std.testing.expect(std.mem.indexOf(u8, escaped, "call i32 @dict_lua_require_module_id") == null);
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
    try std.testing.expect(std.mem.indexOf(u8, stable, "call ptr @dict_lua_global_ptr") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, generated_source, "call i32 @dict_lua_get_field") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, ir, "direct_export") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "dynamic_export") != null);
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
    const start = std.mem.indexOf(u8, ir, "pristine_export_multi:") orelse return error.MissingPristineExportBlock;
    const rest = ir[start..];
    const end = std.mem.indexOf(u8, rest, "pristine_export_multi_fallback:") orelse rest.len;
    const block = rest[0..end];
    try std.testing.expect(std.mem.indexOf(u8, block, "@dict_lua_get_field") == null);
    try std.testing.expect(std.mem.indexOf(u8, block, "@dict_lua_value_is_function_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call %FunctionResult @lua_f_99") != null);
    const fallback_start = std.mem.indexOf(u8, ir, "export_callee_fallback:") orelse return error.MissingExportFallbackBlock;
    try std.testing.expect(std.mem.indexOf(u8, ir[fallback_start..], "@dict_lua_get_field") != null);
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

    var dynamic_chunk = try llvm_parser.parse(
        std.testing.allocator,
        "local name='Module:Dependency'; local dep=require(name); return dep",
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
