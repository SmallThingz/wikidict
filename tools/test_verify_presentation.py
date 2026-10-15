import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import verify_presentation as audit


class PresentationDiagnosticTests(unittest.TestCase):
    def test_behavior_markers_include_localized_word_spelling(self):
        for text in ('__NOEDITSECTION__', '__noeditsection__', '__لاتحريرقسم__', '__NO_CONTENT_CONVERT__'):
            with self.subTest(text=text):
                self.assertIn('behavior-switch', audit.diagnostic_categories(text))

    def test_existing_source_markup_remains_a_candidate(self):
        for text in ('[[cat]]', '{{missing}}', '<span>literal</span>', '{| table |}'):
            with self.subTest(text=text):
                self.assertIn('source-markup', audit.diagnostic_categories(text))

    def test_visible_runtime_error_spellings_are_candidates(self):
        for text in ('Lua error in Module:Fixture: intentional failure',
                     'Script error', 'Parser error: invalid argument', 'Scribunto error'):
            with self.subTest(text=text):
                self.assertIn('error-prose', audit.diagnostic_categories(text))

    def test_unavailable_template_is_distinct_from_raw_markup(self):
        self.assertEqual(['unavailable-template'],
                         audit.diagnostic_categories('[unavailable template: Missing]'))

    def test_ordinary_prose_has_no_candidate(self):
        for text in ('cat and dog', 'Lua programming language', 'a script without an error', 'NOEDITSECTION'):
            with self.subTest(text=text):
                self.assertEqual([], audit.diagnostic_categories(text))

    def test_decoded_protected_literals_are_not_silently_suppressed(self):
        # Deliberate nowiki/source examples have no reliable decoded provenance.
        # A code flag is a hint, not proof that an error is an intentional example.
        for code in (False, True):
            value = [{'kind': 'text', 'text': 'Lua error in Module:Fixture: text',
                      'trail': ' __NOEDITSECTION__', 'flags': {'code': code}}]
            [(path, text)] = audit.text_fields(value)
            self.assertEqual('entry', path)
            self.assertEqual(['behavior-switch', 'error-prose'], audit.diagnostic_categories(text))

    def test_text_and_trail_join_before_scanning(self):
        spans = [{'kind': 'text', 'text': '__NO', 'trail': 'EDIT'},
                 {'kind': 'text', 'text': 'SECTION__', 'trail': ''}]
        [(path, text)] = audit.text_fields({'blocks': [{'spans': spans}]})
        self.assertEqual('entry.blocks[0].spans', path)
        self.assertEqual(['behavior-switch'], audit.diagnostic_categories(text))

    def run_report(self, text):
        responses = [
            {'languages': ['English']},
            {'matches': [{'title': 'fixture'}], 'has_more': False},
            {'entries': [{'title': 'fixture', 'spans': [{'kind': 'text', 'text': text, 'trail': ''}]}]},
        ]
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / 'audit.json'
            argv = ['verify_presentation.py', '--binary', str(Path(directory) / 'dict'),
                    '--root', directory, '--report', str(report)]
            with mock.patch.object(audit.subprocess, 'check_output',
                                   side_effect=[json.dumps(row).encode() for row in responses]) as query,                  mock.patch('sys.argv', argv), mock.patch('builtins.print'):
                exit_value = audit.main()
            self.assertEqual(3, query.call_count)
            self.assertTrue(all(call.kwargs == {'timeout': 60} for call in query.call_args_list))
            self.assertEqual(['languages', 'search', 'export'],
                             [call.args[0][1] for call in query.call_args_list])
            return exit_value, json.loads(report.read_text())

    def test_report_preserves_legacy_keys_and_review_exit(self):
        exit_value, result = self.run_report('__NOEDITSECTION__')
        self.assertTrue(exit_value)
        self.assertEqual('failed', result['status'])
        self.assertEqual(1, result['records'])
        issue = result['issues'][0]
        self.assertEqual({'language', 'title', 'path', 'text', 'categories'}, set(issue))
        self.assertEqual(['behavior-switch'], issue['categories'])
        self.assertTrue(result['diagnostic_only'])
        self.assertFalse(result['semantic_acceptance'])
        self.assertFalse(result['scope']['protected_literal_provenance'])

    def test_zero_hits_is_not_semantic_acceptance(self):
        exit_value, result = self.run_report('ordinary visible text')
        self.assertFalse(exit_value)
        self.assertEqual('passed', result['status'])
        self.assertEqual([], result['issues'])
        self.assertFalse(result['semantic_acceptance'])
        self.assertEqual('language', result['scope']['record_kind'])


if __name__ == '__main__':
    unittest.main()
