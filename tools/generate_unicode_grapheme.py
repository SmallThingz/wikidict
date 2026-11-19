#!/usr/bin/env python3
"""Generate Unicode 16.0.0 terminal boundary marks; Python stdlib only.

Usage: generate_unicode_grapheme.py DATA_DIRECTORY OUTPUT_FILE
Builds and the reader never fetch Unicode data.
"""
import hashlib
from pathlib import Path
import sys
import unicodedata
from urllib.request import urlopen

VERSION = "16.0.0"
URL = f"https://www.unicode.org/Public/{VERSION}/ucd/auxiliary/GraphemeBreakProperty.txt"
SHA256 = "c29360bd6f7132811d701d29069541e827eb44bfc4c8fbde8c370d6982689dc1"


def main():
    directory, output = map(Path, sys.argv[1:])
    directory.mkdir(parents=True, exist_ok=True)
    source = directory / "GraphemeBreakProperty.txt"
    raw = source.read_bytes() if source.exists() else urlopen(URL, timeout=60).read()
    if hashlib.sha256(raw).hexdigest() != SHA256:
        raise ValueError("GraphemeBreakProperty.txt: SHA-256 mismatch")
    if not source.exists():
        source.write_bytes(raw)
    ranges = []
    for line in raw.decode("utf-8").splitlines():
        body = line.partition("#")[0].strip()
        if not body:
            continue
        span, prop = map(str.strip, body.split(";"))
        if prop in ("Extend", "SpacingMark"):
            parts = span.split("..")
            ranges.append((int(parts[0], 16), int(parts[-1], 16)))
    # Older terminal width tables can advance a mark that newer libc treats
    # as nonspacing. Keep established narrow combining marks and protocol
    # selectors at zero. This allowance is only used when wrapping pane prose.
    historic = unicodedata.ucd_3_2_0
    merged = []
    for low, high in sorted(ranges):
        for cp in range(low, high + 1):
            category = historic.category(chr(cp))
            if 0xfe00 <= cp <= 0xfe0f or 0xe0100 <= cp <= 0xe01ef or 0xe0020 <= cp <= 0xe007f:
                advance = 0
            elif category != 'Cn' and historic.east_asian_width(chr(cp)) in ('W', 'F'):
                advance = 2
            else:
                advance = int(category not in ('Mn', 'Me', 'Cf'))
            if merged and cp == merged[-1][1] + 1 and advance == merged[-1][2]:
                merged[-1] = (merged[-1][0], cp, advance)
            else:
                merged.append((cp, cp, advance))
    text = f"//! Generated Unicode {VERSION} Grapheme_Cluster_Break Extend/SpacingMark ranges.\n//! Source: {URL}\n//! SHA-256: {SHA256}\n//! Unicode data license: UNICODE-LICENSE.txt.\n"
    text += "const Range = struct { first: u21, last: u21, legacy_advance: u2 = 0 };\nconst ranges = [_]Range{\n"
    for low, high, advance in merged:
        extra = f", .legacy_advance = {advance}" if advance else ""
        text += f"    .{{ .first = 0x{low:x}, .last = 0x{high:x}{extra} }},\n"
    text += """};
fn markRange(cp: u21) ?Range {
    var low: usize = 0;
    var high: usize = ranges.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const range = ranges[mid];
        if (cp < range.first) high = mid else if (cp > range.last) low = mid + 1 else return range;
    }
    return null;
}
pub fn isExtendOrSpacingMark(cp: u21) bool {
    return markRange(cp) != null;
}
pub fn legacyMarkAdvance(cp: u21) u2 {
    return if (markRange(cp)) |r| r.legacy_advance else 0;
}
"""
    output.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
