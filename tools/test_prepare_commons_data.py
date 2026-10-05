import argparse
import copy
import json
from pathlib import Path
import tempfile
import unittest

import prepare_commons_data as helper

TITLE = 'CS1/Identifier limits.tab'
NAMESPACE = b'# wikidict-namespace-registry-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n'
SOURCE = {'license': 'CC0-1.0', 'description': {'en': 'Limits', 'ar': 'حدود'},
          'schema': {'fields': [{'name': 'identifier', 'type': 'string', 'title': {'en': 'Identifier'}},
                               {'name': 'upper', 'type': 'number', 'title': {'en': 'Upper'}}]},
          'data': [['PMID', 40400000], ['OCLC', 10450000000]]}


def response():
    return {'query': {'general': {'wikiid': 'commonswiki'}, 'pages': [{
        'pageid': 123, 'ns': 486, 'title': 'Data:' + TITLE, 'revisions': [{
            'revid': 456, 'parentid': 455, 'timestamp': '2026-10-05T12:00:00Z',
            'slots': {'main': {'contentmodel': 'Tabular.JsonConfig', 'contentformat': 'application/json',
                              'content': json.dumps(SOURCE, ensure_ascii=False, indent=2)}}}]}]}}


class CommonsCaptureTests(unittest.TestCase):
    def setUp(self):
        parent = helper.evidence.REPO / '.tmp' / 'commons-capture-hermetic'
        parent.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=parent)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        namespace = self.root / 'namespace.tsv'
        namespace.write_bytes(NAMESPACE)
        self.args = argparse.Namespace(wiki='arwiktionary', date='20261001', title=[TITLE],
            namespace_registry=namespace, output=self.root / 'capture', delay=0, wall_seconds=30)

    def transport(self, value=None):
        raw = json.dumps(response() if value is None else value, ensure_ascii=False).encode()
        def get(url, timeout):
            self.assertEqual(helper.query_url(TITLE), url)
            self.assertGreater(timeout, 0)
            return 200, {'Content-Type': 'application/json'}, raw
        return get

    def capture(self):
        return helper.capture(self.args, self.transport(), sleep=lambda _: None)

    def test_capture_replays_exact_fields_license_source_and_identity(self):
        manifest = self.capture()
        self.assertEqual(1, manifest['rows'])
        self.assertEqual('CC0-1.0', manifest['records'][0]['license'])
        self.assertEqual(456, manifest['records'][0]['revision_id'])
        self.assertEqual('current-api-observation', manifest['temporal_scope'])
        self.assertFalse(manifest['corpus_query_closure_proven'])
        replay = helper.validate_snapshot(self.args.output / 'commons-data.tsv', 'arwiktionary', '20261001')
        self.assertEqual(manifest, replay)
        row = (self.args.output / 'commons-data.tsv').read_text().splitlines()[-1].split('\t')
        self.assertEqual([TITLE, 'Tabular.JsonConfig'], row[:2])
        self.assertEqual(SOURCE, json.loads(row[2]))
        with self.assertRaises(ValueError):
            helper.validate_snapshot(self.args.output / 'commons-data.tsv', 'enwiktionary', '20261001')
        self.assertIn(helper.COMPLETE, helper.capture_artifacts(self.args.output / 'commons-data.tsv', manifest))

    def test_consumer_binds_replayed_capture_and_namespace_identity(self):
        import build_wiktionaries as build
        manifest = self.capture()
        path = self.args.output / 'commons-data.tsv'
        snapshots = {'commons-data': path, 'namespace-registry': self.args.namespace_registry}
        hashes = build.verified_auxiliary_hashes(snapshots, 'arwiktionary', '20261001')
        self.assertEqual(manifest['output_sha256'], hashes['commons-data'])
        manifests, artifacts = build.auxiliary_capture_identities(snapshots, 'arwiktionary', '20261001')
        self.assertIn('commons-data', manifests)
        self.assertIn('commons-data', artifacts)
        self.args.namespace_registry.write_bytes(NAMESPACE + b'# changed\n')
        with self.assertRaisesRegex(ValueError, 'different namespace registry'):
            build.verified_auxiliary_hashes(snapshots, 'arwiktionary', '20261001')

    def test_consumer_rejects_unknown_explicit_capture_schema(self):
        import build_wiktionaries as build
        self.capture()
        path = self.args.output / 'commons-data.tsv'
        mp = path.with_name('commons-data.manifest.json')
        original = json.loads(mp.read_text())
        for schema in ['wikidict.commons-data-capture.v999', None]:
            changed = dict(original, schema=schema)
            mp.write_bytes(helper.evidence.encoded(changed))
            with self.subTest(schema=schema):
                with self.assertRaisesRegex(ValueError, 'Unsupported Commons manifest'):
                    build.verified_auxiliary_hashes({'commons-data': path}, 'arwiktionary', '20261001')
                with self.assertRaisesRegex(ValueError, 'Unsupported Commons manifest'):
                    build.auxiliary_capture_identities({'commons-data': path}, 'arwiktionary', '20261001')

    def test_capture_requires_new_directory(self):
        self.capture()
        with self.assertRaises(FileExistsError):
            self.capture()

    def test_missing_page_preserves_evidence_without_publishable_pair(self):
        missing = response()
        missing['query']['pages'][0] = {'title': 'Data:' + TITLE, 'ns': 486, 'missing': True}
        with self.assertRaises(ValueError):
            helper.capture(self.args, self.transport(missing), sleep=lambda _: None)
        self.assertTrue(list(self.args.output.glob('*.raw.json')))
        self.assertTrue((self.args.output / 'commons-failure.json').is_file())
        self.assertFalse((self.args.output / helper.COMPLETE).exists())
        self.assertFalse((self.args.output / 'commons-data.tsv').exists())

    def test_rejects_wrong_repository_model_normalization_and_hidden(self):
        variants = []
        value = response(); value['query']['general']['wikiid'] = 'enwiki'; variants.append(value)
        value = response(); value['query']['pages'][0]['revisions'][0]['slots']['main']['contentmodel'] = 'wikitext'; variants.append(value)
        value = response(); value['query']['normalized'] = [{'from': 'X', 'to': 'Y'}]; variants.append(value)
        value = response(); value['query']['pages'][0]['revisions'][0]['slots']['main']['contenthidden'] = True; variants.append(value)
        value = response(); value['continue'] = {'rvcontinue': 'x'}; variants.append(value)
        value = response(); value['warnings'] = {'main': 'warning'}; variants.append(value)
        for value in variants:
            with self.subTest(value=value), self.assertRaises(ValueError):
                helper.classify(value, TITLE)

    def test_rejects_duplicate_json_keys_nonfinite_and_row_width(self):
        for content in ['{"schema":{},"schema":{}}', '{"schema":{"fields":[{"name":"x","type":"number"}]},"data":[[NaN]]}',
                        '{"schema":{"fields":[{"name":"x","type":"number"}]},"data":[[]]}']:
            value = response(); value['query']['pages'][0]['revisions'][0]['slots']['main']['content'] = content
            with self.subTest(content=content), self.assertRaises(ValueError):
                helper.classify(value, TITLE)

    def test_tsv_tampering_fails_even_with_rehashed_manifest_inventory(self):
        self.capture()
        root = self.args.output
        path = root / 'commons-data.tsv'
        path.write_bytes(path.read_bytes().replace(b'40400000', b'40400001'))
        mp = root / 'commons-data.manifest.json'
        manifest = json.loads(mp.read_text())
        sha = helper.evidence.digest(path.read_bytes())
        manifest['artifacts']['commons-data.tsv'] = sha
        manifest['output_sha256'] = sha
        mp.write_bytes(helper.evidence.encoded(manifest))
        (root / helper.COMPLETE).write_bytes(helper.evidence.encoded({'schema': helper.SCHEMA,
            'manifest_sha256': helper.evidence.digest(mp.read_bytes())}))
        with self.assertRaisesRegex(ValueError, 'TSV replay mismatch'):
            helper.verify(root)

    def test_raw_tampering_or_extra_artifact_fails(self):
        self.capture()
        (self.args.output / 'unexpected.txt').write_text('unrecorded')
        with self.assertRaisesRegex(ValueError, 'payload inventory mismatch'):
            helper.verify(self.args.output)

    def test_retry_retains_rejected_response_and_replays_success(self):
        calls = []
        def get(url, timeout):
            calls.append(url)
            if len(calls) == 1:
                return 503, {'Retry-After': '0'}, b'{"error":{"code":"maxlag"}}'
            return self.transport()(url, timeout)
        waits = []
        manifest = helper.capture(self.args, get, sleep=waits.append)
        self.assertEqual([1], waits)
        self.assertEqual(2, len(calls))
        self.assertEqual(2, len(list(self.args.output.glob('*.raw.json'))))
        self.assertEqual(manifest, helper.verify(self.args.output))

    def test_unsafe_or_alias_title_fails_before_requests(self):
        for title in ['Data:X.tab', '../X\n.tab', 'X_map.tab', 'X.map', 'X.tab|Y.tab', ' X.tab']:
            with self.subTest(title=title), self.assertRaises(ValueError):
                helper.checked_title(title)

    def test_symlink_artifact_fails(self):
        self.capture()
        path = self.args.output / 'commons-data.tsv'
        outside = self.root / 'copy.tsv'; outside.write_bytes(path.read_bytes())
        path.unlink(); path.symlink_to(outside)
        with self.assertRaises(ValueError):
            helper.verify(self.args.output)


if __name__ == '__main__':
    unittest.main()
