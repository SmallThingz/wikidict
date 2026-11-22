import bz2
import hashlib
from pathlib import Path
import random
import tempfile
import unittest

from build_wiktionaries import XmlFrames
from index_original_dump import _markers, decode_block, index_part, index_parts


class CountOnlyXmlFrames(unittest.TestCase):
    @staticmethod
    def outcome(chunks, *, materialize=True, part_boundary=False, target=23):
        boundaries = []

        class Observed(XmlFrames):
            def _take(self):
                boundaries.append(self.batch_size)
                return super()._take()

        state = Observed(target, 97, 'same-original.xml.bz2',
                         materialize=materialize, part_boundary=part_boundary)
        frames = []
        error = None
        try:
            for chunk in chunks:
                frames.extend(state.feed(chunk))
            frames.extend(state.finish())
        except (ValueError, RuntimeError) as exc:
            error = (type(exc).__name__, exc.args)
        return dict(pages=state.pages, xml_bytes=state.xml_bytes, boundaries=boundaries,
                    frames=[bytes(frame) if frame is not None else None for frame in frames],
                    error=error)

    def test_count_only_preserves_materialized_bytes_and_batch_boundaries(self):
        large_page = b'<page>' + b'x' * 44 + b'</page>'
        sources = [b'', b'<mediawiki/>', b'<page>a</page>',
                   b'<mediawiki><page>a</page>' + large_page + b'</mediawiki>',
                   b'<page>one</page>\n<page>two</page>trailer',
                   large_page * 2, large_page + b'x' * 44]
        for raw in sources:
            for target in (23, 97, 200):
                for width in range(1, len(raw) + 2):
                    chunks = [raw[i:i + width] for i in range(0, len(raw), width)]
                    materialized = self.outcome(chunks, target=target)
                    counted = self.outcome(chunks, target=target, materialize=False)
                    self.assertIsNone(materialized['error'])
                    self.assertEqual(b''.join(materialized['frames']), raw)
                    self.assertEqual(materialized['pages'], raw.count(b'<page>'))
                    self.assertEqual(materialized['xml_bytes'], len(raw))
                    self.assertEqual(materialized | {'frames': [None] * len(materialized['frames'])}, counted)

    def test_count_only_preserves_errors_and_partial_part_fallback(self):
        sources = [b'</page>', b'<page>unfinished', b'<pa', b'<page>' + b'x' * 98,
                   b'<page>a</page><page>' + b'x' * 98 + b'</page>', b'header' * 20]
        for raw in sources:
            for part in (False, True):
                for width in (1, 6, 7, 13, len(raw) + 1):
                    chunks = [raw[i:i + width] for i in range(0, len(raw), width)]
                    materialized = self.outcome(chunks, part_boundary=part)
                    counted = self.outcome(chunks, materialize=False, part_boundary=part)
                    self.assertEqual(materialized | {'frames': [None] * len(materialized['frames'])}, counted)

    def test_count_only_keeps_no_materialized_batch(self):
        state = XmlFrames(20, 100, 'source', materialize=False)
        for raw in (b'<page>a</page>', b'<page>b</page>', b'tail'):
            self.assertTrue(all(frame is None for frame in state.feed(raw)))
            self.assertIsNone(state.batch)
        self.assertTrue(all(frame is None for frame in state.finish()))
        self.assertEqual((state.pages, state.xml_bytes), (2, 32))
        self.assertIsNone(state.batch)
        self.assertEqual(state.batch_size, 0)


class OriginalXmlParts(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.path = self.base / 'one.bz2'

    def index(self, packed):
        self.path.write_bytes(packed)
        return index_part(self.path, len(packed), hashlib.sha1(packed).hexdigest())

    def test_nonbyte_aligned_random_reads_and_full_logical_content(self):
        raw = random.Random(1427).randbytes(420000)
        packed = bz2.compress(raw, compresslevel=1)
        desc = self.index(packed)
        self.assertGreater(len(desc['blocks']), 3)
        self.assertTrue(any(first % 8 for first, *_ in desc['blocks']))
        self.assertEqual(desc['xml_bytes'], len(raw))
        blocks = []
        for first, length, raw_length, level in desc['blocks']:
            data = packed[first // 8:(first + length + 7) // 8]
            block = decode_block(data, first % 8, length, level)
            self.assertEqual(len(block), raw_length)
            blocks.append(block)
        self.assertEqual(b''.join(blocks), raw)

    def test_concatenated_and_empty_streams(self):
        raw = [b'first' * 1000, b'', b'second' * 800]
        packed = b''.join(bz2.compress(item, compresslevel=i + 1) for i, item in enumerate(raw))
        desc = self.index(packed)
        self.assertEqual([b[3] for b in desc['blocks']], [1, 3])
        self.assertEqual(desc['xml_bytes'], sum(map(len, raw)))
        self.assertEqual(self.index(bz2.compress(b''))['blocks'], [])

    def test_changed_input_digest_or_length(self):
        packed = bz2.compress(b'content')
        self.path.write_bytes(packed)
        for size, digest in ((len(packed)+1, hashlib.sha1(packed).hexdigest()), (len(packed), '0'*40)):
            with self.assertRaisesRegex(ValueError, 'SHA-1'):
                index_part(self.path, size, digest)

    def test_empty_or_broken_tail_is_rejected_even_if_file_hash_matches(self):
        packed = bz2.compress(b'content')
        for invalid in (b'', packed[:-1], packed+b'junk'):
            with self.subTest(size=len(invalid)), self.assertRaises(ValueError):
                self.index(invalid)

    def test_real_stream_crc_is_checked_independently_of_block_crc(self):
        packed = bytearray(bz2.compress(b'full original stream integrity'))
        trailer = _markers(packed, 100)[-1]
        after = trailer + 48
        packed[after//8] ^= 1 << (7 - after%8)
        with self.assertRaisesRegex(ValueError, 'stream CRC'):
            self.index(packed)

    def test_block_data_corruption_rejects_authenticated_file(self):
        packed = bytearray(bz2.compress(b'abc'*6000)); packed[10] ^= 64
        with self.assertRaises(ValueError):
            self.index(packed)

    def test_marker_crossing_read_chunk(self):
        import index_original_dump as module
        packed = bz2.compress(random.Random(153).randbytes(200100), compresslevel=1)
        marker = _markers(packed, 100)[0]
        original = module.CHUNK
        self.addCleanup(setattr, module, 'CHUNK', original)
        module.CHUNK = marker // 8 + 3
        desc = self.index(packed)
        self.assertEqual(desc['blocks'][1][0], marker)

    def test_two_parts_parallel_preserve_source_order(self):
        root = self.base / 'enwiktionary' / '20261001'; root.mkdir(parents=True)
        items = []
        for name, raw in [('z.bz2',b'z'*8), ('a.bz2',b'a'*5)]:
            packed = bz2.compress(raw); (root/name).write_bytes(packed)
            items.append(dict(wiki=root.parent.name, date=root.name, name=name, size=len(packed), sha1=hashlib.sha1(packed).hexdigest()))
        seq = index_parts(items,self.base,1)
        self.assertEqual(seq, index_parts(items,self.base,2))
        self.assertEqual(seq['xml_bytes'],13)
        self.assertEqual([p['name'] for p in seq['parts']],['a.bz2','z.bz2'])
        with self.assertRaises(ValueError): index_parts(items+items,self.base,1)

    def test_ranged_archives_follow_page_ids_and_keep_existing_coordinate_orders(self):
        import json
        from build_wiktionaries import validated_original_archive
        from index_original_dump import matches_archive_parts, prepare_build_input, write_directory

        wiki, date = 'frwiktionary', '20261001'
        source = self.base / wiki / date
        source.mkdir(parents=True)
        items = []
        for span, text in [('p1p1500000', b'<page>first</page>'),
                           ('p1500001p3000000', b'<page>second</page>'),
                           ('p3000001p4500000', b'<page>third</page>')]:
            name = f'{wiki}-{date}-pages-meta-current1.xml-{span}.bz2'
            packed = bz2.compress(text)
            (source / name).write_bytes(packed)
            items.append(dict(wiki=wiki, date=date, name=name, size=len(packed), sha1=hashlib.sha1(packed).hexdigest()))

        directory = self.base / 'blocks.json'
        indexed = write_directory(items[::-1], self.base, directory, workers=2, count_pages=True)
        self.assertEqual(indexed, index_parts(items, self.base, 1, count_pages=True))
        parts = indexed['parts']
        self.assertEqual([p['name'] for p in parts], [i['name'] for i in items])
        self.assertEqual(indexed['source_pages'], 3)
        legacy = sorted(parts, key=lambda part: part['name'])
        self.assertNotEqual(parts, legacy)
        self.assertTrue(matches_archive_parts(items, legacy, fresh=False))
        self.assertFalse(matches_archive_parts(items, parts, fresh=False))
        self.assertFalse(matches_archive_parts(items, parts[::-1], fresh=True))
        for label, stored in [('current', parts), ('previous', legacy)]:
            with self.subTest(label=label):
                descriptor = self.base / (label + '.json')
                descriptor.write_text(json.dumps({**indexed, 'parts': stored}))
                selected = self.base / label
                marker = prepare_build_input(selected, descriptor, hashlib.sha256(descriptor.read_bytes()).hexdigest(), items, self.base)
                verified, stamps = validated_original_archive(items, selected, marker)
                self.assertEqual(verified, marker)
                self.assertIn(descriptor, stamps)

    def test_fresh_build_from_split_originals_has_only_current_source_coordinates(self):
        import json
        from index_original_dump import prepare_build_input, write_directory

        source = self.base / 'srwiktionary' / '20261001'
        source.mkdir(parents=True)
        items = []
        for index, raw in enumerate([b'<mediawiki><page>a</page><pa', b'ge>b</page></mediawiki>']):
            name = f'part{index}.xml.bz2'
            packed = bz2.compress(raw)
            (source / name).write_bytes(packed)
            items.append(dict(wiki=source.parent.name, date=source.name, name=name, size=len(packed),
                              sha1=hashlib.sha1(packed).hexdigest()))
        out = self.base / 'blocks.json'
        blocks = write_directory(items[::-1], self.base, out, workers=2, count_pages=True)
        self.assertEqual(blocks['source_pages'], 2)
        self.assertNotIn('zstd_frame_bridge', blocks)
        root = self.base / 'selected'
        digest = hashlib.sha256(out.read_bytes()).hexdigest()
        marker = prepare_build_input(root, out, digest, items, self.base)
        self.assertEqual(json.loads((root / '.complete.json').read_bytes()), marker)
        self.assertEqual(set(marker), {'version', 'source_pages', 'input_sha256', 'source_directory', 'block_directory'})
        self.assertEqual(marker['version'], 'wikidict-original-bzip2-fresh-input-v1')
        self.assertEqual(marker['source_pages'], 2)
        self.assertEqual(marker['block_directory']['sha256'], digest)
        self.assertEqual(sorted(p.name for p in self.base.iterdir()), ['blocks.json', 'selected', 'srwiktionary'])
        for changes in [{'source_pages': None}, {'source_pages': False}, {'source_pages': -1}, {'zstd_frame_bridge': {}}]:
            with self.subTest(changes=changes):
                out.write_text(json.dumps(blocks | changes))
                with self.assertRaisesRegex(ValueError, 'counted original XML'):
                    prepare_build_input(self.base / 'wrong', out, hashlib.sha256(out.read_bytes()).hexdigest(), items, self.base)
                self.assertFalse((self.base / 'wrong').exists())

    def test_fresh_count_validates_unfinished_xml_and_accepts_empty_source(self):
        from index_original_dump import write_directory

        source = self.base / 'aawiktionary' / '20261001'
        source.mkdir(parents=True)
        name = 'empty.xml.bz2'
        out = self.base / 'blocks.json'
        for raw, expected in [(b'<mediawiki><page>unfinished', None), (b'<mediawiki/>', 0)]:
            packed = bz2.compress(raw)
            (source / name).write_bytes(packed)
            items = [dict(wiki=source.parent.name, date=source.name, name=name, size=len(packed), sha1=hashlib.sha1(packed).hexdigest())]
            if expected is None:
                with self.assertRaisesRegex(ValueError, 'Truncated XML'):
                    write_directory(items, self.base, out, count_pages=True)
                self.assertFalse(out.exists())
            else:
                self.assertEqual(write_directory(items, self.base, out, count_pages=True)['source_pages'], expected)

    def test_select_existing_blocks_without_repacking_or_replacing_a_stage(self):
        import json
        from build_wiktionaries import DUMP_STAGING_VERSION, _stage_seekable_dump, dump_input_fingerprint
        from index_original_dump import prepare_build_input, write_directory

        source = self.base / 'tnwiktionary' / '20261001'
        source.mkdir(parents=True)
        name = 'part.xml.bz2'
        packed = bz2.compress(b'<page>one</page>')
        (source / name).write_bytes(packed)
        items = [dict(wiki=source.parent.name, date=source.name, name=name, size=len(packed),
                      sha1=hashlib.sha1(packed).hexdigest())]
        stage = dict(version=DUMP_STAGING_VERSION, input_sha256=dump_input_fingerprint(items))
        _stage_seekable_dump(items, self.base, self.base, stage)
        page_index = dict(bytes=1, sha256=hashlib.sha256(b'1').hexdigest())
        out = self.base / 'blocks.json'
        write_directory(items, self.base, out, stage=stage, page_index=page_index)
        digest = hashlib.sha256(out.read_bytes()).hexdigest()
        root = self.base / 'build-input'

        def select(**overrides):
            args = dict(root=root, output=out, block_sha256=digest, items=items, downloads=self.base,
                        stage=stage, page_index=page_index)
            return prepare_build_input(**(args | overrides))

        for variant in [dict(block_sha256='f' * 64), dict(items=[dict(items[0], sha1='f' * 40)]),
                        dict(stage=dict(stage, input_sha256='f' * 64)), dict(stage=dict(stage, index_size=1)),
                        dict(page_index=dict(page_index, bytes=True)), dict(page_index=dict(page_index, sha256='f' * 64))]:
            with self.subTest(variant=variant), self.assertRaises(ValueError):
                select(**variant)
            self.assertFalse(root.exists())
        marker = select()
        self.assertEqual(list(root.iterdir()), [root / '.complete.json'])
        self.assertEqual(json.loads((root / '.complete.json').read_bytes()), marker)
        self.assertEqual(marker['source_directory'], str(source))
        self.assertEqual(marker['block_directory'], dict(path=str(out), bytes=out.stat().st_size, sha256=digest))
        self.assertEqual(marker['dump_sha256'], stage['dump_sha256'])
        with self.assertRaises(FileExistsError):
            select()
        (source / name).write_bytes(packed[:-1])
        with self.assertRaisesRegex(ValueError, 'archive inventory'):
            select(root=self.base / 'changed')

    def test_single_archive_parallel_blocks_preserve_stream_order_and_recover_ambiguous_split(self):
        from unittest.mock import patch
        import index_original_dump as module
        from build_wiktionaries import DUMP_STAGING_VERSION, _stage_seekable_dump, dump_input_fingerprint

        directory = self.base / 'tnwiktionary' / '20261001'
        directory.mkdir(parents=True)
        raw = b'<page>' + random.Random(327).randbytes(480000).hex().encode() + b'</page>'
        packed = bz2.compress(raw, compresslevel=1) + bz2.compress(b'<page>last</page>')
        name = 'pages.xml.bz2'
        (directory / name).write_bytes(packed)
        items = [dict(wiki=directory.parent.name, date=directory.name, name=name, size=len(packed),
                      sha1=hashlib.sha1(packed).hexdigest())]
        stage = dict(version=DUMP_STAGING_VERSION, input_sha256=dump_input_fingerprint(items))
        _stage_seekable_dump(items, self.base, self.base, stage, workers=1)
        page_index = dict(bytes=1, sha256=hashlib.sha256(b'1').hexdigest())
        def bridge(workers):
            return module.verified_frame_bridge(items, self.base, stage, page_index, workers=workers)
        expected = bridge(1)
        self.assertGreater(len(expected['parts'][0]['blocks']), 4)
        with patch.object(module.os, 'sched_getaffinity', return_value={0, 1, 2}):
            self.assertEqual(bridge(3), expected)
            # Reject a speculative split after earlier buffers have already reached the framer.
            original = module.decode_block
            import threading
            lock = threading.Lock()
            attempts = 0
            def ambiguous(*args):
                nonlocal attempts
                with lock:
                    attempts += 1
                    if attempts == 6:
                        raise OSError('Ambiguous candidate inside packed data')
                return original(*args)
            with patch.object(module, 'decode_block', side_effect=ambiguous):
                self.assertEqual(bridge(3), expected)

    def test_retained_stage_uses_the_same_coordinates_for_split_and_independent_parts(self):
        import json
        from build_wiktionaries import DUMP_STAGING_VERSION, _stage_seekable_dump, dump_input_fingerprint
        from index_original_dump import write_directory

        for mode, parts in [('independent', [b'<page>first</page>', b'<page>next</page>']),
                            ('split', [b'<page>first</page><pa', b'ge>next</page>'])]:
            root = self.base / mode
            directory = root / 'tnwiktionary' / '20261001'
            directory.mkdir(parents=True)
            items = []
            for i, content in enumerate(parts):
                name = f'part{i}.xml.bz2'
                packed = bz2.compress(content)
                (directory / name).write_bytes(packed)
                items.append(dict(wiki='tnwiktionary', date='20261001', name=name, size=len(packed),
                                  sha1=hashlib.sha1(packed).hexdigest()))
            stage = dict(version=DUMP_STAGING_VERSION, input_sha256=dump_input_fingerprint(items))
            _stage_seekable_dump(items, root, root, stage, workers=2)
            page_index = dict(bytes=7, sha256=hashlib.sha256(b'index\r\n').hexdigest())
            output = root / 'directory.json'
            stored = write_directory(items, root, output, stage=stage, page_index=page_index)
            self.assertEqual(json.loads(output.read_bytes()), stored)
            bridge = stored['zstd_frame_bridge']
            self.assertEqual(bridge['dump_sha256'], stage['dump_sha256'])
            self.assertEqual(bridge['offset_index_sha256'], stage['index_sha256'])
            self.assertEqual(sum(size for _, size in bridge['frames']), sum(map(len, parts)))
            with self.assertRaises(FileExistsError):
                write_directory(items, root, output)
            stale = root / 'different.json'
            with self.assertRaisesRegex(ValueError, 'staged dump_sha256'):
                write_directory(items, root, stale, stage=dict(stage, dump_sha256='0' * 64), page_index=page_index)
            self.assertFalse(stale.exists())


if __name__ == '__main__':
    unittest.main()
