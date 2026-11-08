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

    def test_historical_producer_is_strict_recorded_provenance(self):
        current = names.producer()
        self.assertEqual(set(current['dependency_sha256']), set(names.DEPENDENCY_PATHS))
        for name, path in names.DEPENDENCY_PATHS.items():
            self.assertEqual(current['dependency_sha256'][name], names.evidence.digest(names.evidence.small(path)))
        historic = copy.deepcopy(current)
        historic['generator_sha256'] = '0' * 64
        historic['dependency_sha256'] = {name: '1' * 64 for name in names.DEPENDENCY_PATHS}
        names.validate_provenance(historic)
        for value in (dict(historic, generator_sha256='BAD'), dict(historic, dependency_sha256={}),
                      dict(historic, dependency_sha256={**historic['dependency_sha256'], 'unknown.py': '2' * 64}),
                      dict(historic, dependency_sha256={**historic['dependency_sha256'], 'download_wiktionaries.py': None})):
            with self.assertRaises(ValueError): names.validate_provenance(value)

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

    def test_primary_api_preserves_implicit_defaults_and_accepts_selected_core(self):
        class ReachedPrimary(Exception):
            pass
        root = Path('/unused-primary-api-control')
        self.assertIs(names._base.primary_contract, names.primary_contract)
        with patch.object(names, '_original_primary', side_effect=ReachedPrimary) as primary:
            with self.assertRaises(ReachedPrimary): names.primary_contract(root)
            primary.assert_called_once_with(root, '')
            primary.reset_mock()
            with self.assertRaises(ReachedPrimary): names.primary_contract(root, 'source-')
            primary.assert_called_once_with(root, 'source-')
            primary.reset_mock()
            with self.assertRaises(ReachedPrimary): names.primary_contract(root, 'source-', names.CORE, None)
            primary.assert_called_once_with(root, 'source-', names.CORE, None)
            primary.reset_mock()
            with self.assertRaises(ReachedPrimary):
                names.primary_contract(root, core=names.CORE, name_source_profile=None)
            primary.assert_called_once_with(root, '', names.CORE, None)

    def test_primary_api_rejects_foreign_core_or_profile_before_source_io(self):
        cases = [dict(core=generic.CORE), dict(core=generic.CURRENT_CORE),
                 dict(core='0' * 40), dict(core=True), dict(core=None),
                 dict(core=names.CORE, name_source_profile=generic.ITALIAN_SOURCE_PROFILE),
                 dict(name_source_profile='unreviewed'), dict(name_source_profile=False)]
        with patch.object(names, '_original_primary', side_effect=AssertionError('foreign source IO')) as primary:
            for kwargs in cases:
                with self.subTest(kwargs=kwargs), self.assertRaisesRegex(ValueError, 'Unsupported Translate primary'):
                    names.primary_contract(Path('/unused-primary-authority-control'), **kwargs)
            primary.assert_not_called()

    def test_finish_api_accepts_false_and_rejects_unreviewed_locales(self):
        single = dict(TABLES['en'], qqq=names.DOCUMENTATION_NAMES['en'])
        expected = names.finish_profile(single, TABLES['en'], {}, TABLES, 'en', FALLBACKS)
        self.assertEqual(names.finish_profile(single, TABLES['en'], {}, TABLES, 'en', FALLBACKS, require_locales=False), expected)
        for value in (True, None, 0, 'unreviewed'):
            with self.subTest(value=value), patch.object(names, '_original_finish', side_effect=AssertionError('unreviewed locale IO')) as original:
                with self.assertRaisesRegex(ValueError, 'Unsupported Translate locale'):
                    names.finish_profile(single, TABLES['en'], {}, TABLES, 'en', FALLBACKS, require_locales=value)
                original.assert_not_called()

    def translate_source_fixture(self, root):
        # Only the primary generic source parser is mocked below. The Translate
        # wrapper itself reads and hashes every source, then validates its hooks.
        commit = 'cb5a4a08978a7c8a180837d8236afe616c619bf8'
        values = {
            'translate-extension.json': {'Hooks': {'LanguageGetTranslatedLanguageNames': 'MediaWiki\\Extension\\Translate\\HookHandler::translateMessageDocumentationLanguage'}},
            'translate-en.json': {'translate-documentation-language': names.DOCUMENTATION_NAMES['en']},
            'translate-fr.json': {'translate-documentation-language': names.DOCUMENTATION_NAMES['fr']},
            'wmf-translate-config-catalog.json': {'commit': commit},
            'wmf-translate-config-tree.json': {'sha': commit, 'truncated': False},
        }
        sources = {name: json.dumps(value, sort_keys=True, ensure_ascii=False).encode() for name, value in values.items()}
        sources['translate-HookHandler.php'] = b'<?php /* explicit finite source fixture */'
        sources['wmf-translate.dblist'] = b'frwiktionary\n'
        self.assertEqual(set(sources), set(names.TRANSLATE_SOURCE_PINS))
        for name, raw in sources.items(): (root / name).write_bytes(raw)
        return {name: names.evidence.digest(raw) for name, raw in sources.items()}

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
            source_pins = self.translate_source_fixture(root)
            with patch.object(names, '_original_primary', return_value=({'fixture': b'pinned fixture'}, {}, TABLES)), \
                 patch.object(names, 'TRANSLATE_SOURCE_PINS', source_pins):
                manifest = names.capture(args, transport=transport, sleep=lambda _: None)
                self.assertEqual(len(calls), 2)
                self.assertEqual(manifest['schema'], names.SCHEMA)
                self.assertEqual(names.verify(args.output), manifest)
                # Exercise the real Translate wrapper through the same nested
                # autonyms replay route that failed in the retained FR binder.
                import prepare_language_names_autonyms as autonyms
                previous_root = root / 'autonyms-previous'
                previous_root.mkdir()
                previous = {}
                for path in args.output.iterdir():
                    raw = path.read_bytes()
                    (previous_root / ('previous.' + path.name)).write_bytes(raw)
                    previous[path.name] = dict(size=len(raw), sha256=names.evidence.digest(raw))
                with patch.object(autonyms.evidence, 'get_response', side_effect=AssertionError('offline replay called network')):
                    restored_tsv, restored_manifest = autonyms.replay_previous(previous_root, dict(
                        previous=previous, wiki='frwiktionary', date='20261001'))
                self.assertEqual(restored_tsv, (args.output / 'language-names.tsv').read_bytes())
                self.assertEqual(restored_manifest, manifest)
                self.assertEqual(names.capture_artifacts(args.output/'language-names.tsv', manifest),
                                 names.capture_artifacts(args.output/'language-names.tsv'))
                manifest = copy.deepcopy(manifest)
                manifest['generator_sha256'] = '0' * 64
                manifest['dependency_sha256'] = {name: '1' * 64 for name in names.DEPENDENCY_PATHS}
                mp = args.output/'language-names.manifest.json'
                def reseal():
                    manifest['artifacts'] = names._base.payload(args.output)
                    mp.write_bytes(names.evidence.encoded(manifest))
                    (args.output/names.COMPLETE).write_bytes(names.evidence.encoded({
                        'schema': names.SCHEMA, 'manifest_sha256': names.evidence.digest(mp.read_bytes())}))
                reseal()
                self.assertEqual(names.verify(args.output), manifest)
                preserved = {p.name: p.read_bytes() for p in args.output.iterdir()}
                record = manifest['requests'][0]
                request_path = args.output / record['request']
                receipt_path = args.output / record['accepted_receipt']
                for change in ('query', 'receipt', 'resealed_raw'):
                    for name, raw_bytes in preserved.items(): (args.output/name).write_bytes(raw_bytes)
                    if change == 'query':
                        request = json.loads(request_path.read_text()); request['query']['uselang'] = 'fr'
                        request['url'] = names.evidence.wiktionary_api('frwiktionary') + '?' + urllib.parse.urlencode(sorted(request['query'].items()))
                        request_path.write_bytes(names.evidence.encoded(request))
                    else:
                        receipt = json.loads(receipt_path.read_text())
                        if change == 'receipt': receipt['accepted'] = False
                        else:
                            raw_path = args.output / receipt['response']; body = json.loads(raw_path.read_text())
                            body['query']['languageinfo']['qqq']['name'] = 'Fabricated documentation'
                            raw = names.evidence.encoded(body); raw_path.write_bytes(raw)
                            receipt['response_bytes'] = len(raw); receipt['response_sha256'] = names.evidence.digest(raw)
                        receipt_path.write_bytes(names.evidence.encoded(receipt))
                    reseal()
                    with self.subTest(change=change), self.assertRaises(ValueError): names.verify(args.output)
                for name, raw_bytes in preserved.items(): (args.output/name).write_bytes(raw_bytes)
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
