//! The dictionary pipeline delegates bytecode generation to the VM-owned converter.
pub const main = @import("runtime_bridge").compileBundle;
