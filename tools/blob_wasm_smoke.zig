const blobs = @import("blob_decoder");

pub export fn blobSmoke(ptr: [*]const u8, len: usize) usize {
    const view = blobs.openTrustedBlob(ptr[0..len]) catch return 0;
    var records = view.iterator();
    const record = records.next() catch return 0;
    return if (record) |item| item.title().len else @intFromEnum(view.kind());
}

pub export fn catalogSmoke(ptr: [*]const u8, len: usize) usize {
    const entry = blobs.findLanguageBlob(ptr[0..len], "English") catch return 0;
    if (entry) |found| return found.heading.len;
    var filename: [blobs.language_blob_filename_len]u8 = undefined;
    return blobs.languageBlobFilename("English", &filename).len;
}

// Exercise the allocating runtime-index API without introducing an OS allocator.
pub export fn blobIndexSmoke(ptr: [*]const u8, len: usize) usize {
    const std = @import("std");
    var scratch: [4096]u8 = undefined;
    var buffer = std.heap.FixedBufferAllocator.init(&scratch);
    const allocator = buffer.allocator();
    const view = blobs.openTrustedBlob(ptr[0..len]) catch return 0;
    var index = view.buildIndexAlloc(allocator) catch return 0;
    defer index.deinit(allocator);
    if (index.recordCount() == 0) return 0;
    const record = (index.find("cat") catch return 0) orelse
        (index.recordAt(0) catch return 0);
    return record.title().len;
}
