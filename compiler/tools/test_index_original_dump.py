import bz2
import hashlib
from pathlib import Path
import random
import tempfile
import unittest

from index_original_dump import _markers, decode_block, index_part, index_parts


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
