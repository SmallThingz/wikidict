import copy
import gzip
import hashlib
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


class SourceLinkBoundaryTest(unittest.TestCase):
    def test_telaio_nested_caption_keeps_outer_suffix_and_byte_offsets(self):
        # Exact retained token; the historical first-]] lookup stopped at189.
        token = (b'[[File:TRANSPORT SENEGAL USINE SENBUS 17.jpg|thumb|upright|'
                 b"Produzione di '''telai''' per autobus in [[Senegal]] (2).]]")
        source = b'x' * 78 + token + b'\nfollowing source'
        self.assertEqual(observed.source_link_end(source, 78), 196)
        self.assertEqual(source.find(b']]', 78) + 2, 189)
        with self.assertRaisesRegex(ValueError, 'Incomplete'):
            observed.source_link_end(source[:189], 78)
        prefix = '\u00e9\u65e5'.encode()
        self.assertEqual(observed.source_link_end(prefix + token, len(prefix)), len(prefix + token))

    def test_comments_nowiki_and_tag_attributes_do_not_close_link(self):
        for protected in (b'<!-- ]] [[ -->', b'<nowiki>]] [[</nowiki>',
                          b'<NoWiKi a=">">]]</NoWiKi >', b'<nowiki/>',
                          b'<span title="]] [[">caption</span>',
                          b'<ref>]] [[</ref>', b'<math>]]</math>'):
            token = b'[[File:A.jpg|caption ' + protected + b' [[place]] end]]'
            with self.subTest(protected=protected):
                self.assertEqual(observed.source_link_end(token + b' tail', 0), len(token))

    def test_templates_and_parameters_keep_inner_brackets_protected(self):
        for caption in (b'{{x|]]}}', b'{{{x|]]}}}', b'[[place|{{x|]]}}]]'):
            token = b'[[File:A.jpg|' + caption + b' end]]'
            with self.subTest(caption=caption):
                self.assertEqual(observed.source_link_end(token, 0), len(token))

    def test_invalid_pre_extension_boundary_uses_html_attribute_boundary(self):
        token = b'[[File:A.jpg|<pre/foo title="]]">caption end]]'
        self.assertEqual(observed.source_link_end(token, 0), len(token))
        # Ordinary fallback pre is not an opaque strip body.
        token = b'[[File:A.jpg|<pre/foo>]]</pre>tail'
        self.assertEqual(observed.source_link_end(token, 0), token.index(b']]', 2) + 2)

    def test_malformed_start_unclosed_link_and_unclosed_comment_refuse(self):
        for source, start in ((b'File:A.jpg]]', 0), (b'[[File:A.jpg]]', -1),
                              (b'[[File:A.jpg|[[place]]', 0),
                              (b'[[File:A.jpg|<!-- ]]', 0)):
            with self.subTest(source=source, start=start), self.assertRaises(ValueError):
                observed.source_link_end(source, start)
        # An unmatched nowiki opener does not hide the active remainder.
        source = b'[[File:A.jpg|<nowiki>[[place]] end]]'
        self.assertEqual(observed.source_link_end(source, 0), len(source))

    def test_normal_intake_rejects_inner_close_even_with_rehashed_evidence(self):
        raw, namespace, defaults = inputs()
        doc = observed.decode(raw)
        page = doc['pages'][0]
        occurrence = page['occurrences'][0]
        parsed = observed.decode(page['response'])
        original = parsed['parse']['wikitext'].encode()
        # Controlled source/transport rehash tests the boundary, not stale hashes.
        addition = b' [[Senegal]] (2).'
        insertion = occurrence['end'] - 2
        source = original[:insertion] + addition + original[insertion:]
        for row in page['occurrences']:
            if row['start'] >= insertion:
                row['start'] += len(addition)
                row['end'] += len(addition)
        occurrence['end'] += len(addition)
        params = dict(observed.urllib.parse.parse_qsl(page['form_body'], keep_blank_values=True))
        params['text'] = source.decode()
        page['form_body'] = observed.urllib.parse.urlencode(params)
        request = observed.decode(page['request'])
        request['form'].update(bytes=len(page['form_body'].encode()), sha256=observed.digest(page['form_body'].encode()))
        request['text_source'].update(bytes=len(source), sha256=observed.digest(source))
        parsed['parse']['wikitext'] = source.decode()
        page['request'] = observed.encoded(request).decode()
        page['response'] = observed.encoded(parsed).decode()
        receipt = observed.decode(page['receipt'])
        for key in ('request', 'response'):
            receipt[key].update(bytes=len(page[key].encode()), sha256=observed.digest(page[key].encode()))
        page['receipt'] = observed.encoded(receipt).decode()
        self.assertEqual(observed.validate_document(observed.encoded(doc), namespace, defaults), doc)
        occurrence['end'] = insertion + addition.index(b']]') + 2
        with self.assertRaisesRegex(ValueError, 'complete source link'):
            observed.validate_document(observed.encoded(doc), namespace, defaults)


class ObservationContractTest(unittest.TestCase):
    def test_height_only_intake_is_independent_and_preserves_complete_el_response(self):
        raw, namespace, defaults = inputs('el-height')
        doc = observed.validate_document(raw, namespace, defaults)
        self.assertEqual([True, True], [row['height'] for row in doc['pages'][0]['occurrences']])
        self.assertTrue(all(not row['width'] and not row['anchor_attributes'] for row in doc['pages'][0]['occurrences']))
        self.assertEqual(doc, observed.decode(raw))
        for change in ({'height': 1}, {'height': False}, {'width': True}, {'anchor_attributes': True}, {'unknown_height': True}):
            with self.subTest(change=change):
                modified = copy.deepcopy(doc)
                modified['pages'][0]['occurrences'][0].update(change)
                with self.assertRaises(ValueError):
                    observed.validate_document(observed.encoded(modified), namespace, defaults)

    def framed_form(self, target_bytes):
        # Controlled intake evidence, not a newly captured page or sizing fact.
        raw, namespace, defaults = inputs()
        doc = observed.decode(raw)
        page = doc['pages'][0]
        request = observed.decode(page['request'])
        response = observed.decode(page['response'])
        receipt = observed.decode(page['receipt'])
        pairs = observed.urllib.parse.parse_qsl(page['form_body'], keep_blank_values=True)
        params = dict(pairs)
        original_source = params['text']
        original_html = response['parse']['text']
        original_form = observed.urllib.parse.urlencode(params)
        self.assertLess(len(original_form), target_bytes)
        params['text'] += 'a' * (target_bytes - len(original_form))
        page['form_body'] = observed.urllib.parse.urlencode(params)
        self.assertEqual(len(page['form_body'].encode('ascii')), target_bytes)
        request['form'].update(bytes=target_bytes, sha256=observed.digest(page['form_body'].encode('ascii')))
        source = params['text'].encode()
        request['text_source'].update(bytes=len(source), sha256=observed.digest(source))
        response['parse']['wikitext'] = params['text']
        page['request'] = observed.encoded(request).decode()
        page['response'] = observed.encoded(response).decode()
        for part in ('request', 'response'):
            body = page[part].encode()
            receipt[part].update(bytes=len(body), sha256=observed.digest(body))
        page['receipt'] = observed.encoded(receipt).decode()
        self.assertTrue(params['text'].startswith(original_source))
        self.assertEqual(response['parse']['text'], original_html)
        return doc, namespace, defaults

    def test_encoded_form_boundary_preserves_complete_echo_and_html(self):
        # Both sides of the old64KiB boundary, Mai's actual form length, new max.
        for length in (65536, 65537, 98608, 131072, 131073, 131913, 262144):
            with self.subTest(length=length):
                doc, namespace, defaults = self.framed_form(length)
                accepted = observed.validate_document(observed.encoded(doc), namespace, defaults)
                self.assertEqual(accepted, doc)
                page = accepted['pages'][0]
                params = dict(observed.urllib.parse.parse_qsl(page['form_body'], keep_blank_values=True))
                self.assertEqual(observed.decode(page['response'])['parse']['wikitext'], params['text'])
                self.assertIsNone(observed.decode(page['response'])['parse'].get('revid'))

    def test_encoded_form_empty_over_max_and_malformed_escape_refuse(self):
        doc, namespace, defaults = self.framed_form(262145)
        with self.assertRaisesRegex(ValueError, 'form body'):
            observed.validate_document(observed.encoded(doc), namespace, defaults)
        for form in ('', '%zz'):
            with self.subTest(form=form):
                doc['pages'][0]['form_body'] = form
                with self.assertRaisesRegex(ValueError, 'form body'):
                    observed.validate_document(observed.encoded(doc), namespace, defaults)

    def test_large_form_keeps_source_hash_echo_and_response_bounds(self):
        for failure in ('source_hash', 'echo', 'response_size'):
            with self.subTest(failure=failure):
                doc, namespace, defaults = self.framed_form(131072)
                page = doc['pages'][0]
                request = observed.decode(page['request'])
                response = observed.decode(page['response'])
                receipt = observed.decode(page['receipt'])
                if failure == 'source_hash':
                    request['text_source']['sha256'] = '0' * 64
                    page['request'] = observed.encoded(request).decode()
                elif failure == 'echo':
                    response['parse']['wikitext'] += 'changed'
                    page['response'] = observed.encoded(response).decode()
                else:
                    page['response'] = observed.encoded(response).decode() + ' ' * observed.MAX_RESPONSE
                for part in ('request', 'response'):
                    body = page[part].encode()
                    receipt[part].update(bytes=len(body), sha256=observed.digest(body))
                page['receipt'] = observed.encoded(receipt).decode()
                with self.assertRaises(ValueError):
                    observed.validate_document(observed.encoded(doc), namespace, defaults)


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




# Genuine retained observation fixtures shared with the native Book controls.
EXTENDED_FIXTURES = Path(os.environ.get('WIKIDICT_OBSERVATION_EXTENDED_FIXTURE_ROOT', Path(__file__).parent / 'testdata'))


def fixture(relative, size, sha256):
    return {'path': EXTENDED_FIXTURES / relative, 'bytes': size, 'sha256': sha256}


PREP = {
    'snapshot': fixture('en-missing-tayassu/figure-page-observations.json', 135813, '7e85b85be6c02e2895aea77b1966dee187d8f61a811dd62e3297f2ce6df9a203'),
    'namespace': fixture('figure-page-observations/en-upright/namespace-registry.tsv', 3611, '55df778e3d40f6acf08e10b8246bd28fab792d48ac619936202db15c29db0f08'),
    'defaults': fixture('figure-page-observations/en-upright/figure-siteinfo.raw.json', 18310, '1165cd3e0b017581502859bb1b8c72906e3911fe6891e26a422ece06790d6bfb'),
    'vi_snapshot': fixture('vi-missing-next268/figure-page-observations.json', 401214, '488b8acf2b9a2bd162d19856eb66e5ae5fdea7734a883511f6397f13eefa675c'),
    'vi_namespace': fixture('figure-inputs198/vi/namespace-registry.tsv', 2407, 'a574bc96b85652b6df6462f70bf90b142e3c15369e26041f8eb8e04b9bae562d'),
    'vi_defaults': fixture('figure-inputs198/vi/figure-siteinfo.raw.json', 16146, 'eb0dd59011bfb846be294843217806fa3c2de3eeec75d24fb9960eb083d19efc'),
    'cubeb_context': {'expanded': fixture('vi-cubeb268/expanded.wikitext', 6576, '4152682161b163e2dc72b7e0dac620d293ca352328c9866fdb9fdd2a2214f4e3'), 'figure_files': fixture('vi-cubeb268/figure-sizing.json', 37421, '04d01266b5e6b66bda02b6a21a4467b14f66d4c99e1bf974315671712e1f88a3'), 'namespace': fixture('figure-inputs198/vi/namespace-registry.tsv', 2407, 'a574bc96b85652b6df6462f70bf90b142e3c15369e26041f8eb8e04b9bae562d'), 'defaults': fixture('vi-cubeb268/figure-siteinfo.raw.json', 16146, 'eb0dd59011bfb846be294843217806fa3c2de3eeec75d24fb9960eb083d19efc'), 'raw': fixture('vi-cubeb268/raw.wikitext', 741, '13217242da5172d771ae1ddc4a110f2a2b576d821122aa8ddea6de545e7425c8'), 'request': fixture('figure-text-class-scope/cubeb/request.json', 1950, '84d11992821e0abb9c53b4efc3a855421f57dc9767ead19c7a804173f120bd34'), 'form_body': fixture('figure-text-class-scope/cubeb/request.form', 10758, 'cdeee8ab864b40ea0bd06c9fe2ff8e50652aa2af70c6d53bc9d6fed05d30a3cd'), 'receipt': fixture('figure-text-class-scope/cubeb/receipt.json', 1055, '91785c3a8ed374d2f8522fcebeedc45114c18387a0eacef594c5364a8056982d'), 'response': fixture('figure-text-class-scope/cubeb/response.json', 31952, '041770f1847ea19931d0d81d5d2f641accf42105cc84e59ad45f257a3f7c24b7')},
    'outer_context': {'receipt': fixture('figure-outer-context/cubeb/receipt.json', 6837, '88d7060f31944dfd506f23327944c46c2da01491886d4a166ec7a47ba23a02e9'), 'response': fixture('figure-outer-context/cubeb/response.html', 94181, 'c3f78ca7d2e67626675adc939705db10e54e2707e9b2aeaa6b2da909f9ae17c9')}
}
LEGACY = EXTENDED_FIXTURES / 'figure-page-observations/en-upright/figure-page-observations.json'


def authenticated(record):
    raw = Path(record['path']).read_bytes()
    if len(raw) != record['bytes'] or hashlib.sha256(raw).hexdigest() != record['sha256']:
        raise AssertionError('Changed retained input: ' + record['path'])
    return raw



class MissingObservationContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.helper = observed
        cls.raw = authenticated(PREP['snapshot'])
        cls.namespace = authenticated(PREP['namespace'])
        cls.defaults = authenticated(PREP['defaults'])
        cls.document = json.loads(cls.raw)

    def validate(self, document):
        return self.helper.validate_document(self.helper.encoded(document), self.namespace, self.defaults)

    def test_complete_retained_missing_page_preserves_evidence(self):
        actual = self.helper.validate_document(self.raw, self.namespace, self.defaults)
        self.assertEqual(actual, self.document)
        self.assertEqual(len(actual['pages']), 1)
        page = actual['pages'][0]
        self.assertEqual(page['page_id'], 10513182)
        self.assertEqual(page['revision_id'], 89044640)
        self.assertEqual(len(page['occurrences']), 1)
        self.assertEqual(set(page['occurrences'][0]), {'start', 'end', 'canonical_file', 'missing_content'})
        self.assertIs(page['occurrences'][0]['missing_content'], True)
        self.assertEqual(len(json.loads(page['response'])['parse']['wikitext'].encode()), 3172)
        self.assertEqual(len(json.loads(page['response'])['parse']['text'].encode()), 8968)

    def test_legacy_image_pages_and_v2_image_pages_keep_same_identity(self):
        # Authentic complete two-page image observations, not a missing row
        # relabeled as an image. The legacy parser is the independent comparator.
        legacy_raw = LEGACY.read_bytes()
        self.assertEqual(hashlib.sha256(legacy_raw).hexdigest(), '9a569d94b82861579c7e69132012ad3a2f23d374d54e5a0f0334f928591124a6')
        expected = json.loads(legacy_raw)
        actual = self.helper.validate_document(legacy_raw, self.namespace, self.defaults)
        self.assertEqual(actual, expected)
        promoted = copy.deepcopy(expected)
        promoted['schema'] = 'wikidict.figure-page-observations.v2'
        self.assertEqual(self.validate(promoted)['pages'], expected['pages'])

    def test_missing_requires_v2_and_exact_true(self):
        legacy = copy.deepcopy(self.document)
        legacy['schema'] = 'wikidict.figure-page-observations.v2'
        del legacy['missing_link_styles']
        self.assertIs(self.validate(legacy)['pages'][0]['occurrences'][0]['missing_content'], True)
        for schema, flag in [('wikidict.figure-page-observations.v1', True),
                             ('wikidict.figure-page-observations.v2', False),
                             ('wikidict.figure-page-observations.v2', None),
                             ('wikidict.figure-page-observations.v2', 1)]:
            with self.subTest(schema=schema, flag=flag):
                changed = copy.deepcopy(self.document)
                changed['schema'] = schema
                del changed['missing_link_styles']
                changed['pages'][0]['occurrences'][0]['missing_content'] = flag
                with self.assertRaises(ValueError):
                    self.validate(changed)

    def test_missing_rejects_pixel_identity_and_unknown_fields(self):
        for field, value in [('original_width', 180), ('original_height', 1),
                             ('file_sha1', '0' * 40), ('file_timestamp', '2026-01-01'),
                             ('width', True), ('anchor_attributes', True), ('invented', None)]:
            with self.subTest(field=field):
                changed = copy.deepcopy(self.document)
                changed['pages'][0]['occurrences'][0][field] = value
                with self.assertRaises(ValueError):
                    self.validate(changed)

    def test_missing_duplicate_and_overlap_are_rejected(self):
        changed = copy.deepcopy(self.document)
        item = changed['pages'][0]['occurrences'][0]
        changed['pages'][0]['occurrences'].append(copy.deepcopy(item))
        with self.assertRaises(ValueError):
            self.validate(changed)
        changed['pages'][0]['occurrences'][1]['canonical_file'] = 'Different.png'
        with self.assertRaises(ValueError):
            self.validate(changed)

    def test_missing_cannot_bypass_full_echo_or_namespace(self):
        changed = copy.deepcopy(self.document)
        page = changed['pages'][0]
        response = json.loads(page['response'])
        response['parse']['wikitext'] += ' changed'
        page['response'] = json.dumps(response, ensure_ascii=False)
        receipt = json.loads(page['receipt'])
        receipt['response']['bytes'] = len(page['response'].encode())
        receipt['response']['sha256'] = hashlib.sha256(page['response'].encode()).hexdigest()
        page['receipt'] = json.dumps(receipt)
        with self.assertRaises(ValueError):
            self.validate(changed)
        with self.assertRaises(ValueError):
            self.helper.validate_document(self.raw, self.namespace + b'\n', self.defaults)


    def test_old_missing_snapshot_has_no_paint_capability(self):
        legacy = copy.deepcopy(self.document)
        del legacy['missing_link_styles']
        legacy['schema'] = 'wikidict.figure-page-observations.v2'
        canonical = json.dumps(legacy, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()
        self.assertEqual(hashlib.sha256(canonical).hexdigest(), 'd5629f9257716ff51dc93e92ddd4f0d7772d5aa6bdb8c5d9e4f81f8d5ceb5206')
        old = self.helper.validate_document(self.helper.encoded(legacy), self.namespace, self.defaults)
        self.assertEqual(old['pages'], self.document['pages'])
        self.assertNotIn('missing_link_styles', old)

    def test_css_tamper_still_refused_after_receipt_rehash(self):
        changed = copy.deepcopy(self.document)
        styles = changed['missing_link_styles']
        styles['response'] = styles['response'].replace('#bf3c2c', '#000000')
        receipt = json.loads(styles['receipt'])
        receipt['sources'][0].update(bytes=len(styles['response'].encode()), sha256=self.helper.digest(styles['response'].encode()))
        styles['receipt'] = json.dumps(receipt)
        with self.assertRaises(ValueError):
            self.validate(changed)

    def test_actual_stylesheet_receipt_scope_cannot_be_relabelled(self):
        for key, value in [('status', 403), ('url', 'https://en.wiktionary.org/w/api.php'),
                           ('final_url', 'https://example.com/skin.css'),
                           ('source_path', 'served:skins.vector.styles:ru:vector-2022'),
                           ('headers', {'content-type': 'text/html'})]:
            with self.subTest(key=key):
                changed = copy.deepcopy(self.document)
                styles = changed['missing_link_styles']
                receipt = json.loads(styles['receipt'])
                receipt['sources'][0][key] = value
                styles['receipt'] = json.dumps(receipt)
                with self.assertRaises(ValueError):
                    self.validate(changed)
        changed = copy.deepcopy(self.document)
        receipt = json.loads(changed['missing_link_styles']['receipt'])
        receipt['core'] = 'guessed-historical-core'
        changed['missing_link_styles']['receipt'] = json.dumps(receipt)
        with self.assertRaises(ValueError):
            self.validate(changed)

    def test_rehashed_other_skin_defaults_do_not_grant_new_link_paint(self):
        changed = copy.deepcopy(self.document)
        defaults = json.loads(self.defaults)
        defaults['query']['defaultoptions']['skin'] = 'monobook'
        raw = self.helper.encoded(defaults)
        changed['defaults_sha256'] = self.helper.digest(raw)
        changed['missing_link_styles']['defaults'] = raw.decode()
        with self.assertRaises(ValueError):
            self.helper.validate_document(self.helper.encoded(changed), self.namespace, raw)

    def test_paint_requires_explicit_version_and_complete_proof(self):
        for schema, remove in [('wikidict.figure-page-observations.v2', False),
                               ('wikidict.figure-page-observations.v3', True)]:
            changed = copy.deepcopy(self.document)
            changed['schema'] = schema
            if remove:
                del changed['missing_link_styles']
            with self.assertRaises(ValueError):
                self.validate(changed)
        changed = copy.deepcopy(self.document)
        changed['missing_link_styles']['profile'] = 'external-link-default'
        with self.assertRaises(ValueError):
            self.validate(changed)



    def test_vi_complete_actual_pages_preserve_all_observation_bytes(self):
        raw = authenticated(PREP['vi_snapshot'])
        namespace = authenticated(PREP['vi_namespace'])
        defaults = authenticated(PREP['vi_defaults'])
        expected = json.loads(raw)
        actual = self.helper.validate_document(raw, namespace, defaults)
        self.assertEqual(actual, expected)
        self.assertEqual(len(actual['pages']), 10)
        self.assertEqual(sum(o.get('missing_content') is True for p in actual['pages'] for o in p['occurrences']), 8)
        self.assertEqual({p['title'] for p in actual['pages'] if any(o.get('missing_content') for o in p['occurrences'])},
                         {'cosmos', 'irritant', 'journal', 'jujube', 'islam', 'g', 'univers', 'Thừa Thiên Huế'})

    def test_vi_paint_requires_its_own_actual_receipt_identity(self):
        doc = json.loads(authenticated(PREP['vi_snapshot']))
        defaults = authenticated(PREP['vi_defaults'])
        styles = doc['missing_link_styles']
        self.helper.validate_missing_link_styles(styles, defaults, 'viwiktionary')
        for old, new in [('vi.wiktionary.org', 'en.wiktionary.org'),
                         ('lang=vi', 'lang=en'),
                         ('served:skins.vector.styles:vi:', 'served:skins.vector.styles:en:')]:
            changed = copy.deepcopy(styles)
            self.assertIn(old, changed['receipt'])
            changed['receipt'] = changed['receipt'].replace(old, new)
            with self.assertRaises(ValueError):
                self.helper.validate_missing_link_styles(changed, defaults, 'viwiktionary')
        with self.assertRaises(ValueError):
            self.helper.validate_missing_link_styles(styles, defaults, 'enwiktionary')
        with self.assertRaises(ValueError):
            self.helper.validate_missing_link_styles(styles, defaults, 'srwiktionary')

    def test_vi_paint_rejects_changed_selected_language_skin_and_theme(self):
        doc = json.loads(authenticated(PREP['vi_snapshot']))
        original = json.loads(authenticated(PREP['vi_defaults']))
        for key, value in [('language', 'en'), ('skin', 'monobook'), ('vector-theme', 'night')]:
            changed_defaults = copy.deepcopy(original)
            changed_defaults['query']['defaultoptions'][key] = value
            raw = self.helper.encoded(changed_defaults)
            styles = copy.deepcopy(doc['missing_link_styles'])
            styles['defaults'] = raw.decode()
            with self.assertRaises(ValueError):
                self.helper.validate_missing_link_styles(styles, raw, 'viwiktionary')


    def cubeb_v4(self):
        # Actual retained supplied-page tuple and actual image facts, assembled
        # only in memory by this validator test. No pack or native Book is run.
        records = PREP['cubeb_context']
        source = authenticated(records['expanded'])
        lines = source.splitlines()
        token = lines[2]
        self.assertTrue(token.startswith('[[Tập tin:Piper cubeba muda.jpg|nhỏ|'.encode()))
        self.assertTrue(token.endswith(b'</span>]]'))
        self.assertEqual(source.count(token), 1)
        start = source.index(token)
        facts = [json.loads(line) for line in authenticated(records['figure_files']).splitlines()]
        selected = [row for row in facts if row.get('canonical_file') == 'Tập tin:Piper cubeba muda.jpg']
        self.assertEqual(len(selected), 1)
        fact = selected[0]
        self.assertEqual(fact['state'], 'eligible')
        occurrence = {key: fact[key] for key in ('canonical_file', 'file_sha1', 'file_timestamp', 'original_width', 'original_height')}
        occurrence.update(start=start, end=start + len(token), width=True, anchor_attributes=False)
        namespace = authenticated(records['namespace'])
        defaults = authenticated(records['defaults'])
        page = dict(namespace_id=0, page_id=12617, revision_id=2313690, title='cubeb',
                    raw_sha256=self.helper.digest(authenticated(records['raw'])), text_class_scope=True,
                    occurrences=[occurrence],
                    **{key: authenticated(records[key]).decode() for key in ('request', 'form_body', 'receipt', 'response')})
        document = dict(schema='wikidict.figure-page-observations.v4', wiki='viwiktionary', date='20261001',
                        namespace_sha256=self.helper.digest(namespace), defaults_sha256=self.helper.digest(defaults), pages=[page])
        self.assertEqual(json.loads(page['response'])['parse']['wikitext'].encode(), source)
        return document, namespace, defaults

    def rebind_request(self, page, request=None, response=None, form=None):
        # Rehash controlled negative artifacts so the semantic joins, not merely
        # a stale digest, are exercised. No retained original is modified.
        receipt = json.loads(page['receipt'])
        if form is not None:
            page['form_body'] = form
            request = request if request is not None else json.loads(page['request'])
            request['form'].update(bytes=len(form.encode()), sha256=self.helper.digest(form.encode()))
        if request is not None:
            page['request'] = self.helper.encoded(request).decode()
            receipt['request'].update(bytes=len(page['request'].encode()), sha256=self.helper.digest(page['request'].encode()))
        if response is not None:
            page['response'] = self.helper.encoded(response).decode()
            receipt['response'].update(bytes=len(page['response'].encode()), sha256=self.helper.digest(page['response'].encode()))
        page['receipt'] = self.helper.encoded(receipt).decode()

    def test_v4_actual_complete_context_keeps_original_response_and_image_identity(self):
        document, namespace, defaults = self.cubeb_v4()
        actual = self.helper.validate_document(self.helper.encoded(document), namespace, defaults)
        self.assertEqual(actual, document)
        page = actual['pages'][0]
        self.assertIs(page['text_class_scope'], True)
        self.assertEqual(page['response'].encode(), authenticated(PREP['cubeb_context']['response']))
        self.assertEqual(page['request'].encode(), authenticated(PREP['cubeb_context']['request']))
        self.assertEqual(page['form_body'].encode(), authenticated(PREP['cubeb_context']['form_body']))
        self.assertEqual(page['receipt'].encode(), authenticated(PREP['cubeb_context']['receipt']))
        self.assertEqual(page['occurrences'][0]['original_width'], 1200)
        self.assertEqual(page['occurrences'][0]['original_height'], 1600)
        self.assertNotIn('root_classes', page)
        self.assertNotIn('subtree_classes', page)
        # The parser root/class inventory is derived only by Zig after selection.
        self.assertNotIn('class_inventory', document)

    def test_v4_false_or_absent_flag_keeps_legacy_request_and_optional_paint_contract(self):
        for flag in (None, False):
            document = copy.deepcopy(self.document)
            document['schema'] = 'wikidict.figure-page-observations.v4'
            if flag is not None:
                document['pages'][0]['text_class_scope'] = flag
            self.assertEqual(self.validate(document), document)
            del document['missing_link_styles']
            self.assertEqual(self.validate(document), document)
            document['missing_link_styles'] = None
            self.assertEqual(self.validate(document), document)
        document = copy.deepcopy(self.document)
        document['schema'] = 'wikidict.figure-page-observations.v4'
        document['missing_link_styles']['profile'] = 'invented-profile'
        with self.assertRaises(ValueError):
            self.validate(document)

    def test_v4_context_requires_boolean_flag_and_explicit_schema_without_inventory_input(self):
        document, namespace, defaults = self.cubeb_v4()
        for schema in ('wikidict.figure-page-observations.v1', 'wikidict.figure-page-observations.v2', 'wikidict.figure-page-observations.v3'):
            changed = copy.deepcopy(document)
            changed['schema'] = schema
            with self.subTest(schema=schema), self.assertRaises(ValueError):
                self.helper.validate_document(self.helper.encoded(changed), namespace, defaults)
        for value in (False, None, 0, 1, 'true', {'root_classes': 'mw-parser-output'}):
            changed = copy.deepcopy(document)
            changed['pages'][0]['text_class_scope'] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.helper.validate_document(self.helper.encoded(changed), namespace, defaults)
        changed = copy.deepcopy(document)
        del changed['pages'][0]['text_class_scope']
        with self.assertRaises(ValueError):
            self.helper.validate_document(self.helper.encoded(changed), namespace, defaults)
        for field in ('class_inventory', 'root_tag', 'root_classes', 'subtree_classes', 'text_class_scope_source'):
            changed = copy.deepcopy(document)
            changed['pages'][0][field] = 'caller supplied'
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.helper.validate_document(self.helper.encoded(changed), namespace, defaults)
        changed = copy.deepcopy(document)
        changed['pages'][0]['occurrences'] = []
        with self.assertRaises(ValueError):
            self.helper.validate_document(self.helper.encoded(changed), namespace, defaults)

    def test_v4_rehashed_extended_request_rejects_context_and_echo_mismatches(self):
        import urllib.parse
        document, namespace, defaults = self.cubeb_v4()
        for key, value in [('useskin', 'monobook'), ('prop', 'text|wikitext|revid|displaytitle'),
                           ('title', 'other'), ('revid', '2313691'), ('parser', 'parsoid'), ('usearticle', '0')]:
            changed = copy.deepcopy(document)
            page = changed['pages'][0]
            request = json.loads(page['request'])
            request['parameters_except_text'][key] = value
            pairs = urllib.parse.parse_qsl(page['form_body'], keep_blank_values=True)
            form = urllib.parse.urlencode([(name, value if name == key else old) for name, old in pairs])
            self.rebind_request(page, request=request, form=form)
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.helper.validate_document(self.helper.encoded(changed), namespace, defaults)
        changed = copy.deepcopy(document)
        page = changed['pages'][0]
        self.rebind_request(page, form=page['form_body'] + '&useskin=vector-2022')
        with self.assertRaises(ValueError):
            self.helper.validate_document(self.helper.encoded(changed), namespace, defaults)
        for key, value in [('wikitext', 'changed complete expansion'), ('pageid', 12618), ('title', 'other'), ('revid', 2313691), ('text', '')]:
            changed = copy.deepcopy(document)
            page = changed['pages'][0]
            response = json.loads(page['response'])
            response['parse'][key] = value
            self.rebind_request(page, response=response)
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.helper.validate_document(self.helper.encoded(changed), namespace, defaults)
        with self.assertRaises(ValueError):
            self.helper.validate_document(self.helper.encoded(document), namespace + b'\n', defaults)
        with self.assertRaises(ValueError):
            self.helper.validate_document(self.helper.encoded(document), namespace, defaults + b'\n')

    def test_v4_legacy_flag_does_not_upgrade_missing_or_image_authority(self):
        document = copy.deepcopy(self.document)
        document['schema'] = 'wikidict.figure-page-observations.v4'
        document['pages'][0]['text_class_scope'] = False
        original = copy.deepcopy(document['pages'][0]['occurrences'])
        self.assertEqual(self.validate(document)['pages'][0]['occurrences'], original)
        for key, value in [('original_width', 180), ('width', True), ('file_sha1', '0' * 40)]:
            changed = copy.deepcopy(document)
            changed['pages'][0]['occurrences'][0][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.validate(changed)
        image, namespace, defaults = self.cubeb_v4()
        for key, value in [('original_width', 0), ('original_height', 0), ('width', 1), ('file_sha1', 'bad')]:
            changed = copy.deepcopy(image)
            changed['pages'][0]['occurrences'][0][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.helper.validate_document(self.helper.encoded(changed), namespace, defaults)

    def outer_document(self):
        document, namespace, defaults = self.cubeb_v4()
        document['pages'][0]['outer_context'] = {
            'profile': 'mediawiki-vector-2022-1.48.0-wmf.3',
            'receipt': authenticated(PREP['outer_context']['receipt']).decode(),
            'response': authenticated(PREP['outer_context']['response']).decode(),
        }
        return document, namespace, defaults

    def rebind_outer(self, page, html):
        outer = page['outer_context']
        outer['response'] = html
        receipt = json.loads(outer['receipt'])
        receipt['sources'][0].update(bytes=len(html.encode()), sha256=self.helper.digest(html.encode()))
        outer['receipt'] = self.helper.encoded(receipt).decode()

    def test_outer_actual_full_response_preserves_supplied_page_and_all_occurrences(self):
        document, namespace, defaults = self.outer_document()
        original, _, _ = self.cubeb_v4()
        actual = self.helper.validate_document(self.helper.encoded(document), namespace, defaults)
        self.assertEqual(actual, document)
        page = copy.deepcopy(actual['pages'][0])
        outer = page.pop('outer_context')
        self.assertEqual(page, original['pages'][0])
        self.assertEqual(outer['response'].encode(), authenticated(PREP['outer_context']['response']))
        self.assertEqual(outer['receipt'].encode(), authenticated(PREP['outer_context']['receipt']))
        self.assertEqual(len(outer['response'].encode()), 94181)
        self.assertNotEqual(outer['response'], json.loads(page['response'])['parse']['text'])
        self.assertEqual(set(outer), {'profile', 'receipt', 'response'})

    def test_outer_omission_or_null_retains_absence_and_nonnull_requires_v4_scope(self):
        document, namespace, defaults = self.outer_document()
        for schema in ('wikidict.figure-page-observations.v1', 'wikidict.figure-page-observations.v2', 'wikidict.figure-page-observations.v3'):
            changed = copy.deepcopy(document)
            changed['schema'] = schema
            with self.subTest(schema=schema), self.assertRaises(ValueError):
                self.helper.validate_document(self.helper.encoded(changed), namespace, defaults)
        for flag in (False, None, 0, 1):
            changed = copy.deepcopy(document)
            changed['pages'][0]['text_class_scope'] = flag
            with self.subTest(flag=flag), self.assertRaises(ValueError):
                self.helper.validate_document(self.helper.encoded(changed), namespace, defaults)
        for missing in (False, True):
            changed = copy.deepcopy(document)
            if missing:
                del changed['pages'][0]['outer_context']
            else:
                changed['pages'][0]['outer_context'] = None
            self.assertEqual(self.helper.validate_document(self.helper.encoded(changed), namespace, defaults), changed)

    def test_outer_exact_profile_keys_bounds_and_receipt_identity(self):
        document, namespace, defaults = self.outer_document()
        changes = [('profile', 'unreviewed'), ('receipt', ''), ('response', ''),
                   ('response', 'x' * (self.helper.MAX_RESPONSE + 1)), ('receipt', 7),
                   ('classes', 'caller-supplied')]
        for key, value in changes:
            changed = copy.deepcopy(document)
            changed['pages'][0]['outer_context'][key] = value
            with self.subTest(key=key, value_type=type(value).__name__), self.assertRaises(ValueError):
                self.helper.validate_document(self.helper.encoded(changed), namespace, defaults)
        for key, value in [('status', 403), ('bytes', 1), ('sha256', '0' * 64),
                           ('final_url', 'https://vi.wiktionary.org/wiki/cubeb')]:
            changed = copy.deepcopy(document)
            outer = changed['pages'][0]['outer_context']
            receipt = json.loads(outer['receipt'])
            receipt['sources'][0][key] = value
            outer['receipt'] = self.helper.encoded(receipt).decode()
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.helper.validate_document(self.helper.encoded(changed), namespace, defaults)

    def test_outer_changed_page_skin_origin_and_duplicate_query_refuse(self):
        document, namespace, defaults = self.outer_document()
        base = json.loads(document['pages'][0]['outer_context']['receipt'])['sources'][0]['url']
        for url in (base.replace('title=cubeb', 'title=other'), base.replace('2313690', '2313691'),
                    base.replace('vector-2022', 'monobook'), base.replace('vi.wiktionary', 'en.wiktionary'),
                    base + '&title=cubeb', base + '&extra=1', base + '#fragment'):
            changed = copy.deepcopy(document)
            outer = changed['pages'][0]['outer_context']
            receipt = json.loads(outer['receipt'])
            receipt['sources'][0].update(url=url, final_url=url)
            outer['receipt'] = self.helper.encoded(receipt).decode()
            with self.subTest(url=url), self.assertRaises(ValueError):
                self.helper.validate_document(self.helper.encoded(changed), namespace, defaults)

    def test_outer_rehashed_generator_body_and_parser_root_changes_refuse(self):
        document, namespace, defaults = self.outer_document()
        html = document['pages'][0]['outer_context']['response']
        mutations = [html.replace('MediaWiki 1.48.0-wmf.3', 'MediaWiki 1.48.0-wmf.4'),
                     html.replace('skin-vector-2022', 'skin-monobook'),
                     html.replace('class="mw-content-ltr mw-parser-output" lang="vi" dir="ltr"',
                                  'class="mw-content-ltr mw-parser-output" lang="en" dir="ltr"'),
                     html.replace('<body ', '<body class="duplicate" '),
                     html + '<div class="mw-parser-output" lang="vi" dir="ltr"></div>']
        for index, mutated in enumerate(mutations):
            self.assertNotEqual(mutated, html)
            changed = copy.deepcopy(document)
            self.rebind_outer(changed['pages'][0], mutated)
            with self.subTest(index=index), self.assertRaises(ValueError):
                self.helper.validate_document(self.helper.encoded(changed), namespace, defaults)

    def test_outer_does_not_relax_supplied_echo_or_normal_input_identity(self):
        document, namespace, defaults = self.outer_document()
        changed = copy.deepcopy(document)
        page = changed['pages'][0]
        response = json.loads(page['response'])
        response['parse']['wikitext'] += 'changed'
        self.rebind_request(page, response=response)
        with self.assertRaises(ValueError):
            self.helper.validate_document(self.helper.encoded(changed), namespace, defaults)
        with self.assertRaises(ValueError):
            self.helper.validate_document(self.helper.encoded(document), namespace + b'\n', defaults)
        with self.assertRaises(ValueError):
            self.helper.validate_document(self.helper.encoded(document), namespace, defaults + b'\n')


class Wmf6OuterContextContract(unittest.TestCase):
    def actual(self):
        folder = Path(__file__).parent / 'testdata' / 'zh-outer-wmf6'
        raw = gzip.decompress((folder / 'figure-page-observations.json.gz').read_bytes())
        self.assertEqual((len(raw), observed.digest(raw)),
                         (610976, '615fcbca8c0d1b916751b78b3051d525215e77fda90434a6774207e50d0c641b'))
        namespace = (FIXTURES.parent / 'zh-magal' / 'namespace-registry.tsv').read_bytes()
        defaults = (FIXTURES.parents[2] / 'src' / 'encoder' / 'testdata' /
                    'zh-gugli176' / 'figure-siteinfo.raw.json').read_bytes()
        return observed.decode(raw), namespace, defaults

    def validate(self, doc, namespace, defaults):
        return observed.validate_document(observed.encoded(doc), namespace, defaults)

    def test_actual_wmf6_retains_the_complete_captured_page(self):
        doc, namespace, defaults = self.actual()
        original = copy.deepcopy(doc)
        self.assertEqual(self.validate(doc, namespace, defaults), original)
        self.assertEqual(doc, original)
        page = doc['pages'][0]
        self.assertEqual((page['title'], page['page_id'], page['revision_id']),
                         ('咱人學堂', 1500194, 9255758))
        self.assertEqual(observed.digest(page['outer_context']['response'].encode()),
                         '66456db0fead53640b57757c3f8b5b7cc9fce76a9f52c77e40f8ad7840d91d3a')
        self.assertEqual(observed.digest(page['response'].encode()),
                         'ec2685fd714adefe8af8090d0b13dcca0cddb078dcc5ccd7af70e59d6c074f05')

    def test_wmf6_refuses_unknown_or_mismatched_profiles_and_transport(self):
        doc, namespace, defaults = self.actual()
        for profile in ('mediawiki-vector-2022-1.48.0-wmf.7',
                        'mediawiki-vector-2022-1.48.0-wmf.3', 'unknown'):
            changed = copy.deepcopy(doc)
            changed['pages'][0]['outer_context']['profile'] = profile
            with self.subTest(profile=profile), self.assertRaises(ValueError):
                self.validate(changed, namespace, defaults)
        outer = doc['pages'][0]['outer_context']
        base = observed.decode(outer['receipt'])['sources'][0]['url']
        for url in (base.replace('oldid=9255758', 'oldid=9255759'),
                    base.replace('zh.wiktionary', 'en.wiktionary'),
                    base.replace('vector-2022', 'monobook'),
                    base + '&oldid=9255758', base + '#fragment'):
            changed = copy.deepcopy(doc)
            selected = changed['pages'][0]['outer_context']
            receipt = observed.decode(selected['receipt'])
            receipt['sources'][0].update(url=url, final_url=url)
            selected['receipt'] = observed.encoded(receipt).decode()
            with self.subTest(url=url), self.assertRaises(ValueError):
                self.validate(changed, namespace, defaults)

    def test_wmf6_rehashed_generator_body_and_root_changes_still_refuse(self):
        doc, namespace, defaults = self.actual()
        html = doc['pages'][0]['outer_context']['response']
        changes = (
            ('MediaWiki 1.48.0-wmf.6', 'MediaWiki 1.48.0-wmf.7'),
            ('skin-vector-2022', 'skin-monobook'),
            ('class="mw-content-ltr mw-parser-output" lang="zh" dir="ltr"',
             'class="mw-content-ltr mw-parser-output" lang="en" dir="ltr"'),
            ('<body ', '<body class="duplicate" '),
        )
        for before, after in changes:
            self.assertIn(before, html)
            changed = copy.deepcopy(doc)
            outer = changed['pages'][0]['outer_context']
            outer['response'] = html.replace(before, after)
            receipt = observed.decode(outer['receipt'])
            body = outer['response'].encode()
            receipt['sources'][0].update(bytes=len(body), sha256=observed.digest(body))
            outer['receipt'] = observed.encoded(receipt).decode()
            with self.subTest(mutation=before), self.assertRaises(ValueError):
                self.validate(changed, namespace, defaults)

    def test_wmf6_requires_unchanged_source_registry_and_scope(self):
        doc, namespace, defaults = self.actual()
        for flag in (False, None, 0):
            changed = copy.deepcopy(doc)
            changed['pages'][0]['text_class_scope'] = flag
            with self.subTest(scope=flag), self.assertRaises(ValueError):
                self.validate(changed, namespace, defaults)
        for ns, source_defaults in ((namespace + b'\n', defaults),
                                    (namespace, defaults + b'\n')):
            with self.assertRaises(ValueError):
                self.validate(doc, ns, source_defaults)


class SelectedFullGetRootContract(unittest.TestCase):
    def actual(self):
        folder = FIXTURES / 'ku-missing-served-set'
        doc = observed.decode((folder / 'figure-page-observations.json').read_bytes())
        raw = (folder / 'mismatched-53658-page.json').read_bytes()
        self.assertEqual((len(raw), observed.digest(raw)),
                         (337870, 'ee49c199da0719aaab7b6b63d3b20f171190bb4099fdd3ed30c66c19ac801bca'))
        page = observed.decode(raw)
        page['outer_context']['selected_body'] = 'full_get_root'
        page['page_styles'] = copy.deepcopy(doc['missing_link_styles']['served_set'])
        page['figure_style_operations'] = [{'start': 25780, 'end': 26121, 'media_kind': 'missing'}]
        doc['pages'] = [page]
        doc['schema'] = 'wikidict.figure-page-observations.v8'
        return doc, (folder / 'namespace-registry.tsv').read_bytes(), doc['missing_link_styles']['defaults'].encode()

    @staticmethod
    def changed_get(page, change):
        outer = page['outer_context']
        outer['response'] = change(outer['response'])
        receipt = observed.decode(outer['receipt'])
        receipt['sources'][0].update(bytes=len(outer['response'].encode()), sha256=observed.digest(outer['response'].encode()))
        outer['receipt'] = observed.encoded(receipt).decode()

    def test_actual_full_get_view_preserves_every_original_capture_and_complete_root_bytes(self):
        doc, namespace, defaults = self.actual()
        before = copy.deepcopy(doc)
        self.assertEqual(observed.validate_document(observed.encoded(doc), namespace, defaults), before)
        page = doc['pages'][0]
        parsed = observed.decode(page['response'])['parse']
        view = observed.validate_outer_context(page['outer_context'], page, doc['wiki'], parsed)
        self.assertEqual((len(view['text'].encode()), observed.digest(view['text'].encode())),
                         (76038, '72866b7e71bb94a5ba773a06324a24d26bd2e1611134f20211a6f9894cdb0a33'))
        self.assertNotEqual(view['text'], parsed['text'])
        self.assertIn('mw-editsection', view['text'])
        self.assertIn('vector-feature-custom-font-size-clientpref--excluded', view['headhtml'])
        self.assertEqual(view['wikitext'], parsed['wikitext'])
        self.assertEqual(doc, before)

    def test_changed_oldid_root_state_tail_and_source_operations_refuse(self):
        def relocated_config(html, destination):
            start = html.index('<script>')
            stop = html.index('</script>', start) + len('</script>')
            original = html[start:stop]
            self.assertIn('RLCONF=', original)
            # Preserve the original head's other bytes and every receipt field;
            # only the configuration's actual ancestry is changed.
            changed = html[:start] + original.replace('RLCONF=', 'RLFAKE=', 1) + html[stop:]
            if destination == 'body':
                return changed.replace('</body>', '<head>' + original + '</head></body>', 1)
            if destination == 'nested-head':
                return changed.replace('</head>', '<div><head>' + original + '</head></div></head>', 1)
            if destination == 'nested-script':
                return changed.replace('</head>', '<div>' + original + '</div></head>', 1)
            raise AssertionError(destination)

        mutations = [
            lambda p: self.changed_get(p, lambda h: h.replace('"wgRevisionId":5884328', '"wgRevisionId":5884327')),
            lambda p: self.changed_get(p, lambda h: h.replace('"wgArticleId":53658', '"wgArticleId":53659')),
            lambda p: self.changed_get(p, lambda h: h.replace('"wgNamespaceNumber":100', '"wgNamespaceNumber":0')),
            lambda p: self.changed_get(p, lambda h: h.replace('"wgAction":"view"', '"wgAction":"edit"')),
            lambda p: self.changed_get(p, lambda h: h.replace('custom-font-size-clientpref--excluded', 'custom-font-size-clientpref-1', 1)),
            lambda p: self.changed_get(p, lambda h: h.replace('<div class="mw-content-ltr mw-parser-output" lang="ku" dir="ltr">', '<div class="mw-content-ltr mw-parser-output" lang="en" dir="ltr">')),
            lambda p: self.changed_get(p, lambda h: h + '<style>.vector-body{font-size:99px}</style>'),
            lambda p: self.changed_get(p, lambda h: h + '<div class="mw-parser-output"></div>'),
            lambda p: self.changed_get(p, lambda h: relocated_config(h, 'body')),
            lambda p: self.changed_get(p, lambda h: relocated_config(h, 'nested-head')),
            lambda p: self.changed_get(p, lambda h: relocated_config(h, 'nested-script')),
            lambda p: self.changed_get(p, lambda h: h.replace('<head>', '<head data-forged="true">', 1)),
            lambda p: p['figure_style_operations'][0].update(start=25781),
            lambda p: p.pop('figure_style_operations'),
            lambda p: p.pop('page_styles'),
            lambda p: p['outer_context'].update(selected_body=None),
        ]
        for mutate_page in mutations:
            with self.subTest(mutation=mutate_page):
                doc, namespace, defaults = self.actual()
                mutate_page(doc['pages'][0])
                with self.assertRaises(ValueError):
                    observed.validate_document(observed.encoded(doc), namespace, defaults)

    def test_absent_selection_keeps_default_validation_view_and_immutable_api(self):
        doc, namespace, defaults = self.actual()
        page = doc['pages'][0]
        page['outer_context'].pop('selected_body')
        parsed = observed.decode(page['response'])['parse']
        before = copy.deepcopy(parsed)
        self.assertIsNone(observed.validate_outer_context(page['outer_context'], page, doc['wiki'], parsed))
        self.assertEqual(parsed, before)
        # Packaging remains a transport check. Native's unchanged default API
        # constructor still rejects this unequal paired font state.
        self.assertEqual(observed.validate_document(observed.encoded(doc), namespace, defaults), doc)




class SelectedSunStandaloneSvgTests(unittest.TestCase):
    def test_genuine_yiddish_svg_book_accepts_only_its_observed_capsule(self):
        fixture = Path(__file__).parent / 'testdata/yi-sun-standalone/selected-book.json.gz'
        bundle = json.loads(gzip.decompress(fixture.read_bytes()))
        book, namespace, defaults = (bundle[name].encode() for name in ('book', 'namespace', 'defaults'))
        doc = observed.validate_document(book, namespace, defaults)
        root, = doc['table_roots']
        self.assertEqual((root['title'], root['page_id'], root['revision_id']), ('☉', 5463, 17199))
        capsule = root['standalone_svg']
        box = json.loads(capsule)
        self.assertEqual((box['width'], box['height'], box['screen_max']), (80, 80, 639))
        self.assertEqual(root['source'].encode()[box['start']:box['end']],
                         b'[[File:Sun symbol (fixed width).svg|80px|left|frameless]]')
        for key, bad in (('standalone_svg', capsule + ' '), ('revision_id', 17200), ('page_id', 8372)):
            with self.subTest(key=key):
                rejected = copy.deepcopy(doc)
                rejected['table_roots'][0][key] = bad
                with self.assertRaisesRegex(ValueError, 'Unbound selected standalone SVG observation'):
                    observed.validate_document(observed.encoded(rejected), namespace, defaults)
        del root['standalone_svg']
        self.assertEqual(observed.validate_document(observed.encoded(doc), namespace, defaults), doc)

class RootOnlyObservationTests(unittest.TestCase):
 def test_saved_aragonese_sun_table_and_closed_heading_parent(self):
  folder = Path(__file__).parent / 'testdata/an-planet-table'
  namespace = (folder.parent / 'an-decimal-noun/namespace-registry.tsv').read_bytes()
  defaults = gzip.decompress((folder / 'figure-siteinfo.json.gz').read_bytes())
  snapshot = gzip.decompress((folder / 'sun-table-source.json.gz').read_bytes())
  doc = observed.validate_document(snapshot, namespace, defaults)
  root, = doc['table_roots']
  self.assertEqual((root['title'], root['page_id'], root['revision_id']), ('☉', 8372, 32427))
  source = (folder / 'expanded.wikitext').read_bytes()
  self.assertEqual(root['source'].encode(), source)
  self.assertEqual(root['raw_sha256'], observed.digest((folder / 'raw.wikitext').read_bytes()))
  self.assertEqual(observed.table_root_source_parent(source, root['source_table']['start']), {'align':'center'})
  suffix = source[source.index(b'<div align='):]
  for prefix in (b'ordinary text\n', b'==Unclosed\n', b'==<h3 id="x">word</h3>==\n==Next==\n',
                 b'[[open\n==Next==\n', b':[1x]:\n==Next==\n', b'<sub>x\n==Next==\n'):
   altered = prefix + suffix
   with self.subTest(prefix=prefix), self.assertRaises(ValueError):
    observed.table_root_source_parent(altered, altered.index(b'{|'))

 def test_aragonese_planetary_table_configuration(self):
  prelude = (Path(__file__).parent / 'testdata/an-planet-table/vector-prelude.js').read_text()
  classes = 'client-nojs ' + prelude.split('var className="client-js ', 1)[1].split('";var cookie=', 1)[0]
  script = prelude + 'RLCONF={"wgArticleId":8372,"wgRevisionId":32427};'
  self.assertEqual(observed.table_root_configuration(script, classes)['wgRevisionId'], 32427)
  for changed in (script.replace('anwiktionarymwclientpreferences','xxwiktionarymwclientpreferences'),
                  script.replace('vector-toc-not-available','vector-toc-not-availablx'),
                  script.replace('RLCONF=','if(false)RLCONF=')):
   with self.assertRaises(ValueError): observed.table_root_configuration(changed, classes)
  with self.assertRaises(ValueError): observed.table_root_configuration(script, classes + ' foreign')

 def setUp(self):
  root=Path(__file__).parent/'testdata'
  self.snapshot_path=root/'ru-current-table-root/figure-page-observations.json'
  self.namespace_path=root/'ru-denaske114/namespace-registry.tsv'
  self.defaults_path=root/'ru-current5573/normal-figure-siteinfo.raw.json'
  self.raw=self.snapshot_path.read_bytes();self.namespace=self.namespace_path.read_bytes();self.defaults=self.defaults_path.read_bytes()

 def test_genuine_root_only_pack_and_snapshot_roundtrip(self):
  self.assertEqual(observed.digest(self.raw),'fbc9d52baa6cdad8e66206890cae0a7644a77d80096c8aa8bf80f9a393e8eee9')
  doc=observed.validate_document(self.raw,self.namespace,self.defaults);self.assertEqual(doc['pages'],[]);self.assertTrue(doc['table_roots'])
  with tempfile.TemporaryDirectory() as tmp:
   out=Path(tmp)/'pack';record=observed.pack(self.snapshot_path,self.namespace_path,self.defaults_path,out)
   self.assertEqual((out/observed.SNAPSHOT).read_bytes(),self.raw);self.assertEqual(observed.validate_snapshot(out/observed.SNAPSHOT,'ruwiktionary','20261001'),record)
 def test_empty_pages_and_roots_refused(self):
  doc=json.loads(self.raw);doc['table_roots']=[]
  with self.assertRaises(ValueError):observed.validate_document(observed.encoded(doc),self.namespace,self.defaults)
 def test_invalid_root_refused(self):
  doc=json.loads(self.raw);doc['table_roots']=[{}]
  with self.assertRaises(ValueError):observed.validate_document(observed.encoded(doc),self.namespace,self.defaults)
 def test_root_digest_grammar_and_namespace_authentication_retained(self):
  doc=json.loads(self.raw);doc['namespace_sha256']='0'*64
  with self.assertRaises(ValueError):observed.validate_document(observed.encoded(doc),self.namespace,self.defaults)
  doc=json.loads(self.raw);root=doc['table_roots'][0];root['raw_sha256']='not-a-sha256'
  with self.assertRaises(ValueError):observed.validate_document(observed.encoded(doc),self.namespace,self.defaults)

 def test_first_row_and_header_source_boundaries(self):
  for old,new in (('|-\n!colspan="11"','|-\n|-\n!colspan="11"'),('|-\n!colspan="11"','|- style="color:red"\n!colspan="11"'),('!colspan="11"','!colspan="0"'),('!colspan="11"','!colspan="65536"')):
   with self.subTest(new=new):
    doc=json.loads(self.raw);root=doc['table_roots'][0];assert old in root['source'];root['source']=root['source'].replace(old,new,1)
    with self.assertRaises(ValueError):observed.validate_document(observed.encoded(doc),self.namespace,self.defaults)
 def altered_response(self,old,new):
  doc=json.loads(self.raw);root=doc['table_roots'][0];response=root['response'];opening=response.encode()[root['observed_table']['start']:root['observed_table']['end']]
  assert old in response;root['response']=response.replace(old,new,1);raw=root['response'].encode();at=raw.find(opening);assert at>=0 and raw.find(opening,at+1)<0;root['observed_table']=dict(start=at,end=at+len(opening))
  receipt=json.loads(root['receipt']);receipt['sources'][0].update(bytes=len(raw),sha256=observed.digest(raw));root['receipt']=json.dumps(receipt)
  return doc
 def test_authored_parent_and_captured_attribute_guards(self):
  for old,new in (('style="width:auto;margin:0px;overflow:auto;"','style="width:auto;margin:1px;overflow:auto;"'),('style="width:auto;margin:0px;overflow:auto;"','style="width:auto;margin:0px;overflow:auto;" onclick="bad"')):
   with self.subTest(new=new):
    doc=self.altered_response(old,new)
    with self.assertRaises(ValueError):observed.validate_document(observed.encoded(doc),self.namespace,self.defaults)
  doc=json.loads(self.raw);root=doc['table_roots'][0];root['source']=root['source'].replace('<div style="width:auto;margin:0px;overflow:auto;">','<div style="width:auto;margin:0px;overflow:auto;" class="foreign">');delta=len(root['source'].encode())-len(json.loads(self.raw)['table_roots'][0]['source'].encode());root['source_table']={k:v+delta for k,v in root['source_table'].items()}
  with self.assertRaises(ValueError):observed.validate_document(observed.encoded(doc),self.namespace,self.defaults)
 def test_unicode_section_tokens_keep_native_byte_and_identity_limits(self):
  for old,new in (('data-mw-section-id="1"','data-mw-section-id="-1"'),('data-mw-section-id="1"','data-mw-section-id="01"'),('aria-labelledby="Японский"','aria-labelledby="Япон ский"'),('aria-labelledby="Японский"','aria-labelledby="'+('я'*129)+'"')):
   with self.subTest(new=new[:80]):
    doc=self.altered_response(old,new)
    with self.assertRaises(ValueError):observed.validate_document(observed.encoded(doc),self.namespace,self.defaults)

 def test_source_prefix_and_closed_style_match_native_custody(self):
  for prefix in ('<span>\n','<nav>\n'):
   with self.subTest(prefix=prefix):
    source=(prefix+'<div style="width:auto;margin:0px;overflow:auto;">\n{|').encode()
    with self.assertRaises(ValueError):observed.table_root_source_parent(source,len(source)-2)
  for style in ('background:url(https://x)','width:calc(100% - 1px)','width:10px\\bad','color:"red"'):
   with self.subTest(style=style):
    source=('<div style="'+style+'">\n{|').encode()
    with self.assertRaises(ValueError):observed.table_root_source_parent(source,len(source)-2)

 def test_root_parent_block_boundary_and_first_header_child(self):
  for prefix in ('preceding text\n','preceding text\n\n ','preceding text\n\n\t','preceding text\n \n'):
   source=(prefix+'<div style="width:auto;margin:0px;overflow:auto;">\n{|').encode()
   with self.subTest(prefix=prefix),self.assertRaises(ValueError):observed.table_root_source_parent(source,len(source)-2)
  doc=json.loads(self.raw);response=doc['table_roots'][0]['response'];opening=response.encode()[doc['table_roots'][0]['observed_table']['start']:doc['table_roots'][0]['observed_table']['end']].decode();at=response.index(opening)+len(opening);tail=response[at:];th=tail.index('<th');needle=tail[th:tail.index('>',th)+1]
  doc=self.altered_response(needle,'<td>foreign</td>'+needle)
  with self.assertRaises(ValueError):observed.validate_document(observed.encoded(doc),self.namespace,self.defaults)

 def test_native_configuration_prelude_and_json_boundaries(self):
  import html.parser
  response=json.loads(self.raw)['table_roots'][0]['response']
  class Scripts(html.parser.HTMLParser):
   def __init__(self):super().__init__();self.in_script=False;self.items=[];self.classes=None
   def handle_starttag(self,tag,attrs):
    if tag=='html':self.classes=dict(attrs)['class']
    if tag=='script':self.in_script=True
   def handle_endtag(self,tag):
    if tag=='script':self.in_script=False
   def handle_data(self,text):
    if self.in_script and 'RLCONF='in text:self.items.append(text)
  parser=Scripts();parser.feed(response);text,=parser.items
  self.assertEqual(observed.table_root_configuration(text,parser.classes)['wgArticleId'],1500042)
  with self.assertRaises(ValueError):observed.table_root_configuration(text,parser.classes+' foreign')
  marker=text.index('RLCONF=')
  for bad in ('x'+text, text+'RLCONF={};',text[:marker]+'RLCONF={"x":'+('['*33)+'0'+(']'*33)+'};',text[:marker]+'RLCONF={"x":1,"x":2};',text[:marker]+'RLCONF={} ',text[:marker]+'RLCONF=[];'):
   with self.subTest(bad=bad[-70:]),self.assertRaises(ValueError):observed.table_root_configuration(bad,parser.classes)
  self.assertEqual(observed.table_root_configuration('RLCONF={"x":1};',None),{'x':1})

  for token in ('NaN','Infinity','-Infinity'):
   with self.subTest(token=token),self.assertRaises(ValueError):observed.table_root_configuration('RLCONF={"x":'+token+'};',None)


if __name__ == '__main__':
    unittest.main()
