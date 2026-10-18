import copy
import unittest
from unittest import mock
import file_metadata_producer_compatibility as policy


class NamespaceProducerCompatibilityTest(unittest.TestCase):
    def authorities(self, kind):
        old = dict(generator_sha256=policy.HISTORICAL_CAPTURE_GENERATOR, dependency_sha256=dict(policy.HISTORICAL_DEPENDENCIES))
        deps = dict(policy.HISTORICAL_DEPENDENCIES)
        deps['src/shared/namespace_registry.zig'] = policy.CURRENT_SOURCE_HASHES['src/shared/namespace_registry.zig']
        new = dict(generator_sha256=policy.CURRENT_SOURCE_HASHES['tools/prepare_file_metadata_v2.py'], dependency_sha256=deps)
        if kind == 'union':
            old = dict(generator_sha256=policy.HISTORICAL_UNION_GENERATOR, capture_producer=old)
            new = dict(generator_sha256=policy.CURRENT_SOURCE_HASHES['tools/prepare_file_metadata_union.py'], capture_producer=new)
        manifest = dict(old, wiki='enwiktionary', date='20261001')
        return manifest, new

    def test_exact_historical_capture_and_union_preserve_original_provenance(self):
        for kind in ('capture', 'union'):
            manifest, current = self.authorities(kind)
            expected = {'azwiktionary', 'bclwiktionary', 'bewwiktionary', 'bgwiktionary', 'bjnwiktionary', 'bnwiktionary', 'cawiktionary', 'enwiktionary'}
            self.assertEqual(set(policy.HISTORICAL_CAPTURE_EDITIONS), expected)
            for wiki in sorted(expected if kind == 'capture' else {'enwiktionary'}):
                manifest['wiki'] = wiki
                original = copy.deepcopy(manifest)
                with mock.patch.object(policy, '_source_hashes', return_value=dict(policy.CURRENT_SOURCE_HASHES)):
                    self.assertTrue(policy.matches(manifest, current, kind, '/unused'), (kind, wiki))
                self.assertEqual(manifest, original)
                self.assertNotEqual(manifest['generator_sha256'], current['generator_sha256'])

    def test_historical_authority_and_current_patch_drift_refuse(self):
        for kind in ('capture', 'union'):
            manifest, current = self.authorities(kind)
            with mock.patch.object(policy, '_source_hashes', return_value=dict(policy.CURRENT_SOURCE_HASHES)):
                for key, bad in [('wiki', 'arwiktionary'), ('date', '20261002'), ('generator_sha256', '0' * 64)]:
                    changed = copy.deepcopy(manifest); changed[key] = bad
                    self.assertFalse(policy.matches(changed, current, kind, '/unused'))
                for wiki in ('arwiktionary', 'zzwiktionary') + (('azwiktionary', 'bclwiktionary', 'bewwiktionary', 'bgwiktionary', 'bjnwiktionary', 'bnwiktionary', 'cawiktionary') if kind == 'union' else ()):
                    changed = copy.deepcopy(manifest); changed['wiki'] = wiki
                    self.assertFalse(policy.matches(changed, current, kind, '/unused'), (kind, wiki))
                self.assertFalse(policy.matches(manifest, current, 'unknown', '/unused'))
                changed = copy.deepcopy(current); changed['generator_sha256'] = '0' * 64
                self.assertFalse(policy.matches(manifest, changed, kind, '/unused'))
            for name in policy.CURRENT_SOURCE_HASHES:
                changed = dict(policy.CURRENT_SOURCE_HASHES); changed[name] = '0' * 64
                with mock.patch.object(policy, '_source_hashes', return_value=changed):
                    self.assertFalse(policy.matches(manifest, current, kind, '/unused'))

    def test_other_capture_dependencies_refuse_and_exact_new_producer_stays_normal(self):
        for kind in ('capture', 'union'):
            manifest, current = self.authorities(kind)
            with mock.patch.object(policy, '_source_hashes', return_value=dict(policy.CURRENT_SOURCE_HASHES)):
                for name in policy.HISTORICAL_DEPENDENCIES:
                    changed = copy.deepcopy(manifest)
                    capture = changed if kind == 'capture' else changed['capture_producer']
                    capture['dependency_sha256'][name] = '0' * 64
                    self.assertFalse(policy.matches(changed, current, kind, '/unused'))
            new_manifest = dict(current, wiki='arwiktionary', date='20261002')
            with mock.patch.object(policy, '_source_hashes', side_effect=AssertionError('Exact ordinary path must remain direct')):
                self.assertTrue(policy.matches(new_manifest, current, kind, '/unused'))
