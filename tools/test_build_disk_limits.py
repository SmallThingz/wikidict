import hashlib
import json
import lzma
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import build_disk_limits as d

HERE = Path(__file__).resolve().parent


class MergeDiskAdmissionTests(unittest.TestCase):
    def setUp(self):
        work = Path(os.environ.get('WIKIDICT_DISK_TEST_ROOT',
            str(HERE.parent / '.tmp' / 'disk-merge-admission-tests')))
        work.mkdir(parents=True, exist_ok=True)
        self.root = Path(tempfile.mkdtemp(prefix='case-', dir=work))
        self.destination = self.root / 'merged'

    def shard(self, name='shard', count=9, heading='English'):
        root = self.root / name
        root.mkdir()
        (root / 'languages').mkdir()
        (root / '.verified').write_bytes(b'verified\n')
        (root / 'page-coverage.json').write_text('{}')
        (root / 'fallback-pages.jsonl').write_bytes(b'{"title":"x"}\n')
        (root / 'languages.tsv').write_bytes(b'heading\n' + heading.encode() + b'\n')
        filename = hashlib.sha256(heading.encode()).hexdigest() + '.wikblb'
        raw = root / 'languages' / filename
        raw.write_bytes(b'WIKBLB08\x01en\0' + heading.encode() + b'\0word\0\x01x')
        row = dict(id=0, name='', kind='language', input_rows=count, compile_only_rows=0,
                   source_unavailable_rows=0, dispatched_rows=count, expanded_pages=count,
                   fallback_pages=0, duplicate_rows=0)
        (root / 'namespace-coverage.json').write_text(json.dumps(
            dict(version=1, registry_sha256='a' * 64, namespaces=[row])))
        return root, raw

    def admit(self, shards, available=10**9, reserve=128, **kwargs):
        with mock.patch.object(d.os, 'statvfs', return_value=SimpleNamespace(
                f_bavail=available, f_frsize=1)) as space:
            receipt = d.require_merge_disk_space(shards, self.destination, reserve, **kwargs)
        space.assert_called_once_with(self.destination.parent)
        return receipt

    def test_measured_components_and_exact_admission_boundary(self):
        one, raw_one = self.shard('one')
        two, raw_two = self.shard('two', 1, 'Français')
        (two / 'thesaurus.wikblb').write_bytes(b'WIKBLB08\x02word\0\x01x')
        plan = self.root / 'compile-plan.tsv'
        plan.write_bytes(b'x' * 37)
        texts = ['é\n', '{"build":true}\n']
        before = {p: p.read_bytes() for s in (one, two) for p in s.rglob('*') if p.is_file()}
        receipt = self.admit([one, two], metadata_paths=[plan, self.root / 'absent'],
                             metadata_texts=texts)
        self.assertEqual(receipt['raw_shard_bytes'], sum(p.stat().st_size for p in
            (raw_one, raw_two, two / 'thesaurus.wikblb')))
        self.assertEqual(receipt['raw_blob_count'], 3)
        self.assertEqual(receipt['fallback_bytes'], 2 * len(b'{"title":"x"}\n'))
        self.assertEqual(receipt['metadata_bytes'], 37 + sum(len(x.encode()) for x in texts))
        self.assertEqual(receipt['required_free_bytes'], sum(receipt[k] for k in
            ('raw_shard_bytes', 'fallback_bytes', 'language_manifest_bound_bytes',
             'namespace_coverage_bound_bytes', 'metadata_bytes', 'reserve_bytes')))
        required = receipt['required_free_bytes']
        self.admit([one, two], required, metadata_paths=[plan], metadata_texts=texts)
        with self.assertRaisesRegex(ValueError, 'Insufficient merge disk space.*raw_shard_bytes'):
            self.admit([one, two], required - 1, metadata_paths=[plan], metadata_texts=texts)
        self.assertFalse(self.destination.exists())
        self.assertEqual(before, {p: p.read_bytes() for p in before})

    def test_compressed_and_mixed_shards_reserve_logical_output_not_transport(self):
        one, raw_one = self.shard('one')
        two, raw_two = self.shard('two',heading='French')
        payload = raw_one.read_bytes() + b'x' * 65536
        raw_one.write_bytes(payload)
        target = Path(str(raw_one)+'.xz')
        target.write_bytes(lzma.compress(payload));raw_one.unlink()
        receipt = self.admit([one,two],allow_compressed=True)
        self.assertEqual(receipt['raw_shard_bytes'],len(payload)+raw_two.stat().st_size)
        self.assertEqual(receipt['stored_shard_blob_bytes'],target.stat().st_size+raw_two.stat().st_size)
        self.assertEqual(receipt['compressed_shard_blob_bytes'],target.stat().st_size)
        required=receipt['required_free_bytes']
        with self.assertRaisesRegex(ValueError,'Insufficient merge disk space'):
            self.admit([one,two],required-1,allow_compressed=True)
        self.assertTrue(target.is_file());self.assertFalse(self.destination.exists())
        with self.assertRaises(ValueError): self.admit([one,two])

    def test_streamed_output_admission_uses_transport_estimate_plus_separate_reserve(self):
        shard,raw=self.shard()
        payload=raw.read_bytes()+b'x'*65536
        raw.write_bytes(payload);target=Path(str(raw)+'.xz')
        target.write_bytes(lzma.compress(payload));raw.unlink()
        ordinary=self.admit([shard],allow_compressed=True)
        streamed=self.admit([shard],allow_compressed=True,compressed_output=True)
        self.assertEqual(ordinary['required_free_bytes']-streamed['required_free_bytes'],
                         len(payload)-target.stat().st_size)
        self.assertEqual(streamed['logical_shard_bytes'],len(payload))
        self.assertEqual(streamed['stored_shard_blob_bytes'],target.stat().st_size)
        self.assertEqual(streamed['raw_output_reservation_bytes'],0)
        self.assertEqual(streamed['compressed_output_estimate_bytes'],target.stat().st_size)
        self.assertEqual(streamed['streaming_output_headroom_bytes'],target.stat().st_size+128)
        self.assertEqual(streamed['remaining_write_headroom_bytes']+128,streamed['required_free_bytes'])
        self.assertIsNone(streamed['compressed_output_size_bound_bytes'])
        required=streamed['required_free_bytes']
        self.admit([shard],required,allow_compressed=True,compressed_output=True)
        with self.assertRaisesRegex(ValueError,'Insufficient merge disk space'):
            self.admit([shard],required-1,allow_compressed=True,compressed_output=True)
        with self.assertRaisesRegex(ValueError,'Insufficient merge disk space'):
            self.admit([shard],required,allow_compressed=True)
        self.assertTrue(target.is_file());self.assertFalse(self.destination.exists())

    def test_small_completed_merge_funds_remaining_writes_below_old_floor(self):
        shard,raw=self.shard()
        payload=raw.read_bytes()+b'x'*65536
        target=Path(str(raw)+'.xz')
        target.write_bytes(lzma.compress(payload));raw.unlink()
        before=target.read_bytes()
        receipt=self.admit([shard],available=2*1024**3-786432,
                           reserve=d.BUILD_DISK_RESERVE_BYTES,
                           allow_compressed=True,compressed_output=True)
        self.assertGreater(receipt['remaining_write_headroom_bytes'],len(before))
        self.assertLess(receipt['required_free_bytes'],2*1024**3-786432)
        self.assertGreater(receipt['reserve_bytes'],0)
        self.admit([shard],receipt['required_free_bytes'],reserve=d.BUILD_DISK_RESERVE_BYTES,
                   allow_compressed=True,compressed_output=True)
        with self.assertRaisesRegex(ValueError,'Insufficient merge disk space'):
            self.admit([shard],receipt['required_free_bytes']-1,reserve=d.BUILD_DISK_RESERVE_BYTES,
                       allow_compressed=True,compressed_output=True)
        self.assertEqual(before,target.read_bytes())
        self.assertFalse(self.destination.exists())

    def test_streamed_mixed_shards_budget_all_pending_transports_without_raw_copy(self):
        one,raw_one=self.shard('one')
        two,raw_two=self.shard('two',heading='French')
        target=Path(str(raw_one)+'.xz')
        target.write_bytes(lzma.compress(raw_one.read_bytes()));raw_one.unlink()
        receipt=self.admit([one,two],allow_compressed=True,compressed_output=True)
        self.assertEqual(receipt['compressed_output_estimate_bytes'],
                         target.stat().st_size+raw_two.stat().st_size)
        self.assertEqual(receipt['raw_output_reservation_bytes'],0)
        self.assertIsNone(receipt['compressed_output_size_bound_bytes'])
        self.assertEqual(receipt['remaining_write_headroom_bytes'],sum(receipt[k] for k in
            ('compressed_output_estimate_bytes','fallback_bytes','language_manifest_bound_bytes',
             'namespace_coverage_bound_bytes','metadata_bytes')))
        self.assertFalse(self.destination.exists())

    def test_streamed_output_keeps_manifest_duplicate_and_identity_checks(self):
        shard,raw=self.shard();target=Path(str(raw)+'.xz')
        target.write_bytes(lzma.compress(raw.read_bytes()))
        with self.assertRaises(ValueError):self.admit([shard],allow_compressed=True,compressed_output=True)
        target.unlink();(shard/'languages.tsv').write_text('heading\nOther\n')
        with self.assertRaisesRegex(ValueError,'manifest/raw file mismatch'):
            self.admit([shard],compressed_output=True)
        (shard/'languages.tsv').write_text('heading\nEnglish\n')
        original=d._identity;calls=0
        def changed(info):
            nonlocal calls
            value=original(info)
            if info.st_ino==raw.stat().st_ino:
                calls+=1
                if calls==3:return value[:-1]+(value[-1]+1,)
            return value
        with mock.patch.object(d,'_identity',side_effect=changed):
            with self.assertRaisesRegex(ValueError,'changed during admission'):
                self.admit([shard],compressed_output=True)
        with self.assertRaisesRegex(ValueError,'Invalid compressed merge output mode'):
            self.admit([shard],compressed_output=1)

    def test_compressed_shard_rejects_duplicate_transport_wrong_kind_and_truncation(self):
        shard, raw = self.shard()
        payload=raw.read_bytes();target=Path(str(raw)+'.xz')
        target.write_bytes(lzma.compress(payload))
        with self.assertRaises(ValueError):self.admit([shard],allow_compressed=True)
        raw.unlink()
        target.write_bytes(lzma.compress(b'WIKBLB08\x02wrong kind'))
        with self.assertRaisesRegex(ValueError,'Expected compressed WIKBLB08'):
            self.admit([shard],allow_compressed=True)
        target.write_bytes(lzma.compress(payload)[:-8])
        with self.assertRaises((ValueError,EOFError,lzma.LZMAError,d.subprocess.CalledProcessError)):
            self.admit([shard],allow_compressed=True)

    def test_alias_only_shard_counts_raw_bytes_and_retains_header_check(self):
        shard, ordinary = self.shard()
        ordinary.unlink()
        (shard / 'languages').rmdir()
        (shard / 'languages.tsv').write_bytes(b'heading\n')
        coverage = json.loads((shard / 'namespace-coverage.json').read_text())
        coverage['namespaces'][0]['alias_pages'] = 9
        (shard / 'namespace-coverage.json').write_text(json.dumps(coverage))
        aliases = shard / 'aliases.wikblb'
        aliases.write_bytes(b'WIKBLB08\x08opaque verified alias records')
        receipt = self.admit([shard])
        self.assertEqual(receipt['raw_shard_bytes'], aliases.stat().st_size)
        self.assertEqual(receipt['raw_blob_count'], 1)
        self.admit([shard], receipt['required_free_bytes'])
        with self.assertRaisesRegex(ValueError, 'Insufficient merge disk space'):
            self.admit([shard], receipt['required_free_bytes'] - 1)
        aliases.write_bytes(b'WIKBLB08\x07wrong kind')
        with self.assertRaisesRegex(ValueError, 'Expected raw WIKBLB08 shard'):
            self.admit([shard])

    def test_alias_counter_included_in_coverage_bound_and_validation(self):
        row = dict(id=0, name='', kind='language', alias_pages=2**64 - 1)
        source = dict(version=1, namespaces=[row])
        bound = d._coverage_bound(json.dumps(source).encode())
        all_counters = dict(row, **{key: 2**64 - 1 for key in d._COUNTERS})
        merged = dict(version=1, registry_sha256='a' * 64, namespaces=[all_counters])
        self.assertGreaterEqual(bound, len(json.dumps(merged, separators=(',', ':')).encode()))
        for value in (-1, 2**64, True):
            row['alias_pages'] = value
            with self.assertRaisesRegex(ValueError, 'Invalid namespace counter'):
                d._coverage_bound(json.dumps(source).encode())

    def test_raw_header_only_read_and_logical_sparse_size(self):
        shard, raw = self.shard()
        with raw.open('r+b') as out:
            out.truncate(4 * 1024**2)
        inode = raw.stat().st_ino
        opened = d.os.fdopen
        reads = []
        class Tracked:
            def __init__(self, source): self.source = source
            def __enter__(self): return self
            def __exit__(self, *args): return self.source.__exit__(*args)
            def fileno(self): return self.source.fileno()
            def read(self, size=-1):
                reads.append(size)
                return self.source.read(size)
        def wrap(fd, *args):
            source = opened(fd, *args)
            return Tracked(source) if os.fstat(fd).st_ino == inode else source
        with mock.patch.object(d.os, 'fdopen', side_effect=wrap):
            receipt = self.admit([shard])
        self.assertEqual(reads, [9])
        self.assertEqual(receipt['raw_shard_bytes'], 4 * 1024**2)

    def test_symlink_artifacts_directories_and_metadata_rejected(self):
        for target in ('raw', 'languages', 'shard', 'fallback', 'plan'):
            with self.subTest(target=target):
                shard, raw = self.shard(target)
                chosen = dict(raw=raw, languages=shard / 'languages', shard=shard,
                              fallback=shard / 'fallback-pages.jsonl',
                              plan=self.root / ('plan-' + target))[target]
                if target == 'plan':
                    chosen.write_text('plan')
                moved = self.root / ('saved-' + target)
                chosen.rename(moved)
                chosen.symlink_to(moved)
                with self.assertRaisesRegex(ValueError, 'symlink'):
                    self.admit([shard], metadata_paths=[chosen] if target == 'plan' else [])

    def test_fifo_rejected_without_opening(self):
        shard, raw = self.shard()
        raw.unlink()
        os.mkfifo(raw)
        with self.assertRaisesRegex(ValueError, 'Unsupported'):
            self.admit([shard])

    def test_compressed_and_unexpected_artifacts_rejected(self):
        for case in ('renamed', 'disguised', 'spool', 'unknown'):
            with self.subTest(case=case):
                shard, raw = self.shard(case)
                if case == 'renamed': raw.rename(raw.with_suffix('.wikblb.xz'))
                elif case == 'disguised': raw.write_bytes(b'\xfd7zXZ\0compressed')
                elif case == 'spool': (shard / '.spool').mkdir()
                else: (shard / 'surprise.wikblb').write_bytes(b'WIKBLB08\x02')
                with self.assertRaises(ValueError): self.admit([shard])

    def test_marker_manifest_and_missing_sidecars_rejected(self):
        for case in ('marker', 'manifest', 'missing'):
            with self.subTest(case=case):
                shard, raw = self.shard(case)
                if case == 'marker': (shard / '.verified').write_text('not verified')
                elif case == 'manifest': (shard / 'languages.tsv').write_text('heading\nOther\n')
                else: (shard / 'fallback-pages.jsonl').unlink()
                with self.assertRaises(ValueError): self.admit([shard])

    def test_namespace_bound_covers_defaults_escaping_and_digit_growth(self):
        row = dict(id=0, name='控制\x01/𐐷', kind='language')
        original = dict(version=1, namespaces=[row])
        bound = d._coverage_bound(json.dumps(original).encode())
        merged_row = dict(row, **{key: 2**64 - 1 for key in d._COUNTERS})
        merged = dict(version=1, registry_sha256='a' * 64, namespaces=[merged_row])
        for ascii_only in (True, False):
            encoded = json.dumps(merged, ensure_ascii=ascii_only, separators=(',', ':')).encode()
            self.assertGreaterEqual(bound, len(encoded))
        for bad in ({}, dict(version=2, namespaces=[]),
                    dict(version=1, namespaces=[dict(row, input_rows=2**64)])):
            with self.assertRaises(ValueError): d._coverage_bound(json.dumps(bad).encode())

    def test_empty_language_manifest_allows_absent_directory_only_when_empty(self):
        shard, raw = self.shard()
        raw.unlink()
        (shard / 'languages').rmdir()
        with self.assertRaisesRegex(ValueError, 'manifest/raw file mismatch'):
            self.admit([shard])
        (shard / 'languages.tsv').write_bytes(b'heading\n')
        self.assertEqual(self.admit([shard])['raw_shard_bytes'], 0)
        (shard / 'thesaurus.wikblb').write_bytes(b'WIKBLB08\x02')
        self.assertEqual(self.admit([shard])['raw_shard_bytes'], 9)

    def test_bounded_sidecar_read(self):
        shard, raw = self.shard()
        with (shard / 'namespace-coverage.json').open('r+b') as source:
            source.truncate(8 * 1024**2 + 1)
        with self.assertRaisesRegex(ValueError, 'size limit'): self.admit([shard])

    def test_empty_duplicate_existing_and_symlink_destination_rejected(self):
        shard, raw = self.shard()
        for roots in ([], [shard, shard]):
            with self.assertRaises(ValueError): self.admit(roots)
        self.destination.mkdir()
        with self.assertRaisesRegex(ValueError, 'already exists'): self.admit([shard])
        other = self.root / 'output-link'
        other.symlink_to(self.root / 'missing')
        self.destination = other
        with self.assertRaisesRegex(ValueError, 'already exists'): self.admit([shard])

    def test_byte_overflow_invalid_reserve_and_filesystem_values(self):
        shard, raw = self.shard()
        for reserve in (-1, 0, True, 1.5, 2**63):
            with self.assertRaises(ValueError): self.admit([shard], reserve=reserve)
        with self.assertRaises(ValueError): d._add(d.MAX_DISK_BYTES, 1)
        for blocks, size in ((-1, 1), (d.MAX_DISK_BYTES, 4096), (10, 0)):
            with mock.patch.object(d.os, 'statvfs', return_value=SimpleNamespace(
                    f_bavail=blocks, f_frsize=size)):
                with self.assertRaises(ValueError):
                    d.require_merge_disk_space([shard], self.destination, 1)

    def test_file_change_during_measurement_rejected(self):
        shard, raw = self.shard()
        original = Path.lstat
        visits = 0
        def changed(path):
            nonlocal visits
            info = original(path)
            if path == raw:
                visits += 1
                if visits == 2:
                    names = ('st_dev', 'st_ino', 'st_mode', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
                    values = {key: getattr(info, key) for key in names}
                    values['st_size'] += 1
                    return SimpleNamespace(**values)
            return info
        with mock.patch.object(Path, 'lstat', changed):
            with self.assertRaisesRegex(ValueError, 'changed during admission'):
                self.admit([shard])


class SiteMetadataDiskBoundTests(unittest.TestCase):
    def test_new_counter_and_authority_hash_fit_native_report_bound(self):
        row=dict(id=0,name='',kind='language',site_metadata_rows=2)
        source=dict(version=1,namespaces=[row])
        bound=d._coverage_bound(json.dumps(source).encode())
        full=dict(version=1,registry_sha256='a'*64,site_info_sha256='b'*64,
                  namespaces=[dict(row,**{key:2**64-1 for key in d._COUNTERS})])
        self.assertGreaterEqual(bound,len(json.dumps(full,separators=(',',':')).encode()))
        del row['site_metadata_rows']
        self.assertEqual(bound,d._coverage_bound(json.dumps(source).encode()))
    def test_site_metadata_counter_rejects_invalid_values(self):
        for value in (-1,2**64,True,'2',None):
            with self.subTest(value=value):
                source=dict(version=1,namespaces=[dict(id=0,name='',kind='language',site_metadata_rows=value)])
                with self.assertRaisesRegex(ValueError,'Invalid namespace counter'):
                    d._coverage_bound(json.dumps(source).encode())


if __name__ == '__main__':
    unittest.main(verbosity=2)
