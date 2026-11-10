"""Controlled staging fixtures only; these do not attest native language semantics."""
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import build_wiktionaries as b
import page_language_snapshot as p


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def encode(value):
    return (json.dumps(value, sort_keys=True) + '\n').encode()


def fixture(root, with_prefix=True):
    root.mkdir(parents=True, exist_ok=True)
    ns = root.parent / 'namespace-registry.tsv'
    ns.write_bytes(b'# wikidict-namespace-registry-v1\n# wiki\ttestwiktionary\n# dump-date\t20261001\n')
    response = encode({'query': {'pages': [{'pageid': 10}, {'pageid': 20}]}})
    (root / p.RAW).write_bytes(response)
    parts = [b'controlled prefix for page ten', b'controlled prefix for page twenty']
    records = []
    offset = 0
    for row, page_id in enumerate((10, 20)):
        prefix = None
        if with_prefix:
            prefix = {'offset': offset, 'slice_bytes': len(parts[row]), 'sha256': digest(parts[row]),
                      'observed_utc': '2026-11-09T05:34:38Z'}
            offset += len(parts[row])
        records.append({'page': {'id': page_id, 'revision': page_id + 100, 'namespace': 0,
                                 'title': 'controlled-' + str(page_id), 'model': 'wikitext',
                                 'raw_sha256': '1' * 64, 'expanded_sha256': '2' * 64},
                        'response_index': 0, 'response_page_index': row, 'prefix': prefix})
    if with_prefix:
        (root / p.HTML).write_bytes(b''.join(parts))
    index = {'schema': 'wikidict.page-language-index.v1', 'wiki': 'testwiktionary',
             'core_revision': 'a' * 40, 'namespace_registry_sha256': digest(ns.read_bytes()),
             'historical_page_language_proven': False, 'source_profile': {'controlled_test_only': True},
             'responses': [{'offset': 0, 'bytes': len(response), 'sha256': digest(response),
                            'observed_utc': '2026-11-09T05:20:03Z'}], 'records': records}
    rewrite(root, index)
    return root / p.SNAPSHOT, ns


def rewrite(root, index):
    main = encode(index)
    (root / p.SNAPSHOT).write_bytes(main)
    artifacts = {}
    for name in (p.SNAPSHOT, p.RAW, p.HTML):
        if (root / name).exists():
            raw = (root / name).read_bytes()
            artifacts[name] = {'bytes': len(raw), 'sha256': digest(raw)}
    manifest = {'schema': 'wikidict.page-language-capture.v1', 'wiki': index['wiki'], 'date': '20261001',
                'namespace_registry_sha256': index['namespace_registry_sha256'],
                'output_sha256': digest(main), 'output_bytes': len(main), 'record_count': len(index['records']),
                'artifacts': artifacts}
    (root / p.MANIFEST).write_bytes(encode(manifest))


class PageLanguageStagingTests(unittest.TestCase):
    def test_actual_ru_ordinary_metadata_can_omit_capture_digest(self):
        data = Path(__file__).with_name('testdata') / 'ru-page-language201'
        original = json.loads((data / p.SNAPSHOT).read_text())
        raw = (data / 'response.raw.json').read_bytes()
        html = (data / 'response.prefix.html').read_bytes()
        self.assertEqual('92dfe1570fe613dbc276f3f3a4559f7b9626422d217ec901415eb415f472797f', digest(raw))
        self.assertEqual('99fff60ce2af26ed1d12e4366480cc70dff895da05fe34c2df229549795f62e3', digest(html))
        self.assertEqual([3726], [row['page']['id'] for row in original['records']])
        for explicit_null in (False, True):
            with self.subTest(explicit_null=explicit_null), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp) / 'page-language'
                root.mkdir()
                index = json.loads(json.dumps(original))
                page = index['records'][0]['page']
                if explicit_null:
                    page['expanded_sha256'] = None
                else:
                    del page['expanded_sha256']
                (root / p.RAW).write_bytes(raw)
                (root / p.HTML).write_bytes(html)
                rewrite(root, index)
                manifest, inventory = p.validated_capture(root / p.SNAPSHOT, 'ruwiktionary', '20261001')
                self.assertEqual(1, manifest['record_count'])
                self.assertEqual({p.SNAPSHOT, p.RAW, p.HTML, p.MANIFEST}, set(inventory))
                hashes = b.verified_auxiliary_hashes({'page-language': root / p.SNAPSHOT}, 'ruwiktionary', '20261001')
                manifests, artifacts = b.auxiliary_capture_identities({'page-language': root / p.SNAPSHOT})
                pinned = b.pinned_auxiliary_snapshots({'page-language': root / p.SNAPSHOT}, hashes, Path(tmp) / 'pinned', manifests, artifacts)
                self.assertEqual((root / p.SNAPSHOT).read_bytes(), pinned['page-language'].read_bytes())
                self.assertEqual(raw, pinned['page-language'].with_name(p.RAW).read_bytes())
                self.assertEqual(html, pinned['page-language'].with_name(p.HTML).read_bytes())
        self.assertIsInstance(original['records'][0]['page']['expanded_sha256'], str)

    def test_optional_capture_digest_never_weakens_required_identity_or_range_checks(self):
        for field, value in (('expanded_sha256', 1), ('expanded_sha256', False),
                             ('expanded_sha256', ''), ('expanded_sha256', 'bad'),
                             ('raw_sha256', None), ('revision', 0), ('id', 0)):
            with self.subTest(field=field, value=value), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp) / 'page-language'
                main, _ = fixture(root)
                index = json.loads(main.read_text())
                del index['records'][0]['page']['expanded_sha256']
                index['records'][0]['page'][field] = value
                rewrite(root, index)
                with self.assertRaises(ValueError):
                    p.validated_capture(main)
        for missing in ('raw_sha256', 'id', 'revision', 'namespace', 'title', 'model'):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp) / 'page-language'
                main, _ = fixture(root)
                index = json.loads(main.read_text())
                del index['records'][0]['page']['expanded_sha256']
                del index['records'][0]['page'][missing]
                rewrite(root, index)
                with self.assertRaises(ValueError):
                    p.validated_capture(main)

    def test_discovery_absent_and_complete_generation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.assertEqual({}, b.discover_auxiliary_generation(root, 'page-language', ('page-language',), 'testwiktionary', '20261001'))
            main, _ = fixture(root / 'page-language')
            self.assertEqual({'page-language': main}, b.discover_auxiliary_generation(root, 'page-language', ('page-language',), 'testwiktionary', '20261001'))
            self.assertEqual(['--page-language-snapshot', str(main)], b.auxiliary_snapshot_args({'page-language': main}))

    def test_normal_resolver_routes_explicit_page_language_with_selected_namespace(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            main, ns = fixture(root / 'capture' / 'page-language')
            downloads = root / 'downloads'
            target = downloads / 'testwiktionary' / '20261001'
            target.mkdir(parents=True)
            (target / 'namespace-registry.tsv').write_bytes(ns.read_bytes())
            language = target / 'language-registry.tsv'
            language.write_bytes(b'controlled language registry\n')
            manifest = {'language_registries': [{'wiki': 'testwiktionary', 'date': '20261001',
                         'name': language.name, 'size': language.stat().st_size, 'sha256': digest(language.read_bytes())}]}
            groups = {('testwiktionary', '20261001'): []}
            result = b.resolve_edition_snapshot_options(manifest, groups, downloads, {'page-language': main}, workspace=root)
            self.assertEqual(main, result[('testwiktionary', '20261001')]['auxiliary_snapshots']['page-language'])
            absent = b.resolve_edition_snapshot_options(manifest, groups, downloads, workspace=root)
            self.assertNotIn('page-language', absent[('testwiktionary', '20261001')]['auxiliary_snapshots'])

    def test_pinning_copies_complete_payload_and_manifest_into_isolated_folder(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            main, ns = fixture(root / 'source' / 'page-language')
            snapshots = {'page-language': main, 'namespace-registry': ns}
            hashes = b.verified_auxiliary_hashes(snapshots, 'testwiktionary', '20261001')
            manifests, artifacts = b.auxiliary_capture_identities(snapshots)
            destination = root / 'pinned'
            destination.mkdir()
            marker = destination / '.complete.json'
            marker.write_bytes(b'unchanged staged checkpoint')
            actual = b.pinned_auxiliary_snapshots(snapshots, hashes, destination, manifests, artifacts)
            self.assertEqual(destination / 'page-language' / p.SNAPSHOT, actual['page-language'])
            for name in (p.SNAPSHOT, p.RAW, p.HTML, p.MANIFEST):
                self.assertEqual((main.parent / name).read_bytes(), (actual['page-language'].parent / name).read_bytes())
            self.assertEqual(b'unchanged staged checkpoint', marker.read_bytes())
            self.assertEqual(b.validated_auxiliary_capture('page-language', main), b.validated_auxiliary_capture('page-language', actual['page-language']))

    def test_optional_prefix_absence_and_unregistered_presence_are_distinct(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            main, _ = fixture(root / 'page-language', False)
            record, inventory = p.validated_capture(main)
            self.assertEqual({p.SNAPSHOT, p.RAW, p.MANIFEST}, set(inventory))
            self.assertEqual(2, record['record_count'])
            (main.parent / p.HTML).write_bytes(b'unregistered')
            with self.assertRaisesRegex(ValueError, 'unregistered prefix'):
                p.validate_snapshot(main)

    def test_partial_generation_and_dangling_optional_symlink_fail(self):
        for missing in (p.SNAPSHOT, p.RAW, p.HTML, p.MANIFEST):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                main, _ = fixture(root / 'page-language')
                (main.parent / missing).unlink()
                with self.assertRaises((ValueError, OSError)):
                    b.discover_auxiliary_generation(root, 'page-language', ('page-language',), 'testwiktionary', '20261001')
        with tempfile.TemporaryDirectory() as tmp:
            main, _ = fixture(Path(tmp) / 'page-language', False)
            (main.parent / p.HTML).symlink_to('absent')
            with self.assertRaises(ValueError):
                p.validate_snapshot(main)

    def test_selected_namespace_wiki_and_date_mismatch_refuse(self):
        with tempfile.TemporaryDirectory() as tmp:
            main, ns = fixture(Path(tmp) / 'page-language')
            for wiki, date in (('otherwiktionary', '20261001'), ('testwiktionary', '20260901')):
                with self.subTest(wiki=wiki, date=date), self.assertRaises(ValueError):
                    p.validate_snapshot(main, wiki, date)
            b.validate_captured_snapshot('page-language', main, {'wiki': 'testwiktionary', 'date': '20261001'}, [], ns.parent)
            ns.write_bytes(ns.read_bytes() + b'changed\n')
            with self.assertRaisesRegex(ValueError, 'namespace'):
                b.verified_auxiliary_hashes({'page-language': main, 'namespace-registry': ns})
            with self.assertRaisesRegex(ValueError, 'namespace'):
                b.validate_captured_snapshot('page-language', main, {'wiki': 'testwiktionary', 'date': '20261001'}, [], ns.parent)

    def test_changed_response_or_manifest_is_rejected_before_copy(self):
        for name in (p.RAW, p.HTML, p.MANIFEST):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                main, _ = fixture(root / 'source')
                snapshots = {'page-language': main}
                hashes = b.verified_auxiliary_hashes(snapshots)
                manifests, artifacts = b.auxiliary_capture_identities(snapshots)
                file = main.parent / name
                file.write_bytes(file.read_bytes() + b' ')
                with self.assertRaises(ValueError):
                    b.pinned_auxiliary_snapshots(snapshots, hashes, root / 'destination', manifests, artifacts)
                self.assertFalse((root / 'destination').exists())

    def test_changed_observation_changes_normal_build_input_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            main, _ = fixture(root / 'source')
            compiler = root / 'controlled-compiler'; compiler.write_bytes(b'controlled identity only')
            snapshots = {'page-language': main}
            with patch.object(b, 'source_fingerprint', return_value='controlled-source'), patch.object(b.shutil, 'which', return_value=str(compiler)):
                first = b.build_input_identity([], 'controlled-compiler', None, None, None, snapshots, validate_auxiliary=True)
                index = json.loads(main.read_text())
                index['responses'][0]['observed_utc'] = '2026-11-09T05:21:03Z'
                rewrite(main.parent, index)
                second = b.build_input_identity([], 'controlled-compiler', None, None, None, snapshots, validate_auxiliary=True)
            self.assertNotEqual(first['auxiliary_snapshot_sha256'], second['auxiliary_snapshot_sha256'])
            self.assertNotEqual(first['auxiliary_capture_artifact_sha256'], second['auxiliary_capture_artifact_sha256'])
            with self.assertRaises(ValueError):
                b.require_auxiliary_capture_identity(snapshots, first)

    def test_mutation_during_copy_cannot_publish_a_valid_pinned_capture(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            main, _ = fixture(root / 'source')
            snapshots = {'page-language': main}
            hashes = b.verified_auxiliary_hashes(snapshots)
            original_copy = b.copy_verified_snapshot
            def changing_copy(source, destination, expected):
                if source.name == p.RAW:
                    source.write_bytes(source.read_bytes() + b'changed during copy')
                return original_copy(source, destination, expected)
            with patch.object(b, 'copy_verified_snapshot', side_effect=changing_copy):
                with self.assertRaisesRegex(ValueError, 'changed while copying'):
                    b.pinned_auxiliary_snapshots(snapshots, hashes, root / 'destination')
            with self.assertRaises((ValueError, OSError)):
                p.validate_snapshot(root / 'destination' / 'page-language' / p.SNAPSHOT)

    def test_rehashed_ranges_and_record_rows_still_require_complete_unique_coverage(self):
        mutations = (
            lambda x: x['responses'][0].update(offset=1),
            lambda x: x['responses'][0].update(bytes=x['responses'][0]['bytes'] + 1),
            lambda x: x['records'].pop(),
            lambda x: x['records'][1]['page'].update(id=10),
            lambda x: x['records'][1].update(response_page_index=0),
            lambda x: x['records'][1].update(response_index=1),
            lambda x: x['records'][1]['prefix'].update(offset=0),
            lambda x: x['records'][0]['prefix'].update(slice_bytes=0),
            lambda x: x['records'][0].update(response_index=True),
            lambda x: x.update(historical_page_language_proven=True),
        )
        for number, mutate in enumerate(mutations):
            with self.subTest(number=number), tempfile.TemporaryDirectory() as tmp:
                main, _ = fixture(Path(tmp) / 'page-language')
                index = json.loads(main.read_text()); mutate(index); rewrite(main.parent, index)
                with self.assertRaises(ValueError):
                    p.validate_snapshot(main)

    def test_rehashed_trailing_stores_or_unused_prefix_are_rejected(self):
        for mode in ('raw-trailing', 'html-trailing', 'unused-prefix'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                main, _ = fixture(Path(tmp) / 'page-language')
                index = json.loads(main.read_text())
                if mode == 'unused-prefix':
                    index['records'][1]['prefix'] = None
                else:
                    file = main.parent / (p.RAW if mode == 'raw-trailing' else p.HTML)
                    file.write_bytes(file.read_bytes() + b'x')
                rewrite(main.parent, index)
                with self.assertRaises(ValueError):
                    p.validate_snapshot(main)

    def test_duplicate_json_unsafe_artifacts_and_nonregular_files_refuse(self):
        with tempfile.TemporaryDirectory() as tmp:
            main, _ = fixture(Path(tmp) / 'page-language')
            manifest = main.with_name(p.MANIFEST)
            raw = manifest.read_bytes()
            manifest.write_bytes(b'{"schema":"duplicate",' + raw[1:])
            with self.assertRaisesRegex(ValueError, 'duplicate JSON'):
                p.validate_snapshot(main)
            manifest.write_bytes(raw)
            value = json.loads(raw); value['artifacts']['../escape'] = {'bytes': 1, 'sha256': '0' * 64}
            manifest.write_bytes(encode(value))
            with self.assertRaises(ValueError):
                p.validate_snapshot(main)
            manifest.write_bytes(raw)
            store = main.with_name(p.RAW); store.unlink(); os.mkfifo(store)
            with self.assertRaisesRegex(ValueError, 'bounded regular'):
                p.validate_snapshot(main)

    def test_declared_limits_are_checked_before_unbounded_payload_reads(self):
        with tempfile.TemporaryDirectory() as tmp:
            main, _ = fixture(Path(tmp) / 'page-language')
            manifest = main.with_name(p.MANIFEST)
            value = json.loads(manifest.read_text()); value['artifacts'][p.RAW]['bytes'] = p.MAX_STORE + 1
            manifest.write_bytes(encode(value))
            with self.assertRaisesRegex(ValueError, 'payload descriptor'):
                p.validate_snapshot(main)
            main, _ = fixture(main.parent)
            with patch.object(p, 'MAX_RECORDS', 1), self.assertRaises(ValueError):
                p.validate_snapshot(main)
