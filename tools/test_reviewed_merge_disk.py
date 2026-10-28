"""Synthetic integration checks for the converged reviewed merge disk API."""
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import build_disk_limits as disk


class ReviewedMergeDiskTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.shard = self.root / 'shard'
        self.shard.mkdir()
        for name, raw in {'.verified': b'verified\n', 'page-coverage.json': b'{}',
                          'fallback-pages.jsonl': b'', 'languages.tsv': b'heading\n'}.items():
            (self.shard / name).write_bytes(raw)
        self.coverage = dict(version=2, registry_sha256='a' * 64,
            reviewed_nonlexical_sha256='b' * 64, reviewed_nonlexical_page_ids=[7],
            namespaces=[dict(id=0, name='', kind='language', input_rows=1,
                compile_only_rows=0, source_unavailable_rows=0, reviewed_nonlexical_rows=1,
                dispatched_rows=0, expanded_pages=0, fallback_pages=0, duplicate_rows=0)])
        (self.shard / 'namespace-coverage.json').write_text(json.dumps(self.coverage))
        self.manifest = self.root / 'reviewed-nonlexical.json'
        self.manifest.write_bytes(b'synthetic exact reviewed manifest bytes\n')

    def admit(self, **kwargs):
        with mock.patch.object(disk.os, 'statvfs', return_value=SimpleNamespace(f_bavail=10**9, f_frsize=1)):
            return disk.require_merge_disk_space([self.shard], self.root / 'output', 128, **kwargs)

    def test_manifest_reserved_exactly_once_outside_shards(self):
        baseline = self.admit()
        reviewed = self.admit(reviewed_manifest_path=self.manifest)
        self.assertEqual(reviewed['metadata_bytes'] - baseline['metadata_bytes'], self.manifest.stat().st_size)
        self.assertEqual(reviewed['required_free_bytes'] - baseline['required_free_bytes'], self.manifest.stat().st_size)
        self.assertFalse((self.root / 'output').exists())

    def test_manifest_requires_regular_file(self):
        for unsafe in (self.root / 'absent', self.shard):
            with self.subTest(path=unsafe), self.assertRaises((ValueError, FileNotFoundError)):
                self.admit(reviewed_manifest_path=unsafe)
        link = self.root / 'link'
        link.symlink_to(self.manifest)
        with self.assertRaises(ValueError):
            self.admit(reviewed_manifest_path=link)

    def test_shard_layout_stays_strict(self):
        (self.shard / 'reviewed-nonlexical.json').write_bytes(self.manifest.read_bytes())
        with self.assertRaisesRegex(ValueError, 'layout'):
            self.admit(reviewed_manifest_path=self.manifest)

    def test_invalid_coverage_ids_rejected_before_admission(self):
        self.coverage['reviewed_nonlexical_page_ids'] = [7, 7]
        (self.shard / 'namespace-coverage.json').write_text(json.dumps(self.coverage))
        with self.assertRaisesRegex(ValueError, 'reviewed namespace coverage'):
            self.admit(reviewed_manifest_path=self.manifest)


if __name__ == '__main__':
    unittest.main()
