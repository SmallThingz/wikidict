const std = @import("std");
const builtin = @import("builtin");

pub fn isGuiInvocation(argv0: []const u8) bool {
    const name = std.fs.path.basename(argv0);
    return std.mem.eql(u8, name, "wikidict-gio") or
        (builtin.os.tag == .windows and std.ascii.eqlIgnoreCase(name, "wikidict-gio.exe"));
}

// The only executable is wikidict. Qt and the GUI are loaded only after argv[0]
// selects this branch. Resolve beside the real executable, never through cwd.
pub fn run(init: std.process.Init, argv: []const []const u8) !u8 {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        std.debug.print("wikidict-gio: the desktop component is unsupported on this platform\n", .{});
        return 2;
    } else {
        const a = init.arena.allocator();
        const executable_dir = try std.process.executableDirPathAlloc(init.io, a);
        const filename = if (builtin.os.tag == .macos) "libwikidict-gui.dylib" else "libwikidict-gui.so";
        const path = try std.fs.path.resolve(a, &.{ executable_dir, "..", "lib", filename });
        var library = std.DynLib.open(path) catch |err| {
            std.debug.print("wikidict-gio: cannot load desktop component '{s}' ({s}); install the desktop component beside wikidict\n", .{ path, @errorName(err) });
            return 2;
        };
        // Keep Qt loaded until the process exits: static Qt/plugin destructors
        // may refer to its code after the application event loop returns.
        const GuiMain = *const fn (c_int, [*:null]?[*:0]u8) callconv(.c) c_int;
        const gui_main = library.lookup(GuiMain, "wikidict_gui_main") orelse {
            std.debug.print("wikidict-gio: desktop component '{s}' is incompatible (missing wikidict_gui_main)\n", .{path});
            return 2;
        };
        if (argv.len > std.math.maxInt(c_int)) return error.TooManyArguments;
        const c_argv = try a.allocSentinel(?[*:0]u8, argv.len, null);
        for (argv, 0..) |arg, i| c_argv[i] = (try a.dupeSentinel(u8, arg, 0)).ptr;
        const result = gui_main(@intCast(argv.len), c_argv.ptr);
        return if (result >= 0 and result <= 255) @intCast(result) else 2;
    }
}

test "GUI dispatch uses only the invoked basename" {
    const expect = std.testing.expect;
    try expect(isGuiInvocation("wikidict-gio"));
    try expect(isGuiInvocation("/opt/wikidict/bin/wikidict-gio"));
    try expect(isGuiInvocation("./wikidict-gio"));
    try expect(!isGuiInvocation("wikidict"));
    try expect(!isGuiInvocation("dict"));
    try expect(!isGuiInvocation("/wikidict-gio/wikidict"));
    try expect(!isGuiInvocation("wikidict-gio-extra"));
    if (builtin.os.tag != .windows)
        try expect(!isGuiInvocation("prefix\\wikidict-gio"));
    try expect(!isGuiInvocation(""));
}
