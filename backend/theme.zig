const builtin = @import("builtin");
const std = @import("std");

pub const Source = enum {
    fallback,
    gtk,
    qt,
    cosmic,
    macos,
    windows,
};

pub const Scheme = enum {
    light,
    dark,
};

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    fn mix(a: Rgb, b: Rgb, t: f32) Rgb {
        return .{
            .r = lerpChannel(a.r, b.r, t),
            .g = lerpChannel(a.g, b.g, t),
            .b = lerpChannel(a.b, b.b, t),
        };
    }

    fn withLightness(self: Rgb, min_l: f32, max_l: f32, max_s: f32) Rgb {
        var hsl = Hsl.fromRgb(self);
        hsl.l = clamp01(hsl.l, min_l, max_l);
        hsl.s = @min(hsl.s, max_s);
        return hsl.toRgb();
    }

    fn withAccentRange(self: Rgb, scheme: Scheme) Rgb {
        var hsl = Hsl.fromRgb(self);
        if (hsl.s < 0.28) hsl.s = 0.28;
        hsl.s = clamp01(hsl.s, 0.42, 0.76);
        hsl.l = switch (scheme) {
            .light => clamp01(hsl.l, 0.38, 0.56),
            .dark => clamp01(hsl.l, 0.58, 0.74),
        };
        return hsl.toRgb();
    }
};

pub const Palette = struct {
    source: Source,
    name: []const u8,
    scheme: Scheme,
    bg: Rgb,
    page: Rgb,
    panel: Rgb,
    line: Rgb,
    line_strong: Rgb,
    ink: Rgb,
    muted: Rgb,
    accent: Rgb,
    accent_strong: Rgb,
    // Alpha-only overlays are shipped separately so the frontend can blend them over
    // whichever solid theme colors it is currently animating between.
    accent_soft_alpha: f32,
    glass_bg_alpha: f32,
    glass_border_alpha: f32,

    pub fn deinit(self: *Palette, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const JsonPalette = struct {
    source: []const u8,
    name: []const u8,
    scheme: []const u8,
    colors: struct {
        bg: []const u8,
        page: []const u8,
        panel: []const u8,
        line: []const u8,
        lineStrong: []const u8,
        ink: []const u8,
        muted: []const u8,
        accent: []const u8,
        accentStrong: []const u8,
        accentSoft: []const u8,
        glassBg: []const u8,
        glassBorder: []const u8,
    },
};

pub fn detectSystemPalette(io: std.Io, allocator: std.mem.Allocator) !Palette {
    const os = builtin.os.tag;
    if (os == .windows) {
        if (try probeWindows(io, allocator)) |palette| return palette;
        return fallbackPalette(allocator, .windows, .light, "Windows");
    }
    if (os == .macos) {
        if (try probeMacOs(io, allocator)) |palette| return palette;
        return fallbackPalette(allocator, .macos, .light, "macOS");
    }

    const desktop = firstNonEmpty(&.{
        envVar("XDG_CURRENT_DESKTOP"),
        envVar("DESKTOP_SESSION"),
        envVar("XDG_SESSION_DESKTOP"),
    }) orelse "";

    if (containsIgnoreCase(desktop, "cosmic")) {
        if (try probeCosmic(io, allocator)) |palette| return palette;
        if (try probeGtk(io, allocator)) |palette| return renamePalette(allocator, palette, .cosmic, "COSMIC");
        return fallbackPalette(allocator, .cosmic, .light, "COSMIC");
    }
    if (containsIgnoreCase(desktop, "plasma") or containsIgnoreCase(desktop, "kde")) {
        if (try probeQt(io, allocator, envVar("HOME"))) |palette| return palette;
        if (try probeGtk(io, allocator)) |palette| return palette;
        return fallbackPalette(allocator, .qt, .light, "KDE");
    }

    if (try probeQt(io, allocator, envVar("HOME"))) |palette| return palette;
    if (try probeGtk(io, allocator)) |palette| return palette;
    return fallbackPalette(allocator, .fallback, .light, "System");
}

pub fn jsonPaletteAlloc(allocator: std.mem.Allocator, palette: *const Palette) !JsonPalette {
    return .{
        .source = sourceString(palette.source),
        .name = palette.name,
        .scheme = schemeString(palette.scheme),
        .colors = .{
            .bg = try hexColorAlloc(allocator, palette.bg),
            .page = try hexColorAlloc(allocator, palette.page),
            .panel = try hexColorAlloc(allocator, palette.panel),
            .line = try hexColorAlloc(allocator, palette.line),
            .lineStrong = try hexColorAlloc(allocator, palette.line_strong),
            .ink = try hexColorAlloc(allocator, palette.ink),
            .muted = try hexColorAlloc(allocator, palette.muted),
            .accent = try hexColorAlloc(allocator, palette.accent),
            .accentStrong = try hexColorAlloc(allocator, palette.accent_strong),
            .accentSoft = try rgbaColorAlloc(allocator, palette.accent, palette.accent_soft_alpha),
            .glassBg = try rgbaColorAlloc(allocator, palette.panel, palette.glass_bg_alpha),
            .glassBorder = try rgbaColorAlloc(allocator, palette.accent, palette.glass_border_alpha),
        },
    };
}

fn fallbackPalette(
    allocator: std.mem.Allocator,
    source: Source,
    scheme: Scheme,
    name: []const u8,
) !Palette {
    return buildPalette(allocator, .{
        .source = source,
        .scheme = scheme,
        .name = name,
        .bg = switch (scheme) {
            .light => .{ .r = 0xf5, .g = 0xf5, .b = 0xf2 },
            .dark => .{ .r = 0x0f, .g = 0x11, .b = 0x15 },
        },
        .panel = switch (scheme) {
            .light => .{ .r = 0xfe, .g = 0xfd, .b = 0xf8 },
            .dark => .{ .r = 0x17, .g = 0x1b, .b = 0x21 },
        },
        .ink = switch (scheme) {
            .light => .{ .r = 0x1e, .g = 0x22, .b = 0x2a },
            .dark => .{ .r = 0xf2, .g = 0xf4, .b = 0xf8 },
        },
        .accent = switch (scheme) {
            .light => .{ .r = 0x3d, .g = 0x72, .b = 0x91 },
            .dark => .{ .r = 0x7f, .g = 0xba, .b = 0xd6 },
        },
    });
}

const ProbeSeed = struct {
    source: Source,
    scheme: Scheme,
    name: []const u8,
    // Probe colors are raw desktop-theme samples before palette normalization clamps
    // them into the UI-friendly luminance and saturation ranges.
    bg: Rgb,
    panel: Rgb,
    ink: Rgb,
    accent: Rgb,
};

fn buildPalette(allocator: std.mem.Allocator, seed: ProbeSeed) !Palette {
    const bg = switch (seed.scheme) {
        .light => seed.bg.withLightness(0.95, 0.985, 0.1),
        .dark => seed.bg.withLightness(0.075, 0.14, 0.14),
    };
    const panel = switch (seed.scheme) {
        .light => seed.panel.withLightness(0.975, 0.995, 0.12),
        .dark => seed.panel.withLightness(0.11, 0.2, 0.16),
    };
    const ink = switch (seed.scheme) {
        .light => seed.ink.withLightness(0.08, 0.18, 0.22),
        .dark => seed.ink.withLightness(0.88, 0.97, 0.18),
    };
    const accent = seed.accent.withAccentRange(seed.scheme);
    const page = switch (seed.scheme) {
        .light => Rgb.mix(panel, .{ .r = 255, .g = 255, .b = 252 }, 0.42),
        .dark => Rgb.mix(panel, bg, 0.24),
    };
    const line = switch (seed.scheme) {
        .light => Rgb.mix(panel, ink, 0.12),
        .dark => Rgb.mix(panel, ink, 0.16),
    };
    const line_strong = switch (seed.scheme) {
        .light => Rgb.mix(panel, ink, 0.22),
        .dark => Rgb.mix(panel, ink, 0.24),
    };
    const muted = switch (seed.scheme) {
        .light => Rgb.mix(ink, bg, 0.55),
        .dark => Rgb.mix(ink, bg, 0.38),
    };
    const accent_strong = switch (seed.scheme) {
        .light => Rgb.mix(accent, .{ .r = 10, .g = 16, .b = 24 }, 0.18),
        .dark => Rgb.mix(accent, .{ .r = 255, .g = 255, .b = 255 }, 0.18),
    };

    return .{
        .source = seed.source,
        .scheme = seed.scheme,
        .name = try allocator.dupe(u8, seed.name),
        .bg = bg,
        .page = page,
        .panel = panel,
        .line = line,
        .line_strong = line_strong,
        .ink = ink,
        .muted = muted,
        .accent = accent,
        .accent_strong = accent_strong,
        .accent_soft_alpha = switch (seed.scheme) {
            .light => 0.12,
            .dark => 0.18,
        },
        .glass_bg_alpha = switch (seed.scheme) {
            .light => 0.84,
            .dark => 0.82,
        },
        .glass_border_alpha = switch (seed.scheme) {
            .light => 0.09,
            .dark => 0.12,
        },
    };
}

fn renamePalette(
    allocator: std.mem.Allocator,
    palette: Palette,
    source: Source,
    name: []const u8,
) !Palette {
    defer allocator.free(palette.name);
    var renamed = palette;
    renamed.source = source;
    renamed.name = try allocator.dupe(u8, name);
    return renamed;
}

fn probeQt(io: std.Io, allocator: std.mem.Allocator, home_opt: ?[]const u8) !?Palette {
    const home = home_opt orelse return null;
    const path = try std.fs.path.join(allocator, &.{ home, ".config", "kdeglobals" });
    defer allocator.free(path);

    const contents = try readFileIfExists(io, allocator, path) orelse return null;
    defer allocator.free(contents);

    const theme_name = iniValue(contents, "General", "ColorScheme") orelse "KDE";
    const bg = parseCommaRgb(iniValue(contents, "Colors:Window", "BackgroundNormal") orelse return null) orelse return null;
    const panel = parseCommaRgb(iniValue(contents, "Colors:View", "BackgroundNormal") orelse iniValue(contents, "Colors:Window", "BackgroundAlternate") orelse return null) orelse return null;
    const ink = parseCommaRgb(iniValue(contents, "Colors:Window", "ForegroundNormal") orelse return null) orelse return null;
    const accent = parseCommaRgb(
        iniValue(contents, "Colors:Selection", "BackgroundNormal") orelse
            iniValue(contents, "Colors:Button", "DecorationFocus") orelse
            "61,108,176",
    ) orelse Rgb{ .r = 61, .g = 108, .b = 176 };

    const scheme = if (containsIgnoreCase(theme_name, "dark") or perceivedLightness(bg) < 0.4) Scheme.dark else Scheme.light;
    return try buildPalette(allocator, .{
        .source = .qt,
        .scheme = scheme,
        .name = theme_name,
        .bg = bg,
        .panel = panel,
        .ink = ink,
        .accent = accent,
    });
}

fn probeGtk(io: std.Io, allocator: std.mem.Allocator) !?Palette {
    const gtk_theme = try runTextCommand(io, allocator, &.{ "gsettings", "get", "org.gnome.desktop.interface", "gtk-theme" });
    defer if (gtk_theme) |value| allocator.free(value);
    const scheme_text = try runTextCommand(io, allocator, &.{ "gsettings", "get", "org.gnome.desktop.interface", "color-scheme" });
    defer if (scheme_text) |value| allocator.free(value);
    const accent_text = try runTextCommand(io, allocator, &.{ "gsettings", "get", "org.gnome.desktop.interface", "accent-color" });
    defer if (accent_text) |value| allocator.free(value);

    if (gtk_theme == null and scheme_text == null and accent_text == null) return null;

    const gtk_name = if (gtk_theme) |value| unquote(value) else "GTK";
    const scheme = if (scheme_text) |value|
        if (containsIgnoreCase(value, "dark")) Scheme.dark else Scheme.light
    else
        if (containsIgnoreCase(gtk_name, "dark")) Scheme.dark else Scheme.light;
    const accent = if (accent_text) |value|
        accentFromName(unquote(value)) orelse parseCssHex(unquote(value)) orelse defaultAccent(scheme)
    else
        defaultAccent(scheme);

    return try buildPalette(allocator, .{
        .source = .gtk,
        .scheme = scheme,
        .name = gtk_name,
        .bg = switch (scheme) {
            .light => .{ .r = 0xf4, .g = 0xf4, .b = 0xef },
            .dark => .{ .r = 0x12, .g = 0x14, .b = 0x18 },
        },
        .panel = switch (scheme) {
            .light => .{ .r = 0xfc, .g = 0xfb, .b = 0xf7 },
            .dark => .{ .r = 0x1a, .g = 0x1f, .b = 0x26 },
        },
        .ink = switch (scheme) {
            .light => .{ .r = 0x19, .g = 0x1d, .b = 0x24 },
            .dark => .{ .r = 0xee, .g = 0xf1, .b = 0xf5 },
        },
        .accent = accent,
    });
}

fn probeCosmic(io: std.Io, allocator: std.mem.Allocator) !?Palette {
    const mode_text = try runTextCommand(io, allocator, &.{ "gsettings", "get", "com.system76.CosmicTheme", "mode" });
    defer if (mode_text) |value| allocator.free(value);
    const accent_text = try runTextCommand(io, allocator, &.{ "gsettings", "get", "com.system76.CosmicTheme", "accent-color" });
    defer if (accent_text) |value| allocator.free(value);

    if (mode_text == null and accent_text == null) return null;
    const scheme = if (mode_text) |value|
        if (containsIgnoreCase(value, "dark")) Scheme.dark else Scheme.light
    else
        Scheme.light;
    const accent = if (accent_text) |value|
        accentFromName(unquote(value)) orelse parseCssHex(unquote(value)) orelse defaultAccent(scheme)
    else
        defaultAccent(scheme);

    return try buildPalette(allocator, .{
        .source = .cosmic,
        .scheme = scheme,
        .name = "COSMIC",
        .bg = switch (scheme) {
            .light => .{ .r = 0xf5, .g = 0xf4, .b = 0xf0 },
            .dark => .{ .r = 0x11, .g = 0x13, .b = 0x17 },
        },
        .panel = switch (scheme) {
            .light => .{ .r = 0xfe, .g = 0xfc, .b = 0xf8 },
            .dark => .{ .r = 0x1b, .g = 0x1f, .b = 0x25 },
        },
        .ink = switch (scheme) {
            .light => .{ .r = 0x17, .g = 0x1b, .b = 0x21 },
            .dark => .{ .r = 0xf0, .g = 0xf3, .b = 0xf8 },
        },
        .accent = accent,
    });
}

fn probeMacOs(io: std.Io, allocator: std.mem.Allocator) !?Palette {
    const style_text = try runTextCommand(io, allocator, &.{ "defaults", "read", "-g", "AppleInterfaceStyle" });
    defer if (style_text) |value| allocator.free(value);
    const accent_id = try runTextCommand(io, allocator, &.{ "defaults", "read", "-g", "AppleAccentColor" });
    defer if (accent_id) |value| allocator.free(value);
    const highlight = try runTextCommand(io, allocator, &.{ "defaults", "read", "-g", "AppleHighlightColor" });
    defer if (highlight) |value| allocator.free(value);

    const scheme: Scheme = if (style_text) |value|
        if (containsIgnoreCase(value, "dark")) .dark else .light
    else
        .light;

    var accent = defaultAccent(scheme);
    if (highlight) |value| {
        if (parseFloatTripletRgb(value)) |parsed| accent = parsed;
    } else if (accent_id) |value| {
        if (std.fmt.parseInt(i32, std.mem.trim(u8, value, " \t\r\n"), 10)) |parsed| {
            accent = accentFromApple(parsed) orelse accent;
        } else |_| {}
    }

    return try buildPalette(allocator, .{
        .source = .macos,
        .scheme = scheme,
        .name = "macOS",
        .bg = switch (scheme) {
            .light => .{ .r = 0xf3, .g = 0xf4, .b = 0xf6 },
            .dark => .{ .r = 0x12, .g = 0x12, .b = 0x14 },
        },
        .panel = switch (scheme) {
            .light => .{ .r = 0xfb, .g = 0xfb, .b = 0xfd },
            .dark => .{ .r = 0x1c, .g = 0x1c, .b = 0x1f },
        },
        .ink = switch (scheme) {
            .light => .{ .r = 0x17, .g = 0x1b, .b = 0x21 },
            .dark => .{ .r = 0xf2, .g = 0xf3, .b = 0xf6 },
        },
        .accent = accent,
    });
}

fn probeWindows(io: std.Io, allocator: std.mem.Allocator) !?Palette {
    const theme_text = try runTextCommand(io, allocator, &.{ "reg", "query", "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize", "/v", "AppsUseLightTheme" });
    defer if (theme_text) |value| allocator.free(value);
    const accent_text = try runTextCommand(io, allocator, &.{ "reg", "query", "HKCU\\Software\\Microsoft\\Windows\\DWM", "/v", "ColorizationColor" });
    defer if (accent_text) |value| allocator.free(value);

    if (theme_text == null and accent_text == null) return null;

    const scheme = if (theme_text) |value|
        if (containsIgnoreCase(value, "0x0")) Scheme.dark else Scheme.light
    else
        Scheme.light;

    const accent = if (accent_text) |value|
        parseRegistryHexRgb(value) orelse defaultAccent(scheme)
    else
        defaultAccent(scheme);

    return try buildPalette(allocator, .{
        .source = .windows,
        .scheme = scheme,
        .name = "Windows",
        .bg = switch (scheme) {
            .light => .{ .r = 0xf3, .g = 0xf4, .b = 0xf6 },
            .dark => .{ .r = 0x11, .g = 0x14, .b = 0x18 },
        },
        .panel = switch (scheme) {
            .light => .{ .r = 0xff, .g = 0xff, .b = 0xff },
            .dark => .{ .r = 0x1b, .g = 0x21, .b = 0x28 },
        },
        .ink = switch (scheme) {
            .light => .{ .r = 0x14, .g = 0x19, .b = 0x20 },
            .dark => .{ .r = 0xf1, .g = 0xf5, .b = 0xf9 },
        },
        .accent = accent,
    });
}

fn runTextCommand(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) !?[]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            allocator.free(result.stdout);
            return null;
        },
        else => {
            allocator.free(result.stdout);
            return null;
        },
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == result.stdout.len) return result.stdout;

    const out = try allocator.dupe(u8, trimmed);
    allocator.free(result.stdout);
    return out;
}

fn readFileIfExists(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);

    const stat = try file.stat(io);
    const len = std.math.cast(usize, stat.size) orelse return error.FileTooLarge;
    const buffer = try allocator.alloc(u8, len);
    _ = try file.readPositionalAll(io, buffer, 0);
    return buffer;
}

fn iniValue(contents: []const u8, section: []const u8, key: []const u8) ?[]const u8 {
    var current_section: []const u8 = "";
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == ';' or line[0] == '#') continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            current_section = line[1 .. line.len - 1];
            continue;
        }
        if (!std.mem.eql(u8, current_section, section)) continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const found_key = std.mem.trim(u8, line[0..equals], " \t");
        if (!std.mem.eql(u8, found_key, key)) continue;
        return std.mem.trim(u8, line[equals + 1 ..], " \t");
    }
    return null;
}

fn parseCommaRgb(value: []const u8) ?Rgb {
    var parts = std.mem.splitScalar(u8, value, ',');
    const r = parts.next() orelse return null;
    const g = parts.next() orelse return null;
    const b = parts.next() orelse return null;
    return .{
        .r = std.fmt.parseInt(u8, std.mem.trim(u8, r, " \t"), 10) catch return null,
        .g = std.fmt.parseInt(u8, std.mem.trim(u8, g, " \t"), 10) catch return null,
        .b = std.fmt.parseInt(u8, std.mem.trim(u8, b, " \t"), 10) catch return null,
    };
}

fn parseFloatTripletRgb(value: []const u8) ?Rgb {
    var parts = std.mem.tokenizeAny(u8, value, " \t\r\n");
    const rf = parts.next() orelse return null;
    const gf = parts.next() orelse return null;
    const bf = parts.next() orelse return null;
    return .{
        .r = floatUnitToByte(std.fmt.parseFloat(f32, rf) catch return null),
        .g = floatUnitToByte(std.fmt.parseFloat(f32, gf) catch return null),
        .b = floatUnitToByte(std.fmt.parseFloat(f32, bf) catch return null),
    };
}

fn parseCssHex(value: []const u8) ?Rgb {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    const hex = if (trimmed.len > 0 and trimmed[0] == '#') trimmed[1..] else trimmed;
    if (hex.len != 6) return null;
    const parsed = std.fmt.parseInt(u24, hex, 16) catch return null;
    return .{
        .r = @truncate(parsed >> 16),
        .g = @truncate(parsed >> 8),
        .b = @truncate(parsed),
    };
}

fn parseRegistryHexRgb(value: []const u8) ?Rgb {
    const token = lastToken(value) orelse return null;
    var cleaned = token;
    if (std.mem.startsWith(u8, cleaned, "0x")) cleaned = cleaned[2..];
    const parsed = std.fmt.parseInt(u32, cleaned, 16) catch return null;
    return .{
        .r = @truncate(parsed >> 16),
        .g = @truncate(parsed >> 8),
        .b = @truncate(parsed),
    };
}

fn hexColorAlloc(allocator: std.mem.Allocator, color: Rgb) ![]const u8 {
    return std.fmt.allocPrint(allocator, "#{X:0>2}{X:0>2}{X:0>2}", .{ color.r, color.g, color.b });
}

fn rgbaColorAlloc(allocator: std.mem.Allocator, color: Rgb, alpha: f32) ![]const u8 {
    return std.fmt.allocPrint(allocator, "rgba({d}, {d}, {d}, {d:.3})", .{ color.r, color.g, color.b, alpha });
}

fn sourceString(source: Source) []const u8 {
    return switch (source) {
        .fallback => "fallback",
        .gtk => "gtk",
        .qt => "qt",
        .cosmic => "cosmic",
        .macos => "macos",
        .windows => "windows",
    };
}

fn schemeString(scheme: Scheme) []const u8 {
    return switch (scheme) {
        .light => "light",
        .dark => "dark",
    };
}

fn defaultAccent(scheme: Scheme) Rgb {
    return switch (scheme) {
        .light => .{ .r = 61, .g = 114, .b = 145 },
        .dark => .{ .r = 127, .g = 186, .b = 214 },
    };
}

fn accentFromName(name: []const u8) ?Rgb {
    if (std.ascii.eqlIgnoreCase(name, "blue")) return .{ .r = 63, .g = 120, .b = 184 };
    if (std.ascii.eqlIgnoreCase(name, "teal")) return .{ .r = 30, .g = 140, .b = 132 };
    if (std.ascii.eqlIgnoreCase(name, "green")) return .{ .r = 58, .g = 133, .b = 71 };
    if (std.ascii.eqlIgnoreCase(name, "yellow")) return .{ .r = 180, .g = 132, .b = 36 };
    if (std.ascii.eqlIgnoreCase(name, "orange")) return .{ .r = 194, .g = 110, .b = 28 };
    if (std.ascii.eqlIgnoreCase(name, "red")) return .{ .r = 180, .g = 74, .b = 74 };
    if (std.ascii.eqlIgnoreCase(name, "pink")) return .{ .r = 178, .g = 82, .b = 126 };
    if (std.ascii.eqlIgnoreCase(name, "purple")) return .{ .r = 121, .g = 94, .b = 176 };
    if (std.ascii.eqlIgnoreCase(name, "slate")) return .{ .r = 86, .g = 104, .b = 124 };
    if (std.ascii.eqlIgnoreCase(name, "graphite")) return .{ .r = 92, .g = 104, .b = 116 };
    return null;
}

fn accentFromApple(id: i32) ?Rgb {
    return switch (id) {
        -1 => .{ .r = 104, .g = 112, .b = 120 },
        0 => .{ .r = 204, .g = 76, .b = 76 },
        1 => .{ .r = 205, .g = 109, .b = 42 },
        2 => .{ .r = 194, .g = 149, .b = 38 },
        3 => .{ .r = 58, .g = 140, .b = 83 },
        4 => .{ .r = 52, .g = 120, .b = 186 },
        5 => .{ .r = 125, .g = 93, .b = 180 },
        6 => .{ .r = 182, .g = 88, .b = 134 },
        else => null,
    };
}

fn firstNonEmpty(values: []const ?[]const u8) ?[]const u8 {
    for (values) |value| {
        if (value) |slice| if (slice.len != 0) return slice;
    }
    return null;
}

fn envVar(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

fn lastToken(value: []const u8) ?[]const u8 {
    var parts = std.mem.tokenizeAny(u8, value, " \t\r\n");
    var last: ?[]const u8 = null;
    while (parts.next()) |part| last = part;
    return last;
}

fn unquote(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len >= 2 and ((trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'') or
        (trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"')))
    {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
    }
    return false;
}

fn perceivedLightness(color: Rgb) f32 {
    const r = @as(f32, @floatFromInt(color.r)) / 255.0;
    const g = @as(f32, @floatFromInt(color.g)) / 255.0;
    const b = @as(f32, @floatFromInt(color.b)) / 255.0;
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

fn floatUnitToByte(value: f32) u8 {
    return @intFromFloat(std.math.clamp(value, 0.0, 1.0) * 255.0);
}

fn clamp01(value: f32, min_value: f32, max_value: f32) f32 {
    return std.math.clamp(value, min_value, max_value);
}

fn lerpChannel(a: u8, b: u8, t: f32) u8 {
    const af = @as(f32, @floatFromInt(a));
    const bf = @as(f32, @floatFromInt(b));
    return @intFromFloat(af + ((bf - af) * std.math.clamp(t, 0.0, 1.0)));
}

const Hsl = struct {
    h: f32,
    s: f32,
    l: f32,

    fn fromRgb(rgb: Rgb) Hsl {
        const r = @as(f32, @floatFromInt(rgb.r)) / 255.0;
        const g = @as(f32, @floatFromInt(rgb.g)) / 255.0;
        const b = @as(f32, @floatFromInt(rgb.b)) / 255.0;

        const maxv = @max(r, @max(g, b));
        const minv = @min(r, @min(g, b));
        const delta = maxv - minv;
        const l = (maxv + minv) / 2.0;

        if (delta == 0) return .{ .h = 0, .s = 0, .l = l };

        const s = delta / (1.0 - @abs((2.0 * l) - 1.0));
        const h = blk: {
            if (maxv == r) break :blk @mod((g - b) / delta, 6.0);
            if (maxv == g) break :blk ((b - r) / delta) + 2.0;
            break :blk ((r - g) / delta) + 4.0;
        };
        return .{
            .h = h * 60.0,
            .s = s,
            .l = l,
        };
    }

    fn toRgb(self: Hsl) Rgb {
        const c = (1.0 - @abs((2.0 * self.l) - 1.0)) * self.s;
        const hh = self.h / 60.0;
        const x = c * (1.0 - @abs(@mod(hh, 2.0) - 1.0));

        const tmp = if (hh < 1.0)
            [3]f32{ c, x, 0 }
        else if (hh < 2.0)
            [3]f32{ x, c, 0 }
        else if (hh < 3.0)
            [3]f32{ 0, c, x }
        else if (hh < 4.0)
            [3]f32{ 0, x, c }
        else if (hh < 5.0)
            [3]f32{ x, 0, c }
        else
            [3]f32{ c, 0, x };

        const m = self.l - (c / 2.0);
        return .{
            .r = floatUnitToByte(tmp[0] + m),
            .g = floatUnitToByte(tmp[1] + m),
            .b = floatUnitToByte(tmp[2] + m),
        };
    }
};

test "parseCommaRgb parses kde-style values" {
    const parsed = parseCommaRgb("239, 240, 241").?;
    try std.testing.expectEqual(@as(u8, 239), parsed.r);
    try std.testing.expectEqual(@as(u8, 240), parsed.g);
    try std.testing.expectEqual(@as(u8, 241), parsed.b);
}

test "buildPalette clamps accent and neutral ranges" {
    var palette = try buildPalette(std.testing.allocator, .{
        .source = .gtk,
        .scheme = .light,
        .name = "Test",
        .bg = .{ .r = 255, .g = 210, .b = 210 },
        .panel = .{ .r = 255, .g = 240, .b = 240 },
        .ink = .{ .r = 16, .g = 18, .b = 22 },
        .accent = .{ .r = 255, .g = 40, .b = 40 },
    });
    defer palette.deinit(std.testing.allocator);

    try std.testing.expect(perceivedLightness(palette.bg) > 0.9);
    try std.testing.expect(perceivedLightness(palette.ink) < 0.25);
    try std.testing.expect(Hsl.fromRgb(palette.accent).s >= 0.4);
}

test "jsonPaletteAlloc emits css-ready colors" {
    var palette = try fallbackPalette(std.testing.allocator, .fallback, .dark, "System");
    defer palette.deinit(std.testing.allocator);

    const json = try jsonPaletteAlloc(std.testing.allocator, &palette);
    defer {
        std.testing.allocator.free(json.colors.bg);
        std.testing.allocator.free(json.colors.page);
        std.testing.allocator.free(json.colors.panel);
        std.testing.allocator.free(json.colors.line);
        std.testing.allocator.free(json.colors.lineStrong);
        std.testing.allocator.free(json.colors.ink);
        std.testing.allocator.free(json.colors.muted);
        std.testing.allocator.free(json.colors.accent);
        std.testing.allocator.free(json.colors.accentStrong);
        std.testing.allocator.free(json.colors.accentSoft);
        std.testing.allocator.free(json.colors.glassBg);
        std.testing.allocator.free(json.colors.glassBorder);
    }

    try std.testing.expectEqualStrings("dark", json.scheme);
    try std.testing.expectEqualStrings("fallback", json.source);
    try std.testing.expect(std.mem.startsWith(u8, json.colors.bg, "#"));
    try std.testing.expect(std.mem.startsWith(u8, json.colors.accentSoft, "rgba("));
}
