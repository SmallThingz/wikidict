//! Compiler-facing exports; keep the capture-bound normalization source stable.
const registry = @import("namespace_registry.zig");

pub const magic_words = registry.magic_words;
pub const Role = registry.Role;
pub const Spec = registry.Spec;
pub const Registry = registry.Registry;
pub const normalizeSpacing = registry.normalizeSpacing;
pub const english_test_fixture = registry.english_test_fixture;
pub const englishTestRegistry = registry.englishTestRegistry;
pub const french_test_fixture = registry.french_test_fixture;
pub const german_test_fixture = registry.german_test_fixture;
pub const page_redirects = @import("page_redirects.zig");

test {
    // Retain discovery of both original registry and redirect parser tests.
    _ = registry;
    _ = page_redirects;
}
