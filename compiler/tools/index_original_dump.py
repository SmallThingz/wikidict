"""Locate and verify independently decodable blocks in original Wikimedia XML parts."""
import bz2
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from contextlib import nullcontext
import hashlib
import json
import os
import re
import tempfile
from pathlib import Path


BLOCK = 0x314159265359
END = 0x177245385090
CHUNK = 256 * 1024
MAX_PACKED_BLOCK = 4 * 1024 * 1024
MAX_RAW_BLOCK = 64 * 1024 * 1024


class AmbiguousBlockBoundary(ValueError):
    """A speculative block range needs the ordinary sequential boundary search."""


def _bits(data, start, length):
    end = start + length
    if start < 0 or length <= 0 or end > len(data) * 8:
        raise ValueError('Truncated bzip2 field')
    word = int.from_bytes(data[start // 8:(end + 7) // 8], 'big')
    return (word >> (-end % 8)) & ((1 << length) - 1)


# A non-byte-aligned marker contains five complete bytes. Native byte search
# finds those first, then the remaining eight bits distinguish actual markers.
def _needles():
    for marker in (BLOCK, END):
        yield marker, 0, marker.to_bytes(6, 'big')
        for shift in range(1, 8):
            yield marker, shift, (marker << (8 - shift)).to_bytes(7, 'big')[1:6]


NEEDLES = tuple(_needles())


def _markers(data, start):
    hits = []
    for marker, shift, needle in NEEDLES:
        at = start // 8
        while (at := data.find(needle, at)) >= 0:
            bit = (at - bool(shift)) * 8 + shift
            if bit >= start and bit + 48 <= len(data) * 8 and _bits(data, bit, 48) == marker:
                hits.append(bit)
            at += 1
    return sorted(hits)


def decode_block(packed, first_bit, length, level):
    """Rebuild only the bzip2 framing. libbz2 verifies the original block CRC."""
    if not 1 <= level <= 9 or not 80 <= length <= MAX_PACKED_BLOCK * 8 or _bits(packed, first_bit, 48) != BLOCK:
        raise ValueError('Invalid bzip2 block range')
    payload = _bits(packed, first_bit, length)
    crc = (payload >> (length - 80)) & 0xffffffff
    padding = -(length + 80) % 8
    bits = ((payload << 80) | (END << 32) | crc) << padding
    member = b'BZh' + bytes([ord('0') + level]) + bits.to_bytes((length + 80 + padding) // 8, 'big')
    decoder = bz2.BZ2Decompressor()
    raw = decoder.decompress(member, max_length=MAX_RAW_BLOCK + 1)
    if len(raw) > MAX_RAW_BLOCK or not decoder.eof or decoder.unused_data:
        raise ValueError('Invalid bzip2 block length or trailer')
    return raw


class _ArchiveWindow:
    def __init__(self, file):
        self.file = file
        self.data = bytearray()
        self.base = 0
        self.sha1 = hashlib.sha1()
        self.eof = False

    def fill(self, minimum):
        while len(self.data) < minimum and not self.eof:
            chunk = self.file.read(CHUNK)
            if not chunk:
                self.eof = True
                break
            self.sha1.update(chunk)
            self.data.extend(chunk)
        return len(self.data) >= minimum

    def consume(self, count):
        del self.data[:count]
        self.base += count

    def next_block(self, bit, level, pool):
        scan = bit + 80
        while True:
            for end in _markers(self.data, scan):
                if pool is not None:
                    packed = bytes(memoryview(self.data)[:(end + 7) // 8])
                    return end, pool.submit(decode_block, packed, bit, end - bit, level)
                try:
                    raw = decode_block(self.data, bit, end - bit, level)
                except (OSError, ValueError):
                    # A marker pattern can occur inside compressed data. Only a
                    # complete independently decoded block establishes a boundary.
                    continue
                return end, raw
            if self.eof or len(self.data) > MAX_PACKED_BLOCK + 7:
                raise ValueError('No valid end for bzip2 block')
            # Six trailing bytes can overlap the next read at any bit alignment.
            scan = max(scan, len(self.data) * 8 - 47)
            self.fill(len(self.data) + 1)


def _stamp(st):
    return (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)


def index_part(path, expected_size, expected_sha1, *, consume_xml=None):
    return _index_part(path, expected_size, expected_sha1, consume_xml, 1)


def _index_part(path, expected_size, expected_sha1, consume_xml, workers):
    blocks = []
    pending = deque()
    xml_bytes = 0

    def consume(position, length, level, raw):
        nonlocal xml_bytes
        blocks.append([position, length, len(raw), level])
        xml_bytes += len(raw)
        if consume_xml is not None:
            consume_xml(raw)

    def drain_one():
        position, length, level, future = pending.popleft()
        try:
            raw = future.result()
        except (OSError, ValueError) as exc:
            raise AmbiguousBlockBoundary('Candidate block did not decode') from exc
        consume(position, length, level, raw)

    with path.open('rb') as source, (ThreadPoolExecutor(workers) if workers > 1 else nullcontext()) as pool:
        before = os.fstat(source.fileno())
        window = _ArchiveWindow(source)
        while window.fill(1):
            if not window.fill(4) or window.data[:3] != b'BZh' or not ord('1') <= window.data[3] <= ord('9'):
                raise ValueError(f'Invalid bzip2 stream header: {path.name}')
            level = window.data[3] - ord('0')
            window.consume(4)
            bit = combined_crc = 0
            while True:
                window.fill((bit + 80 + 7) // 8)
                marker = _bits(window.data, bit, 48)
                crc = _bits(window.data, bit + 48, 32)
                if marker == END:
                    # Validate speculative boundaries before trusting a new stream.
                    while pending:
                        drain_one()
                    if crc != combined_crc:
                        raise ValueError(f'Original bzip2 stream CRC differs: {path.name}')
                    window.consume((bit + 80 + 7) // 8)
                    break
                if marker != BLOCK:
                    while pending:
                        drain_one()
                    raise ValueError(f'Expected a bzip2 block: {path.name}')
                end, result = window.next_block(bit, level, pool)
                position = window.base * 8 + bit
                if pool is None:
                    consume(position, end - bit, level, result)
                else:
                    pending.append((position, end - bit, level, result))
                    if len(pending) >= workers:
                        drain_one()
                combined_crc = (((combined_crc << 1) & 0xffffffff) | (combined_crc >> 31)) ^ crc
                window.consume(end // 8)
                bit = end % 8
        if window.base == 0 or window.base != expected_size or window.sha1.hexdigest() != expected_sha1:
            raise ValueError(f'Original dump size or SHA-1 differs: {path.name}')
        if _stamp(before) != _stamp(os.fstat(source.fileno())) or _stamp(before) != _stamp(path.stat()):
            raise ValueError(f'Original archive changed during indexing: {path.name}')
    return dict(name=path.name, size=expected_size, sha1=expected_sha1, xml_bytes=xml_bytes, blocks=blocks)


def ordered_parts(items):
    if not items:
        raise ValueError('Expected dated XML parts')
    items = sorted(items, key=lambda item: item['name'])
    if len({(item['wiki'], item['date']) for item in items}) != 1 or len({item['name'] for item in items}) != len(items):
        raise ValueError('Expected distinct parts from a single edition and date')
    for item in items:
        for key in ('wiki', 'date', 'name'):
            value = item[key]
            if not value or value in ('.', '..') or Path(value).name != value:
                raise ValueError('Expected a single path component')
    return items


def index_parts(items, downloads, workers=1, *, count_pages=False):
    """Return a sidecar only after every selected compressed input authenticates."""
    from build_wiktionaries import SplitXmlPage, STAGE_MAX_MEMBER_BYTES, STAGE_TARGET_BYTES, XmlFrames

    if type(workers) is not int or workers < 1:
        raise ValueError('Expected a positive worker count')
    items = ordered_parts(items)
    slots = min(workers, len(os.sched_getaffinity(0)), 4)

    def scan(item, block_workers, framer):
        def observe(raw):
            # Count with ordinary XML boundaries without materializing discarded batches.
            for _ in framer.feed(raw):
                pass
        path = downloads / item['wiki'] / item['date'] / item['name']
        return _index_part(path, item['size'], item['sha1'], observe if framer is not None else None, block_workers)

    def independent(item, block_workers=None):
        if block_workers is None:
            block_workers = slots if len(items) == 1 else 1
        framer = XmlFrames(STAGE_TARGET_BYTES, STAGE_MAX_MEMBER_BYTES, item['name'],
                           part_boundary=len(items) > 1, materialize=False) if count_pages else None
        try:
            part = scan(item, block_workers, framer)
        except AmbiguousBlockBoundary:
            return independent(item, 1)  # Discard any XML counted before the false boundary.
        if framer is not None:
            for _ in framer.finish():
                pass
        return part, framer.pages if framer is not None else 0

    try:
        if len(items) > 1 and slots > 1:
            with ThreadPoolExecutor(max_workers=min(slots, len(items))) as pool:
                records = list(pool.map(independent, items))
        else:
            records = list(map(independent, items))
        parts = [part for part, _ in records]
        pages = sum(count for _, count in records)
    except SplitXmlPage:
        # One XML page can span physical parts. Retain only its unfinished bytes.
        framer = XmlFrames(STAGE_TARGET_BYTES, STAGE_MAX_MEMBER_BYTES, items[0]['name'], materialize=False)
        parts = []
        for item in items:
            framer.source = item['name']
            parts.append(scan(item, 1, framer))
        for _ in framer.finish():
            pass
        pages = framer.pages
    directory = dict(format='wikidict-bzip2-blocks-v1', xml_bytes=sum(part['xml_bytes'] for part in parts), parts=parts)
    if count_pages:
        directory['source_pages'] = pages
    return directory


def verified_frame_bridge(items, downloads, stage, page_index, *, workers=1, split_parts=True):
    from build_wiktionaries import (DUMP_STAGING_VERSION, STAGE_MAX_MEMBER_BYTES, STAGE_TARGET_BYTES,
                                    XmlFrames, consume_ordered_part_frames, dump_input_fingerprint)
    from compression import zstd

    if (stage.get('version') != DUMP_STAGING_VERSION or stage.get('dump_codec') != 'zstd'
            or stage.get('dump_stream_kind') != 'multistream-zstd'):
        raise ValueError('Unsupported historical staging recipe')
    if (type(page_index.get('bytes')) is not int or page_index['bytes'] <= 0
            or not re.fullmatch('[0-9a-f]{64}', page_index.get('sha256', ''))):
        raise ValueError('Expected a bound logical page-index identity')
    items = ordered_parts(items)
    if stage.get('input_sha256') != dump_input_fingerprint(items):
        raise ValueError('Staging record belongs to a different set of original XML inputs')
    frames, parts = [], []
    xml_size = packed_size = index_size = pages = 0
    dump_hash, index_hash = hashlib.sha256(), hashlib.sha256()
    offset_encoder = bz2.BZ2Compressor(1)

    def store(frame):
        nonlocal xml_size, packed_size, index_size
        size = zstd.get_frame_info(frame).decompressed_size
        ordinal = len(frames)
        offsets = offset_encoder.compress(f'{packed_size}:{ordinal + 1}:member{ordinal}\n'.encode())
        index_hash.update(offsets)
        index_size += len(offsets)
        dump_hash.update(frame)
        packed_size += len(frame)
        frames.append([xml_size, size])
        xml_size += size

    per_part = split_parts and len(items) > 1
    framer = XmlFrames(STAGE_TARGET_BYTES, STAGE_MAX_MEMBER_BYTES, items[0]['name'], part_boundary=per_part)

    def read_part(item, state, consume):
        def observe(raw):
            for batch in state.feed(raw):
                consume(zstd.compress(batch, level=1))
        path = downloads / item['wiki'] / item['date'] / item['name']
        slots = min(workers, len(os.sched_getaffinity(0)), 4) if len(items) == 1 else 1
        return _index_part(path, item['size'], item['sha1'], observe, slots)

    def finish(state, consume):
        for batch in state.finish():
            consume(zstd.compress(batch, level=1))

    def produce(item, consume):
        state = XmlFrames(STAGE_TARGET_BYTES, STAGE_MAX_MEMBER_BYTES, item['name'], part_boundary=True)
        part = read_part(item, state, consume)
        finish(state, consume)
        return part, state.pages

    if per_part:
        # Only compressed frames cross threads. An unusually large single page
        # may occupy a queue alone, so it cannot wait forever for more space.
        slots = min(workers, len(items), len(os.sched_getaffinity(0)), 4)
        records = consume_ordered_part_frames(items, slots, produce, store, queue_bytes=8 * 1024 * 1024)
        parts = [part for part, _ in records]
        pages = sum(count for _, count in records)
    else:
        try:
            for item in items:
                framer.source = item['name']
                parts.append(read_part(item, framer, store))
        except AmbiguousBlockBoundary:
            # No bytes have been published. Recreate all frames, counters and
            # hashes so a partially consumed parallel prefix is never repeated.
            return verified_frame_bridge(items, downloads, stage, page_index, workers=1, split_parts=False)
        finish(framer, store)
        pages = framer.pages
    if not frames:
        store(zstd.compress(b'', level=1))
    offsets = offset_encoder.flush()
    index_hash.update(offsets)
    index_size += len(offsets)
    for key, actual in [('dump_size', packed_size), ('dump_sha256', dump_hash.hexdigest()),
                        ('index_size', index_size), ('index_sha256', index_hash.hexdigest()),
                        ('source_pages', pages)]:
        if stage.get(key) != actual:
            raise ValueError(f'Original input does not reproduce staged {key}')
    if sum(p['xml_bytes'] for p in parts) != xml_size:
        raise ValueError('Virtual frames do not cover the full original XML')
    bridge = dict(frames=frames, dump_bytes=packed_size, dump_sha256=dump_hash.hexdigest(),
                  offset_index_bytes=index_size, offset_index_sha256=index_hash.hexdigest(),
                  page_index_bytes=page_index['bytes'], page_index_sha256=page_index['sha256'])
    return dict(format='wikidict-bzip2-blocks-v1', xml_bytes=xml_size, parts=parts, zstd_frame_bridge=bridge)


def write_directory(items, downloads, output, workers=1, *, stage=None, page_index=None, count_pages=False):
    """Install one authenticated directory without replacing an earlier selection."""
    if os.path.lexists(output):
        raise FileExistsError(output)
    if type(workers) is not int or workers <= 0:
        raise ValueError('Expected a positive worker count')
    items = ordered_parts(items)
    paths = [downloads / item['wiki'] / item['date'] / item['name'] for item in items]
    before = [_stamp(path.stat()) for path in paths]
    if (stage is None) != (page_index is None):
        raise ValueError('The retained staging and page index identities must be provided together')
    if stage is None:
        result = index_parts(items, downloads, workers, count_pages=count_pages)
    else:
        from build_wiktionaries import SplitXmlPage
        try:
            result = verified_frame_bridge(items, downloads, stage, page_index, workers=workers)
        except SplitXmlPage:
            # Ordinary staging carries a partial page across archive parts.
            result = verified_frame_bridge(items, downloads, stage, page_index, split_parts=False)
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf8', dir=output.parent) as temporary:
        json.dump(result, temporary, separators=(',', ':'))
        temporary.write('\n')
        temporary.flush()
        os.fsync(temporary.fileno())
        if before != [_stamp(path.stat()) for path in paths]:
            raise ValueError('Original archive selection changed during indexing')
        os.link(temporary.name, output)
    return result


def read_bound_json(path, expected_sha256):
    if not isinstance(expected_sha256, str) or not re.fullmatch('[0-9a-f]{64}', expected_sha256):
        raise ValueError('Expected a SHA-256 digest')
    path = path.absolute()
    if path.resolve(strict=True) != path or not path.is_file():
        raise ValueError(f'Expected a regular input file: {path}')
    with path.open('rb') as stream:
        stamp = _stamp(os.fstat(stream.fileno()))
        if not 0 < stamp[2] <= 64 * 1024 * 1024:
            raise ValueError(f'Unexpected metadata size: {path}')
        raw = stream.read(stamp[2] + 1)
        if (_stamp(os.fstat(stream.fileno())) != stamp or _stamp(path.stat()) != stamp
                or len(raw) != stamp[2] or hashlib.sha256(raw).hexdigest() != expected_sha256):
            raise ValueError(f'Metadata identity changed: {path}')
    return json.loads(raw), stamp


def prepare_build_input(root, output, block_sha256, items, downloads, stage=None, page_index=None):
    """Select an authenticated fresh or historically bridged archive directory."""
    from build_wiktionaries import dump_input_fingerprint

    blocks, stamp = read_bound_json(output, block_sha256)
    items = ordered_parts(items)
    directory = (downloads / items[0]['wiki'] / items[0]['date']).resolve(strict=True)
    parts = [(item['name'], item['size'], item['sha1']) for item in items]
    if (blocks.get('format') != 'wikidict-bzip2-blocks-v1'
            or parts != [(p['name'], p['size'], p['sha1']) for p in blocks['parts']]
            or any(not (directory / name).is_file() or (directory / name).stat().st_size != size
                   for name, size, _ in parts)):
        raise ValueError('Block directory differs from the official archive inventory')
    if (stage is None) != (page_index is None):
        raise ValueError('Select both the retained stage and its page index, or neither')
    marker = dict(input_sha256=dump_input_fingerprint(items), source_directory=str(directory),
                  block_directory=dict(path=str(output.absolute()), bytes=stamp[2], sha256=block_sha256))
    if stage is None:
        pages = blocks.get('source_pages')
        if 'zstd_frame_bridge' in blocks or type(pages) is not int or pages < 0:
            raise ValueError('Fresh builds require a counted original XML block directory')
        marker.update(version='wikidict-original-bzip2-fresh-input-v1', source_pages=pages)
    else:
        marker = bridged_build_marker(marker, blocks.get('zstd_frame_bridge'), stage, page_index)
    root.mkdir(mode=0o700)
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf8', dir=root) as temporary:
            json.dump(marker, temporary, separators=(',', ':'))
            temporary.write('\n')
            temporary.flush()
            os.fsync(temporary.fileno())
            if _stamp(output.stat()) != stamp:
                raise ValueError('Block directory changed before selection')
            os.link(temporary.name, root / '.complete.json')
    except BaseException:
        # Never retire a file that a different writer placed in this directory.
        if not any(root.iterdir()):
            root.rmdir()
        raise
    return marker


def bridged_build_marker(base, bridge, stage, page_index):
    from build_wiktionaries import DUMP_STAGING_VERSION

    if (not isinstance(bridge, dict) or stage.get('version') != DUMP_STAGING_VERSION
            or stage.get('input_sha256') != base['input_sha256']
            or stage.get('dump_codec') != 'zstd' or stage.get('dump_stream_kind') != 'multistream-zstd'
            or type(stage.get('source_pages')) is not int or stage['source_pages'] < 0
            or type(page_index.get('bytes')) is not int or page_index['bytes'] <= 0
            or not isinstance(page_index.get('sha256'), str) or not re.fullmatch('[0-9a-f]{64}', page_index['sha256'])
            or type(bridge.get('page_index_bytes')) is not int
            or bridge.get('page_index_bytes') != page_index['bytes']
            or bridge.get('page_index_sha256') != page_index['sha256']):
        raise ValueError('Original index and retained stage select different inputs')
    marker = dict(version='wikidict-original-bzip2-input-v1', source_pages=stage['source_pages'], **base)
    for role, byte_key, hash_key in [('dump', 'dump_bytes', 'dump_sha256'), ('index', 'offset_index_bytes', 'offset_index_sha256')]:
        size, digest = bridge[byte_key], bridge[hash_key]
        if (type(size) is not int or size <= 0 or not isinstance(digest, str) or not re.fullmatch('[0-9a-f]{64}', digest)
                or (size, digest) != (stage.get(role + '_size'), stage.get(role + '_sha256'))):
            raise ValueError(f'Retained {role} differs from the authenticated frame bridge')
        marker[role + '_size'], marker[role + '_sha256'] = size, digest
    return marker


def main():
    import argparse
    from download_wiktionaries import load_input_manifest, select_manifest_files

    parser = argparse.ArgumentParser(description='Index original Wiktionary bzip2 blocks without staging a copy of the XML')
    parser.add_argument('--downloads', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--manifest-sha256', required=True)
    parser.add_argument('--edition', required=True, help='Edition name, e.g. enwiktionary')
    parser.add_argument('--output', type=Path, required=True, help='Block directory JSON file to create or select by digest')
    parser.add_argument('--workers', type=int, choices=range(1, 5), default=4,
                        help='Concurrent archive parts, or bzip2 blocks for a single part')
    parser.add_argument('--stage-receipt', type=Path, help='Reproduce a retained Zstandard stage and its stream index in memory')
    parser.add_argument('--page-index-size', type=int, help='Authenticated uncompressed size of the retained page-index.tsv')
    parser.add_argument('--page-index-sha256', help='Authenticated SHA-256 of the retained page-index.tsv')
    parser.add_argument('--build-input-root', type=Path, help='Select fresh original XML or a retained logical stage in a new build-input directory')
    parser.add_argument('--existing-blocks-sha256', help='Reuse the exact block directory at --output when preparing a build input')
    parser.add_argument('--stage-receipt-sha256', help='Authenticated stage receipt digest, required for reuse of an existing index')
    args = parser.parse_args()
    bridge = (args.stage_receipt, args.page_index_size, args.page_index_sha256)
    if any(value is not None for value in bridge) and any(value is None for value in bridge):
        parser.error('--stage-receipt, --page-index-size and --page-index-sha256 belong together')
    if args.build_input_root and os.path.lexists(args.build_input_root):
        parser.error('--build-input-root requires an unused destination')
    if args.existing_blocks_sha256 and (not args.build_input_root or (args.stage_receipt and not args.stage_receipt_sha256)):
        parser.error('Reusing a block directory requires --build-input-root and a digest for any retained stage receipt')
    if args.stage_receipt_sha256 and not args.stage_receipt:
        parser.error('--stage-receipt-sha256 requires --stage-receipt')
    downloads = args.downloads.absolute()
    manifest = load_input_manifest(args.manifest.absolute(), args.manifest_sha256, downloads)
    items = [row for row in select_manifest_files(manifest, [args.edition]) if '-pages-meta-current' in row['name']
             and re.search(r'\.xml(?:-p[0-9]+p[0-9]+)?\.bz2$', row['name'])]
    stage = (read_bound_json(args.stage_receipt, args.stage_receipt_sha256)[0] if args.stage_receipt_sha256
             else json.loads(args.stage_receipt.read_bytes()) if args.stage_receipt else None)
    page_index = dict(bytes=args.page_index_size, sha256=args.page_index_sha256) if args.stage_receipt else None
    if not args.existing_blocks_sha256:
        result = write_directory(items, downloads, args.output, args.workers, stage=stage, page_index=page_index,
                                 count_pages=args.build_input_root is not None and stage is None)
        print(f'{args.edition}: indexed {len(result["parts"])} archive parts, {result["xml_bytes"]} XML bytes; directory {args.output.stat().st_size} bytes')
    if args.build_input_root:
        digest = args.existing_blocks_sha256 or hashlib.sha256(args.output.read_bytes()).hexdigest()
        marker = prepare_build_input(args.build_input_root, args.output, digest, items, downloads, stage, page_index)
        print(f'{args.edition}: selected {marker["source_pages"]} source pages in {args.build_input_root}')


if __name__ == '__main__':
    main()
