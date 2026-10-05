"""Point-in-time admission for a verified raw-shard merge; no space is reserved."""
import hashlib
import json
import os
from pathlib import Path
import stat

BUILD_DISK_RESERVE_BYTES = 2 * 1024**3  # Policy margin, not an output-size bound.
MAX_DISK_BYTES = (1 << 63) - 1
_COUNTERS = ('input_rows', 'compile_only_rows', 'source_unavailable_rows',
             'dispatched_rows', 'expanded_pages', 'fallback_pages', 'duplicate_rows')
_FEATURES = {name + '.wikblb': kind for kind, name in enumerate(
    ('thesaurus', 'citations', 'reconstruction', 'rhymes', 'sign-gloss', 'supplemental'), 2)}
_KINDS = (None, 'language', 'thesaurus', 'citations', 'reconstruction',
          'rhymes', 'sign_gloss', 'supplemental')


def _bytes(value):
    if type(value) is not int or not 0 <= value <= MAX_DISK_BYTES:
        raise ValueError('Invalid or overflowing disk byte count')
    return value


def _add(*values):
    return _bytes(sum(_bytes(value) for value in values))


def _identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns)


def _coverage_bound(data):
    """Bound native output, including omitted native default counters.

    Count every input row, use maximum u64 counter widths, and allow six output
    bytes per UTF-8 name byte. This avoids assuming Python/Zig JSON byte parity.
    """
    report = json.loads(data)
    if not isinstance(report, dict) or type(report.get('version', 1)) is not int or report.get('version', 1) != 1:
        raise ValueError('Unsupported namespace coverage')
    rows = report.get('namespaces')
    if not isinstance(rows, list):
        raise ValueError('Invalid namespace coverage rows')
    total = len(json.dumps(dict(version=1, registry_sha256='0' * 64, namespaces=[]),
                           separators=(',', ':')))
    for row in rows:
        if not isinstance(row, dict) or type(row.get('id')) is not int or not 0 <= row['id'] < 2**32:
            raise ValueError('Invalid namespace coverage row')
        if not isinstance(row.get('name'), str) or row.get('kind') not in _KINDS:
            raise ValueError('Invalid namespace identity')
        for key in _COUNTERS:
            value = row.get(key, 0)
            if type(value) is not int or not 0 <= value < 2**64:
                raise ValueError('Invalid namespace counter')
        bounded = dict(id=2**32 - 1, name='', kind=row.get('kind'),
                       **{key: 2**64 - 1 for key in _COUNTERS})
        total = _add(total, len(json.dumps(bounded, separators=(',', ':'))),
                     6 * len(row['name'].encode('utf-8')), 1)
    return total


def require_merge_disk_space(shard_paths, destination, reserve_bytes,
                             *, metadata_paths=(), metadata_texts=()):
    """Require room for one additional raw output, sidecars, and a policy reserve.

    Call immediately before merge while owning the edition lock. Shards must
    already have passed the native verifier. Raw merge bytes are at most the
    measured raw shard sum: record bytes are preserved, repeated headers removed.
    Existing shards already consume space; do not require their bytes twice.
    The watchdog handles later capacity loss. Compressed input size is unused.
    Optional metadata paths are subsequent copies (absent paths are skipped);
    texts are the actual pending serializations. Reserve covers filesystem
    allocation/metadata and concurrent writes, not unmeasured output growth.
    """
    reserve_bytes = _bytes(reserve_bytes)
    if reserve_bytes == 0:
        raise ValueError('Disk reserve must be positive')
    destination = Path(destination)
    parent = destination.parent
    checked = {}

    def remember(path, directory=False):
        path = Path(path)
        info = path.lstat()
        if not (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)):
            raise ValueError(f'Unsupported or symlink merge artifact: {path}')
        if not directory:
            _bytes(info.st_size)
        checked[path] = _identity(info)
        return info

    def read_small(path, limit):
        before = remember(path)
        if before.st_size > limit:
            raise ValueError(f'Merge sidecar exceeds size limit: {path}')
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as source:
            if _identity(os.fstat(source.fileno())) != _identity(before):
                raise ValueError(f'Merge artifact changed: {path}')
            data = source.read(limit + 1)
        if len(data) != before.st_size:
            raise ValueError(f'Merge artifact changed: {path}')
        return data

    def raw_size(path, kind):
        info = remember(path)
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as source:
            if _identity(os.fstat(source.fileno())) != _identity(info):
                raise ValueError(f'Merge artifact changed: {path}')
            if source.read(9) != b'WIKBLB08' + bytes([kind]):
                raise ValueError(f'Expected raw WIKBLB08 shard: {path}')
        return info.st_size

    parent_info = remember(parent, directory=True)
    if os.path.lexists(destination):
        raise ValueError(f'Merge destination already exists: {destination}')
    shards = [Path(path) for path in shard_paths]
    if not shards or len(set(shards)) != len(shards):
        raise ValueError('Merge requires distinct verified shard roots')
    raw = fallback = manifests = coverage = metadata = 0
    blob_count = 0
    sidecars = {'languages.tsv', 'namespace-coverage.json', 'fallback-pages.jsonl',
                'page-coverage.json', '.verified'}
    for root in shards:
        remember(root, directory=True)
        entries = {path.name: path for path in root.iterdir()}
        if not sidecars.issubset(entries) or set(entries) - sidecars - set(_FEATURES) - {'languages'}:
            raise ValueError(f'Unsupported or incomplete raw shard layout: {root}')
        if read_small(root / '.verified', 64) != b'verified\n':
            raise ValueError(f'Unverified shard: {root}')
        remember(root / 'page-coverage.json')
        fallback = _add(fallback, remember(root / 'fallback-pages.jsonl').st_size)
        manifest = read_small(root / 'languages.tsv', 16 * 1024**2)
        lines = manifest.split(b'\n')
        if lines and lines[-1] == b'':
            lines.pop()
        if not lines or lines[0] != b'heading' or any(not line for line in lines[1:]):
            raise ValueError(f'Invalid language manifest: {root}')
        # Also covers a valid input manifest lacking its final newline.
        manifests = _add(manifests, len(manifest), 1)
        expected = {hashlib.sha256(heading).hexdigest() + '.wikblb' for heading in lines[1:]}
        language_root = root / 'languages'
        language_files = {}
        if os.path.lexists(language_root):
            remember(language_root, directory=True)
            language_files = {path.name: path for path in language_root.iterdir()}
        if set(language_files) != expected:
            raise ValueError(f'Language manifest/raw file mismatch: {root}')
        for path in language_files.values():
            raw = _add(raw, raw_size(path, 1))
            blob_count += 1
        for name, kind in _FEATURES.items():
            if name in entries:
                raw = _add(raw, raw_size(entries[name], kind))
                blob_count += 1
        coverage = _add(coverage, _coverage_bound(
            read_small(root / 'namespace-coverage.json', 8 * 1024**2)))
    for path in metadata_paths:
        path = Path(path)
        if os.path.lexists(path):
            metadata = _add(metadata, remember(path).st_size)
    for content in metadata_texts:
        if not isinstance(content, str):
            raise ValueError('Metadata must be serialized text')
        metadata = _add(metadata, len(content.encode('utf-8')))
    required = _add(raw, fallback, manifests, coverage, metadata, reserve_bytes)
    for path, expected_identity in checked.items():
        if _identity(path.lstat()) != expected_identity:
            raise ValueError(f'Merge artifact changed during admission: {path}')
    if os.path.lexists(destination):
        raise ValueError(f'Merge destination appeared during admission: {destination}')
    space = os.statvfs(parent)
    if type(space.f_frsize) is not int or space.f_frsize <= 0:
        raise ValueError('Invalid destination filesystem block size')
    available = _bytes(_bytes(space.f_bavail) * space.f_frsize)
    receipt = dict(raw_shard_bytes=raw, raw_blob_count=blob_count,
                   fallback_bytes=fallback, language_manifest_bound_bytes=manifests,
                   namespace_coverage_bound_bytes=coverage, metadata_bytes=metadata,
                   reserve_bytes=reserve_bytes, required_free_bytes=required,
                   available_bytes=available, destination_device=parent_info.st_dev)
    if available < required:
        raise ValueError('Insufficient merge disk space: ' +
                         json.dumps(receipt, sort_keys=True, separators=(',', ':')))
    return receipt
