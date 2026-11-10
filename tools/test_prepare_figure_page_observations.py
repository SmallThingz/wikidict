import copy
import json
import os
from pathlib import Path
import tempfile
import unittest

import prepare_figure_page_observations as observed

FIXTURES = Path(os.environ.get('WIKIDICT_FIGURE_PAGE_FIXTURE_ROOT', Path(__file__).parent / 'testdata' / 'figure-page-observations'))


def inputs(language='it'):
    folder = FIXTURES / language
    return tuple((folder / name).read_bytes() for name in (
        'figure-page-observations.json', 'namespace-registry.tsv', 'figure-siteinfo.raw.json'))


def mutate(raw, change):
    value = observed.decode(raw)
    change(value)
    return observed.encoded(value)


class ObservationContractTest(unittest.TestCase):
    def test_two_real_supplied_pages_preserve_distinct_capabilities_and_revision_context(self):
        for language, page_id, revision, records in (('it', 4075, 3935048, 2), ('hsb', 332, 18318, 1)):
            with self.subTest(language=language):
                doc = observed.validate_document(*inputs(language))
                page = doc['pages'][0]
                self.assertEqual((page['page_id'], page['revision_id'], len(page['occurrences'])), (page_id, revision, records))
                self.assertIsNone(observed.decode(page['response'])['parse'].get('revid'))
                self.assertEqual({(x['width'], x['anchor_attributes']) for x in page['occurrences']},
                                 {(True, False)} if language == 'it' else {(False, True)})

    def test_offline_pack_verify_complete_and_capture_inventory_preserve_original_artifacts(self):
        for language in ('it', 'hsb'):
            with self.subTest(language=language), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / 'packed'
                source = FIXTURES / language
                record = observed.pack(source / observed.SNAPSHOT, source / 'namespace-registry.tsv',
                                       source / 'figure-siteinfo.raw.json', root)
                self.assertEqual(observed.validate_snapshot(root / observed.SNAPSHOT, language + 'wiktionary', '20261001'), record)
                inventory = observed.capture_artifacts(root / observed.SNAPSHOT, record)
                self.assertEqual(set(inventory), {observed.SNAPSHOT, observed.NAMESPACE, observed.DEFAULTS, observed.MANIFEST, observed.COMPLETE})
                self.assertEqual((root / observed.SNAPSHOT).read_bytes(), (source / observed.SNAPSHOT).read_bytes())
                self.assertEqual(record['output_sha256'], observed.digest((source / observed.SNAPSHOT).read_bytes()))
                with self.assertRaises(FileExistsError):
                    observed.pack(source / observed.SNAPSHOT, source / 'namespace-registry.tsv', source / 'figure-siteinfo.raw.json', root)

    def test_namespace_defaults_edition_and_duplicate_page_refuse(self):
        raw, namespace, defaults = inputs()
        for bad_namespace, bad_defaults in ((namespace + b'\n', defaults), (namespace, defaults + b'\n')):
            with self.assertRaisesRegex(ValueError, 'identity'):
                observed.validate_document(raw, bad_namespace, bad_defaults)
        for change in (
                lambda d: d.update(schema='unknown'),
                lambda d: d.update(wiki='https://other.example'),
                lambda d: d['pages'].append(copy.deepcopy(d['pages'][0])),
                lambda d: d['pages'][0].update(page_id=0),
                lambda d: d['pages'][0].update(revision_id=0)):
            with self.subTest(change=change), self.assertRaises(ValueError):
                observed.validate_document(mutate(raw, change), namespace, defaults)

    def test_changed_request_form_receipt_or_full_echo_cannot_borrow_acceptance(self):
        raw, namespace, defaults = inputs()
        for key in ('request', 'form_body', 'response'):
            def change(doc):
                doc['pages'][0][key] += ' '
            with self.subTest(key=key), self.assertRaises(ValueError):
                observed.validate_document(mutate(raw, change), namespace, defaults)
        # Receipt acceptance/status is checked semantically in the next control;
        # harmless JSON whitespace is not an evidence identity supplied here.

    def test_failed_status_warning_wrong_title_and_missing_complete_html_refuse(self):
        raw, namespace, defaults = inputs()
        def framed(doc, part, modify):
            page = doc['pages'][0]
            value = observed.decode(page[part]); modify(value)
            page[part] = observed.encoded(value).decode()
            receipt = observed.decode(page['receipt'])
            if part == 'response':
                receipt['response'].update(bytes=len(page[part].encode()), sha256=observed.digest(page[part].encode()))
            else:
                receipt.update(accepted=False)
            page['receipt'] = observed.encoded(receipt).decode()
        for part, change in (
                ('receipt', lambda d: d.update(status=429)),
                ('response', lambda d: d.update(warnings={'parse': {'*': 'warning retained'}})),
                ('response', lambda d: d['parse'].update(title='other')),
                ('response', lambda d: d['parse'].update(wikitext='partial')),
                ('response', lambda d: d['parse'].update(text=''))):
            with self.subTest(part=part, change=change), self.assertRaises(ValueError):
                observed.validate_document(mutate(raw, lambda d: framed(d, part, change)), namespace, defaults)

    def test_occurrence_tuple_overlap_missing_capability_and_unknown_fields_refuse(self):
        raw, namespace, defaults = inputs()
        for change in (
                lambda d: d['pages'][0]['occurrences'].append(copy.deepcopy(d['pages'][0]['occurrences'][0])),
                lambda d: d['pages'][0]['occurrences'][0].update(width=False),
                lambda d: d['pages'][0]['occurrences'][0].update(start=-1),
                lambda d: d['pages'][0]['occurrences'][0].update(end=1000000),
                lambda d: d['pages'][0]['occurrences'][0].update(original_width=0),
                lambda d: d['pages'][0]['occurrences'][0].update(width=True, extra='untyped grant')):
            with self.subTest(change=change), self.assertRaises(ValueError):
                observed.validate_document(mutate(raw, change), namespace, defaults)

    def test_duplicate_json_keys_and_symbolic_or_changed_capture_files_refuse(self):
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            observed.decode(b'{"x":1,"x":2}')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = FIXTURES / 'it'
            observed.pack(source / observed.SNAPSHOT, source / 'namespace-registry.tsv', source / 'figure-siteinfo.raw.json', root / 'packed')
            path = root / 'packed' / observed.SNAPSHOT
            original = path.read_bytes(); path.write_bytes(original + b'\n')
            with self.assertRaisesRegex(ValueError, 'descriptor'):
                observed.validate_snapshot(path)
            path.unlink(); path.symlink_to(source / observed.SNAPSHOT)
            with self.assertRaisesRegex(ValueError, 'regular'):
                observed.validate_snapshot(path)


if __name__ == '__main__':
    unittest.main()
