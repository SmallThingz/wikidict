import copy
import io
import json
import os
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

    def test_historical_children_and_union_replay_without_restamping(self):
        child = self.capture(['File:A.ogg'])
        child_manifest = v2.decode((child / v2.MANIFEST).read_bytes())
        child_manifest['generator_sha256'] = 'a' * 64
        child_manifest['dependency_sha256'] = {key: 'b' * 64 for key in child_manifest['dependency_sha256']}
        raw = v2.encoded(child_manifest)
        (child / v2.MANIFEST).write_bytes(raw)
        (child / v2.COMPLETE).write_bytes(v2.encoded({'schema': v2.SCHEMA, 'manifest_sha256': v2.digest(raw)}))
        self.inventory(['ملف:A.ogg'])
        manifest = union.compose([child], self.inv, self.out, WIKI, DATE)
        manifest['generator_sha256'] = 'c' * 64
        manifest['capture_producer'] = {key: child_manifest[key] for key in ('generator_sha256', 'dependency_sha256')}
        raw = v2.encoded(manifest)
        (self.out / union.MANIFEST).write_bytes(raw)
        (self.out / union.COMPLETE).write_bytes(v2.encoded({'schema': union.SCHEMA, 'manifest_sha256': v2.digest(raw)}))
        self.assertEqual(union.verify(self.out), manifest)
        self.assertEqual((self.out / union.MANIFEST).read_bytes(), raw)
        self.assertEqual(self.calls, 1)
        path = self.out / union.TSV
        path.write_bytes(path.read_bytes().replace(b'\tAUDIO\t', b'\tVIDEO\t'))
        self.rehash_outer()
        with self.assertRaisesRegex(ValueError, 'differs from replayed'):
            union.verify(self.out)

    def test_missing_child_producer_provenance_rejected(self):
        manifest = self.prepare()
        manifest['capture_producer'] = {'generator_sha256': 'a' * 64}
        (self.out / union.MANIFEST).write_bytes(v2.encoded(manifest))
        with self.assertRaisesRegex(ValueError, 'producer provenance'):
            union.verify(self.out)

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
        with self.assertRaisesRegex(ValueError, 'completion mismatch'):
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


    def test_extraction_digest_includes_complete_tar_suffix(self):
        self.prepare()
        archive = self.out / 'file-metadata.capture-0000.tar'
        suffix = b'ignored-after-tar-end\0' * 2000
        with archive.open('ab') as stream:
            stream.write(suffix)
        self.rehash_outer()
        target = self.root / 'extracted-with-suffix'
        target.mkdir()
        record, identity = union.extract_capture(archive, target)
        self.assertEqual(record, union.file_record(archive, union.MAX_ARCHIVE))
        self.assertEqual(identity, v2.evidence.stamp(archive))
        self.assertEqual(record['size'], archive.stat().st_size)
        self.assertEqual(union.verify(self.out)['rows'], 2)

    def test_initial_archive_authentication_precedes_extraction(self):
        self.prepare()
        archive = self.out / 'file-metadata.capture-0000.tar'
        with archive.open('ab') as stream:
            stream.write(b'unsealed-tail')
        with mock.patch.object(union, 'extract_capture', side_effect=AssertionError('parsed before auth')) as extract:
            with self.assertRaisesRegex(ValueError, 'inventory changed'):
                union.verify(self.out)
        extract.assert_not_called()

    def test_archive_mutation_or_replacement_during_extraction_refused(self):
        self.prepare()
        original = (self.out / 'file-metadata.capture-0000.tar').read_bytes()
        copy = union.shutil.copyfileobj
        for replacement in (False, True):
            with self.subTest(replacement=replacement):
                archive = self.root / ('mutate-%s.tar' % replacement)
                archive.write_bytes(original)
                target = self.root / ('mutate-%s' % replacement)
                target.mkdir()
                stamp = archive.stat()
                fired = False
                def mutate(source, destination, length):
                    nonlocal fired
                    copy(source, destination, length)
                    if fired:
                        return
                    fired = True
                    if replacement:
                        sibling = archive.with_suffix('.replacement')
                        sibling.write_bytes(original)
                        sibling.replace(archive)
                    else:
                        with archive.open('r+b') as stream:
                            stream.seek(-1, 2)
                            stream.write(b'X')
                    os.utime(archive, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
                with mock.patch.object(union.shutil, 'copyfileobj', side_effect=mutate):
                    with self.assertRaisesRegex(ValueError, 'Archive changed while extracting'):
                        union.extract_capture(archive, target)
                self.assertTrue(fired)

    def test_archive_growth_during_extraction_obeys_byte_limit(self):
        self.prepare()
        archive = self.out / 'file-metadata.capture-0000.tar'
        limit = archive.stat().st_size + 10
        target = self.root / 'growing'
        target.mkdir()
        copy = union.shutil.copyfileobj
        fired = False
        def grow(source, destination, length):
            nonlocal fired
            copy(source, destination, length)
            if not fired:
                fired = True
                with archive.open('ab') as stream:
                    stream.write(b'X' * 11)
        with mock.patch.object(union, 'MAX_ARCHIVE', limit), mock.patch.object(union.shutil, 'copyfileobj', side_effect=grow):
            with self.assertRaisesRegex(ValueError, 'byte limit'):
                union.extract_capture(archive, target)
        self.assertTrue(fired)

    def test_archive_tail_mutation_during_child_replay_refused(self):
        self.prepare()
        archive = self.out / 'file-metadata.capture-0000.tar'
        stamp = archive.stat()
        replay = union.child_identity
        fired = False
        def mutate(*args, **kwargs):
            nonlocal fired
            result = replay(*args, **kwargs)
            if not fired:
                fired = True
                with archive.open('r+b') as stream:
                    stream.seek(-1, 2)
                    stream.write(b'X')
                os.utime(archive, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
            return result
        with mock.patch.object(union, 'child_identity', side_effect=mutate):
            with self.assertRaisesRegex(ValueError, 'Archive changed during replay'):
                union.verify(self.out)
        self.assertTrue(fired)

    def test_final_archive_authentication_still_checks_earlier_capture(self):
        self.prepare()
        archive = self.out / 'file-metadata.capture-0000.tar'
        replay = union.child_identity
        calls = 0
        def mutate(*args, **kwargs):
            nonlocal calls
            result = replay(*args, **kwargs)
            calls += 1
            if calls == 2:
                with archive.open('ab') as stream:
                    stream.write(b'changed-after-first-child')
            return result
        with mock.patch.object(union, 'child_identity', side_effect=mutate):
            with self.assertRaisesRegex(ValueError, 'Union changed during replay'):
                union.verify(self.out)
        self.assertEqual(calls, 2)

    def test_verify_retains_two_archive_authentication_passes(self):
        manifest = self.prepare()
        with mock.patch.object(union, 'file_record', wraps=union.file_record) as check:
            self.assertEqual(union.verify(self.out), manifest)
        archives = [self.out / ('file-metadata.capture-%04d.tar' % number) for number in range(2)]
        for archive in archives:
            self.assertEqual(sum(call.args[0] == archive for call in check.call_args_list), 2)

    def test_identical_archive_replacement_during_replay_refused(self):
        self.prepare()
        archive = self.out / 'file-metadata.capture-0000.tar'
        replay = union.child_identity
        fired = False
        def replace(*args, **kwargs):
            nonlocal fired
            result = replay(*args, **kwargs)
            if not fired:
                fired = True
                sibling = archive.with_suffix('.replacement')
                sibling.write_bytes(archive.read_bytes())
                sibling.replace(archive)
            return result
        with mock.patch.object(union, 'child_identity', side_effect=replace):
            with self.assertRaisesRegex(ValueError, 'Archive changed during replay'):
                union.verify(self.out)
        self.assertTrue(fired)


class BaseCaptureTest(unittest.TestCase):
    setUp = UnionTest.setUp
    capture = UnionTest.capture
    inventory = UnionTest.inventory

    def prepare_base(self):
        self.base = self.capture(['File:A.ogg', 'File:B.ogg', 'File:C.ogg'], negative=('B.ogg',))
        self.addition = self.capture(['File:D.ogg'], negative=('D.ogg',))
        self.inventory(['ملف:A.ogg', 'ملف:B.ogg', 'ملف:C.ogg', 'ملف:D.ogg'])
        with mock.patch.object(union, 'MAX_CHILD_ROWS', 2):
            return union.compose([self.addition], self.inv, self.out, WIKI, DATE, base_capture=self.base)

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
            {'schema': manifest['schema'], 'manifest_sha256': v2.digest(raw)}))

    def test_base_preserves_positive_negative_rows_and_normal_builder_pinning(self):
        manifest = self.prepare_base()
        base_rows = (self.base / union.TSV).read_bytes().splitlines()[1:]
        self.assertEqual(manifest['schema'], union.BASE_SCHEMA)
        self.assertEqual((manifest['rows'], manifest['positive_rows'], manifest['negative_rows']), (4, 2, 2))
        output_rows = (self.out / union.TSV).read_bytes().splitlines()[1:]
        self.assertEqual(output_rows[:3], base_rows)
        with mock.patch.object(union, 'MAX_CHILD_ROWS', 2):
            self.assertEqual(union.verify(self.out), manifest)
            snapshots = {'file-metadata': self.out / union.TSV, 'namespace-registry': self.namespace}
            hashes = builder.verified_auxiliary_hashes(snapshots, WIKI, DATE)
            captures, artifacts = builder.auxiliary_capture_identities(snapshots, WIKI, DATE)
            pinned = builder.pinned_auxiliary_snapshots(snapshots, hashes, self.root / 'pinned', captures, artifacts)
            self.assertEqual(union.validate_snapshot(pinned['file-metadata'], WIKI, DATE), manifest)
        self.assertEqual(self.calls, 2)
        self.assertEqual(union.MAX_CHILD_ROWS, 10000)
        self.assertEqual(union.MAX_BASE_ROWS, v2.MAX_TITLES)

    def test_oversized_new_child_is_not_promoted_to_base(self):
        base = self.capture(['File:A.ogg'])
        addition = self.capture(['File:B.ogg', 'File:C.ogg', 'File:D.ogg'])
        self.inventory(['ملف:A.ogg', 'ملف:B.ogg', 'ملف:C.ogg', 'ملف:D.ogg'])
        with mock.patch.object(union, 'MAX_CHILD_ROWS', 2):
            with self.assertRaisesRegex(ValueError, 'row capacity'):
                union.compose([addition], self.inv, self.out, WIKI, DATE, base_capture=base)
        self.assertFalse((self.out / union.COMPLETE).exists())

    def test_base_still_obeys_finite_existing_capture_capacity(self):
        with mock.patch.object(union, 'MAX_BASE_ROWS', 2):
            with self.assertRaisesRegex(ValueError, 'row capacity'):
                self.prepare_base()
        self.assertFalse((self.out / union.COMPLETE).exists())

    def test_base_reference_cannot_move_or_be_boolean(self):
        self.prepare_base()
        original = (self.out / union.EVIDENCE).read_bytes()
        for reference in (1, False, '0'):
            with self.subTest(reference=reference):
                index = v2.decode(original)
                index['base_capture'] = reference
                (self.out / union.EVIDENCE).write_bytes(v2.encoded(index))
                self.rehash_outer()
                with self.assertRaisesRegex(ValueError, 'base reference'):
                    union.verify(self.out)

    def test_legacy_schema_cannot_smuggle_a_base_reference(self):
        manifest = self.prepare_base()
        manifest['schema'] = union.SCHEMA
        raw = v2.encoded(manifest)
        (self.out / union.MANIFEST).write_bytes(raw)
        (self.out / union.COMPLETE).write_bytes(v2.encoded({'schema': union.SCHEMA, 'manifest_sha256': v2.digest(raw)}))
        with self.assertRaisesRegex(ValueError, 'Invalid union index'):
            union.verify(self.out)

    def test_base_api_tamper_is_replayed_even_with_resealed_outer_archive(self):
        self.prepare_base()
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

    def test_resealed_positive_negative_projection_tamper_fails(self):
        self.prepare_base()
        path = self.out / union.TSV
        path.write_bytes(path.read_bytes().replace(b'\t0\t0\t0\t-\t-', b'\t1\t0\t0\tAUDIO\tX', 1))
        self.rehash_outer()
        with self.assertRaisesRegex(ValueError, 'differs from replayed'):
            union.verify(self.out)

    def test_base_duplicate_root_or_title_is_refused(self):
        base = self.capture(['File:A.ogg'])
        self.inventory(['ملف:A.ogg'])
        with self.assertRaisesRegex(ValueError, 'Duplicate capture root'):
            union.compose([base], self.inv, self.out, WIKI, DATE, base_capture=base)
        addition = self.capture(['File:A.ogg'])
        with self.assertRaisesRegex(ValueError, 'Duplicate title'):
            union.compose([addition], self.inv, self.out, WIKI, DATE, base_capture=base)

    def test_foreign_base_context_is_refused(self):
        base = self.capture(['File:A.ogg'])
        addition = self.capture(['File:B.ogg'])
        self.inventory(['ملف:A.ogg', 'ملف:B.ogg'])
        with self.assertRaisesRegex(ValueError, 'edition/date/namespace mismatch'):
            union.compose([addition], self.inv, self.out, 'glwiktionary', DATE, base_capture=base)

    def test_recursive_union_base_is_not_accepted(self):
        self.prepare_base()
        addition = self.capture(['File:E.ogg'])
        self.inventory(['ملف:A.ogg', 'ملف:B.ogg', 'ملف:C.ogg', 'ملف:D.ogg', 'ملف:E.ogg'])
        with self.assertRaisesRegex(ValueError, 'completion/schema mismatch'):
            union.compose([addition], self.inv, self.root / 'nested', WIKI, DATE, base_capture=self.out)


if __name__ == '__main__':
    unittest.main()
