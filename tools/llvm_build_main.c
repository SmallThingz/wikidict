/*
 * Keep the LLVM producer on a libc entry point. On the supported Zig toolchain,
 * a std.process.Init executable linked to system LLVM reproduces a crash in
 * LLVMContextCreate; the same Zig core called from libc main is stable.
 */
extern int dict_llvm_build_main(int argc, char **argv);

int main(int argc, char **argv) {
    return dict_llvm_build_main(argc, argv);
}
