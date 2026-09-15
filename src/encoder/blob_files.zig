//! Data-only blob file ownership. Final dictionaries are self-contained;
//! there are no companion/symbol resolution paths at read time.
const std = @import("std");
const enc = @import("blob_encoder");

pub const File = struct {
    a: std.mem.Allocator,
    bytes: []align(std.heap.page_size_min) const u8,
    index: enc.blob_format.IndexedBlobView,

    pub fn open(io: std.Io, a: std.mem.Allocator, path: []const u8) !File {
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const len = std.math.cast(usize, (try file.stat(io)).size) orelse return error.FileTooBig;
        if (len == 0) return error.InvalidBlob;
        const bytes = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
        errdefer std.posix.munmap(bytes);
        const view = try enc.blob_format.openTrusted(bytes);
        return .{ .a = a, .bytes = bytes, .index = try view.buildIndexAlloc(a) };
    }

    pub fn deinit(self: *File) void {
        self.index.deinit(self.a);
        std.posix.munmap(self.bytes);
        self.* = undefined;
    }
};

pub fn requireComplete(io: std.Io, a: std.mem.Allocator, root: []const u8) !void {
    const path = try std.fs.path.join(a, &.{ root, ".incomplete" });
    defer a.free(path);
    var marker = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    marker.close(io);
    return error.DictionaryBuildIncomplete;
}
