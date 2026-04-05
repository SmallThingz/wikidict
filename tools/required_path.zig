const std = @import("std");

pub fn exists(io: std.Io, path: []const u8) !bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

pub fn ensureExistsOrExit(io: std.Io, path: []const u8, label: []const u8) void {
    const found = exists(io, path) catch |err| {
        std.debug.print("failed to access {s} at {s}: {s}\n", .{ label, path, @errorName(err) });
        std.process.exit(1);
    };
    if (!found) {
        std.debug.print("{s} not found: {s}\n", .{ label, path });
        std.process.exit(1);
    }
}

pub fn runToolOrExit(
    io: std.Io,
    allocator: std.mem.Allocator,
    tool_path: []const u8,
    tool_label: []const u8,
    tool_args: []const []const u8,
) void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    argv.append(allocator, tool_path) catch oomExit();
    argv.appendSlice(allocator, tool_args) catch oomExit();

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        std.debug.print("failed to spawn {s} at {s}: {s}\n", .{ tool_label, tool_path, @errorName(err) });
        std.process.exit(1);
    };
    const term = child.wait(io) catch |err| {
        std.debug.print("failed waiting for {s} at {s}: {s}\n", .{ tool_label, tool_path, @errorName(err) });
        std.process.exit(1);
    };
    switch (term) {
        .exited => |code| {
            if (code != 0) std.process.exit(code);
        },
        .signal => |sig| {
            std.debug.print("{s} at {s} terminated by signal {d}\n", .{ tool_label, tool_path, @intFromEnum(sig) });
            std.process.exit(1);
        },
        else => std.process.exit(1),
    }
}

fn oomExit() noreturn {
    std.debug.print("out of memory while preparing tool command\n", .{});
    std.process.exit(1);
}
