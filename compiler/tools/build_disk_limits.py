"""Point-in-time admission for a verified shard merge; no space is reserved."""
import hashlib
import json
import lzma
import subprocess
import os
from pathlib import Path
import stat

BUILD_DISK_RESERVE_BYTES = 512 * 1024**2  # Maintained floor, separate from pending writes.
MAX_DISK_BYTES = (1 << 63) - 1
XZ_LIST_BATCH = 16
_COUNTERS = ('input_rows', 'compile_only_rows', 'source_unavailable_rows', 'site_metadata_rows',
             'dispatched_rows', 'expanded_pages', 'fallback_pages', 'duplicate_rows', 'alias_pages')
_FEATURES = {name + '.wikblb': kind for kind, name in enumerate(
    ('thesaurus', 'citations', 'reconstruction', 'rhymes', 'sign-gloss', 'supplemental', 'aliases'), 2)}
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
    if not isinstance(report, dict) or type(report.get('version', 1)) is not int or report.get('version', 1) not in (1, 2):
        raise ValueError('Unsupported namespace coverage')
    rows = report.get('namespaces')
    if not isinstance(rows, list):
        raise ValueError('Invalid namespace coverage rows')
    total = len(json.dumps(dict(version=1, registry_sha256='0' * 64, site_info_sha256='0' * 64, namespaces=[]),
                           separators=(',', ':')))
    counters = _COUNTERS
    if report.get('version') == 2:
        counters += ('reviewed_nonlexical_rows',)
        ids = report.get('reviewed_nonlexical_page_ids')
        sha = report.get('reviewed_nonlexical_sha256')
        if (not isinstance(ids, list) or any(type(page) is not int or not 0 < page < 2**64 for page in ids)
                or ids != sorted(set(ids)) or not isinstance(sha, str) or len(sha) != 64
                or any(c not in '0123456789abcdef' for c in sha)):
            raise ValueError('Invalid reviewed namespace coverage')
        total = _add(total, len(',"reviewed_nonlexical_sha256":"' + '0'*64 + '","reviewed_nonlexical_page_ids":[]'), 21 * len(ids))
    for row in rows:
        if not isinstance(row, dict) or type(row.get('id')) is not int or not 0 <= row['id'] < 2**32:
            raise ValueError('Invalid namespace coverage row')
        if not isinstance(row.get('name'), str) or row.get('kind') not in _KINDS:
            raise ValueError('Invalid namespace identity')
        for key in counters:
            value = row.get(key, 0)
            if type(value) is not int or not 0 <= value < 2**64:
                raise ValueError('Invalid namespace counter')
        bounded = dict(id=2**32 - 1, name='', kind=row.get('kind'),
                       **{key: 2**64 - 1 for key in counters})
        total = _add(total, len(json.dumps(bounded, separators=(',', ':'))),
                     6 * len(row['name'].encode('utf-8')), 1)
    return total


def _compressed_blob_header(path, kind):
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode):
        raise ValueError(f'Unsupported compressed shard: {path}')
    # Decode only the framing prefix, with a bounded decoder dictionary.
    decoder = lzma.LZMADecompressor(format=lzma.FORMAT_XZ, memlimit=128 * 1024**2)
    header = bytearray()
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as source:
        if _identity(os.fstat(source.fileno())) != _identity(before):
            raise ValueError(f'Compressed shard changed: {path}')
        while len(header) < 9:
            block = source.read(65536) if decoder.needs_input else b''
            if not block and decoder.needs_input:
                raise ValueError(f'Truncated compressed shard: {path}')
            header.extend(decoder.decompress(block, max_length=9-len(header)))
            if decoder.eof and len(header) < 9:
                raise ValueError(f'Truncated compressed shard: {path}')
    if header != b'WIKBLB08' + bytes([kind]):
        raise ValueError(f'Expected compressed WIKBLB08 shard: {path}')
    return before


def compressed_blob_sizes(members):
    """Measure a bounded group in argv order. Native verification checks the contents."""
    if not 1 <= len(members) <= XZ_LIST_BATCH:
        raise ValueError('Invalid XZ listing batch size')
    paths = [Path(path) for path, kind in members]
    identities = [_compressed_blob_header(path, kind) for path, (_, kind) in zip(paths, members)]
    result = subprocess.run(['xz', '--robot', '--list', '--', *map(str, paths)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            check=True, timeout=60 * len(paths))
    if len(result.stdout) > 65536 * len(paths):
        raise ValueError('XZ listing exceeds metadata bound')
    rows = [row.split(b'\t') for row in result.stdout.splitlines() if row.startswith(b'file\t')]
    if len(rows) != len(paths):
        raise ValueError('Invalid XZ logical size listing')
    sizes = []
    for path, before, row in zip(paths, identities, rows):
        if len(row) < 5 or not row[3].isdigit() or not row[4].isdigit():
            raise ValueError('Invalid XZ logical size listing')
        logical = _bytes(int(row[4]))
        if logical < 9 or int(row[3]) != before.st_size or _identity(path.lstat()) != _identity(before):
            raise ValueError(f'Compressed shard changed: {path}')
        sizes.append(logical)
    return sizes


def compressed_blob_size(path, kind):
    return compressed_blob_sizes([(path, kind)])[0]


def require_merge_disk_space(shard_paths, destination, reserve_bytes,
                             *, metadata_paths=(), metadata_texts=(), allow_compressed=False, compressed_output=False,
                             reviewed_manifest_path=None):
    """Require pending output headroom plus sidecars, metadata and a maintained floor.

    Call immediately before merge while owning the edition lock. Shards must
    already have passed the native verifier. Raw merge bytes are at most the
    measured logical shard sum: record bytes are preserved, repeated headers removed.
    Optional compressed shards contribute their XZ logical size, never compressed
    transport size, to the merged-output reservation. Stored transport bytes are
    reported separately and already consume space. XZ listing/header checks do
    not replace the ordinary native verifier.
    With compressed_output, use the stored shard transport bytes as an output
    estimate. Recompression can change that size: it is not an XZ fit bound.
    The watchdog maintains the separate reserve if actual growth exceeds the
    estimate or concurrent writers consume space.
    Existing shards already consume space; do not require their bytes twice.
    The watchdog handles later capacity loss.
    Optional metadata paths are subsequent copies (absent paths are skipped);
    texts are the actual pending serializations. Reserve covers filesystem
    allocation/metadata and concurrent writes, not unmeasured output growth.
    """
    if type(allow_compressed) is not bool: raise ValueError('Invalid compressed shard mode')
    if type(compressed_output) is not bool: raise ValueError('Invalid compressed merge output mode')
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
                raise ValueError(f'Merge artifact changed during admission: {path}')
            data = source.read(limit + 1)
        if len(data) != before.st_size:
            raise ValueError(f'Merge artifact changed during admission: {path}')
        return data

    def raw_size(path, kind):
        info = remember(path)
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as source:
            if _identity(os.fstat(source.fileno())) != _identity(info):
                raise ValueError(f'Merge artifact changed during admission: {path}')
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
    stored = compressed = 0
    pending_xz = []
    blob_count = 0
    sidecars = {'languages.tsv', 'namespace-coverage.json', 'fallback-pages.jsonl',
                'page-coverage.json', '.verified'}
    for root in shards:
        remember(root, directory=True)
        entries = {path.name: path for path in root.iterdir()}
        if not sidecars.issubset(entries) or set(entries) - sidecars - set(_FEATURES) - ({name+'.xz' for name in _FEATURES} if allow_compressed else set()) - {'languages'}:
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
        logical_names = {name[:-3] if allow_compressed and name.endswith('.xz') else name for name in language_files}
        if logical_names != expected or len(language_files) != len(logical_names):
            raise ValueError(f'Language manifest/raw file mismatch: {root}')
        blobs = [(path, 1) for path in language_files.values()]
        for name, kind in _FEATURES.items():
            present = [entries[key] for key in (name, name+'.xz') if key in entries]
            if len(present) > 1: raise ValueError(f'Duplicate raw/XZ shard: {root/name}')
            if present: blobs.append((present[0], kind))
        for path, kind in blobs:
            info = remember(path)
            if allow_compressed and path.name.endswith('.xz'):
                pending_xz.append((path, kind))
                if len(pending_xz) == XZ_LIST_BATCH:
                    raw = _add(raw, *compressed_blob_sizes(pending_xz))
                    pending_xz.clear()
                compressed = _add(compressed, info.st_size)
            else:
                raw = _add(raw, raw_size(path, kind))
            stored = _add(stored, info.st_size)
            blob_count += 1
        coverage = _add(coverage, _coverage_bound(
            read_small(root / 'namespace-coverage.json', 8 * 1024**2)))
    if pending_xz:
        raw = _add(raw, *compressed_blob_sizes(pending_xz))
    if reviewed_manifest_path is not None:
        metadata = _add(metadata, remember(Path(reviewed_manifest_path)).st_size)
    for path in metadata_paths:
        path = Path(path)
        if os.path.lexists(path):
            metadata = _add(metadata, remember(path).st_size)
    for content in metadata_texts:
        if not isinstance(content, str):
            raise ValueError('Metadata must be serialized text')
        metadata = _add(metadata, len(content.encode('utf-8')))
    # Streaming XZ never allocates a full raw merged copy. Use the measured
    # transports for planning, while retaining a separate runtime floor.
    output_bound = 0 if compressed_output else raw
    compressed_estimate = stored if compressed_output else 0
    remaining_writes = _add(output_bound, compressed_estimate, fallback, manifests, coverage, metadata)
    required = _add(remaining_writes, reserve_bytes)
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
                   compressed_output=compressed_output, logical_shard_bytes=raw,
                   raw_output_reservation_bytes=output_bound,
                   streaming_output_headroom_bytes=_add(compressed_estimate, reserve_bytes) if compressed_output else 0,
                   compressed_output_size_bound_bytes=None if compressed_output else raw,
                   compressed_output_estimate_bytes=compressed_estimate if compressed_output else None,
                   remaining_write_headroom_bytes=remaining_writes,
                   stored_shard_blob_bytes=stored, compressed_shard_blob_bytes=compressed,
                   fallback_bytes=fallback, language_manifest_bound_bytes=manifests,
                   namespace_coverage_bound_bytes=coverage, metadata_bytes=metadata,
                   reserve_bytes=reserve_bytes, required_free_bytes=required,
                   available_bytes=available, destination_device=parent_info.st_dev)
    if available < required:
        raise ValueError('Insufficient merge disk space: ' +
                         json.dumps(receipt, sort_keys=True, separators=(',', ':')))
    return receipt
