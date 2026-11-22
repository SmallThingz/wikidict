#!/usr/bin/env python3
"""Generate the two synthetic typed entries used by SectionLinkDeviceTest.

WIKBLB08 framing reuses the existing QA edge-fixture writer convention.
This is authored test data, not a Wiktionary source or release dictionary.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct


def vu(value):
    data = bytearray()
    while value >= 128:
        data.append((value & 127) | 128)
        value >>= 7
    return bytes(data) + bytes([value])


def fixed(value):
    raw = value.encode("utf-8")
    return struct.pack("<I", len(raw)) + raw


def items(values):
    return struct.pack("<I", len(values)) + b"".join(values)


def span(text, target=""):
    return bytes([1 if target else 0, 0, 0]) + b"".join(
        fixed(value) for value in (text, target, "", "", "", "")
    )


def block(text, target="", definition=True):
    return bytes([2 if definition else 0, 1 if definition else 0, 0]) + items([span(text, target)]) + b"\0" + fixed("") + fixed("") + b"\0"


def section(level, title, blocks):
    return bytes([level]) + fixed(title) + items(blocks)


def entry(sections):
    # Display title, sections, preamble, organizations, root sections, references, media.
    return b"DPR2" + items([]) + items(sections) + items([]) * 5


def fixture():
    source = entry([section(3, "Noun", [
        block("Read destination notes", "Anchor destination#Usage_notes"),
        block("Read missing anchor", "Anchor destination#No_such_section"),
        block("Read destination normally", "Anchor destination"),
    ])])
    destination = entry([
        section(3, "Noun", [
            block("Read destination notes again", "Anchor destination#Usage_notes"),
            block("Back to source", "Anchor source"),
        ] + [block(f"Earlier destination meaning {index}") for index in range(35)]),
        section(3, "Etymology 2", [block("PARENT SECTION REMAINS FOLDED", definition=False)]),
        section(4, "Usage notes", [block("DESTINATION USAGE BODY", definition=False)]),
    ])
    records = {"Anchor source": source, "Anchor destination": destination}
    return b"WIKBLB08\1en\0English\0" + b"".join(
        title.encode() + b"\0" + vu(len(payload)) + payload
        for title, payload in sorted(records.items())
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    target = Path(__file__).resolve().parents[1] / "app/src/androidTest/assets/section-navigation.wikblb"
    data = fixture()
    if args.check:
        if not target.is_file() or target.read_bytes() != data:
            raise SystemExit("Navigation fixture differs; regenerate it with this script")
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    print(json.dumps({"path": str(target), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(), "records": 2, "synthetic": True}))


if __name__ == "__main__":
    main()
