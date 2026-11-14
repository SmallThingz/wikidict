//! Build-time observers only. No Lua Value/Context/Callable layout fields.
//! Generated literals require the new explicit emitter symbol; old inlined
//! value-leaf boxing does not invoke this interface and remains unproved.
pub const Observer = struct {
    data: *anyopaque,
    copy: *const fn (*anyopaque, usize, []const u8, []const u8) anyerror!void,
    concat: *const fn (*anyopaque, usize, []const []const u8, []const u8) anyerror!void,
    slice: *const fn (*anyopaque, usize, []const u8, usize, usize, []const u8) anyerror!void,
    format: *const fn (*anyopaque, usize, []const u8, []const []const u8, []const u8) anyerror!void,
    literal: *const fn (*anyopaque, []const u8) anyerror!void,
    retire: *const fn (*anyopaque, usize) void,
    failure: ?anyerror = null,
    previous: ?*Observer = null,
};
threadlocal var active: ?*Observer = null;
pub fn enter(observer: *Observer) ?*Observer { const previous = active; observer.previous = previous; active = observer; return previous; }
pub fn restore(previous: ?*Observer) void { active = previous; }
pub fn enabled() bool { return active != null; }
pub fn copied(owner: usize, source: []const u8, result: []const u8) !void {
    if (active) |o| o.copy(o.data, owner, source, result) catch |err| return failed(err);
}
pub fn concatenated(owner: usize, sources: []const []const u8, result: []const u8) !void {
    if (active) |o| o.concat(o.data, owner, sources, result) catch |err| return failed(err);
}
pub fn sliced(owner: usize, source: []const u8, start: usize, end: usize, result: []const u8) !void {
    if (active) |o| o.slice(o.data, owner, source, start, end, result) catch |err| return failed(err);
}
pub fn formatted(owner: usize, format: []const u8, args: []const []const u8, result: []const u8) !void {
    if (active) |o| o.format(o.data, owner, format, args, result) catch |err| return failed(err);
}
pub fn retired(owner: usize) void { if (active) |o| o.retire(o.data, owner); }
pub fn literal(bytes: []const u8) void {
    if (active) |o| o.literal(o.data, bytes) catch |err| { noteFailure(err); };
}
pub fn check() !void { if (active) |o| if (o.failure) |err| return err; }

pub fn noteFailure(err: anyerror) void {
    var current = active;
    while (current) |observer| { observer.failure = err; current = observer.previous; }
}
pub fn operational(err: anyerror) anyerror { return failed(err); }
fn failed(err: anyerror) anyerror {
    noteFailure(err);
    return err;
}
