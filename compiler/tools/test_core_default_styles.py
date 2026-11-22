"""Offline normal-role tests for the reviewed core-default snapshot variant."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import prepare_stylesheet_imports as collector


class CoreDefaultsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        fixture = Path(__file__).parent / 'testdata' / 'core-default-styles'
        self.snapshot = json.loads((fixture / 'snapshot.json').read_text())
        self.css = (fixture / 'common.css').read_bytes()
        self.namespace = (fixture / 'namespace-registry.tsv').read_bytes()
        self.inputs = self.root / 'inputs'
        self.inputs.mkdir()
        self.put('common.css', self.css)
        value = self.snapshot
        auth = {'wiki': value['wiki'], 'dump_date': value['dump_date'], 'title': 'MediaWiki:Common.css',
                'content_model': 'css', 'decoded_source_bytes': len(self.css),
                'decoded_source_sha256': hashlib.sha256(self.css).hexdigest(),
                'namespace_sha256': value['namespace_sha256'], 'page_id': value['root_page_id'],
                'revision_id': value['root_revision_id']}
        self.put('authority.json', json.dumps(auth).encode())
        self.put('raw.json', value['siteinfo_raw'].encode())
        self.put('normalized.json', value['siteinfo_normalized'].encode())
        self.put('namespace.tsv', self.namespace)
        for pin, source in zip(collector.CORE_SOURCES, value['sources']):
            self.put(pin[0], source['text'].encode())
        self.output = self.root / 'generation'

    def put(self, name, raw):
        (self.inputs / name).write_bytes(raw)

    def derive(self):
        return collector.derive_core_defaults(self.output, self.inputs / 'common.css', self.inputs / 'authority.json',
                    self.inputs / 'raw.json', self.inputs / 'normalized.json', self.inputs / 'namespace.tsv', self.inputs)

    def restamp_for_negative(self):
        # Deliberately recompute outer hashes: semantic verification must still
        # reject a forged projection/graph, not rely only on directory hashes.
        path = self.output / collector.MANIFEST
        manifest = json.loads(path.read_text())
        for name in manifest['artifacts']:
            manifest['artifacts'][name] = collector.digest((self.output / name).read_bytes())
        path.write_text(json.dumps(manifest))
        (self.output / collector.COMPLETE).write_text(json.dumps({'schema': collector.CORE_SCHEMA,
            'manifest_sha256': collector.digest(path.read_bytes())}))

    def test_exact_derivation_normal_summary_and_artifact_replay(self):
        self.assertEqual(self.snapshot, self.derive())
        self.assertEqual(self.snapshot, collector.verify(self.output))
        path = self.output / collector.SNAPSHOT
        record = collector.validate_snapshot(path, 'euwiktionary', '20261001')
        self.assertEqual(collector.CORE_SCHEMA, record['schema'])
        self.assertEqual(collector.CORE_NAMESPACE_SHA, record['namespace_registry_sha256'])
        artifacts = collector.capture_artifacts(path, record)
        self.assertIn(collector.COMPLETE, artifacts)
        self.assertIn('mediawiki.skin.variables.less', artifacts)
        with self.assertRaises(ValueError):
            collector.validate_snapshot(path, 'ptwiktionary', '20261001')
        with self.assertRaises(FileExistsError):
            self.derive()

    def test_forged_range_or_version_never_acquires_authority(self):
        self.derive()
        for field, value in [('projection', dict(collector.CORE_RANGE, start=4825)),
                             ('core_revision', 'caller-selected'), ('coverage_policy', 'all-css-covered')]:
            forged = dict(self.snapshot)
            forged[field] = value
            (self.output / collector.SNAPSHOT).write_text(json.dumps(forged))
            self.restamp_for_negative()
            with self.assertRaises(ValueError):
                collector.verify(self.output)

    def test_rehashed_dependency_change_is_rejected(self):
        self.derive()
        (self.output / 'mediawiki.mixins.less').write_text('/* omitted definitions */')
        self.restamp_for_negative()
        with self.assertRaises(ValueError):
            collector.verify(self.output)

    def test_wrong_root_hash_or_namespace_is_rejected(self):
        self.put('common.css', self.css + b'\n')
        with self.assertRaises(ValueError):
            self.derive()
        self.assertFalse(self.output.exists())
        self.put('common.css', self.css)
        self.put('namespace.tsv', self.namespace + b'\n')
        with self.assertRaises(ValueError):
            self.derive()
        self.assertFalse(self.output.exists())

    def test_wrong_siteinfo_version_is_rejected_before_output(self):
        raw = json.loads(self.snapshot['siteinfo_raw'])
        raw['query']['general']['generator'] = 'MediaWiki 1.48'
        self.put('raw.json', json.dumps(raw).encode())
        with self.assertRaises(ValueError):
            self.derive()
        self.assertFalse(self.output.exists())

    def test_missing_completion_and_unsafe_file_are_rejected(self):
        self.derive()
        (self.output / collector.COMPLETE).unlink()
        with self.assertRaises((ValueError, FileNotFoundError)):
            collector.verify(self.output)
        dependency = self.output / 'mediawiki.mixins.less'
        dependency.unlink()
        dependency.symlink_to(self.inputs / 'mediawiki.mixins.less')
        with self.assertRaises((ValueError, OSError)):
            collector.verify(self.output, require_complete=False)


if __name__ == '__main__':
    unittest.main()
