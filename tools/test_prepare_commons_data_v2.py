import argparse
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from urllib.parse import parse_qs, urlsplit

import build_wiktionaries as build
import prepare_commons_data as legacy
import prepare_commons_data_v2 as helper
from test_prepare_commons_data import NAMESPACE, response


class CommonsCaptureV2Tests(unittest.TestCase):
    def setUp(self):
        parent = helper.evidence.REPO / '.tmp' / 'commons-capture-v2-hermetic'
        parent.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=parent)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        namespace = self.root / 'namespace.tsv'
        namespace.write_bytes(NAMESPACE)
        self.args = argparse.Namespace(
            wiki='arwiktionary', date='20261001', title=self.titles(17),
            namespace_registry=namespace, output=self.root / 'capture',
            delay=0, wall_seconds=30)
        self.calls = []

    @staticmethod
    def titles(count):
        return [f'Unicode data/names/{index:03X}.tab' for index in range(count)]

    def transport(self, url, timeout):
        self.assertGreater(timeout, 0)
        title = parse_qs(urlsplit(url).query)['titles'][0]
        self.assertIn(title.removeprefix('Data:'), self.args.title)
        value = response()
        value['query']['pages'][0]['title'] = title
        self.calls.append(title)
        return 200, {'Content-Type': 'application/json'}, json.dumps(value).encode()

    def capture(self, count=17, producer=helper):
        self.args.title = self.titles(count)
        return producer.capture(self.args, self.transport, sleep=lambda _: None)

    def rewrite_manifest(self, manifest):
        path = self.args.output / 'commons-data.manifest.json'
        raw = helper.evidence.encoded(manifest)
        path.write_bytes(raw)
        (self.args.output / helper.COMPLETE).write_bytes(helper.evidence.encoded({
            'schema': helper.SCHEMA, 'manifest_sha256': helper.evidence.digest(raw)}))

    def rewrite_index(self, manifest, index):
        raw = helper.evidence.encoded(index)
        (self.args.output / helper.INDEX).write_bytes(raw)
        manifest['evidence_index'] = {
            'path': helper.INDEX, 'bytes': len(raw), 'sha256': helper.evidence.digest(raw)}
        self.rewrite_manifest(manifest)

    def test_128_maximum_length_titles_and_four_attempt_receipts_replay(self):
        self.args.title = [f'{index:03d}/' + 'x' * 504 + '.tab' for index in range(128)]
        self.assertTrue(all(len(title.encode()) == 512 for title in self.args.title))
        attempts = {}
        def retry_transport(url, timeout):
            title = parse_qs(urlsplit(url).query)['titles'][0]
            attempts[title] = attempts.get(title, 0) + 1
            if attempts[title] < 4:
                return 503, {}, b'{"error":{"code":"readonly"}}'
            return self.transport(url, timeout)
        manifest = helper.capture(self.args, retry_transport, sleep=lambda _: None)
        self.assertEqual(512, sum(attempts.values()))
        self.assertEqual(128, len(self.calls))
        index = helper.read_index(self.args.output, manifest)
        self.assertEqual(1155, len(index['artifacts']))
        self.assertGreater((self.args.output / 'commons-requested.json').stat().st_size, 64 * 1024)
        self.assertLessEqual((self.args.output / 'commons-requested.json').stat().st_size,
                             helper.MAX_CONFIGURATION)
        self.assertLessEqual((self.args.output / helper.INDEX).stat().st_size, helper.MAX_INDEX)
        self.assertLessEqual((self.args.output / 'commons-data.manifest.json').stat().st_size,
                             helper.MAX_MANIFEST)
        self.assertEqual(manifest, helper.verify(self.args.output))
        copied = self.root / 'copied'
        copied.mkdir()
        for name in helper.capture_artifacts(self.args.output / 'commons-data.tsv', manifest):
            (copied / name).write_bytes((self.args.output / name).read_bytes())
        self.assertEqual(manifest, helper.verify(copied))

    def test_index_identity_and_coherently_resealed_revision_drift_fail(self):
        manifest = self.capture()
        index = helper.read_index(self.args.output, manifest)
        original = (self.args.output / helper.INDEX).read_bytes()
        (self.args.output / helper.INDEX).write_bytes(original + b' ')
        with self.assertRaisesRegex(ValueError, 'evidence index identity mismatch'):
            helper.verify(self.args.output)
        index['records'][0]['revision_id'] += 1
        self.rewrite_index(manifest, index)
        with self.assertRaisesRegex(ValueError, 'Commons revision proof mismatch'):
            helper.verify(self.args.output)

    def test_index_schema_and_finite_index_configuration_bounds(self):
        manifest = self.capture()
        index = helper.read_index(self.args.output, manifest)
        index['schema'] = 'wikidict.commons-data-evidence.v999'
        self.rewrite_index(manifest, index)
        with self.assertRaisesRegex(ValueError, 'Invalid Commons evidence index'):
            helper.verify(self.args.output)
        index['schema'] = helper.INDEX_SCHEMA
        self.rewrite_index(manifest, index)
        manifest['evidence_index']['bytes'] = helper.MAX_INDEX + 1
        self.rewrite_manifest(manifest)
        with self.assertRaisesRegex(ValueError, 'Invalid Commons evidence index reference'):
            helper.verify(self.args.output)
        self.rewrite_index(manifest, index)
        configuration = self.args.output / 'commons-requested.json'
        configuration.write_bytes(configuration.read_bytes() + b' ' * helper.MAX_CONFIGURATION)
        index['artifacts'] = helper.payload_inventory(self.args.output)
        self.rewrite_index(manifest, index)
        with self.assertRaises(ValueError):
            helper.verify(self.args.output)

    def test_seventeen_thirtytwo_and_128_actual_shaped_titles_replay_through_builder(self):
        for count in (17, 32, 128):
            with self.subTest(count=count):
                self.args.output = self.root / f'capture-{count}'
                self.calls = []
                manifest = self.capture(count)
                path = self.args.output / 'commons-data.tsv'
                self.assertEqual(helper.SCHEMA, manifest['schema'])
                self.assertEqual(count, manifest['rows'])
                self.assertEqual(count, len(self.calls))
                self.assertEqual(count, len(set(self.calls)))
                index = helper.read_index(self.args.output, manifest)
                self.assertEqual(count, len(index['records']))
                self.assertLessEqual((self.args.output / 'commons-data.manifest.json').stat().st_size,
                                     helper.MAX_MANIFEST)
                self.assertLessEqual((self.args.output / helper.INDEX).stat().st_size,
                                     helper.MAX_INDEX)
                self.assertEqual('CC0-1.0', index['records'][0]['license'])
                self.assertEqual(2, len(index['records'][0]['fields']))
                self.assertEqual(manifest, helper.verify(self.args.output))
                self.assertEqual(helper, build.auxiliary_capture_helper('commons-data', path))
                snapshots = {'commons-data': path,
                             'namespace-registry': self.args.namespace_registry}
                self.assertEqual(manifest['output_sha256'],
                                 build.verified_auxiliary_hashes(
                                     snapshots, 'arwiktionary', '20261001')['commons-data'])
                manifests, artifacts = build.auxiliary_capture_identities(
                    snapshots, 'arwiktionary', '20261001')
                self.assertIn('commons-data', manifests)
                self.assertIn('commons-data', artifacts)
                capture_artifacts = helper.capture_artifacts(path, manifest)
                self.assertIn(helper.INDEX, capture_artifacts)
                self.assertEqual(manifest['evidence_index']['sha256'], capture_artifacts[helper.INDEX])
                self.assertEqual('# wikidict-commons-data-v1', path.read_text().splitlines()[0])
                self.assertFalse(manifest['corpus_query_closure_proven'])
                self.assertEqual('current-api-observation', manifest['temporal_scope'])
                self.assertEqual(
                    hashlib.sha256(Path(legacy.__file__).read_bytes()).hexdigest(),
                    manifest['dependency_sha256']['tools/prepare_commons_data.py'])
                with self.assertRaisesRegex(ValueError, 'Unsupported Commons manifest'):
                    legacy.verify(self.args.output)
        self.args.namespace_registry.write_bytes(NAMESPACE + b'# changed\n')
        with self.assertRaisesRegex(ValueError, 'different namespace registry'):
            build.verified_auxiliary_hashes(
                {'commons-data': self.args.output / 'commons-data.tsv',
                 'namespace-registry': self.args.namespace_registry},
                'arwiktionary', '20261001')

    def test_129_titles_rejected_before_network_or_output(self):
        with self.assertRaisesRegex(ValueError, 'bounded Commons title inventory'):
            self.capture(129)
        self.assertEqual([], self.calls)
        self.assertFalse(self.args.output.exists())

    def test_verifier_enforces_title_limit_after_inventory_and_marker_rehash(self):
        manifest = self.capture(17)
        config_path = self.args.output / 'commons-requested.json'
        configuration = json.loads(config_path.read_text())
        configuration['titles'] = self.titles(129)
        config_path.write_bytes(helper.evidence.encoded(configuration))
        index = helper.read_index(self.args.output, manifest)
        index['configuration'] = configuration
        index['requests'].extend(
            {'request': f'commons-request-{index:06d}.request.json',
             'accepted_receipt': f'commons-request-{index:06d}-01.receipt.json'}
            for index in range(18, 130))
        index['artifacts'] = helper.payload_inventory(self.args.output)
        self.rewrite_index(manifest, index)
        with self.assertRaisesRegex(ValueError, 'Commons request inventory mismatch'):
            helper.verify(self.args.output)

    def test_v1_keeps_its_own_producer_dispatch_and_sixteen_title_limit(self):
        manifest = self.capture(16, legacy)
        path = self.args.output / 'commons-data.tsv'
        self.assertEqual(legacy.SCHEMA, manifest['schema'])
        self.assertEqual(legacy, build.auxiliary_capture_helper('commons-data', path))
        self.assertEqual(manifest, legacy.verify(self.args.output))
        self.assertEqual(manifest['output_sha256'], build.verified_auxiliary_hashes(
            {'commons-data': path, 'namespace-registry': self.args.namespace_registry},
            'arwiktionary', '20261001')['commons-data'])
        self.args.output = self.root / 'legacy-over-limit'
        self.calls = []
        with self.assertRaisesRegex(ValueError, 'bounded Commons title inventory'):
            self.capture(17, legacy)
        self.assertEqual([], self.calls)
        self.assertFalse(self.args.output.exists())

    def test_changed_tsv_rejected_even_after_manifest_and_artifacts_rehash(self):
        manifest = self.capture()
        path = self.args.output / 'commons-data.tsv'
        path.write_bytes(path.read_bytes().replace(b'40400000', b'40400001'))
        index = helper.read_index(self.args.output, manifest)
        index['artifacts'] = helper.payload_inventory(self.args.output)
        manifest['output_sha256'] = helper.evidence.digest(path.read_bytes())
        self.rewrite_index(manifest, index)
        with self.assertRaisesRegex(ValueError, 'Commons TSV replay mismatch'):
            helper.verify(self.args.output)

    def test_v2_cannot_claim_another_generator_or_legacy_dependency(self):
        original = self.capture()
        for field in ('generator_sha256', 'legacy_dependency'):
            manifest = copy.deepcopy(original)
            if field == 'generator_sha256':
                manifest[field] = '0' * 64
            else:
                manifest['dependency_sha256']['tools/prepare_commons_data.py'] = '0' * 64
            self.rewrite_manifest(manifest)
            with self.subTest(field=field), self.assertRaisesRegex(
                    ValueError, 'Commons collector dependencies changed'):
                helper.verify(self.args.output)

    def test_unknown_or_null_explicit_schema_still_fails_builder_validation(self):
        original = self.capture()
        path = self.args.output / 'commons-data.tsv'
        for schema in ('wikidict.commons-data-capture.v999', None):
            manifest = dict(original, schema=schema)
            self.rewrite_manifest(manifest)
            with self.subTest(schema=schema):
                with self.assertRaisesRegex(ValueError, 'Unsupported Commons manifest'):
                    build.verified_auxiliary_hashes(
                        {'commons-data': path}, 'arwiktionary', '20261001')
                with self.assertRaisesRegex(ValueError, 'Unsupported Commons manifest'):
                    build.auxiliary_capture_identities(
                        {'commons-data': path}, 'arwiktionary', '20261001')


if __name__ == '__main__':
    unittest.main()
