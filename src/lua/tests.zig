test {
    _ = @import("parser/root.zig");
    _ = @import("compiler/ir.zig");
    _ = @import("compiler/optimize.zig");
    _ = @import("compiler/link_image.zig");
    _ = @import("compiler/numeric_link.zig");
    _ = @import("compiler/numbers.zig");
    _ = @import("aot/codegen.zig");
    _ = @import("aot/program_data.zig");
    _ = @import("aot/module_registry_gen.zig");
    _ = @import("extract/modules.zig");
    _ = @import("extract/templates.zig");
    _ = @import("wikitext/expression.zig");
    _ = @import("wikitext/preprocess.zig");
    _ = @import("runtime/pattern.zig");
    _ = @import("runtime/format_core.zig");
}
