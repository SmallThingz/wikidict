//! Native integration boundary. Compiler, codec and VM stay owned by lua2/.
//! Updating the VM must update this adapter rather than duplicating its wire grammar.
pub const Runtime = @import("lua2/wiktionary_runtime.zig").Runtime;
pub const Vm = @import("lua2/vm_exec.zig").Vm;
pub const compileBundle = @import("lua2/bundle_compile.zig").main;
