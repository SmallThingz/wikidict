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

// Compact static-literal blobs self-identify so DLPMETA5 artifacts containing
// legacy blobs remain readable. Legacy blobs always begin with ValueTag 0..5.
pub const compact_marker: u8 = 0xf0;
pub const compact_version: u8 = 1;
pub const table_has_shape: u8 = 1 << 0;
pub const table_flags_mask: u8 = table_has_shape;
pub const synth_callable_marker: u8 = 0xf1;
