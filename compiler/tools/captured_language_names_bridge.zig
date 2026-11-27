// Bind only the maintained language-profile data types for ordinary Tools.
// No provider callbacks, captured values, fallback policy or metadata are added.
const host_api = @import("language_name_host");
pub const WikitextProvider = struct {
    pub const LanguageNameRow = host_api.LanguageNameRow;
    pub const LanguageNameScope = host_api.LanguageNameScope;
    pub const LanguageDirection = host_api.LanguageDirection;
};
