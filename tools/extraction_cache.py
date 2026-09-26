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
OBJECT_VERSION = 4
MAX_OBJECT_BYTES = 1024 * 1024 * 1024
MAX_BATCHES = 100_000
LEAF_PRODUCER_FLAGS = ("build-obj", "-OReleaseFast", "-mcpu=baseline", "-fllvm", "-fstrip", "-lc")
LEAF_PRODUCER_SOURCES = ("src/lua/value_leaf_build.zig", "src/lua/runtime/value_leaf.zig")
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


def clang_identity(command, flags=()):
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
    result = {"tool": tool_identity(executable), "target": target, "version": version}
    if "-march=native" in flags:
        # -### resolves native CPUID without compiling a source file. A literal
        # '-march=native' cache key is unsafe when the cache moves hosts.
        command_line = [str(executable), "-###", "-march=native", "-x", "c",
                        "-c", "/dev/null", "-o", "/dev/null"]
        driver = subprocess.run(command_line, capture_output=True, text=True,
                                check=True, timeout=15).stderr
        cpus = re.findall(r'"-target-cpu" "([^"]+)"', driver)
        features = re.findall(r'"-target-feature" "([+-][A-Za-z0-9_.-]+)"', driver)
        if len(cpus) != 1 or not re.fullmatch(r"[A-Za-z0-9_.-]+", cpus[0]) or not features:
            raise ValueError("Clang native CPU/features unavailable")
        result["resolved_native"] = {"cpu": cpus[0], "features": features}
    return result


def zig_leaf_identity(command):
    resolved = shutil.which(command)
    if resolved is None:
        raise ValueError(f"Zig executable unavailable: {command}")
    executable = Path(resolved).resolve(strict=True)
    regular(executable)
    version = subprocess.run([str(executable), "version"], capture_output=True,
                             text=True, check=True, timeout=15).stdout.strip()
    environment = subprocess.run([str(executable), "env"], capture_output=True,
                                 text=True, check=True, timeout=15).stdout
    target = re.search(r'\.target = "([^"]+)"', environment)
    if not version or target is None:
        raise ValueError("Zig version/target unavailable")
    return {"tool_sha256": sha256(executable), "version": version,
            "target": target.group(1), "flags": list(LEAF_PRODUCER_FLAGS)}


def value_leaf_identity(llvm_dir, project_root, zig):
    bitcode = llvm_dir / "value_leaf.bc"
    regular(bitcode)
    sources = []
    for name in LEAF_PRODUCER_SOURCES:
        path = project_root / name
        regular(path)
        sources.append([name, sha256(path)])
    return {"bitcode": [bitcode.stat().st_size, sha256(bitcode)],
            "producer_sources": sources, "zig": zig_leaf_identity(zig)}


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
        if len(plans) > MAX_BATCHES:
            raise ValueError("Oversized LLVM batch plan")
    if not plans:
        raise ValueError("Empty LLVM batch plan")
    return plans


def object_identity(llvm_dir, clang, project_root, flags, zig="zig"):
    """Snapshot all build inputs; only object_entries() defines reuse keys."""
    if not flags or flags[-1] not in ("-O0", "-O1", "-O2"):
        raise ValueError("Missing LLVM program optimization mode")
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
        "clang": clang_identity(clang, flags),
        "flags": flags,
        "value_leaf": value_leaf_identity(llvm_dir, project_root, zig),
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
    if not isinstance(bitcode, list) or not bitcode or len(bitcode) > MAX_BATCHES:
        raise ValueError("Invalid cached object identity")
    return [f"module_batch_{index:06d}.o" for index in range(len(bitcode))] + ["program.o"]


def valid_digest_record(value):
    return (isinstance(value, list) and len(value) == 2 and
            type(value[0]) is int and 0 < value[0] <= MAX_OBJECT_BYTES and
            isinstance(value[1], str) and re.fullmatch(r"[0-9a-f]{64}", value[1]))


def object_entries(expected):
    """Map current link order to content keys independent of batch names/IDs.

    Function IDs remain embedded in the exact bitcode bytes. Neither metadata
    nor unrelated batches are Clang inputs. Only O1/O2 batches import the leaf
    producer; the program and O0 objects do not depend on that producer.
    """
    names = object_names(expected)
    flags = expected.get("flags")
    if (expected.get("version") != OBJECT_VERSION or
            not isinstance(expected.get("clang"), dict) or
            not isinstance(flags, list) or not flags or
            any(not isinstance(flag, str) for flag in flags) or
            flags[-1] not in ("-O0", "-O1", "-O2") or
            not valid_digest_record(expected.get("program_bc")) or
            not isinstance(expected.get("value_leaf"), dict) or
            not valid_digest_record(expected["value_leaf"].get("bitcode"))):
        raise ValueError("Invalid cached object identity")
    seen = set()
    for index, row in enumerate(expected["bitcode"] + [
            [flags[-1], "program.bc", *expected.get("program_bc", [])]]):
        if (not isinstance(row, list) or len(row) != 4 or
                row[0] not in ("-O0", "-O1", "-O2") or
                not isinstance(row[1], str) or row[1] in seen or
                (index < len(names) - 1 and not re.fullmatch(
                    r"module_batch_o[012]_[0-9]{6}\.bc", row[1])) or
                not valid_digest_record(row[2:])):
            raise ValueError("Invalid cached bitcode record")
        seen.add(row[1])
        identity = {"version": OBJECT_VERSION, "bitcode": row[2:],
                    "mode": row[0], "flags": flags[:-1], "clang": expected["clang"]}
        if index < len(names) - 1 and row[0] != "-O0":
            identity["value_leaf"] = expected["value_leaf"]
        yield names[index], identity


def record_object(path):
    regular(path)
    size = path.stat().st_size
    if not 0 < size <= MAX_OBJECT_BYTES:
        raise ValueError(f"Invalid native object size: {path}")
    return [size, sha256(path)]


def validated_object(root, expected):
    """Return the verified object digest, or None for an unusable entry."""
    if root.is_symlink() or not root.is_dir():
        return None
    record = read_marker(root / ".complete.json")
    if not isinstance(record, dict) or record.get("identity") != expected:
        return None
    if not valid_abi_provenance(
            record.get("provenance", {}).get("abi") if isinstance(
                record.get("provenance"), dict) else None):
        return None
    names = set()
    for path in root.iterdir():
        names.add(path.name)
        if len(names) > 2:
            return None
    if names != {"object.o", ".complete.json"}:
        return None
    expected_object = record.get("object")
    if not valid_digest_record(expected_object):
        return None
    actual = record_object(root / "object.o")
    return actual if actual == expected_object else None


def cached_object(root, expected):
    try:
        return validated_object(root, expected)
    except (OSError, ValueError, json.JSONDecodeError, TypeError):
        return None


def object_cache_path(root, expected):
    if root.is_symlink():
        raise ValueError(f"Unsafe extraction cache root: {root}")
    parent = root / "objects"
    key = hashlib.sha256(json.dumps(expected, sort_keys=True,
                                    separators=(",", ":")).encode()).hexdigest()
    return cache_path(parent, key)


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


def write_private_marker(path, value):
    raw = json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
    if len(raw.encode()) > MAX_MARKER_BYTES:
        raise ValueError("Oversized object cache identity marker")
    fd, temporary = tempfile.mkstemp(prefix=".object-state-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(raw)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def probe_objects(root, clang, project_root, llvm_dir, flags, zig="zig"):
    expected = object_identity(llvm_dir, clang, project_root, flags, zig)
    entries = list(object_entries(expected))
    # Preflight the whole output set before installing any cache link. A file
    # merely existing in the private build directory is never a verified hit.
    for name, _ in entries:
        destination = llvm_dir / name
        if destination.exists() or destination.is_symlink():
            raise ValueError(f"Refusing to replace LLVM object: {destination}")
    restored = []
    sources = []
    hits = []
    for name, identity in entries:
        source = object_cache_path(root, identity)
        asset = cached_object(source, identity)
        hits.append("1" if asset is not None else "0")
        if asset is not None:
            restored.append([name, *asset])
            sources.append((source / "object.o", llvm_dir / name))
    # Clang deletes compiled bitcode, so retain all input digests before any
    # child starts. Keep restored hashes too: publication cannot certify an
    # accidentally modified hardlink as newly compiled output.
    write_private_marker(llvm_dir / ".object-identity.json", {
        "identity": expected, "provenance": {"abi": abi_provenance(project_root)},
        "restored": restored,
    })
    for source, destination in sources:
        link_or_copy(source, destination)
    # This bounded bitmap is the sole authority for the build driver's skips.
    # The final bit belongs to program.o; preceding bits follow the fresh plan.
    (llvm_dir / ".object-hits").write_text("".join(hits) + "\n")
    print(f"Reusing verified native Lua objects: {len(restored)}/{len(entries)}", flush=True)
    return 0 if len(restored) == len(entries) else MISS


def remove_cache_entry(path):
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink(missing_ok=True)


def publish_object(root, source, identity, provenance, asset):
    destination = object_cache_path(root, identity)
    if cached_object(destination, identity) is not None:
        return destination
    temporary = Path(tempfile.mkdtemp(prefix=".part-", dir=destination.parent))
    stale = None
    try:
        link_or_copy(source, temporary / "object.o")
        if record_object(temporary / "object.o") != asset:
            raise ValueError("Native object changed during cache publication")
        marker = {"identity": identity, "provenance": provenance, "object": asset}
        (temporary / ".complete.json").write_text(
            json.dumps(marker, sort_keys=True, separators=(",", ":")) + "\n")
        if destination.exists() or destination.is_symlink():
            stale = destination.parent / (".stale-" + destination.name)
            remove_cache_entry(stale)
            destination.rename(stale)
        temporary.rename(destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    if stale is not None:
        remove_cache_entry(stale)
    return destination


def publish_objects(root, llvm_dir, clang, flags):
    # The LLVM directory and immutable cache are protected by the corpus lock.
    # No producer may mutate inputs while Clang is running or publishing.
    snapshot = read_marker(llvm_dir / ".object-identity.json")
    if not isinstance(snapshot, dict) or not isinstance(snapshot.get("identity"), dict):
        raise ValueError("Invalid object cache identity marker")
    expected = snapshot["identity"]
    entries = list(object_entries(expected))
    provenance = snapshot.get("provenance")
    if not isinstance(provenance, dict) or not valid_abi_provenance(provenance.get("abi")):
        raise ValueError("Invalid object cache ABI provenance")
    if expected.get("clang") != clang_identity(clang, flags) or expected.get("flags") != flags:
        raise ValueError("Clang native target or compile flags changed during compilation")
    for filename, key in (("batch-plan.tsv", "batch_plan_sha256"),
                          ("program.meta", "program_meta_sha256")):
        path = llvm_dir / filename
        regular(path)
        if sha256(path) != expected.get(key):
            raise ValueError(f"LLVM {filename} changed during compilation")
    leaf = llvm_dir / "value_leaf.bc"
    regular(leaf)
    if [leaf.stat().st_size, sha256(leaf)] != expected["value_leaf"]["bitcode"]:
        raise ValueError("Build-only value helper bitcode changed during compilation")
    restored = snapshot.get("restored")
    if not isinstance(restored, list) or len(restored) > len(entries):
        raise ValueError("Invalid restored native object inventory")
    assets = {name: record_object(llvm_dir / name) for name, _ in entries}
    seen = set()
    for row in restored:
        if (not isinstance(row, list) or len(row) != 3 or
                not isinstance(row[0], str) or row[0] not in assets or
                row[0] in seen or not valid_digest_record(row[1:])):
            raise ValueError("Invalid restored native object inventory")
        seen.add(row[0])
        if assets[row[0]] != row[1:]:
            raise ValueError("Restored native object changed during compilation")
    # Validate all producer outputs before changing any cache entry. Each
    # immutable object is independently atomic. Only a complete publication
    # prunes older keys, retaining exactly the latest build's object set.
    parent = object_cache_path(root, entries[0][1]).parent
    parent.mkdir(parents=True, exist_ok=True)
    prune_abandoned_partials(parent)
    current = set()
    for name, identity in entries:
        current.add(publish_object(root, llvm_dir / name, identity,
                                   provenance, assets[name]))
    for older in parent.iterdir():
        if older not in current and re.fullmatch(r"[0-9a-f]{64}", older.name):
            remove_cache_entry(older)
    print(f"Published verified native Lua objects: {len(entries)} outputs, "
          f"{len(current)} content keys", flush=True)
    return 0


def main(argv):
    if len(argv) == 8 and argv[1] in ("probe-objects", "publish-objects"):
        _, action, root, clang, project_root, llvm_dir, flags_raw, zig = argv
        flags = flags_raw.split(",")
        if not flags or any(not re.fullmatch(r"-[A-Za-z0-9-]+(?:=[A-Za-z0-9_.-]+)?", flag)
                            for flag in flags):
            raise ValueError("Invalid Clang compile flags")
        if action == "probe-objects":
            return probe_objects(Path(root), clang, Path(project_root),
                                 Path(llvm_dir), flags, zig)
        return publish_objects(Path(root), Path(llvm_dir), clang, flags)
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
