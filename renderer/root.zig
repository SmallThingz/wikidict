pub const html_render = @import("html_render.zig");
pub const wikitext_runtime = @import("wikitext_runtime.zig");
pub const xml_decode = @import("xml_decode.zig");

test "renderer module compiles" {
    _ = html_render;
    _ = wikitext_runtime;
    _ = xml_decode;
}
