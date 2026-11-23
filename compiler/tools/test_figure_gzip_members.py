import gzip
import hashlib
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

import figure_gzip_members as codec
import prepare_figure_metadata as figure
from test_prepare_figure_files import CompleteSelectionDocumentTests


class IndexedArchiveTests(unittest.TestCase):
    def test_codec_source_is_bound_to_provenance_and_replay(self):
        with tempfile.TemporaryDirectory() as local:
            source = Path(local) / 'figure_gzip_members.py'
            source.write_bytes(b'first source\n')
            with patch.object(codec, '__file__', str(source)):
                before = figure.inventory_runtime_authority()
                expected = hashlib.sha256(source.read_bytes()).hexdigest()
                self.assertEqual(figure.producer()['dependency_sha256']['figure_gzip_members'], expected)
                self.assertEqual(before[0]['dependency_sha256']['figure_gzip_members'], expected)
                self.assertIn((str(source), str(source.resolve()), figure.evidence.stamp(source)), before[1])
                replaced = source.with_suffix('.new')
                replaced.write_bytes(source.read_bytes())
                replaced.replace(source)
                after = figure.inventory_runtime_authority()
                self.assertEqual(before[0], after[0])
                self.assertNotEqual(before[1], after[1])
                source.write_bytes(b'changed source\n')
                self.assertNotEqual(after[0], figure.capture_source())
                self.assertNotEqual(expected, figure.producer()['dependency_sha256']['figure_gzip_members'])

    def test_bounded_index_and_invalid_members(self):
        with tempfile.TemporaryDirectory() as local:
            root = Path(local)
            rows = (b'{"name":"one"}\n', b'{"name":"two"}\n')
            archive = root / 'archive.gz'
            with archive.open('xb') as output:
                writer = codec.Writer(output)
                for row in rows:
                    writer.write(row)
            first = archive.read_bytes(); left = len(gzip.compress(rows[0], compresslevel=1, mtime=0))
            self.assertEqual(writer.identity(), {'bytes': sum(map(len, rows)), 'sha256': hashlib.sha256(b''.join(rows)).hexdigest()})
            with archive.open('rb') as source:
                stored_sha = hashlib.sha256()
                self.assertEqual(codec.read_member(source, 1024, len(first), stored_sha=stored_sha), rows[0])
                self.assertEqual(source.tell(), left)
                self.assertEqual(codec.read_member(source, 1024, len(first), stored_sha=stored_sha), rows[1])
                self.assertEqual(source.tell(), len(first))
                self.assertEqual(stored_sha.digest(), hashlib.sha256(first).digest())
            locator = left, len(first)-left, len(rows[1]), hashlib.sha256(rows[1]).hexdigest()
            before = figure.evidence.stamp(archive)
            self.assertEqual(codec.read_indexed_row(archive, before, locator), rows[1])
            wrong = root / 'wrong.gz'; wrong.write_bytes(first)
            for path, stamp, candidate in ((wrong,before,locator), (archive,before,(left-1,*locator[1:])),
                (archive,before,(left, locator[1]-1, *locator[2:])),
                (archive,before,(*locator[:3], '0'*64)), (archive,before,(0,len(first),len(rows[0]),hashlib.sha256(rows[0]).hexdigest()))):
                with self.assertRaises(ValueError):
                    codec.read_indexed_row(path, stamp, candidate)
            archive.touch()
            with self.assertRaises(ValueError):
                codec.read_indexed_row(archive, before, locator)
            broken_crc = bytearray(first); broken_crc[left-8] ^= 1
            broken_size = bytearray(first); broken_size[left-4] ^= 1
            for value in (first[:left-1], bytes(broken_crc), bytes(broken_size), gzip.compress(b'a\nb\n')):
                bad = root/'bad.gz'; bad.write_bytes(value)
                with bad.open('rb') as source, self.assertRaises(ValueError):
                    codec.read_member(source, 1024, len(value))
            reordered = gzip.compress(rows[1]) + gzip.compress(rows[0])
            self.assertNotEqual(hashlib.sha256(gzip.decompress(reordered)).hexdigest(), writer.identity()['sha256'])

    def test_identity_append_releases_selected_parent_facts_before_child_replay(self):
        fixture, args, observation, _ = CompleteSelectionDocumentTests.fresh(self)
        parent = args.output
        args.reuse, args.reuse_batch = [parent], [observation]
        args.output = fixture.root / 'identity-lifetime'
        native_read, native_files, native_batch = figure.read_complete_capture, figure.file_records, figure.complete_stream_batch
        parents, stages = [], set()

        def read(path, *values, **options):
            result = native_read(path, *values, **options)
            if Path(path).parent == parent:
                self.assertIs(options.get('include_document'), False)
                self.assertNotIn('document', result)
                if not parents:
                    parents.append(result)
            return result

        def check(stage):
            if parents:
                self.assertNotIn('document', parents[0])
                stages.add(stage)

        def files(*values, **options):
            check('child file projection')
            return native_files(*values, **options)

        def batch(*values, **options):
            check('retained batch replay')
            return native_batch(*values, **options)

        with patch.object(figure, 'read_complete_capture', new=read), \
                patch.object(figure, 'file_records', new=files), patch.object(figure, 'complete_stream_batch', new=batch):
            child = figure.capture_files(args, transport=lambda *_: self.fail('Offline child fetched HTTP'))
        self.assertTrue(parents)
        self.assertEqual(stages, {'child file projection', 'retained batch replay'})
        self.assertEqual(figure.verify(args.output), child)
        for kind in ('parent member', 'dated SQL'):
            path = (parent/figure.PROVIDER) if kind == 'parent member' else Path(args.sql[0])
            original = path.read_bytes()
            try:
                path.write_bytes(original + b'changed')
                with self.subTest(kind=kind), self.assertRaises(ValueError):
                    figure.verify(args.output)
            finally:
                path.write_bytes(original)

    def test_completed_compressed_projection_identity_and_mutations(self):
        fixture, args, _, original = CompleteSelectionDocumentTests.fresh(self)
        root = args.output
        name = figure.ROLES['figure-sizing']
        plain = root / name
        logical = plain.read_bytes()
        stored = plain.with_suffix(plain.suffix + '.gz')
        encoded = gzip.compress(logical, mtime=0)
        stored.write_bytes(encoded)
        plain.unlink()
        authenticate = figure._authenticate_figure_capture_files
        def proof(*values, **options):
            self.assertEqual(options['_verified_projection'], {name: (stored.resolve(), figure.evidence.stamp(stored),
                {'bytes':len(logical), 'sha256':hashlib.sha256(logical).hexdigest()})})
            return authenticate(*values, **options)
        with patch.object(figure, '_authenticate_figure_capture_files', side_effect=proof), \
                patch.object(figure, '_role_identity', side_effect=AssertionError('projection was reinflated')):
            self.assertEqual(figure.verify(root), original)
        for mutation in ('inode', 'same-sized content'):
            def change(*values, **options):
                if mutation == 'inode':
                    replacement = fixture.root / 'same-bytes.gz'
                    replacement.write_bytes(encoded)
                    replacement.replace(stored)
                else:
                    stored.write_bytes(encoded[:-1] + bytes([encoded[-1] ^ 1]))
                return authenticate(*values, **options)
            with self.subTest(mutation=mutation), patch.object(figure, '_authenticate_figure_capture_files', side_effect=change):
                with self.assertRaisesRegex(ValueError, 'changed before content authentication'):
                    figure.verify(root)
            stored.write_bytes(encoded)
        for mutation, data in [('truncated', encoded[:-4]), ('corrupt CRC', encoded[:-8] + bytes([encoded[-8] ^ 1]) + encoded[-7:])]:
            stored.write_bytes(data)
            with self.subTest(mutation=mutation), patch.object(figure, '_authenticate_figure_capture_files') as final:
                with self.assertRaises((EOFError, gzip.BadGzipFile, ValueError)):
                    figure.verify(root)
                final.assert_not_called()

    def test_parent_append_materialize(self):
        fixture, args, observation, original = CompleteSelectionDocumentTests.fresh(self)
        parent = args.output
        for name in (figure.ROLES['figure-sizing-raw'], figure.ROLES['figure-sizing'],
                     figure.MANIFEST, figure.PROVIDER, figure.FILE_REQUESTS, figure.INVENTORY):
            path = parent / name
            raw = path.read_bytes()
            path.unlink()
            stored = path.with_name(path.name+'.gz')
            if name == figure.ROLES['figure-sizing-raw']:
                stored.write_bytes(b''.join(gzip.compress(row, mtime=0) for row in raw.splitlines(keepends=True)))
            else:
                stored.write_bytes(gzip.compress(raw, mtime=0))
        parent_path = parent / figure.MANIFEST
        self.assertEqual(figure.verify(parent), original)
        cache = {}
        checked = figure.read_complete_capture(parent_path, cache)
        self.assertEqual(len(checked['offsets']), 2)
        source = dict(kind='complete-stream',path=str(parent_path),sha256=checked['manifest_sha256'],batch=1)
        self.assertTrue(figure.complete_stream_batch(source,cache)['requests'])
        source_path = parent / (figure.ROLES['figure-sizing-raw']+'.gz')
        stored_original = source_path.read_bytes()
        original_rows = gzip.decompress(stored_original).splitlines(keepends=True)
        source_path.write_bytes(b''.join(gzip.compress(row, mtime=0) for row in (original_rows[0], *reversed(original_rows[1:]))))
        with self.assertRaises(ValueError):
            figure.complete_stream_batch(source,cache)
        output = {}
        with self.assertRaises(ValueError):
            figure.verify(parent, _raw_index_out=output)
        self.assertEqual(output, {})
        source_path.write_bytes(stored_original)
        manifest_path = parent / (figure.MANIFEST+'.gz')
        manifest_store = manifest_path.read_bytes()
        marker_path = parent/figure.COMPLETE
        marker = marker_path.read_bytes()
        forged = figure.encoded({**original, '_raw_storage': checked['raw_storage']})
        manifest_path.write_bytes(gzip.compress(forged, mtime=0))
        marker_path.write_bytes(figure.encoded({'schema':figure.SCHEMA,'manifest_sha256':figure.digest(forged)}))
        with self.assertRaisesRegex(ValueError, 'Invalid Figure capture manifest'):
            figure.verify(parent)
        manifest_path.write_bytes(manifest_store); marker_path.write_bytes(marker)
        self.assertEqual(figure.verify(parent), original)
        args.output = fixture.root/'gzip-append'
        args.reuse = [parent]; args.reuse_batch = [observation]; args.gzip_output = True
        native_complete_batch = figure.complete_stream_batch
        def guarded_parent_batch(reference, retained):
            if Path(reference['path']).parent == parent:
                self.assertNotIn('document', retained[figure.complete_stream_cache_key(reference['path'])])
            return native_complete_batch(reference, retained)
        with patch.object(figure, 'complete_stream_batch', new=guarded_parent_batch):
            child = figure.capture_files(args, transport=lambda *_: self.fail('Offline child fetched HTTP'))
        self.assertEqual(figure.verify(args.output), child)
        for path in (figure.ROLES['figure-sizing-raw'], figure.ROLES['figure-sizing'], figure.PROVIDER):
            self.assertFalse((args.output/path).exists())
            self.assertTrue((args.output/(path+'.gz')).is_file())
        target = fixture.root/'gzip-materialized'
        materialized = figure.materialize_complete_capture(args.output/figure.MANIFEST, target)
        self.assertEqual(figure.verify(target), materialized)
        self.assertEqual(materialized['outputs'], child['outputs'])
        args.output = fixture.root/'identity-append'
        args.gzip_output = False
        ordinary = figure.capture_files(args, transport=lambda *_: self.fail('Identity child fetched HTTP'))
        self.assertEqual(ordinary['outputs'], child['outputs'])


if __name__ == '__main__':
    unittest.main()
