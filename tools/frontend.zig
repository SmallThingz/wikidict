const std = @import("std");

const Command = enum {
    install,
    build,
    check,
    dev,
    preview,
    help,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const command = parseCommand(args[1..]) catch |err| switch (err) {
        error.MissingCommand => {
            printUsage();
            std.process.exit(1);
        },
        error.UnknownCommand => {
            std.debug.print("unknown frontend command: {s}\n\n", .{args[1]});
            printUsage();
            std.process.exit(1);
        },
    };

    if (command == .help) {
        printUsage();
        return;
    }

    switch (command) {
        .install => try runCommand(init.io, "frontend", &.{ "bun", "install" }),
        .build => {
            try runCommand(init.io, "frontend", &.{ "bun", "install" });
            try runCommand(init.io, "frontend", &.{ "bun", "run", "build" });
        },
        .check => {
            try runCommand(init.io, "frontend", &.{ "bun", "install" });
            try runCommand(init.io, "frontend", &.{ "bun", "run", "check" });
        },
        .dev => {
            try runCommand(init.io, "frontend", &.{ "bun", "install" });
            try runCommand(init.io, "frontend", &.{ "bun", "run", "dev" });
        },
        .preview => {
            try runCommand(init.io, "frontend", &.{ "bun", "install" });
            try runCommand(init.io, "frontend", &.{ "bun", "run", "start" });
        },
        .help => unreachable,
    }
}

fn parseCommand(args: []const []const u8) !Command {
    if (args.len == 0) return error.MissingCommand;
    if (std.mem.eql(u8, args[0], "install")) return .install;
    if (std.mem.eql(u8, args[0], "build")) return .build;
    if (std.mem.eql(u8, args[0], "check")) return .check;
    if (std.mem.eql(u8, args[0], "dev")) return .dev;
    if (std.mem.eql(u8, args[0], "preview")) return .preview;
    if (std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help")) return .help;
    return error.UnknownCommand;
}

fn runCommand(io: std.Io, cwd: []const u8, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| {
            if (code != 0) std.process.exit(code);
        },
        .signal => |sig| {
            std.debug.print("frontend command terminated by signal {d}\n", .{@intFromEnum(sig)});
            std.process.exit(1);
        },
        else => std.process.exit(1),
    }
}

fn printUsage() void {
    std.debug.print(
        \\Usage: zig build frontend -- <command>
        \\
        \\Commands:
        \\  install   Install frontend dependencies
        \\  build     Build the frontend
        \\  check     Type-check and build the frontend
        \\  dev       Run the frontend dev server
        \\  preview   Preview the built frontend
        \\
    , .{});
}

test "parseCommand maps supported subcommands" {
    try std.testing.expectEqual(.install, try parseCommand(&.{"install"}));
    try std.testing.expectEqual(.build, try parseCommand(&.{"build"}));
    try std.testing.expectEqual(.check, try parseCommand(&.{"check"}));
    try std.testing.expectEqual(.dev, try parseCommand(&.{"dev"}));
    try std.testing.expectEqual(.preview, try parseCommand(&.{"preview"}));
    try std.testing.expectEqual(.help, try parseCommand(&.{"--help"}));
}

test "parseCommand rejects missing and unknown commands" {
    try std.testing.expectError(error.MissingCommand, parseCommand(&.{}));
    try std.testing.expectError(error.UnknownCommand, parseCommand(&.{"wat"}));
}
