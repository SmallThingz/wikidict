import copy
from contextlib import contextmanager
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

import prepare_language_names_union as m


class ProducerContractTests(unittest.TestCase):
    def test_current_producer_binds_actual_generator_and_reviewed_dependencies(self):
        actual = m.producer()
        self.assertEqual(actual['generator_sha256'], m.identity(Path(m.__file__).read_bytes())['sha256'])
        self.assertEqual(actual['dependency_sha256'], {
            'prepare_language_names_autonyms.py': 'bf84f0c4ff9549a054e213704031bab06bb0e6c0f6564183c44ee888a901d904',
            'prepare_language_names_generic.py': 'bbe9020879766923c63021b93016aa0edb5331be0b996671351cb4f953e6ebc3',
            'prepare_file_metadata.py': 'cc8684fd9d0b8e38d4ccf53730cb0863249b2706132c474a2c5c42c0e738d802',
        })
        for name, module in (('prepare_language_names_autonyms.py', m.autonyms),
                             ('prepare_language_names_generic.py', m.generic),
                             ('prepare_file_metadata.py', m.evidence)):
            self.assertEqual(actual['dependency_sha256'][name], m.identity(Path(module.__file__).read_bytes())['sha256'])

    def test_changed_dependency_bytes_cannot_issue_current_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            changed = Path(directory) / 'prepare_file_metadata.py'
            changed.write_bytes(Path(m.evidence.__file__).read_bytes() + b'\n')
            with mock.patch.object(m.evidence, '__file__', str(changed)):
                with self.assertRaisesRegex(ValueError, 'Union dependency changed: prepare_file_metadata.py'):
                    m.producer()


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
        repo = Path(__file__).resolve().parents[2]
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

    def test_resealed_union_output_tamper_rejected(self):
        root = self.copy_union(); manifest = copy.deepcopy(self.manifest)
        (root / m.TSV).write_bytes((root / m.TSV).read_bytes().replace(b'English', b'Changed'))
        manifest['output'] = m.identity((root / m.TSV).read_bytes()); self.reseal(root, manifest)
        with self.assertRaises(ValueError):
            m.validate_snapshot(root / m.TSV)

    def test_resealed_producer_changes_rejected_against_valid_archive(self):
        changes = (
            ('generator', {'generator_sha256': '0' * 64}),
            ('historical-generator', {'generator_sha256': '027db1c6d7e87647c8b33c1d819d2f308bfca6728a088b2393e8a8f3c80eaf77'}),
            ('historical-dependency', {'dependency_sha256': dict(self.manifest['dependency_sha256'],
                **{'prepare_file_metadata.py': 'd2a09c741c3fb12ee1a59ea5ce6eeb9611105ffa782d90ca25d3a7b37acf23ab'})}),
        )
        for label, update in changes:
            with self.subTest(label=label):
                root = self.root / (self.id().split('.')[-1] + '-' + label)
                shutil.copytree(self.output, root)
                manifest = copy.deepcopy(self.manifest); manifest.update(update)
                self.reseal(root, manifest)
                self.assertEqual((root / m.TSV).read_bytes(), (self.output / m.TSV).read_bytes())
                with self.assertRaisesRegex(ValueError, 'Unreviewed union producer or scope'):
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


def prepare_real_validator_union_fixture(base, work, union_module):
    """Use retained source evidence with an explicitly synthetic raw response.

    The base is read-only. The addition is a unit fixture, not a captured API
    observation or evidence of French language-name correctness.
    """
    import argparse
    import urllib.parse

    module = union_module
    base, work = Path(base).resolve(), Path(work)
    base_manifest_raw = module.autonyms.regular(base / module.MANIFEST)
    base_manifest = module.autonyms.validate_snapshot(base / module.TSV)
    base_files = {name: module.identity(module.autonyms.regular(base / name))
                  for name in (*base_manifest['artifacts'], module.MANIFEST, module.COMPLETE)}
    base_raw = module.autonyms.regular(base / module.TSV)
    _, base_profiles, base_directions = module.sections(base_raw)
    if any(('fr', scope) in base_profiles for scope in module.generic.SCOPES):
        raise ValueError('Real-validator fixture requires a disjoint fr profile')
    previous = module.evidence.decode(module.autonyms.regular(
        base / ('previous.' + module.MANIFEST)))
    if (previous.get('schema') != module.generic.SCHEMA
            or previous.get('core') != '79b81ba96674efc8a803fc956bc501d347d440d2'
            or previous.get('name_source_profile') is not None):
        raise ValueError('Real-validator fixture requires the retained generic source profile')
    work.mkdir(exist_ok=False)
    sources = work / 'primary'; sources.mkdir()
    for name, digest in module.generic.SOURCE_PINS.items():
        archived = 'previous.language-names.source-' + name
        raw = module.autonyms.regular(base / archived)
        if (module.identity(raw) != base_manifest['artifacts'].get(archived)
                or module.identity(raw)['sha256'] != digest):
            raise ValueError('Retained primary source differs: ' + name)
        (sources / name).write_bytes(raw)
    _, aliases, tables = module.generic.primary_contract(sources, core=previous['core'])
    namespace_raw = module.autonyms.regular(base / 'previous.language-names.namespace-registry.tsv')
    if module.identity(namespace_raw)['sha256'] != base_manifest['namespace_registry_sha256']:
        raise ValueError('Retained namespace differs')
    namespace = work / 'namespace-registry.tsv'; namespace.write_bytes(namespace_raw)

    # A complete deterministic synthetic MW table deliberately overrides CLDR
    # values. Names are fixture labels, not asserted French translations. The
    # real source parser still proves the aliases and complete English universe.
    codes = set(tables['en']) | set(base_directions) | set(aliases) | set(aliases.values()) | {'fr'}
    if 'en-x-piglatin' not in base_directions:
        codes.discard('en-x-piglatin')
    mw = {code: 'Synthetic union fixture ' + code for code in sorted(codes)}
    info = {code: dict(code=code, name=mw[aliases.get(code, code)],
                       dir=base_directions.get(code, 'ltr'), fallbacks=[])
            for code in sorted(codes)}
    response = {
        'unit_fixture': {'synthetic': True, 'network_observation': False,
                         'purpose': 'Current union producer and real child-validator regression'},
        'query': {
            'general': {'wikiid': base_manifest['wiki'], 'lang': base_manifest['content_language'],
                        'git-hash': previous['core']},
            'languageinfo': info,
            'languages': [dict(code=code, name=name) for code, name in mw.items()],
        },
    }
    raw_response = module.evidence.encoded(response)
    calls = []

    def transport(url, timeout):
        parsed = urllib.parse.urlsplit(url)
        expected = module.generic.request_query('fr', True, {})
        if (url != module.evidence.wiktionary_api(base_manifest['wiki']) + '?' +
                urllib.parse.urlencode(sorted(expected.items()))
                or urllib.parse.parse_qs(parsed.query) != {key: [value] for key, value in expected.items()}
                or calls or not 0 < timeout <= 30):
            raise AssertionError('Unexpected synthetic fixture transport request')
        calls.append(url)
        return 200, {'content-type': 'application/json'}, raw_response

    def no_retry(delay):
        raise AssertionError('Synthetic fixture unexpectedly requested a retry')

    args = argparse.Namespace(
        wiki=base_manifest['wiki'], date=base_manifest['date'], namespace_registry=namespace,
        primary_sources=sources, output=work / 'addition', languages=['fr'],
        core=previous['core'], delay=0, wall_seconds=60,
    )
    addition_manifest = module.generic.capture(args, transport=transport, sleep=no_retry)
    if len(calls) != 1 or module.generic.validate_snapshot(args.output / module.TSV) != addition_manifest:
        raise AssertionError('Real generic validator did not reproduce the authored addition')
    observed_raw = args.output / addition_manifest['requests'][0]['accepted_receipt']
    receipt = module.evidence.decode(module.autonyms.regular(observed_raw))
    if module.autonyms.regular(args.output / receipt['response']) != raw_response:
        raise AssertionError('Synthetic raw response was not retained exactly')
    if ({name: module.identity(module.autonyms.regular(base / name)) for name in base_files} != base_files
            or module.autonyms.regular(base / module.MANIFEST) != base_manifest_raw):
        raise AssertionError('Read-only genuine base changed')
    return dict(base=base, addition=args.output, base_manifest=base_manifest,
                addition_manifest=addition_manifest, raw_response=raw_response,
                base_files=base_files, raw_response_name=receipt['response'],
                fixture_marker=response['unit_fixture'])


class RealChildValidatorUnionTests(unittest.TestCase):
    """Optional retained-source integration; no validator or producer mocks."""
    @classmethod
    def setUpClass(cls):
        import os
        selected = os.environ.get('WIKIDICT_NAMES_UNION_REAL_BASE')
        if selected is None:
            raise unittest.SkipTest('Set WIKIDICT_NAMES_UNION_REAL_BASE to the retained source fixture')
        base = Path(selected)
        if not base.is_absolute() or not base.is_dir():
            raise ValueError('Selected real-validator base must be an existing absolute directory')
        project = Path(m.__file__).resolve().parent.parent
        if project.name == 'compiler':
            project = project.parent
        scratch = project / '.tmp'; scratch.mkdir(exist_ok=True)
        cls.temp = tempfile.TemporaryDirectory(prefix='names-union-real-validator-', dir=scratch)
        cls.addClassCleanup(cls.temp.cleanup)
        # Autonym archive replay uses tempfile's default location. This changes
        # scratch placement only, never a validator, source pin or producer.
        temporary_root = mock.patch.object(tempfile, 'tempdir', cls.temp.name)
        temporary_root.start(); cls.addClassCleanup(temporary_root.stop)
        cls.root = Path(cls.temp.name)
        cls.fixture = prepare_real_validator_union_fixture(base, cls.root / 'authored', m)
        cls.output = cls.root / 'union'
        cls.manifest = m.union(cls.fixture['base'], cls.fixture['addition'], cls.output, ['fr'])

    @contextmanager
    def copy_union(self, suffix):
        with tempfile.TemporaryDirectory(prefix='union-mutation-' + suffix + '-', dir=self.root) as directory:
            root = Path(directory) / 'union'
            shutil.copytree(self.output, root)
            yield root

    @staticmethod
    def reseal(root, manifest):
        raw = m.evidence.encoded(manifest)
        (root / m.MANIFEST).write_bytes(raw)
        (root / m.COMPLETE).write_bytes(m.evidence.encoded(
            dict(schema=m.SCHEMA, manifest_sha256=m.identity(raw)['sha256'])))

    def test_current_union_replays_real_children_and_records_actual_producer(self):
        self.assertEqual(m.autonyms.validate_snapshot(self.fixture['base'] / m.TSV),
                         self.fixture['base_manifest'])
        self.assertEqual(m.generic.validate_snapshot(self.fixture['addition'] / m.TSV),
                         self.fixture['addition_manifest'])
        self.assertEqual(m.validate_snapshot(self.output / m.TSV), self.manifest)
        self.assertEqual({key: self.manifest[key] for key in m.producer()}, m.producer())
        self.assertEqual(m.producer()['generator_sha256'], m.identity(Path(m.__file__).read_bytes())['sha256'])
        self.assertEqual(m.producer()['dependency_sha256']['prepare_file_metadata.py'],
                         m.identity(Path(m.evidence.__file__).read_bytes())['sha256'])
        self.assertTrue((self.output / m.TSV).read_bytes().startswith(
            (self.fixture['base'] / m.TSV).read_bytes()))
        self.assertEqual((self.output / ('addition.' + self.fixture['raw_response_name'])).read_bytes(),
                         self.fixture['raw_response'])
        self.assertEqual(m.evidence.decode(self.fixture['raw_response'])['unit_fixture'],
                         self.fixture['fixture_marker'])
        self.assertIs(self.fixture['fixture_marker']['network_observation'], False)
        self.assertEqual({name: m.identity(m.autonyms.regular(self.fixture['base'] / name))
                          for name in self.fixture['base_files']}, self.fixture['base_files'])
        for field in ('atomic_observation', 'native_resolution_proven', 'corpus_query_closure_proven'):
            self.assertIs(self.manifest[field], False)

    def test_historical_producer_substitution_is_refused_without_restamping(self):
        historical_generator = '027db1c6d7e87647c8b33c1d819d2f308bfca6728a088b2393e8a8f3c80eaf77'
        historical_evidence = 'd2a09c741c3fb12ee1a59ea5ce6eeb9611105ffa782d90ca25d3a7b37acf23ab'
        for case in ('generator', 'dependency', 'both'):
            with self.subTest(case=case), self.copy_union(case) as root:
                manifest = copy.deepcopy(self.manifest)
                if case in ('generator', 'both'):
                    manifest['generator_sha256'] = historical_generator
                if case in ('dependency', 'both'):
                    manifest['dependency_sha256']['prepare_file_metadata.py'] = historical_evidence
                self.reseal(root, manifest)
                with self.assertRaisesRegex(ValueError, 'Unreviewed union producer or scope'):
                    m.validate_snapshot(root / m.TSV)
                self.assertEqual((root / m.TSV).read_bytes(), (self.output / m.TSV).read_bytes())
                self.assertEqual(json.loads((root / m.MANIFEST).read_bytes()), manifest)

    def test_resealed_changed_raw_response_fails_the_real_generic_validator(self):
        with self.copy_union('raw') as root:
            manifest = copy.deepcopy(self.manifest)
            name = self.fixture['raw_response_name']; archived = 'addition.' + name
            raw = m.evidence.decode((root / archived).read_bytes())
            raw['query']['languageinfo']['fr']['name'] = 'Changed synthetic fixture name'
            changed = m.evidence.encoded(raw); (root / archived).write_bytes(changed)
            identity = m.identity(changed)
            manifest['children']['addition']['files'][name] = identity
            manifest['artifacts'][archived] = identity
            # Re-seal the outer archive, keeping the child's accepted receipt and
            # manifest unchanged. Actual child verification must find the mismatch.
            self.reseal(root, manifest)
            with self.assertRaisesRegex(ValueError, 'Capture evidence inventory differs'):
                m.validate_snapshot(root / m.TSV)


if __name__ == '__main__':
    unittest.main()
