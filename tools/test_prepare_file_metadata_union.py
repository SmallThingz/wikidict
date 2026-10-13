import copy
import io
import json
from pathlib import Path
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
from urllib.parse import parse_qs, urlsplit

import build_wiktionaries as builder
import prepare_file_metadata_v2 as v2
import prepare_file_metadata_union as union
from test_prepare_file_metadata import registry_bytes, absent_page, response
from test_prepare_file_metadata_v2 import present, WIKI, DATE


class UnionTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='file-metadata-union-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.namespace = self.root / 'namespace.tsv'
        self.namespace.write_bytes(registry_bytes())
        self.inv = self.root / 'inventory.txt'
        self.out = self.root / 'union'
        self.calls = 0
        self.child_roots = []

    def capture(self, titles, negative=()):
        number = len(self.child_roots)
        seed = self.root / ('seed-%d.txt' % number)
        seed.write_text(''.join(t + '\n' for t in titles))
        output = self.root / ('capture-%d' % number)
        args = SimpleNamespace(wiki=WIKI, date=DATE, namespace_registry=self.namespace,
                               output=output, titles=[seed], log=[], batch_size=50,
                               delay=0, wall_seconds=30)
        def transport(url, timeout):
            self.calls += 1
            selected = parse_qs(urlsplit(url).query)['titles'][0].split('|')
            pages = [absent_page(t) if t.split(':', 1)[1] in negative else present(t)
                     for t in selected]
            return 200, {}, v2.encoded(response(*pages, general={'wikiid': WIKI}))
        v2.capture(args, transport=transport, sleep=lambda _: None)
        self.child_roots.append(output)
        return output

    def inventory(self, titles):
        self.inv.write_text(''.join(t + '\n' for t in sorted(titles, key=lambda t: t.encode())))

    def prepare(self):
        self.capture(['File:A.ogg'])
        self.capture(['File:B.ogg'], negative=('B.ogg',))
        self.inventory(['ملف:A.ogg', 'ملف:B.ogg'])
        return union.compose(self.child_roots, self.inv, self.out, WIKI, DATE)

    def rehash_outer(self):
        manifest = v2.decode((self.out / union.MANIFEST).read_bytes())
        index = v2.decode((self.out / union.EVIDENCE).read_bytes())
        index['artifacts'] = union.payload(self.out)
        raw = v2.encoded(index)
        (self.out / union.EVIDENCE).write_bytes(raw)
        manifest['evidence'] = {'path': union.EVIDENCE, 'size': len(raw), 'sha256': v2.digest(raw)}
        tsv = (self.out / union.TSV).read_bytes()
        manifest.update(output_bytes=len(tsv), output_sha256=v2.digest(tsv))
        raw = v2.encoded(manifest)
        (self.out / union.MANIFEST).write_bytes(raw)
        (self.out / union.COMPLETE).write_bytes(v2.encoded(
            {'schema': union.SCHEMA, 'manifest_sha256': v2.digest(raw)}))

    def test_real_v2_replay_union_and_builder_pin_preserve_bytes_and_scope(self):
        original = v2.producer()
        manifest = self.prepare()
        self.assertEqual((manifest['rows'], manifest['positive_rows'], manifest['negative_rows']), (2, 1, 1))
        self.assertFalse(manifest['corpus_query_closure_proven'])
        self.assertEqual(self.calls, 2)
        self.assertEqual(union.verify(self.out), manifest)
        snapshots = {'file-metadata': self.out / union.TSV, 'namespace-registry': self.namespace}
        hashes = builder.verified_auxiliary_hashes(snapshots, WIKI, DATE)
        captures, artifacts = builder.auxiliary_capture_identities(snapshots, WIKI, DATE)
        pinned = builder.pinned_auxiliary_snapshots(snapshots, hashes, self.root / 'pinned',
                                                   captures, artifacts)
        self.assertEqual(union.validate_snapshot(pinned['file-metadata'], WIKI, DATE), manifest)
        self.assertEqual(union.capture_artifacts(self.out / union.TSV, manifest),
                         union.capture_artifacts(pinned['file-metadata'], manifest))
        self.assertEqual(v2.producer(), original)
        self.assertEqual((v2.MAX_TITLES, v2.MAX_REQUESTS, v2.MAX_METADATA),
                         (250000, 10000, 64 * 1024 * 1024))
        self.assertEqual(self.calls, 2)

    def test_duplicate_capture_reference_refused(self):
        root = self.capture(['File:A.ogg'])
        self.inventory(['ملف:A.ogg'])
        with self.assertRaisesRegex(ValueError, 'Duplicate capture'):
            union.compose([root, root], self.inv, self.out, WIKI, DATE)

    def test_duplicate_title_across_independent_captures_refused(self):
        self.capture(['File:A.ogg'])
        self.capture(['File:A.ogg'])
        self.inventory(['ملف:A.ogg'])
        with self.assertRaisesRegex(ValueError, 'Duplicate title'):
            union.compose(self.child_roots, self.inv, self.out, WIKI, DATE)
        self.assertFalse((self.out / union.COMPLETE).exists())

    def test_uncovered_inventory_refused(self):
        self.capture(['File:A.ogg'])
        self.inventory(['ملف:A.ogg', 'ملف:B.ogg'])
        with self.assertRaisesRegex(ValueError, 'Uncovered'):
            union.compose(self.child_roots, self.inv, self.out, WIKI, DATE)
        self.assertFalse((self.out / union.COMPLETE).exists())

    def test_omitted_or_unsorted_inventory_refused(self):
        self.capture(['File:A.ogg', 'File:B.ogg'])
        self.inventory(['ملف:A.ogg'])
        with self.assertRaisesRegex(ValueError, 'differs'):
            union.compose(self.child_roots, self.inv, self.out, WIKI, DATE)
        self.inv.write_text('ملف:B.ogg\nملف:A.ogg\n')
        with self.assertRaisesRegex(ValueError, 'sorted'):
            list(union.inventory_rows(self.inv))

    def test_foreign_edition_date_namespace_refused(self):
        root = self.capture(['File:A.ogg'])
        sha = v2.digest(self.namespace.read_bytes())
        for wiki, date, namespace in [('enwiktionary', DATE, sha), (WIKI, '20261002', sha),
                                     (WIKI, DATE, '0' * 64)]:
            with self.subTest(wiki=wiki, date=date, namespace=namespace):
                with self.assertRaisesRegex(ValueError, 'edition/date/namespace'):
                    union.child_identity(root, wiki, date, namespace)

    def test_changed_archive_and_forged_producer_refused(self):
        self.prepare()
        archive = self.out / 'file-metadata.capture-0000.tar'
        original = archive.read_bytes()
        archive.write_bytes(original + b'changed')
        with self.assertRaisesRegex(ValueError, 'inventory changed'):
            union.verify(self.out)
        archive.write_bytes(original)
        manifest = v2.decode((self.out / union.MANIFEST).read_bytes())
        manifest['generator_sha256'] = '0' * 64
        (self.out / union.MANIFEST).write_bytes(v2.encoded(manifest))
        with self.assertRaisesRegex(ValueError, 'producer changed'):
            union.verify(self.out)

    def test_coherently_rehashed_union_data_still_requires_child_replay(self):
        self.prepare()
        tsv = self.out / union.TSV
        tsv.write_bytes(tsv.read_bytes().replace(b'\tAUDIO\t', b'\tVIDEO\t'))
        self.rehash_outer()
        with self.assertRaisesRegex(ValueError, 'differs from replayed'):
            union.verify(self.out)

    def test_child_raw_api_tamper_cannot_be_hidden_by_outer_hashes(self):
        self.prepare()
        archive = self.out / 'file-metadata.capture-0000.tar'
        with tempfile.TemporaryDirectory(dir=self.root) as temporary:
            child = Path(temporary)
            union.extract_capture(archive, child)
            raw = next(child.glob('*.raw.json'))
            raw.write_bytes(raw.read_bytes() + b' ')
            archive.unlink()
            with tarfile.open(archive, 'w', format=tarfile.USTAR_FORMAT) as tar:
                for path in sorted(child.iterdir()):
                    info = tarfile.TarInfo(path.name)
                    info.size = path.stat().st_size
                    with path.open('rb') as stream:
                        tar.addfile(info, stream)
        self.rehash_outer()
        with self.assertRaisesRegex(ValueError, 'artifact inventory changed'):
            union.verify(self.out)

    def test_row_byte_and_child_capacity_fail_before_completion(self):
        self.capture(['File:A.ogg', 'File:B.ogg'])
        self.inventory(['ملف:A.ogg', 'ملف:B.ogg'])
        with mock.patch.object(union, 'MAX_ROWS', 1):
            with self.assertRaisesRegex(ValueError, 'row limit'):
                union.compose(self.child_roots, self.inv, self.out, WIKI, DATE)
        self.assertFalse(self.out.exists())
        with mock.patch.object(union, 'MAX_CHILD_ROWS', 1):
            with self.assertRaisesRegex(ValueError, 'row capacity'):
                union.child_identity(self.child_roots[0], WIKI, DATE, v2.digest(self.namespace.read_bytes()))
        with mock.patch.object(union, 'MAX_TSV', 32):
            with self.assertRaisesRegex(ValueError, 'capacity'):
                union.merge_rows([self.child_roots[0] / union.TSV], self.inv,
                                 output=self.root / 'too-big.tsv')

    def test_archive_traversal_link_duplicate_and_expansion_refused(self):
        cases = [('file-metadata../escape', tarfile.REGTYPE, 1),
                 ('file-metadata.link', tarfile.SYMTYPE, 0),
                 ('file-metadata.big', tarfile.REGTYPE, v2.MAX_METADATA + 1)]
        for number, (name, kind, size) in enumerate(cases):
            archive = self.root / ('bad-%d.tar' % number)
            info = tarfile.TarInfo(name)
            info.type, info.size, info.linkname = kind, size, '/tmp/foreign'
            with archive.open('wb') as stream:
                stream.write(info.tobuf(format=tarfile.USTAR_FORMAT))
                stream.write(b'\0' * 1024)
            target = self.root / ('bad-root-%d' % number)
            target.mkdir()
            with self.assertRaises(ValueError):
                union.extract_capture(archive, target)
        archive = self.root / 'duplicate.tar'
        with tarfile.open(archive, 'w') as tar:
            for _ in range(2):
                info = tarfile.TarInfo('file-metadata.duplicate')
                info.size = 1
                tar.addfile(info, io.BytesIO(b'x'))
        target = self.root / 'duplicate-root'
        target.mkdir()
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            union.extract_capture(archive, target)

    def test_cached_builder_still_checks_archive_bytes(self):
        self.prepare()
        path = self.out / union.TSV
        builder.validated_auxiliary_capture('file-metadata', path, WIKI, DATE)
        archive = self.out / 'file-metadata.capture-0001.tar'
        archive.write_bytes(archive.read_bytes() + b'changed')
        with self.assertRaisesRegex(ValueError, 'inventory changed'):
            builder.validated_auxiliary_capture('file-metadata', path, WIKI, DATE)


    def test_streamed_merge_crosses_legacy_title_and_64mib_caps(self):
        # Exercise the aggregate stream only. These generated rows are not API
        # evidence and cannot make a completed union without child replay.
        snapshots = []
        streams = []
        try:
            with self.inv.open('wb') as inventory:
                for number in range(250001):
                    if number % 10000 == 0:
                        path = self.root / ('stream-%04d.tsv' % len(snapshots))
                        source = path.open('wb')
                        source.write((v2.HEADER + '\n').encode())
                        snapshots.append(path)
                        streams.append(source)
                    title = ('File:%06d_' % number).encode() + b'a' * 120
                    inventory.write(title + b'\n')
                    source.write(title + b'\t1\t0\t0\tAUDIO\t' + title + b'\n')
        finally:
            for stream in streams:
                stream.close()
        output = self.root / 'large-stream.tsv'
        totals = union.merge_rows(snapshots, self.inv, output=output)
        self.assertEqual(totals['rows'], 250001)
        self.assertGreater(totals['output_bytes'], v2.MAX_METADATA)
        self.assertEqual(union.merge_rows(snapshots, self.inv, existing=output), totals)


if __name__ == '__main__':
    unittest.main()
