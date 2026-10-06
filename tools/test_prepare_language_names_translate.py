"""Hermetic finite Translate profile regressions; no network or native work."""
import argparse
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.parse

import prepare_language_names_generic as generic
import prepare_language_names_translate as names

TABLES = {'en': {'en': 'English', 'fr': 'French'},
          'fr': {'en': 'anglais', 'fr': 'français'}}
FALLBACKS = {'en': (), 'fr': ()}


def response(display):
    ordinary = dict(TABLES[display])
    rows = {key: {'code': key, 'name': value, 'dir': 'ltr', 'fallbacks': []}
            for key, value in ordinary.items()}
    rows['qqq'] = {'code': 'qqq', 'name': names.DOCUMENTATION_NAMES[display],
                   'dir': 'ltr', 'fallbacks': ['en']}
    return {'query': {'general': {'wikiid': 'frwiktionary', 'lang': 'fr',
                                  'git-hash': names.CORE},
                     'languageinfo': rows,
                     'languages': [{'code': k, 'name': v} for k, v in sorted(ordinary.items())]}}


class TranslateNamesTest(unittest.TestCase):
    def config(self):
        return {'wiki': 'frwiktionary', 'date': '20261001', 'content_language': 'fr',
                'languages': ['en', 'fr'], 'core': names.CORE}

    def batches(self):
        return [(generic.request_query(d, i == 0, {}), response(d))
                for i, d in enumerate(['en', 'fr'])]

    def test_exact_hook_changes_all_and_single_only(self):
        profiles, directions = names.reconstruct(self.config(), self.batches(), {}, TABLES)
        for display in ['en', 'fr']:
            self.assertEqual(profiles[display]['all']['qqq'], names.DOCUMENTATION_NAMES[display])
            self.assertEqual(profiles[display]['single']['qqq'], names.DOCUMENTATION_NAMES[display])
            self.assertNotIn('qqq', profiles[display]['mw'])
        self.assertEqual(directions['qqq'], 'ltr')

    def test_other_unknown_api_key_still_fails(self):
        batches = self.batches()
        batches[0][1]['query']['languageinfo']['unknown'] = {
            'code': 'unknown', 'name': 'Not reviewed', 'dir': 'ltr', 'fallbacks': []}
        with self.assertRaisesRegex(ValueError, 'universe'):
            names.reconstruct(self.config(), batches, {}, TABLES)

    def test_missing_or_changed_qqq_is_not_fabricated(self):
        for mutation in [lambda rows: rows.pop('qqq'),
                         lambda rows: rows['qqq'].update(name='Changed label')]:
            batches = self.batches()
            mutation(batches[0][1]['query']['languageinfo'])
            with self.assertRaisesRegex(ValueError, 'Missing or changed'):
                names.reconstruct(self.config(), batches, {}, TABLES)

    def test_qqq_cannot_enter_defined_or_alias_maps(self):
        raw = {**TABLES['en'], 'qqq': names.DOCUMENTATION_NAMES['en']}
        with self.assertRaisesRegex(ValueError, 'outside MW'):
            names.finish_profile(raw, raw, {}, TABLES, 'en', FALLBACKS)
        with self.assertRaisesRegex(ValueError, 'outside MW'):
            names.finish_profile(raw, TABLES['en'], {'qqq': 'en'}, TABLES, 'en', FALLBACKS)

    def test_scope_is_fixed_to_reviewed_french_profile(self):
        for changes in [{'wiki': 'enwiktionary'}, {'content_language': 'en'},
                        {'languages': ['en']}, {'languages': ['en', 'fr', 'de']},
                        {'core': generic.CORE}, {'extra_direction_codes': ['rmq']}]:
            config = {**self.config(), **changes}
            with self.assertRaisesRegex(ValueError, 'Unsupported Translate'):
                names.reconstruct(config, self.batches(), {}, TABLES)

    def test_shared_generic_instance_remains_strict(self):
        self.assertEqual(generic.SCHEMA, 'wikidict.language-names-capture.v2')
        self.assertIsNot(generic, names._base)
        self.assertIsNot(generic.finish_profile, names._base.finish_profile)
        with self.assertRaisesRegex(ValueError, 'universe'):
            generic.reconstruct(self.config(), self.batches(), {}, TABLES)

    def test_dependency_mutation_is_rejected(self):
        original = names.evidence.small
        def changed(path, *args):
            if Path(path).name == 'prepare_language_names_generic.py':
                return b'changed producer'
            return original(path, *args)
        with patch.object(names.evidence, 'small', side_effect=changed):
            with self.assertRaisesRegex(ValueError, 'dependency changed'):
                names.producer()

    def test_source_proof_hashes_are_mandatory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(names, '_original_primary', return_value=({}, {}, TABLES)):
                with self.assertRaises((ValueError, OSError)):
                    names.primary_contract(root)
                first = next(iter(names.TRANSLATE_SOURCE_PINS))
                (root / first).write_bytes(b'{}')
                with self.assertRaisesRegex(ValueError, 'Unreviewed Translate'):
                    names.primary_contract(root)

    def test_capture_replay_and_coherently_rehashed_output_tamper(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            namespace = root / 'namespace-registry.tsv'
            namespace.write_text('# wikidict-namespace-registry-v1\n# wiki\tfrwiktionary\n'
                                 '# dump-date\t20261001\n# content-language\tfr\n')
            args = argparse.Namespace(wiki='frwiktionary', date='20261001',
                namespace_registry=namespace, primary_sources=root, output=root/'capture',
                languages=['en', 'fr'], delay=0, wall_seconds=60, core=names.CORE,
                extra_direction_codes=[])
            calls = []
            def transport(url, timeout):
                query = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
                calls.append(query)
                return 200, {}, json.dumps(response(query['uselang'][0])).encode()
            with patch.object(names._base, 'primary_contract',
                              return_value=({'fixture': b'pinned fixture'}, {}, TABLES)):
                manifest = names.capture(args, transport=transport, sleep=lambda _: None)
                self.assertEqual(len(calls), 2)
                self.assertEqual(manifest['schema'], names.SCHEMA)
                self.assertEqual(names.verify(args.output), manifest)
                self.assertEqual(names.capture_artifacts(args.output/'language-names.tsv', manifest),
                                 names.capture_artifacts(args.output/'language-names.tsv'))
                path = args.output/'language-names.tsv'
                raw = path.read_bytes().replace(b'Message documentation', b'Changed documentation')
                path.write_bytes(raw)
                manifest['output_sha256'] = names.evidence.digest(raw)
                manifest['output_bytes'] = len(raw)
                manifest['artifacts'] = names._base.payload(args.output)
                mp = args.output/'language-names.manifest.json'
                mp.write_bytes(names.evidence.encoded(manifest))
                (args.output/names.COMPLETE).write_bytes(names.evidence.encoded({
                    'schema': names.SCHEMA, 'manifest_sha256': names.evidence.digest(mp.read_bytes())}))
                with self.assertRaisesRegex(ValueError, 'Rendered rows differ'):
                    names.verify(args.output)

    def test_builder_dispatch_preserves_generic_and_selects_translate(self):
        import build_wiktionaries as builder
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root/'language-names.tsv'
            manifest = root/'language-names.manifest.json'
            manifest.write_text(json.dumps({'schema': names.SCHEMA}))
            self.assertIs(builder.auxiliary_capture_helper('language-names', path), names)
            manifest.write_text(json.dumps({'schema': generic.SCHEMA}))
            self.assertIs(builder.auxiliary_capture_helper('language-names', path), generic)


if __name__ == '__main__':
    unittest.main()
