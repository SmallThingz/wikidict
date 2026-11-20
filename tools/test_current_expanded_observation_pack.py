"""Offline normal packaging of an independent current expanded-operation witness."""
import copy
import json
import os
from pathlib import Path
import tempfile
import unittest

import prepare_figure_page_observations as observed


def fixture():
    namespace = b'# controlled packaging namespace\n'
    defaults = observed.encoded({'wiki': 'huwiktionary', 'query': {'defaultoptions': {
        'skin': 'vector-2022', 'language': 'hu', 'vector-theme': 'day'}}})
    title = 'v\u00edz'
    url = 'https://hu.wiktionary.org/wiki/v%C3%ADz'
    css_url = 'https://hu.wiktionary.org/w/load.php?lang=hu&modules=site.styles&only=styles&skin=vector-2022'
    config = dict(wgArticleId=609, wgRevisionId=3518053, wgCurRevisionId=3518053,
                  wgNamespaceNumber=0, wgTitle=title, wgPageName=title, wgAction='view', wgIsArticle=True)
    prefix = ('<!DOCTYPE html><html class="client-nojs skin-theme-clientpref-day"><head>'
              '<script>RLCONF=' + json.dumps(config) + ';</script><link rel="stylesheet" href="' + css_url + '">'
              '</head><body class="skin-vector-2022"><div class="mw-parser-output">')
    span = '<span style="display:inline-block">2</span>'
    expanded = '\u00e9\n' + span
    response = prefix + span + '</div></body></html>'
    def source(text, url, mime):
        return dict(bytes=len(text.encode()), sha256=observed.digest(text.encode()), url=url, final_url=url,
                    status=200, headers={'content-type': mime}, source_path='controlled', file='response',
                    retrieved_utc='2026-11-20T00:00:00Z')
    html_source = source(response, url, 'text/html; charset=UTF-8')
    html_source.update(accepted=True, response_complete=True, unknown_response_outcome=False, request_count=1,
                       accept_encoding='gzip', content_encoding='gzip', encoded=dict(bytes=32, path='/controlled/encoded', sha256='1' * 64))
    html_source['headers']['content-encoding'] = 'gzip'
    receipt = lambda sources: json.dumps(dict(core=None, sources=sources, unrequested=[], historical_equality_proven=False))
    raw = '{{controlled}}'
    operation = dict(transport=dict(profile='source-parent-direct-get-v1',
        page=dict(id=609, revision=3518053, namespace=0, title=title, model='wikitext',
                  raw_sha256=observed.digest(raw.encode()), expanded_sha256=observed.digest(expanded.encode())),
        mode='current-canonical', response_kind='complete-response', response=response, prefix=prefix,
        receipt=receipt([html_source]), styles=None),
        temporal_scope='current_anonymous_associated_retained_source', historical_equality_proven=False,
        javascript_outcome_proven=False, raw_source=raw, expanded_source=expanded, display_title='',
        missing_dependency_metadata=json.dumps(dict(schema='wikidict.missing-dependency-phase.v1',
            output_sha256=observed.digest(expanded.encode()), display_title_sha256=observed.digest(b''),
            occurrences=[dict(id=1, title='Sablon:missing')], output=dict(ranges=[], unknown=True),
            display_title=dict(ranges=[], unknown=False))), start=len('\u00e9\n'.encode()), end=len(expanded.encode()),
        captured_styles=dict(responses=['.x{color:red}'], receipt=receipt([source('.x{color:red}', css_url, 'text/css')])),
        indexed_sources=[dict(base_url='', byte_start=0, css_sha256=observed.digest(b'.other{}'), unknown_applicability=False)])
    doc = dict(schema='wikidict.figure-page-observations.v8', wiki='huwiktionary', date='20261001',
               namespace_sha256=observed.digest(namespace), defaults_sha256=observed.digest(defaults),
               pages=[], current_get_expanded_operations=[operation])
    return doc, namespace, defaults


class CurrentExpandedObservationPackTest(unittest.TestCase):
    def validate(self, doc, namespace=None, defaults=None):
        _, ns, df = fixture()
        return observed.validate_document(observed.encoded(doc), ns if namespace is None else namespace, df if defaults is None else defaults)

    def test_normal_pack_round_trip_preserves_unknown_and_all_source_bytes(self):
        doc, ns, defaults = fixture(); raw = observed.encoded(doc)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, body in [('input.json', raw), ('namespace.tsv', ns), ('defaults.json', defaults)]:
                (root / name).write_bytes(body)
            record = observed.pack(root / 'input.json', root / 'namespace.tsv', root / 'defaults.json', root / 'packed')
            self.assertEqual((root / 'packed' / observed.SNAPSHOT).read_bytes(), raw)
            self.assertEqual(observed.validate_snapshot(root / 'packed' / observed.SNAPSHOT), record)
            self.assertIn('no historical or JavaScript equivalence', record['source_contract'])
            phase = json.loads(doc['current_get_expanded_operations'][0]['missing_dependency_metadata'])
            self.assertIs(phase['output']['unknown'], True)

    def test_field_does_not_relax_other_schemas_or_duplicate_identities(self):
        for version in (1, 4, 7, 9, 10, 11):
            doc, _, _ = fixture(); doc['schema'] = f'wikidict.figure-page-observations.v{version}'
            with self.subTest(version=version), self.assertRaises(ValueError): self.validate(doc)
        doc, _, _ = fixture(); doc['current_get_expanded_operations'] *= 2
        with self.assertRaises(ValueError): self.validate(doc)
        doc, _, _ = fixture(); doc['current_get_expanded_operations'] = []
        with self.assertRaises(ValueError): self.validate(doc)

    def test_source_identity_range_and_temporal_mutations_refuse(self):
        changes = [lambda x: x.update(raw_source='other'), lambda x: x.update(expanded_source='other'),
                   lambda x: x.update(start=1), lambda x: x.update(end=True),
                   lambda x: x.update(historical_equality_proven=True), lambda x: x.update(javascript_outcome_proven=True),
                   lambda x: x['transport']['page'].update(revision=3518054),
                   lambda x: x['transport'].update(mode='historical-oldid'),
                   lambda x: x['transport'].update(styles={}), lambda x: x.update(display_title='changed')]
        for change in changes:
            doc, _, _ = fixture(); change(doc['current_get_expanded_operations'][0])
            with self.subTest(change=change), self.assertRaises((ValueError, UnicodeDecodeError)): self.validate(doc)

    def test_transport_completeness_and_response_binding_refuse(self):
        for key, value in [('accepted', False), ('response_complete', False), ('request_count', 2),
                           ('unknown_response_outcome', True), ('status', 302), ('url', 'https://other.example/wiki/viz')]:
            doc, _, _ = fixture(); transport = doc['current_get_expanded_operations'][0]['transport']
            receipt = json.loads(transport['receipt']); receipt['sources'][0][key] = value
            transport['receipt'] = json.dumps(receipt)
            with self.subTest(key=key), self.assertRaises(ValueError): self.validate(doc)
        doc, _, _ = fixture(); doc['current_get_expanded_operations'][0]['transport']['response'] += 'changed'
        with self.assertRaises(ValueError): self.validate(doc)

    def test_advertised_styles_and_selected_index_are_independent_but_bound(self):
        doc, _, _ = fixture(); self.validate(doc)
        operation = doc['current_get_expanded_operations'][0]
        self.assertNotEqual(operation['indexed_sources'][0]['css_sha256'], observed.digest(operation['captured_styles']['responses'][0].encode()))
        for change in (lambda x: x['captured_styles']['responses'].append('.extra{}'),
                       lambda x: x['captured_styles']['responses'].__setitem__(0, '.changed{}'),
                       lambda x: x['indexed_sources'][0].update(css_sha256='x' * 64),
                       lambda x: x['indexed_sources'][0].update(unknown_applicability=0)):
            bad = copy.deepcopy(doc); change(bad['current_get_expanded_operations'][0])
            with self.assertRaises(ValueError): self.validate(bad)

    def test_missing_overlap_refuses_without_clearing_unknown(self):
        doc, _, _ = fixture(); op = doc['current_get_expanded_operations'][0]
        phase = json.loads(op['missing_dependency_metadata']); phase['output']['ranges'] = [dict(start=op['start'], end=op['end'], id=1)]
        op['missing_dependency_metadata'] = json.dumps(phase)
        with self.assertRaises(ValueError): self.validate(doc)

    @unittest.skipUnless(os.environ.get('WIKIDICT_EXPANDED_OPERATION_FIXTURE'), 'retained ordinary input supplied by guarded qualification')
    def test_retained_hu_operation_normal_pack(self):
        operation = json.loads(Path(os.environ['WIKIDICT_EXPANDED_OPERATION_FIXTURE']).read_text())
        ns = Path(os.environ['WIKIDICT_EXPANDED_NAMESPACE']).read_bytes()
        defaults = Path(os.environ['WIKIDICT_EXPANDED_DEFAULTS']).read_bytes()
        doc = dict(schema='wikidict.figure-page-observations.v8', wiki='huwiktionary', date='20261001',
                   namespace_sha256=observed.digest(ns), defaults_sha256=observed.digest(defaults),
                   pages=[], current_get_expanded_operations=[operation])
        before = observed.encoded(operation)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, body in [('input.json', observed.encoded(doc)), ('namespace.tsv', ns), ('defaults.json', defaults)]:
                (root / name).write_bytes(body)
            observed.pack(root / 'input.json', root / 'namespace.tsv', root / 'defaults.json', root / 'packed')
            packed = observed.decode((root / 'packed' / observed.SNAPSHOT).read_bytes())
            self.assertEqual(observed.encoded(packed['current_get_expanded_operations'][0]), before)
            self.assertTrue(json.loads(operation['missing_dependency_metadata'])['output']['unknown'])


if __name__ == '__main__':
    unittest.main()
