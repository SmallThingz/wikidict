"""Locate and verify independently decodable blocks in original Wikimedia XML parts."""
import bz2
from concurrent.futures import ThreadPoolExecutor
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

    def next_block(self, bit, level):
        scan = bit + 80
        while True:
            for end in _markers(self.data, scan):
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
    blocks = []
    xml_bytes = 0
    with path.open('rb') as source:
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
                    if crc != combined_crc:
                        raise ValueError(f'Original bzip2 stream CRC differs: {path.name}')
                    window.consume((bit + 80 + 7) // 8)
                    break
                if marker != BLOCK:
                    raise ValueError(f'Expected a bzip2 block: {path.name}')
                end, raw = window.next_block(bit, level)
                blocks.append([window.base * 8 + bit, end - bit, len(raw), level])
                xml_bytes += len(raw)
                if consume_xml is not None:
                    consume_xml(raw)
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


def index_parts(items, downloads, workers=1):
    """Return a sidecar only after every selected compressed input authenticates."""
    if type(workers) is not int or workers < 1:
        raise ValueError('Expected a positive worker count')
    items = ordered_parts(items)

    def index(item):
        return index_part(downloads / item['wiki'] / item['date'] / item['name'], item['size'], item['sha1'])

    if workers == 1 or len(items) == 1:
        parts = list(map(index, items))
    else:
        with ThreadPoolExecutor(max_workers=min(workers, len(items), len(os.sched_getaffinity(0)), 4)) as pool:
            parts = list(pool.map(index, items))
    return dict(format='wikidict-bzip2-blocks-v1', xml_bytes=sum(part['xml_bytes'] for part in parts), parts=parts)


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
        return index_part(path, item['size'], item['sha1'], consume_xml=observe)

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
        for item in items:
            framer.source = item['name']
            parts.append(read_part(item, framer, store))
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


def write_directory(items, downloads, output, workers=1, *, stage=None, page_index=None):
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
        result = index_parts(items, downloads, workers)
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


def main():
    import argparse
    from download_wiktionaries import load_input_manifest, select_manifest_files

    parser = argparse.ArgumentParser(description='Index original Wiktionary bzip2 blocks without staging a copy of the XML')
    parser.add_argument('--downloads', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--manifest-sha256', required=True)
    parser.add_argument('--edition', required=True, help='Edition name, e.g. enwiktionary')
    parser.add_argument('--output', type=Path, required=True, help='New block directory JSON file')
    parser.add_argument('--workers', type=int, choices=range(1, 5), default=4, help='Concurrent independent archive parts')
    parser.add_argument('--stage-receipt', type=Path, help='Reproduce a retained Zstandard stage and its stream index in memory')
    parser.add_argument('--page-index-size', type=int, help='Authenticated uncompressed size of the retained page-index.tsv')
    parser.add_argument('--page-index-sha256', help='Authenticated SHA-256 of the retained page-index.tsv')
    args = parser.parse_args()
    bridge = (args.stage_receipt, args.page_index_size, args.page_index_sha256)
    if any(value is not None for value in bridge) and any(value is None for value in bridge):
        parser.error('--stage-receipt, --page-index-size and --page-index-sha256 belong together')
    downloads = args.downloads.absolute()
    manifest = load_input_manifest(args.manifest.absolute(), args.manifest_sha256, downloads)
    items = [row for row in select_manifest_files(manifest, [args.edition]) if '-pages-meta-current' in row['name']
             and re.search(r'\.xml(?:-p[0-9]+p[0-9]+)?\.bz2$', row['name'])]
    stage = json.loads(args.stage_receipt.read_bytes()) if args.stage_receipt else None
    page_index = dict(bytes=args.page_index_size, sha256=args.page_index_sha256) if args.stage_receipt else None
    result = write_directory(items, downloads, args.output, args.workers, stage=stage, page_index=page_index)
    print(f'{args.edition}: indexed {len(result["parts"])} archive parts, {result["xml_bytes"]} XML bytes; directory {args.output.stat().st_size} bytes')


if __name__ == '__main__':
    main()
