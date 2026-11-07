import copy
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

import prepare_language_names_union as m


def tsv(displays, autonym=False):
    profiles = {display: {mode: {'en': 'English', 'fr': 'French', 'sr': 'Serbian'}
                         for mode in m.generic.SCOPES} for display in displays}
    profiles[next(iter(profiles))]['single']['zz'] = ''
    raw = m.generic.render(profiles, {'en': 'ltr', 'fr': 'ltr', 'sr': 'ltr'},
                           'tpiwiktionary', '20261001', 'tpi')
    if autonym:
        raw += m.autonyms.render_profile({'en': 'English', 'fr': 'Français', 'sr': 'српски', 'zz': ''})
    return raw


class ProjectionTests(unittest.TestCase):
    def setUp(self):
        self.base = tsv(['en', 'tpi'], True)
        self.addition = tsv(['fr', 'sr'])

    def test_exact_old_prefix_and_complete_disjoint_profiles(self):
        out = m.compose(self.base, self.addition, ['sr', 'fr'])
        self.assertTrue(out.startswith(self.base))
        _, old, _ = m.sections(self.base)
        _, joined, _ = m.sections(out)
        for key, value in old.items():
            self.assertEqual(joined[key], value)
        self.assertEqual(len(joined) - len(old), 6)
        self.assertEqual(out, m.compose(self.base, self.addition, ['fr', 'sr']))

    def test_conflicting_or_identical_existing_profile_rejected(self):
        for raw in [tsv(['en']), tsv(['en']).replace(b'English', b'Changed')]:
            with self.assertRaises(ValueError):
                m.compose(self.base, raw, ['en'])

    def test_missing_scope_and_unselected_profile_rejected(self):
        _, blocks, _ = m.sections(self.addition)
        for raw in [self.addition.replace(blocks[('fr', 'mw')], b''), tsv(['fr', 'sr', 'de'])]:
            with self.assertRaises(ValueError):
                m.compose(self.base, raw, ['fr', 'sr'])

    def test_profile_count_and_row_declaration_order_rejected(self):
        for raw in [self.addition.replace(b'C\tfr\tall\t3', b'C\tfr\tall\t4'),
                    self.addition.replace(b'C\tfr\tall\t3\n', b''),
                    self.addition.replace(b'C\tfr\tall\t3', b'C\tfr\tall\t20032')]:
            with self.assertRaises(ValueError):
                m.compose(self.base, raw, ['fr', 'sr'])

    def test_duplicate_profile_or_code_rejected(self):
        for raw in [self.addition + b'C\tfr\tall\t0\n',
                    self.addition.replace(b'N\tfr\tall\tsr\tSerbian', b'N\tfr\tall\tfr\tFrench')]:
            with self.assertRaises(ValueError):
                m.compose(self.base, raw, ['fr', 'sr'])

    def test_reserved_profile_unknown_mode_and_duplicate_selection_rejected(self):
        for raw, profiles in [(tsv(['fr'], True), ['fr']),
                              (self.addition.replace(b'\tall\t', b'\tmwfile\t'), ['fr', 'sr']),
                              (self.addition, ['fr', 'fr']), (self.addition, ['-'])]:
            with self.assertRaises(ValueError):
                m.compose(self.base, raw, profiles)

    def test_direction_mismatch_and_missing_direction_rejected(self):
        for raw in [self.addition.replace(b'D\tfr\tltr', b'D\tfr\trtl'),
                    self.addition.replace(b'C\t-\tdir\t3\n', b'')]:
            with self.assertRaises(ValueError):
                m.compose(self.base, raw, ['fr', 'sr'])

    def test_new_direction_observations_do_not_replace_original_layer(self):
        profiles = {display: {mode: {'en': 'English', 'bjj': 'Kannauji'}
                             for mode in m.generic.SCOPES} for display in ('fr', 'sr')}
        extra = m.generic.render(profiles, {'en':'ltr', 'fr':'ltr', 'sr':'ltr', 'bjj':'ltr'},
                                 'tpiwiktionary', '20261001', 'tpi')
        out = m.compose(self.base, extra, ['fr', 'sr'])
        self.assertTrue(out.startswith(self.base))
        self.assertEqual(m.sections(out)[2], m.sections(self.base)[2])
        self.assertNotIn(b'D\tbjj\t', out)
        self.assertIn(b'N\tfr\tsingle\tbjj\tKannauji\n', out)
        self.assertEqual(m.unadopted_directions(self.base, extra), {'bjj':'ltr'})
        for directions in ({'en':'ltr', 'fr':'rtl', 'sr':'ltr', 'bjj':'ltr'},
                           {'en':'ltr', 'sr':'ltr', 'bjj':'ltr'}):
            bad = m.generic.render(profiles, directions, 'tpiwiktionary', '20261001', 'tpi')
            with self.assertRaisesRegex(ValueError, 'direction conflict'):
                m.compose(self.base, bad, ['fr', 'sr'])

    def test_identity_and_truncated_snapshot_rejected(self):
        for raw in [self.addition.replace(b'tpiwiktionary', b'enwiktionary'), self.addition[:-1]]:
            with self.assertRaises(ValueError):
                m.compose(self.base, raw, ['fr', 'sr'])

    def test_profile_limit_checked_after_composition(self):
        displays = [f'x{i:02}' for i in range(20)]
        base = tsv(displays, True)
        with self.assertRaises(ValueError):
            m.compose(base, self.addition, ['fr', 'sr'])

    def test_escaped_and_empty_names_remain_exact_bytes(self):
        raw = self.addition.replace(b'N\tfr\tsingle\ten\tEnglish',
                                   b'N\tfr\tsingle\ten\ta\\tb\\nc\\\\d')
        out = m.compose(self.base, raw, ['fr', 'sr'])
        self.assertIn(b'N\tfr\tsingle\ten\ta\\tb\\nc\\\\d\n', out)
        self.assertIn(b'N\tfr\tsingle\tzz\t\n', out)
        self.assertTrue(out.startswith(self.base))


class ArchiveAndBuilderTests(unittest.TestCase):
    """Mock only existing API replay boundaries; never claim real API acceptance."""
    @classmethod
    def setUpClass(cls):
        repo = Path(m.evidence.__file__).resolve().parent.parent
        scratch = repo / '.tmp'; scratch.mkdir(exist_ok=True)
        cls.scratch = tempfile.TemporaryDirectory(prefix='names-union-suite-', dir=scratch)
        cls.addClassCleanup(cls.scratch.cleanup)
        cls.tempdir_patch = mock.patch.object(tempfile, 'tempdir', cls.scratch.name)
        cls.tempdir_patch.start(); cls.addClassCleanup(cls.tempdir_patch.stop)
        cls.temp = tempfile.TemporaryDirectory(prefix='names-union-unit-', dir=m.scratch())
        cls.root = Path(cls.temp.name)
        cls.base, cls.addition, cls.output = (cls.root / n for n in ('base', 'addition', 'union'))
        cls.expected = {}
        for root, helper, raw in [(cls.base, m.autonyms, tsv(['en', 'tpi'], True)),
                                  (cls.addition, m.generic, tsv(['fr', 'sr']))]:
            root.mkdir()
            if helper is m.generic:
                raw = raw.replace(b'C\t-\tdir\t3\n', b'C\t-\tdir\t4\n') + b'D\tbjj\tltr\n'
            evidence = b'unit synthetic response only; independent observation time unknown\n'
            namespace = b'unit same namespace bytes\n'
            namespace_name = 'language-autonyms.namespace-registry.tsv' if helper is m.autonyms else 'language-names.namespace-registry.tsv'
            payload = {m.TSV: raw, 'language-names.unit-response.json': evidence, namespace_name: namespace}
            for name, data in payload.items():
                (root / name).write_bytes(data)
            manifest = dict(schema=helper.SCHEMA, wiki='tpiwiktionary', date='20261001', content_language='tpi',
                            namespace_registry_sha256=m.identity(namespace)['sha256'],
                            artifacts={name: m.identity(data) for name, data in payload.items()},
                            observed_at=None, unit_fixture=True)
            (root / m.MANIFEST).write_text(json.dumps(manifest))
            (root / m.COMPLETE).write_text(json.dumps({'unit_fixture': True}))
            cls.expected[helper.SCHEMA] = manifest
        cls.base_patch = mock.patch.object(m.autonyms, 'validate_snapshot', side_effect=cls.validate_fixture)
        cls.add_patch = mock.patch.object(m.generic, 'validate_snapshot', side_effect=cls.validate_fixture)
        cls.base_validator = cls.base_patch.start(); cls.add_validator = cls.add_patch.start()
        try:
            cls.manifest = m.union(cls.base, cls.addition, cls.output, ['sr', 'fr'])
        except BaseException:
            cls.add_patch.stop(); cls.base_patch.stop(); cls.temp.cleanup()
            raise
        path = Path(__file__).with_name('build_wiktionaries.py')
        spec = importlib.util.spec_from_file_location('union_candidate_builder', path)
        cls.builder = importlib.util.module_from_spec(spec); spec.loader.exec_module(cls.builder)

    @classmethod
    def tearDownClass(cls):
        cls.add_patch.stop(); cls.base_patch.stop(); cls.temp.cleanup()

    @classmethod
    def validate_fixture(cls, path, wiki=None, date=None):
        path = Path(path); manifest = json.loads((path.parent / m.MANIFEST).read_text())
        expected = cls.expected[manifest['schema']]
        if manifest != expected or (wiki is not None and wiki != expected['wiki']) or (date is not None and date != expected['date']):
            raise ValueError('Synthetic child fixture changed')
        for name, value in expected['artifacts'].items():
            if m.identity((path.parent / name).read_bytes()) != value:
                raise ValueError('Synthetic child evidence changed')
        return manifest

    def copy_union(self):
        root = self.root / self.id().split('.')[-1]
        shutil.copytree(self.output, root)
        return root

    def reseal(self, root, manifest):
        manifest['artifacts'] = m.inventory(root)
        (root / m.MANIFEST).write_text(json.dumps(manifest))
        (root / m.COMPLETE).write_text(json.dumps(dict(schema=m.SCHEMA,
            manifest_sha256=m.identity((root / m.MANIFEST).read_bytes())['sha256'])))

    def test_children_are_replayed_and_provenance_preserved(self):
        out = m.validate_snapshot(self.output / m.TSV)
        self.assertEqual(out, self.manifest)
        self.assertTrue(self.base_validator.called and self.add_validator.called)
        for role, source in [('base', self.base), ('addition', self.addition)]:
            for name in out['children'][role]['files']:
                self.assertEqual((self.output / (role + '.' + name)).read_bytes(), (source / name).read_bytes())
        self.assertFalse(out['atomic_observation'])
        self.assertEqual(out['temporal_scope'], 'independent-current-api-observations')
        self.assertIsNone(json.loads((self.output / ('base.' + m.MANIFEST)).read_text())['observed_at'])
        self.assertEqual(out['unadopted_direction_rows'], {'bjj':'ltr'})
        self.assertNotIn(b'D\tbjj\t', (self.output / m.TSV).read_bytes())

    def test_resealed_direction_policy_and_unadopted_rows_are_rejected(self):
        for field, value in (('direction_policy', 'refresh'),
                             ('unadopted_direction_rows', {}),
                             ('unadopted_direction_rows', {'bjj':'rtl'})):
            with tempfile.TemporaryDirectory(dir=self.root) as directory:
                root=Path(directory)/'union';shutil.copytree(self.output,root)
                manifest=copy.deepcopy(self.manifest);manifest[field]=value;self.reseal(root,manifest)
                with self.assertRaisesRegex(ValueError,'Union projection differs'):
                    m.validate_snapshot(root/m.TSV)

    def test_tampered_child_bytes_rejected(self):
        root = self.copy_union()
        (root / ('addition.' + m.TSV)).write_bytes(b'changed')
        with self.assertRaises(ValueError):
            m.validate_snapshot(root / m.TSV)

    def test_resealed_unreferenced_prefixed_artifact_rejected(self):
        root = self.copy_union(); manifest = copy.deepcopy(self.manifest)
        (root / 'base.unreferenced').write_bytes(b'unvalidated evidence')
        self.reseal(root, manifest)
        with self.assertRaisesRegex(ValueError, 'Unreferenced or missing child artifact'):
            m.validate_snapshot(root / m.TSV)

    def test_noncanonical_selection_order_rejected(self):
        root = self.copy_union(); manifest = copy.deepcopy(self.manifest)
        manifest['profiles_added'] = ['sr', 'fr']; self.reseal(root, manifest)
        with self.assertRaisesRegex(ValueError, 'Noncanonical profile selection'):
            m.validate_snapshot(root / m.TSV)

    def test_resealed_child_inventory_still_requires_original_validator(self):
        root = self.copy_union(); manifest = copy.deepcopy(self.manifest)
        name = 'language-names.unit-response.json'; data = b'forged observation'
        (root / ('addition.' + name)).write_bytes(data)
        manifest['children']['addition']['files'][name] = m.identity(data)
        self.reseal(root, manifest)
        with self.assertRaisesRegex(ValueError, 'Synthetic child evidence changed'):
            m.validate_snapshot(root / m.TSV)

    def test_union_output_and_producer_tamper_rejected(self):
        root = self.copy_union(); manifest = copy.deepcopy(self.manifest)
        (root / m.TSV).write_bytes((root / m.TSV).read_bytes().replace(b'English', b'Changed'))
        manifest['output'] = m.identity((root / m.TSV).read_bytes()); self.reseal(root, manifest)
        with self.assertRaises(ValueError):
            m.validate_snapshot(root / m.TSV)
        manifest['generator_sha256'] = '0' * 64; self.reseal(root, manifest)
        with self.assertRaises(ValueError):
            m.validate_snapshot(root / m.TSV)

    def test_reserved_selection_and_namespace_mismatch_rejected(self):
        for field, value in [('profiles_added', ['-']), ('namespace_registry_sha256', '0' * 64)]:
            root = self.root / (self.id().split('.')[-1] + field); shutil.copytree(self.output, root)
            manifest = copy.deepcopy(self.manifest); manifest[field] = value; self.reseal(root, manifest)
            with self.assertRaises(ValueError):
                m.validate_snapshot(root / m.TSV)

    def test_unsafe_child_path_and_extra_artifact_rejected(self):
        root = self.copy_union(); manifest = copy.deepcopy(self.manifest)
        manifest['children']['addition']['files']['../outside'] = m.identity(b'bad'); self.reseal(root, manifest)
        with self.assertRaises(ValueError):
            m.validate_snapshot(root / m.TSV)
        (root / 'unexpected').write_bytes(b'extra')
        with self.assertRaises(ValueError):
            m.validate_snapshot(root / m.TSV)

    def test_symlink_and_total_evidence_limit_rejected(self):
        root = self.copy_union(); target = root / ('addition.' + m.TSV); target.unlink(); target.symlink_to(self.addition / m.TSV)
        with self.assertRaises(ValueError):
            m.validate_snapshot(root / m.TSV)
        with mock.patch.object(m, 'MAX_TOTAL', 1), self.assertRaises(ValueError):
            m.validate_snapshot(self.output / m.TSV)

    def test_actual_builder_dispatch_pinning_and_replay(self):
        b = self.builder; path = self.output / m.TSV
        self.assertIs(b.auxiliary_capture_helper('language-names', path), m)
        record, artifacts = b.validated_auxiliary_capture('language-names', path, 'tpiwiktionary', '20261001')
        self.assertEqual(record, self.manifest)
        verified = b.verified_auxiliary_hashes({'language-names': path}, 'tpiwiktionary', '20261001')
        self.assertEqual(verified, {'language-names': m.identity(path.read_bytes())['sha256']})
        self.assertIn('base.language-autonyms.namespace-registry.tsv', artifacts)
        destination = self.root / 'builder-stage'; destination.mkdir()
        namespace = self.base / 'language-autonyms.namespace-registry.tsv'
        snapshots = {'language-names': path, 'namespace-registry': namespace}
        hashes = {name: m.identity(p.read_bytes())['sha256'] for name, p in snapshots.items()}
        pinned = b.pinned_auxiliary_snapshots(snapshots, hashes, destination)
        self.assertEqual(pinned['language-names'], destination / 'language-names' / m.TSV)
        self.assertEqual(b.validated_auxiliary_capture('language-names', pinned['language-names'])[0], self.manifest)

    def test_preferred_autonym_generation_accepts_only_authenticated_union(self):
        parent = self.root / 'discovery'; parent.mkdir()
        shutil.copytree(self.output, parent / 'language-names-autonyms-v1')
        found = self.builder.discover_auxiliary_generation(parent, 'language-names-autonyms-v1', ('language-names',), 'tpiwiktionary', '20261001')
        self.assertIn('language-names', found)
        path = parent / 'language-names-autonyms-v1' / m.MANIFEST
        value = json.loads(path.read_text()); value['schema'] = 'unknown-union'; path.write_text(json.dumps(value))
        with self.assertRaises(ValueError):
            self.builder.discover_auxiliary_generation(parent, 'language-names-autonyms-v1', ('language-names',), 'tpiwiktionary', '20261001')

    def test_builder_namespace_provenance_matches_selected_capture(self):
        capture_root = self.root / 'namespace-selection'; capture_root.mkdir()
        path = capture_root / 'namespace-registry.tsv'
        path.write_bytes((self.base / 'language-autonyms.namespace-registry.tsv').read_bytes())
        capture = dict(wiki='tpiwiktionary', date='20261001')
        self.builder.validate_captured_snapshot('language-names', self.output / m.TSV, capture, [], capture_root)
        path.write_bytes(b'other namespace snapshot')
        with self.assertRaises(ValueError):
            self.builder.validate_captured_snapshot('language-names', self.output / m.TSV, capture, [], capture_root)


if __name__ == '__main__':
    unittest.main()
