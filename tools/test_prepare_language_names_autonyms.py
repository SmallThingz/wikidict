import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import prepare_language_names_autonyms as m


def response():
    return {'query': {'general': {'wikiid': 'arwiktionary', 'lang': 'ar', 'git-hash': m.CORE},
                      'languageinfo': {'en': {'code': 'en', 'autonym': 'English'},
                                       'ar': {'code': 'ar', 'autonym': 'العربية'},
                                       'zz': {'code': 'zz', 'autonym': ''}},
                      'languages': [{'code': 'en', 'name': 'translated English'},
                                    {'code': 'ar', 'name': 'translated Arabic'}]}}


class AutonymCaptureTests(unittest.TestCase):
    def test_genuine_autonyms_ignore_translated_siteinfo_values(self):
        names, mw, _, continuation = m.parse_response(response(), 'arwiktionary', 'ar')
        self.assertEqual(names['ar'], 'العربية')
        self.assertNotEqual(names['ar'], mw['ar'])
        self.assertEqual(names['zz'], '')
        self.assertEqual(continuation, {})

    def test_exact_site_and_core_identity_required(self):
        for key, value in [('wikiid', 'enwiktionary'), ('lang', 'en'), ('git-hash', '0' * 40)]:
            data = response()
            data['query']['general'][key] = value
            with self.assertRaises(ValueError):
                m.parse_response(data, 'arwiktionary', 'ar')

    def test_warning_and_duplicate_mw_code_refused(self):
        data = response(); data['warnings'] = {}
        with self.assertRaises(ValueError):
            m.parse_response(data, 'arwiktionary', 'ar')
        data = response(); data['query']['languages'].append(data['query']['languages'][0])
        with self.assertRaises(ValueError):
            m.parse_response(data, 'arwiktionary', 'ar')

    def test_missing_autonym_and_mismatched_code_refused(self):
        for change in ('missing', 'code'):
            data = response()
            if change == 'missing':
                del data['query']['languageinfo']['en']['autonym']
            else:
                data['query']['languageinfo']['en']['code'] = 'de'
            with self.assertRaises(ValueError):
                m.parse_response(data, 'arwiktionary', 'ar')

    def test_continuation_shape_is_finite_and_exact(self):
        data = response(); data['continue'] = {'continue': '-||', 'licontinue': 'en'}
        self.assertEqual(m.parse_response(data, 'arwiktionary', 'ar')[3], data['continue'])
        data['continue']['extra'] = 'x'
        with self.assertRaises(ValueError):
            m.parse_response(data, 'arwiktionary', 'ar')

    def test_alias_union_uses_only_normalized_genuine_targets(self):
        names = {'en': 'English', 'ar': 'العربية', 'zz': ''}
        single = m.finish(names, {'en': 'not autonym', 'ar': 'not autonym'}, {'eng': 'en', 'unknown-alias': 'missing'}, {'en', 'ar'})
        self.assertEqual(single['eng'], 'English')
        self.assertEqual(single['unknown-alias'], '')
        with self.assertRaises(ValueError):
            m.finish({'en': 'English', 'eng': 'different'}, {'en': 'English'}, {'eng': 'en'}, {'en'})

    def test_positive_unobserved_language_is_not_guessed(self):
        with self.assertRaises(ValueError):
            m.finish({'en': 'English', 'xx': 'invented'}, {'en': 'English'}, {}, {'en'})
        with self.assertRaises(ValueError):
            m.finish({'en': 'English'}, {'en': 'English', 'ar': 'العربية'}, {}, {'en', 'ar'})

        # Removing the same built-in code from both API arrays must still fail.
        with self.assertRaisesRegex(ValueError, 'Incomplete built-in MW inventory'):
            m.finish({'en': 'English'}, {'en': 'English'}, {}, {'en', 'ar'})

    def test_null_single_serialization_keeps_empty_and_escapes(self):
        raw = m.render_profile({'ar': 'العربية', 'zz': '', 'xx': 'a\tb\nc\\d'})
        self.assertEqual(raw.splitlines()[0], b'C\t-\tsingle\t3')
        self.assertIn(b'N\t-\tsingle\tzz\t\n', raw)
        self.assertIn(b'N\t-\tsingle\txx\ta\\tb\\nc\\\\d\n', raw)

    def test_legacy_schema_dispatch_is_preserved_and_unknown_refused(self):
        self.assertIs(m.previous_helper('wikidict.language-names-capture.v1'), m.legacy)
        self.assertEqual(m.previous_helper('wikidict.language-names-capture.v2').SCHEMA, 'wikidict.language-names-capture.v2')
        self.assertEqual(m.previous_helper('wikidict.language-names-translate-capture.v1').SCHEMA, 'wikidict.language-names-translate-capture.v1')
        with self.assertRaises(ValueError):
            m.previous_helper('unknown')

    def test_capture_records_one_http_observation_and_replays_offline(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); sources = root / 'sources'; sources.mkdir()
            code = b"private const DEPRECATED_LANGUAGE_CODE_MAPPING = [\n\t];\nprivate const NON_STANDARD_LANGUAGE_CODE_MAPPING = [\n\t];\n"
            (sources / 'LanguageCode.php').write_bytes(code)
            names_source = b"public const NAMES = [\n\t\t'en' => 'English',\n\t\t'ar' => 'unused value',\n\t\t'en-x-piglatin' => 'optional testing language',\n\t];\n"
            (sources / 'Names.php').write_bytes(names_source)
            namespace = root / 'namespace.tsv'
            namespace.write_text('# wikidict-namespace-registry-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n')
            raw = json.dumps(response(), ensure_ascii=False).encode()
            calls = []
            def transport(url, timeout):
                calls.append((url, timeout))
                return 200, {}, raw
            with mock.patch.object(m, 'SOURCE_PINS', {'LanguageCode.php': hashlib.sha256(code).hexdigest(), 'Names.php': hashlib.sha256(names_source).hexdigest()}):
                observed = m.capture_observation('arwiktionary', '20261001', namespace, sources, root / 'out', transport=transport)
                self.assertEqual(len(calls), 1)
                self.assertIn('liprop=code%7Cautonym', calls[0][0])
                self.assertLessEqual(calls[0][1], 30)
                self.assertEqual(observed['observed_codes'], 3)
                self.assertEqual(observed['observed_empty'], 1)
                self.assertEqual(m.replay_observation(root / 'out', observed)[1]['ar'], 'العربية')
                record = observed['requests'][0]
                receipt_path = root / 'out' / record['accepted_receipt']
                receipt = json.loads(receipt_path.read_text())
                self.assertTrue(receipt['accepted'])
                body = root / 'out' / receipt['response']
                body.write_bytes(raw + b' ')
                with self.assertRaises(ValueError):
                    m.replay_observation(root / 'out', observed)

    def test_rejected_http_receipt_cannot_be_silently_promoted(self):
        receipt = {'accepted': False, 'error': 'something else'}
        with self.assertRaises(ValueError):
            m.accepted_receipt(Path('.'), {'request': 'a', 'accepted_receipt': 'b'}, receipt)

    def test_unsafe_evidence_names_and_changed_previous_bytes_refused(self):
        for name in ('../response', '/response', '..'):
            with self.assertRaises(ValueError):
                m.safe_name(name)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'previous.language-names.tsv').write_bytes(b'changed')
            manifest = {'previous': {'language-names.tsv': {'size': 3, 'sha256': '0' * 64}},
                        'wiki': 'arwiktionary', 'date': '20261001'}
            with self.assertRaises(ValueError):
                m.replay_previous(root, manifest)


if __name__ == '__main__':
    unittest.main()
