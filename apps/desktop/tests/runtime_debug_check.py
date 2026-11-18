#!/usr/bin/env python3
"""Exercise the real install helper without rebuilding Qt or running a GUI."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile


def elf_sections(path):
    data = path.read_bytes()
    if data[:4] != b"\x7fELF" or data[4] not in (1, 2) or data[5] not in (1, 2):
        raise RuntimeError("expected an ELF runtime")
    endian = "<" if data[5] == 1 else ">"
    wide = data[4] == 2
    header = struct.unpack_from(endian + ("HHIQQQIHHHHHH" if wide else "HHIIIIIHHHHHH"), data, 16)
    offset, size, count, names_index = header[5], header[10], header[11], header[12]
    section_format = endian + ("IIQQQQIIQQ" if wide else "IIIIIIIIII")
    if size != struct.calcsize(section_format) or not 0 < names_index < count:
        raise RuntimeError("unsupported ELF section table")
    rows = [struct.unpack_from(section_format, data, offset + i * size) for i in range(count)]
    names = rows[names_index]
    strings = data[names[4]:names[4] + names[5]]
    sections = {}
    for row in rows:
        name = strings[row[0]:].split(b"\0", 1)[0].decode()
        if name in sections:
            raise RuntimeError("duplicate ELF section name")
        sections[name] = (row, b"" if row[1] == 8 else data[row[4]:row[4] + row[5]])
    return sections, endian + ("qQ" if wide else "iI")


def debug_bytes(sections):
    return sum(row[5] for name, (row, _) in sections.items()
               if name.startswith((".debug_", ".zdebug_", ".stab")))


def verify_runtime_bytes(source, installed):
    original, dynamic_format = elf_sections(source)
    actual, actual_format = elf_sections(installed)
    if actual_format != dynamic_format:
        raise RuntimeError("ELF format changed")
    loaded = {name for name, (row, _) in original.items() if row[2] & 2}
    if loaded != {name for name, (row, _) in actual.items() if row[2] & 2}:
        raise RuntimeError("allocated ELF section membership changed")
    dynamic = original[".dynamic"][1]
    paths = [value for tag, value in struct.iter_unpack(dynamic_format, dynamic) if tag in (15, 29)]
    if len(paths) != 1:
        raise RuntimeError("expected one source runtime path")
    for name in loaded | ({".qtmetadata"} & original.keys()):
        before, data = original[name]
        after, transformed = actual[name]
        # File offsets and section-number references can change when debug-only
        # sections disappear; loaded addresses, sizes and contents must not.
        if any(before[index] != after[index] for index in (1, 2, 3, 5, 8, 9)):
            raise RuntimeError(f"allocated section contract changed: {name}")
        if name == ".dynstr":
            start = paths[0]
            old = data[start:].split(b"\0", 1)[0]
            new = b"$ORIGIN"
            if len(new) > len(old):
                raise RuntimeError("source lacks reserved runtime path space")
            data = data[:start] + new + b"\0" * (len(old) - len(new)) + data[start + len(old):]
        if data != transformed:
            raise RuntimeError(f"runtime section contents changed: {name}")
    return {"allocated_sections_preserved": len(loaded), "source_debug_bytes": debug_bytes(original),
            "installed_debug_bytes": debug_bytes(actual), "source_bytes": source.stat().st_size,
            "installed_bytes": installed.stat().st_size}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cmake", required=True, type=Path)
    parser.add_argument("--readelf", required=True, type=Path)
    parser.add_argument("--strip", required=True, type=Path)
    parser.add_argument("--runtime", required=True, type=Path)
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--tmp-root", required=True, type=Path)
    args = parser.parse_args()
    args.tmp_root.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix="runtime-debug-", dir=args.tmp_root.resolve()))
    source = args.runtime.resolve(strict=True)
    source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
    template = args.template.read_text()
    functions = {re.match(r"function\((\w+)", body).group(1): body
                 for body in re.findall(r"(?ms)^function\([^\n]*\).*?^endfunction\(\)", template)}
    helpers = "\n".join(functions[name] for name in ("_directory", "_elf", "_dynamic_symbols", "_copy_runtime"))
    env = dict(os.environ, LC_ALL="C")
    def quote(value):
        value = str(value)
        if "]=]" in value:
            raise RuntimeError("unsupported CMake fixture path")
        return "[=[" + value + "]=]"
    def stage(label, strip_debug, tool):
        prefix = root / label
        script = root / (label + ("-repeat" if prefix.exists() else "") + ".cmake")
        script.write_text("cmake_minimum_required(VERSION 3.21)\n"
                          + f"set(_stage {quote(prefix)})\nset(_readelf {quote(args.readelf)})\n"
                          + f"set(_strip {quote(tool)})\nset(_strip_debug {strip_debug})\n"
                          + helpers + "\n"
                          + f"_copy_runtime({quote(source)} lib/runtime.so [=[$ORIGIN]=] row)\n"
                          + f"file(WRITE {quote(prefix / 'row.json')} \"${{row}}\\n\")\n")
        result = subprocess.run([str(args.cmake), "-P", str(script)], env=env, capture_output=True, timeout=45)
        (script.with_suffix(".stdout")).write_bytes(result.stdout)
        (script.with_suffix(".stderr")).write_bytes(result.stderr)
        return prefix, result
    try:
        kept, result = stage("kept", "OFF", args.strip)
        if result.returncode:
            raise RuntimeError(result.stderr.decode(errors="replace"))
        kept_proof = verify_runtime_bytes(source, kept / "lib/runtime.so")
        if kept_proof["installed_debug_bytes"] != kept_proof["source_debug_bytes"]:
            raise RuntimeError("preserve-debug install discarded debug information")
        lean, result = stage("lean", "ON", args.strip)
        if result.returncode:
            raise RuntimeError(result.stderr.decode(errors="replace"))
        lean_proof = verify_runtime_bytes(source, lean / "lib/runtime.so")
        if lean_proof["installed_debug_bytes"]:
            raise RuntimeError("debug information remains after stripping")
        first = (lean / "row.json").read_bytes()
        _, result = stage("lean", "ON", args.strip)
        if result.returncode or (lean / "row.json").read_bytes() != first:
            raise RuntimeError("repeat install changed runtime bytes or metadata")
        _, result = stage("bad-tool", "ON", root / "missing-strip-tool")
        if result.returncode == 0 or b"Selected debug stripping tool is unavailable" not in result.stderr:
            raise RuntimeError("missing strip tool was silently accepted")
        if hashlib.sha256(source.read_bytes()).hexdigest() != source_hash:
            raise RuntimeError("original runtime changed")
        print(json.dumps({"passed": True, "preserved": kept_proof, "removed": lean_proof,
                          "repeat_install_exact": True, "missing_tool_refused": True,
                          "original_runtime_unchanged": True}, sort_keys=True))
    except Exception:
        print(f"Qualification failed; evidence retained at {root}")
        raise
    shutil.rmtree(root)


if __name__ == "__main__":
    main()
