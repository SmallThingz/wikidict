"""Hermetic tests: synthetic HTTP data only; no network, compiler, or Lua."""
import argparse
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.parse

import prepare_language_names as names


def response(display='ar', continuation=False):
    single = {'ar': 'العربية', 'en': 'الإنجليزية', 'als': 'الألمانية السويسرية',
              'gsw': 'الألمانية السويسرية', 'egl': 'Emiliano-Romagnolo', 'eml': 'Emiliano-Romagnolo'}
    if display == 'en':
        single.update(ar='Arabic', en='English', als='Swiss German', gsw='Swiss German')
    raw_mw = {**single, 'als': 'Alemannic', 'egl': 'Emilian'}
    info = {code: {'code': code, 'name': value, 'dir': 'rtl' if code == 'ar' else 'ltr', 'fallbacks': []}
            for code, value in single.items()}
    result = {'batchcomplete': True, 'query': {'general': {'wikiid': 'arwiktionary', 'lang': 'ar', 'git-hash': names.CORE},
              'languageinfo': info, 'languages': [{'code': code, 'name': value} for code, value in raw_mw.items()]}}
    if continuation:
        result['continue'] = {'continue': '-||', 'licontinue': 'eml'}
    return result


ALIASES = {'als': 'gsw', 'egl': 'eml', 'en-x-test': 'uncaptured-canonical'}


class CaptureTest(unittest.TestCase):
    def config(self):
        return {'wiki': 'arwiktionary', 'date': '20261001', 'content_language': 'ar', 'languages': ['ar', 'en']}

    def batches(self):
        return [(names.request_query(display, index == 0, {}), response(display))
                for index, display in enumerate(('ar', 'en'))]

    def test_raw_table_and_single_lookup_remain_distinct(self):
        profiles, directions = names.reconstruct(self.config(), self.batches(), ALIASES)
        self.assertEqual(profiles['ar']['all']['als'], 'Alemannic')
        self.assertEqual(profiles['ar']['single']['als'], 'الألمانية السويسرية')
        self.assertEqual(profiles['en']['all']['egl'], 'Emilian')
        self.assertEqual(profiles['en']['single']['egl'], 'Emiliano-Romagnolo')
        self.assertEqual(profiles['en']['single']['en-x-test'], '')
        self.assertNotIn('en-x-test', profiles['en']['all'])
        self.assertNotIn('en-x-test', directions)
        self.assertEqual(directions['ar'], 'rtl')
        self.assertEqual(directions['en'], 'ltr')
        data = names.render(profiles, directions, 'arwiktionary', '20261001', 'ar').decode()
        self.assertIn('C\tar\tall\t6\n', data)
        self.assertIn('C\tar\tsingle\t7\n', data)
        self.assertIn('N\tar\tsingle\ten-x-test\t\n', data)
        self.assertNotIn('C\t-\tall', data)

    def test_continuation_is_complete_ordered_and_unique(self):
        first, last = response('ar', True), response('ar')
        keys = sorted(first['query']['languageinfo'])
        first['query']['languageinfo'] = {k: first['query']['languageinfo'][k] for k in keys[:3]}
        last['query']['languageinfo'] = {k: last['query']['languageinfo'][k] for k in keys[3:]}
        batches = [(names.request_query('ar', True, {}), first),
                   (names.request_query('ar', True, first['continue']), last), self.batches()[1]]
        expected = names.reconstruct(self.config(), self.batches(), ALIASES)
        self.assertEqual(names.reconstruct(self.config(), batches, ALIASES), expected)
        with self.assertRaisesRegex(ValueError, 'Incomplete|Reordered'):
            names.reconstruct(self.config(), batches[:1], ALIASES)
        repeated = copy.deepcopy(batches)
        repeated[1][1]['query']['languageinfo'].update(first['query']['languageinfo'])
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            names.reconstruct(self.config(), repeated, ALIASES)

    def test_direction_identity_and_unknown_profiles_are_not_guessed(self):
        for mutation, pattern in ((lambda r: r['query']['general'].update(wikiid='enwiktionary'), 'identity|mismatch'),
                                  (lambda r: r['query']['general'].update({'git-hash': 'other'}), 'mismatch'),
                                  (lambda r: r['query']['languageinfo']['ar'].pop('dir'), 'direction'),
                                  (lambda r: r['query']['languageinfo']['ar'].update(fallbacks=['fa']), 'fallback')):
            data = response()
            mutation(data)
            with self.assertRaisesRegex(ValueError, pattern):
                names.parse_response(data, 'arwiktionary', 'ar', True)
        data = response()
        data['warnings'] = {'test': 'warning'}
        with self.assertRaisesRegex(ValueError, 'warning'):
            names.parse_response(data, 'arwiktionary', 'ar', True)

    def test_escaped_fields_and_complete_counts(self):
        special = 'a\\b\tc\nd\re'
        profiles = {'ar': {scope: {'ar': special} for scope in names.SCOPES}}
        raw = names.render(profiles, {'ar': 'rtl'}, 'arwiktionary', '20261001', 'ar').decode()
        self.assertIn('N\tar\tall\tar\ta\\\\b\\tc\\nd\\re\n', raw)
        self.assertIn('C\t-\tdir\t1\nD\tar\trtl\n', raw)

    def test_full_capture_verify_tamper_rejected_and_no_network(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent) as directory:
            root = Path(directory)
            registry = root / 'namespace-registry.tsv'
            registry.write_text('# wikidict-namespace-registry-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n')
            args = argparse.Namespace(wiki='arwiktionary', date='20261001', namespace_registry=registry,
                primary_sources=root, output=root / 'capture', languages=['en', 'ar', 'ar'], delay=0, wall_seconds=60)
            seen = []
            def transport(url, timeout):
                self.assertGreater(timeout, 0)
                query = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
                seen.append(query)
                return 200, {}, json.dumps(response(query['uselang'][0]), ensure_ascii=False).encode()
            with patch.object(names, 'primary_contract', return_value=({'fixture': b'primary fixture'}, ALIASES)):
                manifest = names.capture(args, transport=transport, sleep=lambda _: None)
                self.assertEqual(len(seen), 2)
                self.assertIn('dir', seen[0]['liprop'][0])
                self.assertNotIn('dir', seen[1]['liprop'][0])
                self.assertEqual(names.verify(args.output), manifest)
                self.assertEqual(names.validate_snapshot(args.output / 'language-names.tsv', 'arwiktionary', '20261001'), manifest)
                with self.assertRaisesRegex(ValueError, 'edition/date'):
                    names.validate_snapshot(args.output / 'language-names.tsv', 'enwiktionary', '20261001')
                (args.output / 'language-names.tsv').write_bytes(b'tampered\n')
                with self.assertRaisesRegex(ValueError, 'inventory'):
                    names.verify(args.output)
            args.languages = ['fr']
            args.output = root / 'unsupported'
            with self.assertRaisesRegex(ValueError, 'unproved'):
                names.capture(args, transport=lambda *_: self.fail('Unexpected network'))
            self.assertFalse(args.output.exists())


if __name__ == '__main__':
    unittest.main()
