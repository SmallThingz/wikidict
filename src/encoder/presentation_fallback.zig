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
    expansion_error: bool = false,

    pub fn merge(self: *Report, other: Report) void {
        inline for (@typeInfo(Report).@"struct".fields) |field|
            @field(self, field.name) = @field(self, field.name) or @field(other, field.name);
    }
    pub fn any(self: Report) bool {
        inline for (@typeInfo(Report).@"struct".fields) |field|
            if (@field(self, field.name)) return true;
        return false;
    }
};
