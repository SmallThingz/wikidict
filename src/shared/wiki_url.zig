//! One maintained build-time URL constructor used by ordinary Lua URI calls
//! and source-owned native anchor issuance. Callers supply captured site facts;
//! this module introduces no edition/server/path default.
const std = @import("std");
pub const SiteUrlConfig = struct { server: []const u8, script: []const u8, article_path: []const u8 };
pub const WikiUrlKind = enum { local, full, canonical };

pub fn appendPercentByte(out: *std.ArrayList(u8), a: std.mem.Allocator, byte: u8) !void {
    const hex = "0123456789ABCDEF";
    try out.append(a, '%');
    try out.append(a, hex[byte >> 4]);
    try out.append(a, hex[byte & 0xf]);
}

pub fn appendWikiEncoded(out: *std.ArrayList(u8), a: std.mem.Allocator, source: []const u8) !void {
    for (source) |c| {
        const safe = std.ascii.isAlphanumeric(c) or c == '!' or c == '$' or c == '(' or c == ')' or c == '*' or c == ',' or c == '.' or c == '/' or c == ':' or c == ';' or c == '@' or c == '~' or c == '_' or c == '-';
        if (safe) try out.append(a, c) else if (c == ' ') try out.append(a, '_') else try appendPercentByte(out, a, c);
    }
}

pub fn wikiEncodeAlloc(a: std.mem.Allocator, source: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try appendWikiEncoded(&out, a, source);
    return out.toOwnedSlice(a);
}

pub fn appendQueryEncoded(out: *std.ArrayList(u8), a: std.mem.Allocator, source: []const u8) !void {
    for (source) |c| {
        const safe = std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '~' or c == '-';
        if (safe) try out.append(a, c) else if (c == ' ') try out.append(a, '+') else try appendPercentByte(out, a, c);
    }
}

pub fn appendAmpEscaped(out: *std.ArrayList(u8), a: std.mem.Allocator, source: []const u8, escaped: bool) !void {
    if (!escaped) return out.appendSlice(a, source);
    var start: usize = 0;
    for (source, 0..) |c, i| if (c == '&') {
        try out.appendSlice(a, source[start..i]);
        try out.appendSlice(a, "&amp;");
        start = i + 1;
    };
    try out.appendSlice(a, source[start..]);
}

pub fn buildSiteWikiUrlRawQuery(a: std.mem.Allocator, raw_title: []const u8, query: ?[]const u8, kind: WikiUrlKind, escaped: bool, proto_override: ?[]const u8, site: SiteUrlConfig) ![]const u8 {
    const title = std.mem.trim(u8, raw_title, " \t\r\n");
    const hash = std.mem.indexOfScalar(u8, title, '#');
    const base_title = if (hash) |i| title[0..i] else title;
    const fragment = if (hash) |i| title[i + 1 ..] else "";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const relative_server = if (std.mem.indexOf(u8, site.server, "://")) |at| site.server[at + 1 ..] else site.server;
    switch (kind) {
        .local => {},
        .full => {
            if (proto_override) |proto| {
                if (std.ascii.eqlIgnoreCase(proto, "http") or std.ascii.eqlIgnoreCase(proto, "https")) {
                    try out.appendSlice(a, proto);
                    try out.append(a, ':');
                    try out.appendSlice(a, relative_server);
                } else {
                    try out.appendSlice(a, site.server);
                }
            } else try out.appendSlice(a, site.server);
        },
        .canonical => {
            if (std.mem.startsWith(u8, site.server, "//")) try out.appendSlice(a, "https:");
            try out.appendSlice(a, site.server);
        },
    }
    if (query) |q| {
        try out.appendSlice(a, site.script);
        try out.appendSlice(a, "?title=");
        try appendWikiEncoded(&out, a, base_title);
        if (q.len != 0) {
            try out.appendSlice(a, if (escaped) "&amp;" else "&");
            try appendAmpEscaped(&out, a, q, escaped);
        }
    } else {
        const marker = std.mem.indexOf(u8, site.article_path, "$1") orelse return error.InvalidSiteInfoSnapshot;
        try appendAmpEscaped(&out, a, site.article_path[0..marker], escaped);
        try appendWikiEncoded(&out, a, base_title);
        try appendAmpEscaped(&out, a, site.article_path[marker + 2 ..], escaped);
    }
    if (fragment.len != 0) {
        try out.append(a, '#');
        try appendWikiEncoded(&out, a, fragment);
    }
    return out.toOwnedSlice(a);
}
