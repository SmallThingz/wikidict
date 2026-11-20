#!/usr/bin/env python3
"""Verified immutable extraction and Clang-object assets for corpus builds.

The caller must supply both SHA256 values from its already verified staged
dump marker. This helper does not reread the multigigabyte dump or stream index.
"""
import hashlib
import errno
import io
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

VERSION = 1
EXTRACTION_IDENTITY_VERSION = 4
# Keep this equal to the extractor argv in bundle_build.zig. Changing the
# extraction mode also changes the cache identity, even with the same binary.
EXTRACTOR_ARGS = ("--page-index",)
FILES = (
    "manifest.jsonl", "module-redirects.tsv", "page-index.tsv",
    "dump-streams.tsv", "page-title-index.bin", "lua-usage.tsv",
    "template-source.bin", "template-source.idx", "compiler-inputs.ready", "extraction-source.json",
)
TREE = "modules"
MISS = 3
MAX_MARKER_BYTES = 64 * 1024 * 1024
OBJECT_VERSION = 4
MAX_OBJECT_BYTES = 1024 * 1024 * 1024
MAX_BATCHES = 100_000
# Semantic settings of the build-graph leaf producer, retained as a conservative
# cache discriminator. These are not a recorded invocation of the live Zig tool.
LEAF_CONTRACT_FLAGS = ("build-obj", "-Ofast", "-mcpu=baseline", "-fllvm", "-fstrip", "-lc")
# Observed live files are not a transitive source manifest for cached bitcode.
LIVE_LEAF_SOURCE_PATHS = ("src/lua/value_leaf_build.zig", "src/lua/runtime/value_leaf.zig")
ABI_FILES = (
    "src/lua/abi/globals.zig",
    "src/lua/abi/static_fields.zig",
    "src/lua/runtime/llvm_abi.zig",
    "src/lua/runtime/static_literal_format.zig",
    "src/lua/program_metadata.zig",
)


PHASE_TIMING_ENV = "WIKIDICT_PHASE_TIMING"
COMPLETED_EXPANDER = ".completed-expander.json"
COMPLETED_EXPANDER_VERSION = 1
EXPANDER_SNAPSHOTS = (
    "namespace-registry.tsv", "stylesheet-imports.json", "namespace-siteinfo.raw.json",
    "figure-siteinfo.raw.json", "figure-sizing.json", "figure-sizing.raw.json",
    "figure-sizing.site.json", "figure-page-observations.json",
    "site-statistics-format.json", "commons-data.tsv", "category-stats.tsv",
    "category-statistics-format.json", "interface-messages.tsv", "category-tree.tsv",
    "interwiki-map.tsv", "wikibase-sitelinks.tsv", "wikibase-entity-text.tsv",
    "wikibase-entities.tsv", "wikibase-page-links.tsv", "page-redirects.tsv",
    "wikibase-entity-terms.tsv", "language-registry.tsv", "language-fallbacks.tsv",
    "date-numbering.tsv", "language-names.tsv", "image-options.tsv",
    "behavior-switches.tsv", "magic-words.tsv", "file-metadata.tsv",
    "transclusion-redirects.tsv", "parser-function-facts.json",
    "page-language.json", "page-language.raw.json", "page-language.html",
)


def _full_stamp(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns)


def stable_file_digest(path, *, snapshot=False, _memo=None):
    """Hash held regular bytes; only explicitly selected snapshots may be links."""
    import stat
    path = Path(path)
    link = os.readlink(path) if path.is_symlink() else None
    if link is not None and not snapshot:
        raise ValueError("Linked expander asset")
    target = path.resolve(strict=True) if snapshot else path
    before = target.stat()
    if not stat.S_ISREG(before.st_mode):
        raise ValueError("Nonregular expander asset")
    key = (os.getpid(), *_full_stamp(before)) if _memo is not None else None
    try:
        with target.open("rb") as stream:
            if _full_stamp(os.fstat(stream.fileno())) != _full_stamp(before):
                raise ValueError("Expander asset replaced before reading")
            # Only this completed-identity transaction supplies a memo. Every
            # alias still opens its current target and earns both fd/path guards.
            value = _memo.get(key) if _memo is not None else None
            if value is None:
                digest = hashlib.sha256()
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
                value = (before.st_size, digest.hexdigest())
            if _full_stamp(os.fstat(stream.fileno())) != _full_stamp(before):
                raise ValueError("Expander asset changed during reading")
        if (_full_stamp(path.stat()) != _full_stamp(before) or
                (os.readlink(path) if path.is_symlink() else None) != link):
            raise ValueError("Expander asset path changed during reading")
    except BaseException:
        if _memo is not None:
            _memo.pop(key, None)
        raise
    if _memo is not None:
        _memo[key] = value
    return list(value)


def _receipt_identity(path, *, index=False):
    regular(path)
    info = path.stat()
    return dict(device_major=os.major(info.st_dev), device_minor=os.minor(info.st_dev),
                inode=info.st_ino, size=info.st_size, mtime_ns=info.st_mtime_ns,
                ctime_ns=0 if index else info.st_ctime_ns)


def completed_source_binding(root, dump):
    """Keep the existing physical SourceReceipt v2; never rewrite its origin."""
    return _completed_source_binding(root, dump)


def _read_source_receipt(root):
    receipt_path = root / "extraction-source.json"
    regular(receipt_path)
    with receipt_path.open("rb") as stream:
        raw = stream.read(16385)
    if len(raw) > 16384:
        raise ValueError("Oversized extraction source receipt")
    return raw, json.loads(raw)


def _receipt_indexes(root):
    return [_receipt_identity(root / name, index=True) for name in
            ("page-index.tsv", "page-title-index.bin", "dump-streams.tsv")]


def _completed_source_binding(root, dump, *, restored_source=None, restored_indexes=None):
    raw, receipt = _read_source_receipt(root)
    namespace = stable_file_digest(root / "namespace-registry.tsv", snapshot=True)[1]
    redirects_path = root / "transclusion-redirects.tsv"
    redirects = (stable_file_digest(redirects_path, snapshot=True)[1]
                 if os.path.lexists(redirects_path) else None)
    indexes = _receipt_indexes(root)
    if restored_indexes is not None:
        _require_restored_indexes(restored_indexes, root)
        original = json.loads(restored_indexes[2])['receipt']['indexes']
        indexes[:2] = original[:2]
    expected = dict(version=2, source=(_receipt_identity(dump) if restored_source is None else restored_source["receipt"]["source"]),
                    indexes=indexes,
                    namespace_sha256=list(bytes.fromhex(namespace)),
                    redirects_sha256=list(bytes.fromhex(redirects)) if redirects else None)
    if receipt != expected:
        raise ValueError("Completed expander source receipt changed")
    return dict(path=(str(dump.absolute()) if restored_source is None else restored_source["path"]), receipt=expected,
                receipt_bytes=[len(raw), hashlib.sha256(raw).hexdigest()])


class _RestoredDumpBinding(tuple):
    """Process-local immutable custody, separate from the historical SourceReceipt."""
    __slots__ = ()


def _restored_dump_custody(dump):
    import stat
    dump = Path(dump)
    if not dump.is_absolute() or str(dump) != os.path.normpath(str(dump)):
        raise ValueError('Invalid restored dump path')
    parents = []
    for parent in dump.parents:
        info = parent.lstat()
        if not stat.S_ISDIR(info.st_mode):
            raise ValueError('Linked or non-directory restored dump parent')
        parents.append((str(parent), info.st_dev, info.st_ino, info.st_mode))
    info = dump.lstat()
    if not stat.S_ISREG(info.st_mode):
        raise ValueError('Linked or nonregular restored dump')
    return _full_stamp(info), tuple(parents)


def _require_restored_dump(binding, root, dump, expected_sha, source):
    if (type(binding) is not _RestoredDumpBinding or len(binding) != 7
            or binding[:3] != (str(root), str(dump), expected_sha)
            or binding[3] != json.dumps(source, sort_keys=True, separators=(',', ':')).encode()
            or _restored_dump_custody(dump) != binding[4:6]):
        raise ValueError('Restored dump custody changed')


def restored_dump_binding(root, descriptor, expected_sha, *, previous=None, restored_indexes=None):
    """Authenticate exact original compressed bytes once, then retain their custody."""
    import stat
    root = Path(root)
    if type(descriptor) is not dict:
        raise ValueError('Invalid restored dump selection')
    selected_descriptor = descriptor
    descriptor = dict(descriptor)
    if (not root.is_absolute() or str(root) != os.path.normpath(str(root))
            or any(p.is_symlink() for p in (root, *root.parents)) or not root.is_dir()
            or not isinstance(descriptor, dict)
            or not {'path', 'bytes', 'sha256'} <= set(descriptor)
            or not set(descriptor) <= {'path', 'bytes', 'sha256', 'mode'}
            or type(descriptor['path']) is not str or type(descriptor['bytes']) is not int
            or descriptor['bytes'] < 0 or type(descriptor['sha256']) is not str
            or not re.fullmatch('[0-9a-f]{64}', descriptor['sha256'])
            or ('mode' in descriptor and type(descriptor['mode']) is not int)
            or not isinstance(expected_sha, str) or not re.fullmatch('[0-9a-f]{64}', expected_sha)):
        raise ValueError('Invalid restored dump selection')
    dump = Path(descriptor['path'])
    if str(dump) != descriptor['path']:
        raise ValueError('Noncanonical restored dump path')
    selection = json.dumps(descriptor, sort_keys=True, separators=(',', ':')).encode()
    marker = root / COMPLETED_EXPANDER
    regular(marker)
    before = _full_stamp(marker.stat())
    with marker.open('rb') as stream:
        if _full_stamp(os.fstat(stream.fileno())) != before:
            raise ValueError('Restored dump seal changed before reading')
        raw = stream.read(MAX_MARKER_BYTES + 1)
        if _full_stamp(os.fstat(stream.fileno())) != before:
            raise ValueError('Restored dump seal changed during reading')
    if (len(raw) > MAX_MARKER_BYTES or hashlib.sha256(raw).hexdigest() != expected_sha
            or _full_stamp(marker.stat()) != before):
        raise ValueError('Restored dump original seal changed')
    seal = json.loads(raw)
    source = seal['identity']['source']
    if (descriptor['sha256'] != seal['identity']['verified_input'][0]
            or descriptor['bytes'] != source['receipt']['source']['size']):
        raise ValueError('Restored dump differs from original compressed input')
    custody = _restored_dump_custody(dump)
    if custody[0][3] != descriptor['bytes'] or ('mode' in descriptor and stat.S_IMODE(custody[0][2]) != descriptor['mode']):
        raise ValueError('Restored dump size or mode differs')
    if previous is None:
        if stable_file_digest(dump) != [descriptor['bytes'], descriptor['sha256']]:
            raise ValueError('Restored compressed dump bytes differ')
        binding = _RestoredDumpBinding((str(root), str(dump), expected_sha,
            json.dumps(source, sort_keys=True, separators=(',', ':')).encode(),
            *custody, selection))
    else:
        binding = previous
        if type(binding) is not _RestoredDumpBinding or len(binding) != 7 or binding[6] != selection:
            raise ValueError('Restored dump selection changed')
    _require_restored_dump(binding, root, dump, expected_sha, source)
    if (_completed_source_binding(root, dump, restored_source=source, restored_indexes=restored_indexes) != source
            or _full_stamp(marker.stat()) != before):
        raise ValueError('Restored dump original source binding changed')
    _require_restored_dump(binding, root, dump, expected_sha, source)
    if json.dumps(selected_descriptor, sort_keys=True, separators=(',', ':')).encode() != selection:
        raise ValueError('Restored dump selection changed during authentication')
    return binding


RESTORED_INDEX_NAMES = ('page-index.tsv', 'page-title-index.bin')


class _RestoredIndexBinding(tuple):
    """Authenticated current aliases; never a replacement historical seal."""
    __slots__ = ()

    def __deepcopy__(self, memo):
        return self


_RESTORED_INDEX_BINDINGS = {}


def _index_alias_custody(path):
    custody = _restored_dump_custody(path)
    info = path.lstat()
    return custody, (info.st_uid, info.st_gid, info.st_nlink)


def _require_restored_indexes(binding, root, expected_sha=None):
    if (type(binding) is not _RestoredIndexBinding
            or _RESTORED_INDEX_BINDINGS.get(id(binding)) is not binding
            or binding[0] != str(root)
            or (expected_sha is not None and binding[1] != expected_sha)):
        raise ValueError('Invalid restored index custody')
    # Include both aliases, all parents, the original seal/receipt and the
    # authenticated cache manifest on every reuse, including after hashing.
    for path, before in binding[4]:
        if _index_alias_custody(Path(path)) != before:
            raise ValueError('Restored index custody changed: ' + path)


def restored_index_binding(root, selection, expected_sha, *, previous=None):
    """Explicitly rebind two losslessly restored indexes to their original bytes.

    Default source/ready validation still requires original inode identities.
    This opt-in is only for the two normal extraction aliases and authenticates
    the original completed seal, cache identity and complete index payloads.
    """
    import stat
    root = Path(root)
    if (type(selection) is not dict
            or set(selection) != {'original_seal_sha256', 'cache_manifest', 'names'}
            or selection['original_seal_sha256'] != expected_sha
            or selection['names'] != list(RESTORED_INDEX_NAMES)
            or not isinstance(expected_sha, str) or not re.fullmatch('[0-9a-f]{64}', expected_sha)
            or not root.is_absolute() or str(root) != os.path.normpath(str(root))):
        raise ValueError('Invalid restored index selection')
    selected = json.dumps(selection, sort_keys=True, separators=(',', ':')).encode()
    if previous is not None:
        _require_restored_indexes(previous, root, expected_sha)
        if previous[3] != selected:
            raise ValueError('Restored index selection changed')
        return previous
    reference = selection['cache_manifest']
    if (type(reference) is not dict or set(reference) != {'path', 'bytes', 'sha256'}
            or type(reference['path']) is not str):
        raise ValueError('Invalid restored index manifest')
    manifest = Path(reference['path']); backing = manifest.parent
    if (manifest.name != '.complete.json' or str(manifest) != reference['path']
            or not manifest.is_absolute() or str(manifest) != os.path.normpath(str(manifest))
            or backing == root or backing.is_relative_to(root) or root.is_relative_to(backing)):
        raise ValueError('Invalid restored index alias root')
    marker = root / COMPLETED_EXPANDER
    receipt = root / 'extraction-source.json'
    proof = root / 'extraction-completion.json'
    paths = [marker, receipt, manifest, proof, root / 'dump-streams.tsv', root / 'compiler-inputs.ready']
    paths.extend(p / name for name in RESTORED_INDEX_NAMES for p in (root, backing))
    held = tuple((str(path), _index_alias_custody(path)) for path in paths)
    with marker.open('rb') as stream:
        raw = stream.read(MAX_MARKER_BYTES + 1)
    if not raw or len(raw) > MAX_MARKER_BYTES or hashlib.sha256(raw).hexdigest() != expected_sha:
        raise ValueError('Restored index original seal changed')
    recorded = json.loads(raw); source = recorded['identity']['source']
    cached = _frontend_reference(reference)
    if (not extraction_ownership_proven(backing)
            or cached['identity']['dump_sha256'] != recorded['identity']['verified_input'][0]
            or cached['identity']['index_sha256'] != recorded['identity']['verified_input'][1]):
        raise ValueError('Restored index cache input differs')
    if stable_file_digest(receipt) != source['receipt_bytes'] or json.loads(receipt.read_bytes()) != source['receipt']:
        raise ValueError('Restored index original SourceReceipt changed')
    original_assets = {name: [size, digest] for name, size, digest in recorded['identity']['assets']}
    cache_assets = {name: [size, digest] for name, size, digest in cached['assets']}
    for number, name in enumerate(RESTORED_INDEX_NAMES):
        old = recorded['runtime_stamps']['assets'][name]
        pair = [_index_alias_custody(p / name) for p in (root, backing)]
        current = pair[0][0][0]
        if (len(old) != 6 or any(type(v) is not int for v in old) or not stat.S_ISREG(old[2])
                or pair[0][0][0] != pair[1][0][0] or pair[0][1] != pair[1][1]
                or pair[0][1][0] != os.geteuid() or pair[0][1][2] != 2
                or list(current[2:5]) != old[2:5]
                or recorded['runtime_stamps']['snapshot_links'].get(name) is not None
                or original_assets[name] != cache_assets.get(name)
                or source['receipt']['indexes'][number] != dict(
                    device_major=os.major(old[0]), device_minor=os.minor(old[0]), inode=old[1],
                    size=old[3], mtime_ns=old[4], ctime_ns=0)):
            raise ValueError('Restored index alias or original identity differs: ' + name)
        if stable_file_digest(root / name) != original_assets[name]:
            raise ValueError('Restored index bytes differ: ' + name)
    with (root / 'page-index.tsv').open('rb') as stream:
        if stream.readline(128) != b'# dict-page-index-v3\tmultistream-zstd\n':
            raise ValueError('Unsupported restored page index format')
    with (root / 'page-title-index.bin').open('rb') as stream:
        if int.from_bytes(stream.read(16)[8:16], 'little') != 2:
            raise ValueError('Restored title/page index kinds differ')
    validate_extraction_completion(root)
    binding = _RestoredIndexBinding((str(root), expected_sha,
        json.dumps(source, sort_keys=True, separators=(',', ':')).encode(), selected, held))
    # Publish only after the complete transaction; no partial success survives.
    if any(_index_alias_custody(Path(path)) != before for path, before in held):
        raise ValueError('Restored index changed during authentication')
    if json.dumps(selection, sort_keys=True, separators=(',', ':')).encode() != selected:
        raise ValueError('Restored index selection changed during authentication')
    _RESTORED_INDEX_BINDINGS[id(binding)] = binding
    return binding


def completed_asset_names(root, *, sealing=False):
    names = set(walk_assets(root))
    for child in root.iterdir():
        if child.name in (TREE, ".incomplete", ".compiler-inputs.lock", COMPLETED_EXPANDER):
            continue
        if sealing and child.name == "llvm" and child.is_dir() and not child.is_symlink():
            continue
        if not child.is_file():
            raise ValueError("Unexpected completed expander member")
        names.add(child.name)
    return names


def completed_producer_identity(graph):
    if (not isinstance(graph, dict) or
            set(graph) != {"project_root", "extractor", "llvm", "runtime", "leaf", "main_c", "zig", "clang"} or
            any(not isinstance(value, str) or not value for value in graph.values())):
        raise ValueError("Invalid completed expander graph")
    stamps = {name: _full_stamp(Path(value).stat()) for name, value in graph.items()
              if name not in ("project_root", "clang")}
    project = Path(graph["project_root"])
    producer = dict(
        extractor=tool_identity(Path(graph["extractor"])),
        llvm=tool_identity(Path(graph["llvm"])),
        runtime=stable_file_digest(Path(graph["runtime"])),
        leaf=stable_file_digest(Path(graph["leaf"])),
        main_c=stable_file_digest(Path(graph["main_c"])),
        zig=live_zig_observation(graph["zig"]),
        clang=clang_identity(graph["clang"], ("-march=native", "-fno-lto", "-Wno-override-module", "-O1")),
        unicode=unicode_case_identity(),
        abi=abi_provenance(project),
        policy=[[name, stable_file_digest(project / name)] for name in
                ("build.zig", "tools/bundle_build.zig", "tools/extraction_cache.py")],
        link_flags=["cc", "-O2", "-pthread", "-lm", "-lbz2", "-lzstd", "-lc"],
    )
    if any(_full_stamp(Path(graph[name]).stat()) != stamp for name, stamp in stamps.items()):
        raise ValueError("Current expansion producer changed during validation")
    return producer, stamps


def completed_expander_identity(root, dump, dump_sha, index_sha, graph, snapshots, *, restored_dump=None):
    """Compare the current ordinary graph, not a guessed source exclusion list."""
    if (not isinstance(graph, dict) or not isinstance(snapshots, dict) or
            set(graph) != {"project_root", "extractor", "llvm", "runtime", "leaf",
                       "main_c", "zig", "clang"} or
            any(not isinstance(value, str) or not value for value in graph.values()) or
            set(snapshots) != set(EXPANDER_SNAPSHOTS) or
            any(value is not None and (not isinstance(value, str) or not value)
                for value in snapshots.values()) or
            any(not re.fullmatch(r"[0-9a-f]{64}", value) for value in (dump_sha, index_sha))):
        raise ValueError("Invalid completed expander inputs")
    if any(parent.is_symlink() for parent in (root, *root.parents)) or not root.is_dir():
        raise ValueError("Invalid completed expander root")
    if {p.name for p in root.parent.iterdir()} != {
            ".bundle-expander", ".incomplete", "compile-plan.tsv", "module-compile-plan.tsv"}:
        raise ValueError("Unexpected owned expander outputs")
    producer, graph_stamps = completed_producer_identity(graph)
    source = _frontend_completed_source(root, dump, restored_dump)
    validate_extraction_completion(root)
    providers = {}
    # Operation-local hashes only: no previous seal or caller-provided digest.
    digests = {}
    for name, selected in snapshots.items():
        installed = root / name
        if selected is None:
            if os.path.lexists(installed):
                raise ValueError("Unexpected expander snapshot")
            providers[name] = None
        else:
            value = stable_file_digest(Path(selected), snapshot=True, _memo=digests)
            if stable_file_digest(installed, snapshot=True, _memo=digests) != value:
                raise ValueError("Selected expander snapshot differs")
            providers[name] = value
    # Generated modules/indexes must remain regular owned assets. Snapshot links
    # are allowed only by the explicit, complete normal option inventory above.
    names = completed_asset_names(root, sealing=True)
    required = {"dict-bundle-expander", "lua-program.meta"}
    if not required <= names:
        raise ValueError("Incomplete native expander output")
    stamps = {name: _full_stamp((root / name).stat()) for name in names}
    assets = [[name, *stable_file_digest(root / name, snapshot=name in snapshots,
                                        _memo=digests if name in snapshots else None)]
              for name in sorted(names)]
    runtime_libraries = tool_identity(root / "dict-bundle-expander")
    plans = [[name, *stable_file_digest(root.parent / name)] for name in
             ("compile-plan.tsv", "module-compile-plan.tsv")]
    if (completed_asset_names(root, sealing=True) != names or
            any(_full_stamp(Path(graph[name]).stat()) != stamp for name, stamp in graph_stamps.items()) or
            any(_full_stamp((root / name).stat()) != stamp for name, stamp in stamps.items()) or
            _frontend_completed_source(root, dump, restored_dump) != source):
        raise ValueError("Expander source changed during validation")
    return dict(version=COMPLETED_EXPANDER_VERSION, source=source,
                verified_input=[dump_sha, index_sha], producer=producer,
                providers=providers, assets=assets, plans=plans, runtime_libraries=runtime_libraries)


def _snapshot_metadata_refresh(root, record, expected_sha, receipt):
    # Explicit current observation changes custody only, never the old seal.
    keys = {'name', 'source', 'original_seal_sha256', 'old_stamp', 'current_stamp', 'current_nlink', 'ctime_cause'}
    multiple = isinstance(receipt,dict) and set(receipt) == {'original_seal_sha256','snapshots'}
    if multiple:
        members = receipt['snapshots']
        if (receipt['original_seal_sha256'] != expected_sha or not isinstance(members,list) or not members
                or any(not isinstance(row,dict) or set(row) != keys | {'alias_stamp'} for row in members)):
            raise ValueError('Invalid snapshot metadata refresh list')
        names = [row['name'] for row in members]
        if any(not isinstance(name,str) for name in names) or names != sorted(set(names)):
            raise ValueError('Snapshot metadata refresh names are not exact and unique')
    else:
        members = [receipt]
    successor = dict(record)
    successor['runtime_stamps'] = dict(record['runtime_stamps'])
    successor['runtime_stamps']['assets'] = dict(record['runtime_stamps']['assets'])
    held = []
    for row in members:
        if (not isinstance(row,dict) or set(row) != (keys | {'alias_stamp'} if multiple else keys)
                or row['name'] not in EXPANDER_SNAPSHOTS or (not multiple and row['name'] != 'figure-page-observations.json')
                or row['original_seal_sha256'] != expected_sha or row['ctime_cause'] != 'unknown'
                or type(row['current_nlink']) is not int or row['current_nlink'] < 1):
            raise ValueError('Invalid snapshot metadata refresh receipt')
        name = row['name']; old = row['old_stamp']; current = row['current_stamp']
        if (not isinstance(old,list) or not isinstance(current,list) or len(old) != 6 or len(current) != 6
                or any(type(v) is not int for v in old + current) or old[:5] != current[:5] or old[5] == current[5]
                or record['runtime_stamps']['assets'].get(name) != old):
            raise ValueError('Snapshot metadata refresh is not ctime-only')
        current = list(current); path = root / name; source = Path(row['source'])
        if (not source.is_absolute() or str(source) != os.path.normpath(str(source))
                or any(p.is_symlink() for p in (source,*source.parents)) or not path.is_symlink()
                or os.readlink(path) != str(source) or record['runtime_stamps']['snapshot_links'].get(name) != str(source)):
            raise ValueError('Snapshot metadata refresh alias changed')
        alias = list(_full_stamp(path.lstat()))
        if multiple and (not isinstance(row['alias_stamp'],list) or len(row['alias_stamp']) != 6
                or any(type(v) is not int for v in row['alias_stamp']) or alias != row['alias_stamp']):
            raise ValueError('Snapshot metadata refresh current alias changed')
        nlink = row['current_nlink']
        if _full_stamp(source.stat()) != tuple(current) or source.stat().st_nlink != nlink:
            raise ValueError('Snapshot metadata refresh source changed')
        value = stable_file_digest(source,snapshot=True)
        assets = [asset for asset in record['identity']['assets'] if asset[0] == name]
        if (len(assets) != 1 or list(value) != assets[0][1:] or list(value) != record['identity']['providers'].get(name)
                or _full_stamp(source.stat()) != tuple(current) or source.stat().st_nlink != nlink
                or not path.is_symlink() or os.readlink(path) != str(source) or list(_full_stamp(path.lstat())) != alias):
            raise ValueError('Snapshot metadata refresh content or identity changed')
        successor['runtime_stamps']['assets'][name] = current
        held.append((path,source,current,nlink,alias))
    for path,source,current,nlink,alias in held:
        if (not path.is_symlink() or os.readlink(path) != str(source) or list(_full_stamp(path.lstat())) != alias
                or _full_stamp(source.stat()) != tuple(current) or source.stat().st_nlink != nlink):
            raise ValueError('Snapshot metadata refresh changed during validation')
    return successor


def _metadata_custody_json(reference):
    if (not isinstance(reference, dict) or set(reference) != {'path', 'bytes', 'sha256'} or
            not isinstance(reference['path'], str) or type(reference['bytes']) is not int or
            not 0 < reference['bytes'] <= MAX_MARKER_BYTES or
            not isinstance(reference['sha256'], str) or not re.fullmatch('[0-9a-f]{64}', reference['sha256'])):
        raise ValueError('Invalid closed metadata custody descriptor')
    path = Path(reference['path'])
    if not path.is_absolute() or str(path) != os.path.normpath(str(path)) or any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError('Unsafe closed metadata custody descriptor')
    regular(path); before = path.stat(); raw = path.read_bytes(); after = path.stat()
    if (_full_stamp(before) != _full_stamp(after) or before.st_nlink != after.st_nlink or
            len(raw) != reference['bytes'] or hashlib.sha256(raw).hexdigest() != reference['sha256']):
        raise ValueError('Closed metadata custody authority changed')
    return json.loads(raw)


def _materialized_custody_contract(root, recorded, operation, native, observations, names):
    """Validate a known link event without changing source or seal identity."""
    import stat
    payload_names = {'figure-sizing.json', 'figure-sizing.raw.json',
                     'file-metadata.tsv', 'figure-file-inventory.json'}
    fields = ('st_dev', 'st_ino', 'st_mode', 'st_uid', 'st_gid', 'st_size',
              'st_mtime_ns', 'st_ctime_ns', 'st_nlink')
    failed = operation.get('outcome') == 'FAILED-PHYSICALLY-SOURCE-CLOSED'
    if (observations.get('operation') != 'materialize-complete'
            or observations.get('complete') is not (not failed)
            or observations.get('source_complete_verified') is not True
            or 'repair_manifest_sha256' in observations
            or 'repaired_manifest' in native
            or (failed and (observations.get('failed_link_recovery_verified') is not True
                            or observations.get('new_output_adoption_allowed') is not False
                            or operation.get('output_manifest') is not None))):
        raise ValueError('Known materialization custody disposition differs')
    selected = operation['source_manifest'] if failed else operation['output_manifest']
    if native.get('validated_manifest') != selected:
        raise ValueError('Known custody did not validate its selected complete tuple')
    compatibility = _metadata_custody_json(native['compatibility'])
    argv = compatibility.get('argv', [])
    selected_root = Path(selected['path']).parent
    namespace = recorded['runtime_stamps']['snapshot_links'].get('namespace-registry.tsv')
    namespace = Path(namespace) if namespace is not None else root / 'namespace-registry.tsv'
    figure_names = ('figure-siteinfo.raw.json', 'figure-sizing.json',
                    'figure-sizing.raw.json', 'figure-sizing.site.json')
    expected_paths = [str(namespace.resolve(strict=True)),
                      *(str(selected_root / name) for name in figure_names)]
    if (not isinstance(argv, list) or len(argv) != 8
            or argv[1:3] != ['--check-figure-compatibility', '--full']
            or argv[3:] != expected_paths):
        raise ValueError('Known custody validated another Figure root')
    source = _metadata_custody_json(operation['source_manifest'])
    if not failed:
        output = _metadata_custody_json(operation['output_manifest'])
        if any(source.get('artifacts', {}).get(name) != output.get('artifacts', {}).get(name)
               for name in payload_names | set(figure_names)):
            raise ValueError('Known materialization changed an original payload')
    source_root = Path(operation['source_manifest']['path']).parent
    members = observations.get('original_members', operation['linked_members'] if not failed else None)
    if (not isinstance(members, list) or len(members) != 4
            or {row.get('path') for row in members} != payload_names):
        raise ValueError('Known custody lacks the complete original payload inventory')
    changed = []
    for row in members:
        if set(row) != {'path', 'before', 'after', 'sha256_before', 'sha256_after'}:
            raise ValueError('Invalid known custody source member')
        before, after = row['before'], row['after']
        if (not isinstance(before, dict) or not isinstance(after, dict)
                or set(before) != set(fields) or set(after) != set(fields)
                or any(type(value) is not int for value in [*before.values(), *after.values()])
                or any(before[key] != after[key] for key in fields if key not in ('st_ctime_ns', 'st_nlink'))
                or not stat.S_ISREG(before['st_mode']) or before['st_uid'] != os.geteuid()
                or before['st_nlink'] < 1 or after['st_nlink'] < before['st_nlink']
                or after['st_nlink'] > before['st_nlink'] + 1
                or not isinstance(row['sha256_before'], str) or not re.fullmatch('[0-9a-f]{64}', row['sha256_before'])
                or row['sha256_before'] != row['sha256_after']
                or source.get('artifacts', {}).get(row['path']) !=
                    {'bytes': before['st_size'], 'sha256': row['sha256_before']}):
            raise ValueError('Known custody changed original payload bytes or stable identity')
        path = source_root / row['path']
        if path.is_symlink() or not path.is_file() or any(getattr(path.stat(), key) != after[key] for key in fields):
            raise ValueError('Known custody source changed after closure')
        if before != after:
            changed.append(row)
    events = operation.get('linked_members')
    if (observations.get('linked_members') != events or not isinstance(events, list)
            or len({row.get('path') for row in events}) != len(events)
            or {row.get('path') for row in events} != {row['path'] for row in changed}
            or len({(row['before']['st_dev'], row['before']['st_ino']) for row in members}) != 4):
        raise ValueError('Known custody did not record exactly its touched sources')
    members_by_name = {row['path']:row for row in members}
    events_by_name = {row['path']:row for row in events}
    for event in events:
        member = members_by_name[event['path']]
        if (set(event) != {'path', 'before', 'after', 'sha256_before', 'sha256_after'}
                or event['before'] != member['before'] or not isinstance(event['after'], dict)
                or set(event['after']) != set(fields)
                or any(type(value) is not int for value in event['after'].values())
                or any(event['after'][key] != member['before'][key] for key in fields
                       if key not in ('st_ctime_ns', 'st_nlink'))
                or event['after']['st_nlink'] != member['before']['st_nlink'] + 1
                or any(event[key] != member[key] for key in ('sha256_before', 'sha256_after'))):
            raise ValueError('Known custody creation event differs from original source')
    selected_names = sorted(name for name, target in recorded['runtime_stamps']['snapshot_links'].items()
                            if target is not None and Path(target).parent == source_root
                            and Path(target).name in payload_names)
    if names != selected_names:
        raise ValueError('Known custody selected different native assets')
    # Failed output is never adopted; surviving owned links remain explicit
    # evidence. A removed link still has its original source ctime transition.
    output_root = observations.get('output_root')
    if (not isinstance(output_root, dict) or set(output_root) != {'path', 'device', 'inode', 'mode', 'uid'}):
        raise ValueError('Known custody lacks its owned output root')
    destination = Path(output_root['path'])
    if not failed and destination != Path(operation['output_manifest']['path']).parent:
        raise ValueError('Known custody output manifest belongs to another operation root')
    if failed and os.path.lexists(destination / 'figure-inputs.complete.json'):
        raise ValueError('Failed known custody output acquired a complete marker')
    if (not destination.is_absolute() or str(destination) != os.path.normpath(str(destination))
            or any(path.is_symlink() for path in (destination, *destination.parents))
            or not destination.is_dir() or destination == source_root
            or destination.is_relative_to(source_root) or source_root.is_relative_to(destination)
            or destination.is_relative_to(root)):
        raise ValueError('Unsafe known custody output root')
    current = destination.stat()
    if (current.st_dev, current.st_ino, current.st_mode, current.st_uid) != (
            output_root['device'], output_root['inode'], output_root['mode'], output_root['uid']) or current.st_uid != os.geteuid():
        raise ValueError('Known custody output identity changed')
    remaining = observations.get('remaining_owned_links')
    if not isinstance(remaining, list) or len({row.get('path') for row in remaining}) != len(remaining):
        raise ValueError('Known custody remaining links are not exact')
    remaining_by_name = {row['path']: row for row in remaining}
    removed = observations.get('removed_owned_links', [])
    if (not isinstance(removed, list) or len({row.get('path') for row in removed}) != len(removed)
            or any(row.get('path') not in payload_names for row in removed)):
        raise ValueError('Known custody removed links are not exact')
    removed_by_name = {row['path']:row for row in removed}
    if set(removed_by_name) & set(remaining_by_name) or (not failed and removed_by_name):
        raise ValueError('Known custody mixed surviving and removed links')
    if not set(remaining_by_name) <= payload_names:
        raise ValueError('Known custody contains an unowned payload link')
    for row in members:
        count = row['after']['st_nlink'] - row['before']['st_nlink']
        if row['before'] != row['after'] and count == 0:
            event = removed_by_name.get(row['path'])
            target = destination / row['path']
            if (not isinstance(event, dict) or set(event) != {'path', 'target', 'before', 'after'}
                    or event['target'] != str(target) or event['after'] != row['after']
                    or not isinstance(event['before'], dict) or set(event['before']) != set(fields)
                    or any(type(value) is not int for value in event['before'].values())
                    or any(event['before'][key] != row['before'][key] for key in fields
                           if key not in ('st_ctime_ns', 'st_nlink'))
                    or event['before'] != events_by_name[row['path']]['after']
                    or os.path.lexists(target)):
                raise ValueError('Known custody cleanup lacks its explicit owned-target event')
        elif row['path'] in removed_by_name:
            raise ValueError('Known custody removal does not explain a source transition')
        if count != int(row['path'] in remaining_by_name):
            raise ValueError('Known custody nlink delta differs from its remaining owned links')
        if row['path'] in remaining_by_name:
            link = remaining_by_name[row['path']]
            target = destination / row['path']
            if (set(link) != {'path', 'target', 'stamp'} or link['target'] != str(target)
                    or link['stamp'] != row['after'] or target.is_symlink() or not target.is_file()
                    or any(getattr(target.stat(), key) != row['after'][key] for key in fields)):
                raise ValueError('Known custody surviving link changed')
    if not failed and set(remaining_by_name) != payload_names:
        raise ValueError('Completed materialization did not retain all four links')
    return failed


def _closed_metadata_custody(root, recorded, expected_sha, receipt):
    # No payload, producer, logical Provider identity, or seal is rewritten.
    # Same-byte custody comes from an explicitly selected closed operation that
    # hashed both sides, then a matched closed full native input validation.
    import stat
    if (not isinstance(receipt, dict) or set(receipt) != {'original_seal_sha256', 'operation', 'native_validation', 'names'} or
            receipt['original_seal_sha256'] != expected_sha or not isinstance(receipt['names'], list) or
            any(not isinstance(n, str) for n in receipt['names']) or
            receipt['names'] != sorted(set(receipt['names'])) or not set(receipt['names']) <= set(EXPANDER_SNAPSHOTS)):
        raise ValueError('Invalid metadata custody receipt selection')
    operation = _metadata_custody_json(receipt['operation']); native = _metadata_custody_json(receipt['native_validation'])
    observations = _metadata_custody_json(operation['observations'])
    known = isinstance(observations, dict) and observations.get('operation') == 'materialize-complete'
    recovery = known and operation.get('outcome') == 'FAILED-PHYSICALLY-SOURCE-CLOSED'
    for evidence in (operation, native):
        if not isinstance(evidence, dict):
            raise ValueError('Invalid closed metadata custody evidence')
        expected_outcome = ('FAILED' if evidence is operation and recovery else 'PASSED') + '-PHYSICALLY-SOURCE-CLOSED'
        if (evidence.get('outcome') != expected_outcome or
                any(evidence.get(k) is not True for k in ('source_after', 'source_lease_released', 'allocation_released'))):
            raise ValueError('Metadata custody requires closed successful authorities')
    if (native.get('native_returncode') != 0 or native.get('ordinary_full_stream_validation') is not True or
            native.get('pages_executed') != 0 or native.get('compiler_executed') is not False or
            (not known and native.get('repaired_manifest') != operation.get('output_manifest'))):
        raise ValueError('Metadata custody lacks matched full native validation')
    compatibility = _metadata_custody_json(native['compatibility'])
    if (not isinstance(compatibility, dict) or compatibility.get('returncode') != 0 or compatibility.get('ordinary_full_stream_validation') is not True or
            compatibility.get('input_after') is not True or compatibility.get('pages_executed') != 0 or
            compatibility.get('compiler_executed') is not False or
            compatibility.get('argv', [])[1:3] != ['--check-figure-compatibility', '--full']):
        raise ValueError('Metadata custody native result differs')
    if (not isinstance(observations, dict) or observations.get('source_content_mode_inode_preserved') is not True
            or observations.get('linked_members') != operation.get('linked_members')
            or observations.get('source_manifest_sha256') != operation['source_manifest']['sha256']):
        raise ValueError('Metadata custody operation observations differ')
    if known:
        _materialized_custody_contract(root, recorded, operation, native, observations, receipt['names'])
    elif (observations.get('operation') is not None or not receipt['names']
            or observations.get('complete') is not True
            or observations.get('repair_manifest_sha256') != operation['source_manifest']['sha256']):
        raise ValueError('Metadata custody repair observations differ')
    _metadata_custody_json(operation['source_manifest'])
    if not recovery:
        _metadata_custody_json(operation['output_manifest'])
    source_root = Path(operation['source_manifest']['path']).parent
    fields = ('st_dev', 'st_ino', 'st_mode', 'st_uid', 'st_gid', 'st_size', 'st_mtime_ns', 'st_ctime_ns', 'st_nlink')
    frozen_fields = ('st_dev', 'st_ino', 'st_mode', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
    # Only refreshed asset stamps are written; all other seal data stays borrowed.
    successor = dict(recorded)
    successor['runtime_stamps'] = dict(recorded['runtime_stamps'])
    successor['runtime_stamps']['assets'] = dict(recorded['runtime_stamps']['assets'])
    held = []
    for name in receipt['names']:
        source_text = recorded['runtime_stamps']['snapshot_links'].get(name)
        if not isinstance(source_text, str):
            raise ValueError('Metadata custody requires an original external Provider alias')
        source = Path(source_text); installed = root / name
        if (not source.is_absolute() or source.parent != source_root or root in source.parents or
                source.resolve(strict=True) != source or any(p.is_symlink() for p in (source, *source.parents)) or
                not installed.is_symlink() or os.readlink(installed) != source_text):
            raise ValueError('Metadata custody changed an unrecorded Provider alias')
        members = observations['original_members'] if known else operation['linked_members']
        matches = [r for r in members if r.get('path') == source.name]
        if len(matches) != 1 or set(matches[0]) != {'path', 'before', 'after', 'sha256_before', 'sha256_after'}:
            raise ValueError('Metadata custody Provider operation is not unique')
        row = matches[0]; before, after = row['before'], row['after']
        if (not isinstance(before, dict) or not isinstance(after, dict) or set(before) != set(fields) or set(after) != set(fields) or
                any(type(v) is not int for v in [*before.values(), *after.values()]) or
                any(before[k] != after[k] for k in fields if k not in ('st_ctime_ns', 'st_nlink')) or
                not stat.S_ISREG(before['st_mode']) or before['st_nlink'] < 1 or after['st_nlink'] < 1 or
                (not known and (before['st_ctime_ns'], before['st_nlink']) == (after['st_ctime_ns'], after['st_nlink'])) or
                [before[k] for k in frozen_fields[:5 if known else 6]] != recorded['runtime_stamps']['assets'][name][:5 if known else 6]):
            raise ValueError('Metadata custody is not a recorded physical-only change')
        assets = [r for r in recorded['identity']['assets'] if r[0] == name]
        expected = [before['st_size'], row['sha256_before']]
        if (len(assets) != 1 or assets[0][1:] != expected or recorded['identity']['providers'].get(name) != expected or
                row['sha256_before'] != row['sha256_after']):
            raise ValueError('Metadata custody changed original Provider bytes')
        current = source.stat()
        if any(getattr(current, k) != after[k] for k in fields):
            raise ValueError('Metadata custody current Provider identity differs')
        successor['runtime_stamps']['assets'][name] = [after[k] for k in frozen_fields]
        held.append((installed, source, source_text, after))
    # Bracket all selected sources and alias targets together too.
    for installed, source, source_text, after in held:
        current = source.stat()
        if (not installed.is_symlink() or os.readlink(installed) != source_text or
                any(getattr(current, k) != after[k] for k in fields)):
            raise ValueError('Metadata custody changed during validation')
    return successor


# Current byte validation, not an assertion about the historical linking actor.
# Bindings live only in the validating process and never replace the old seal.
_EXTRACTION_METADATA_BINDINGS = {}


def _extraction_metadata_refresh(root, recorded, expected_sha, selection):
    import stat
    if (not isinstance(selection, dict) or set(selection) != {'original_seal_sha256', 'cache_manifest', 'names'}
            or selection['original_seal_sha256'] != expected_sha
            or not isinstance(selection['names'], list) or not selection['names']
            or any(not isinstance(n, str) for n in selection['names'])
            or selection['names'] != sorted(set(selection['names']))):
        raise ValueError('Invalid extraction metadata refresh selection')
    reference = selection['cache_manifest']
    if (not isinstance(reference, dict) or set(reference) != {'path', 'bytes', 'sha256'}
            or not isinstance(reference['path'], str) or type(reference['bytes']) is not int
            or not 0 < reference['bytes'] <= MAX_MARKER_BYTES
            or not isinstance(reference['sha256'], str)
            or not re.fullmatch('[0-9a-f]{64}', reference['sha256'])):
        raise ValueError('Invalid extraction cache manifest descriptor')
    manifest = Path(reference['path']); backing = manifest.parent
    if (manifest.name != '.complete.json' or not manifest.is_absolute()
            or str(manifest) != os.path.normpath(str(manifest)) or backing == root
            or backing.is_relative_to(root) or root.is_relative_to(backing)):
        raise ValueError('Invalid extraction cache alias root')
    manifest_custody = _restored_dump_custody(manifest)
    if manifest_custody[0][3] != reference['bytes']:
        raise ValueError('Extraction cache manifest size changed')
    with manifest.open('rb') as stream:
        if _full_stamp(os.fstat(stream.fileno())) != manifest_custody[0]:
            raise ValueError('Extraction cache manifest replaced before reading')
        raw = stream.read(reference['bytes'] + 1)
        if _full_stamp(os.fstat(stream.fileno())) != manifest_custody[0]:
            raise ValueError('Extraction cache manifest changed during reading')
    if (len(raw) != reference['bytes'] or hashlib.sha256(raw).hexdigest() != reference['sha256']
            or _restored_dump_custody(manifest) != manifest_custody):
        raise ValueError('Extraction cache manifest changed')
    cached = json.loads(raw)
    if not extraction_ownership_proven(backing):
        raise ValueError('Extraction cache lacks normal owned publication identity')
    names = selection['names']; assets = cached['assets']
    if ([r[0] for r in assets] != names
            or not set(names) <= set(recorded['runtime_stamps']['assets'])
            or cached['identity']['dump_sha256'] != recorded['identity']['verified_input'][0]
            or cached['identity']['index_sha256'] != recorded['identity']['verified_input'][1]):
        raise ValueError('Extraction metadata selection differs from original inputs')
    original_assets = {n: [size, digest] for n, size, digest in recorded['identity']['assets']}
    held = []
    for name, size, digest in assets:
        if (original_assets.get(name) != [size, digest]
                or recorded['runtime_stamps']['snapshot_links'].get(name) is not None):
            raise ValueError('Extraction cache differs from original core assets')
        source, alias = root / name, backing / name
        source_custody, alias_custody = _restored_dump_custody(source), _restored_dump_custody(alias)
        current, alias_current = source.lstat(), alias.lstat()
        old = recorded['runtime_stamps']['assets'][name]
        if (not isinstance(old, list) or len(old) != 6 or any(type(x) is not int for x in old)
                or not stat.S_ISREG(old[2]) or old[3] != size
                or list(source_custody[0][:5]) != old[:5]
                or source_custody[0] != alias_custody[0]
                or current.st_uid != os.geteuid() or alias_current.st_uid != current.st_uid
                or current.st_gid != alias_current.st_gid
                or current.st_nlink < 2 or current.st_nlink != alias_current.st_nlink):
            raise ValueError('Extraction metadata change exceeds owned alias custody: ' + name)
        held.append((name, source_custody, alias_custody, current.st_uid, current.st_gid, current.st_nlink))
    key = (os.getpid(), str(root), expected_sha, json.dumps(selection, sort_keys=True, separators=(',', ':')))
    guard = (manifest_custody, tuple(held))
    previous = _EXTRACTION_METADATA_BINDINGS.get(key)
    if previous is not None and previous != guard:
        raise ValueError('Validated extraction metadata custody changed')
    if previous is None:
        for name, size, digest in assets:
            if stable_file_digest(root / name) != [size, digest]:
                raise ValueError('Extraction core bytes differ from original seal and cache: ' + name)
        validate_extraction_completion(root)
    # Check every alias after the complete hash transaction, including the final
    # member and directories; cached calls earn exactly the same custody checks.
    for name, source_before, alias_before, uid, gid, links in held:
        source, alias = root / name, backing / name
        if (_restored_dump_custody(source) != source_before
                or _restored_dump_custody(alias) != alias_before
                or any((p.lstat().st_uid, p.lstat().st_gid, p.lstat().st_nlink) != (uid, gid, links)
                       for p in (source, alias))):
            raise ValueError('Extraction alias changed during validation: ' + name)
    if _restored_dump_custody(manifest) != manifest_custody:
        raise ValueError('Extraction cache manifest changed during validation')
    _EXTRACTION_METADATA_BINDINGS[key] = guard
    successor = dict(recorded)
    successor['runtime_stamps'] = dict(recorded['runtime_stamps'])
    successor['runtime_stamps']['assets'] = dict(recorded['runtime_stamps']['assets'])
    for name, custody, *_ in held:
        successor['runtime_stamps']['assets'][name] = list(custody[0])
    return successor


def frozen_runtime_context(root, dump, expected_sha, *, provider_update=False, snapshot_metadata_refresh=None, metadata_custody_refresh=None, extraction_metadata_refresh=None, restored_dump=None, restored_indexes=None):
    """Validate an original completed seal, never the current compilation graph.

    None means the old/absent seal cannot authorize source-custody release.
    A claimed new proof that changed is fatal, not a cache miss/reset authority.
    Asset payloads were hashed by the normal seal transaction; its stamped
    identity is checked here without repeating the corpus-sized asset read.
    """
    import stat
    root, dump = Path(root), Path(dump)
    if (not root.is_absolute() or str(root) != os.path.normpath(str(root)) or
            any(path.is_symlink() for path in (root, *root.parents)) or not root.is_dir()):
        raise ValueError('Invalid frozen context root')
    marker = root / COMPLETED_EXPANDER
    if not os.path.lexists(marker):
        return None
    if not re.fullmatch(r'[0-9a-f]{64}', expected_sha):
        raise ValueError('Missing original completed generation binding')
    before = _full_stamp(marker.stat())
    regular(marker)
    with marker.open('rb') as stream:
        raw = stream.read(MAX_MARKER_BYTES + 1)
    if len(raw) > MAX_MARKER_BYTES:
        raise ValueError(f'Oversized extraction cache marker: {marker}')
    if hashlib.sha256(raw).hexdigest() != expected_sha or _full_stamp(marker.stat()) != before:
        raise ValueError('Original completed generation binding changed')
    recorded = json.loads(raw)
    if not isinstance(recorded, dict) or 'runtime_stamps' not in recorded:
        return None
    _provider_update_provenance(recorded)
    original_recorded = recorded
    def refreshed_context(original):
        value = original
        if snapshot_metadata_refresh is not None:
            if provider_update:
                raise ValueError('Snapshot refresh requires the original ready context')
            value = _snapshot_metadata_refresh(root, value, expected_sha, snapshot_metadata_refresh)
        if extraction_metadata_refresh is not None:
            if provider_update:
                raise ValueError('Extraction metadata refresh requires original ready context')
            value = _extraction_metadata_refresh(root, value, expected_sha, extraction_metadata_refresh)
        if metadata_custody_refresh is not None:
            if provider_update:
                raise ValueError('Metadata custody requires an original ready context')
            if snapshot_metadata_refresh is not None:
                legacy = snapshot_metadata_refresh.get('snapshots', [snapshot_metadata_refresh])
                if set(metadata_custody_refresh.get('names', [])) & {row['name'] for row in legacy}:
                    raise ValueError('Snapshot and known-operation custody overlap')
            value = _closed_metadata_custody(root, value, expected_sha, metadata_custody_refresh)
        if restored_indexes is not None:
            if (provider_update or extraction_metadata_refresh is not None
                    or set((metadata_custody_refresh or {}).get('names', [])) & set(RESTORED_INDEX_NAMES)):
                raise ValueError('Restored indexes cannot mix overlapping custody changes')
            _require_restored_indexes(restored_indexes, root, expected_sha)
            if json.loads(restored_indexes[2]) != original['identity']['source']:
                raise ValueError('Restored index original source differs')
            value = dict(value); value['runtime_stamps'] = dict(value['runtime_stamps'])
            value['runtime_stamps']['assets'] = dict(value['runtime_stamps']['assets'])
            for name in RESTORED_INDEX_NAMES:
                value['runtime_stamps']['assets'][name] = list(_full_stamp((root / name).stat()))
        return value
    recorded = refreshed_context(original_recorded)
    identity = recorded['identity']; stamps = recorded['runtime_stamps']
    if restored_dump is not None:
        _require_restored_dump(restored_dump, root, dump, expected_sha, identity['source'])
    if (set(stamps) != {'assets', 'plans', 'snapshot_links'} or
            type(identity.get('version')) is not int or identity.get('version') != COMPLETED_EXPANDER_VERSION):
        raise ValueError('Invalid frozen runtime stamp contract')
    regular(root.parent / '.incomplete')
    if type(provider_update) is not bool:
        raise ValueError('Invalid Provider update validation mode')
    if provider_update:
        regular(root / '.incomplete')
        if (recorded.get('provenance') not in ('ordinary-wikibase-provider-update', 'ordinary-derived-provider-restoration', 'ordinary-file-metadata-provider-update', 'ordinary-sitelinks-provider-update') or
                (root / '.incomplete').read_bytes() != (FILE_METADATA_UPDATE_MARKER if recorded.get('provenance') == 'ordinary-file-metadata-provider-update' else SITELINKS_UPDATE_MARKER if recorded.get('provenance') == 'ordinary-sitelinks-provider-update' else PROVIDER_UPDATE_MARKER)):
            raise ValueError('Provider update is not ready for final verification')
    elif os.path.lexists(root / '.incomplete'):
        return None
    if (root.parent / '.incomplete').read_bytes() != b'expander ready':
        return None
    if {p.name for p in root.parent.iterdir()} != {'.bundle-expander', '.incomplete', 'compile-plan.tsv', 'module-compile-plan.tsv'}:
        raise ValueError('Unexpected frozen expander outputs')
    names = completed_asset_names(root)
    if (set(stamps['assets']) != names or
            set(stamps['snapshot_links']) != names or
            names != {row[0] for row in identity['assets']} or
            len(identity['assets']) != len(names) or
            not {'dict-bundle-expander', 'lua-program.meta'} <= names or
            set(stamps['plans']) != {'compile-plan.tsv', 'module-compile-plan.tsv'}):
        raise ValueError('Incomplete frozen native context inventory')
    def same(path, value):
        if (not isinstance(value, list) or len(value) != 6 or
                any(type(x) is not int for x in value) or
                not stat.S_ISREG(value[2]) or tuple(value) != _full_stamp(path.stat())):
            raise ValueError('Frozen native context identity changed: ' + str(path))
    for name, size, digest in identity['assets']:
        if type(size) is not int or size < 0 or not re.fullmatch('[0-9a-f]{64}', digest):
            raise ValueError('Invalid completed runtime asset digest')
        path = root / name; same(path, stamps['assets'][name])
        if size != path.stat().st_size:
            raise ValueError('Completed runtime asset size changed')
        link = os.readlink(path) if path.is_symlink() else None
        if link != stamps['snapshot_links'][name] or (link is not None and name not in EXPANDER_SNAPSHOTS):
            raise ValueError('Frozen native snapshot path changed')
    for name in stamps['plans']:
        regular(root.parent / name); same(root.parent / name, stamps['plans'][name])
    source = (completed_source_binding(root, dump) if restored_dump is None and restored_indexes is None else
              _completed_source_binding(root, dump,
                  restored_source=identity['source'] if restored_dump is not None else None,
                  restored_indexes=restored_indexes))
    if source != identity['source']:
        raise ValueError('Frozen extraction SourceReceipt changed')
    # Bracket SourceReceipt reads too; a same-name change must not escape.
    for name in names:
        path = root / name; same(path, stamps['assets'][name])
        if (os.readlink(path) if path.is_symlink() else None) != stamps['snapshot_links'][name]:
            raise ValueError('Frozen snapshot changed during source validation')
    for name in stamps['plans']:
        same(root.parent / name, stamps['plans'][name])
    if completed_asset_names(root) != names or _full_stamp(marker.stat()) != before:
        raise ValueError('Frozen native context changed during validation')
    # This proves original context assets only. The custody caller must also
    # authorize the source/attempt and bind private tools, Python and live libs.
    if refreshed_context(original_recorded) != recorded:
        raise ValueError('Metadata custody changed during source validation')
    if restored_dump is not None:
        _require_restored_dump(restored_dump, root, dump, expected_sha, identity['source'])
    return recorded



WIKIBASE_PROVIDER_FILES = frozenset(('wikibase-entities.tsv', 'wikibase-entity-terms.tsv'))
PROVIDER_UPDATE_MARKER = b'updating Wikibase providers\n'


FILE_METADATA_PROVIDER_FILES = frozenset(('file-metadata.tsv',))
FILE_METADATA_UPDATE_MARKER = b'updating file-metadata Provider\n'
SITELINKS_PROVIDER_FILES = frozenset(('wikibase-sitelinks.tsv',))
SITELINKS_UPDATE_MARKER = b'updating sitelinks Provider\n'


def _sitelinks_append(before, after, selected_rows):
    """Preserve every old fact; an explicit empty title is an observed absence."""
    def rows(raw):
        if not raw.endswith(b'\n'):
            raise ValueError('Sitelinks snapshot must end in a newline')
        comments, result = [], {}
        for line in raw[:-1].split(b'\n'):
            if line.startswith(b'#'):
                comments.append(line)
                continue
            cells = line.decode('utf8').split('\t')
            if (len(cells) != 3 or not cells[0] or not cells[1]
                    or any(ord(ch) < 32 or ord(ch) == 127 for cell in cells for ch in cell)
                    or (cells[1] == '*' and cells[2])):
                raise ValueError('Invalid sitelinks Provider row')
            key = tuple(cells[:2])
            if key in result:
                raise ValueError('Duplicate sitelinks Provider pair')
            result[key] = cells[2]
        return comments, result
    old_comments, old = rows(before)
    comments, current = rows(after)
    if (not isinstance(selected_rows, list) or not selected_rows
            or any(not isinstance(row, list) or len(row) != 3
                   or any(not isinstance(value, str) for value in row) for row in selected_rows)
            or selected_rows != sorted(selected_rows)
            or len({tuple(row[:2]) for row in selected_rows}) != len(selected_rows)):
        raise ValueError('Invalid selected sitelinks additions')
    added = {key: value for key, value in current.items() if key not in old}
    if (comments != old_comments or any(current.get(key) != value for key, value in old.items())
            or added != {tuple(row[:2]): row[2] for row in selected_rows}
            or any(tuple(row[:2]) in old for row in selected_rows)):
        raise ValueError('Sitelinks update exceeds its selected additions')
    return selected_rows


def _file_metadata_audio_append(before, after, selected_titles):
    if (not isinstance(selected_titles, list) or not selected_titles or
            any(not isinstance(value, str) for value in selected_titles) or
            len(set(selected_titles)) != len(selected_titles)):
        raise ValueError('File metadata additions need exact distinct selected titles')
    old, current = io.BytesIO(before), io.BytesIO(after)
    header = b'# wikidict-file-metadata-v2\n'
    if old.readline() != header or current.readline() != header:
        raise ValueError('File metadata update requires identical v2 header/schema')
    original = old.readline()
    if not original:
        raise ValueError('File metadata origin must contain named rows')
    prefix = original.partition(b'\t')[0].decode('utf8').partition(':')[0] + ':'
    remaining = set(selected_titles)
    previous = ''
    invalid_control = re.compile(rb'[\x00-\x08\x0a-\x1f\x7f]')
    for line in current:
        if not line.endswith(b'\n'):
            raise ValueError('File metadata update requires identical v2 header/schema')
        row = line[:-1]
        cells = row.decode('utf8').split('\t')
        if len(cells) != 6 or not cells[0] or invalid_control.search(row):
            raise ValueError('Malformed file metadata row')
        title = cells[0]
        if title.strip() != title or ':' not in title or title <= previous:
            raise ValueError('Duplicate or unordered file metadata title')
        previous = title
        # Both snapshots are sorted. An exact match validates the old row too.
        if line == original:
            if not title.startswith(prefix):
                raise ValueError('Ambiguous original file namespace')
            original = old.readline()
        else:
            if title not in remaining:
                raise ValueError('File metadata update differs from selected audio titles')
            if (cells[1:5] != ['1', '0', '0', 'AUDIO'] or not title.startswith(prefix) or
                    not cells[5].startswith(prefix) or cells[5] == prefix or cells[5].strip() != cells[5]):
                raise ValueError('File metadata update permits only zero-axis AUDIO additions')
            remaining.remove(title)
    if original:
        raise ValueError('File metadata update changed or deleted an original row')
    if remaining:
        raise ValueError('File metadata update differs from selected audio titles')
    return sorted(selected_titles)


def _file_metadata_sources(proof):
    sitelinks = 'sitelinks_update' in proof
    update = proof['sitelinks_update' if sitelinks else 'file_metadata_update']
    if (not isinstance(update, dict) or set(update) != {'source', 'source_stamp', 'source_nlink',
            'original_source', 'original_source_stamp', 'original_source_nlink',
            ('added_rows' if sitelinks else 'added_titles'), 'native_graph_stamps', 'native_clang_locator'}):
        raise ValueError('Invalid file metadata update authority')
    graph_stamps = update['native_graph_stamps']
    if (not isinstance(graph_stamps, dict) or set(graph_stamps) != {'extractor', 'llvm', 'runtime', 'leaf', 'main_c', 'zig', 'clang'} or
            any(not isinstance(value, (list, tuple)) or len(value) != 6 or any(type(item) is not int for item in value) for value in graph_stamps.values())):
        raise ValueError('Invalid file metadata native producer stamp authority')
    if (not isinstance(update['native_clang_locator'], dict) or
            _file_metadata_clang_locator(proof['record']['origin_graph']['clang']) != update['native_clang_locator']):
        raise ValueError('Invalid original native Clang locator authority')
    identity = proof['record']['identity']; contents = []
    for name, stamp_key, nlink_key in (('original_source', 'original_source_stamp', 'original_source_nlink'),
                                     ('source', 'source_stamp', 'source_nlink')):
        descriptor = update[name]
        if (not isinstance(descriptor, dict) or set(descriptor) != {'path', 'bytes', 'sha256'} or not isinstance(descriptor.get('path'), str) or
                not valid_digest_record([descriptor.get('bytes'), descriptor.get('sha256')])):
            raise ValueError('Invalid file metadata selected source')
        path = Path(descriptor['path'])
        if (not path.is_absolute() or path.resolve(strict=True) != path or
                any(item.is_symlink() for item in (path, *path.parents)) or Path(proof['root']) in path.parents):
            raise ValueError('Unsafe file metadata selected source')
        regular(path); before = _full_stamp(path.stat())
        if before != tuple(update[stamp_key]) or path.stat().st_nlink != update[nlink_key]:
            raise ValueError('File metadata source physical identity changed')
        raw = path.read_bytes()
        if (len(raw) != descriptor['bytes'] or hashlib.sha256(raw).hexdigest() != descriptor['sha256'] or
                _full_stamp(path.stat()) != before or path.stat().st_nlink != update[nlink_key]):
            raise ValueError('File metadata selected source changed')
        contents.append(raw)
    original = update['original_source']
    if (identity['providers'].get('wikibase-sitelinks.tsv' if sitelinks else 'file-metadata.tsv') != [original['bytes'], original['sha256']] or
            proof['record']['runtime_stamps']['snapshot_links']['wikibase-sitelinks.tsv' if sitelinks else 'file-metadata.tsv'] != original['path'] or
            update['source']['path'] == original['path']):
        raise ValueError('File metadata original Provider authority differs')
    if sitelinks:
        _sitelinks_append(*contents, update['added_rows'])
    else:
        _file_metadata_audio_append(*contents, update['added_titles'])
    return update


def _file_metadata_clang_locator(command):
    located = shutil.which(command)
    if located is None:
        raise ValueError('Original native Clang locator is unavailable')
    initial = os.path.abspath(located); pending = Path(initial); chain = []
    for _ in range(40):
        parts = pending.parts
        for count in range(1, len(parts) + 1):
            path = Path(*parts[:count])
            if path.is_symlink():
                before = path.lstat(); target = os.readlink(path)
                chain.append(dict(path=str(path), target=target,
                    stamp=list(_full_stamp(before)), nlink=before.st_nlink))
                if (_full_stamp(path.lstat()) != _full_stamp(before) or path.lstat().st_nlink != before.st_nlink or os.readlink(path) != target):
                    raise ValueError('Native Clang alias changed during observation')
                next_path = Path(target) if os.path.isabs(target) else path.parent / target
                pending = Path(os.path.normpath(str(next_path.joinpath(*parts[count:]))))
                break
        else:
            resolved = pending.resolve(strict=True)
            regular(resolved)
            return dict(command=command, located=initial, resolved=str(resolved), chain=chain)
    raise ValueError('Native Clang alias chain is cyclic or too deep')


def _file_metadata_native_origin(record, selected_locator=None):
    # A closed worker keeps its original ABI/policy provenance. Authenticate its
    # actual native artifacts and libraries, never current source as old code.
    graph = record['origin_graph']; producer = record['identity']['producer']
    paths = {name: Path(graph[name]) for name in ('extractor', 'llvm', 'runtime', 'leaf', 'main_c', 'zig')}
    locator = _file_metadata_clang_locator(graph['clang'])
    if selected_locator is not None and locator != selected_locator:
        raise ValueError('Original native Clang locator changed')
    paths['clang'] = Path((selected_locator if selected_locator is not None else locator)['resolved'])
    stamps = {name: _full_stamp(path.stat()) for name, path in paths.items()}
    for name in ('runtime', 'leaf', 'main_c'):
        if stable_file_digest(Path(graph[name])) != producer[name]:
            raise ValueError('File metadata update changed native producer input')
    for name in ('extractor', 'llvm'):
        if tool_identity(Path(graph[name])) != producer[name]:
            raise ValueError('File metadata update changed native producer tool')
    if (sha256(Path(graph['zig'])) != producer['zig']['tool_sha256'] or
            tool_identity(paths['clang']) != producer['clang']['tool'] or
            unicode_case_identity() != producer['unicode']):
        raise ValueError('File metadata update changed native toolchain or Unicode')

    if (any(_full_stamp(paths[name].stat()) != value for name, value in stamps.items()) or
            _file_metadata_clang_locator(graph['clang']) != locator):
        raise ValueError('File metadata native producer changed during observation')
    return stamps, locator


def _file_metadata_publication_guard(proof):
    sitelinks = 'sitelinks_update' in proof
    update = proof['sitelinks_update' if sitelinks else 'file_metadata_update']
    for name, stamp_key, nlink_key in (('original_source', 'original_source_stamp', 'original_source_nlink'),
                                     ('source', 'source_stamp', 'source_nlink')):
        path = Path(update[name]['path'])
        if (not path.is_absolute() or path.resolve(strict=True) != path or
                any(item.is_symlink() for item in (path, *path.parents)) or Path(proof['root']) in path.parents):
            raise ValueError('File metadata selected source path changed at publication')
        regular(path)
        if _full_stamp(path.stat()) != tuple(update[stamp_key]) or path.stat().st_nlink != update[nlink_key]:
            raise ValueError('File metadata selected source identity changed at publication')
    graph = proof['record']['origin_graph']
    paths = {name: Path(graph[name]) for name in ('extractor', 'llvm', 'runtime', 'leaf', 'main_c', 'zig')}
    locator = update['native_clang_locator']
    if _file_metadata_clang_locator(graph['clang']) != locator:
        raise ValueError('Original native Clang locator changed at publication')
    paths['clang'] = Path(locator['resolved'])
    if any(_full_stamp(path.stat()) != tuple(update['native_graph_stamps'][name]) for name, path in paths.items()):
        raise ValueError('File metadata native graph changed at publication')


def _provider_update_provenance(record):
    if record.get('provenance') == 'ordinary-linked-expander':
        return
    update = record.get('provider_update')
    restored = record.get('provenance') == 'ordinary-derived-provider-restoration'
    expected_providers = (DERIVED_PROVIDER_FILES if restored else SITELINKS_PROVIDER_FILES
                          if record.get('provenance') == 'ordinary-sitelinks-provider-update' else FILE_METADATA_PROVIDER_FILES
                          if record.get('provenance') == 'ordinary-file-metadata-provider-update' else WIKIBASE_PROVIDER_FILES)
    if (record.get('provenance') not in ('ordinary-wikibase-provider-update', 'ordinary-derived-provider-restoration', 'ordinary-file-metadata-provider-update', 'ordinary-sitelinks-provider-update') or
            not isinstance(update, dict) or
            set(update) != {'original_seal_sha256', 'previous_seal_sha256', 'original_providers'} or
            any(not isinstance(update.get(key), str) or not re.fullmatch('[0-9a-f]{64}', update[key])
                for key in ('original_seal_sha256', 'previous_seal_sha256')) or
            not isinstance(update.get('original_providers'), dict) or
            set(update['original_providers']) != expected_providers or
            any(not valid_digest_record(value) for value in update['original_providers'].values())):
        raise ValueError('Unreviewed completed generation origin')
    if restored and any(record.get('identity', {}).get('providers', {}).get(name) != value
                        for name, value in update['original_providers'].items()):
        raise ValueError('Restored derived Provider bytes differ from their original authority')


def prepare_wikibase_provider_update(root, dump, expected_sha, *, file_metadata_source=None, file_metadata_titles=None, snapshot_metadata_refresh=None, sitelinks_source=None, sitelinks_rows=None):
    """Authenticate the old native generation before its ordinary workspace reset."""
    root, dump = Path(root), Path(dump)
    record = frozen_runtime_context(root, dump, expected_sha, snapshot_metadata_refresh=snapshot_metadata_refresh)
    if record is None:
        return None
    if sitelinks_source is not None and (file_metadata_source is not None or file_metadata_titles is not None or snapshot_metadata_refresh is not None):
        raise ValueError('Mixed singleton Provider update selections')
    if sitelinks_source is None and sitelinks_rows is not None:
        raise ValueError('Sitelinks rows lack selected source')
    singleton_source = sitelinks_source if sitelinks_source is not None else file_metadata_source
    selected = SITELINKS_PROVIDER_FILES if sitelinks_source is not None else FILE_METADATA_PROVIDER_FILES if file_metadata_source is not None else WIKIBASE_PROVIDER_FILES
    if any(not valid_digest_record(record['identity']['providers'].get(name)) for name in selected):
        return None
    if selected in (FILE_METADATA_PROVIDER_FILES, SITELINKS_PROVIDER_FILES):
        if (not isinstance(singleton_source, dict) or set(singleton_source) != {'path', 'bytes', 'sha256'} or not isinstance(singleton_source.get('path'), str) or
                not valid_digest_record([singleton_source.get('bytes'), singleton_source.get('sha256')])):
            raise ValueError('Invalid file metadata selected source')
        if record['provenance'] not in ('ordinary-linked-expander', 'ordinary-sitelinks-provider-update' if selected == SITELINKS_PROVIDER_FILES else 'ordinary-file-metadata-provider-update'):
            raise ValueError('Mixed Provider update families are not selected')
        graph_stamps, clang_locator = _file_metadata_native_origin(record)
    else:
        if file_metadata_titles is not None or record['provenance'] in ('ordinary-file-metadata-provider-update', 'ordinary-sitelinks-provider-update'):
            raise ValueError('File metadata Provider selection differs')
        producer, _ = completed_producer_identity(record['origin_graph'])
        if producer != record['identity']['producer']:
            raise ValueError('Native producer changed before Provider update')
    if tool_identity(root / 'dict-bundle-expander') != record['identity']['runtime_libraries']:
        raise ValueError('Native worker libraries changed before Provider update')
    proof = dict(root=str(root), dump=str(dump), seal_sha256=expected_sha,
                 marker_stamp=_full_stamp((root / COMPLETED_EXPANDER).stat()), record=record)
    if snapshot_metadata_refresh is not None:
        if selected != FILE_METADATA_PROVIDER_FILES:
            raise ValueError('Snapshot refresh is selected only for file metadata update')
        proof['snapshot_metadata_refresh'] = snapshot_metadata_refresh
        proof['original_record'] = read_marker(root / COMPLETED_EXPANDER)
    if selected in (FILE_METADATA_PROVIDER_FILES, SITELINKS_PROVIDER_FILES):
        path = root / next(iter(selected))
        if not path.is_symlink():
            raise ValueError('File metadata update requires an original external alias')
        original = Path(os.readlink(path)); source = Path(singleton_source['path'])
        if not original.is_absolute():
            raise ValueError('File metadata original alias must be absolute')
        value = stable_file_digest(original, snapshot=True)
        proof['sitelinks_update' if selected == SITELINKS_PROVIDER_FILES else 'file_metadata_update'] = dict(
            original_source=dict(path=str(original), bytes=value[0], sha256=value[1]),
            original_source_stamp=_full_stamp(original.stat()), original_source_nlink=original.stat().st_nlink,
            source=singleton_source, source_stamp=_full_stamp(source.stat()), source_nlink=source.stat().st_nlink,
            native_graph_stamps=graph_stamps, native_clang_locator=clang_locator,
            **({'added_rows': sitelinks_rows} if selected == SITELINKS_PROVIDER_FILES else {'added_titles': file_metadata_titles}))
        _file_metadata_sources(proof)
    return proof


def finish_wikibase_provider_update(proof, expected_hashes):
    """Reseal only fresh Provider data; retain the actual linked native origin."""
    root, dump = Path(proof['root']), Path(proof['dump'])
    sitelinks_update = 'sitelinks_update' in proof
    if sitelinks_update and 'file_metadata_update' in proof:
        raise ValueError('Mixed singleton Provider proof')
    file_update = 'file_metadata_update' in proof or sitelinks_update
    selected = SITELINKS_PROVIDER_FILES if sitelinks_update else FILE_METADATA_PROVIDER_FILES if file_update else WIKIBASE_PROVIDER_FILES
    provenance = 'ordinary-sitelinks-provider-update' if sitelinks_update else 'ordinary-file-metadata-provider-update'
    transaction_marker = SITELINKS_UPDATE_MARKER if sitelinks_update else FILE_METADATA_UPDATE_MARKER if file_update else PROVIDER_UPDATE_MARKER
    if (not root.is_absolute() or str(root) != os.path.normpath(str(root)) or
            any(path.is_symlink() for path in (root, *root.parents)) or not root.is_dir()):
        raise ValueError('Invalid Provider update root')
    if {p.name for p in root.parent.iterdir()} != {'.bundle-expander', '.incomplete', 'compile-plan.tsv', 'module-compile-plan.tsv'}:
        raise ValueError('Unexpected Provider update outputs')
    record = proof['record']
    marker = root / COMPLETED_EXPANDER
    if (set(expected_hashes) != selected or
            any(not isinstance(value, str) or not re.fullmatch('[0-9a-f]{64}', value)
                for value in expected_hashes.values()) or
            (root / '.incomplete').read_bytes() != transaction_marker or
            (root.parent / '.incomplete').read_bytes() != b'expander ready'):
        raise ValueError('Invalid Provider update transaction')
    regular(marker)
    if (_full_stamp(marker.stat()) != tuple(proof['marker_stamp']) or
            sha256(marker) != proof['seal_sha256'] or read_marker(marker) != proof.get('original_record', record)):
        raise ValueError('Original native generation proof changed')
    if 'snapshot_metadata_refresh' in proof:
        if _snapshot_metadata_refresh(root, proof['original_record'], proof['seal_sha256'], proof['snapshot_metadata_refresh']) != record:
            raise ValueError('Snapshot metadata refresh differs from selected original')
    _provider_update_provenance(record)
    if ((file_update and record['provenance'] not in ('ordinary-linked-expander', provenance)) or
            (not file_update and record['provenance'] in ('ordinary-file-metadata-provider-update', 'ordinary-sitelinks-provider-update'))):
        raise ValueError('Mixed Provider update families are not selected')
    update = _file_metadata_sources(proof) if file_update else None
    if file_update and expected_hashes != {next(iter(selected)): update['source']['sha256']}:
        raise ValueError('File metadata selected hashes differ')
    identity = record['identity']
    names = completed_asset_names(root)
    original_names = {row[0] for row in identity['assets']}
    if names != original_names:
        raise ValueError('Provider update changed native asset membership')
    native_stamps = {name: stamp for name, stamp in record['runtime_stamps']['assets'].items()
                     if name not in identity['providers']}
    provider_stamps = {name: value for name, value in record['runtime_stamps']['assets'].items()
                       if file_update and name in identity['providers'] and name not in selected}
    def unchanged_native():
        for name, stamp in native_stamps.items():
            regular(root / name)
            if _full_stamp((root / name).stat()) != tuple(stamp):
                raise ValueError('Provider update changed native asset: ' + name)
        for name, stamp in provider_stamps.items():
            path = root / name
            link = os.readlink(path) if path.is_symlink() else None
            if (not path.is_file() or _full_stamp(path.stat()) != tuple(stamp) or
                    link != record['runtime_stamps']['snapshot_links'][name]):
                raise ValueError('File metadata update changed nonselected Provider identity')
        for name, stamp in record['runtime_stamps']['plans'].items():
            regular(root.parent / name)
            if _full_stamp((root.parent / name).stat()) != tuple(stamp):
                raise ValueError('Provider update changed native plan')
        if completed_asset_names(root) != names:
            raise ValueError('Provider update changed native membership')
    unchanged_native()
    providers, stamps, links = {}, {}, {}
    for name in names:
        path = root / name
        stamps[name] = _full_stamp(path.stat())
        links[name] = os.readlink(path) if path.is_symlink() else None
        expected_link = update['source']['path'] if file_update and name in selected else record['runtime_stamps']['snapshot_links'][name]
        if links[name] != expected_link:
            raise ValueError('Provider update changed installed input path')
    provider_names = set(identity['providers'])
    if provider_names not in (set(EXPANDER_SNAPSHOTS),
                              set(EXPANDER_SNAPSHOTS) - {'figure-page-observations.json'}):
        raise ValueError('Unsupported original Provider inventory')
    for name in identity['providers']:
        old = identity['providers'][name]
        path = root / name
        if old is None:
            if os.path.lexists(path):
                raise ValueError('Provider update introduced another input')
            providers[name] = None
            continue
        value = stable_file_digest(path, snapshot=True)
        if name in selected:
            if value[1] != expected_hashes[name]:
                raise ValueError('Installed selected Provider differs from selected authority')
        elif value != old:
            raise ValueError('Provider update changed a nonselected input')
        providers[name] = value
    if completed_source_binding(root, dump) != identity['source']:
        raise ValueError('Provider update changed extraction source')
    if file_update:
        graph_stamps, clang_locator = _file_metadata_native_origin(record, update['native_clang_locator'])
        if ({name: tuple(value) for name, value in update['native_graph_stamps'].items()} != graph_stamps or
                clang_locator != update['native_clang_locator']):
            raise ValueError('File metadata native producer physical identity changed')
    else:
        producer, _ = completed_producer_identity(record['origin_graph'])
        if producer != identity['producer']:
            raise ValueError('Provider update changed native producer')
    if tool_identity(root / 'dict-bundle-expander') != identity['runtime_libraries']:
        raise ValueError('Provider update changed native producer')
    unchanged_native()
    if (sha256(marker) != proof['seal_sha256'] or
            _full_stamp(marker.stat()) != tuple(proof['marker_stamp']) or
            any(_full_stamp((root / name).stat()) != value for name, value in stamps.items()) or
            any((os.readlink(root / name) if (root / name).is_symlink() else None) != value
                for name, value in links.items())):
        raise ValueError('Provider update changed during verification')
    successor = json.loads(json.dumps(record))
    successor['identity']['providers'] = providers
    successor['identity']['assets'] = [[name, *(providers[name] if name in providers else [size, digest])]
                                      for name, size, digest in identity['assets']]
    successor['runtime_stamps']['assets'] = stamps
    successor['runtime_stamps']['snapshot_links'] = links
    previous = record.get('provider_update')
    successor['provider_update'] = dict(
        original_seal_sha256=previous['original_seal_sha256'] if previous else proof['seal_sha256'],
        previous_seal_sha256=proof['seal_sha256'],
        original_providers={name: previous['original_providers'][name] for name in selected} if previous else
            {name: identity['providers'][name] for name in selected})
    successor['provenance'] = (provenance if file_update else 'ordinary-wikibase-provider-update')
    # Ready is published by the builder only after binding this exact successor
    # in ordinary state.json. A write failure leaves the incomplete marker.
    if file_update:
        if 'snapshot_metadata_refresh' in proof:
            _snapshot_metadata_refresh(root, proof['original_record'], proof['seal_sha256'], proof['snapshot_metadata_refresh'])
        _file_metadata_publication_guard(proof)
    write_private_marker(marker, successor)
    if file_update:
        if 'snapshot_metadata_refresh' in proof:
            _snapshot_metadata_refresh(root, proof['original_record'], proof['seal_sha256'], proof['snapshot_metadata_refresh'])
        _file_metadata_publication_guard(proof)
        unchanged_native()
    return sha256(marker)


DERIVED_PROVIDER_FILES = WIKIBASE_PROVIDER_FILES | frozenset(('category-stats.tsv', 'category-tree.tsv'))


def _derived_provider_context(proof, *, installed):
    root, dump = Path(proof['root']), Path(proof['dump'])
    if (not root.is_absolute() or str(root) != os.path.normpath(str(root)) or
            any(path.is_symlink() for path in (root, *root.parents)) or not root.is_dir()):
        raise ValueError('Invalid derived Provider restoration root')
    marker = root / COMPLETED_EXPANDER
    regular(marker)
    if (_full_stamp(marker.stat()) != tuple(proof['marker_stamp']) or
            sha256(marker) != proof['seal_sha256'] or read_marker(marker) != proof['record']):
        raise ValueError('Original derived Provider seal changed')
    record = proof['record']; _provider_update_provenance(record)
    if record.get('provenance') in ('ordinary-file-metadata-provider-update', 'ordinary-sitelinks-provider-update'):
        raise ValueError('Mixed Provider restoration/update families are not selected')
    identity, stamps = record['identity'], record['runtime_stamps']
    if (identity.get('version') != COMPLETED_EXPANDER_VERSION or
            set(stamps) != {'assets', 'plans', 'snapshot_links'} or
            set(proof['sources']) != DERIVED_PROVIDER_FILES or
            set(proof['source_stamps']) != DERIVED_PROVIDER_FILES or
            set(stamps['plans']) != {'compile-plan.tsv', 'module-compile-plan.tsv'}):
        raise ValueError('Invalid derived Provider restoration inventory')
    assets = {name: [size, digest] for name, size, digest in identity['assets']}
    if len(assets) != len(identity['assets']) or set(stamps['assets']) != set(assets) or set(stamps['snapshot_links']) != set(assets):
        raise ValueError('Derived Provider asset membership differs')
    if {path.name for path in root.parent.iterdir()} != {'.bundle-expander', '.incomplete', 'compile-plan.tsv', 'module-compile-plan.tsv'}:
        raise ValueError('Derived Provider parent membership differs')
    regular(root.parent / '.incomplete')
    if (root.parent / '.incomplete').read_bytes() != b'expander ready':
        raise ValueError('Derived Provider parent is not ready')
    if installed:
        regular(root / '.incomplete')
        if (root / '.incomplete').read_bytes() != PROVIDER_UPDATE_MARKER:
            raise ValueError('Missing derived Provider transaction marker')
    elif os.path.lexists(root / '.incomplete'):
        raise ValueError('Derived Provider origin is incomplete')
    names = set(walk_assets(root))
    for path in root.iterdir():
        if path.name in (TREE, '.incomplete', '.compiler-inputs.lock', COMPLETED_EXPANDER):
            continue
        if path.name not in DERIVED_PROVIDER_FILES and not path.is_file():
            raise ValueError('Unexpected derived Provider context member')
        names.add(path.name)
    if names != set(assets):
        raise ValueError('Derived Provider native membership changed')
    for name in names:
        path = root / name
        size, digest = assets[name]
        if (type(size) is not int or size < 0 or not isinstance(digest, str) or
                re.fullmatch('[0-9a-f]{64}', digest) is None):
            raise ValueError('Invalid original derived Provider asset digest')
        if name in DERIVED_PROVIDER_FILES:
            descriptor = proof['sources'][name]
            if (not isinstance(descriptor, dict) or set(descriptor) != {'path', 'bytes', 'sha256'} or
                    not valid_digest_record([descriptor.get('bytes'), descriptor.get('sha256')]) or
                    identity['providers'].get(name) != assets[name] or
                    assets[name] != [descriptor['bytes'], descriptor['sha256']]):
                raise ValueError('Derived Provider source authority differs')
            source = Path(descriptor['path'])
            if (not source.is_absolute() or source.resolve(strict=True) != source or
                    any(item.is_symlink() for item in (source, *source.parents))):
                raise ValueError('Unsafe derived Provider source path')
            regular(source)
            if _full_stamp(source.stat()) != tuple(proof['source_stamps'][name]):
                raise ValueError('Derived Provider selected source changed')
            if stable_file_digest(source, snapshot=True) != assets[name]:
                raise ValueError('Derived Provider source content differs')
            if not path.is_symlink():
                raise ValueError('Derived Provider alias role changed')
            expected_link = str(source) if installed else stamps['snapshot_links'][name]
            if not isinstance(expected_link, str) or not Path(expected_link).is_absolute() or os.readlink(path) != expected_link:
                raise ValueError('Derived Provider alias target changed')
            if not installed and os.path.lexists(Path(expected_link)):
                raise ValueError('Derived Provider target is not missing')
        else:
            if not path.is_file() or (path.is_symlink() and name not in EXPANDER_SNAPSHOTS):
                raise ValueError('Invalid original derived Provider asset role')
            if _full_stamp(path.stat()) != tuple(stamps['assets'][name]) or path.stat().st_size != assets[name][0]:
                raise ValueError('Derived Provider changed original native asset: ' + name)
            if (os.readlink(path) if path.is_symlink() else None) != stamps['snapshot_links'][name]:
                raise ValueError('Derived Provider changed original native alias')
    for name, value in stamps['plans'].items():
        regular(root.parent / name)
        if _full_stamp((root.parent / name).stat()) != tuple(value):
            raise ValueError('Derived Provider changed original native plan')
    if completed_source_binding(root, dump) != identity['source']:
        raise ValueError('Derived Provider changed original extraction source')
    return record


def prepare_derived_provider_restoration(root, dump, expected_sha, sources):
    """Authenticate missing aliases against the original sealed Provider bytes.

    This is a restoration of data beside an unchanged native worker. It never
    recompiles a producer or interprets current source as its historical policy.
    The caller owns the original edition locks through finish and ready publish.
    """
    root, dump = Path(root), Path(dump)
    marker = root / COMPLETED_EXPANDER
    if not re.fullmatch('[0-9a-f]{64}', expected_sha):
        raise ValueError('Invalid original derived Provider seal binding')
    before = _full_stamp(marker.stat()); raw = marker.read_bytes()
    if hashlib.sha256(raw).hexdigest() != expected_sha or _full_stamp(marker.stat()) != before:
        raise ValueError('Original derived Provider seal changed while reading')
    if not isinstance(sources, dict) or set(sources) != DERIVED_PROVIDER_FILES:
        raise ValueError('Derived Provider restoration requires exactly four sources')
    if any(not isinstance(value, dict) or set(value) != {'path', 'bytes', 'sha256'} or
           not isinstance(value['path'], str) or not valid_digest_record([value['bytes'], value['sha256']])
           for value in sources.values()):
        raise ValueError('Invalid derived Provider selected source descriptor')
    proof = dict(root=str(root), dump=str(dump), seal_sha256=expected_sha,
                 marker_stamp=before, record=json.loads(raw), sources=json.loads(json.dumps(sources)),
                 source_stamps={name: _full_stamp(Path(value['path']).stat()) for name, value in sources.items()})
    _derived_provider_context(proof, installed=False)
    # Keep the exact old bytes/mode outside the frozen expander-parent inventory.
    archive = root.parent.parent / ('.completed-before-derived-provider-' + expected_sha + '.json')
    if not os.path.lexists(archive):
        descriptor, temporary = tempfile.mkstemp(prefix=archive.name + '.part-', dir=archive.parent)
        try:
            with os.fdopen(descriptor, 'wb') as stream:
                stream.write(raw); stream.flush()
                os.fchmod(stream.fileno(), marker.stat().st_mode & 0o7777)
            os.link(temporary, archive, follow_symlinks=False)
        finally:
            os.unlink(temporary)
    regular(archive)
    if archive.read_bytes() != raw or (archive.stat().st_mode & 0o7777) != (marker.stat().st_mode & 0o7777):
        raise ValueError('Original derived Provider archive differs')
    proof['original_seal_archive'] = dict(path=str(archive), bytes=len(raw), sha256=expected_sha)
    _derived_provider_context(proof, installed=False)
    return proof


def finish_derived_provider_restoration(proof):
    """Publish new physical custody for byte-identical restored Provider aliases."""
    record = _derived_provider_context(proof, installed=True)
    root, dump = Path(proof['root']), Path(proof['dump'])
    archive = proof['original_seal_archive']; path = Path(archive['path'])
    if path != root.parent.parent / ('.completed-before-derived-provider-' + proof['seal_sha256'] + '.json'):
        raise ValueError('Derived Provider original archive path differs')
    regular(path)
    if (stable_file_digest(path) != [archive['bytes'], archive['sha256']] or archive['sha256'] != proof['seal_sha256'] or
            (path.stat().st_mode & 0o7777) != (proof['marker_stamp'][2] & 0o7777)):
        raise ValueError('Derived Provider original archive changed')
    if tool_identity(root / 'dict-bundle-expander') != record['identity']['runtime_libraries']:
        raise ValueError('Derived Provider original native worker or libraries changed')
    successor = json.loads(json.dumps(record))
    for name in DERIVED_PROVIDER_FILES:
        successor['runtime_stamps']['assets'][name] = list(_full_stamp((root / name).stat()))
        successor['runtime_stamps']['snapshot_links'][name] = str(Path(proof['sources'][name]['path']))
    successor['provenance'] = 'ordinary-derived-provider-restoration'
    successor['provider_update'] = dict(original_seal_sha256=proof['seal_sha256'],
        previous_seal_sha256=proof['seal_sha256'],
        original_providers={name: record['identity']['providers'][name] for name in DERIVED_PROVIDER_FILES})
    _provider_update_provenance(successor)
    _derived_provider_context(proof, installed=True)
    write_private_marker(root / COMPLETED_EXPANDER, successor)
    digest = sha256(root / COMPLETED_EXPANDER)
    if frozen_runtime_context(root, dump, digest, provider_update=True) != successor:
        raise ValueError('Restored Provider successor is not a complete current context')
    return digest


def completed_link_provenance(root, graph):
    """Retain the actual ordered link inputs before ordinary scratch retirement."""
    import shlex
    llvm = root / "llvm"
    snapshot = read_marker(llvm / ".object-identity.json")
    if (not isinstance(snapshot, dict) or not isinstance(snapshot.get("identity"), dict) or
            not valid_abi_provenance(snapshot.get("provenance", {}).get("abi"))):
        raise ValueError("Missing completed native object provenance")
    identity = snapshot["identity"]
    entries = list(object_entries(identity))
    response = llvm / "module-objects.rsp"
    response_digest = stable_file_digest(response)
    names = shlex.split(response.read_text())
    if names != [str(llvm / name) for name, _ in entries]:
        raise ValueError("Completed worker link order differs from object plan")
    leaf = stable_file_digest(Path(graph["leaf"]))
    if (identity.get("value_leaf", {}).get("bitcode") != leaf or
            snapshot["provenance"]["abi"] != abi_provenance(Path(graph["project_root"])) or
            stable_file_digest(llvm / "value_leaf.bc") != leaf or
            identity.get("program_meta_sha256") != stable_file_digest(root / "lua-program.meta")[1] or
            identity.get("batch_plan_sha256") != stable_file_digest(root.parent / "compile-plan.tsv")[1]):
        raise ValueError("Completed worker paired leaf or program metadata differs")
    objects = [[name, *stable_file_digest(llvm / name)] for name, _ in entries]
    if stable_file_digest(response) != response_digest:
        raise ValueError("Completed worker link response changed")
    return dict(object_inputs=snapshot, ordered_objects=objects, response=response_digest)


def seal_completed_expander(root, dump, dump_sha, index_sha, graph, snapshots, *, frontend_reference=None):
    marker = root / COMPLETED_EXPANDER
    # The caller has joined native compilation/linking and moved program metadata,
    # but must not publish its ordinary ready marker until this seal succeeds.
    regular(root / ".incomplete")
    regular(root.parent / ".incomplete")
    if (root / ".incomplete").read_bytes() != b"building" or os.path.lexists(marker):
        raise ValueError("Unexpected completed expander sealing state")
    names = completed_asset_names(root, sealing=True)
    stamps = {name: _full_stamp((root / name).stat()) for name in names}
    snapshot_links = {name: os.readlink(root / name) if (root / name).is_symlink() else None for name in names}
    plan_stamps = {name: _full_stamp((root.parent / name).stat()) for name in ('compile-plan.tsv', 'module-compile-plan.tsv')}
    restored_binding = None
    if frontend_reference is not None:
        authority = _frontend_reference(frontend_reference)
        selected = authority.get('sealed_frontend') if isinstance(authority, dict) else None
        if isinstance(selected, dict) and 'restored_dump' in selected:
            frontend = _frontend_selection(frontend_reference, graph, validate_roles=False)
            restored_binding = frontend[0]['_restored_dump_binding']
    identity = completed_expander_identity(root, dump, dump_sha, index_sha, graph, snapshots,
                                           restored_dump=restored_binding)
    link = completed_link_provenance(root, graph)
    if frontend_reference is not None:
        _, _, _, original, _, _, _ = _frontend_selection(frontend_reference, graph, validate_roles=False,
                                                         producer_observation=identity['producer'],
                                                         restored_dump=restored_binding)
        _frontend_identity_matches(original['identity'], identity)
        if (link['object_inputs']['identity'] != original['link']['object_inputs']['identity'] or
                link['ordered_objects'] != original['link']['ordered_objects'] or
                link['object_inputs']['provenance'].get('frontend_reference') != frontend_reference):
            raise ValueError('Sealed frontend linked objects or original selection changed')
    if (completed_asset_names(root, sealing=True) != names or
            any(_full_stamp((root / name).stat()) != stamp for name, stamp in stamps.items())):
        raise ValueError('Expander output changed before sealing')
    if (any(_full_stamp((root.parent / name).stat()) != value for name, value in plan_stamps.items()) or
            any((os.readlink(root / name) if (root / name).is_symlink() else None) != value for name, value in snapshot_links.items())):
        raise ValueError('Expander context changed before runtime sealing')
    write_private_marker(marker, dict(identity=identity, origin_graph=graph, link=link,
                                     runtime_stamps=dict(assets=stamps, plans=plan_stamps, snapshot_links=snapshot_links),
                                     provenance="ordinary-linked-expander"))
    return 0


def finalize_sealed_expander(root, dump, expected_sha, expected_graph, *, helper_transition=None, project_root=None):
    """Finish only the normal post-link transition of an authenticated seal."""
    import stat
    root, dump = Path(root), Path(dump)
    marker = root / COMPLETED_EXPANDER
    regular(marker)
    raw = marker.read_bytes()
    if not re.fullmatch('[0-9a-f]{64}', expected_sha) or hashlib.sha256(raw).hexdigest() != expected_sha:
        raise ValueError('Sealed recovery proof changed')
    record = json.loads(raw)
    if record.get('provenance') != 'ordinary-linked-expander' or record.get('origin_graph') != expected_graph:
        raise ValueError('Sealed recovery selected another native graph')
    observation_graph = expected_graph
    if not Path(expected_graph['project_root']).is_absolute():
        # Ordinary drivers record "." from their authenticated source root.
        # Recovery can run elsewhere; observe that root without rewriting the
        # original graph or changing the process-wide working directory.
        if expected_graph['project_root'] != '.' or project_root is None:
            raise ValueError('Sealed recovery requires a bound original project root')
        project_root = Path(project_root)
        if (not project_root.is_absolute() or str(project_root) != os.path.normpath(str(project_root)) or
                any(path.is_symlink() for path in (project_root, *project_root.parents)) or
                not project_root.is_dir()):
            raise ValueError('Invalid sealed recovery project root')
        if any(not Path(expected_graph[name]).is_absolute() for name in
               ('extractor', 'llvm', 'runtime', 'leaf', 'main_c', 'zig')):
            raise ValueError('Unbound relative sealed recovery artifact')
        observation_graph = dict(expected_graph, project_root=str(project_root))
    producer, _ = completed_producer_identity(observation_graph)
    original_producer = record['identity']['producer']
    if producer != original_producer:
        if not isinstance(helper_transition, dict) or set(helper_transition) != {'original', 'current'}:
            raise ValueError('Sealed recovery native producer changed')
        old, current = helper_transition['original'], helper_transition['current']
        for descriptor in (old, current):
            if (set(descriptor) != {'path', 'bytes', 'sha256'} or
                    stable_file_digest(Path(descriptor['path'])) != [descriptor['bytes'], descriptor['sha256']]):
                raise ValueError('Sealed recovery helper policy changed')
        if Path(current['path']).resolve() != (Path(observation_graph['project_root']) / 'tools/extraction_cache.py').resolve():
            raise ValueError('Sealed recovery policy belongs to another graph')
        before = json.loads(json.dumps(original_producer))
        after = json.loads(json.dumps(producer))
        old_policy = dict(before['policy']); new_policy = dict(after['policy'])
        if (old_policy.pop('tools/extraction_cache.py') != [old['bytes'], old['sha256']] or
                new_policy.pop('tools/extraction_cache.py') != [current['bytes'], current['sha256']]):
            raise ValueError('Sealed recovery helper transition differs from original seal')
        before['policy'] = old_policy; after['policy'] = new_policy
        if before != after:
            raise ValueError('Sealed recovery changed native producer or ABI')
    if not os.path.lexists(root / '.incomplete'):
        if frozen_runtime_context(root, dump, expected_sha) != record:
            raise ValueError('Sealed recovery is not finalized')
        return record
    regular(root / '.incomplete'); regular(root.parent / '.incomplete')
    if (root / '.incomplete').read_bytes() != b'building':
        raise ValueError('Sealed recovery is not a post-link build')
    scratch = root / 'llvm'
    retired = root.parent.parent / ('.sealed-llvm-' + expected_sha)
    if os.path.lexists(retired):
        if os.path.lexists(scratch) or retired.is_symlink() or not retired.is_dir():
            raise ValueError('Conflicting sealed recovery scratch retirement')
        # An interrupted retirement is restored only for the complete original
        # seal/link validation below; no partial object plan is accepted.
        retired.rename(scratch)
    snapshots = {name: (record['runtime_stamps']['snapshot_links'].get(name) or str(root / name))
                 if value is not None else None for name, value in record['identity']['providers'].items()}
    verified = record['identity']['verified_input']
    identity = completed_expander_identity(root, dump, verified[0], verified[1],
                                          observation_graph, snapshots)
    identity['producer'] = original_producer
    if identity != record['identity'] or completed_link_provenance(root, observation_graph) != record['link']:
        raise ValueError('Sealed recovery compiled assets changed')
    # This is the same owned scratch tree retired by the normal driver after
    # sealing. Refuse foreign links/owners before applying that transition.
    for directory, dirs, files in os.walk(scratch, followlinks=False):
        for name in [*dirs, *files]:
            path = Path(directory) / name
            info = path.lstat()
            if info.st_uid != os.geteuid() or stat.S_ISLNK(info.st_mode) or not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                raise ValueError('Unsafe sealed recovery LLVM scratch')
    if marker.read_bytes() != raw:
        raise ValueError('Sealed recovery changed before finalization')
    scratch.rename(retired)
    # Publish the parent first: a failed write still leaves the child building
    # marker and the complete renamed scratch available for revalidation.
    (root.parent / '.incomplete').write_bytes(b'expander ready')
    (root / '.incomplete').unlink()
    if frozen_runtime_context(root, dump, expected_sha) != record:
        raise ValueError('Sealed recovery ready transition changed')
    # A cleanup failure occurs after valid readiness. An ordinary retry can use
    # the sealed generation; any remaining retired prefix stays as evidence.
    shutil.rmtree(retired)
    return record


def _phase_thread_cpu():
    try:
        return time.thread_time()
    except (AttributeError, OSError, NotImplementedError):
        return None


class _PhaseTiming:
    """In-process diagnostics only; counts describe known files, not physical I/O."""
    def __init__(self, emit):
        self.emit = emit
        self.name = None

    def switch(self, name):
        self.finish("success")
        try:
            wall, cpu = time.monotonic(), _phase_thread_cpu()
            self.wall, self.cpu, self.name = wall, cpu, name
            self.counts = {"files": None, "bytes": None}
        except Exception:
            self.name = None

    def count(self, **known):
        try:
            self.counts.update(known)
        except Exception:
            pass

    def finish(self, status):
        if self.name is None:
            return
        name, self.name = self.name, None
        try:
            wall, cpu = time.monotonic(), _phase_thread_cpu()
            available = cpu is not None and self.cpu is not None
            self.emit(name, status, dict(
                seconds=round(wall - self.wall, 6),
                thread_cpu_seconds=round(cpu - self.cpu, 6) if available else None,
                thread_cpu_available=available, **self.counts))
        except Exception:
            # Clock/output failure cannot replace a producer result or error.
            pass


def optional_phase_timing(emit):
    try:
        if os.environ.get(PHASE_TIMING_ENV) == "1":
            return _PhaseTiming(emit)
    except Exception:
        pass
    return None


def _cache_phase_event(name, status, fields):
    print("EXTRACTION_CACHE_PHASE " + json.dumps(dict(
        action="publish", phase=name, status=status,
        scope="helper-subphase", **fields), sort_keys=True),
        file=sys.stderr, flush=True)


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


def identity_probe_timeout(default):
    """Use the admitted job's remaining wall budget, not a host-idle timer."""
    raw = os.environ.get('WIKIDICT_BUILD_DEADLINE_MONOTONIC')
    if raw is None:
        return default
    deadline = float(raw)
    remaining = deadline - time.monotonic()
    if not math.isfinite(deadline) or not 0 < remaining <= 7 * 24 * 60 * 60:
        raise ValueError("Invalid or expired build identity-probe deadline")
    return remaining


def tool_identity(executable, *, _digest_memo=None):
    """Digest the emitted extractor and its resolved dynamic libraries."""
    regular(executable)
    result = subprocess.run(["ldd", str(executable)], capture_output=True,
                            text=True, check=True, timeout=identity_probe_timeout(30))
    libraries = set()
    for line in result.stdout.splitlines():
        match = re.search(r"(?:=>\s*)?(/[^\s]+)\s*\(", line)
        if match:
            libraries.add(Path(match.group(1)))
        elif "not found" in line:
            raise ValueError(f"Unresolved extractor library: {line}")
    # Only a live object-cache transaction supplies this process-local memo.
    # Resolve/open and guard every current library path even on memo hits.
    def digest(path):
        if _digest_memo is None:
            return sha256(path)
        return stable_file_digest(path, snapshot=True, _memo=_digest_memo)[1]
    return {
        "extractor_sha256": digest(executable),
        "libraries": [[str(path), digest(path)] for path in sorted(libraries)],
    }


def unicode_case_identity():
    # Match the dynamically loaded backend used by namespace title casing.
    # ldd alone omits dlopen libraries.
    import ctypes
    try: library = ctypes.CDLL("libunistring.so.5")
    except OSError: library = ctypes.CDLL("libunistring.so")
    try: normalization = ctypes.CDLL("libutf8proc.so.3")
    except OSError: normalization = ctypes.CDLL("libutf8proc.so")
    if not hasattr(normalization,"utf8proc_decompose"):raise ValueError("Missing NFC backend")
    if not hasattr(library, "u8_totitle"):raise ValueError("Missing title-case backend")
    paths = {Path(line.split(maxsplit=5)[5].strip()).resolve()
             for line in Path("/proc/self/maps").read_text().splitlines()
             if len(line.split(maxsplit=5)) == 6 and ("/libunistring.so" in line or "/libutf8proc.so" in line)}
    if len(paths) != 2:raise ValueError("Ambiguous title-case backend identity")
    return {"libraries":[{"path":str(path),"sha256":sha256(path)} for path in sorted(paths)]}


def identity(executable, dump_sha256, index_sha256, namespace_sha256, transclusion_redirects_sha256=None, page_redirects_sha256=None):
    if not all(re.fullmatch(r"[0-9a-fA-F]{64}", value)
               for value in (dump_sha256, index_sha256, namespace_sha256)):
        raise ValueError("Invalid verified staged input digest")
    return {"version": EXTRACTION_IDENTITY_VERSION, "extractor_args": list(EXTRACTOR_ARGS),
            "dump_sha256": dump_sha256.lower(),
            "index_sha256": index_sha256.lower(),
            "namespace_registry_sha256": namespace_sha256.lower(),
            "transclusion_redirects_sha256": transclusion_redirects_sha256,
            "page_redirects_sha256": page_redirects_sha256,
            "unicode_case": unicode_case_identity(),
            "tool": tool_identity(executable)}


def cache_path(root, key):
    if root.is_symlink():
        raise ValueError(f"Unsafe extraction cache root: {root}")
    return root / key


def extraction_files(root):
    # Legacy generations have no full-scan proof and retain the tail guard.
    proof = "extraction-completion.json"
    return (*FILES, proof) if os.path.lexists(root / proof) else FILES


def walk_assets(root):
    """Return every allowed regular file, including each module source."""
    names = list(extraction_files(root))
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


def last_nonempty_line(path, tail_bytes=256 * 1024):
    regular(path)
    size = path.stat().st_size
    if size == 0:
        raise ValueError(f"Empty extraction asset: {path}")
    with path.open("rb") as stream:
        stream.seek(max(0, size - tail_bytes))
        raw = stream.read()
    lines = [line for line in raw.splitlines() if line]
    if not lines:
        raise ValueError(f"No data rows in extraction asset: {path}")
    return lines[-1]


def validate_extraction_completion(root):
    """Reject internally consistent but prematurely terminated extractions."""
    ready = root / "compiler-inputs.ready"
    regular(ready)
    if ready.read_bytes() != b"complete\n":
        raise ValueError("Invalid compiler inputs completion marker")

    stream_fields = last_nonempty_line(root / "dump-streams.tsv").split(b"\t")
    page_fields = last_nonempty_line(root / "page-index.tsv").split(b"\t")
    if len(stream_fields) != 3 or len(page_fields) < 3:
        raise ValueError("Invalid extraction stream/page tail")
    try:
        final_stream = int(stream_fields[0])
        final_page_stream = int(page_fields[0])
    except ValueError as exc:
        raise ValueError("Invalid extraction stream/page id") from exc
    proof_path = root / "extraction-completion.json"
    if os.path.lexists(proof_path):
        regular(proof_path)
        with proof_path.open("rb") as stream:
            raw = stream.read(4097)
        if len(raw) > 4096:
            raise ValueError("Oversized extraction completion proof")
        proof = json.loads(raw)
        fields = {"schema", "version", "expected_stream_count", "consumed_stream_count", "pages"}
        if (not isinstance(proof, dict) or set(proof) != fields or
                proof["schema"] != "wikidict.extraction-completion.v1" or
                type(proof["version"]) is not int or proof["version"] != 1 or
                any(type(proof[name]) is not int or not 0 < proof[name] <= 2**64 - 1
                    for name in ("expected_stream_count", "consumed_stream_count", "pages")) or
                proof["expected_stream_count"] != proof["consumed_stream_count"] or
                proof["expected_stream_count"] != final_stream + 1 or
                not 0 <= final_page_stream <= final_stream):
            raise ValueError("Invalid extraction completion proof")
        title_path = root / "page-title-index.bin"
        regular(title_path)
        with title_path.open("rb") as stream:
            header = stream.read(64)
        if len(header) != 64 or header[:8] != b"DPTIDX01":
            raise ValueError("Invalid page title index header")
        kind, capacity, rows, unique, page_size = (
            int.from_bytes(header[offset:offset + 8], "little") for offset in range(8, 48, 8))
        if (kind not in (1, 2) or capacity < 8 or capacity & (capacity - 1) or
                unique > rows or unique > capacity or title_path.stat().st_size != 64 + 16 * capacity or
                page_size != (root / "page-index.tsv").stat().st_size or rows != proof["pages"]):
            raise ValueError("Extraction completion page index mismatch")
    elif final_page_stream != final_stream:
        raise ValueError(
            f"Incomplete extraction: final page stream {final_page_stream} != final stream {final_stream}")


EXTRACTION_OWNERSHIP = "wikidict.extraction-owned-assets.v1"


def extraction_ownership_proven(root):
    """Bound retirement to a structurally complete marker for this exact key.

    This is an ownership protocol check, not a replacement for the full asset
    validation required on reuse. Unproven backing is never retired implicitly.
    """
    try:
        if root.is_symlink() or not root.is_dir():
            return False
        record = read_marker(root / ".complete.json")
        if (not isinstance(record, dict) or
                record.get("asset_ownership") != EXTRACTION_OWNERSHIP or
                not isinstance(record.get("identity"), dict) or
                not record["identity"] or not isinstance(record.get("assets"), list)):
            return False
        identity_record = record["identity"]
        digest = lambda value: isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value)
        fields = {"version", "extractor_args", "dump_sha256", "index_sha256",
                  "namespace_registry_sha256", "transclusion_redirects_sha256",
                  "page_redirects_sha256", "unicode_case", "tool"}
        if (set(record) != {"identity", "assets", "asset_ownership"} or
                set(identity_record) != fields or type(identity_record["version"]) is not int or
                identity_record["version"] != EXTRACTION_IDENTITY_VERSION or
                identity_record["extractor_args"] != list(EXTRACTOR_ARGS) or
                not all(digest(identity_record[name]) for name in
                        ("dump_sha256", "index_sha256", "namespace_registry_sha256")) or
                any(identity_record[name] is not None and not digest(identity_record[name]) for name in
                    ("transclusion_redirects_sha256", "page_redirects_sha256"))):
            return False
        tool, unicode_case = identity_record["tool"], identity_record["unicode_case"]
        if (not isinstance(tool, dict) or set(tool) != {"extractor_sha256", "libraries"} or
                not digest(tool["extractor_sha256"]) or not isinstance(tool["libraries"], list) or
                any(not isinstance(row, list) or len(row) != 2 or
                    not isinstance(row[0], str) or not Path(row[0]).is_absolute() or not digest(row[1])
                    for row in tool["libraries"]) or
                not isinstance(unicode_case, dict) or set(unicode_case) != {"libraries"} or
                not isinstance(unicode_case["libraries"], list) or
                any(not isinstance(row, dict) or set(row) != {"path", "sha256"} or
                    not isinstance(row["path"], str) or not Path(row["path"]).is_absolute() or
                    not digest(row["sha256"]) for row in unicode_case["libraries"])):
            return False
        key = hashlib.sha256(json.dumps(identity_record, sort_keys=True).encode()).hexdigest()
        if root.name not in (key, ".stale-" + key):
            return False
        names = []
        for row in record["assets"]:
            if (not isinstance(row, list) or len(row) != 3 or
                    not isinstance(row[0], str) or type(row[1]) is not int or row[1] < 0 or
                    not isinstance(row[2], str) or not re.fullmatch(r"[0-9a-f]{64}", row[2])):
                return False
            name = row[0]
            if (name not in (*FILES, "extraction-completion.json") and
                    not (name.startswith(TREE + "/") and
                         all(part not in ("", ".", "..") for part in name.split("/")))):
                return False
            names.append(name)
        return (names == sorted(set(names)) and set(FILES) <= set(names))
    except (OSError, ValueError, json.JSONDecodeError, TypeError):
        return False


def prune_extraction_generations(parent, current):
    # An unmarked legacy name can still back retained symlinks. Never infer
    # retirement from age, key inequality, or missing/corrupt metadata.
    for older in parent.iterdir():
        if (older != current and re.fullmatch(r"[0-9a-f]{64}", older.name) and
                extraction_ownership_proven(older)):
            shutil.rmtree(older)


def prune_extraction_partials(parent):
    now = time.time()
    for path in parent.iterdir():
        if path.is_symlink() or not path.is_dir():
            continue
        abandoned = path.name.startswith(".part-") or (
            re.fullmatch(r"\.stale-[0-9a-f]{64}", path.name) and
            extraction_ownership_proven(path))
        if abandoned and now - path.stat().st_mtime > 24 * 3600:
            shutil.rmtree(path)


def validate(root, expected, *, validated_names=None):
    """Optionally retain the asset names that passed the full content check."""
    marker = root / ".complete.json"
    record = read_marker(marker)
    if not isinstance(record, dict):
        return False
    if ("asset_ownership" in record and
            record["asset_ownership"] != EXTRACTION_OWNERSHIP):
        return False
    if record.get("identity") != expected:
        return False
    assets = record.get("assets")
    if not isinstance(assets, list) or assets != record_assets(root):
        return False
    validate_extraction_completion(root)
    if validated_names is not None:
        validated_names.extend(row[0] for row in assets)
    return True


def _owned_extraction_link(source, destination):
    """Link immutable bytes without changing inode-bound SourceReceipt indexes.

    link() changes ctime/nlink. SourceReceipt v2 deliberately zeros index ctime
    and records no nlink; its full-ctime dump source is never linked here.
    Consumers must replace generated files atomically, never mutate shared bytes.
    """
    source, destination = Path(source), Path(destination)
    regular(source)
    before = source.stat()
    os.link(source, destination, follow_symlinks=False)
    regular(destination)
    stable = lambda value: (value.st_dev, value.st_ino, value.st_mode,
                            value.st_size, value.st_mtime_ns)
    if stable(before) != stable(destination.stat()) or stable(before) != stable(source.stat()):
        raise ValueError('Extraction asset identity changed during ownership')
    return str(destination)


def probe(root, expected, output, *, dump=None, _after_verified=None):
    key = hashlib.sha256(json.dumps(expected, sort_keys=True).encode()).hexdigest()
    source = cache_path(root, key)
    validated_identity = expected
    if not os.path.lexists(source):
        # Only a missing current key may use the exact historical identity. The
        # new probe owns those inodes; it never upgrades legacy retirement proof.
        if expected.get("version") != EXTRACTION_IDENTITY_VERSION:
            return MISS
        validated_identity = dict(expected, version=3)
        legacy_key = hashlib.sha256(json.dumps(validated_identity, sort_keys=True).encode()).hexdigest()
        source = cache_path(root, legacy_key)
        if not os.path.lexists(source):
            return MISS
    verified_marker = source / '.complete.json'
    if _after_verified is not None:
        if source.is_symlink():
            return MISS
        regular(verified_marker)
        marker_stamp = _full_stamp(verified_marker.stat())
        marker_bytes = verified_marker.read_bytes()
        verified_record = json.loads(marker_bytes)
    dump_identity = _receipt_identity(dump) if dump is not None else None
    try:
        if source.is_symlink():
            return MISS
        if dump is not None:
            # The extractor binds offsets to the original dump and index inodes.
            # An identical restaged dump needs fresh indexes, even on a content-key hit.
            _, receipt = _read_source_receipt(source)
            if (not isinstance(receipt, dict) or receipt.get('version') != 2 or
                    receipt.get('source') != dump_identity or
                    receipt.get('indexes') != _receipt_indexes(source)):
                print('Extraction cache miss: receipt does not bind the current dump and indexes.', file=sys.stderr)
                return MISS
        asset_names = []
        if not validate(source, validated_identity, validated_names=asset_names):
            return MISS
    except (OSError, ValueError, json.JSONDecodeError, TypeError):
        return MISS
    # The normal corpus lock excludes concurrent source/output replacement.
    # Stage every owned inode before exposing any result. Cache-name pruning
    # must not invalidate metadata or module bytes held by a retained output.
    if output.is_symlink() or not output.is_dir():
        raise ValueError('Expected regular extraction output directory')
    names = (TREE, *extraction_files(source))
    if any(os.path.lexists(output / name) for name in names):
        raise ValueError('Refusing to replace existing extraction output')
    temporary = Path(tempfile.mkdtemp(prefix='.extraction-probe-', dir=output))
    installed = []
    try:
        try:
            (temporary / TREE).mkdir()
            # Link validated asset paths directly. copytree aggregates OSError
            # into shutil.Error and would hide module-stage EXDEV classification.
            for name in asset_names:
                destination = temporary / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                _owned_extraction_link(source / name, destination)
        except OSError as exc:
            if exc.errno == errno.EXDEV:
                # Copying would change the physical indexes in SourceReceipt.
                # No hit is exposed; the ordinary extraction miss path remains.
                return MISS
            raise
        for name in names:
            destination = output / name
            if os.path.lexists(destination):
                raise ValueError('Extraction output appeared during ownership')
            (temporary / name).rename(destination)
            installed.append(destination)
    except BaseException:
        for path in reversed(installed):
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
            else:
                path.unlink()
        raise
    finally:
        shutil.rmtree(temporary)
    if _after_verified is not None:
        if (_full_stamp(verified_marker.stat()) != marker_stamp or verified_marker.read_bytes() != marker_bytes):
            raise ValueError('Verified extraction marker changed before frontend restoration')
        _after_verified(source, verified_record)
    print(f"Reusing verified extraction assets: {source}", flush=True)
    return 0


def publish(root, expected, source):
    timing = optional_phase_timing(_cache_phase_event)
    completed = False
    try:
        if timing is not None: timing.switch("setup")
        key = hashlib.sha256(json.dumps(expected, sort_keys=True).encode()).hexdigest()
        destination = cache_path(root, key)
        root.mkdir(parents=True, exist_ok=True)
        prune_extraction_partials(root)
        # Refuse symlinks in the producer tree before copytree can follow one.
        if timing is None:
            walk_assets(source)
        else:
            timing.switch("preflight")
            timing.count(files=len(walk_assets(source)))
        if timing is not None: timing.switch("completion")
        validate_extraction_completion(source)
        if timing is not None: timing.switch("destination_selection")
        if destination.exists() or destination.is_symlink():
            try:
                if not destination.is_symlink() and validate(destination, expected):
                    if timing is not None: timing.switch("prune")
                    prune_extraction_generations(root, destination)
                    completed = True
                    return 0
            except (OSError, ValueError, json.JSONDecodeError, TypeError):
                pass
            if not extraction_ownership_proven(destination):
                raise ValueError("Refusing to replace unproven legacy extraction generation")
            # A corrupt owned directory remains unavailable until the new one is ready.
            stale = root / (".stale-" + key)
            if stale.exists() or stale.is_symlink():
                if not extraction_ownership_proven(stale):
                    raise ValueError("Refusing to replace unproven stale extraction backing")
                if stale.is_dir() and not stale.is_symlink():
                    shutil.rmtree(stale)
                else:
                    stale.unlink()
            destination.rename(stale)
        else:
            stale = None
        if timing is not None: timing.switch("link_copy")
        temporary = Path(tempfile.mkdtemp(prefix=".part-", dir=root))
        try:
            for name in extraction_files(source):
                original = source / name
                regular(original)
                link_or_copy(original, temporary / name)
            module_source = source / TREE
            if module_source.is_symlink() or not module_source.is_dir():
                raise ValueError("Missing regular modules directory")
            shutil.copytree(module_source, temporary / TREE, symlinks=False,
                            copy_function=link_or_copy)
            if timing is not None: timing.switch("record_assets_hash")
            assets = record_assets(temporary)
            if timing is not None:
                timing.count(files=len(assets), bytes=sum(row[1] for row in assets))
                timing.switch("seal_cleanup")
            marker = {"identity": expected, "assets": assets}
            if expected.get("version") == EXTRACTION_IDENTITY_VERSION:
                marker["asset_ownership"] = EXTRACTION_OWNERSHIP
            (temporary / ".complete.json").write_text(
                json.dumps(marker, sort_keys=True, separators=(",", ":")) + "\n")
            temporary.rename(destination)
        finally:
            if temporary.exists():
                shutil.rmtree(temporary)
        if timing is not None: timing.switch("prune")
        if stale is not None:
            if stale.is_dir() and not stale.is_symlink():
                shutil.rmtree(stale)
            else:
                stale.unlink()
        # The corpus resource lock admits one build at a time.
        prune_extraction_generations(root, destination)
        print(f"Published verified extraction assets: {destination}", flush=True)
        completed = True
        return 0
    finally:
        if timing is not None: timing.finish("success" if completed else "failure")


def clang_identity(command, flags=(), *, _digest_memo=None):
    resolved = shutil.which(command)
    if resolved is None:
        raise ValueError(f"Clang executable unavailable: {command}")
    executable = Path(resolved).resolve(strict=True)
    target = subprocess.run([str(executable), "-dumpmachine"], capture_output=True,
                            text=True, check=True, timeout=identity_probe_timeout(15)).stdout.strip()
    version = subprocess.run([str(executable), "--version"], capture_output=True,
                             text=True, check=True, timeout=identity_probe_timeout(15)).stdout.splitlines()[0]
    if not target or not version:
        raise ValueError("Clang target/version unavailable")
    observed_tool = (tool_identity(executable) if _digest_memo is None else
                     tool_identity(executable, _digest_memo=_digest_memo))
    result = {"tool": observed_tool, "target": target, "version": version}
    if "-march=native" in flags:
        # -### resolves native CPUID without compiling a source file. A literal
        # '-march=native' cache key is unsafe when the cache moves hosts.
        command_line = [str(executable), "-###", "-march=native", "-x", "c",
                        "-c", "/dev/null", "-o", "/dev/null"]
        driver = subprocess.run(command_line, capture_output=True, text=True,
                                check=True, timeout=identity_probe_timeout(15)).stderr
        cpus = re.findall(r'"-target-cpu" "([^"]+)"', driver)
        features = re.findall(r'"-target-feature" "([+-][A-Za-z0-9_.-]+)"', driver)
        if len(cpus) != 1 or not re.fullmatch(r"[A-Za-z0-9_.-]+", cpus[0]) or not features:
            raise ValueError("Clang native CPU/features unavailable")
        result["resolved_native"] = {"cpu": cpus[0], "features": features}
    return result


def live_zig_observation(command):
    """Observe the currently selected tool; do not identify a cached BC producer."""
    resolved = shutil.which(command)
    if resolved is None:
        raise ValueError(f"Zig executable unavailable: {command}")
    executable = Path(resolved).resolve(strict=True)
    regular(executable)
    version = subprocess.run([str(executable), "version"], capture_output=True,
                             text=True, check=True, timeout=identity_probe_timeout(15)).stdout.strip()
    environment = subprocess.run([str(executable), "env"], capture_output=True,
                                 text=True, check=True, timeout=identity_probe_timeout(15)).stdout
    target = re.search(r'\.target = "([^"]+)"', environment)
    if not version or target is None:
        raise ValueError("Zig version/target unavailable")
    return {"tool_sha256": sha256(executable), "version": version,
            "target": target.group(1), "flags": list(LEAF_CONTRACT_FLAGS)}


def value_leaf_identity(llvm_dir, project_root, zig, *, observe_zig=True):
    """Bind exact consumed BC bytes plus conservative live source/tool observations.

    The pipeline may be an older cached binary with paired worker/leaf artifacts.
    Live repository files and the current Zig path need not have produced that
    leaf. Zig's build graph binds the actual source closure; these observations
    only cause additional cache misses and must not be reported as provenance.
    """
    bitcode = llvm_dir / "value_leaf.bc"
    regular(bitcode)
    sources = []
    for name in LIVE_LEAF_SOURCE_PATHS:
        path = project_root / name
        regular(path)
        sources.append([name, sha256(path)])
    identity = {"bitcode": [bitcode.stat().st_size, sha256(bitcode)],
                "live_source_observations": sources}
    if observe_zig:
        identity["live_zig_observation"] = live_zig_observation(zig)
    return identity


def read_object_plan(llvm_dir):
    plan_path = llvm_dir / "batch-plan.tsv"
    regular(plan_path)
    if plan_path.stat().st_size > 64 * 1024 * 1024:
        raise ValueError("Oversized LLVM batch plan")
    plans = []
    seen = set()
    lines = plan_path.read_text().splitlines()
    for line in lines:
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
    if not plans and lines != ["# dict-llvm-batch-plan-v1",
                              "# opt\tfile\tcount\tfirst\tlast\tsource_bytes"]:
        raise ValueError("Empty LLVM batch plan lacks producer framing")
    return plans


def object_identity(llvm_dir, clang, project_root, flags, zig="zig", *, _digest_memo=None):
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
        "clang": (clang_identity(clang, flags) if _digest_memo is None else
                  clang_identity(clang, flags, _digest_memo=_digest_memo)),
        "flags": flags,
        # Only optimized Lua batches record the live Zig tool observation.
        # It is provenance, not an input to Clang's emitted-bitcode compilation.
        # Exact leaf bytes remain bound and rechecked at publication for every plan.
        "value_leaf": value_leaf_identity(llvm_dir, project_root, zig,
            observe_zig=any(mode in ("-O1", "-O2") for mode, *_ in plans)),
    }


def abi_provenance(project_root):
    """Observe current ABI source versions without claiming object-producer provenance.

    Clang consumes emitted bitcode, not live Zig runtime source. The paired
    build-graph worker/leaf and frontend artifacts establish compatibility.
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
    if not isinstance(bitcode, list) or len(bitcode) > MAX_BATCHES:
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
            # Clang consumes the emitted BC, not the currently selected Zig.
            # Keep the full observation in the snapshot, outside the object key.
            identity["value_leaf"] = {key: value for key, value in expected["value_leaf"].items()
                                      if key != "live_zig_observation"}
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


def probe_objects(root, clang, project_root, llvm_dir, flags, zig="zig", *, _digest_memo=None):
    expected = (object_identity(llvm_dir, clang, project_root, flags, zig)
                if _digest_memo is None else object_identity(
                    llvm_dir, clang, project_root, flags, zig, _digest_memo=_digest_memo))
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
        "identity": expected,
        "provenance": {"abi": abi_provenance(project_root),
                       "abi_scope": "live-source-observation"},
        "restored": restored,
    })
    for source, destination in sources:
        link_or_copy(source, destination)
    # This bounded bitmap is the sole authority for the build driver's skips.
    # The final bit belongs to program.o; preceding bits follow the fresh plan.
    (llvm_dir / ".object-hits").write_text("".join(hits) + "\n")
    print(f"Reusing verified native Lua objects: {len(restored)}/{len(entries)}", flush=True)
    return 0 if len(restored) == len(entries) else MISS


def _object_session_phase(action, operation):
    started = time.monotonic()
    code, status = 1, "failed"
    try:
        code = operation()
        status = "returned"
        return code
    finally:
        try:
            print("EXTRACTION_CACHE_PHASE " + json.dumps(dict(
                action=action, status=status, exit_code=code,
                seconds=round(time.monotonic() - started, 3),
                scope="live-helper-operation-wall"), sort_keys=True),
                file=sys.stderr, flush=True)
        except Exception:
            pass


def object_cache_session(root, clang, project_root, llvm_dir, flags, zig="zig", *, request=None, response=None):
    """One probe/compile/publish transaction; no digest authority leaves memory.

    The driver owns this child and closes its input after the single publication
    request. EOF, extra input or a failed compiler never authorizes publication.
    Legacy one-shot commands still perform independent complete observations.
    """
    import contextlib
    request = sys.stdin.buffer if request is None else request
    response = sys.stdout.buffer if response is None else response
    digest_memo = {}
    # Session stdout is only the bounded readiness response. Diagnostics retain
    # their text on stderr; the old standalone CLI's streams are unchanged.
    with contextlib.redirect_stdout(sys.stderr):
        code = _object_session_phase("probe-objects", lambda: probe_objects(
            root, clang, project_root, llvm_dir, flags, zig, _digest_memo=digest_memo))
    if code not in (0, MISS):
        raise ValueError("Invalid object-cache probe result")
    response.write(b"O0\n" if code == 0 else b"O3\n")
    response.flush()
    if request.read(2) != b"P":
        raise ValueError("Object-cache publication was not requested exactly once")
    with contextlib.redirect_stdout(sys.stderr):
        return _object_session_phase("publish-objects", lambda: publish_objects(
            root, llvm_dir, clang, flags, _digest_memo=digest_memo))


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


def publish_objects(root, llvm_dir, clang, flags, *, _digest_memo=None):
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
    # Older private snapshots also observed live ABI files. Keep accepting
    # their list shape while making that scope explicit on new publications.
    provenance = dict(provenance, abi_scope="live-source-observation")
    observed_clang = (clang_identity(clang, flags) if _digest_memo is None else
                      clang_identity(clang, flags, _digest_memo=_digest_memo))
    if expected.get("clang") != observed_clang or expected.get("flags") != flags:
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



def _frontend_reference(reference):
    if (not isinstance(reference, dict) or set(reference) != {'path', 'bytes', 'sha256'} or
            type(reference['bytes']) is not int or not 0 <= reference['bytes'] <= MAX_MARKER_BYTES or
            not isinstance(reference['path'], str) or not reference['path'] or
            not isinstance(reference['sha256'], str) or not re.fullmatch('[0-9a-f]{64}', reference['sha256'])):
        raise ValueError('Invalid sealed frontend reference')
    path = Path(reference['path'])
    if not path.is_absolute() or '..' in path.parts or any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError('Unsafe sealed frontend reference')
    regular(path)
    before = _full_stamp(path.stat())
    raw = path.read_bytes()
    if (len(raw) != reference['bytes'] or hashlib.sha256(raw).hexdigest() != reference['sha256'] or
            _full_stamp(path.stat()) != before):
        raise ValueError('Sealed frontend reference changed')
    return json.loads(raw)


def _frontend_sources(record):
    values = []
    for value in record.values():
        if isinstance(value, dict) and 'layout_source_correspondence' in value:
            reference = value['layout_source_correspondence']
            if reference not in values:
                values.append(reference)
    return sorted(values, key=lambda value: (value['path'], value['sha256']))



# A source contract for the existing qualification scheduler, not a build-file
# exemption. Every other token, including producer flags and graph edges, stays.
_SCHEDULER_HELPERS = {'validateQualificationStepMemory': '2bcf6f1b8bf0a79e36d7ee3801553ced2529b4723de42fe877faa2e872ad185f', 'claimQualificationMemory': '90a3e02663dd3ed87aa78a18369ebbdb3a266b45ea90136fc26394a15f14eca4', 'claimQualificationStep': '791b64c71b4294f26290dd225bd3373960a276c5aa54e2dd61aa8ec9b9de58af', 'addTestOrder': '6d6d7d9e79a49c77c8ab2b063618dfe242d72b9e8bd2f7f47d8ded90827c606d'}
_QUALIFICATION_EDGES = (('test_step', '&encoder_tests[i].step', '&run_encoder_tests[i - 1].step', 'test_step_memory != 0'), ('test_step', '&blob_encoder_tests.step', '&run_encoder_tests[encoder_partitions.len - 1].step', 'test_step_memory != 0'), ('test_step', '&blob_decoder_tests.step', '&run_blob_encoder_tests.step', 'test_step_memory != 0'), ('test_step', '&blob_query_tests.step', '&run_blob_decoder_tests.step', 'test_step_memory != 0'), ('test_step', '&wikimedia_dump_tests.step', '&run_blob_query_tests.step', 'test_step_memory != 0'), ('test_step', '&lua_tests.step', '&run_wikimedia_dump_tests.step', 'test_step_memory != 0'), ('test_step', '&lua_core_tests.step', '&run_lua_tests.step', 'test_step_memory != 0'), ('test_step', '&global_index_tests.step', '&run_lua_core_tests.step', 'test_step_memory != 0'), ('test_step', '&program_shapes_tests.step', '&run_global_index_tests.step', 'test_step_memory != 0'), ('test_step', '&lua_abi_tests.step', '&run_program_shapes_tests.step', 'test_step_memory != 0'), ('test_step', '&lua_stdlib_tests.step', '&run_lua_abi_tests.step', 'test_step_memory != 0'), ('test_step', '&lua_ustring_tests.step', '&run_lua_stdlib_tests.step', 'test_step_memory != 0'), ('test_step', '&lua_scribunto_tests.step', '&run_lua_ustring_tests.step', 'test_step_memory != 0'), ('test_step', '&lua_wikitext_tests.step', '&run_lua_scribunto_tests.step', 'test_step_memory != 0'), ('test_step', '&run_bundle_protocol_tests.step', '&run_lua_wikitext_tests.step', 'test_step_memory != 0'), ('test_step', '&lua_tests.step', '&run_namespace_registry_tests.step', 'test_step_memory != 0'), ('test_step', '&blob_wasm_smoke.step', '&run_bundle_protocol_tests.step', 'test_step_memory != 0'), ('test_step', '&run_bundle_pipeline_tests.step', '&blob_wasm_smoke.step', 'test_step_memory != 0'), ('test_step', '&run_blob_build_tests.step', '&run_bundle_pipeline_tests.step', 'test_step_memory != 0'), ('test_step', '&run_blob_file_tools_tests.step', '&run_blob_build_tests.step', 'test_step_memory != 0'), ('storage_test_step', '&storage_unit_run.step', '&reader_test_run.step', 'test_step_memory != 0'), ('storage_test_step', '&storage_run.step', '&storage_unit_run.step', 'test_step_memory != 0'))
_SCHEDULER_PREAMBLE = '269b22ae7292d74cb64d94bab5b9ccd168a64a3291bb962027952190f70f2a39'
_INSTALL_ONLY_SOURCE = '''    const prepare_expander_tools = b.step("prepare-expander-tools", "Install the module extractor, LLVM compiler and shared expansion runtime");
    for ([_]*std.Build.Step.Compile{ module_extract_exe, llvm_exe }) |artifact| {
        const install = b.addInstallArtifact(artifact, .{});
        prepare_expander_tools.dependOn(&install.step);
    }
    const install_worker_object = b.addInstallFileWithDir(worker_object.getEmittedBin(), .lib, worker_object.out_filename);
    prepare_expander_tools.dependOn(&install_worker_object.step);
'''

_RUNTIME_ONLY_SOURCE = '    b.step("prepare-expander-runtime", "Install only the shared expansion runtime").dependOn(&install_worker_object.step);\n'

def _build_policy_tokens(source):
    if not isinstance(source, str) or len(source.encode()) > 512 * 1024 or '\0' in source:
        raise ValueError('Invalid native build policy source')
    pattern = r'//[^\n]*|\s+|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|\\\\[^\n]*|[A-Za-z_][A-Za-z_0-9]*|[0-9][A-Za-z_0-9.]*|\.\.\.|<<\||<<|>>|==|!=|<=|>=|\+\+|\+%|-\%|\*%|\+\||-\||\*\||\.\.|[^\s]'
    return [token for token in re.findall(pattern, source) if not token.isspace() and not token.startswith('//')]

def _policy_token_hash(tokens):
    return hashlib.sha256(json.dumps(tokens, separators=(',', ':')).encode()).hexdigest()

def _policy_close(tokens, start, left='{', right='}'):
    depth = 0
    for i in range(start, len(tokens)):
        if tokens[i] == left: depth += 1
        elif tokens[i] == right:
            depth -= 1
            if depth == 0: return i + 1
    raise ValueError('Unclosed native build policy declaration')

def _policy_replace(tokens, before, after):
    out = []; count = 0; at = 0
    while at < len(tokens):
        if tokens[at:at + len(before)] == before:
            out.extend(after); at += len(before); count += 1
        else: out.append(tokens[at]); at += 1
    return out, count

def _native_build_policy_projection(source):
    tokens = _build_policy_tokens(source); out = []; at = 0; depth = 0; helpers = set()
    while at < len(tokens):
        if depth == 0 and tokens[at] == 'test':
            opening = at + 1 if tokens[at + 1] == '{' else at + 2
            if tokens[opening] != '{': raise ValueError('Invalid build policy test declaration')
            at = _policy_close(tokens, opening); continue
        if depth == 0 and tokens[at:at + 1] == ['fn'] and at + 1 < len(tokens) and tokens[at + 1] in _SCHEDULER_HELPERS:
            name = tokens[at + 1]; opening = tokens.index('{', at); end = _policy_close(tokens, opening)
            if name in helpers or _policy_token_hash(tokens[at:end]) != _SCHEDULER_HELPERS[name]:
                raise ValueError('Qualification scheduler implementation changed')
            helpers.add(name); at = end; continue
        if tokens[at] == '{': depth += 1
        elif tokens[at] == '}': depth -= 1
        if depth < 0: raise ValueError('Invalid native build policy scope')
        out.append(tokens[at]); at += 1
    if depth != 0: raise ValueError('Invalid native build policy scope')
    tokens = out
    start = _build_policy_tokens('pub fn build(b: *std.Build) void {')
    positions = [i for i in range(len(tokens)) if tokens[i:i + len(start)] == start]
    if len(positions) != 1: raise ValueError('Ambiguous native build policy entry')
    begin = positions[0] + len(start)
    target = _build_policy_tokens('const target = b.standardTargetOptions(.{});')
    end = next((i for i in range(begin, len(tokens)) if tokens[i:i + len(target)] == target), None)
    if end is None: raise ValueError('Missing native build target selection')
    preamble = tokens[begin:end]
    if preamble:
        if helpers != set(_SCHEDULER_HELPERS) or _policy_token_hash(preamble) != _SCHEDULER_PREAMBLE:
            raise ValueError('Native build policy preamble changed')
        tokens = tokens[:begin] + tokens[end:]
    elif helpers: raise ValueError('Unexpected qualification scheduler declarations')
    if _INSTALL_ONLY_SOURCE:
        prefix = _build_policy_tokens('const worker_object = bundleWorkerObject(b);')
        suffix = _build_policy_tokens('pipeline_paths.addOptionPath("worker_object", worker_object.getEmittedBin());')
        count = 0
        # Both exact public install selections share the original worker node.
        # No producer, flag, dependency or arbitrary target is projected away.
        for install in (_INSTALL_ONLY_SOURCE + _RUNTIME_ONLY_SOURCE, _INSTALL_ONLY_SOURCE):
            before = prefix + _build_policy_tokens(install) + suffix
            tokens, found = _policy_replace(tokens, before, prefix + suffix)
            count += found
        if count > 1: raise ValueError('Duplicate native install-only graph')
    # This public target installs only the existing verifier artifact. Match
    # the complete original loop so altered targets or dependency edges remain.
    verifier_before = _build_policy_tokens('    const prepare_captured_writer = b.step("prepare-captured-writer", "Prepare the existing blob tool for authenticated retained-page diagnostics");\n    const prepare_blob_tools = b.step("prepare-blob-tools", "Prepare native blob build, merge and verification tools");\n    const prepare_blob_verify = b.step("prepare-blob-verify", "Prepare only the existing native blob verification tool");\n    for ([_]*std.Build.Step.Compile{ blob_build_exe, blob_merge_exe, blob_verify_exe }) |artifact| {\n        const install = b.addInstallArtifact(artifact, .{});\n        prepare_blob_tools.dependOn(&install.step);\n        if (artifact == blob_build_exe) prepare_captured_writer.dependOn(&install.step);\n        if (artifact == blob_verify_exe) prepare_blob_verify.dependOn(&install.step);\n    }')
    verifier_after = _build_policy_tokens('    const prepare_captured_writer = b.step("prepare-captured-writer", "Prepare the existing blob tool for authenticated retained-page diagnostics");\n    const prepare_blob_tools = b.step("prepare-blob-tools", "Prepare native blob build, merge and verification tools");\n    for ([_]*std.Build.Step.Compile{ blob_build_exe, blob_merge_exe, blob_verify_exe }) |artifact| {\n        const install = b.addInstallArtifact(artifact, .{});\n        prepare_blob_tools.dependOn(&install.step);\n        if (artifact == blob_build_exe) prepare_captured_writer.dependOn(&install.step);\n    }')
    tokens, verifier_count = _policy_replace(tokens, verifier_before, verifier_after)
    if verifier_count > 1: raise ValueError('Duplicate verifier-only install graph')
    test_step = _build_policy_tokens('const test_step = b.step("test", "Run bundle encoder, data reader, Lua, and tooling tests");')
    locations = [i for i in range(len(tokens)) if tokens[i:i + len(test_step)] == test_step]
    if len(locations) != 1: raise ValueError('Ambiguous test aggregate')
    location = locations[0]
    following = tokens[location + len(test_step):]
    allowed_following = (_build_policy_tokens('var run_encoder_tests: [encoder_partitions.len]*std.Build.Step.Run = undefined;'),
                         _build_policy_tokens('const missing_dependency_tests = b.addTest('))
    if not any(following[:len(row)] == row for row in allowed_following):
        raise ValueError('Qualification aggregate moved outside its reviewed test context')
    tokens = tokens[:location] + following
    out = []; at = 0; edges = set()
    allowed_edges = {tuple(tuple(_build_policy_tokens(argument)) for argument in row) for row in _QUALIFICATION_EDGES}
    while at < len(tokens):
        if tokens[at:at + 2] != ['addTestOrder', '(']: out.append(tokens[at]); at += 1; continue
        end = _policy_close(tokens, at + 1, '(', ')'); args = []; part = []; level = 0
        for token in tokens[at + 2:end - 1]:
            if token == ',' and level == 0: args.append(part); part = []
            else:
                part.append(token)
                if token in ('(', '[', '{'): level += 1
                elif token in (')', ']', '}'): level -= 1
        args.append(part)
        if (len(args) != 4 or args[0] not in (['test_step'], ['storage_test_step']) or not args[1] or not args[2] or
                args[1][0] != '&' or args[2][0] != '&' or args[3] != ['test_step_memory', '!=', '0'] or tokens[end] != ';'):
            raise ValueError('Unsupported qualification dependency transition')
        edge = tuple(tuple(part) for part in args)
        if edge not in allowed_edges or edge in edges:
            raise ValueError('Native or duplicate edge is not a qualification transition')
        edges.add(edge)
        out.extend(args[1][1:] + ['.', 'dependOn', '('] + args[2] + [')', ';']); at = end + 1
    if preamble and edges != allowed_edges: raise ValueError('Qualification transition edge inventory changed')
    tokens = out
    storage = 'b.step("test-storage", "Exercise after-compression indexes and selective real XZ block decoding")'
    tokens, count = _policy_replace(tokens, _build_policy_tokens('const storage_test_step = ' + storage + ';'), [])
    if count > 1: raise ValueError('Duplicate storage aggregate')
    tokens, _ = _policy_replace(tokens, _build_policy_tokens('storage_test_step.dependOn(&storage_run.step);'), _build_policy_tokens(storage + '.dependOn(&storage_run.step);'))
    tokens, _ = _policy_replace(tokens, _build_policy_tokens('test_step.dependOn(if (test_step_memory != 0) storage_test_step else &storage_run.step);'), _build_policy_tokens('test_step.dependOn(&storage_run.step);'))
    return tokens


def _frontend_build_policy(selection, original, current):
    before = original['dependencies'].get('runtime_source:build.zig')
    after = current['dependencies'].get('runtime_source:build.zig')
    if before == after:
        return None
    records = []
    for descriptor in selection['layout_sources']:
        value = _frontend_reference(descriptor)
        if isinstance(value, dict) and 'build_policy_correspondence' in value:
            records.append(value['build_policy_correspondence'])
    if not records:
        return None
    if (len(records) != 1 or not isinstance(before, dict) or not isinstance(after, dict) or
            set(before) != set(after) or {k:v for k,v in before.items() if k not in ('bytes','sha256')} !=
            {k:v for k,v in after.items() if k not in ('bytes','sha256')}):
        raise ValueError('Ambiguous sealed frontend build policy source')
    proof = records[0]
    if (not isinstance(proof, dict) or set(proof) != {'version','projection','original_source','original_build','current_build'} or
            type(proof['version']) is not int or proof['version'] != 1 or
            proof['projection'] != 'qualification-scheduler-v1' or not isinstance(proof['original_source'], str) or
            proof['original_build'] != [before[k] for k in ('bytes','sha256')] or
            proof['current_build'] != [after[k] for k in ('bytes','sha256')]):
        raise ValueError('Sealed frontend build policy correspondence differs')
    if (len(proof['original_source']) > 512 * 1024 or any(type(row.get('bytes')) is not int or not 0 < row['bytes'] <= 512 * 1024 for row in (before, after))):
        raise ValueError('Oversized sealed frontend build policy source')
    old = proof['original_source'].encode()
    path = Path(after['path'])
    if path != Path(current['source_root']) / 'build.zig':
        raise ValueError('Sealed frontend build policy path differs')
    regular(path)
    stamp = _full_stamp(path.stat())
    if path.stat().st_size != after['bytes']:
        raise ValueError('Sealed frontend build policy size changed')
    new = path.read_bytes()
    if ([len(old), hashlib.sha256(old).hexdigest()] != proof['original_build'] or
            [len(new), hashlib.sha256(new).hexdigest()] != proof['current_build'] or
            _full_stamp(path.stat()) != stamp):
        raise ValueError('Sealed frontend build policy bytes changed')
    try:
        equivalent = _native_build_policy_projection(old.decode()) == _native_build_policy_projection(new.decode())
    except (UnicodeError, IndexError, ValueError) as error:
        raise ValueError('Unsupported sealed frontend build policy transition') from error
    if not equivalent:
        raise ValueError('Sealed frontend native producer graph changed')
    return dict(original=proof['original_build'], current=proof['current_build'])

def _frontend_restored_source(selection, result, plan, seal, *, previous=None):
    if 'restored_dump' not in selection:
        if previous is not None:
            raise ValueError('Unselected restored frontend source')
        return None
    chosen = selection['restored_dump']
    if (type(chosen) is not dict or set(chosen) != {'dump', 'custody'} or
            type(chosen['dump']) is not dict or
            any(chosen['dump'].get(key) != plan['dump'].get(key) for key in ('bytes', 'sha256'))):
        raise ValueError('Invalid restored frontend source selection')
    old_root = Path(result['expander'])
    binding = restored_dump_binding(old_root, chosen['dump'], result['completed_expander_seal']['sha256'], previous=previous)
    if (json.loads(binding[3]) != seal['identity']['source'] or
            json.dumps(binding[4:6], sort_keys=True, separators=(',', ':')) !=
            json.dumps(chosen['custody'], sort_keys=True, separators=(',', ':'))):
        raise ValueError('Restored frontend source identity or physical custody differs')
    return binding


def _frontend_completed_source(root, dump, binding):
    if binding is None:
        return completed_source_binding(root, dump)
    if type(binding) is not _RestoredDumpBinding or len(binding) != 7:
        raise ValueError('Invalid restored frontend source binding')
    # Reauthenticate the original root/seal independently; feeding binding[0]
    # back only to the tuple comparator would let a foreign root self-validate.
    descriptor = json.loads(binding[6])
    restored_dump_binding(Path(binding[0]), descriptor, binding[2], previous=binding)
    source = json.loads(binding[3])
    _require_restored_dump(binding, Path(binding[0]), dump, binding[2], source)
    current = _completed_source_binding(root, dump, restored_source=source)
    _require_restored_dump(binding, Path(binding[0]), dump, binding[2], source)
    restored_dump_binding(Path(binding[0]), descriptor, binding[2], previous=binding)
    if current != source:
        raise ValueError('Restored frontend extraction receipt or indexes differ')
    return current


def _frontend_selection(reference, graph, *, validate_roles, producer_observation=None, restored_dump=None):
    authority = _frontend_reference(reference)
    # Reuse the existing keyed-preparation DATA, not a new manifest layer.
    selected = authority.get('sealed_frontend') if isinstance(authority, dict) else None
    if (not isinstance(selected, dict) or set(selected) not in ({'version', 'preparation_result',
            'preparation_closure', 'original_policy_git', 'layout_sources'},
            {'version', 'preparation_result', 'preparation_closure', 'original_policy_git', 'layout_sources', 'restored_dump'}) or type(selected['version']) is not int or selected['version'] != 1 or
            not {'roles', 'inputs', 'expander_args', 'workspace', 'cache', 'dump', 'builder'} <= set(authority)):
        raise ValueError('Invalid sealed frontend selection in preparation DATA')
    selection = dict(selected, current_roles=authority['roles'], workspace=authority['workspace'], cache=authority['cache'])
    result = _frontend_reference(selection['preparation_result'])
    closed = _frontend_reference(selection['preparation_closure'])
    if (not isinstance(result, dict) or not isinstance(closed, dict) or
            not {'input_authority', 'role_map', 'worker', 'metadata', 'source_receipt', 'expander',
                 'completed_expander_seal'} <= set(result)):
        raise ValueError('Invalid sealed frontend preparation records')
    if (result.get('passed') is not True or result.get('source_after') is not True or
            result.get('inputs_after') is not True or result.get('pages_executed') != 0 or
            closed.get('outcome') != 'PASSED-PHYSICALLY-SOURCE-CLOSED' or
            any(closed.get(key) is not True for key in ('source_after', 'allocation_released')) or
            closed.get('pages_executed') != 0 or any(closed.get(key) != result.get(key)
                for key in ('worker', 'metadata', 'source_receipt'))):
        raise ValueError('Sealed frontend preparation is not independently closed')
    plan = _frontend_reference(result['input_authority'])
    if not isinstance(plan, dict) or not {'roles', 'expander_args', 'workspace', 'dump'} <= set(plan):
        raise ValueError('Invalid sealed frontend original inputs')
    if plan.get('roles') != result.get('role_map'):
        raise ValueError('Sealed frontend original role map differs')
    for name in ('inputs', 'dump', 'cache', 'registry', 'interwiki', 'page_links', 'page_redirects',
                 'staged_complete', 'original_configuration'):
        if authority.get(name) != plan.get(name):
            raise ValueError('Sealed frontend selected another ordinary input')
    expected_args = list(plan['expander_args'])
    expected_args[1] = str(Path(authority['workspace']) / 'expander')
    if authority['expander_args'] != expected_args:
        raise ValueError('Sealed frontend preparation arguments changed')
    old_workspace, workspace = Path(plan['workspace']), Path(authority['workspace'])
    if (not workspace.is_absolute() or workspace.is_relative_to(old_workspace) or
            old_workspace.is_relative_to(workspace)):
        raise ValueError('Sealed frontend requires a fresh independent workspace')
    original_roles = _frontend_reference(plan['roles'])
    current_roles = _frontend_reference(selection['current_roles'])
    original = original_roles['dict-bundle-build']
    current = current_roles['dict-bundle-build']
    # Only the frontend's inputs are projected here. Blob tools remain separately
    # authenticated by the ordinary retained-role constructor and never authorize
    # reuse of analysis. The pipeline/options artifact is authenticated there too.
    old_dependencies, dependencies = original['dependencies'], current['dependencies']
    excluded = {'blobs', 'pipeline_paths', 'worker_object', 'extraction_helper',
                'runtime_source:tools/bundle_build.zig', 'runtime_source:tools/extraction_cache.py'}
    build_policy = _frontend_build_policy(selection, original, current)
    if build_policy is not None:
        excluded.add('runtime_source:build.zig')
    if (set(old_dependencies) != set(dependencies) or
            {k:v for k,v in old_dependencies.items() if k not in excluded} !=
            {k:v for k,v in dependencies.items() if k not in excluded}):
        raise ValueError('Sealed frontend compiler or ABI dependency changed')
    root = Path(result['expander'])
    if (Path(result['metadata']['path']) != root / 'lua-program.meta' or
            Path(result['completed_expander_seal']['path']) != root / COMPLETED_EXPANDER or
            Path(result['source_receipt']['path']) != root / 'extraction-source.json' or
            os.path.lexists(root / '.incomplete') or (root.parent / '.incomplete').read_bytes() != b'expander ready'):
        raise ValueError('Sealed frontend original workspace is not ready')
    seal = _frontend_reference(result['completed_expander_seal'])
    if seal.get('provenance') != 'ordinary-linked-expander':
        raise ValueError('Sealed frontend origin is not an ordinary linked worker')
    if plan['dump']['sha256'] != seal['identity']['verified_input'][0]:
        raise ValueError('Sealed frontend original dump authority differs')
    for flag, digest in zip(('--verified-dump-sha256', '--verified-index-sha256'), seal['identity']['verified_input']):
        args = plan['expander_args']
        if args.count(flag) != 1 or args.index(flag) + 1 >= len(args) or args[args.index(flag) + 1] != digest:
            raise ValueError('Sealed frontend original verified input arguments differ')
    restored_binding = _frontend_restored_source(selection, result, plan, seal, previous=restored_dump)
    if restored_binding is not None:
        selection['_restored_dump_binding'] = restored_binding
    for name in ('lua-program.meta',):
        regular(root / name)
        if _full_stamp((root / name).stat()) != tuple(seal['runtime_stamps']['assets'][name]):
            raise ValueError('Sealed frontend original metadata physical input changed')
    for name, stamp in seal['runtime_stamps']['plans'].items():
        regular(root.parent / name)
        if _full_stamp((root.parent / name).stat()) != tuple(stamp):
            raise ValueError('Sealed frontend original plan physical input changed')
    if result['metadata']['sha256'] != seal['link']['object_inputs']['identity']['program_meta_sha256']:
        raise ValueError('Sealed frontend metadata authority differs')
    if selection['layout_sources'] != _frontend_sources(current_roles):
        raise ValueError('Sealed frontend layout source authority differs')
    for descriptor in selection['layout_sources']:
        _frontend_reference(descriptor)
    if (seal['identity']['producer']['runtime'] != [old_dependencies['worker_object'][k] for k in ('bytes', 'sha256')] or
            (old_dependencies['worker_object'] != dependencies['worker_object'] and not selection['layout_sources'])):
        raise ValueError('Sealed frontend runtime lacks its original/layout authority')
    project = Path(graph['project_root'])
    if not project.is_absolute():
        project = Path.cwd() / project
    project = project.resolve(strict=True)
    observation = dict(graph, project_root=str(project))
    for field, dependency in (('extractor', 'modules'), ('llvm', 'llvm'), ('runtime', 'worker_object'),
                               ('leaf', 'value_leaf_bc'), ('main_c', 'worker_main_c'), ('zig', 'zig')):
        path = Path(graph[field])
        if not path.is_absolute(): path = project / path
        if str(path) != dependencies[dependency]['path']:
            raise ValueError('Sealed frontend selected another live native graph')
        observation[field] = str(path)
    if Path(dependencies['extraction_helper']['path']).resolve() != Path(__file__).resolve():
        raise ValueError('Sealed frontend imported another extraction helper')
    # This is the existing constructor, not a second native-role interpretation.
    # It authenticates compilation/Git custody, actual closed emissions and all
    # live inputs. It does not install tools, compile, relink or run a worker.
    if validate_roles:
        import importlib.util
        import sys
        descriptor = authority['builder']
        builder_path = Path(descriptor['path'])
        if (builder_path != project / 'tools/build_wiktionaries.py' or
                stable_file_digest(builder_path) != [descriptor[k] for k in ('bytes', 'sha256')]):
            raise ValueError('Sealed frontend selected another build pipeline')
        # -I deliberately removes the script directory from sys.path. Resolve the
        # existing caller by its authenticated absolute path, then its own imports.
        sys.path.insert(0, str(project / 'tools'))
        spec = importlib.util.spec_from_file_location('build_wiktionaries', builder_path)
        builder = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = builder
        spec.loader.exec_module(builder)
        roles = builder.RetainedNativeToolRoles(current_roles, zig_sha256=current['zig_sha256'])
        if any(getattr(roles, name, None) is not None for name in
               ('initial_sealed_generation', 'sealed_expander_recovery', 'writer_figure_transition')):
            raise ValueError('Sealed frontend is a fresh preparation, not sealed-worker adoption')
        if getattr(builder._PREPARED_SOURCE, 'value', None) is not None:
            raise ValueError('An authorized generation cannot relink')
        original_policy_names = ('tools/bundle_build.zig', 'tools/extraction_cache.py') + (('build.zig',) if build_policy is not None else ())
        for name in original_policy_names:
            identity = roles.compilation_identity({'source_payload_git': selection['original_policy_git']}, name)
            if [identity[k] for k in ('bytes', 'sha256')] != dict(seal['identity']['producer']['policy'])[name]:
                raise ValueError('Sealed frontend original policy custody differs')
        roles.require_unchanged()
    producer, stamps = (completed_producer_identity(observation) if producer_observation is None
                        else (producer_observation, {}))
    expected_policy = dict(producer['policy'])
    for name in ('tools/bundle_build.zig', 'tools/extraction_cache.py'):
        descriptor = dependencies['runtime_source:' + name]
        if expected_policy[name] != [descriptor[k] for k in ('bytes', 'sha256')]:
            raise ValueError('Sealed frontend live policy differs from qualified roles')
    if producer['runtime'] != [dependencies['worker_object'][k] for k in ('bytes', 'sha256')]:
        raise ValueError('Sealed frontend live runtime differs from qualified roles')
    _frontend_producer_transition(seal['identity']['producer'], producer, build_policy=build_policy)
    return selection, result, plan, seal, observation, producer, stamps


def _frontend_producer_transition(original, current, *, build_policy=None):
    before, after = json.loads(json.dumps(original)), json.loads(json.dumps(current))
    if not {'runtime', 'policy'} <= set(before) or set(before) != set(after):
        raise ValueError('Sealed frontend producer contract changed')
    before.pop('runtime'); after.pop('runtime')
    old_policy, policy = dict(before.pop('policy')), dict(after.pop('policy'))
    if build_policy is not None:
        if (old_policy.get('build.zig') != build_policy['original'] or
                policy.get('build.zig') != build_policy['current']):
            raise ValueError('Sealed frontend producer build policy differs from source proof')
        del old_policy['build.zig']; del policy['build.zig']
    for name in ('tools/bundle_build.zig', 'tools/extraction_cache.py'):
        if name not in old_policy or name not in policy:
            raise ValueError('Sealed frontend lacks explicit pipeline/helper policy')
        del old_policy[name]; del policy[name]
    if before != after or old_policy != policy:
        raise ValueError('Sealed frontend LLVM, leaf, main-C, flags or ABI changed')


def _frontend_identity_matches(original, current):
    required = {'version', 'source', 'verified_input', 'providers', 'plans', 'assets', 'producer', 'runtime_libraries'}
    if not isinstance(original, dict) or not isinstance(current, dict) or set(original) != required or set(current) != required:
        raise ValueError('Invalid sealed frontend identity shape')
    for name in ('version', 'source', 'verified_input', 'providers', 'plans'):
        if original[name] != current[name]:
            raise ValueError('Sealed frontend source, provider or plan changed')
    old_assets = {name: [size, digest] for name,size,digest in original['assets']}
    assets = {name: [size, digest] for name,size,digest in current['assets']}
    if len(old_assets) != len(original['assets']) or len(assets) != len(current['assets']):
        raise ValueError('Duplicate sealed frontend assets')
    if (set(old_assets) != set(assets) or
            {k:v for k,v in old_assets.items() if k != 'dict-bundle-expander'} !=
            {k:v for k,v in assets.items() if k != 'dict-bundle-expander'}):
        raise ValueError('Sealed frontend metadata or extraction asset changed')
    old_libraries, libraries = dict(original['runtime_libraries']), dict(current['runtime_libraries'])
    if libraries.pop('extractor_sha256') != assets['dict-bundle-expander'][1]:
        raise ValueError('Sealed frontend linked runtime identity differs')
    old_libraries.pop('extractor_sha256')
    if old_libraries != libraries:
        raise ValueError('Sealed frontend linked library changed')


def _frontend_original_object_rows(cache_root, snapshot, ordered, reference):
    authority = _frontend_reference(reference)
    descriptor = authority.get('object_correspondence') if isinstance(authority, dict) else None
    if descriptor is None:
        return None
    selected = authority.get('sealed_frontend')
    if not isinstance(selected, dict) or not {'preparation_result', 'preparation_closure'} <= set(selected):
        raise ValueError('Sealed frontend original object preparation differs')
    result = _frontend_reference(selected['preparation_result'])
    record = _frontend_reference(descriptor)
    required = {'preparation_result', 'closure', 'role_map', 'input_authority', 'new_seal',
                'ordered_count', 'ordered_identity_exact', 'ordered_object_digests_exact',
                'all_marker_identities_and_abi_authenticated', 'pages_executed', 'rows'}
    if (not isinstance(record, dict) or not required <= set(record) or
            not isinstance(result, dict) or not {'role_map', 'input_authority', 'completed_expander_seal'} <= set(result) or
            record['preparation_result'] != selected['preparation_result'] or
            record['closure'] != selected['preparation_closure'] or
            record['role_map'] != result['role_map'] or record['input_authority'] != result['input_authority'] or
            record['new_seal'] != result['completed_expander_seal'] or
            any(record[key] is not True for key in ('ordered_identity_exact', 'ordered_object_digests_exact',
                                                   'all_marker_identities_and_abi_authenticated')) or
            type(record['ordered_count']) is not int or record['ordered_count'] != len(ordered) or
            type(record['pages_executed']) is not int or record['pages_executed'] != 0 or
            not isinstance(record['rows'], list) or len(record['rows']) != len(ordered)):
        raise ValueError('Sealed frontend original object correspondence differs')
    entries = list(object_entries(snapshot['identity']))
    if len(entries) != len(ordered):
        raise ValueError('Sealed frontend original object count differs')
    for index, ((name, identity), linked, row) in enumerate(zip(entries, ordered, record['rows'])):
        source = object_cache_path(cache_root, identity)
        fields = {'ordinal', 'link_name', 'cache_key', 'marker', 'object', 'object_stat', 'abi_provenance'}
        if (not isinstance(row, dict) or not fields <= set(row) or type(row['ordinal']) is not int or
                row['ordinal'] != index or row['link_name'] != name or linked[0] != name or
                row['cache_key'] != source.name or row['object'] != linked[1:] or
                not isinstance(row['marker'], dict) or row['marker'].get('path') != str(source / '.complete.json') or
                not valid_abi_provenance(row['abi_provenance'])):
            raise ValueError('Sealed frontend original object order/key differs')
        marker = _frontend_reference(row['marker'])
        if (not isinstance(marker, dict) or marker.get('identity') != identity or
                marker.get('object') != row['object'] or not isinstance(marker.get('provenance'), dict) or
                marker['provenance'].get('abi') != row['abi_provenance']):
            raise ValueError('Sealed frontend original marker provenance differs')
        regular(source / 'object.o')
        stat = (source / 'object.o').stat()
        if row['object_stat'] != dict(dev=stat.st_dev, ino=stat.st_ino,
                                     mode=oct(stat.st_mode & 0o7777), bytes=stat.st_size):
            raise ValueError('Sealed frontend original object physical input differs')
    return record['rows']


def _restore_frontend_objects(cache_root, llvm, snapshot, ordered, project, reference):
    if (not isinstance(snapshot, dict) or not isinstance(snapshot.get('identity'), dict) or
            not isinstance(snapshot.get('provenance'), dict) or not isinstance(ordered, list) or
            llvm.is_symlink() or not llvm.is_dir()):
        raise ValueError('Invalid sealed frontend object restoration')
    expected = snapshot['identity']
    entries = list(object_entries(expected))
    if (len(entries) != len(ordered) or
            snapshot['provenance']['abi'] != abi_provenance(project) or
            not valid_abi_provenance(snapshot['provenance']['abi'])):
        raise ValueError('Sealed frontend native ABI/order changed')
    original_rows = _frontend_original_object_rows(cache_root, snapshot, ordered, reference)
    sources = []
    for index, ((name, identity), row) in enumerate(zip(entries, ordered)):
        if row[0] != name or os.path.lexists(llvm / name):
            raise ValueError('Sealed frontend object order or destination changed')
        source = object_cache_path(cache_root, identity)
        value = cached_object(source, identity)
        expected_abi = (snapshot['provenance']['abi'] if original_rows is None
                        else original_rows[index]['abi_provenance'])
        if original_rows is not None:
            _frontend_reference(original_rows[index]['marker'])
        if (value != row[1:] or read_marker(source / '.complete.json')['provenance']['abi'] != expected_abi):
            raise ValueError('Sealed frontend requires every exact verified native object')
        sources.append((source / 'object.o', llvm / name))
    # Publish nothing until every original object has actually verified.
    restored = dict(snapshot, restored=ordered, provenance=dict(snapshot['provenance'], frontend_reference=reference))
    write_private_marker(llvm / '.object-identity.json', restored)
    for source, destination in sources:
        link_or_copy(source, destination)
    (llvm / '.object-hits').write_text('1' * len(entries) + '\n')
    print(f'Reusing sealed frontend verified native objects: {len(entries)}/{len(entries)}', flush=True)


def probe_sealed_frontend(cache_root, executable, dump_sha, index_sha, output, dump, graph, reference):
    selection, result, plan, seal, observation, producer, graph_stamps = _frontend_selection(reference, graph, validate_roles=True)
    selected_dump = selection.get('restored_dump', {}).get('dump', plan['dump'])
    if (str(dump) != selected_dump['path'] or seal['identity']['verified_input'] != [dump_sha, index_sha]):
        raise ValueError('Sealed frontend dump/index selection changed')
    old_root = Path(result['expander'])
    if output != Path(selection['workspace']) / 'expander' / '.bundle-expander' or cache_root != Path(selection['cache']['path']):
        raise ValueError('Sealed frontend selected another output/cache')
    info = cache_root.lstat()
    if (cache_root.is_symlink() or not cache_root.is_dir() or
            (info.st_dev, info.st_ino, info.st_mode & 0o7777, info.st_uid) !=
            tuple(selection['cache'][name] for name in ('device', 'inode', 'mode', 'uid'))):
        raise ValueError('Sealed frontend cache identity changed')
    # Providers are not extraction-cache assets. This first, deliberately narrow
    # route requires the same retained physical provider inputs; it never treats
    # a changed stamp or retargeted link as a cached digest.
    provider_stamps = {}
    for name, value in seal['identity']['providers'].items():
        path = output / name
        if value is None:
            if os.path.lexists(path): raise ValueError('Unexpected sealed frontend provider')
        else:
            if (_full_stamp(path.stat()) != tuple(seal['runtime_stamps']['assets'][name]) or
                    path.resolve(strict=True) != (old_root / name).resolve(strict=True)):
                raise ValueError('Sealed frontend provider physical input changed')
            provider_stamps[name] = (_full_stamp(path.stat()), os.readlink(path) if path.is_symlink() else None)
    expected = _frontend_extraction_identity(executable, dump_sha, index_sha, output)
    def restore(source, record):
        old_assets = {name: [size, digest] for name,size,digest in seal['identity']['assets']}
        expected_names = {name for name in old_assets if name in FILES or name == 'extraction-completion.json' or name.startswith(TREE + '/')}
        if ({name: [size, digest] for name,size,digest in record['assets']} !=
                {name: old_assets[name] for name in expected_names}):
            raise ValueError('Sealed frontend extraction bytes changed')
        if _frontend_completed_source(output, dump, selection.get('_restored_dump_binding')) != seal['identity']['source']:
            raise ValueError('Sealed frontend physical extraction receipt changed')
        source_stamps = {name: _full_stamp((output / name).stat()) for name in walk_assets(output)}
        llvm = output / 'llvm'
        for source_name, target in [('lua-program.meta', llvm / 'program.meta'),
                                    ('compile-plan.tsv', llvm / 'batch-plan.tsv'),
                                    ('module-compile-plan.tsv', llvm / 'compile-plan.tsv')]:
            src = old_root / source_name if source_name == 'lua-program.meta' else old_root.parent / source_name
            value = ([result['metadata'][k] for k in ('bytes', 'sha256')] if source_name == 'lua-program.meta' else
                     next([size,digest] for name,size,digest in seal['identity']['plans'] if name == source_name))
            if stable_file_digest(src) != value or os.path.lexists(target):
                raise ValueError('Sealed frontend metadata/plan changed or target exists')
            before = _full_stamp(src.stat()); shutil.copyfile(src, target)
            if _full_stamp(src.stat()) != before or stable_file_digest(target) != value:
                raise ValueError('Sealed frontend metadata changed during staging')
        _restore_frontend_objects(cache_root, llvm, seal['link']['object_inputs'], seal['link']['ordered_objects'], Path(observation['project_root']), reference)
        if (any(_full_stamp((output / name).stat()) != stamp for name,stamp in source_stamps.items()) or
                any((_full_stamp((output / name).stat()), os.readlink(output / name) if (output / name).is_symlink() else None) != stamp
                    for name,stamp in provider_stamps.items()) or
                any(_full_stamp(Path(observation[name]).stat()) != stamp for name,stamp in graph_stamps.items())):
            raise ValueError('Sealed frontend input changed during restoration')
        _frontend_completed_source(output, dump, selection.get('_restored_dump_binding'))
        _frontend_reference(reference)
    if probe(cache_root, expected, output, _after_verified=restore) != 0:
        raise ValueError('Explicit sealed frontend reuse requires an ordinary extraction hit')
    return 0


def _frontend_extraction_identity(executable, dump_sha, index_sha, output):
    redirects, page_redirects = output / 'transclusion-redirects.tsv', output / 'page-redirects.tsv'
    if page_redirects.exists() or page_redirects.is_symlink():
        page_redirects = page_redirects.resolve(strict=True); regular(page_redirects)
    return identity(Path(executable), dump_sha, index_sha, sha256(output / 'namespace-registry.tsv'),
                    sha256(redirects) if redirects.exists() else None,
                    sha256(page_redirects) if page_redirects.exists() else None)


def main(argv):
    if len(argv) == 10 and argv[1] == "probe-sealed-frontend":
        _, _, cache, executable, dump_sha, index_sha, root, dump, graph, reference = argv
        return probe_sealed_frontend(Path(cache), executable, dump_sha, index_sha, Path(root),
                                     Path(dump), json.loads(graph), json.loads(reference))
    if len(argv) == 9 and argv[1] == "seal-expander":
        _, _, root, dump, dump_sha, index_sha, graph, snapshots, reference = argv
        return seal_completed_expander(Path(root), Path(dump), dump_sha, index_sha,
                                       json.loads(graph), json.loads(snapshots),
                                       frontend_reference=json.loads(reference))
    if len(argv) == 8 and argv[1] == "seal-expander":
        _, action, root, dump, dump_sha, index_sha, graph, snapshots = argv
        return seal_completed_expander(Path(root), Path(dump), dump_sha, index_sha,
                                       json.loads(graph), json.loads(snapshots))
    if len(argv) == 8 and argv[1] in ("probe-objects", "publish-objects", "object-session"):
        _, action, root, clang, project_root, llvm_dir, flags_raw, zig = argv
        flags = flags_raw.split(",")
        if not flags or any(not re.fullmatch(r"-[A-Za-z0-9-]+(?:=[A-Za-z0-9_.-]+)?", flag)
                            for flag in flags):
            raise ValueError("Invalid Clang compile flags")
        if action == "object-session":
            return object_cache_session(Path(root), clang, Path(project_root),
                                        Path(llvm_dir), flags, zig)
        if action == "probe-objects":
            return probe_objects(Path(root), clang, Path(project_root),
                                 Path(llvm_dir), flags, zig)
        return publish_objects(Path(root), Path(llvm_dir), clang, flags)
    if not ((len(argv) == 7 and argv[1] in ("probe", "publish")) or
            (len(argv) == 8 and argv[1] == "probe")):
        raise SystemExit("usage: extraction_cache.py probe|publish CACHE_ROOT EXTRACTOR DUMP_SHA256 INDEX_SHA256 EXPANDER_ROOT [DUMP for probe]")
    _, action, root, executable, dump_sha256, index_sha256, output = argv[:7]
    redirects = Path(output) / "transclusion-redirects.tsv"
    page_redirects = Path(output) / "page-redirects.tsv"
    # bundle_build installs input snapshots as links; they are not cached assets.
    # Resolve only this identity input, retaining strict asset symlink rejection.
    if page_redirects.exists() or page_redirects.is_symlink():
        page_redirects = page_redirects.resolve(strict=True)
        regular(page_redirects)
    expected = identity(Path(executable), dump_sha256, index_sha256, sha256(Path(output) / "namespace-registry.tsv"), sha256(redirects) if redirects.exists() else None, sha256(page_redirects) if page_redirects.exists() else None)
    if action == "probe":
        return probe(Path(root), expected, Path(output), dump=Path(argv[7]) if len(argv) == 8 else None)
    return publish(Path(root), expected, Path(output))


if __name__ == "__main__":
    phase_started = time.monotonic()
    phase_status, phase_exit_code = "failure", None
    try:
        phase_exit_code = main(sys.argv)
        phase_status = "returned"
        sys.exit(phase_exit_code)
    except (OSError, ValueError, json.JSONDecodeError,
            subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        phase_exit_code = 1
        print(f"extraction cache: {error}", file=sys.stderr)
        sys.exit(1)
    finally:
        # CLI invocation scope includes identity/probes, validation and asset I/O;
        # child compiler work and overlapping extraction are separate intervals.
        try:
            action = sys.argv[1] if len(sys.argv) > 1 else "unknown"
            if action not in ("probe", "publish", "probe-objects", "publish-objects",
                              "object-session", "seal-expander", "probe-sealed-frontend"):
                action = "unknown"
            print("EXTRACTION_CACHE_PHASE " + json.dumps(dict(
                action=action, status=phase_status, exit_code=phase_exit_code,
                seconds=round(time.monotonic() - phase_started, 3),
                scope=("live-helper-lifetime-including-compilation" if action == "object-session"
                       else "joined-helper-invocation-wall")), sort_keys=True),
                file=sys.stderr, flush=True)
        except Exception:
            # Diagnostic output must not replace the original exit or error.
            pass
