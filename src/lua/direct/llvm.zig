const std = @import("std");

// Minimal LLVM C-API surface used by the build-only producer. Keep emitted
// modules free of producer-version-specific intrinsics/attributes.

pub const ContextRef = *anyopaque;
pub const ModuleRef = *anyopaque;
pub const TypeRef = *anyopaque;
pub const ValueRef = *anyopaque;
pub const BasicBlockRef = *anyopaque;
pub const BuilderRef = *anyopaque;
pub const AttributeRef = *anyopaque;

pub const Linkage = enum(c_uint) {
    external = 0,
    available_externally = 1,
    link_once_any = 2,
    link_once_odr = 3,
    link_once_odr_auto_hide = 4,
    weak_any = 5,
    weak_odr = 6,
    appending = 7,
    internal = 8,
    private = 9,
    dll_import = 10,
    dll_export = 11,
    external_weak = 12,
    ghost = 13,
    common = 14,
    linker_private = 15,
    linker_private_weak = 16,
};

pub const IntPredicate = enum(c_uint) {
    eq = 32,
    ne = 33,
    ugt = 34,
    uge = 35,
    ult = 36,
    ule = 37,
    sgt = 38,
    sge = 39,
    slt = 40,
    sle = 41,
};

pub const RealPredicate = enum(c_uint) {
    false_ = 0,
    oeq = 1,
    ogt = 2,
    oge = 3,
    olt = 4,
    ole = 5,
    one = 6,
    ord = 7,
    uno = 8,
    ueq = 9,
    ugt = 10,
    uge = 11,
    ult = 12,
    ule = 13,
    une = 14,
    true_ = 15,
};

extern fn LLVMContextCreate() ?ContextRef;
extern fn LLVMContextDispose(C: ContextRef) void;
extern fn LLVMModuleCreateWithNameInContext(ModuleID: [*:0]const u8, C: ContextRef) ?ModuleRef;
extern fn LLVMDisposeModule(M: ModuleRef) void;
extern fn LLVMPrintModuleToString(M: ModuleRef) ?[*:0]u8;
extern fn LLVMDisposeMessage(Message: [*:0]u8) void;
extern fn LLVMVerifyModule(M: ModuleRef, Action: c_int, OutMessage: *?[*:0]u8) c_int;

extern fn LLVMVoidTypeInContext(C: ContextRef) ?TypeRef;
extern fn LLVMInt1TypeInContext(C: ContextRef) ?TypeRef;
extern fn LLVMInt8TypeInContext(C: ContextRef) ?TypeRef;
extern fn LLVMInt32TypeInContext(C: ContextRef) ?TypeRef;
extern fn LLVMInt64TypeInContext(C: ContextRef) ?TypeRef;
extern fn LLVMDoubleTypeInContext(C: ContextRef) ?TypeRef;
extern fn LLVMPointerTypeInContext(C: ContextRef, AddressSpace: c_uint) ?TypeRef;
extern fn LLVMArrayType(ElementType: TypeRef, ElementCount: c_uint) ?TypeRef;
extern fn LLVMStructCreateNamed(C: ContextRef, Name: [*:0]const u8) ?TypeRef;
extern fn LLVMStructSetBody(StructTy: TypeRef, ElementTypes: [*]TypeRef, ElementCount: c_uint, Packed: c_int) void;
extern fn LLVMFunctionType(ReturnType: TypeRef, ParamTypes: ?[*]TypeRef, ParamCount: c_uint, IsVarArg: c_int) ?TypeRef;

extern fn LLVMConstInt(IntTy: TypeRef, N: c_ulonglong, SignExtend: c_int) ?ValueRef;
extern fn LLVMConstReal(RealTy: TypeRef, N: f64) ?ValueRef;
extern fn LLVMConstNull(Ty: TypeRef) ?ValueRef;
extern fn LLVMConstStringInContext(C: ContextRef, Str: [*]const u8, Length: c_uint, DontNullTerminate: c_int) ?ValueRef;
extern fn LLVMConstArray(ElementTy: TypeRef, ConstantVals: [*]ValueRef, Length: c_uint) ?ValueRef;

extern fn LLVMAddGlobal(M: ModuleRef, Ty: TypeRef, Name: [*:0]const u8) ?ValueRef;
extern fn LLVMSetInitializer(GlobalVar: ValueRef, ConstantVal: ValueRef) void;
extern fn LLVMSetGlobalConstant(GlobalVar: ValueRef, IsConstant: c_int) void;
extern fn LLVMSetLinkage(Global: ValueRef, Linkage: Linkage) void;
extern fn LLVMSetAlignment(V: ValueRef, Bytes: c_uint) void;
extern fn LLVMAddFunction(M: ModuleRef, Name: [*:0]const u8, FunctionTy: TypeRef) ?ValueRef;
extern fn LLVMGlobalGetValueType(Global: ValueRef) ?TypeRef;
extern fn LLVMGetParam(Fn: ValueRef, Index: c_uint) ?ValueRef;
extern fn LLVMSetValueName2(Val: ValueRef, Name: [*]const u8, NameLen: usize) void;
extern fn LLVMGetEnumAttributeKindForName(Name: [*]const u8, SLen: usize) c_uint;
extern fn LLVMCreateEnumAttribute(C: ContextRef, KindID: c_uint, Val: u64) ?AttributeRef;
extern fn LLVMAddAttributeAtIndex(Fn: ValueRef, Idx: c_uint, A: AttributeRef) void;

extern fn LLVMAppendBasicBlockInContext(C: ContextRef, Fn: ValueRef, Name: [*:0]const u8) ?BasicBlockRef;
extern fn LLVMCreateBuilderInContext(C: ContextRef) ?BuilderRef;
extern fn LLVMDisposeBuilder(Builder: BuilderRef) void;
extern fn LLVMPositionBuilderAtEnd(Builder: BuilderRef, Block: BasicBlockRef) void;

extern fn LLVMBuildAlloca(B: BuilderRef, Ty: TypeRef, Name: [*:0]const u8) ?ValueRef;
extern fn LLVMBuildGEP2(B: BuilderRef, Ty: TypeRef, Pointer: ValueRef, Indices: [*]ValueRef, NumIndices: c_uint, Name: [*:0]const u8) ?ValueRef;
extern fn LLVMBuildLoad2(B: BuilderRef, Ty: TypeRef, PointerVal: ValueRef, Name: [*:0]const u8) ?ValueRef;
extern fn LLVMBuildStore(B: BuilderRef, Val: ValueRef, Ptr: ValueRef) ?ValueRef;
extern fn LLVMBuildCall2(B: BuilderRef, Ty: TypeRef, Fn: ValueRef, Args: ?[*]ValueRef, NumArgs: c_uint, Name: [*:0]const u8) ?ValueRef;
extern fn LLVMBuildICmp(B: BuilderRef, Op: IntPredicate, LHS: ValueRef, RHS: ValueRef, Name: [*:0]const u8) ?ValueRef;
extern fn LLVMBuildFCmp(B: BuilderRef, Op: RealPredicate, LHS: ValueRef, RHS: ValueRef, Name: [*:0]const u8) ?ValueRef;
extern fn LLVMBuildBr(B: BuilderRef, Dest: BasicBlockRef) ?ValueRef;
extern fn LLVMBuildCondBr(B: BuilderRef, If: ValueRef, Then: BasicBlockRef, Else: BasicBlockRef) ?ValueRef;
extern fn LLVMBuildRet(B: BuilderRef, V: ValueRef) ?ValueRef;
extern fn LLVMBuildZExt(B: BuilderRef, Val: ValueRef, DestTy: TypeRef, Name: [*:0]const u8) ?ValueRef;
extern fn LLVMBuildFAdd(B: BuilderRef, LHS: ValueRef, RHS: ValueRef, Name: [*:0]const u8) ?ValueRef;
extern fn LLVMBuildFSub(B: BuilderRef, LHS: ValueRef, RHS: ValueRef, Name: [*:0]const u8) ?ValueRef;
extern fn LLVMBuildFMul(B: BuilderRef, LHS: ValueRef, RHS: ValueRef, Name: [*:0]const u8) ?ValueRef;
extern fn LLVMBuildFDiv(B: BuilderRef, LHS: ValueRef, RHS: ValueRef, Name: [*:0]const u8) ?ValueRef;
extern fn LLVMBuildFNeg(B: BuilderRef, V: ValueRef, Name: [*:0]const u8) ?ValueRef;
extern fn LLVMBuildNot(B: BuilderRef, V: ValueRef, Name: [*:0]const u8) ?ValueRef;
extern fn LLVMBuildAdd(B: BuilderRef, LHS: ValueRef, RHS: ValueRef, Name: [*:0]const u8) ?ValueRef;
extern fn LLVMBuildSub(B: BuilderRef, LHS: ValueRef, RHS: ValueRef, Name: [*:0]const u8) ?ValueRef;
extern fn LLVMBuildSelect(B: BuilderRef, If: ValueRef, Then: ValueRef, Else: ValueRef, Name: [*:0]const u8) ?ValueRef;
extern fn LLVMBuildExtractValue(B: BuilderRef, AggVal: ValueRef, Index: c_uint, Name: [*:0]const u8) ?ValueRef;

extern fn LLVMWriteBitcodeToFile(M: ModuleRef, Path: [*:0]const u8) c_int;

fn req(comptime T: type, value: ?T) !T {
    return value orelse error.LlvmApiFailure;
}

pub const Types = struct {
    void: TypeRef,
    i1: TypeRef,
    i8: TypeRef,
    i32: TypeRef,
    i64: TypeRef,
    double: TypeRef,
    ptr: TypeRef,
    value: TypeRef,
    function_result: TypeRef,
    call_result: TypeRef,

    pub fn init(ctx: ContextRef) !Types {
        const void_ty = try req(TypeRef, LLVMVoidTypeInContext(ctx));
        const i1_ty = try req(TypeRef, LLVMInt1TypeInContext(ctx));
        const i8_ty = try req(TypeRef, LLVMInt8TypeInContext(ctx));
        const i32_ty = try req(TypeRef, LLVMInt32TypeInContext(ctx));
        const i64_ty = try req(TypeRef, LLVMInt64TypeInContext(ctx));
        const double_ty = try req(TypeRef, LLVMDoubleTypeInContext(ctx));
        const ptr_ty = try req(TypeRef, LLVMPointerTypeInContext(ctx, 0));
        const value_ty = try req(TypeRef, LLVMArrayType(i8_ty, 32));
        const function_result_ty = try req(TypeRef, LLVMStructCreateNamed(ctx, "FunctionResult"));
        const call_result_ty = try req(TypeRef, LLVMStructCreateNamed(ctx, "CallResult"));
        var fields = [_]TypeRef{ ptr_ty, i64_ty, i32_ty, i32_ty };
        LLVMStructSetBody(function_result_ty, &fields, fields.len, 0);
        LLVMStructSetBody(call_result_ty, &fields, fields.len, 0);
        return .{
            .void = void_ty,
            .i1 = i1_ty,
            .i8 = i8_ty,
            .i32 = i32_ty,
            .i64 = i64_ty,
            .double = double_ty,
            .ptr = ptr_ty,
            .value = value_ty,
            .function_result = function_result_ty,
            .call_result = call_result_ty,
        };
    }
};

pub const Module = struct {
    context: ContextRef,
    ref: ModuleRef,
    types: Types,

    pub fn init(name: [*:0]const u8) !Module {
        const context = try req(ContextRef, LLVMContextCreate());
        errdefer LLVMContextDispose(context);
        const module = try req(ModuleRef, LLVMModuleCreateWithNameInContext(name, context));
        errdefer LLVMDisposeModule(module);
        return .{ .context = context, .ref = module, .types = try Types.init(context) };
    }

    pub fn deinit(self: *Module) void {
        LLVMDisposeModule(self.ref);
        LLVMContextDispose(self.context);
        self.* = undefined;
    }

    pub fn functionType(_: *const Module, return_ty: TypeRef, params: []const TypeRef) !TypeRef {
        return req(TypeRef, LLVMFunctionType(return_ty, if (params.len == 0) null else @constCast(params.ptr), @intCast(params.len), 0));
    }

    pub fn addFunction(self: *const Module, name: []const u8, ty: TypeRef) !ValueRef {
        const z = try std.heap.smp_allocator.dupeZ(u8, name);
        defer std.heap.smp_allocator.free(z);
        return req(ValueRef, LLVMAddFunction(self.ref, z.ptr, ty));
    }

    pub fn addGlobal(self: *const Module, name: []const u8, ty: TypeRef, initializer: ValueRef, linkage: Linkage, alignment: u32) !ValueRef {
        const z = try std.heap.smp_allocator.dupeZ(u8, name);
        defer std.heap.smp_allocator.free(z);
        const value = try req(ValueRef, LLVMAddGlobal(self.ref, ty, z.ptr));
        LLVMSetInitializer(value, initializer);
        LLVMSetGlobalConstant(value, 1);
        LLVMSetLinkage(value, linkage);
        if (alignment != 0) LLVMSetAlignment(value, alignment);
        return value;
    }

    pub fn verify(self: *const Module, allocator: std.mem.Allocator) !void {
        var message: ?[*:0]u8 = null;
        if (LLVMVerifyModule(self.ref, 2, &message) == 0) return;
        if (message) |raw| {
            defer LLVMDisposeMessage(raw);
            const msg = try allocator.dupe(u8, std.mem.span(raw));
            defer allocator.free(msg);
            std.debug.print("LLVM verification failed:\n{s}\n", .{msg});
        }
        return error.InvalidLlvmModule;
    }

    pub fn toText(self: *const Module, allocator: std.mem.Allocator) ![]u8 {
        const raw = LLVMPrintModuleToString(self.ref) orelse return error.LlvmApiFailure;
        defer LLVMDisposeMessage(raw);
        return allocator.dupe(u8, std.mem.span(raw));
    }

    pub fn writeBitcode(self: *const Module, allocator: std.mem.Allocator, path: []const u8) !void {
        const z = try allocator.dupeZ(u8, path);
        defer allocator.free(z);
        if (LLVMWriteBitcodeToFile(self.ref, z.ptr) != 0) return error.BitcodeWriteFailed;
    }
};

pub fn arrayType(element: TypeRef, count: usize) !TypeRef {
    if (count > std.math.maxInt(c_uint)) return error.LlvmArrayTooLarge;
    return req(TypeRef, LLVMArrayType(element, @intCast(count)));
}

pub fn constInt(ty: TypeRef, value: anytype) !ValueRef {
    return req(ValueRef, LLVMConstInt(ty, @intCast(value), 0));
}

pub fn constReal(ty: TypeRef, value: f64) !ValueRef {
    return req(ValueRef, LLVMConstReal(ty, value));
}

pub fn constNull(ty: TypeRef) !ValueRef {
    return req(ValueRef, LLVMConstNull(ty));
}

pub fn constString(ctx: ContextRef, bytes: []const u8) !ValueRef {
    if (bytes.len > std.math.maxInt(c_uint)) return error.LlvmStringTooLarge;
    return req(ValueRef, LLVMConstStringInContext(ctx, bytes.ptr, @intCast(bytes.len), 1));
}

pub fn constArray(element: TypeRef, values: []const ValueRef) !ValueRef {
    if (values.len > std.math.maxInt(c_uint)) return error.LlvmArrayTooLarge;
    return req(ValueRef, LLVMConstArray(element, @constCast(values.ptr), @intCast(values.len)));
}

pub fn globalValueType(value: ValueRef) !TypeRef {
    return req(TypeRef, LLVMGlobalGetValueType(value));
}

pub fn param(function: ValueRef, index: usize) !ValueRef {
    if (index > std.math.maxInt(c_uint)) return error.LlvmParamTooLarge;
    return req(ValueRef, LLVMGetParam(function, @intCast(index)));
}

pub fn setName(value: ValueRef, name: []const u8) void {
    LLVMSetValueName2(value, name.ptr, name.len);
}

pub fn addFunctionEnumAttribute(ctx: ContextRef, function: ValueRef, name: []const u8) !void {
    const kind = LLVMGetEnumAttributeKindForName(name.ptr, name.len);
    if (kind == 0) return error.UnknownLlvmAttribute;
    const attribute = try req(AttributeRef, LLVMCreateEnumAttribute(ctx, kind, 0));
    LLVMAddAttributeAtIndex(function, std.math.maxInt(c_uint), attribute);
}

pub fn appendBlock(ctx: ContextRef, function: ValueRef, name: []const u8) !BasicBlockRef {
    const z = try std.heap.smp_allocator.dupeZ(u8, name);
    defer std.heap.smp_allocator.free(z);
    return req(BasicBlockRef, LLVMAppendBasicBlockInContext(ctx, function, z.ptr));
}

pub fn createBuilder(ctx: ContextRef) !BuilderRef {
    return req(BuilderRef, LLVMCreateBuilderInContext(ctx));
}

pub fn disposeBuilder(builder: BuilderRef) void {
    LLVMDisposeBuilder(builder);
}

pub fn position(builder: BuilderRef, block: BasicBlockRef) void {
    LLVMPositionBuilderAtEnd(builder, block);
}

pub fn alloca(builder: BuilderRef, ty: TypeRef, alignment: u32) !ValueRef {
    const value = try req(ValueRef, LLVMBuildAlloca(builder, ty, ""));
    if (alignment != 0) LLVMSetAlignment(value, alignment);
    return value;
}

pub fn gep(builder: BuilderRef, source_ty: TypeRef, base: ValueRef, indices: []const ValueRef) !ValueRef {
    return req(ValueRef, LLVMBuildGEP2(builder, source_ty, base, @constCast(indices.ptr), @intCast(indices.len), ""));
}

pub fn load(builder: BuilderRef, ty: TypeRef, ptr: ValueRef, alignment: u32) !ValueRef {
    const value = try req(ValueRef, LLVMBuildLoad2(builder, ty, ptr, ""));
    if (alignment != 0) LLVMSetAlignment(value, alignment);
    return value;
}

pub fn store(builder: BuilderRef, value: ValueRef, ptr: ValueRef, alignment: u32) !void {
    const inst = try req(ValueRef, LLVMBuildStore(builder, value, ptr));
    if (alignment != 0) LLVMSetAlignment(inst, alignment);
}

pub fn call(builder: BuilderRef, function: ValueRef, args: []const ValueRef) !ValueRef {
    const ty = try globalValueType(function);
    return req(ValueRef, LLVMBuildCall2(builder, ty, function, if (args.len == 0) null else @constCast(args.ptr), @intCast(args.len), ""));
}

pub fn icmp(builder: BuilderRef, predicate: IntPredicate, lhs: ValueRef, rhs: ValueRef) !ValueRef {
    return req(ValueRef, LLVMBuildICmp(builder, predicate, lhs, rhs, ""));
}

pub fn fcmp(builder: BuilderRef, predicate: RealPredicate, lhs: ValueRef, rhs: ValueRef) !ValueRef {
    return req(ValueRef, LLVMBuildFCmp(builder, predicate, lhs, rhs, ""));
}

pub fn br(builder: BuilderRef, dest: BasicBlockRef) !void {
    _ = try req(ValueRef, LLVMBuildBr(builder, dest));
}

pub fn condBr(builder: BuilderRef, condition: ValueRef, then_block: BasicBlockRef, else_block: BasicBlockRef) !void {
    _ = try req(ValueRef, LLVMBuildCondBr(builder, condition, then_block, else_block));
}

pub fn ret(builder: BuilderRef, value: ValueRef) !void {
    _ = try req(ValueRef, LLVMBuildRet(builder, value));
}

pub fn zext(builder: BuilderRef, value: ValueRef, dest_ty: TypeRef) !ValueRef {
    return req(ValueRef, LLVMBuildZExt(builder, value, dest_ty, ""));
}

pub fn fadd(builder: BuilderRef, lhs: ValueRef, rhs: ValueRef) !ValueRef {
    return req(ValueRef, LLVMBuildFAdd(builder, lhs, rhs, ""));
}
pub fn fsub(builder: BuilderRef, lhs: ValueRef, rhs: ValueRef) !ValueRef {
    return req(ValueRef, LLVMBuildFSub(builder, lhs, rhs, ""));
}
pub fn fmul(builder: BuilderRef, lhs: ValueRef, rhs: ValueRef) !ValueRef {
    return req(ValueRef, LLVMBuildFMul(builder, lhs, rhs, ""));
}
pub fn fdiv(builder: BuilderRef, lhs: ValueRef, rhs: ValueRef) !ValueRef {
    return req(ValueRef, LLVMBuildFDiv(builder, lhs, rhs, ""));
}
pub fn fneg(builder: BuilderRef, value: ValueRef) !ValueRef {
    return req(ValueRef, LLVMBuildFNeg(builder, value, ""));
}
pub fn bitNot(builder: BuilderRef, value: ValueRef) !ValueRef {
    return req(ValueRef, LLVMBuildNot(builder, value, ""));
}
pub fn add(builder: BuilderRef, lhs: ValueRef, rhs: ValueRef) !ValueRef {
    return req(ValueRef, LLVMBuildAdd(builder, lhs, rhs, ""));
}
pub fn sub(builder: BuilderRef, lhs: ValueRef, rhs: ValueRef) !ValueRef {
    return req(ValueRef, LLVMBuildSub(builder, lhs, rhs, ""));
}
pub fn select(builder: BuilderRef, condition: ValueRef, then_value: ValueRef, else_value: ValueRef) !ValueRef {
    return req(ValueRef, LLVMBuildSelect(builder, condition, then_value, else_value, ""));
}
pub fn extractValue(builder: BuilderRef, aggregate: ValueRef, index: u32) !ValueRef {
    return req(ValueRef, LLVMBuildExtractValue(builder, aggregate, index, ""));
}

pub fn setLinkage(value: ValueRef, linkage: Linkage) void {
    LLVMSetLinkage(value, linkage);
}
