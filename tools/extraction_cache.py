#!/usr/bin/env python3
"""Verified immutable extraction and Clang-object assets for corpus builds.

The caller must supply both SHA256 values from its already verified staged
dump marker. This helper does not reread the multigigabyte dump or stream index.
"""
import hashlib
import errno
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
    "figure-sizing.site.json",
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


def stable_file_digest(path, *, snapshot=False):
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
    digest = hashlib.sha256()
    with target.open("rb") as stream:
        if _full_stamp(os.fstat(stream.fileno())) != _full_stamp(before):
            raise ValueError("Expander asset replaced before reading")
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
        if _full_stamp(os.fstat(stream.fileno())) != _full_stamp(before):
            raise ValueError("Expander asset changed during reading")
    if (_full_stamp(path.stat()) != _full_stamp(before) or
            (os.readlink(path) if path.is_symlink() else None) != link):
        raise ValueError("Expander asset path changed during reading")
    return [before.st_size, digest.hexdigest()]


def _receipt_identity(path, *, index=False):
    regular(path)
    info = path.stat()
    return dict(device_major=os.major(info.st_dev), device_minor=os.minor(info.st_dev),
                inode=info.st_ino, size=info.st_size, mtime_ns=info.st_mtime_ns,
                ctime_ns=0 if index else info.st_ctime_ns)


def completed_source_binding(root, dump):
    """Keep the existing physical SourceReceipt v2; never rewrite its origin."""
    receipt_path = root / "extraction-source.json"
    regular(receipt_path)
    with receipt_path.open("rb") as stream:
        raw = stream.read(16385)
    if len(raw) > 16384:
        raise ValueError("Oversized extraction source receipt")
    receipt = json.loads(raw)
    namespace = stable_file_digest(root / "namespace-registry.tsv", snapshot=True)[1]
    redirects_path = root / "transclusion-redirects.tsv"
    redirects = (stable_file_digest(redirects_path, snapshot=True)[1]
                 if os.path.lexists(redirects_path) else None)
    expected = dict(version=2, source=_receipt_identity(dump),
                    indexes=[_receipt_identity(root / name, index=True) for name in
                             ("page-index.tsv", "page-title-index.bin", "dump-streams.tsv")],
                    namespace_sha256=list(bytes.fromhex(namespace)),
                    redirects_sha256=list(bytes.fromhex(redirects)) if redirects else None)
    if receipt != expected:
        raise ValueError("Completed expander source receipt changed")
    return dict(path=str(dump.absolute()), receipt=expected,
                receipt_bytes=[len(raw), hashlib.sha256(raw).hexdigest()])


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


def completed_expander_identity(root, dump, dump_sha, index_sha, graph, snapshots):
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
    source = completed_source_binding(root, dump)
    validate_extraction_completion(root)
    providers = {}
    for name, selected in snapshots.items():
        installed = root / name
        if selected is None:
            if os.path.lexists(installed):
                raise ValueError("Unexpected expander snapshot")
            providers[name] = None
        else:
            value = stable_file_digest(Path(selected), snapshot=True)
            if stable_file_digest(installed, snapshot=True) != value:
                raise ValueError("Selected expander snapshot differs")
            providers[name] = value
    # Generated modules/indexes must remain regular owned assets. Snapshot links
    # are allowed only by the explicit, complete normal option inventory above.
    names = completed_asset_names(root, sealing=True)
    required = {"dict-bundle-expander", "lua-program.meta"}
    if not required <= names:
        raise ValueError("Incomplete native expander output")
    stamps = {name: _full_stamp((root / name).stat()) for name in names}
    assets = [[name, *stable_file_digest(root / name, snapshot=name in snapshots)]
              for name in sorted(names)]
    runtime_libraries = tool_identity(root / "dict-bundle-expander")
    plans = [[name, *stable_file_digest(root.parent / name)] for name in
             ("compile-plan.tsv", "module-compile-plan.tsv")]
    if (completed_asset_names(root, sealing=True) != names or
            any(_full_stamp(Path(graph[name]).stat()) != stamp for name, stamp in graph_stamps.items()) or
            any(_full_stamp((root / name).stat()) != stamp for name, stamp in stamps.items()) or
            completed_source_binding(root, dump) != source):
        raise ValueError("Expander source changed during validation")
    return dict(version=COMPLETED_EXPANDER_VERSION, source=source,
                verified_input=[dump_sha, index_sha], producer=producer,
                providers=providers, assets=assets, plans=plans, runtime_libraries=runtime_libraries)


def frozen_runtime_context(root, dump, expected_sha, *, provider_update=False):
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
    recorded = read_marker(marker)
    raw = marker.read_bytes()
    if hashlib.sha256(raw).hexdigest() != expected_sha or _full_stamp(marker.stat()) != before:
        raise ValueError('Original completed generation binding changed')
    if not isinstance(recorded, dict) or 'runtime_stamps' not in recorded:
        return None
    _provider_update_provenance(recorded)
    identity = recorded['identity']; stamps = recorded['runtime_stamps']
    if (set(stamps) != {'assets', 'plans', 'snapshot_links'} or
            type(identity.get('version')) is not int or identity.get('version') != COMPLETED_EXPANDER_VERSION):
        raise ValueError('Invalid frozen runtime stamp contract')
    regular(root.parent / '.incomplete')
    if type(provider_update) is not bool:
        raise ValueError('Invalid Provider update validation mode')
    if provider_update:
        regular(root / '.incomplete')
        if (recorded.get('provenance') != 'ordinary-wikibase-provider-update' or
                (root / '.incomplete').read_bytes() != PROVIDER_UPDATE_MARKER):
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
    if completed_source_binding(root, dump) != identity['source']:
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
    return recorded



WIKIBASE_PROVIDER_FILES = frozenset(('wikibase-entities.tsv', 'wikibase-entity-terms.tsv'))
PROVIDER_UPDATE_MARKER = b'updating Wikibase providers\n'


def _provider_update_provenance(record):
    if record.get('provenance') == 'ordinary-linked-expander':
        return
    update = record.get('provider_update')
    if (record.get('provenance') != 'ordinary-wikibase-provider-update' or
            not isinstance(update, dict) or
            set(update) != {'original_seal_sha256', 'previous_seal_sha256', 'original_providers'} or
            any(not isinstance(update.get(key), str) or not re.fullmatch('[0-9a-f]{64}', update[key])
                for key in ('original_seal_sha256', 'previous_seal_sha256')) or
            not isinstance(update.get('original_providers'), dict) or
            set(update['original_providers']) != WIKIBASE_PROVIDER_FILES or
            any(not valid_digest_record(value) for value in update['original_providers'].values())):
        raise ValueError('Unreviewed completed generation origin')


def prepare_wikibase_provider_update(root, dump, expected_sha):
    """Authenticate the old native generation before its ordinary workspace reset."""
    root, dump = Path(root), Path(dump)
    record = frozen_runtime_context(root, dump, expected_sha)
    if record is None:
        return None
    if any(not valid_digest_record(record['identity']['providers'].get(name))
           for name in WIKIBASE_PROVIDER_FILES):
        return None
    producer, _ = completed_producer_identity(record['origin_graph'])
    if (producer != record['identity']['producer'] or
            tool_identity(root / 'dict-bundle-expander') != record['identity']['runtime_libraries']):
        raise ValueError('Native producer changed before Provider update')
    # The caller owns the edition lock and invalidates every Provider-dependent
    # shard. This proof never authorizes another root or a new native producer.
    return dict(root=str(root), dump=str(dump), seal_sha256=expected_sha,
                marker_stamp=_full_stamp((root / COMPLETED_EXPANDER).stat()), record=record)


def finish_wikibase_provider_update(proof, expected_hashes):
    """Reseal only fresh Provider data; retain the actual linked native origin."""
    root, dump = Path(proof['root']), Path(proof['dump'])
    if (not root.is_absolute() or str(root) != os.path.normpath(str(root)) or
            any(path.is_symlink() for path in (root, *root.parents)) or not root.is_dir()):
        raise ValueError('Invalid Provider update root')
    if {p.name for p in root.parent.iterdir()} != {'.bundle-expander', '.incomplete', 'compile-plan.tsv', 'module-compile-plan.tsv'}:
        raise ValueError('Unexpected Provider update outputs')
    record = proof['record']
    marker = root / COMPLETED_EXPANDER
    if (set(expected_hashes) != WIKIBASE_PROVIDER_FILES or
            any(not isinstance(value, str) or not re.fullmatch('[0-9a-f]{64}', value)
                for value in expected_hashes.values()) or
            (root / '.incomplete').read_bytes() != PROVIDER_UPDATE_MARKER or
            (root.parent / '.incomplete').read_bytes() != b'expander ready'):
        raise ValueError('Invalid Provider update transaction')
    regular(marker)
    if (_full_stamp(marker.stat()) != tuple(proof['marker_stamp']) or
            sha256(marker) != proof['seal_sha256'] or read_marker(marker) != record):
        raise ValueError('Original native generation proof changed')
    _provider_update_provenance(record)
    identity = record['identity']
    names = completed_asset_names(root)
    original_names = {row[0] for row in identity['assets']}
    if names != original_names:
        raise ValueError('Provider update changed native asset membership')
    native_stamps = {name: stamp for name, stamp in record['runtime_stamps']['assets'].items()
                     if name not in EXPANDER_SNAPSHOTS}
    def unchanged_native():
        for name, stamp in native_stamps.items():
            regular(root / name)
            if _full_stamp((root / name).stat()) != tuple(stamp):
                raise ValueError('Provider update changed native asset: ' + name)
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
        if links[name] != record['runtime_stamps']['snapshot_links'][name]:
            raise ValueError('Provider update changed installed input path')
    for name in EXPANDER_SNAPSHOTS:
        old = identity['providers'][name]
        path = root / name
        if old is None:
            if os.path.lexists(path):
                raise ValueError('Provider update introduced another input')
            providers[name] = None
            continue
        value = stable_file_digest(path, snapshot=True)
        if name in WIKIBASE_PROVIDER_FILES:
            if value[1] != expected_hashes[name]:
                raise ValueError('Installed Wikibase Provider differs from selected authority')
        elif value != old:
            raise ValueError('Provider update changed a non-Wikibase input')
        providers[name] = value
    if completed_source_binding(root, dump) != identity['source']:
        raise ValueError('Provider update changed extraction source')
    producer, _ = completed_producer_identity(record['origin_graph'])
    if (producer != identity['producer'] or
            tool_identity(root / 'dict-bundle-expander') != identity['runtime_libraries']):
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
        original_providers=previous['original_providers'] if previous else
            {name: identity['providers'][name] for name in WIKIBASE_PROVIDER_FILES})
    successor['provenance'] = 'ordinary-wikibase-provider-update'
    # Ready is published by the builder only after binding this exact successor
    # in ordinary state.json. A write failure leaves the incomplete marker.
    write_private_marker(marker, successor)
    return sha256(marker)


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


def seal_completed_expander(root, dump, dump_sha, index_sha, graph, snapshots):
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
    identity = completed_expander_identity(root, dump, dump_sha, index_sha, graph, snapshots)
    link = completed_link_provenance(root, graph)
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


def tool_identity(executable):
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
    return {
        "extractor_sha256": sha256(executable),
        "libraries": [[str(path), sha256(path)] for path in sorted(libraries)],
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


def validate(root, expected):
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


def probe(root, expected, output):
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
    try:
        if source.is_symlink() or not validate(source, validated_identity):
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
            for name in walk_assets(source):
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


def clang_identity(command, flags=()):
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
    result = {"tool": tool_identity(executable), "target": target, "version": version}
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
        # Only optimized Lua batches use the live tool observation in their keys.
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
    # Older private snapshots also observed live ABI files. Keep accepting
    # their list shape while making that scope explicit on new publications.
    provenance = dict(provenance, abi_scope="live-source-observation")
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
    if len(argv) == 8 and argv[1] == "seal-expander":
        _, action, root, dump, dump_sha, index_sha, graph, snapshots = argv
        return seal_completed_expander(Path(root), Path(dump), dump_sha, index_sha,
                                       json.loads(graph), json.loads(snapshots))
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
    redirects = Path(output) / "transclusion-redirects.tsv"
    page_redirects = Path(output) / "page-redirects.tsv"
    # bundle_build installs input snapshots as links; they are not cached assets.
    # Resolve only this identity input, retaining strict asset symlink rejection.
    if page_redirects.exists() or page_redirects.is_symlink():
        page_redirects = page_redirects.resolve(strict=True)
        regular(page_redirects)
    expected = identity(Path(executable), dump_sha256, index_sha256, sha256(Path(output) / "namespace-registry.tsv"), sha256(redirects) if redirects.exists() else None, sha256(page_redirects) if page_redirects.exists() else None)
    if action == "probe":
        return probe(Path(root), expected, Path(output))
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
                              "seal-expander"):
                action = "unknown"
            print("EXTRACTION_CACHE_PHASE " + json.dumps(dict(
                action=action, status=phase_status, exit_code=phase_exit_code,
                seconds=round(time.monotonic() - phase_started, 3),
                scope="joined-helper-invocation-wall"), sort_keys=True),
                file=sys.stderr, flush=True)
        except Exception:
            # Diagnostic output must not replace the original exit or error.
            pass
