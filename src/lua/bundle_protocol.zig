pub const Request = struct {
    root: []const u8,
    dump: []const u8,
    title: []const u8,
    source: []const u8,
};

pub const Reply = struct {
    schema: []const u8 = "dict.expansion.v1",
    backend: []const u8 = "lua-aot",
    output: ?[]const u8 = null,
    stage: []const u8 = "expand",
    error_name: ?[]const u8 = null,
    detail: ?[]const u8 = null,
};
