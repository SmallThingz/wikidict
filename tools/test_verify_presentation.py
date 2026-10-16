import json
import hashlib
import subprocess
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

    def test_all_seven_views_and_owner_inventory(self):
        with Fixture() as f:
            f.language('Unverified exact heading', [f.entry('main', '__NOEDITSECTION__', language='Unverified exact heading')])
            for kind in audit.FEATURE_KINDS:
                f.feature(kind, [f.entry(kind, 'Lua error', kind=kind.replace('-', '_'))], compressed=True)
            result = audit.scan(f.root, f.query)
            self.assertEqual(7, result['view_count'])
            self.assertEqual(7, result['records'])
            self.assertEqual(7, result['search_matches'])
            self.assertEqual(7, len(result['issues']))
            self.assertEqual(15, result['commands'])
            self.assertTrue(result['scan_complete'])
            self.assertFalse(result['semantic_acceptance'])
            self.assertEqual('Unverified exact heading', result['views'][0]['language'])
            self.assertIn('not raw DAL1 coverage', result['scope']['aliases'])

    def test_raw_and_xz_select_one_feature_view(self):
        with Fixture() as f:
            f.feature('supplemental', [f.entry('Appendix:X', '__NOEDITSECTION__', kind='supplemental')])
            (f.root / 'supplemental.wikblb.xz').touch()
            result = audit.scan(f.root, f.query)
            self.assertEqual(1, result['view_count'])
            self.assertEqual('supplemental', result['issues'][0]['kind'])
            self.assertEqual('Appendix:X', result['issues'][0]['query_title'])

    def test_neutral_main_alias_only_root(self):
        with Fixture() as f:
            entry = f.entry('only redirect', 'literal __NOEDITSECTION__', kind='alias')
            entry['redirect'] = dict(source_title='only redirect', followed=False)
            f.neutral([entry])
            result = audit.scan(f.root, f.query)
            self.assertTrue(result['views'][0]['neutral'])
            self.assertIsNone(result['views'][0]['language'])
            self.assertEqual(1, result['records'])
            self.assertEqual('alias', result['issues'][0]['kind'])
            self.assertIsNone(result['issues'][0]['language'])

    def test_neutral_without_producer_coverage_uses_native_stats(self):
        with Fixture() as f:
            entry = f.entry('redirect', 'plain', kind='alias')
            entry['redirect'] = dict(source_title='redirect', followed=False)
            f.neutral([entry])
            (f.root / 'namespace-coverage.json').unlink()
            result = audit.scan(f.root, f.query)
            self.assertEqual(('passed', 1, 4), (result['status'], result['records'], result['commands']))
            for mutation in ({'language': 'invented owner'}, {'record_count': 0}, {'total_matches': 2}):
                def query(*parts):
                    value = f.query(*parts)
                    if parts[0] == 'stats': value.update(mutation)
                    return value
                with self.subTest(mutation=mutation), self.assertRaises(audit.ScanError):
                    audit.scan(f.root, query)
            def failed_stats(*parts):
                if parts[0] == 'stats': raise subprocess.CalledProcessError(1, ['dict'])
                return f.query(*parts)
            with self.assertRaises(subprocess.CalledProcessError):
                audit.scan(f.root, failed_stats)

    def test_feature_alias_only_does_not_invent_neutral_owner(self):
        with Fixture() as f:
            entry = f.entry('redirect', 'plain', kind='alias')
            entry['redirect'] = dict(source_title='redirect', followed=False)
            f.feature('supplemental', [entry])
            f.alias_inventory([dict(id=100, kind='supplemental', alias_pages=1)])
            result = audit.scan(f.root, f.query)
            self.assertEqual(1, result['view_count'])
            self.assertEqual('supplemental', result['views'][0]['kind'])

    def test_followed_alias_destination_is_scanned_once_and_keeps_join(self):
        with Fixture() as f:
            target = f.entry('destination', '__NOEDITSECTION__', language='English')
            alias = dict(target, redirect=dict(source_title='alias', target_title='destination', fragment='', followed=True))
            f.language('English', [target], aliases={'alias': alias})
            result = audit.scan(f.root, f.query)
            self.assertEqual((2, 1, 1, 1), (result['search_matches'], result['records'],
                result['duplicate_destinations'], result['alias_views']))
            issue = result['issues'][0]
            self.assertEqual(('alias', 'destination', 'English'),
                             (issue['query_title'], issue['title'], issue['language']))
            self.assertTrue(issue['redirect']['followed'])

    def test_cross_kind_follow_keeps_actual_owner(self):
        with Fixture() as f:
            target = f.entry('Appendix:T', 'Lua error', kind='supplemental')
            alias = dict(target, redirect=dict(source_title='entry alias', followed=True))
            f.language('English', [], aliases={'entry alias': alias})
            f.feature('supplemental', [target])
            result = audit.scan(f.root, f.query)
            self.assertEqual(1, result['records'])
            issue = result['issues'][0]
            self.assertEqual(('language', 'English', 'supplemental', None),
                (issue['view_kind'], issue['view_language'], issue['kind'], issue['language']))

    def test_feature_alias_key_and_full_title_join_deduplicates_destination(self):
        with Fixture() as f:
            target = f.entry('destination', '__NOEDITSECTION__', kind='thesaurus')
            alias = dict(target, redirect=dict(source_title='Thésaurus:A:old',
                         target_title='Thésaurus:destination', fragment='', followed=True))
            f.feature('thesaurus', [target])
            f.tables[('thesaurus', None)]['A:old'] = alias
            result = audit.scan(f.root, f.query)
            self.assertEqual((2, 1, 1), (result['search_matches'], result['records'], result['duplicate_destinations']))
            issue = result['issues'][0]
            self.assertEqual(('A:old', 'Thésaurus:A:old', 'destination', 'Thésaurus:destination'),
                (issue['query_title'], issue['source_title'], issue['title'], issue['redirect']['target_title']))
            for kind in ('language', 'supplemental'):
                self.assertEqual('Topic:part', audit.source_lookup_key(kind, 'Topic:part'))
            self.assertEqual('A:old', audit.source_lookup_key('thesaurus', 'Thésaurus:A:old'))

    def test_coverage_present_rejects_missing_fixed_payload(self):
        with Fixture() as f:
            (f.root / 'namespace-coverage.json').write_text(json.dumps(dict(version=1,
                namespaces=[dict(id=110, kind='thesaurus', expanded_pages=1, fallback_pages=0, alias_pages=0)])))
            with self.assertRaisesRegex(audit.ScanError, 'missing fixed-kind payload'):
                audit.scan(f.root, f.query)

    def test_actual_cli_empty_search_rc1_only(self):
        with Fixture() as f:
            f.language('English', [])
            def query(operation, *parts):
                value = f.query(operation, *parts)
                if operation != 'search': return value
                error = subprocess.CalledProcessError(1, ['dict'], output=json.dumps(value).encode())
                with mock.patch.object(audit.subprocess, 'check_output', side_effect=error):
                    return audit.cli_query(f.root / 'dict', f.root, operation, *parts)
            result = audit.scan(f.root, query)
            self.assertEqual('passed', result['status'])
            self.assertEqual((1, 0), (result['view_count'], result['records']))
            for operation, mutation in (('export', {}), ('search', {'matches': [{'title': 'bad'}]}),
                                        ('search', {'has_more': True})):
                value = f.query('search', '--kind', 'language', '--language', 'English',
                    '--case-sensitive', '--limit', '1000', '--offset', '0', '--', '')
                value.update(mutation)
                error = subprocess.CalledProcessError(1, ['dict'], output=json.dumps(value).encode())
                with self.subTest(operation=operation, mutation=mutation), \
                     mock.patch.object(audit.subprocess, 'check_output', side_effect=error):
                    with self.assertRaises((audit.ScanError, subprocess.CalledProcessError)):
                        audit.cli_query(f.root / 'dict', f.root, operation)

    def test_conflicting_duplicate_destination_is_error(self):
        with Fixture() as f:
            target = f.entry('z', 'plain', language='English')
            alias = dict(target, preamble_spans=[dict(kind='text', text='different')],
                         redirect=dict(source_title='a', followed=True))
            f.language('English', [target], aliases={'a': alias})
            with self.assertRaisesRegex(audit.ScanError, 'conflicting duplicate'):
                audit.scan(f.root, f.query)

    def test_split_marker_in_supplemental_table(self):
        with Fixture() as f:
            entry = f.entry('Appendix:T', '', kind='supplemental')
            entry['sections'] = [dict(blocks=[dict(table=dict(rows=[dict(cells=[dict(spans=[
                dict(kind='text', text='__NO', trail='EDIT'),
                dict(kind='text', text='SECTION__', trail='')])])]))])]
            f.feature('supplemental', [entry])
            result = audit.scan(f.root, f.query)
            self.assertEqual(['behavior-switch'], result['issues'][0]['categories'])

    def test_multiple_pages_are_complete(self):
        with Fixture() as f:
            f.page_size = 1
            f.language('English', [f.entry(x, 'plain', language='English') for x in ('a', 'b')])
            result = audit.scan(f.root, f.query)
            self.assertEqual(2, result['records'])
            self.assertEqual(5, result['commands'])

    def test_duplicate_same_owner_title_is_error(self):
        with Fixture() as f:
            f.language('English', [f.entry('a', 'plain', language='English')])
            def query(*parts):
                value = f.query(*parts)
                if parts[0] == 'search':
                    value.update(matches=[{'title': 'a'}, {'title': 'a'}], record_count=2, total_matches=2)
                return value
            with self.assertRaisesRegex(audit.ScanError, 'duplicate or nonprogressing'):
                audit.scan(f.root, query)

    def test_nonprogressing_page_and_changed_count_are_errors(self):
        for mutation in ('empty', 'changed', 'has_more', 'owner'):
            with self.subTest(mutation=mutation), Fixture() as f:
                f.language('English', [f.entry('a', 'plain', language='English')])
                def query(*parts):
                    value = f.query(*parts)
                    if parts[0] == 'search':
                        if mutation == 'empty': value.update(matches=[], has_more=True)
                        if mutation == 'changed': value['record_count'] = 2
                        if mutation == 'has_more': value['has_more'] = True
                        if mutation == 'owner': value['language'] = 'Other'
                    return value
                with self.assertRaises(audit.ScanError):
                    audit.scan(f.root, query)

    def test_missing_or_ambiguous_export_is_error(self):
        for count in (0, 2):
            with self.subTest(count=count), Fixture() as f:
                entry = f.entry('a', 'plain', language='English')
                f.language('English', [entry])
                def query(*parts):
                    value = f.query(*parts)
                    if parts[0] == 'export': value['entries'] = [entry] * count
                    return value
                with self.assertRaisesRegex(audit.ScanError, 'missing or ambiguous'):
                    audit.scan(f.root, query)

    def test_catalog_duplicates_and_orphan_payload_are_errors(self):
        for mutation in ('duplicate', 'missing_accounting', 'orphan'):
            with self.subTest(mutation=mutation), Fixture() as f:
                f.language('English', [f.entry('a', 'plain', language='English')])
                if mutation == 'orphan': (f.root / 'languages' / ('0' * 64 + '.wikblb')).touch()
                def query(*parts):
                    value = f.query(*parts)
                    if parts[0] == 'languages':
                        if mutation == 'duplicate': value['languages'] *= 2
                        if mutation == 'missing_accounting': value['accounting'] = []
                    return value
                with self.assertRaises(audit.ScanError):
                    audit.scan(f.root, query)

    def run_report(self, text=None, error=None):
        with Fixture() as f:
            if text is not None: f.language('English', [f.entry('fixture', text, language='English')])
            report = f.root / 'audit.json'
            report.write_text('{"status":"passed"}')
            def output(argv, timeout):
                self.assertEqual(60, timeout)
                if error is not None: raise error
                # Match actual CLI argv: operation --root ROOT --format json PARTS.
                return json.dumps(f.query(argv[1], *argv[6:])).encode()
            argv = ['verify_presentation.py', '--binary', str(f.root / 'dict'),
                    '--root', str(f.root), '--report', str(report)]
            with mock.patch.object(audit.subprocess, 'check_output', side_effect=output), \
                 mock.patch('sys.argv', argv), mock.patch('builtins.print') as printed:
                exit_value = audit.main()
            result = json.loads(report.read_text())
            stdout = printed.call_args.args[0]
            if result['status'] == 'error':
                self.assertTrue(stdout.startswith('PRESENTATION_AUDIT error '))
                self.assertLess(len(stdout), 530)
            else:
                self.assertEqual(
                    f"PRESENTATION_AUDIT {result['status']} records={result['records']} "
                    f"issues={len(result['issues'])} views={result['view_count']} commands={result['commands']}", stdout)
            return exit_value, result

    def test_report_preserves_review_exit_and_explicit_scope(self):
        code, result = self.run_report('__NOEDITSECTION__')
        self.assertEqual(1, code)
        self.assertEqual('failed', result['status'])
        self.assertEqual(1, result['records'])
        self.assertTrue(result['scan_complete'])
        self.assertTrue(result['diagnostic_only'])
        self.assertFalse(result['semantic_acceptance'])
        self.assertFalse(result['scope']['protected_literal_provenance'])

    def test_zero_hits_is_not_semantic_acceptance(self):
        code, result = self.run_report('ordinary visible text')
        self.assertEqual(0, code)
        self.assertEqual('passed', result['status'])
        self.assertEqual([], result['issues'])
        self.assertFalse(result['semantic_acceptance'])
        self.assertEqual(list(audit.SUPPORTED_KINDS), result['scope']['record_kinds'])

    def test_command_timeout_exit_and_json_errors_replace_stale_success(self):
        for error in (subprocess.CalledProcessError(1, ['dict']),
                      subprocess.TimeoutExpired(['dict'], 60),
                      json.JSONDecodeError('invalid', 'x', 0), OSError('missing binary')):
            with self.subTest(error=type(error).__name__):
                code, result = self.run_report(error=error)
                self.assertEqual(2, code)
                self.assertEqual('error', result['status'])
                self.assertFalse(result['scan_complete'])
                self.assertFalse(result['semantic_acceptance'])


class Fixture:
    """Small mocked CLI boundary, with native-shaped responses and inventory."""
    def __enter__(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        (self.root / 'languages.tsv').write_text('fixture')
        self.owners, self.tables = {}, {}
        self.page_size = 1000
        return self

    def __exit__(self, *unused):
        self.directory.cleanup()

    @staticmethod
    def entry(title, text, kind='language', language=None):
        return dict(title=title, kind=kind, language=language,
                    preamble_spans=[dict(kind='text', text=text, trail='')])

    def language(self, owner, entries, aliases=None):
        path = self.root / 'languages'
        path.mkdir(exist_ok=True)
        (path / (hashlib.sha256(owner.encode()).hexdigest() + '.wikblb')).touch()
        self.owners[owner] = len(entries)
        self.tables[('language', owner)] = {entry['title']: entry for entry in entries}
        self.tables[('language', owner)].update(aliases or {})

    def feature(self, kind, entries, compressed=False):
        (self.root / (kind + '.wikblb' + ('.xz' if compressed else ''))).touch()
        self.tables[(kind, None)] = {entry['title']: entry for entry in entries}

    def alias_inventory(self, rows):
        (self.root / 'aliases.wikblb').touch()
        (self.root / 'namespace-coverage.json').write_text(json.dumps(dict(version=1,
            namespaces=[dict(expanded_pages=row['alias_pages'], fallback_pages=0, **row) for row in rows])))

    def neutral(self, entries):
        self.alias_inventory([dict(id=0, kind='language', alias_pages=len(entries))])
        self.tables[('language', None)] = {entry['title']: entry for entry in entries}

    def query(self, operation, *parts):
        if operation == 'languages':
            return dict(languages=list(self.owners), accounting=[dict(heading=k, records=v) for k, v in self.owners.items()])
        kind = parts[parts.index('--kind') + 1]
        owner = parts[parts.index('--language') + 1] if '--language' in parts else None
        if owner == 'neutral-alias-view': owner = None
        table = self.tables[(kind, owner)]
        result = dict(operation=operation, query='' if operation in ('search', 'stats') else parts[-1],
                      kind=kind.replace('-', '_'), language=owner, record_count=len(table))
        if operation == 'search':
            offset = int(parts[parts.index('--offset') + 1])
            titles = sorted(table)[offset:offset + self.page_size]
            self.assert_search(parts)
            result.update(total_matches=len(table), offset=offset,
                          matches=[dict(title=t) for t in titles], has_more=offset + len(titles) < len(table))
        elif operation == 'export':
            result['entries'] = [table[parts[-1]]]
        elif operation == 'stats':
            result['total_matches'] = len(table)
        else:
            raise AssertionError(operation)
        return result

    @staticmethod
    def assert_search(parts):
        assert '--case-sensitive' in parts and parts[-2:] == ('--', '')


if __name__ == '__main__':
    unittest.main()
