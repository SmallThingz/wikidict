const blobs = @import("blob_decoder");

pub export fn blobSmoke(ptr: [*]const u8, len: usize) usize {
    const view = blobs.openTrustedBlob(ptr[0..len]) catch return 0;
    var records = view.iterator();
    const record = records.next() catch return 0;
    return if (record) |item| item.title().len else view.recordCount();
}

pub export fn catalogSmoke(ptr: [*]const u8, len: usize) usize {
    const entry = blobs.findLanguageBlob(ptr[0..len], "English") catch return 0;
    if (entry) |found| return found.filename.len;
    var filename: [blobs.language_blob_filename_len]u8 = undefined;
    return blobs.languageBlobFilename("English", &filename).len;
}
