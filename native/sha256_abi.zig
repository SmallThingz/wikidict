//! LLVM-compiled SHA-256 leaf for the native worker.
//! Only raw pointers, lengths and bytes cross this backend boundary.
const std = @import("std");

pub export fn dict_sha256_hash(input: [*]const u8, len: usize, output: [*]u8) callconv(.c) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input[0..len], &digest, .{});
    @memcpy(output[0..digest.len], &digest);
}

test "C ABI SHA-256 leaf matches the standard digest" {
    const input = "semantic symbol identity";
    var actual: [32]u8 = undefined;
    dict_sha256_hash(input.ptr, input.len, &actual);
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}
