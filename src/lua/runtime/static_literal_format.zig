pub const ValueTag = enum(u8) {
    nil = 0,
    false_ = 1,
    true_ = 2,
    number = 3,
    string = 4,
    table = 5,
};

pub const FieldTag = enum(u8) {
    list = 0,
    named = 1,
    keyed = 2,
};

pub const no_shape: u32 = 0xffff_ffff;
pub const max_depth: usize = 256;
