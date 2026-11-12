import copy
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
        for length in (65536, 65537, 98608, 131072):
            with self.subTest(length=length):
                doc, namespace, defaults = self.framed_form(length)
                accepted = observed.validate_document(observed.encoded(doc), namespace, defaults)
                self.assertEqual(accepted, doc)
                page = accepted['pages'][0]
                params = dict(observed.urllib.parse.parse_qsl(page['form_body'], keep_blank_values=True))
                self.assertEqual(observed.decode(page['response'])['parse']['wikitext'], params['text'])
                self.assertIsNone(observed.decode(page['response'])['parse'].get('revid'))

    def test_encoded_form_empty_over_max_and_malformed_escape_refuse(self):
        doc, namespace, defaults = self.framed_form(131073)
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


if __name__ == '__main__':
    unittest.main()
