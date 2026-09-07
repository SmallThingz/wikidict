const std = @import("std");
const lua = @import("root.zig");
const ir = @import("vm_ir.zig");
const opt = @import("vm_optimize.zig");
const exec = @import("vm_exec.zig");
const lib = @import("lua_stdlib.zig");
const Timespec = extern struct { seconds: c_long, nanos: c_long };
extern "c" fn clock_gettime(clock: c_int, value: *Timespec) c_int;
fn cpuNs() !u64 {
    var time: Timespec = undefined;
    if (clock_gettime(2, &time) != 0) return error.ClockFailed;
    return @as(u64, @intCast(time.seconds)) * 1000000000 + @as(u64, @intCast(time.nanos));
}
const cases = [_][]const u8{
    "local s=0; for i=1,N do s=s+i*3-2 end; return s",
    "local function record(v) local t={}; t.a=v;t.b=v+1;return t.a+t.b end; " ++
        "local function one(k,v) local t={};t[k]=v;return t[k] end; " ++
        "local s=0;for i=1,N do s=s+record(one('en',i)) end;return s",
    "local t={};for i=1,N do local k=i%127;t[k]=(t[k] or 0)+1 end;" ++
        "local s=0;for i=0,126 do s=s+(t[i] or 0) end;return s",
    "local function make(v) local t={};t.a=v;t.b=v+1;return t end;" ++
        "local s=0;for i=1,N do local t;if i%2==0 then t=make(i) else t=make(i) end;" ++
        "s=s+t.a+t.b end;return s",
    "local s=0;for i=1,N do if i%2==0 then s=s+1 else s=s+2 end end;return s",
    "local s=0;for i=1,N do s=s+tonumber(i) end;return s",
    "local s=0;for i=1,N do local x=i;local function f(v)x=x+v;return x end;s=s+f(1)+f(2) end;return s",
    "local function f(x)return x+1 end;local s=0;for i=1,N do s=s+f(i)+f(i+1) end;return s",
};
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 4) return error.Usage;
    const which = try std.fmt.parseInt(usize, args[1], 10);
    const n = try std.fmt.parseInt(u64, args[2], 10);
    const rounds = try std.fmt.parseInt(usize, args[3], 10);
    if (which >= cases.len or rounds == 0 or n > 50000000) return error.BadArgument;
    const prefix = try std.fmt.allocPrint(a, "local N={d};", .{n});
    const source = try std.mem.concat(a, u8, &.{ prefix, cases[which] });
    var chunk = try lua.parse(a, source);
    defer chunk.deinit();
    var p = try ir.lowerChunk(a, &chunk);
    defer p.deinit();
    _ = try opt.run(a, &p);
    var ns: u64 = 0;
    var capacity: usize = 0;
    var checksum: f64 = 0;
    const expected: u64 = switch (which) {
        0 => 3 * n * (n + 1) / 2 - 2 * n,
        1, 3 => n * (n + 2),
        4 => 2 * n - n / 2,
        5 => n * (n + 1) / 2,
        6 => n * (n + 5),
        7 => n * (n + 4),
        else => n,
    };
    for (0..rounds + 1) |round| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var vm = try exec.Vm.init(arena.allocator());
        try lib.install(&vm);
        const start = try cpuNs();
        const values = try vm.executeRoot(&p, &.{});
        const elapsed = (try cpuNs()) - start;
        defer exec.Vm.freeResults(values);
        if (values.len != 1 or values[0] != .number or values[0].number != @as(f64, @floatFromInt(expected))) return error.ChecksumMismatch;
        checksum = values[0].number;
        capacity = @max(capacity, arena.queryCapacity());
        if (round != 0) ns += elapsed;
    }
    var instructions: usize = 0;
    var registers: u64 = 0;
    for (p.functions.items) |maybe| if (maybe) |f| {
        instructions += f.insts.items.len;
        registers += f.reg_count;
    };
    std.debug.print("BENCH case={d} n={d} rounds={d} cpu_ns={d} arena_bytes={d} instructions={d} registers={d} checksum={d}\n", .{ which, n, rounds, ns, capacity, instructions, registers, checksum });
}
