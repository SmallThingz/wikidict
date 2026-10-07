"""Strict bounded v2 message capture, paired profiles and exact chunk replay."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from urllib.parse import parse_qs, urlsplit

import build_wiktionaries as builder
import prepare_language_messages as legacy
import prepare_language_messages_v2 as capture

WIKI = 'bnwiktionary'
DATE = '20261001'
LEGACY_SHA = 'd1391161a139f0210f7f0e91dc222cf5026ec9d8607958cef9b91a17fbce3a47'
NAMESPACE = ('# wikidict-namespace-registry-v1\n# wiki\tbnwiktionary\n'
             '# dump-date\t20261001\n# content-language\tbn\n')


def keys(count):
    return [f'Key-{number:03d}' for number in range(count)]


class Transport:
    def __init__(self, retry=False):
        self.calls = []
        self.retry = retry

    def __call__(self, url, timeout):
        self.calls.append(url)
        if self.retry:
            self.retry = False
            return 503, {'Retry-After': '1'}, b'{"error":{"code":"maxlag"}}'
        query = parse_qs(urlsplit(url).query)
        general = {'wikiid': WIKI, 'lang': 'bn'}
        if query['meta'] == ['siteinfo|languageinfo']:
            value = {'query': {'general': general, 'languageinfo': {
                code: {'code': code, 'fallbacks': chain}
                for code, chain in {'bn': [], 'en': [], 'fr': ['en']}.items()}}}
        else:
            assert query['meta'] == ['siteinfo|allmessages']
            assert 'amenableparser' not in query and 'amargs' not in query
            selected = query['ammessages'][0].split('|')
            assert len(selected) <= 32
            value = {'query': {'general': general, 'allmessages': [
                {'name': key, 'normalizedname': capture.normalize_key(key),
                 **({'missing': True} if key.endswith('003')
                    else {'content': 'বাংলা ' + key + '\n\t\\ $1'})}
                for key in selected]}}
        return 200, {'Content-Type': 'application/json'}, json.dumps(value).encode()


class MessageV2Test(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.namespace = self.base / 'namespace.tsv'
        self.namespace.write_text(NAMESPACE)

    def options(self, count, name='capture', languages=None):
        return SimpleNamespace(wiki=WIKI, date=DATE, namespace_registry=self.namespace,
            output=self.base / name, languages=languages or ['bn'],
            messages=keys(count), delay=0, wall_seconds=60)

    def collect(self, count, name='capture', languages=None, retry=False):
        args = self.options(count, name, languages)
        transport = Transport(retry)
        result = capture.capture(args, transport=transport, sleep=lambda _: None)
        return args, transport, result

    def rebind(self, root, change=None):
        inventory = capture.owned_payload(root)
        hashes = {}
        for kind in capture.KINDS:
            path = root / (kind + '.manifest.json')
            value = json.loads(path.read_text())
            value['artifacts'] = inventory
            raw = (root / (kind + '.tsv')).read_bytes()
            value.update(output_bytes=len(raw), output_sha256=capture.evidence.digest(raw))
            if change:
                change(value)
            path.write_bytes(capture.evidence.encoded(value))
            hashes[path.name] = capture.evidence.digest(path.read_bytes())
        (root / capture.COMPLETE).write_bytes(capture.evidence.encoded(
            {'schema': capture.SCHEMA, 'manifests': hashes}))

    def test_boundaries_chunk_replay_and_both_builder_dispatches(self):
        for count in (17, 24, 32, 33, 63, 64, 65, 66):
            with self.subTest(count=count):
                args, transport, result = self.collect(count, str(count), ['bn', 'fr'])
                self.assertEqual(capture.verify(args.output), result)
                expected = 1 + 2 * ((count + 31) // 32)
                self.assertEqual(len(transport.calls), expected)
                self.assertEqual(result['interface-messages']['rows'], count * 2)
                for kind in capture.KINDS:
                    path = args.output / (kind + '.tsv')
                    self.assertIs(builder.auxiliary_capture_helper(kind, path), capture)
                    self.assertEqual(capture.validate_snapshot(path, WIKI, DATE), result[kind])
                    self.assertLess((args.output / (kind + '.manifest.json')).stat().st_size,
                                    capture.MAX_MANIFEST)
                raw = (args.output / 'interface-messages.tsv').read_bytes()
                self.assertTrue(raw.startswith(b'# wikidict-interface-messages-v1\n'))
                self.assertIn(b'bn\tkey-003\tM\n', raw)
                self.assertIn('বাংলা Key-000\\n\\t\\\\ $1'.encode(), raw)

    def test_legacy_profile_stays_byte_exact_and_bounded(self):
        self.assertEqual(hashlib.sha256(Path(legacy.__file__).read_bytes()).hexdigest(), LEGACY_SHA)
        self.assertEqual(capture.producer()['dependency_sha256']['tools/prepare_language_messages.py'],
                         LEGACY_SHA)
        args = self.options(16, 'legacy')
        old = legacy.capture(args, transport=Transport(), sleep=lambda _: None)
        self.assertEqual(legacy.verify(args.output), old)
        for kind in legacy.KINDS:
            self.assertIs(builder.auxiliary_capture_helper(kind, args.output / (kind + '.tsv')), legacy)
        args = self.options(17, 'legacy-rejected')
        transport = Transport()
        with self.assertRaisesRegex(ValueError, 'excessive requested'):
            legacy.capture(args, transport=transport, sleep=lambda _: None)
        self.assertFalse(args.output.exists())
        self.assertEqual(transport.calls, [])

        # Exact prior-v2 producer retains its original evidence and64-key bound.
        self.assertEqual(capture.PRE_LICENSE_GENERATOR_SHA256,
                         'ee9c7745aa4bcea3bb44060fd49d086ae49ad1aa47fb2cd82527fbe6f47ebd08')
        for count in (64, 65, 66):
            args, _, _ = self.collect(count, 'prior-v2-' + str(count))
            self.rebind(args.output, lambda value: value.update(
                generator_sha256=capture.PRE_LICENSE_GENERATOR_SHA256))
            if count == 64:
                capture.verify(args.output)
                self.rebind(args.output, lambda value: value['dependency_sha256'].update(
                    {'tools/prepare_file_metadata.py': '0' * 64}))
            with self.assertRaisesRegex(ValueError, 'original collector'):
                capture.verify(args.output)

    def test_sixty_seven_rejected_before_capture_or_transport(self):
        args = self.options(67)
        transport = Transport()
        with self.assertRaisesRegex(ValueError, 'excessive requested'):
            capture.capture(args, transport=transport, sleep=lambda _: None)
        self.assertFalse(args.output.exists())
        self.assertEqual(transport.calls, [])

    def test_sixty_seven_resealed_selection_rejected_by_replay(self):
        args, _, _ = self.collect(64)
        path = args.output / (capture.PREFIX + 'requested.json')
        config = json.loads(path.read_text())
        config['keys'] = keys(67)
        path.write_bytes(capture.evidence.encoded(config))
        self.rebind(args.output, lambda value: value.update(keys=keys(67)))
        with self.assertRaisesRegex(ValueError, 'Invalid captured language/message selection'):
            capture.verify(args.output)

    def test_duplicate_missing_and_reordered_chunks_rejected_after_reseal(self):
        for mode in ('duplicate', 'missing', 'reordered'):
            with self.subTest(mode=mode):
                args, _, _ = self.collect(66, mode)
                def mutate(value):
                    rows = value['requests']
                    if mode == 'duplicate':
                        rows[2] = copy.deepcopy(rows[1])
                    elif mode == 'missing':
                        del rows[2]
                    else:
                        rows[1], rows[2] = rows[2], rows[1]
                self.rebind(args.output, mutate)
                with self.assertRaisesRegex(ValueError, 'message chunk|coverage'):
                    capture.verify(args.output)

    def test_overlapping_request_chunk_rejected_after_reseal(self):
        args, _, result = self.collect(64)
        path = args.output / result['interface-messages']['requests'][2]['request']
        request = json.loads(path.read_text())
        request['keys'][0] = keys(64)[0]
        request['query'] = capture.query_for(WIKI, request['language'], request['keys'])
        request['url'] = capture.query_url(WIKI, request['query'])
        path.write_bytes(capture.evidence.encoded(request))
        self.rebind(args.output)
        with self.assertRaisesRegex(ValueError, 'requested message chunk'):
            capture.verify(args.output)

    def test_rendered_rows_replayed_even_after_coherent_tamper(self):
        args, _, _ = self.collect(24)
        path = args.output / 'interface-messages.tsv'
        path.write_bytes(path.read_bytes().replace('বাংলা'.encode(), b'wrong', 1))
        self.rebind(args.output)
        with self.assertRaisesRegex(ValueError, 'Rendered TSV'):
            capture.verify(args.output)

    def test_paired_schema_and_own_producer_identity_required(self):
        for mode in ('paired', 'legacy-producer', 'unknown-producer', 'unknown-schema'):
            with self.subTest(mode=mode):
                args, _, _ = self.collect(24, mode)
                if mode in ('legacy-producer', 'unknown-producer'):
                    self.rebind(args.output, lambda value: value.update(
                        generator_sha256=LEGACY_SHA if mode == 'legacy-producer' else '0' * 64))
                    with self.assertRaisesRegex(ValueError, 'original collector'):
                        capture.verify(args.output)
                else:
                    path = args.output / 'interface-messages.manifest.json'
                    value = json.loads(path.read_text())
                    value['schema'] = legacy.SCHEMA if mode == 'paired' else 'unknown'
                    path.write_bytes(capture.evidence.encoded(value))
                    with self.assertRaises(ValueError):
                        capture.verify(args.output)
                    selected = builder.auxiliary_capture_helper(
                        'interface-messages', args.output / 'interface-messages.tsv')
                    self.assertIs(selected, legacy)
                    with self.assertRaises(ValueError):
                        selected.validate_snapshot(args.output / 'interface-messages.tsv', WIKI, DATE)

    def test_namespace_binding_and_encoded_url_bounds_remain(self):
        args, _, _ = self.collect(24)
        path = args.output / (capture.PREFIX + 'namespace-registry.tsv')
        path.write_text(NAMESPACE.replace('content-language\tbn', 'content-language\ten'))
        self.rebind(args.output)
        with self.assertRaisesRegex(ValueError, 'namespace identity'):
            capture.verify(args.output)
        args = self.options(16, 'url-bound')
        args.messages = ['K' + str(i).zfill(2) + '%' * 252 for i in range(16)]
        transport = Transport()
        with self.assertRaisesRegex(ValueError, 'bounded URL'):
            capture.capture(args, transport=transport, sleep=lambda _: None)
        self.assertEqual(len(transport.calls), 1)
        self.assertFalse((args.output / capture.COMPLETE).exists())

    def test_retry_evidence_is_preserved_across_chunks(self):
        args, transport, _ = self.collect(24, retry=True)
        self.assertEqual(len(transport.calls), 3)
        receipts = [json.loads(p.read_text()) for p in args.output.glob('*.receipt.json')]
        self.assertEqual(sum(not row['accepted'] for row in receipts), 1)
        self.assertTrue(capture.verify(args.output)['interface-messages']['candidate_queries_complete'])


if __name__ == '__main__':
    unittest.main()
