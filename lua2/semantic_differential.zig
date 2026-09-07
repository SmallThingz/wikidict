const std = @import("std");
const lua = @import("root.zig");
const ir = @import("vm_ir.zig");
const opt = @import("vm_optimize.zig");
const codec = @import("vm_codec.zig");
const exec = @import("vm_exec.zig");
const lib = @import("lua_stdlib.zig");
const Value = exec.Value;
fn read(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const data = try a.alloc(u8, @intCast(stat.size));
    if (try file.readPositionalAll(io, data, 0) != data.len) return error.Truncated;
    return data;
}
fn write(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, bytes, 0);
}
fn u32le(out: *std.ArrayList(u8), a: std.mem.Allocator, n: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, n, .little);
    try out.appendSlice(a, &bytes);
}
fn pack(out: *std.ArrayList(u8), a: std.mem.Allocator, values: []const Value) !void {
    try out.append(a, 1);
    try u32le(out, a, @intCast(values.len));
    for (values) |v| switch (v) {
        .nil => try out.append(a, 0),
        .boolean => |b| {
            try out.append(a, 1);
            try out.append(a, @intFromBool(b));
        },
        .number => |n| {
            try out.append(a, 2);
            var bytes: [8]u8 = undefined;
            const bits: u64 = if (std.math.isNan(n)) 0x7ff8000000000000 else @bitCast(n);
            std.mem.writeInt(u64, &bytes, bits, .little);
            try out.appendSlice(a, &bytes);
        },
        .string => |s| {
            try out.append(a, 3);
            try u32le(out, a, @intCast(s.len));
            try out.appendSlice(a, s);
        },
        else => return error.UnsupportedResult,
    };
}
fn execute(a: std.mem.Allocator, p: *const ir.Program) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    try lib.install(&vm);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    if (vm.executeRoot(p, &.{})) |values| {
        defer exec.Vm.freeResults(values);
        try pack(&out, a, values);
    } else |_| try out.append(a, 0);
    return out.toOwnedSlice(a);
}
const reference_runner =
    \\local function encode(v)
    \\  local t=type(v)
    \\  if t=='nil' then return string.char(0) end
    \\  if t=='boolean' then return string.char(1,v and 1 or 0) end
    \\  if t=='number' then
    \\    if v~=v then return string.char(2,0,0,0,0,0,0,248,127) end
    \\    return string.char(2)..string.pack('<d',v)
    \\  end
    \\  if t=='string' then return string.char(3)..string.pack('<I4',#v)..v end
    \\  error('unsupported result '..t)
    \\end
    \\for source in io.lines(arg[1]) do
    \\  local f=assert(load(source,'test','t'))
    \\  local values=table.pack(pcall(f))
    \\  local out
    \\  if not values[1] then out=string.char(0)
    \\  else
    \\    out=string.char(1)..string.pack('<I4',values.n-1)
    \\    for i=2,values.n do out=out..encode(values[i]) end
    \\  end
    \\  io.write(string.pack('<I4',#out),out)
    \\end
;
const templates = [_][]const u8{
    "local i=0.0; local s=A; while i<N do s=s+i*B; i=i+1.0 end; return s,i",
    "local function f(x) local y; if x then y=A else y=B end; return y+C end; return f(true),f(false)",
    "local n=A; local function f(x) n=n+x; return n end; return f(B),f(C),n",
    "local n=A; local function m() n=B; return C end; local function pair(x,y) return x,y end; local x,y=pair(n,m()); return x,y,n",
    "local t={}; function t:f(x) return A end; local function m() t.f=function() return B end; return C end; return t:f(m())",
    "local function f(k,v) local t={}; t[k]=v; return t[k] end; return f('en',A),f('fr',B)",
    "local function it(_,i) i=i+1.0; if i<=N then return i,i*B end end; local s=A; for k,v in it,nil,0.0 do s=s+v end; return s",
    "local bound=N; local s=A; for i=1.0,bound do s=s+B; bound=0.0 end; return s,bound",
    "local x=A; local function idx(t,k) x=x+1.0; return function(self,v) return x*100.0+v end end; local o=setmetatable({}, {__index=idx}); return o:missing(x),x",
    "local t={A,B,[9]=C,N}; return t[1],t[2],t[3],t[9]",
    "local function f(...) return ... end; local function pair() return A,B end; return f(C,pair())",
    "local function f(x) local t={}; if x then t.k=A else t.k=B end; return t.k end; return f(true),f(false)",
    "local function f(k) local t={}; t[k]=A; return t[k] end; return f(nil)",
    "local unused='not a number'+A; return B",
    "return 0.0/0.0,1.0/-0.0,-0.0",
    "local f=function(x) return A end; local function m() f=function() return B end; return C end; return f(m())",
    "local function make(x) return function() return x end end; local fs={};for i=1.0,N do fs[i]=make(i+A) end;return fs[1](),fs[N]()",
    "local function make(x) local v=x;return function(d) v=v+d;return v end end;local fs={};for i=1.0,N do fs[i]=make(i*B) end;return fs[1](A),fs[N](B),fs[1](C)",
    "local function make(x) return function() x=x+1.0;return x end,function() return x end end;local a,b={},{};for i=1.0,N do a[i],b[i]=make(i*B) end;return a[1](),b[1](),a[N](),b[N]()",
};
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 4) return error.Usage;
    if (std.mem.eql(u8, args[1], "generate")) {
        const n = if (args.len > 4) try std.fmt.parseInt(usize, args[4], 10) else 2048;
        var sources: std.ArrayList(u8) = .empty;
        var seed: u64 = 0x62dad59;
        for (0..n) |id| {
            seed = seed *% 6364136223846793005 +% 1442695040888963407;
            const numbers = [_]i64{ @as(i64, @intCast(seed % 21)) - 10, @as(i64, @intCast((seed >> 8) % 9)) + 1, @intCast((seed >> 16) % 17), @as(i64, @intCast((seed >> 24) % 7)) + 1 };
            for (templates[id % templates.len]) |ch| {
                const index: ?usize = switch (ch) {
                    'A' => 0,
                    'B' => 1,
                    'C' => 2,
                    'N' => 3,
                    else => null,
                };
                if (index) |i| {
                    const number = try std.fmt.allocPrint(a, "{d}.0", .{numbers[i]});
                    try sources.appendSlice(a, number);
                } else try sources.append(a, ch);
            }
            try sources.append(a, '\n');
        }
        try write(init.io, args[2], sources.items);
        try write(init.io, args[3], reference_runner);
        return;
    }
    const sources = try read(init.io, a, args[2]);
    const reference = try read(init.io, a, args[3]);
    var lines = std.mem.splitScalar(u8, sources, '\n');
    var pos: usize = 0;
    var cases: usize = 0;
    var failures: usize = 0;
    while (lines.next()) |source| {
        if (source.len == 0) continue;
        if (reference.len - pos < 4) return error.TruncatedReference;
        const len = std.mem.readInt(u32, reference[pos..][0..4], .little);
        pos += 4;
        if (len > reference.len - pos) return error.TruncatedReference;
        const expected = reference[pos..][0..len];
        pos += len;
        var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer scratch.deinit();
        const allocator = scratch.allocator();
        var chunk = try lua.parse(allocator, source);
        defer chunk.deinit();
        var p = try ir.lowerChunk(allocator, &chunk);
        defer p.deinit();
        const baseline = try execute(allocator, &p);
        if (!std.mem.eql(u8, baseline, expected)) {
            failures += 1;
            std.debug.print("BASELINE_MISMATCH case={d} source={s}\n", .{ cases, source });
        }
        _ = opt.run(allocator, &p) catch |err| {
            failures += 1;
            std.debug.print("COMPILE_ERROR case={d} {s} source={s}\n", .{ cases, @errorName(err), source });
            cases += 1;
            continue;
        };
        const bytes = try codec.serialize(allocator, &p);
        var q = try codec.deserializeBorrowed(allocator, bytes);
        defer q.deinit();
        const actual = try execute(allocator, &q);
        if (!std.mem.eql(u8, actual, expected)) {
            failures += 1;
            std.debug.print("OPTIMIZED_MISMATCH case={d} expected={x} actual={x} source={s}\n", .{ cases, expected, actual, source });
        }
        cases += 1;
    }
    if (pos != reference.len) return error.ExtraReference;
    std.debug.print("DIFFERENTIAL cases={d} mismatches={d}\n", .{ cases, failures });
    if (failures != 0) return error.DifferentialFailed;
}
