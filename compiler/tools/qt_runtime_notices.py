#!/usr/bin/env python3
"""Collect the pinned Qt runtime notice inventory, never runtime/source trees."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re

MODULES = ("qtbase", "qtsvg", "qtmultimedia")
PATH = re.compile(r"^(qtbase|qtsvg|qtmultimedia)/(LICENSES|src)/[A-Za-z0-9_./+-]+$")


def checked_path(value):
    if not isinstance(value, str) or not PATH.fullmatch(value):
        raise ValueError(f"invalid notice path: {value!r}")
    if any(piece in ("", ".", "..") for piece in value.split("/")):
        raise ValueError(f"noncanonical notice path: {value!r}")
    return value


def source_file(root, relative):
    # Reject redirects, including intermediate links; only selected module bytes.
    current = root
    for piece in relative.parts:
        current = current / piece
        if current.is_symlink():
            raise ValueError(f"symlinked notice source: {current}")
    if not current.is_file():
        raise ValueError(f"missing referenced notice file: {current}")
    return current


def inventory(roots, selection):
    if not isinstance(selection, dict) or selection.get("schema") != "wikidict.qt-notice-selection.v1":
        raise ValueError("invalid Qt notice selection schema")
    if set(roots) != set(MODULES):
        raise ValueError("exactly the three runtime module roots are required")
    roots = {name: Path(roots[name]).resolve(strict=True) for name in MODULES}
    if any(not root.is_dir() for root in roots.values()):
        raise ValueError("module root is not a directory")
    if len(set(roots.values())) != len(MODULES):
        raise ValueError("module roots must be distinct")
    expected = {}
    for row in selection["files"]:
        name = checked_path(row["path"])
        if name in expected or not re.fullmatch(r"[0-9a-f]{64}", row["sha256"]):
            raise ValueError("duplicate path or invalid notice hash")
        if type(row["bytes"]) is not int or row["bytes"] < 0:
            raise ValueError("invalid notice size")
        expected[name] = row
    if not expected:
        raise ValueError("empty Qt notice selection")
    selected = set()
    for module, root in roots.items():
        directory = root / "LICENSES"
        if not directory.is_dir() or directory.is_symlink():
            raise ValueError(f"missing or symlinked LICENSES directory: {directory}")
        for parent, directories, files in os.walk(directory, followlinks=False):
            for name in directories:
                if (Path(parent) / name).is_symlink():
                    raise ValueError("symlinked LICENSES subdirectory")
            for name in files:
                selected.add(checked_path(module + "/" + (Path(parent) / name).relative_to(root).as_posix()))
    attribution_files = selection["attribution_files"]
    if not isinstance(attribution_files, list) or len(set(attribution_files)) != len(attribution_files):
        raise ValueError("invalid or duplicate attribution selection")
    for name in attribution_files:
        name = checked_path(name)
        if not name.endswith("/qt_attribution.json") or "/src/" not in name:
            raise ValueError("invalid attribution selection")
        module, relative = name.split("/", 1)
        root = roots[module]
        metadata = source_file(root, PurePosixPath(relative))
        selected.add(name)
        # Qt metadata contains literal controls. Parse permissively, copy verbatim.
        records = json.loads(metadata.read_text(encoding="utf-8"), strict=False)
        records = records if isinstance(records, list) else [records]
        if any(not isinstance(record, dict) for record in records):
            raise ValueError(f"invalid attribution records: {name}")
        for record in records:
            for field in ("LicenseFile", "LicenseFiles", "CopyrightFile", "CopyrightFiles"):
                references = record.get(field, [])
                references = [references] if isinstance(references, str) else references
                if not isinstance(references, list) or any(not isinstance(ref, str) or not ref for ref in references):
                    raise ValueError(f"invalid {field}: {name}")
                for reference in references:
                    if PurePosixPath(reference).is_absolute() or "\\" in reference:
                        raise ValueError(f"absolute or nonportable notice reference: {reference}")
                    # Relative '..' is used by real Qt metadata; permit it only
                    # within this module, then validate every source path component.
                    candidate = Path(os.path.normpath(metadata.parent / reference))
                    try:
                        ref_relative = candidate.relative_to(root)
                    except ValueError:
                        raise ValueError(f"notice reference escapes module: {reference}") from None
                    source_file(root, ref_relative)
                    selected.add(checked_path(module + "/" + ref_relative.as_posix()))
    if selected != set(expected):
        raise ValueError(f"notice selection drift: missing={sorted(set(expected) - selected)}, extra={sorted(selected - set(expected))}")
    rows, payload = [], {}
    # Retain the selection's stable module/file order as well as its bytes.
    for name in expected:
        module, relative = name.split("/", 1)
        source = source_file(roots[module], PurePosixPath(relative))
        data = source.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        if len(data) != expected[name]["bytes"] or digest != expected[name]["sha256"]:
            raise ValueError(f"notice source bytes drifted: {name}")
        payload[name] = data
        rows.append(dict(path=name, bytes=len(data), sha256=digest, source=str(source)))
    return dict(schema="wikidict.qt-notices.v1",
                scope="Unmodified license texts and attribution/copyright metadata from selected Qt source modules. Metadata may mention optional code; not runtime dependency evidence. Private source and patch provenance retained separately; no public distribution claim.",
                metadata_parser="Python JSON strict=False; source metadata bytes retained unchanged.",
                files=rows, missing_referenced_files=[]), payload


def generate(roots, selection, output):
    output = Path(output).absolute()
    if output.exists() or output.is_symlink():
        raise ValueError("output directory must be new")
    # Validate the complete inventory before any output is created.
    manifest, payload = inventory(roots, selection)
    output.mkdir(parents=True, exist_ok=False)
    for name, data in payload.items():
        target = output / "notices" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as stream:
            stream.write(data)
    destination = output / "manifest.json"
    with destination.open("x", encoding="utf-8") as stream:
        json.dump(manifest, stream, indent=2)
        stream.write("\n")
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for module in MODULES:
        parser.add_argument("--" + module, required=True, type=Path)
    parser.add_argument("--selection", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    try:
        selection = json.loads(args.selection.read_text(encoding="utf-8"))
        print(generate({name: getattr(args, name) for name in MODULES}, selection, args.output_dir))
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"Qt notice inventory: {error}\n")


if __name__ == "__main__":
    main()
