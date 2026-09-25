#!/usr/bin/env python3
"""Verified immutable extraction and Clang-object assets for corpus builds.

The caller must supply both SHA256 values from its already verified staged
dump marker. This helper does not reread the multigigabyte dump or stream index.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

VERSION = 1
# Keep this equal to the extractor argv in bundle_build.zig. Changing the
# extraction mode also changes the cache identity, even with the same binary.
EXTRACTOR_ARGS = ("--page-index",)
FILES = (
    "manifest.jsonl", "module-redirects.tsv", "page-index.tsv",
    "dump-streams.tsv", "page-title-index.bin", "lua-usage.tsv",
    "template-source.bin", "template-source.idx", "compiler-inputs.ready",
)
TREE = "modules"
MISS = 3
MAX_MARKER_BYTES = 64 * 1024 * 1024
OBJECT_VERSION = 2
LEGACY_OBJECT_VERSION = 1
ABI_FILES = (
    "src/lua/abi/globals.zig",
    "src/lua/abi/static_fields.zig",
    "src/lua/runtime/llvm_abi.zig",
    "src/lua/runtime/static_literal_format.zig",
    "src/lua/program_metadata.zig",
)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def regular(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"Expected regular extraction asset: {path}")


def read_marker(path):
    regular(path)
    with path.open("rb") as stream:
        raw = stream.read(MAX_MARKER_BYTES + 1)
    if len(raw) > MAX_MARKER_BYTES:
        raise ValueError(f"Oversized extraction cache marker: {path}")
    return json.loads(raw)


def link_or_copy(source, destination):
    try:
        os.link(source, destination)
    except OSError:
        shutil.copyfile(source, destination)


def tool_identity(executable):
    """Digest the emitted extractor and its resolved dynamic libraries."""
    regular(executable)
    result = subprocess.run(["ldd", str(executable)], capture_output=True,
                            text=True, check=True, timeout=30)
    libraries = set()
    for line in result.stdout.splitlines():
        match = re.search(r"(?:=>\s*)?(/[^\s]+)\s*\(", line)
        if match:
            libraries.add(Path(match.group(1)))
        elif "not found" in line:
            raise ValueError(f"Unresolved extractor library: {line}")
    return {
        "extractor_sha256": sha256(executable),
        "libraries": [[str(path), sha256(path)] for path in sorted(libraries)],
    }


def identity(executable, dump_sha256, index_sha256):
    if not all(re.fullmatch(r"[0-9a-fA-F]{64}", value)
               for value in (dump_sha256, index_sha256)):
        raise ValueError("Invalid verified staged input digest")
    return {"version": VERSION, "extractor_args": list(EXTRACTOR_ARGS),
            "dump_sha256": dump_sha256.lower(),
            "index_sha256": index_sha256.lower(),
            "tool": tool_identity(executable)}


def cache_path(root, key):
    if root.is_symlink():
        raise ValueError(f"Unsafe extraction cache root: {root}")
    return root / key


def walk_assets(root):
    """Return every allowed regular file, including each module source."""
    names = list(FILES)
    module_root = root / TREE
    if module_root.is_symlink() or not module_root.is_dir():
        raise ValueError("Missing regular modules directory")
    for path in module_root.rglob("*"):
        if path.is_symlink():
            raise ValueError(f"Unsafe extraction asset: {path}")
        if path.is_file():
            names.append(path.relative_to(root).as_posix())
            if len(names) > 1_000_000:
                raise ValueError("Oversized extraction asset inventory")
        elif not path.is_dir():
            raise ValueError(f"Unsupported extraction asset: {path}")
    names.sort()
    for name in names:
        regular(root / name)
    return names


def record_assets(root):
    return [[name, (root / name).stat().st_size, sha256(root / name)]
            for name in walk_assets(root)]


def validate(root, expected):
    marker = root / ".complete.json"
    record = read_marker(marker)
    if not isinstance(record, dict):
        return False
    if record.get("identity") != expected:
        return False
    assets = record.get("assets")
    if not isinstance(assets, list) or assets != record_assets(root):
        return False
    return True


def probe(root, expected, output):
    key = hashlib.sha256(json.dumps(expected, sort_keys=True).encode()).hexdigest()
    source = cache_path(root, key)
    if not source.exists():
        return MISS
    try:
        if source.is_symlink() or not validate(source, expected):
            return MISS
    except (OSError, ValueError, json.JSONDecodeError, TypeError):
        return MISS
    # Validation is complete before the first link is installed. The cache is
    # immutable and the top-level build lock excludes concurrent replacement.
    for name in (TREE, *FILES):
        os.symlink((source / name).resolve(strict=True), output / name,
                   target_is_directory=name == TREE)
    print(f"Reusing verified extraction assets: {source}", flush=True)
    return 0


def publish(root, expected, source):
    key = hashlib.sha256(json.dumps(expected, sort_keys=True).encode()).hexdigest()
    destination = cache_path(root, key)
    root.mkdir(parents=True, exist_ok=True)
    prune_abandoned_partials(root)
    # Refuse symlinks in the producer tree before copytree can follow one.
    walk_assets(source)
    if destination.exists() or destination.is_symlink():
        try:
            if not destination.is_symlink() and validate(destination, expected):
                prune_old_generations(root, destination)
                return 0
        except (OSError, ValueError, json.JSONDecodeError, TypeError):
            pass
        # A corrupt directory remains unavailable until the new one is ready.
        stale = root / (".stale-" + key)
        if stale.exists() or stale.is_symlink():
            if stale.is_dir() and not stale.is_symlink():
                shutil.rmtree(stale)
            else:
                stale.unlink()
        destination.rename(stale)
    else:
        stale = None
    temporary = Path(tempfile.mkdtemp(prefix=".part-", dir=root))
    try:
        for name in FILES:
            original = source / name
            regular(original)
            link_or_copy(original, temporary / name)
        module_source = source / TREE
        if module_source.is_symlink() or not module_source.is_dir():
            raise ValueError("Missing regular modules directory")
        shutil.copytree(module_source, temporary / TREE, symlinks=False,
                        copy_function=link_or_copy)
        assets = record_assets(temporary)
        marker = {"identity": expected, "assets": assets}
        (temporary / ".complete.json").write_text(
            json.dumps(marker, sort_keys=True, separators=(",", ":")) + "\n")
        temporary.rename(destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    if stale is not None:
        if stale.is_dir() and not stale.is_symlink():
            shutil.rmtree(stale)
        else:
            stale.unlink()
    # The corpus resource lock admits one build at a time.
    prune_old_generations(root, destination)
    print(f"Published verified extraction assets: {destination}", flush=True)
    return 0


def clang_identity(command):
    resolved = shutil.which(command)
    if resolved is None:
        raise ValueError(f"Clang executable unavailable: {command}")
    executable = Path(resolved).resolve(strict=True)
    target = subprocess.run([str(executable), "-dumpmachine"], capture_output=True,
                            text=True, check=True, timeout=15).stdout.strip()
    version = subprocess.run([str(executable), "--version"], capture_output=True,
                             text=True, check=True, timeout=15).stdout.splitlines()[0]
    if not target or not version:
        raise ValueError("Clang target/version unavailable")
    return {"tool": tool_identity(executable), "target": target, "version": version}


def read_object_plan(llvm_dir):
    plan_path = llvm_dir / "batch-plan.tsv"
    regular(plan_path)
    if plan_path.stat().st_size > 64 * 1024 * 1024:
        raise ValueError("Oversized LLVM batch plan")
    plans = []
    seen = set()
    for line in plan_path.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 6 or fields[0] not in ("-O0", "-O1", "-O2"):
            raise ValueError("Invalid LLVM batch plan row")
        name = fields[1]
        if not re.fullmatch(r"module_batch_o[012]_[0-9]{6}\.bc", name) or name in seen:
            raise ValueError("Unsafe or repeated LLVM batch path")
        seen.add(name)
        try:
            count, first, last, source_bytes = map(int, fields[2:])
        except ValueError:
            raise ValueError("Invalid LLVM batch plan integers") from None
        if count <= 0 or first < 0 or last < first or source_bytes < 0:
            raise ValueError("Invalid LLVM batch plan bounds")
        plans.append(fields)
        if len(plans) > 100_000:
            raise ValueError("Oversized LLVM batch plan")
    if not plans:
        raise ValueError("Empty LLVM batch plan")
    return plans


def object_identity(llvm_dir, clang, project_root, flags):
    plans = read_object_plan(llvm_dir)
    bitcode = []
    for mode, name, *_ in plans:
        path = llvm_dir / name
        regular(path)
        bitcode.append([mode, name, path.stat().st_size, sha256(path)])
    program_bc = llvm_dir / "program.bc"
    program_meta = llvm_dir / "program.meta"
    regular(program_bc)
    regular(program_meta)
    return {
        "version": OBJECT_VERSION,
        "batch_plan_sha256": sha256(llvm_dir / "batch-plan.tsv"),
        "program_meta_sha256": sha256(program_meta),
        "bitcode": bitcode,
        "program_bc": [program_bc.stat().st_size, sha256(program_bc)],
        "clang": clang_identity(clang),
        "flags": flags,
    }


def abi_provenance(project_root):
    """Record runtime ABI source versions without changing Clang object identity.

    Clang consumes emitted bitcode, not Zig runtime source. Fresh LLVM emission
    and the worker's ABI checks remain responsible for compatibility.
    """
    result = []
    for name in ABI_FILES:
        path = project_root / name
        regular(path)
        result.append([name, sha256(path)])
    return result


def valid_abi_provenance(value):
    return (isinstance(value, list) and len(value) == len(ABI_FILES) and
            all(isinstance(row, list) and len(row) == 2 and
                row[0] == name and isinstance(row[1], str) and
                re.fullmatch(r"[0-9a-f]{64}", row[1])
                for row, name in zip(value, ABI_FILES)))


def object_names(expected):
    bitcode = expected.get("bitcode")
    if not isinstance(bitcode, list) or not bitcode or len(bitcode) > 100_000:
        raise ValueError("Invalid cached object identity")
    return [f"module_batch_{index:06d}.o" for index in range(len(bitcode))] + ["program.o"]


def record_named_assets(root, names):
    records = []
    for name in names:
        path = root / name
        regular(path)
        records.append([name, path.stat().st_size, sha256(path)])
    return records


def validate_objects(root, expected):
    marker = root / ".complete.json"
    record = read_marker(marker)
    if not isinstance(record, dict):
        return False
    if record.get("identity") != expected:
        return False
    if expected.get("version") == OBJECT_VERSION and not valid_abi_provenance(
            record.get("provenance", {}).get("abi") if isinstance(
                record.get("provenance"), dict) else None):
        return False
    names = object_names(expected)
    if set(path.name for path in root.iterdir()) != set(names + [".complete.json"]):
        return False
    return record.get("assets") == record_named_assets(root, names)


def object_cache_path(root, expected):
    if root.is_symlink():
        raise ValueError(f"Unsafe extraction cache root: {root}")
    parent = root / "objects"
    key = hashlib.sha256(json.dumps(expected, sort_keys=True,
                                    separators=(",", ":")).encode()).hexdigest()
    return cache_path(parent, key)


def compatible_legacy_objects(root, expected):
    """Find a fully verified v1 generation differing only in ABI provenance.

    Its old key still includes ABI hashes. Never rename or trust that key as a
    v2 key: compare every other identity field and rehash every object first.
    """
    parent = root / "objects"
    if parent.is_symlink() or not parent.is_dir():
        return None
    keys = set(expected) | {"abi"}
    for candidate in parent.iterdir():
        if not re.fullmatch(r"[0-9a-f]{64}", candidate.name) or candidate.is_symlink():
            continue
        try:
            marker = candidate / ".complete.json"
            record = read_marker(marker)
            if not isinstance(record, dict):
                continue
            legacy = record.get("identity")
            if not isinstance(legacy, dict) or set(legacy) != keys or \
                    legacy.get("version") != LEGACY_OBJECT_VERSION or \
                    not valid_abi_provenance(legacy.get("abi")):
                continue
            if any(legacy[key] != value for key, value in expected.items()
                   if key != "version"):
                continue
            if object_cache_path(root, legacy) != candidate:
                continue
            if validate_objects(candidate, legacy):
                return candidate
        except (OSError, ValueError, json.JSONDecodeError, TypeError):
            continue
    return None


def prune_abandoned_partials(parent):
    """The controller holds the corpus lock; a day-old temp is not publishing."""
    now = time.time()
    for path in parent.iterdir():
        if not (path.name.startswith(".part-") or
                re.fullmatch(r"\.stale-[0-9a-f]{64}", path.name)) or path.is_symlink():
            continue
        if path.is_dir() and now - path.stat().st_mtime > 24 * 3600:
            shutil.rmtree(path)


def prune_old_generations(parent, current):
    """Keep only the currently validated complete generation per stage."""
    for older in parent.iterdir():
        if older == current or not re.fullmatch(r"[0-9a-f]{64}", older.name):
            continue
        if older.is_symlink():
            older.unlink()
        elif older.is_dir():
            shutil.rmtree(older)


def probe_objects(root, clang, project_root, llvm_dir, flags):
    expected = object_identity(llvm_dir, clang, project_root, flags)
    provenance = {"abi": abi_provenance(project_root)}
    identity_path = llvm_dir / ".object-identity.json"
    temporary = identity_path.with_suffix(".part")
    temporary.write_text(json.dumps({"identity": expected, "provenance": provenance}, sort_keys=True,
                                    separators=(",", ":")) + "\n")
    os.replace(temporary, identity_path)
    source = object_cache_path(root, expected)
    valid_current = False
    if source.exists() and not source.is_symlink():
        try:
            valid_current = validate_objects(source, expected)
        except (OSError, ValueError, json.JSONDecodeError, TypeError):
            pass
    if not valid_current:
        source = compatible_legacy_objects(root, expected)
        if source is None:
            return MISS
    for name in object_names(expected):
        destination = llvm_dir / name
        if destination.exists() or destination.is_symlink():
            raise ValueError(f"Refusing to replace LLVM object: {destination}")
        link_or_copy(source / name, destination)
    print(f"Reusing verified native Lua objects: {source}", flush=True)
    return 0


def publish_objects(root, llvm_dir):
    # The LLVM directory is private to one locked build. Clang deletes input
    # bitcode after compilation, so probe records its digests before any Clang
    # child starts; no producer may mutate inputs until publication finishes.
    identity_path = llvm_dir / ".object-identity.json"
    snapshot = read_marker(identity_path)
    if not isinstance(snapshot, dict):
        raise ValueError("Invalid object cache identity marker")
    expected = snapshot.get("identity")
    provenance = snapshot.get("provenance")
    if not isinstance(expected, dict) or expected.get("version") != OBJECT_VERSION:
        raise ValueError("Invalid object cache identity marker")
    if not isinstance(provenance, dict) or not valid_abi_provenance(provenance.get("abi")):
        raise ValueError("Invalid object cache ABI provenance")
    if sha256(llvm_dir / "batch-plan.tsv") != expected.get("batch_plan_sha256"):
        raise ValueError("LLVM batch plan changed during compilation")
    if sha256(llvm_dir / "program.meta") != expected.get("program_meta_sha256"):
        raise ValueError("LLVM program metadata changed during compilation")
    names = object_names(expected)
    parent = root / "objects"
    destination = object_cache_path(root, expected)
    parent.mkdir(parents=True, exist_ok=True)
    prune_abandoned_partials(parent)
    if destination.exists() or destination.is_symlink():
        try:
            if not destination.is_symlink() and validate_objects(destination, expected):
                prune_old_generations(parent, destination)
                return 0
        except (OSError, ValueError, json.JSONDecodeError, TypeError):
            pass
        stale = parent / (".stale-" + destination.name)
        if stale.exists() or stale.is_symlink():
            if stale.is_dir() and not stale.is_symlink():
                shutil.rmtree(stale)
            else:
                stale.unlink()
        destination.rename(stale)
    else:
        stale = None
    temporary = Path(tempfile.mkdtemp(prefix=".part-", dir=parent))
    try:
        for name in names:
            source = llvm_dir / name
            regular(source)
            link_or_copy(source, temporary / name)
        marker = {"identity": expected, "provenance": provenance,
                  "assets": record_named_assets(temporary, names)}
        (temporary / ".complete.json").write_text(
            json.dumps(marker, sort_keys=True, separators=(",", ":")) + "\n")
        temporary.rename(destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    if stale is not None:
        if stale.is_dir() and not stale.is_symlink():
            shutil.rmtree(stale)
        else:
            stale.unlink()
    prune_old_generations(parent, destination)
    print(f"Published verified native Lua objects: {destination}", flush=True)
    return 0


def main(argv):
    if len(argv) == 7 and argv[1] in ("probe-objects", "publish-objects"):
        _, action, root, clang, project_root, llvm_dir, flags_raw = argv
        flags = flags_raw.split(",")
        if not flags or any(not re.fullmatch(r"-[A-Za-z0-9-]+", flag)
                            for flag in flags):
            raise ValueError("Invalid Clang compile flags")
        if action == "probe-objects":
            return probe_objects(Path(root), clang, Path(project_root),
                                 Path(llvm_dir), flags)
        return publish_objects(Path(root), Path(llvm_dir))
    if len(argv) != 7 or argv[1] not in ("probe", "publish"):
        raise SystemExit("usage: extraction_cache.py probe|publish CACHE_ROOT EXTRACTOR DUMP_SHA256 INDEX_SHA256 EXPANDER_ROOT")
    _, action, root, executable, dump_sha256, index_sha256, output = argv
    expected = identity(Path(executable), dump_sha256, index_sha256)
    if action == "probe":
        return probe(Path(root), expected, Path(output))
    return publish(Path(root), expected, Path(output))


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (OSError, ValueError, json.JSONDecodeError,
            subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"extraction cache: {error}", file=sys.stderr)
        sys.exit(1)
