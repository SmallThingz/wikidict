const refs = @import("vm_ref.zig");
fn relocateReference(ctx: anytype, value: u32) !u32 {
    return switch (refs.tag(value)) {
        .constant => try refs.constant(try std.math.add(u32, refs.index(value), ctx.constant_base)),
        .string => try refs.remapString(ctx.string_map, value),
        else => value,
    };
}
const std = @import("std");
const ir = @import("vm_ir.zig");
const shape_key = @import("vm_shape_key.zig");
const lua = @import("root.zig");
const exec = @import("vm_exec.zig");

pub const Input = struct {
    title: []const u8,
    program: *const ir.Program,
};

pub const Module = struct {
    root_function: u32,
    function_base: u32,
    function_count: u32,
    constant_base: u32,
    constant_count: u32,
};

pub const Image = struct {
    allocator: std.mem.Allocator,
    program: ir.Program,
    modules: std.ArrayList(Module) = .empty,
    input_finalized: ?bool = null,
    owned_strings: std.ArrayList([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Image {
        return .{ .allocator = allocator, .program = .{ .allocator = allocator } };
    }

    pub fn deinit(self: *Image) void {
        self.modules.deinit(self.allocator);
        self.program.deinit();
        for (self.owned_strings.items) |text| self.allocator.free(text);
        self.owned_strings.deinit(self.allocator);
    }

    pub fn appendModule(self: *Image, source: *const ir.Program) !u32 {
        if (source.global_shape != null) return error.AlreadyLinkedProgram;
        if (source.module_roots.items.len != 0) return error.AlreadyLinkedProgram;
        // Mixing physical registers with semantic registers silently disables
        // later SSA passes. Reject the mismatch before modifying the image.
        if (self.input_finalized) |finalized| {
            if (finalized != source.references_lowered) return error.MixedCompilerPhases;
        }
        self.input_finalized = source.references_lowered;
        self.program.references_lowered = source.references_lowered;

        const string_map = try self.allocator.alloc(u32, source.strings.items.len);
        defer self.allocator.free(string_map);
        for (source.strings.items, 0..) |text, index| {
            string_map[index] = try intern(self, text);
        }

        const constant_base: u32 = @intCast(self.program.constants.items.len);
        const entry_base: u32 = @intCast(self.program.const_entries.items.len);
        const function_base: u32 = @intCast(self.program.functions.items.len);
        const shape_base: u32 = @intCast(self.program.shapes.items.len);
        for (source.shapes.items) |original| {
            var shape = ir.Shape{ .field_count = original.field_count, .choice_count = original.choice_count, .open = original.open };
            errdefer shape.deinit(self.allocator);
            for (original.field_keys.items) |key| {
                if (shape_key.stringId(key)) |sid| {
                    if (sid >= string_map.len) return error.BadStringReference;
                    try shape.field_keys.append(self.allocator, try shape_key.string(string_map[sid]));
                } else {
                    try shape.field_keys.append(self.allocator, key);
                }
            }
            try self.program.shapes.append(self.allocator, shape);
        }
        const module_index: u32 = @intCast(self.modules.items.len);
        for (source.constants.items) |node| {
            try self.program.constants.append(self.allocator, try remapConst(node, string_map, entry_base));
        }
        for (source.const_entries.items) |entry| {
            if ((entry.key != ir.implicit_list_key and entry.key >= source.constants.items.len) or entry.value >= source.constants.items.len)
                return error.BadConstantReference;
            try self.program.const_entries.append(self.allocator, .{
                .key = if (entry.key == ir.implicit_list_key) ir.implicit_list_key else constant_base + entry.key,
                .value = constant_base + entry.value,
            });
        }

        for (source.functions.items) |maybe_function| {
            if (maybe_function) |function| {
                try self.program.functions.append(
                    self.allocator,
                    try cloneFunction(self.allocator, &function, string_map, function_base, constant_base, shape_base),
                );
                try self.program.function_modules.append(self.allocator, module_index);
            } else {
                return error.IncompleteProgram;
            }
        }

        const module = Module{
            .root_function = function_base + source.root_function,
            .function_base = function_base,
            .function_count = @intCast(source.functions.items.len),
            .constant_base = constant_base,
            .constant_count = @intCast(source.constants.items.len),
        };
        try self.modules.append(self.allocator, module);
        try self.program.module_roots.append(self.allocator, module.root_function);
        if (module_index == 0) self.program.root_function = module.root_function;
        return module_index;
    }
};

fn intern(image: *Image, text: []const u8) !u32 {
    if (image.program.interned_strings.get(text)) |id| return id;
    const owned = try image.allocator.dupe(u8, text);
    errdefer image.allocator.free(owned);
    const id: u32 = @intCast(image.program.strings.items.len);
    try image.program.strings.append(image.allocator, owned);
    errdefer _ = image.program.strings.pop();
    try image.owned_strings.append(image.allocator, owned);
    errdefer _ = image.owned_strings.pop();
    try image.program.interned_strings.put(image.allocator, owned, id);
    return id;
}

fn remapConst(node: ir.ConstNode, string_map: []const u32, entry_base: u32) !ir.ConstNode {
    return switch (node) {
        .nil => .nil,
        .boolean => |value| .{ .boolean = value },
        .number => |sid| if (sid < string_map.len) .{ .number = string_map[sid] } else error.BadStringReference,
        .string => |sid| if (sid < string_map.len) .{ .string = string_map[sid] } else error.BadStringReference,
        .integer => |value| .{ .integer = value },
        .number_bits => |bits| .{ .number_bits = bits },
        .table => |table| .{ .table = .{
            .first = entry_base + table.first,
            .count = table.count,
        } },
    };
}

fn cloneFunction(
    allocator: std.mem.Allocator,
    source: *const ir.Function,
    string_map: []const u32,
    function_base: u32,
    constant_base: u32,
    shape_base: u32,
) !ir.Function {
    var out = ir.Function{
        .source_start = source.source_start,
        .source_end = source.source_end,
        .param_count = source.param_count,
        .is_vararg = source.is_vararg,
        .reg_count = source.reg_count,
    };
    errdefer out.deinit(allocator);
    try out.upvalues.appendSlice(allocator, source.upvalues.items);
    try out.operands.appendSlice(allocator, source.operands.items);
    try out.insts.appendSlice(allocator, source.insts.items);
    try refs.visit(&out, .{ .constant_base = constant_base, .string_map = string_map }, relocateReference);
    for (out.insts.items) |*inst| switch (inst.op) {
        .load_number, .load_string, .get_global, .set_global, .get_field, .set_field => {
            if (inst.aux >= string_map.len) return error.BadStringReference;
            inst.aux = string_map[inst.aux];
        },
        .method_call_field, .method_call_field_vararg => {
            if (inst.a >= string_map.len) return error.BadStringReference;
            inst.a = string_map[inst.a];
        },
        .load_const => inst.aux += constant_base,
        .closure, .load_function, .register_function => inst.aux += function_base,
        .direct_call, .direct_call_vararg, .call_scoped, .call_scoped_vararg, .call_local, .call_local_vararg => inst.a += function_base,
        .new_table_shape => inst.aux += shape_base,
        else => {},
    };
    return out;
}

pub fn link(allocator: std.mem.Allocator, inputs: []const Input) !Image {
    var image = Image.init(allocator);
    errdefer image.deinit();
    for (inputs) |input| _ = try image.appendModule(input.program);
    return image;
}

test "linked image shares strings and executes independent module roots" {
    var chunk_a = try lua.parse(std.testing.allocator, "local s='same'; return s .. '1'");
    defer chunk_a.deinit();
    var chunk_b = try lua.parse(std.testing.allocator, "local s='same'; return s .. '2'");
    defer chunk_b.deinit();
    var program_a = try ir.lowerChunk(std.testing.allocator, &chunk_a);
    defer program_a.deinit();
    var program_b = try ir.lowerChunk(std.testing.allocator, &chunk_b);
    defer program_b.deinit();
    const separate_strings = program_a.strings.items.len + program_b.strings.items.len;

    var image = Image.init(std.testing.allocator);
    defer image.deinit();
    _ = try image.appendModule(&program_a);
    _ = try image.appendModule(&program_b);
    try std.testing.expect(image.program.strings.items.len < separate_strings + 2);
    try std.testing.expectEqual(@as(u32, 0), image.modules.items[0].function_base);
    try std.testing.expectEqual(@as(u32, @intCast(program_a.functions.items.len)), image.modules.items[1].function_base);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const a = try vm.execute(&image.program, image.modules.items[0].root_function, &.{}, &.{});
    defer exec.Vm.freeResults(a);
    const b = try vm.execute(&image.program, image.modules.items[1].root_function, &.{}, &.{});
    defer exec.Vm.freeResults(b);
    try std.testing.expectEqualStrings("same1", a[0].string);
    try std.testing.expectEqualStrings("same2", b[0].string);
}

test "streaming linker rebases constant references" {
    var chunk_a = try lua.parse(std.testing.allocator, "return { first = 'a' }");
    defer chunk_a.deinit();
    var chunk_b = try lua.parse(std.testing.allocator, "return { second = 'b' }");
    defer chunk_b.deinit();
    var program_a = try ir.lowerChunk(std.testing.allocator, &chunk_a);
    defer program_a.deinit();
    var program_b = try ir.lowerChunk(std.testing.allocator, &chunk_b);
    defer program_b.deinit();

    var image = Image.init(std.testing.allocator);
    defer image.deinit();
    _ = try image.appendModule(&program_a);
    _ = try image.appendModule(&program_b);
    try std.testing.expect(image.modules.items[1].constant_base != 0);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const out = try vm.execute(&image.program, image.modules.items[1].root_function, &.{}, &.{});
    defer exec.Vm.freeResults(out);
    const table = out[0].table;
    const value = table.rawGet(.{ .string = "second" }) orelse return error.MissingValue;
    try std.testing.expectEqualStrings("b", value.string);
}

test "linker rebases anonymous shape descriptors and numeric roots" {
    const shape_pass = @import("vm_shape_opt.zig");
    const codec = @import("vm_codec.zig");
    var a_chunk = try lua.parse(std.testing.allocator, "local t={}; t.first=2; return t.first");
    defer a_chunk.deinit();
    var b_chunk = try lua.parse(std.testing.allocator, "local t={}; t.second=3; t.third=4; return t.second+t.third");
    defer b_chunk.deinit();
    var p = try ir.lowerChunk(std.testing.allocator, &a_chunk);
    defer p.deinit();
    var q = try ir.lowerChunk(std.testing.allocator, &b_chunk);
    defer q.deinit();
    _ = try shape_pass.run(std.testing.allocator, &p);
    _ = try shape_pass.run(std.testing.allocator, &q);
    var image = try link(std.testing.allocator, &.{ .{ .title = "Module:DoNotSerializeA", .program = &p }, .{ .title = "Module:DoNotSerializeB", .program = &q } });
    defer image.deinit();
    const blob = try codec.serialize(std.testing.allocator, &image.program);
    defer std.testing.allocator.free(blob);
    try std.testing.expect(std.mem.indexOf(u8, blob, "DoNotSerialize") == null);
    var restored = try codec.deserialize(std.testing.allocator, blob);
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 2), restored.module_roots.items.len);
    try std.testing.expectEqual(restored.functions.items.len, restored.function_modules.items.len);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const values = try vm.execute(&restored, restored.module_roots.items[1], &.{}, &.{});
    defer exec.Vm.freeResults(values);
    try std.testing.expectEqual(@as(f64, 7), values[0].number);
}

test "semantic modules remain optimizable after linking before final lowering" {
    const a = std.testing.allocator;
    const opt = @import("vm_optimize.zig");
    var image = Image.init(a);
    defer image.deinit();
    for ([_][]const u8{ "local function f(x)return x+1 end;return f(6)", "local function f(x)return function()return x end end;return f(8)()" }) |source| {
        var chunk = try lua.parse(a, source);
        defer chunk.deinit();
        var p = try ir.lowerChunk(a, &chunk);
        defer p.deinit();
        _ = try opt.runSemantics(a, &p);
        try std.testing.expect(!p.references_lowered);
        _ = try image.appendModule(&p);
    }
    _ = try opt.runSemantics(a, &image.program);
    try std.testing.expectEqual(@as(usize, 2), image.program.module_roots.items.len);
    _ = try opt.finalize(a, &image.program);
    try std.testing.expect(image.program.references_lowered);
    try std.testing.expectError(error.AlreadyFinalized, opt.runSemantics(a, &image.program));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    for (image.program.module_roots.items, [_]f64{ 7, 8 }) |root, wanted| {
        const out = try vm.execute(&image.program, root, &.{}, &.{});
        defer exec.Vm.freeResults(out);
        try std.testing.expectEqual(wanted, out[0].number);
    }
}
test "linking rejects mixed compiler phases without modifying the image" {
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, "return 7");
    defer chunk.deinit();
    var p = try ir.lowerChunk(a, &chunk);
    defer p.deinit();
    var image = Image.init(a);
    defer image.deinit();
    _ = try image.appendModule(&p);
    const functions = image.program.functions.items.len;
    const strings = image.program.strings.items.len;
    _ = try @import("vm_optimize.zig").run(a, &p);
    try std.testing.expectError(error.MixedCompilerPhases, image.appendModule(&p));
    try std.testing.expectEqual(functions, image.program.functions.items.len);
    try std.testing.expectEqual(strings, image.program.strings.items.len);
    try std.testing.expectEqual(@as(usize, 1), image.modules.items.len);
}

test "linker preserves numeric shape keys across string rebasing" {
    const a = std.testing.allocator;
    const shape_pass = @import("vm_shape_opt.zig");
    var chunk = try lua.parse(a, "local t={};t[1]=4;t[2]=5;return t[1],t[2],#t");
    defer chunk.deinit();
    var p = try ir.lowerChunk(a, &chunk);
    defer p.deinit();
    _ = try shape_pass.run(a, &p);
    var image = Image.init(a);
    defer image.deinit();
    const module = try image.appendModule(&p);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const out = try vm.execute(&image.program, image.modules.items[module].root_function, &.{}, &.{});
    defer exec.Vm.freeResults(out);
    try std.testing.expectEqual(@as(f64, 4), out[0].number);
    try std.testing.expectEqual(@as(f64, 5), out[1].number);
    try std.testing.expectEqual(@as(f64, 2), out[2].number);
}
