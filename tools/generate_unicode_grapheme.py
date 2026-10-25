#!/usr/bin/env python3
"""Generate Unicode 16.0.0 terminal boundary marks; Python stdlib only.

Usage: generate_unicode_grapheme.py DATA_DIRECTORY OUTPUT_FILE
Builds and the reader never fetch Unicode data.
"""
import hashlib
from pathlib import Path
import sys
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
    merged = []
    for low, high in sorted(ranges):
        if merged and low <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(high, merged[-1][1]))
        else:
            merged.append((low, high))
    text = f"//! Generated Unicode {VERSION} Grapheme_Cluster_Break Extend/SpacingMark ranges.\n//! Source: {URL}\n//! SHA-256: {SHA256}\n//! Unicode data license: UNICODE-LICENSE.txt.\n"
    text += "const Range = struct { first: u21, last: u21 };\nconst ranges = [_]Range{\n"
    text += "".join("    .{ .first = 0x%x, .last = 0x%x },\n" % row for row in merged)
    text += """};
pub fn isExtendOrSpacingMark(cp: u21) bool {
    var low: usize = 0;
    var high: usize = ranges.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const range = ranges[mid];
        if (cp < range.first) high = mid else if (cp > range.last) low = mid + 1 else return true;
    }
    return false;
}
"""
    output.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
