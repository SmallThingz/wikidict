test "bounded blob file tooling imports framing merge and verification tests" {
    _ = @import("blob_file_reader.zig");
    _ = @import("blob_merge.zig");
    _ = @import("blob_verify.zig");
}
