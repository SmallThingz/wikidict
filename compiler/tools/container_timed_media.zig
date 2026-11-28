//! Build-only positive contribution to the authenticated normal Italian TMH module pair.
//! The Book owner supplies the same bound NS0 ordinary source, collector and style
//! profile used by workerFeatures. An unresolved occurrence cannot witness activation.
const std = @import("std");

const Sha = [32]u8;
fn hex(comptime s: []const u8) Sha {
    var result: Sha = undefined;
    _ = std.fmt.hexToBytes(&result, s) catch unreachable;
    return result;
}

fn hash(bytes: []const u8) Sha {
    var h: Sha = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &h, .{});
    return h;
}

const catalog_hash = hex("1ad0cc7926cecd86a14c992b32bd78e525807bcbabc3c2abab58e0be7d2c6e73");
const provider_hash = hex("f2264e1719cc159761413a5119871f23d46eb20011bbb3fc9907e7fb477a1463");
const namespace_hash = hex("8fc73407a5f932ba725c3339034fc0aa9894078272b08a5ae62566a834496996");
const selection_hash = hex("cdbdd6437688c1a305af6d41ce960f15c6ff587435beda9538851b62c046324a");
pub const Effect = enum { audio_player, video_player };
const Entry = struct { title: []const u8, effect: Effect };

pub const Catalog = struct {
    entries: [63]Entry,

    // Borrow immutable issued bytes for the Book lifetime. Checking their exact
    // digest authenticates every requested/canonical, SHA1, timestamp and MIME join.
    pub fn open(bytes: []const u8, provider: []const u8, namespace: Sha, selection: Sha) !Catalog {
        if (bytes.len > 16 * 1024 or provider.len != 2032387 or
            !std.mem.eql(u8, &namespace, &namespace_hash) or
            !std.mem.eql(u8, &selection, &selection_hash) or
            !std.mem.eql(u8, &hash(bytes), &catalog_hash) or
            !std.mem.eql(u8, &hash(provider), &provider_hash)) return error.InvalidTimedMediaAuthority;
        var result: Catalog = undefined;
        var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
        for (&result.entries) |*entry| {
            var fields = std.mem.splitScalar(u8, lines.next().?, '\t');
            const title = fields.next().?;
            _ = fields.next();
            _ = fields.next();
            _ = fields.next();
            const kind = fields.next().?;
            const effect: Effect = if (std.mem.eql(u8, kind, "AUDIO")) .audio_player else if (std.mem.eql(u8, kind, "VIDEO")) .video_player else return error.InvalidTimedMediaAuthority;
            entry.* = .{ .title = title, .effect = effect };
        }
        return result;
    }

    fn lookup(self: *const Catalog, title: []const u8) ?Effect {
        var lo: usize = 0;
        var hi: usize = self.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, title, self.entries[mid].title)) {
                .lt => hi = mid,
                .gt => lo = mid + 1,
                .eq => return self.entries[mid].effect,
            }
        }
        return null;
    }
};

pub const PageId = struct { title: []const u8, page_id: u64, revision_id: u64 };
pub const NormalParse = struct {
    // This digest must come from the issuer's authenticated, unfiltered Italian
    // action=parse(parser=parsoid,oldid=revision_id) transaction. Do not self-hash
    // untrusted JSON. Collector binding and any existing profile guards still apply.
    expected_sha256: Sha,
    response: []const u8,
};

const media_limit_category = "Pagine_in_cui_è_stato_raggiunto_il_limite_di_contenuti_multimediali";

const Category = struct {
    category: []const u8,
    sortkey: []const u8,
    hidden: ?bool = null,
    known: ?bool = null,
    missing: ?bool = null,
};
const Response = struct {
    parse: struct {
        title: []const u8,
        pageid: u64,
        revid: u64,
        categories: []const Category,
        parsewarnings: []const std.json.Value,
        jsconfigvars: struct { wgParsoidHtmlVersion: []const u8 },
        // Captured independently as oracles. Never use the module arrays to
        // infer a particular file's success.
        modules: ?[]const []const u8 = null,
        modulescripts: ?[]const []const u8 = null,
        modulestyles: ?[]const []const u8 = null,
    },
};

pub const Page = struct {
    expanded: []const u8,

    // A directly parsed literal document has no transclusion, extension,
    // attributes or other pipeline generating hidden media. Every possible file
    // costs at least one '['; count even lone brackets conservatively.
    pub fn fromLiteral(raw: []const u8, expanded: []const u8) ?Page {
        if (raw.len == 0 or raw.len > 1024 * 1024 or !std.mem.eql(u8, raw, expanded) or
            !literalText(raw) or
            !std.unicode.utf8ValidateSlice(raw) or std.mem.count(u8, raw, "[") > 5000) return null;
        return .{ .expanded = expanded };
    }

    // For a transclusion do not equate final visible links with all parser work.
    // Under the pinned nonempty, literal tracking message, an over-limit valid
    // media container forces this category into ParserOutput. This proof is about
    // the image budget only. Invalid/non-media occurrences still have no effect.
    pub fn fromNormal(a: std.mem.Allocator, id: PageId, expanded: []const u8, proof: NormalParse) !?Page {
        if (id.page_id == 0 or id.revision_id == 0 or expanded.len == 0 or expanded.len > 1024 * 1024 or
            proof.response.len > 128 * 1024 or !std.mem.eql(u8, &hash(proof.response), &proof.expected_sha256)) return null;
        const row = std.json.parseFromSlice(Response, a, proof.response, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        defer row.deinit();
        const p = row.value.parse;
        if (p.pageid != id.page_id or p.revid != id.revision_id or !std.mem.eql(u8, p.title, id.title) or
            p.parsewarnings.len != 0 or !std.mem.eql(u8, p.jsconfigvars.wgParsoidHtmlVersion, "2.8.0")) return null;
        for (p.categories) |item| if (std.mem.eql(u8, item.category, media_limit_category)) return null;
        return .{ .expanded = expanded };
    }

    // Offset belongs to this expansion. The scanner supplies the table/HTML
    // state at the operand. Every supported list prefix closes its inline tags
    // before the file. The file is always the last operation on this line.
    pub fn contribution(self: Page, catalog: *const Catalog, start: usize, in_table: bool, html_depth: usize) ?Effect {
        if (in_table or html_depth != 0 or start >= self.expanded.len) return null;
        const line_start = if (std.mem.lastIndexOfScalar(u8, self.expanded[0..start], '\n')) |n| n + 1 else 0;
        const prefix = self.expanded[line_start..start];
        if (!ordinaryPrefix(prefix) and !listPrefix(prefix)) return null;
        const tail = self.expanded[start..];
        const line = std.mem.trimEnd(u8, tail[0 .. std.mem.indexOfScalar(u8, tail, '\n') orelse tail.len], " \t\r");
        if (line.len < 10 or line.len > 512 or !std.mem.startsWith(u8, line, "[[File:") or
            !std.mem.endsWith(u8, line, "]]")) return null;
        return catalog.lookup(line[2 .. line.len - 2]);
    }
};

// A root paragraph can contain a closed italic pronunciation before the file.
// Keep all wiki delimiters out of its text and consume the entire suffix.
fn ordinaryPrefix(prefix: []const u8) bool {
    if (prefix.len == 0) return true;
    if (prefix.len > 256 or !std.ascii.isAlphabetic(prefix[0])) return false;
    const marker = "''(";
    const end = std.mem.indexOf(u8, prefix, marker) orelse prefix.len;
    for (prefix[0..end]) |ch| if (!std.ascii.isAlphabetic(ch) and ch != ' ' and ch != ':') return false;
    if (end == prefix.len) return true;
    const suffix = ")''&nbsp;: ";
    const body = prefix[end + marker.len ..];
    if (prefix[end - 1] != ' ' or body.len <= suffix.len or !std.mem.endsWith(u8, body, suffix)) return false;
    return phoneticText(body[0 .. body.len - suffix.len]);
}

fn phoneticText(text: []const u8) bool {
    if (text.len == 0) return false;
    const view = std.unicode.Utf8View.init(text) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |ch| switch (ch) {
        'a'...'z', '/', 0x00c0...0x02ff, 0x0300...0x036f => {},
        else => return false,
    };
    return true;
}

// Recognize prose and bare File: links only in the standalone literal budget proof.
fn literalText(raw: []const u8) bool {
    var pos: usize = 0;
    while (pos < raw.len) {
        if (std.mem.startsWith(u8, raw[pos..], "[[File:")) {
            const close = std.mem.indexOfPos(u8, raw, pos + 7, "]]") orelse return false;
            const title = raw[pos + 7 .. close];
            if (title.len == 0 or std.mem.indexOfAny(u8, title, "[]{}<>|&%#~_:\r\n") != null) return false;
            pos = close + 2;
        } else {
            const c = raw[pos];
            if (!std.ascii.isAlphabetic(c) and c != ' ' and c != '\n' and c != ':') return false;
            pos += 1;
        }
    }
    return true;
}

// A single SOL marker opens a list item (ul/li or dl/dd). Previous items are
// processed by the ordinary scanner, including their files and other effects.
fn listPrefix(prefix: []const u8) bool {
    if (prefix.len < 2 or prefix.len > 1024 or (prefix[0] != '*' and prefix[0] != ':')) return false;
    var rest = std.mem.cutPrefix(u8, prefix[1..], " ") orelse prefix[1..];

    // Parenthesized italic main-namespace label. Both the link and italic
    // element close before the next sibling. No namespace or interwiki syntax.
    if (std.mem.cutPrefix(u8, rest, "(''[[")) |link| {
        const bar = std.mem.indexOfScalar(u8, link, '|') orelse return false;
        if (!plainWords(link[0..bar])) return false;
        const label = link[bar + 1 ..];
        const end = std.mem.indexOf(u8, label, "]]'') ") orelse return false;
        if (!plainWords(label[0..end])) return false;
        rest = label[end + "]]'') ".len ..];
    }

    // An ordinary Help link can be followed by one or two closed IPA spans.
    // Match the issued style verbatim. Never advance through an arbitrary tag.
    if (std.mem.cutPrefix(u8, rest, "[[Aiuto:IPA|AFI]]: ")) |after_link| {
        rest = afterIpaSpan(after_link) orelse return false;
        if (std.mem.cutPrefix(u8, rest, ", ")) |second| rest = afterIpaSpan(second) orelse return false;
        rest = std.mem.cutPrefix(u8, rest, " ") orelse return false;
    }
    return rest.len > 0 and ordinaryPrefix(rest);
}

fn plainWords(text: []const u8) bool {
    if (text.len == 0 or text.len > 80 or text[0] == ' ' or text[text.len - 1] == ' ') return false;
    for (text) |c| if (!std.ascii.isAlphabetic(c) and c != ' ') return false;
    return true;
}

const ipa_open = "<span class=\"IPA\" style=\"font-family:'Segoe UI', 'Calibri', 'DejaVu Sans', 'Charis SIL', 'Doulos SIL', 'Gentium Plus', Gentium, GentiumAlt, 'Lucida Grande', 'Arial Unicode MS', sans-serif; font-size: 110%;\">";

fn afterIpaSpan(input: []const u8) ?[]const u8 {
    const body = std.mem.cutPrefix(u8, input, ipa_open) orelse return null;
    const end = std.mem.indexOf(u8, body, "</span>") orelse return null;
    if (!phoneticText(body[0..end])) return null;
    return body[end + "</span>".len ..];
}

// At this exact closing token Remex closes td, tr, implied tbody and table.
// Only td/tr are additional entries in the lexical stack. The caller processes
// all of the cell's operands normally, then pops two before its normal table
// pop. A named stack must match [table,tr,td]. No on-media depth correction.
pub fn impliedCellEnd(source: []const u8, close: usize, depth: usize, in_wiki_table: bool) bool {
    if (in_wiki_table or depth != 3 or close > 2048 or close >= source.len or
        !std.mem.startsWith(u8, source[close..], "</table>")) return false;
    const after = source[close + "</table>".len ..];
    if (after.len != 0 and after[0] != '\n') return false;
    var lines = std.mem.splitScalar(u8, source[0..close], '\n');
    const table = lines.next().?;
    if (!std.mem.eql(u8, table, "<table>") and
        !std.mem.eql(u8, table, "<table border=\"1\" cellspacing=\"0\" align=\"Right\" >")) return false;
    const row = lines.next() orelse return false;
    const trailing = lines.next() orelse return false;
    if (trailing.len != 0 or lines.next() != null) return false;
    var body = std.mem.cutPrefix(u8, row, "<tr><td>") orelse
        std.mem.cutPrefix(u8, row, "<tr><td align=\"center\" colspan=\"2\">") orelse return false;
    var files: usize = 0;
    while (std.mem.cutPrefix(u8, body, "[[File:")) |operand| {
        const bar = std.mem.indexOfScalar(u8, operand, '|') orelse return false;
        if (bar == 0 or bar > 200 or files == 8) return false;
        for (operand[0..bar]) |c| if (!std.ascii.isAlphanumeric(c) and c != ' ' and c != '.' and c != '-') return false;
        const width = operand[bar + 1 ..];
        const end = std.mem.indexOf(u8, width, "px]]") orelse return false;
        if (end == 0 or end > 5 or width[0] == '0') return false;
        for (width[0..end]) |c| if (!std.ascii.isDigit(c)) return false;
        files += 1;
        body = width[end + "px]]".len ..];
        if (body.len == 0) return true;
        body = std.mem.cutPrefix(u8, body, " ") orelse return false;
    }
    if (files == 0) return false;
    const label = std.mem.cutPrefix(u8, body, "<small><br/> ") orelse return false;
    return plainWords(std.mem.cutSuffix(u8, label, "<br></small>") orelse return false);
}
