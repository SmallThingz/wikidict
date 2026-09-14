extern fn dict_native_expansion_worker_main() callconv(.c) u8;

pub fn main() !void {
    if (dict_native_expansion_worker_main() != 0)
        return error.NativeExpansionWorkerFailed;
}
