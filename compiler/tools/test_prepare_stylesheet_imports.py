import copy
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
import prepare_stylesheet_imports as collector


class StylesheetImportsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.css = ('/* @import "not-an-import"; */\n@import "' + collector.LEAF_URL + '";\n.hiddenStructure {display:none;}\n').encode()
        self.auth = {'wiki': 'ptwiktionary', 'dump_date': '20261001', 'title': 'MediaWiki:Common.css', 'content_model': 'css',
                     'decoded_source_bytes': len(self.css), 'decoded_source_sha256': collector.digest(self.css),
                     'namespace_sha256': 'a' * 64, 'page_id': 56264, 'revision_id': 3258806}
        self.root_css = self.root / 'root.css'
        self.authority = self.root / 'authority.json'
        self.root_css.write_bytes(self.css)
        self.authority.write_text(json.dumps(self.auth))
        self.leaf = b'.box { background: #fff; }\n'
        self.value = {'query': {'general': {'wikiid': 'mediawikiwiki'}, 'pages': [{
            'pageid': 123, 'ns': 8, 'title': collector.TITLE,
            'revisions': [{'revid': 456, 'timestamp': '2026-01-02T12:00:00Z',
                           'sha1': hashlib.sha1(self.leaf).hexdigest(),
                           'slots': {'main': {'contentmodel': 'css', 'content': self.leaf.decode()}}}]}]}}
        self.calls = []

    def transport(self, url, timeout, accept):
        self.calls.append((url, accept))
        self.assertLessEqual(timeout, 10)
        raw = json.dumps(self.value).encode() if accept == 'application/json' else self.leaf
        return 200, {'Content-Type': accept + '; charset=UTF-8', 'ETag': 'retained'}, raw, url

    def capture(self):
        root = self.root / 'capture'
        snapshot = collector.capture(root, self.root_css, self.authority, transport=self.transport)
        return root, snapshot

    def reseal(self, root, name):
        manifest = json.loads((root / collector.MANIFEST).read_text())
        manifest['artifacts'][name] = collector.digest((root / name).read_bytes())
        (root / collector.MANIFEST).write_text(json.dumps(manifest))
        (root / collector.COMPLETE).write_text(json.dumps({'schema': collector.SCHEMA, 'manifest_sha256': collector.digest((root / collector.MANIFEST).read_bytes())}))

    def test_exact_capture_two_requests_and_offline_replay(self):
        root, snapshot = self.capture()
        self.assertEqual(2, len(self.calls))
        self.assertEqual(collector.LEAF_URL + '&oldid=456', self.calls[1][0])
        self.assertEqual(self.leaf.decode(), snapshot['resource']['css'])
        self.assertEqual(snapshot, collector.verify(root))
        self.assertEqual(2, len(self.calls))

    def test_failure_retained_without_retry_or_completion(self):
        def denied(url, timeout, accept):
            self.calls.append(url)
            return 403, {'Content-Type': 'text/plain'}, b'blocked', url
        root = self.root / 'failed'
        with self.assertRaisesRegex(ValueError, 'no retry'):
            collector.capture(root, self.root_css, self.authority, transport=denied)
        self.assertEqual(1, len(self.calls))
        self.assertEqual(b'blocked', (root / 'request-01.response').read_bytes())
        self.assertFalse((root / collector.COMPLETE).exists())
        self.assertFalse(json.loads((root / 'failure.json').read_text())['retry'])

    def test_redirect_and_mime_fail_without_second_request(self):
        for index, (mime, final) in enumerate([('application/json', 'https://other.example/api'), ('text/html', None)]):
            def invalid(url, timeout, accept):
                self.calls.append(url)
                return 200, {'Content-Type': mime}, b'{}', final or url
            with self.assertRaises(ValueError):
                collector.capture(self.root / ('bad' + str(index)), self.root_css, self.authority, transport=invalid)
        self.assertEqual(2, len(self.calls))

    def test_raw_revision_mismatch_does_not_complete(self):
        def mismatch(url, timeout, accept):
            result = self.transport(url, timeout, accept)
            return result if accept == 'application/json' else (200, {'Content-Type': accept}, b'changed', url)
        root = self.root / 'mismatch'
        with self.assertRaisesRegex(ValueError, 'differs'):
            collector.capture(root, self.root_css, self.authority, transport=mismatch)
        self.assertFalse((root / collector.COMPLETE).exists())
        self.assertEqual(2, len(self.calls))

    def test_api_identity_missing_revision_default_and_source_hash_rejected(self):
        changes = [lambda x: x['query']['general'].update(wikiid='ptwiktionary'),
                   lambda x: x['query']['pages'][0].update(missing=True),
                   lambda x: x['query']['pages'][0]['revisions'][0].update(sha1='0' * 40),
                   lambda x: x['query']['pages'][0]['revisions'][0]['slots']['main'].update(contentmodel='wikitext'),
                   lambda x: x.update(warnings={'unexpected': {}})]
        for change in changes:
            value = copy.deepcopy(self.value)
            change(value)
            with self.assertRaises(ValueError):
                collector.parse_api(json.dumps(value).encode())

    def test_requirement_excludes_other_origins_conditions_late_and_escaped_imports(self):
        good = collector.requirement(self.css)
        self.assertEqual(collector.LEAF_URL, good['resolved_url'])
        for source in ['@import "http://127.0.0.1/private.css";',
                       '@import "https://www.mediawiki.org/other.css";',
                       '.x{} @import "' + collector.LEAF_URL + '";',
                       '@import "' + collector.LEAF_URL + '" print;',
                       '@import "https://www.mediawiki.org/\\escaped.css";',
                       '/* @import "' + collector.LEAF_URL + '"; */ .x{}']:
            with self.assertRaises(ValueError):
                collector.requirement(source.encode())

    def test_replay_rejects_resealed_wrong_target_and_source(self):
        root, _ = self.capture()
        snapshot = json.loads((root / collector.SNAPSHOT).read_text())
        snapshot['resource']['url'] = 'https://www.mediawiki.org/unrequested.css'
        (root / collector.SNAPSHOT).write_text(json.dumps(snapshot))
        self.reseal(root, collector.SNAPSHOT)
        with self.assertRaisesRegex(ValueError, 'projection'):
            collector.verify(root)

    def test_replay_rejects_resealed_false_http_success(self):
        root, _ = self.capture()
        receipt = json.loads((root / 'request-02.receipt.json').read_text())
        receipt['status'] = 403
        (root / 'request-02.receipt.json').write_text(json.dumps(receipt))
        self.reseal(root, 'request-02.receipt.json')
        with self.assertRaisesRegex(ValueError, 'HTTP'):
            collector.verify(root)

    def test_wrong_root_authority_fails_before_network(self):
        self.auth['decoded_source_sha256'] = '0' * 64
        self.authority.write_text(json.dumps(self.auth))
        with self.assertRaisesRegex(ValueError, 'authority'):
            collector.capture(self.root / 'wrong-root', self.root_css, self.authority, transport=self.transport)
        self.assertFalse(self.calls)

    def test_bounded_regular_reads_and_generation_symlinks(self):
        oversized = self.root / 'oversized'
        oversized.write_bytes(b'abcd')
        with self.assertRaises(ValueError):
            collector.read(oversized, 3)
        fifo = self.root / 'fifo'
        os.mkfifo(fifo)
        with self.assertRaises(ValueError):
            collector.read(fifo)
        link = self.root / 'link'
        link.symlink_to(oversized)
        with self.assertRaises(ValueError):
            collector.read(link)
        root, _ = self.capture()
        other = self.root / 'generation-link'
        other.symlink_to(root, target_is_directory=True)
        with self.assertRaises(ValueError):
            collector.verify(other)

    def test_boolean_ids_are_not_page_or_revision_authority(self):
        for field in ['page_id', 'revision_id']:
            auth = dict(self.auth)
            auth[field] = True
            with self.assertRaises(ValueError):
                collector.authority(json.dumps(auth).encode(), self.css)
        for revision in [False, True]:
            value = copy.deepcopy(self.value)
            value['query']['pages'][0]['revisions'][0]['revid'] = revision
            with self.assertRaises(ValueError):
                collector.parse_api(json.dumps(value).encode())

    def test_temporal_scope_and_order_cannot_be_resealed_as_historical(self):
        root, _ = self.capture()
        original = json.loads((root / collector.MANIFEST).read_text())
        for key, replacement in [('temporal_scope', 'historical dump state'), ('retrieved_utc', '1900-01-01T00:00:00Z')]:
            manifest = copy.deepcopy(original)
            manifest[key] = replacement
            (root / collector.MANIFEST).write_text(json.dumps(manifest))
            (root / collector.COMPLETE).write_text(json.dumps({'schema': collector.SCHEMA, 'manifest_sha256': collector.digest((root / collector.MANIFEST).read_bytes())}))
            with self.assertRaises(ValueError):
                collector.verify(root)

    def test_recorded_producer_roles_are_replayed_not_restamped(self):
        root, expected = self.capture()
        original = json.loads((root / collector.MANIFEST).read_text())
        manifest = copy.deepcopy(original)
        manifest['producer']['generator_sha256'] = '81711a437ebe646a2ae4434d208042752c41013a68ec937092672c30b7703100'
        (root / collector.MANIFEST).write_text(json.dumps(manifest))
        (root / collector.COMPLETE).write_text(json.dumps({'schema': collector.SCHEMA, 'manifest_sha256': collector.digest((root / collector.MANIFEST).read_bytes())}))
        self.assertEqual(expected, collector.verify(root))
        for bad in [None, {}, {'generator_sha256': True, 'dependency_sha256': {}},
                    {'generator_sha256': 'f' * 64, 'dependency_sha256': {'unexpected.py': 'f' * 64}}]:
            manifest = copy.deepcopy(original)
            manifest['producer'] = bad
            (root / collector.MANIFEST).write_text(json.dumps(manifest))
            (root / collector.COMPLETE).write_text(json.dumps({'schema': collector.SCHEMA, 'manifest_sha256': collector.digest((root / collector.MANIFEST).read_bytes())}))
            with self.assertRaises(ValueError):
                collector.verify(root)

    def test_capture_artifacts_rejects_rebound_same_context_summary(self):
        root, _ = self.capture()
        old = collector.validate_snapshot(root / collector.SNAPSHOT)
        self.leaf = b'.new-generation { background:#abc; }\n'
        revision = self.value['query']['pages'][0]['revisions'][0]
        revision['revid'] = 457
        revision['sha1'] = hashlib.sha1(self.leaf).hexdigest()
        revision['slots']['main']['content'] = self.leaf.decode()
        other = self.root / 'new-generation'
        collector.capture(other, self.root_css, self.authority, transport=self.transport)
        with self.assertRaisesRegex(ValueError, 'context'):
            collector.capture_artifacts(other / collector.SNAPSHOT, old)
        record = collector.validate_snapshot(other / collector.SNAPSHOT)
        record['namespace_registry_sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'context'):
            collector.capture_artifacts(other / collector.SNAPSHOT, record)


class CustomPropertyInputTests(unittest.TestCase):
    url = 'https://es.wiktionary.org/w/index.php?title=control&useskin=vector-2022'
    link = 'https://es.wiktionary.org/w/load.php?only=styles&skin=vector-2022&modules=control'

    def artifacts(self, extra_head='', root_style=''):
        css = b'.head{font-weight:bold}'
        html = ('<html class="skin-theme-clientpref-day"><head><meta name="generator" content="MediaWiki test">'
                '<style>:root{--ink:#111111}</style>' + extra_head + '<link rel="stylesheet" href="' + self.link.replace('&', '&amp;') + '">'
                '</head><body style="' + root_style + '"><div class="mw-parser-output"><style>.x{--ink:#333333}</style></div></body></html>').encode()
        result = {'root-common.css': css, 'root-authority.json': json.dumps({
            'wiki': 'eswiktionary', 'dump_date': '20261001', 'namespace_sha256': 'a' * 64,
            'title': 'MediaWiki:Common.css', 'content_model': 'css', 'decoded_source_sha256': collector.digest(css),
            'decoded_source_bytes': len(css), 'page_id': 1, 'revision_id': 2}).encode()}
        for number, url, mime, body in [(2, self.url, 'text/html', html), (3, self.link, 'text/css', b':root{--ink:#222222}')]:
            prefix = f'request-{number:02d}'
            result[prefix + '.json'] = json.dumps({'url': url, 'accept': mime, 'method': 'GET', 'retry': False}).encode()
            result[prefix + '.response'] = body
            result[prefix + '.receipt.json'] = json.dumps({'accepted': True, 'status': 200, 'final_url': url,
                'started_utc': '2026-11-06T01:00:00Z', 'ended_utc': '2026-11-06T01:00:01Z',
                'response_bytes': len(body), 'response_sha256': collector.digest(body), 'headers': {'content-type': mime}}).encode()
        return result

    def test_custom_context_keeps_order_ancestor_override_and_distinct_epoch(self):
        value = collector.custom_snapshot(self.artifacts(root_style='--ink:#abcdef'))
        self.assertEqual([':root{--ink:#111111}', ':root{--ink:#222222}', '.x{--ink:#333333}'], [item['css'] for item in value['sources']])
        self.assertEqual('--ink:#abcdef', value['ancestors'][1]['inline_css'])
        self.assertEqual('control', value['page_title'])
        self.assertIsNone(value['dark'])  # day class does not reveal OS preference
        self.assertIn('not historical', value['temporal_scope'])
        self.assertEqual('MediaWiki test', value['generator'])
        raw = self.artifacts()['request-02.response'].replace(b'rel="stylesheet"', b'rel="StyleSheet"')
        parsed, _, _ = collector.custom_page_context(raw, self.url)
        self.assertEqual([self.link], parsed.links)

    def test_custom_context_refuses_unknown_applicability_or_changed_response(self):
        for declaration in ('<style media="print">:root{--ink:red}</style>', '<style type="text/less">:root{--ink:red}</style>',
                            '<style scoped>:root{--ink:red}</style>', '<link rel="alternate stylesheet" href="x.css">',
                            '<link rel="stylesheet" disabled href="x.css">', '<base href="https://other.invalid/">'):
            with self.subTest(declaration=declaration), self.assertRaises(ValueError):
                collector.custom_snapshot(self.artifacts(extra_head=declaration))
        with self.assertRaises(ValueError):
            collector.custom_snapshot(self.artifacts(root_style='--ink:&#35;abcdef'))
        for kind in ('bytes', 'request', 'context'):
            artifacts = self.artifacts()
            if kind == 'bytes':
                artifacts['request-03.response'] = b':root{--ink:red}'
            elif kind == 'request':
                request = json.loads(artifacts['request-03.json']); request['retry'] = True
                artifacts['request-03.json'] = json.dumps(request).encode()
            else:
                artifacts['request-02.response'] = artifacts['request-02.response'].replace(b'clientpref-day', b'clientpref-os')
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                collector.custom_snapshot(artifacts)




class JvStylesheetImportsTests(unittest.TestCase):
    transport = StylesheetImportsTests.transport
    capture = StylesheetImportsTests.capture
    reseal = StylesheetImportsTests.reseal

    def setUp(self):
        StylesheetImportsTests.setUp(self)
        self.context = collector.import_context('jvwiktionary')
        self.css = ('@import "' + self.context['leaf_url'][6:] + '";\n.page-Main {display:none;}\n').encode()
        self.auth.update(wiki='jvwiktionary', title='MédhiaWiki:Common.css', page_id=2634, revision_id=111278,
                         decoded_source_bytes=len(self.css), decoded_source_sha256=collector.digest(self.css))
        self.root_css.write_bytes(self.css)
        self.authority.write_text(json.dumps(self.auth))
        self.value['query']['general']['wikiid'] = 'jvwiki'
        self.value['query']['namespaces'] = {'8': {'id': 8, 'name': 'MediaWiki', 'canonical': 'MediaWiki'}}
        self.value['query']['pages'][0]['title'] = self.context['title']

    def test_jv_exact_origin_revision_two_requests_and_offline_replay(self):
        root, snapshot = self.capture()
        self.assertEqual(2, len(self.calls))
        self.assertTrue(self.calls[0][0].startswith(self.context['api'] + '?'))
        self.assertEqual(self.context['leaf_url'] + '&oldid=456', self.calls[1][0])
        self.assertEqual('jvwiktionary', snapshot['wiki'])
        self.assertEqual('jvwiki', snapshot['resource']['revision']['wiki'])
        self.assertEqual(self.context['leaf_url'], snapshot['resource']['url'])
        self.assertEqual(self.css, (root / 'root-common.css').read_bytes())
        self.assertEqual(snapshot, collector.verify(root))
        self.assertEqual(2, len(self.calls))

    def test_jv_profile_does_not_admit_pt_other_hosts_titles_or_conditions(self):
        for wiki in ['enwiktionary', 'jvwiki', '', None]:
            with self.assertRaises(ValueError):
                collector.import_context(wiki)
        for css in [('@import "' + collector.LEAF_URL + '";').encode(),
                    b'@import "https://private.invalid/x.css";',
                    ('@import "' + self.context['leaf_url'] + '" print;').encode(),
                    ('x{} @import "' + self.context['leaf_url'] + '";').encode()]:
            with self.assertRaises(ValueError):
                collector.requirement(css, 'jvwiktionary')
        with self.assertRaises(ValueError):
            collector.requirement(self.css)
        with self.assertRaises(ValueError):
            collector.parse_api(json.dumps(self.value).encode())
        wrong = dict(self.auth, title='MediaWiki:Common.css')
        with self.assertRaises(ValueError):
            collector.authority(json.dumps(wrong).encode(), self.css)
        self.assertEqual([], self.calls)

    def test_jv_replay_rejects_resealed_profile_or_temporal_rebinding(self):
        root, _ = self.capture()
        original = (root / collector.SNAPSHOT).read_bytes()
        snapshot = json.loads(original)
        snapshot['resource']['url'] = collector.LEAF_URL
        (root / collector.SNAPSHOT).write_text(json.dumps(snapshot))
        self.reseal(root, collector.SNAPSHOT)
        with self.assertRaisesRegex(ValueError, 'projection'):
            collector.verify(root)
        (root / collector.SNAPSHOT).write_bytes(original)
        self.reseal(root, collector.SNAPSHOT)
        manifest = json.loads((root / collector.MANIFEST).read_text())
        manifest['temporal_scope'] = collector.TEMPORAL_SCOPE
        (root / collector.MANIFEST).write_text(json.dumps(manifest))
        (root / collector.COMPLETE).write_text(json.dumps({'schema': collector.SCHEMA, 'manifest_sha256': collector.digest((root / collector.MANIFEST).read_bytes())}))
        with self.assertRaisesRegex(ValueError, 'temporal'):
            collector.verify(root)
        self.assertEqual(2, len(self.calls))

    def test_jv_nested_or_conditional_source_is_retained_without_discovery_fetch(self):
        self.leaf = b'@import "nested.css";\n@media print {.box {background:#fff;}}\n'
        rev = self.value['query']['pages'][0]['revisions'][0]
        rev['sha1'] = hashlib.sha1(self.leaf).hexdigest()
        rev['slots']['main']['content'] = self.leaf.decode()
        root, snapshot = self.capture()
        self.assertEqual(self.leaf.decode(), snapshot['resource']['css'])
        self.assertEqual(self.leaf, (root / 'resource.css').read_bytes())
        self.assertEqual(2, len(self.calls))
        self.assertEqual(snapshot, collector.verify(root))
        self.assertEqual(2, len(self.calls))

    def test_jv_remote_namespace_normalization_is_proved_not_guessed(self):
        value = copy.deepcopy(self.value)
        value['query']['namespaces']['8']['name'] = 'MédhiaWiki'
        value['query']['normalized'] = [{'fromencoded': False, 'from': 'MediaWiki:Common.css', 'to': 'MédhiaWiki:Common.css'}]
        value['query']['pages'][0]['title'] = 'MédhiaWiki:Common.css'
        revision, source = collector.parse_api(json.dumps(value).encode(), self.context)
        self.assertEqual('MédhiaWiki:Common.css', revision['title'])
        self.assertEqual(self.leaf, source)
        for change in (lambda q: q.pop('normalized'),
                       lambda q: q['namespaces']['8'].update(canonical='Other'),
                       lambda q: q['namespaces']['8'].update(id=True),
                       lambda q: q['normalized'][0].update(fromencoded='false'),
                       lambda q: q['normalized'][0].update(to='MédhiaWiki:Other.css'),
                       lambda q: q['pages'][0].update(title='MediaWiki:Unrelated.css')):
            wrong = copy.deepcopy(value)
            change(wrong['query'])
            with self.assertRaises(ValueError):
                collector.parse_api(json.dumps(wrong).encode(), self.context)
        self.assertEqual([], self.calls)

    def retained_first(self, name):
        root = self.root / name
        root.mkdir()
        collector.evidence.put(root / 'root-common.css', self.css)
        collector.evidence.document(root / 'root-authority.json', self.auth)
        selected = collector.requirement(self.css, 'jvwiktionary')
        collector.evidence.document(root / 'requested.json', {'schema': collector.SCHEMA, 'root_css_sha256': collector.digest(self.css), 'import': selected, 'max_requests': 2, 'no_retries': True})
        url = self.context['api'] + '?' + collector.urllib.parse.urlencode(collector.api_query(self.context))
        collector.request(root, 1, url, 'application/json', self.transport, collector.time.monotonic() + 10)
        producer = collector.producer()
        producer['generator_sha256'] = '3553a53ccd16366b6bbaead6cb4c947361082387e94d16d33d5f96986ae206b7'
        collector.evidence.document(root / 'failure.json', {'schema': collector.SCHEMA, 'error': 'old intake stopped', 'ended_utc': collector.evidence.utc(), 'producer': producer, 'retry': False})
        return root

    def test_retained_first_response_continuation_never_reissues_api_or_restamps_it(self):
        self.value['query']['namespaces']['8']['name'] = 'MédhiaWiki'
        self.value['query']['normalized'] = [{'fromencoded': False, 'from': 'MediaWiki:Common.css', 'to': 'MédhiaWiki:Common.css'}]
        self.value['query']['pages'][0]['title'] = 'MédhiaWiki:Common.css'
        parent = self.retained_first('first-only')
        before = {p.name: p.read_bytes() for p in parent.iterdir()}
        self.calls.clear()
        root = self.root / 'continued'
        snapshot = collector.resume_capture(root, parent, self.root_css, self.authority, transport=self.transport)
        self.assertEqual([(self.context['leaf_url'] + '&oldid=456', 'text/css')], self.calls)
        for name in ['request-01.json', 'request-01.receipt.json', 'request-01.response', 'root-common.css', 'root-authority.json', 'requested.json']:
            self.assertEqual(before[name], (root / name).read_bytes())
        self.assertEqual(before['failure.json'], (root / 'continued-from.failure.json').read_bytes())
        self.assertEqual(before, {p.name: p.read_bytes() for p in parent.iterdir()})
        self.assertEqual('MédhiaWiki:Common.css', snapshot['resource']['revision']['title'])
        self.assertEqual(snapshot, collector.verify(root))
        self.assertEqual(1, len(self.calls))

    def test_continuation_rejects_failed_or_changed_first_or_any_second_request(self):
        for number, defect in enumerate(['status', 'response', 'second', 'overlap']):
            parent = self.retained_first('first-' + str(number))
            if defect == 'status':
                receipt = json.loads((parent / 'request-01.receipt.json').read_text())
                receipt.update(status=403, accepted=False)
                (parent / 'request-01.receipt.json').write_text(json.dumps(receipt))
            elif defect == 'response':
                (parent / 'request-01.response').write_bytes(b'changed')
            elif defect == 'second':
                (parent / 'request-02.json').write_text('{}')
            self.calls.clear()
            destination = parent / 'nested' if defect == 'overlap' else self.root / ('bad-' + str(number))
            with self.assertRaises(ValueError):
                collector.resume_capture(destination, parent, self.root_css, self.authority, transport=self.transport)
            self.assertEqual([], self.calls)
            self.assertFalse(destination.exists())

    def test_continuation_preserves_raw_access_failure_without_retry(self):
        parent = self.retained_first('first-denied')
        self.calls.clear()
        def denied(url, timeout, accept):
            self.calls.append((url, accept))
            return 403, {'Content-Type': 'text/plain'}, b'denied', url
        root = self.root / 'raw-denied'
        with self.assertRaisesRegex(ValueError, 'no retry'):
            collector.resume_capture(root, parent, self.root_css, self.authority, transport=denied)
        self.assertEqual(1, len(self.calls))
        self.assertEqual(b'denied', (root / 'request-02.response').read_bytes())
        self.assertFalse((root / collector.COMPLETE).exists())
        with self.assertRaises(ValueError):
            collector.resume_capture(self.root / 'retry-forbidden', root, self.root_css, self.authority, transport=denied)
        self.assertEqual(1, len(self.calls))


if __name__ == '__main__':
    unittest.main()
