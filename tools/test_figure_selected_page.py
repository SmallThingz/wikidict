import copy
import json
import unittest
from urllib.parse import parse_qs, urlsplit

import prepare_figure_metadata as figure
from test_prepare_figure_files import FigureFileTests


class SelectedPageFigureTests(unittest.TestCase):
    setUp = FigureFileTests.setUp
    write_projection = FigureFileTests.write_projection
    inventory = FigureFileTests.inventory
    args = FigureFileTests.args
    response = FigureFileTests.response

    def selection(self, names):
        text = 'Original page\n' + '\n'.join('[[' + name + '|thumb|caption]]' for name in names)
        raw = text.encode()
        occurrences = []
        position = 0
        for name in names:
            token = ('[[' + name).encode()
            start = raw.index(token, position)
            end = start + len(token)
            occurrences.append(dict(start=start, end=end, file=name))
            position = end
        page = dict(wiki=self.wiki, date=self.date, page_id=1, revision_id=42,
                    title='Original', source_wikitext=text, source_sha256=figure.digest(raw),
                    occurrences=occurrences)
        path = self.root / 'selected-page.json'
        path.write_bytes(figure.encoded(page))
        return page, path

    def capture(self):
        names = ['ملف:Example.svg', 'ملف:Missing.svg']
        args = self.args(links=('Example.svg', 'Missing.svg', 'Unselected.svg'))
        page, args.page_selection = self.selection(names)
        calls = []
        def transport(url, timeout):
            titles = parse_qs(urlsplit(url).query)['titles'][0].split('|')
            calls.append(titles)
            value = self.response(names[0])
            value['query']['pages'].append(dict(ns=6, title=names[1], missing=True, imagerepository=''))
            return 200, {}, figure.encoded(value)
        manifest = figure.capture_files(args, transport=transport, sleep=lambda _: None)
        return args, page, calls, manifest

    def test_actual_capture_replays_only_selected_positive_and_negative(self):
        args, page, calls, manifest = self.capture()
        self.assertEqual(calls, [['ملف:Example.svg', 'ملف:Missing.svg']])
        self.assertEqual(manifest['coverage']['files'], 2)
        self.assertEqual(manifest['coverage']['eligible'], 1)
        self.assertEqual(manifest['coverage']['missing'], 1)
        self.assertFalse(manifest['coverage']['file_inventory_complete'])
        self.assertFalse(manifest['coverage']['whole_edition_occurrence_coverage'])
        self.assertEqual(manifest['coverage']['selected_page']['source_sha256'], page['source_sha256'])
        self.assertEqual(figure.verify(args.output), manifest)
        inventory = figure.inventory_document(args.output / figure.INVENTORY)
        self.assertIn('ملف:Unselected.svg', inventory['catalogue']['titles'])
        self.assertNotIn('ملف:Unselected.svg', inventory['titles'])
        batches = list(figure.stream_values(args.output / figure.ROLES['figure-sizing-raw'], figure.RAW_STREAM_SCHEMA))
        expected = self.response('ملف:Example.svg')
        expected['query']['pages'].append(dict(ns=6, title='ملف:Missing.svg', missing=True, imagerepository=''))
        self.assertEqual(batches[1]['response'], figure.encoded(expected).decode())
        self.assertTrue((args.output / 'file-metadata.response-000001-01.receipt.json').is_file())
        paths = {role: args.output / name for role, name in {**figure.ROLES, 'file-metadata': figure.PROVIDER}.items()}
        identity = manifest['coverage']['selected_page']
        with self.assertRaisesRegex(ValueError, 'exact page identity'):
            figure.verify_tuple(paths, self.wiki, self.date)
        for field, value in [('page_id', 2), ('page_id', True), ('revision_id', 43), ('source_sha256', '0'*64)]:
            with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, 'exact page identity'):
                figure.verify_tuple(paths, self.wiki, self.date, selected_page={**identity, field: value})
        verified = figure.verify_tuple(paths, self.wiki, self.date, selected_page=identity)
        self.assertEqual(verified['figure-sizing'][0]['coverage']['selected_page'], identity)
        geometry = {role: path for role, path in paths.items() if role in figure.ROLES}
        self.assertEqual(set(figure.verify_tuple(geometry, self.wiki, self.date, selected_page=identity)), set(figure.ROLES))
        with self.assertRaisesRegex(ValueError, 'exact page identity'):
            figure.verify_tuple(geometry, self.wiki, self.date)
        provider = args.output / figure.PROVIDER
        original = provider.read_bytes()
        provider.write_bytes(original + b'forged')
        with self.assertRaises(ValueError):
            figure.verify_tuple(geometry, self.wiki, self.date, selected_page=identity)
        provider.write_bytes(original)

    def test_page_hash_ranges_identity_and_catalogue_membership_refuse(self):
        args = self.args(links=('Example.svg',))
        catalogue = figure.selected_inventory(args, self.namespace.read_bytes())
        page, _ = self.selection(['ملف:Example.svg'])
        mutations = []
        for key, value in [('wiki', 'plwiktionary'), ('date', '20261002'), ('page_id', True),
                           ('revision_id', 0), ('title', ''), ('source_sha256', '0'*64),
                           ('source_wikitext', page['source_wikitext']+'!')]:
            bad = copy.deepcopy(page); bad[key] = value; mutations.append(bad)
        for key, value in [('start', True), ('end', 1), ('file', 'ملف:Foreign.svg')]:
            bad = copy.deepcopy(page); bad['occurrences'][0][key] = value; mutations.append(bad)
        for bad in mutations:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                figure.selected_page_inventory(catalogue, bad, self.namespace.read_bytes(), self.wiki, self.date)
        missing, _ = self.selection(['ملف:Absent.svg'])
        with self.assertRaisesRegex(ValueError, 'absent'):
            figure.selected_page_inventory(catalogue, missing, self.namespace.read_bytes(), self.wiki, self.date)

    def test_duplicate_occurrences_share_one_file_and_keep_source_order(self):
        args = self.args()
        catalogue = figure.selected_inventory(args, self.namespace.read_bytes())
        page, _ = self.selection(['ملف:Example.svg', 'ملف:Example.svg'])
        result = figure.selected_page_inventory(catalogue, page, self.namespace.read_bytes(), self.wiki, self.date)
        self.assertEqual(result['titles'], ['ملف:Example.svg'])
        self.assertEqual(len(result['selected_page']['occurrences']), 2)
        page['occurrences'].reverse()
        with self.assertRaises(ValueError):
            figure.selected_page_inventory(catalogue, page, self.namespace.read_bytes(), self.wiki, self.date)

    def test_catalogue_and_coverage_cannot_be_relabelled_full(self):
        args, _, _, manifest = self.capture()
        path = args.output / figure.INVENTORY
        original = path.read_bytes()
        changed = json.loads(original)
        changed['catalogue']['titles'].remove('ملف:Unselected.svg')
        path.write_bytes(figure.encoded(changed))
        with self.assertRaises(ValueError): figure.verify(args.output)
        path.write_bytes(original)
        path = args.output / figure.MANIFEST
        changed = copy.deepcopy(manifest)
        changed['coverage']['file_inventory_complete'] = True
        path.write_bytes(figure.encoded(changed))
        with self.assertRaises(ValueError): figure.verify(args.output, require_complete=False)

    def test_selected_page_rejects_query_log_widening_before_http(self):
        args = self.args()
        _, args.page_selection = self.selection(['ملف:Example.svg'])
        log = self.root / 'extra.log'; log.write_text('unrelated')
        args.log = [log]
        calls = []
        with self.assertRaisesRegex(ValueError, 'extra query logs'):
            figure.capture_files(args, transport=lambda *a: calls.append(a), sleep=lambda _: None)
        self.assertEqual(calls, [])
        self.assertFalse(args.output.exists())

    def test_real_transport_refusal_stays_failure_without_marker_or_retry(self):
        args = self.args()
        _, args.page_selection = self.selection(['ملف:Example.svg'])
        calls = []
        def transport(*a):
            calls.append(a)
            return 403, {'content-type': 'text/plain'}, b'Forbidden'
        with self.assertRaises(ValueError):
            figure.capture_files(args, transport=transport, sleep=lambda _: None)
        self.assertEqual(len(calls), 1)
        self.assertFalse((args.output / figure.COMPLETE).exists())
        receipt = json.loads((args.output / 'file-metadata.response-000001-01.receipt.json').read_bytes())
        self.assertEqual(receipt['status'], 403)
        self.assertFalse(receipt['accepted'])
