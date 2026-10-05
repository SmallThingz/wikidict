//! Build-time diagnostics only; never an executable or reader fallback.
pub const Report = struct {
    literal_markup: bool = false,
    unclosed_formatting: bool = false,
    malformed_table: bool = false,
    unsupported_element: bool = false,
    render_limit: bool = false,
    template_presentation: bool = false,
    missing_template: bool = false,
    display_title_rejected: bool = false,
    missing_language_heading: bool = false,
    unresolved_language_heading: bool = false,
    expansion_error: bool = false,

    pub fn merge(self: *Report, other: Report) void {
        inline for (@typeInfo(Report).@"struct".field_names) |field|
            @field(self, field) = @field(self, field) or @field(other, field);
    }
    pub fn any(self: Report) bool {
        inline for (@typeInfo(Report).@"struct".field_names) |field|
            if (@field(self, field)) return true;
        return false;
    }
};
