import gzip
import json
import hashlib
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest
from contextlib import ExitStack
from unittest import mock

import verify_presentation as audit


class PresentationDiagnosticTests(unittest.TestCase):
    def test_category_prescreen_preserves_multiple_matches_and_unicode(self):
        self.assertEqual(audit.diagnostic_categories('ſcript ERROR: [[猫]] __NOTOC__ [MISSING TEMPLATE]'),
                         ['source-markup', 'behavior-switch', 'error-prose', 'unavailable-template'])
        for markup in (']]', '}}', '|}', '{|', '<b>'):
            self.assertEqual(audit.diagnostic_categories(markup), ['source-markup'])

    def test_behavior_markers_include_localized_word_spelling(self):
        for text in ('__NOEDITSECTION__', '__noeditsection__', '__لاتحريرقسم__', '__NO_CONTENT_CONVERT__'):
            with self.subTest(text=text):
                self.assertIn('behavior-switch', audit.diagnostic_categories(text))
        for source_rule in ('________________', 'approx________________', '_' * 8192):
            self.assertNotIn('behavior-switch', audit.diagnostic_categories(source_rule))
        self.assertIn('behavior-switch', audit.diagnostic_categories('______________ __NOTOC__'))

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

    def test_native_recovery_messages_in_visible_prose(self):
        for message in ('malformed template', 'malformed link', 'malformed table', 'missing parameter',
                        'render nesting limit', 'render output truncated'):
            spans = [dict(kind='text', text='before ['), dict(kind='text', text=message + '] after')]
            [(_, prose)] = audit.text_fields(spans)
            self.assertEqual(audit.diagnostic_categories(prose), ['render-diagnostic'])
            self.assertEqual(audit.diagnostic_categories(message), [])

    def test_visible_missing_template_marker_from_native_writer(self):
        spans = [dict(kind='text', text='cat', trail=''),
                 dict(kind='text', text=' [missing template]', trail='')]
        [(path, text)] = audit.text_fields({'blocks': [{'spans': spans}]})
        self.assertEqual(path, 'entry.blocks[0].spans')
        self.assertEqual(['unavailable-template'], audit.diagnostic_categories(text))
        self.assertEqual([], audit.diagnostic_categories('a missing template name'))

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

    def test_ruby_base_reading_and_fallback_are_separate_visible_runs(self):
        def span(text, **fields):
            return dict(kind='text', text=text, **fields)

        ruby = dict(segments=[dict(bases=[dict(spans=[span('日')])], annotations=[dict(
            spans=[span('__NO'), span('TOC__', explanation='{{tooltip}}')],
            fallback_before=[span('(')], fallback_after=[span(')')])])])
        body = [span('{'), span('', ruby=ruby, trail='{'), span('after')]
        fields = list(audit.text_fields(body))
        self.assertEqual(['{', '日', '__NOTOC__', '(', ')', '{after'], [text for _, text in fields])
        self.assertEqual([('entry[1].ruby.segments[0].annotations[0].spans', ['behavior-switch'])],
                         [(path, audit.diagnostic_categories(text)) for path, text in fields
                          if audit.diagnostic_categories(text)])

    def test_nested_inline_groups_scan_visible_text_once_and_keep_target_separate(self):
        visible = dict(kind='link', text='Lua ', target='{{target}}', explanation='{{tooltip}}')
        child = dict(kind='text', text='', inline_action_group=dict(spans=[visible, dict(kind='text', text='error')]))
        for group in ('inline_padding_group', 'inline_box_group'):
            with self.subTest(group=group):
                body = [dict(kind='text', text='', **{group: dict(spans=[child])})]
                self.assertEqual([('entry', 'Lua error')],
                                 list(audit.text_fields(body)))
                self.assertEqual(['{{target}}'], [target for _, target in audit.action_fields(body)])
                self.assertEqual(['{{tooltip}}'], [note for _, note in audit.annotation_fields(body)])


    def test_inline_group_text_joins_outer_prose_and_respects_overlay_order(self):
        def span(text, **fields):
            return dict(kind='text', text=text, **fields)

        for key in ('inline_action_group', 'inline_padding_group', 'inline_box_group'):
            with self.subTest(key=key):
                spans = [span('__NO'), span('', **{key: dict(spans=[span('TO')])}), span('C__')]
                self.assertEqual([('entry', '__NOTOC__')], list(audit.text_fields(spans)))
        group = dict(spans=[span('Lua '), span('error')], overlays=[dict(content=None),
            dict(content=dict(before_child=1, spans=[span('example')])),
            dict(content=dict(before_child=1, spans=[span(' without ')]))])
        fields = list(audit.text_fields([span('', inline_box_group=group, trail='.')]))
        self.assertEqual([('entry', 'Lua example without error.')], fields)
        self.assertEqual([], audit.diagnostic_categories(fields[0][1]))

    def test_explanations_traverse_span_lists_tables_and_references_once(self):
        span = dict(kind='text', text='body', trail='', explanation='literal {{x}}')
        entry = dict(sections=[dict(blocks=[dict(spans=[span], table=dict(
            caption=[span], rows=[dict(cells=[dict(spans=[span])])]))])],
            references=[dict(spans=[span])])
        paths = [path for path, _ in audit.annotation_fields(entry)]
        self.assertEqual([
            'entry.sections[0].blocks[0].spans[0].explanation',
            'entry.sections[0].blocks[0].table.caption[0].explanation',
            'entry.sections[0].blocks[0].table.rows[0].cells[0].spans[0].explanation',
            'entry.references[0].spans[0].explanation'], paths)
        self.assertEqual([], list(audit.annotation_fields([
            dict(kind='text', text='body'), dict(kind='text', text='body', explanation='')])))

    def test_plain_annotations_do_not_become_body_or_action_failures(self):
        with Fixture() as f:
            entry = f.entry('annotated', 'ordinary', language='English')
            entry['sections'] = [dict(blocks=[dict(spans=[dict(kind='text', text='__NO',
                trail='', explanation='EDITSECTION__ {{literal}} Lua error')])])]
            f.language('English', [entry])
            result = audit.scan(f.root, f.query)
            self.assertEqual('passed', result['status'])
            self.assertEqual([], result['issues'])
            [annotation] = result['annotations']
            self.assertEqual('EDITSECTION__ {{literal}} Lua error', annotation['text'])
            self.assertEqual(['source-markup', 'error-prose'], annotation['spelling_matches'])
            self.assertFalse(annotation['lexical_body'] or annotation['runtime_markup'] or annotation['review_issue'])
            self.assertFalse(result['semantic_acceptance'])
            self.assertEqual([], list(audit.action_fields(entry)))

    def test_followed_alias_annotations_keep_owner_join_without_duplication(self):
        with Fixture() as f:
            target = f.entry('destination', 'ordinary', language='English')
            target['sections'] = [dict(blocks=[dict(spans=[dict(kind='link', text='cat',
                target='cat', explanation='plain <literal> __NOTOC__')])])]
            alias = dict(target, redirect=dict(source_title='alias', target_title='destination',
                fragment='', followed=True))
            f.language('English', [target], aliases={'alias': alias})
            result = audit.scan(f.root, f.query)
            self.assertEqual((1, 1), (result['records'], result['duplicate_destinations']))
            [annotation] = result['annotations']
            self.assertEqual(('alias', 'destination', 'English'),
                (annotation['query_title'], annotation['title'], annotation['language']))
            self.assertTrue(annotation['redirect']['followed'])
            self.assertEqual('passed', result['status'])
            self.assertEqual([], result['issues'])

    def test_visible_advice_matches_native_image_precedence_and_keeps_body_separate(self):
        with Fixture() as f:
            entry = f.entry('advice', 'ordinary', language='English')
            entry['sections'] = [dict(blocks=[dict(spans=[
                dict(kind='text', text='†', explanation='abbreviation', tooltip='Obsolete sense'),
                dict(kind='text', text='', tooltip='outer', image=dict(tooltip='{{own image title}}')),
                dict(kind='text', text='', tooltip='suppressed', image=dict(tooltip='')),
                dict(kind='text', text='', tooltip='inherited', image=dict(tooltip=None)),
                dict(kind='text', text='plain', tooltip=None),
            ])])]
            f.language('English', [entry])
            result = audit.scan(f.root, f.query)
            notes = result['annotations']
            self.assertEqual(['abbreviation', 'Obsolete sense', '{{own image title}}', 'inherited'],
                             [note['text'] for note in notes])
            self.assertEqual(['[0].explanation', '[0].tooltip', '[1].image.tooltip', '[3].tooltip'],
                             [note['path'].split('.spans')[1] for note in notes])
            self.assertEqual(['source-markup'], notes[2]['spelling_matches'])
            self.assertEqual([], result['issues'])
            self.assertEqual('passed', result['status'])

    def test_residual_action_targets_are_separate_nonwaivable_candidates(self):
        with Fixture() as f:
            entry = f.entry('citation', 'clean prose', language='Hindi')
            entry['sections'] = [dict(blocks=[dict(spans=[
                dict(kind='external_link', text='page ', target='https://dsal.test/?page={{{page=}}}'),
                dict(kind='external_link', text='741', target='https://dsal.test/?page={{{page=}}}'),
                dict(kind='external_link', text='शारदा', target='https://hindwi.test/?q={{#urlencode:शारदा}}')])])]
            f.language('Hindi', [entry])
            result = audit.scan(f.root, f.query)
            self.assertEqual('failed', result['status'])
            self.assertEqual(3, len(result['issues']))
            self.assertEqual(1, result['records'])
            self.assertTrue(all(x['categories'] == ['unresolved-action-target'] and x['nonwaivable'] for x in result['issues']))
            self.assertTrue(all(x['path'].endswith('.target') for x in result['issues']))
            self.assertFalse(result['semantic_acceptance'])

    def test_action_fields_cover_direct_span_tables_references_and_code_actions(self):
        target = 'https://example.test/?q={{missing}}'
        span = dict(kind='external_link', text='label', target=target, code=True)
        self.assertEqual([('entry.target', target)], list(audit.action_fields(span)))
        entry = dict(sections=[dict(blocks=[dict(table=dict(rows=[dict(cells=[dict(spans=[span])])]))])],
                     references=[dict(spans=[dict(kind='link', text='label', target='{{{arg}}}')])])
        paths = [p for p, _ in audit.action_fields(entry)]
        self.assertEqual(2, len(paths))
        self.assertIn('entry.sections[0].blocks[0].table.rows[0].cells[0].spans[0].target', paths)
        self.assertIn('entry.references[0].spans[0].target', paths)

    def test_valid_action_urls_and_nonaction_metadata_are_unchanged(self):
        for target in ('https://example.test/{literal}', 'https://example.test/%7B%7Bx%7D%7D',
                       'https://example.test/शारदा?a=1&b=2', 'cat#English'):
            self.assertFalse(audit.unresolved_action_target(target))
        self.assertEqual([], list(audit.action_fields(dict(title='{{literal}}', redirect=dict(target_title='{{old}}')))))
        # Existing visible-text diagnostics still apply, including code=true.
        spans = [dict(kind='text', text='{{literal}}', trail='', code=True)]
        self.assertEqual([], list(audit.action_fields(spans)))
        self.assertEqual(['source-markup'], audit.diagnostic_categories(list(audit.text_fields(spans))[0][1]))

    def test_split_fragment_and_image_map_destinations_follow_native_action_paths(self):
        with Fixture() as f:
            entry = f.entry('map', 'clean', language='English')
            region = dict(kind='internal', target='term', target_fragment='{{section}}', label='visible')
            default = dict(kind='external', target='https://example.test/{{page}}', label='fallback')
            image_map = dict(regions=[dict(shape='rectangle', coordinates=[0, 0, 2, 2], action=region)],
                             default_action=default)
            entry['sections'] = [dict(blocks=[dict(spans=[
                dict(kind='link', text='word', target='word', target_fragment='{{heading}}'),
                dict(kind='text', text='', image=dict(file='Map.png', map=image_map)),
                dict(kind='link', text='clean', target='word', target_fragment='%7B%7Bencoded%7D%7D'),
            ])])]
            entry['metadata'] = dict(kind='internal', target='{{not an action}}', target_fragment='{{ignored}}')
            f.language('English', [entry])
            result = audit.scan(f.root, f.query)
            self.assertEqual('failed', result['status'])
            self.assertEqual({'[0].target_fragment', '[1].image.map.regions[0].action.target_fragment',
                              '[1].image.map.default_action.target'},
                             {issue['path'].split('.spans')[1] for issue in result['issues']})
            self.assertTrue(all(issue['nonwaivable'] for issue in result['issues']))

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

    def test_repeated_caption_break_preserves_semantics_and_diagnostic_payload(self):
        # Authored witness: {|\n|+ {\n|+ {example}\n| cell\n|}
        # appendTableCaption emits an empty-text semantic break between caption parts.
        def caption_entry(f, spans):
            entry = f.entry('caption', '', language='English')
            entry['sections'] = [dict(blocks=[dict(table=dict(caption=spans,
                rows=[dict(cells=[dict(spans=[dict(kind='text', text='cell', trail='')])])]))])]
            return entry

        for stored_break in ('', '\n'):
            with self.subTest(stored_break=stored_break), Fixture() as f:
                entry = caption_entry(f, [dict(kind='text', text='{', trail=''),
                    dict(kind='line_break', text=stored_break, trail=''),
                    dict(kind='text', text='{example}', trail='')])
                f.language('English', [entry])
                result = audit.scan(f.root, f.query)
                self.assertEqual(1, result['records'])
                self.assertTrue(result['scan_complete'])
                self.assertEqual([], result['issues'])
                self.assertEqual('passed', result['status'])

        # A semantic break must not hide real artifacts in nonempty text or trail.
        with Fixture() as f:
            entry = caption_entry(f, [dict(kind='line_break', text='{{stored}}',
                trail=' __NOEDITSECTION__', code=True)])
            f.language('English', [entry])
            result = audit.scan(f.root, f.query)
            self.assertEqual('failed', result['status'])
            self.assertEqual(1, len(result['issues']))
            self.assertEqual(['source-markup', 'behavior-switch'], result['issues'][0]['categories'])
            self.assertIn('{{stored}} __NOEDITSECTION__', result['issues'][0]['text'])

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

    def run_report(self, text=None, error=None, compressed=False):
        with Fixture() as f:
            if text is not None: f.language('English', [f.entry('fixture', text, language='English')])
            report = f.root / ('audit.json.gz' if compressed else 'audit.json')
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
            raw = report.read_bytes()
            if compressed:
                raw = gzip.decompress(raw)
            result = json.loads(raw)
            self.assertEqual(raw, (json.dumps(result, ensure_ascii=False, indent=2) + '\n').encode())
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

    def test_compressed_cli_report_preserves_all_three_outcomes(self):
        for kwargs in ({'text': 'სიტყვა'}, {'text': '{{მცდარი}}'}, {'error': OSError('missing binary')}):
            with self.subTest(kwargs=kwargs):
                self.assertEqual(self.run_report(**kwargs), self.run_report(**kwargs, compressed=True))

    def test_report_larger_than_one_write_preserves_exact_bytes(self):
        result = {'issues': [{'title': f'词{n}', 'text': 'მცდარი\n[[target]]'} for n in range(2050)]}
        expected = (json.dumps(result, ensure_ascii=False, indent=2) + '\n').encode()
        with tempfile.TemporaryDirectory() as folder:
            for name in ('result.json', 'result.json.gz'):
                target = Path(folder, name)
                audit.write_report(target, result)
                actual = target.read_bytes()
                self.assertEqual(gzip.decompress(actual) if name.endswith('.gz') else actual, expected)

    def test_diagnostic_spools_preserve_order_counts_and_unicode_at_batch_boundaries(self):
        for codec in (None, audit.zstd):
            with self.subTest(codec=codec), mock.patch.object(audit, 'zstd', codec), ExitStack() as resources:
                for size in (0, 1, 128, 129, 256, 257):
                    rows = audit.ReportRows(resources)
                    expected = [{'title': f'𛀀 {n}', 'text': 'line\n\"ქართული\"' * 14} for n in range(size)]
                    for row in expected:
                        rows.append(row)
                    self.assertEqual(len(rows), size)
                    self.assertLessEqual(len(rows.pending), 128)
                    self.assertEqual(''.join(audit.report_chunks({'issues': rows})),
                                     json.dumps({'issues': expected}, ensure_ascii=False, indent=2) + '\n')

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


class BatchExportBoundaryTests(unittest.TestCase):
    def test_previous_decoded_response_is_released_before_next_native_or_fallback_response(self):
        import weakref
        original_loads = json.loads
        class Response(dict):
            pass
        for fallback in (False, True):
            refs = []
            queries = ['a' * 65537, 'b' * 65537] if fallback else ['one', 'two']
            def observe(value):
                if refs:
                    self.assertIsNone(refs[-1](), 'previous decoded response overlaps the next response')
                answer = Response(value)
                refs.append(weakref.ref(answer))
                return answer
            def decode(line):
                return observe(original_loads(line))
            def single(*parts):
                return observe(dict(query=parts[-1], entries=[]))
            class Child:
                pid = 123
                def __init__(self, argv, **kw):
                    for title in queries:
                        row = dict(schema='dict.results.v1', operation='lookup', query=title,
                                   match_mode='exact-utf8', entries=[])
                        kw['stdout'].write(json.dumps(row).encode() + b'\n')
                def wait(self, timeout=None): return 0
            with mock.patch.object(audit.subprocess, 'Popen', Child), mock.patch.object(audit, 'process_birth', return_value=42), \
                 mock.patch.object(audit.json, 'loads', side_effect=decode), mock.patch.object(audit, 'cli_query', side_effect=single):
                stream = audit.batch_exports(Path('/binary'), Path('/root'), [], [dict(title=q) for q in queries], 2, lambda: None)
                first = next(stream); self.assertEqual(queries[0], first['query']); del first
                second = next(stream); self.assertEqual(queries[1], second['query']); del second
                with self.assertRaises(StopIteration): next(stream)
                self.assertIsNone(refs[-1]())
                self.assertEqual(2, len(refs))

    def test_guard_refuses_member_replacement_edit_symlink_swap_and_membership(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / 'root'; root.mkdir()
            data = root / 'a.wikblb'; data.write_bytes(b'first')
            before = audit.dictionary_snapshot(root)
            data.write_bytes(b'other')
            self.assertNotEqual(before, audit.dictionary_snapshot(root))
            data.unlink(); data.write_bytes(b'first')
            self.assertNotEqual(before, audit.dictionary_snapshot(root))
            link = root / 'link'; link.symlink_to(data)
            current = audit.dictionary_snapshot(root)
            link.unlink(); link.symlink_to('a.wikblb')
            self.assertNotEqual(current, audit.dictionary_snapshot(root))
            current = audit.dictionary_snapshot(root)
            (root / '.incomplete').write_bytes(b'')
            self.assertNotEqual(current, audit.dictionary_snapshot(root))

    def test_shared_ancestor_replaced_during_walk_rejects_same_target(self):
        with tempfile.TemporaryDirectory() as d:
            parent = Path(d)
            real = parent / 'real'
            (real / 'edition').mkdir(parents=True)
            (real / 'edition' / 'entry').write_bytes(b'unchanged')
            link = parent / 'current'
            link.symlink_to(real, target_is_directory=True)
            replacement = parent / 'replacement'
            replacement.symlink_to(real, target_is_directory=True)
            root = link / 'edition'
            listdir = audit.os.listdir

            def list_and_replace(path):
                names = listdir(path)
                if path == root:
                    replacement.replace(link)
                return names

            with mock.patch.object(audit.os, 'listdir', list_and_replace):
                with self.assertRaisesRegex(audit.ScanError, 'ancestor changed'):
                    audit.dictionary_snapshot(root)

    def test_prepared_derived_index_writes_do_not_change_published_source_snapshot(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); (root/'a.wikblb').write_bytes(b'source')
            audit.prepare_index_directories(root)
            before = audit.dictionary_snapshot(root)
            (root/'.dict-cache'/'a.idx').write_bytes(b'derived')
            self.assertEqual(before, audit.dictionary_snapshot(root))

    def test_batch_stream_retains_duplicate_unicode_dash_queries_and_rejects_extra(self):
        responses = [dict(schema='dict.results.v1', operation='lookup', query=q,
                          match_mode='exact-utf8', entries=[dict(title=q)]) for q in ['猫', '-dash', '猫']]
        class Child:
            pid = 123
            def __init__(self, argv, **kw):
                self.argv = argv
                self.spool = kw['stdout']
                self.spool.write(b''.join(json.dumps(x, ensure_ascii=False).encode()+b'\n' for x in responses))
            def wait(self, timeout=None): return 0
        with mock.patch.object(audit.subprocess, 'Popen', Child), mock.patch.object(audit, 'process_birth', return_value=42):
            got = list(audit.batch_exports(Path('/binary'), Path('/root'), ['--kind','language'],
                       [dict(title=x) for x in ['猫','-dash','猫']], 3, lambda: None))
            self.assertEqual(responses, got)
            with self.assertRaises(audit.ScanError):
                list(audit.batch_exports(Path('/binary'), Path('/root'), [], [dict(title='猫')], 1, lambda: None))

    def test_compressed_batch_roundtrips_in_memory_and_after_spill(self):
        line = 'paalunan (BH) 猫\n'.encode()
        payload = line * 50000
        command = [sys.executable, '-c', f'import sys; sys.stdout.buffer.write({line!r} * 50000)']
        spool = tempfile.SpooledTemporaryFile
        for codec in {audit.zstd, None}:
            for limit in (64, len(payload)):
                with self.subTest(codec=codec, limit=limit), spool(max_size=limit) as storage:
                    with mock.patch.object(audit, 'zstd', codec), mock.patch.object(audit.tempfile, 'SpooledTemporaryFile', return_value=storage):
                        with audit.checked_export_stream(command) as result:
                            self.assertEqual(payload, result.read())
                            self.assertEqual(limit == 64, storage._rolled)
                            self.assertLess(storage.tell(), len(payload) // 10)

    def test_failed_and_truncated_batch_never_yields_a_success(self):
        class Child:
            pid = 123
            def __init__(self, argv, **kw): pass
            def wait(self, timeout=None): return 1
        with mock.patch.object(audit.subprocess, 'Popen', Child), mock.patch.object(audit, 'process_birth', return_value=42):
            with self.assertRaisesRegex(audit.ScanError, 'status 1'):
                list(audit.batch_exports(Path('/binary'), Path('/root'), [], [dict(title='missing')], 1, lambda: None))
        Child.wait = lambda self, timeout=None: 0
        with mock.patch.object(audit.subprocess, 'Popen', Child), mock.patch.object(audit, 'process_birth', return_value=42):
            with self.assertRaisesRegex(audit.ScanError, 'incomplete'):
                list(audit.batch_exports(Path('/binary'), Path('/root'), [], [dict(title='missing')], 1, lambda: None))

    def test_source_guard_failure_happens_before_any_child_launch(self):
        def changed(): raise audit.ScanError('changed')
        with mock.patch.object(audit.subprocess, 'Popen') as spawn:
            with self.assertRaisesRegex(audit.ScanError, 'changed'):
                list(audit.batch_exports(Path('/binary'), Path('/root'), [], [dict(title='cat')], 1, changed))
            spawn.assert_not_called()

    def test_timeout_signals_only_same_birth_owned_child_and_waits(self):
        class Child:
            pid = 123
            def __init__(self, argv, **kw): self.calls = 0; self.killed = False
            def wait(self, timeout=None):
                self.calls += 1
                if self.calls == 1: raise subprocess.TimeoutExpired('export', 60)
                return -9
            def poll(self): return None
            def kill(self): self.killed = True
        child = Child([])
        with mock.patch.object(audit.subprocess, 'Popen', return_value=child), mock.patch.object(audit, 'process_birth', return_value=42):
            with self.assertRaises(subprocess.TimeoutExpired):
                list(audit.batch_exports(Path('/binary'), Path('/root'), [], [dict(title='cat')], 1, lambda: None))
        self.assertTrue(child.killed)
        self.assertEqual(child.calls, 2)
        child = Child([])
        with mock.patch.object(audit.subprocess, 'Popen', return_value=child), mock.patch.object(audit, 'process_birth', side_effect=[42,43]):
            with self.assertRaisesRegex(audit.ScanError, 'identity changed'):
                list(audit.batch_exports(Path('/binary'), Path('/root'), [], [dict(title='cat')], 1, lambda: None))
        self.assertFalse(child.killed)
        self.assertEqual(child.calls, 2)

    def test_guard_rejects_file_edit_then_restore_and_directory_link_retarget(self):
        with tempfile.TemporaryDirectory() as d:
            parent = Path(d); a = parent/'a'; b = parent/'b'; a.mkdir(); b.mkdir()
            (a/'entry.wikblb').write_bytes(b'first'); (b/'entry.wikblb').write_bytes(b'first')
            root = parent/'view'; root.symlink_to(a, target_is_directory=True)
            before = audit.dictionary_snapshot(root)
            (a/'entry.wikblb').write_bytes(b'other'); (a/'entry.wikblb').write_bytes(b'first')
            self.assertNotEqual(before, audit.dictionary_snapshot(root))
            before = audit.dictionary_snapshot(root)
            root.unlink(); root.symlink_to(b, target_is_directory=True)
            self.assertNotEqual(before, audit.dictionary_snapshot(root))

    def test_birth_read_failures_always_join_without_unproved_signal(self):
        class Child:
            pid = 123
            def __init__(self): self.waits = 0; self.killed = False
            def wait(self, timeout=None):
                self.waits += 1
                if timeout is not None: raise subprocess.TimeoutExpired('export', timeout)
                return 0
            def poll(self): return None
            def kill(self): self.killed = True
        for births, waits in [([OSError('initial birth unavailable')], 1),
                              ([42, OSError('timeout birth unavailable')], 2)]:
            child = Child()
            with mock.patch.object(audit.subprocess, 'Popen', return_value=child), mock.patch.object(audit, 'process_birth', side_effect=births):
                with self.assertRaisesRegex(OSError, 'birth unavailable'):
                    list(audit.batch_exports(Path('/binary'), Path('/root'), [], [dict(title='cat')], 1, lambda: None))
            self.assertEqual(child.waits, waits)
            self.assertFalse(child.killed)


    def test_transient_published_members_and_cache_routes_cannot_evade_guard(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); (root/'a.wikblb').write_bytes(b'source')
            audit.prepare_index_directories(root)
            before = audit.dictionary_snapshot(root)
            member = root/'aliases.wikblb'; member.write_bytes(b'transient'); member.unlink()
            self.assertNotEqual(before, audit.dictionary_snapshot(root))
            before = audit.dictionary_snapshot(root)
            cache = root/'.dict-cache'; cache.rmdir(); cache.symlink_to(root, target_is_directory=True)
            with self.assertRaises(audit.ScanError): audit.dictionary_snapshot(root)

    def test_cache_preparation_rejects_foreign_routes_and_allows_readonly_no_cache(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            cache = root/'.dict-cache'; cache.write_bytes(b'not a directory')
            with self.assertRaises(audit.ScanError): audit.prepare_index_directories(root)
            cache.unlink(); cache.symlink_to(root, target_is_directory=True)
            with self.assertRaises(audit.ScanError): audit.prepare_index_directories(root)
            cache.unlink()
            with mock.patch.object(Path, 'mkdir', side_effect=PermissionError('read only')):
                audit.prepare_index_directories(root)
            self.assertFalse(cache.exists())
            self.assertEqual(audit.dictionary_snapshot(root), audit.dictionary_snapshot(root))


    def test_batch_scan_retains_alias_owner_pagination_report_and_strictness(self):
        with Fixture() as f:
            target = f.entry('destination', '__NOEDITSECTION__', language='English')
            alias = dict(target, redirect=dict(source_title='-alias', target_title='destination', fragment='', followed=True))
            f.language('English', [target], aliases={'-alias': alias})
            f.language('French', [f.entry('destination', 'Lua error', language='French')])
            f.feature('supplemental', [f.entry('Appendix:X', 'plain', kind='supplemental')])
            f.page_size = 1
            ordinary = audit.scan(f.root, f.query)
            def pages(selection, matches):
                for match in matches:
                    yield f.query('export', *selection, '--case-sensitive', '--', match['title'])
            self.assertEqual(ordinary, audit.scan(f.root, f.query, pages))
            self.assertEqual(ordinary['alias_views'], 1)
            self.assertEqual(ordinary['duplicate_destinations'], 1)
            def foreign(selection, matches):
                for response in pages(selection, matches):
                    yield dict(response, language='foreign')
            with self.assertRaisesRegex(audit.ScanError, 'selection owner mismatch'):
                audit.scan(f.root, f.query, foreign)
            def extra(selection, matches):
                yield from pages(selection, matches)
                yield {}
            with self.assertRaisesRegex(audit.ScanError, 'extra batch export'):
                audit.scan(f.root, f.query, extra)

    def test_confirmed_feature_reference_preserves_report_and_refuses_conflicts(self):
        with Fixture() as f:
            token = 'a' * 64
            target = f.entry('Appendix:X', '__NOEDITSECTION__', kind='supplemental')
            edge = dict(source_title='alias', target_title='Appendix:X', fragment='section', followed=True)
            alias = dict(target, redirect=edge)
            for owner in ('English', 'French'):
                f.language(owner, [f.entry('word', 'plain', language=owner)], aliases={'alias': alias})
            f.feature('supplemental', [target])
            expected = audit.scan(f.root, f.query)

            def exports(mode):
                def run(selection, matches):
                    for match in matches:
                        title = match['title']
                        response = f.query('export', *selection, '--case-sensitive', '--', title)
                        if title == 'alias':
                            response = dict(response, audit_reference=token)
                            if selection[-1] == 'French':
                                if mode == 'conflict':
                                    response['audit_reference'] = 'b' * 64
                                    response['entries'] = [dict(alias, title=target['title'], preamble_spans=[])]
                                else:
                                    response['audit_reference'] = 'b' * 64 if mode == 'unknown' else token
                                    response['entries'] = []
                                    response['audit_reused'] = dict(kind='supplemental', title=target['title'], redirect=edge)
                        yield response
                return run

            self.assertEqual(expected, audit.scan(f.root, f.query, exports('good'), audit_references=True))
            with self.assertRaisesRegex(audit.ScanError, 'unknown or conflicting destination reference'):
                audit.scan(f.root, f.query, exports('unknown'), audit_references=True)
            with self.assertRaisesRegex(audit.ScanError, 'conflicting duplicate destination'):
                audit.scan(f.root, f.query, exports('conflict'), audit_references=True)


if __name__ == '__main__':
    unittest.main()
