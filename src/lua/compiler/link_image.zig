const refs = @import("ref.zig");
fn relocateReference(ctx: anytype, value: u32) !u32 {
    return switch (refs.tag(value)) {
        .constant => try refs.constant(try std.math.add(u32, refs.index(value), ctx.constant_base)),
        .string => try refs.remapString(ctx.string_map, value),
        else => value,
    };
}
const std = @import("std");
const ir = @import("ir.zig");
const shape_key = @import("../abi/shape_key.zig");

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
            try self.program.constants.append(self.allocator, try remapConst(node, string_map, entry_base, shape_base));
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

fn remapConst(node: ir.ConstNode, string_map: []const u32, entry_base: u32, shape_base: u32) !ir.ConstNode {
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
            .shape = if (table.shape == ir.no_shape) ir.no_shape else shape_base + table.shape,
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
        .aot_dynamic_callable = source.aot_dynamic_callable,
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
