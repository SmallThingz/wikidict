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
            messages=[*keys(count - 1), 'parser-template-loop-warning'], delay=0, wall_seconds=60)

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
        for count in (17, 24, 32, 33, 63, 64, 65, 66, 67):
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
                # Changed recorded dependencies are provenance, not a semantic waiver.
                capture.verify(args.output)
            else:
                with self.assertRaisesRegex(ValueError, 'prior collector message scope'):
                    capture.verify(args.output)

    def test_sixty_eight_rejected_before_capture_or_transport(self):
        args = self.options(68)
        transport = Transport()
        with self.assertRaisesRegex(ValueError, 'excessive requested'):
            capture.capture(args, transport=transport, sleep=lambda _: None)
        self.assertFalse(args.output.exists())
        self.assertEqual(transport.calls, [])

    def test_sixty_eight_resealed_selection_rejected_by_replay(self):
        args, _, _ = self.collect(64)
        path = args.output / (capture.PREFIX + 'requested.json')
        config = json.loads(path.read_text())
        config['keys'] = keys(68)
        path.write_bytes(capture.evidence.encoded(config))
        self.rebind(args.output, lambda value: value.update(keys=keys(68)))
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

    def test_paired_schema_and_well_formed_producer_provenance_required(self):
        for mode in ('paired', 'malformed-producer', 'unknown-schema'):
            with self.subTest(mode=mode):
                args, _, _ = self.collect(24, mode)
                if mode == 'malformed-producer':
                    self.rebind(args.output, lambda value: value.update(generator_sha256='not-a-sha256'))
                    with self.assertRaisesRegex(ValueError, 'producer provenance'):
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

    def test_changed_downloader_and_generator_replay_preserves_observation(self):
        args, _, _ = self.collect(24, 'historical')
        def provenance(value):
            value['generator_sha256'] = '1' * 64
            value['dependency_sha256']['tools/download_wiktionaries.py'] = '2' * 64
        self.rebind(args.output, provenance)
        before = {p.name: p.read_bytes() for p in args.output.iterdir()}
        result = capture.verify(args.output)
        self.assertEqual({p.name: p.read_bytes() for p in args.output.iterdir()}, before)
        for kind in capture.KINDS:
            original = json.loads(before[kind + '.manifest.json'])
            self.assertEqual(result[kind], original)
            self.assertEqual(result[kind]['generator_sha256'], '1' * 64)
            self.assertEqual(result[kind]['started_utc'], original['started_utc'])
            self.assertEqual(result[kind]['retrieved_utc'], original['retrieved_utc'])
            self.assertIs(builder.auxiliary_capture_helper(kind, args.output / (kind + '.tsv')), capture)
            self.assertEqual(capture.validate_snapshot(args.output / (kind + '.tsv'), WIKI, DATE), original)

    def test_ordinary_preferred_pair_accepts_replay_but_requires_warning(self):
        args, _, _ = self.collect(24, 'language-messages-loop-v1')
        def historical(value):
            value['generator_sha256'] = '1' * 64
            value['dependency_sha256']['tools/download_wiktionaries.py'] = '2' * 64
        self.rebind(args.output, historical)
        selected = builder.discover_auxiliary_generation(
            self.base, args.output.name, capture.KINDS, WIKI, DATE)
        self.assertEqual(selected, {kind: args.output / (kind + '.tsv') for kind in capture.KINDS})
        # Even a recognized historical scope cannot enter the preferred loop
        # generation without an actually observed parser warning.
        original_required = capture.REQUIRED_MESSAGE_KEYS
        previous = self.base / 'old'
        previous.mkdir()
        options = self.options(24)
        options.output = previous / 'language-messages-loop-v1'
        options.messages = keys(24)
        try:
            capture.REQUIRED_MESSAGE_KEYS = frozenset()
            capture.capture(options, transport=Transport(), sleep=lambda _: None)
        finally:
            capture.REQUIRED_MESSAGE_KEYS = original_required
        self.rebind(options.output, lambda v: v.update(generator_sha256=capture.PRE_LOOP_WARNING_GENERATOR_SHA256))
        capture.verify(options.output)
        with self.assertRaisesRegex(ValueError, 'loop-warning key'):
            builder.discover_auxiliary_generation(previous, options.output.name, capture.KINDS, WIKI, DATE)

    def test_malformed_provenance_roles_and_hashes_rejected(self):
        mutations = (
            lambda v: v.update(generator_sha256=None),
            lambda v: v.update(generator_sha256='A' * 64),
            lambda v: v.update(dependency_sha256=[]),
            lambda v: v['dependency_sha256'].pop('tools/download_wiktionaries.py'),
            lambda v: v['dependency_sha256'].update({'unexpected.py': '0' * 64}),
            lambda v: v['dependency_sha256'].update({'tools/download_wiktionaries.py': 'short'}),
        )
        for number, mutate in enumerate(mutations):
            with self.subTest(number=number):
                args, _, _ = self.collect(24, 'bad-provenance-' + str(number))
                self.rebind(args.output, mutate)
                with self.assertRaisesRegex(ValueError, 'producer provenance'):
                    capture.verify(args.output)

    def test_changed_provenance_does_not_hide_raw_receipt_or_query_tamper(self):
        for mode in ('raw', 'receipt', 'query', 'resealed-raw'):
            with self.subTest(mode=mode):
                args, _, result = self.collect(24, 'tamper-' + mode)
                batch = result['interface-messages']['requests'][1]
                receipt_path = args.output / batch['accepted_receipt']
                receipt = json.loads(receipt_path.read_text())
                if mode in ('raw', 'resealed-raw'):
                    response_path = args.output / receipt['response']
                    response = json.loads(response_path.read_text())
                    response['query']['allmessages'][0]['content'] = 'changed observation'
                    response_path.write_bytes(capture.evidence.encoded(response))
                    if mode == 'resealed-raw':
                        raw = response_path.read_bytes()
                        receipt.update(response_bytes=len(raw), response_sha256=capture.evidence.digest(raw))
                        receipt_path.write_bytes(capture.evidence.encoded(receipt))
                elif mode == 'receipt':
                    receipt['accepted'] = False
                    receipt_path.write_bytes(capture.evidence.encoded(receipt))
                else:
                    request_path = args.output / batch['request']
                    request = json.loads(request_path.read_text())
                    request['query']['amprop'] = 'parsed'
                    request_path.write_bytes(capture.evidence.encoded(request))
                def provenance(value):
                    value['generator_sha256'] = '1' * 64
                    value['dependency_sha256']['tools/download_wiktionaries.py'] = '2' * 64
                self.rebind(args.output, provenance)
                with self.assertRaisesRegex(ValueError, 'Raw API response|accepted API receipt|API semantics|Rendered TSV'):
                    capture.verify(args.output)

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

    def test_required_loop_warning_localized_capture_and_exact_replay(self):
        args = self.options(66, 'required-warning', ['bn', 'fr'])
        args.messages = keys(66)  # Caller omission must still capture the native requirement.
        transport = Transport()
        result = capture.capture(args, transport=transport, sleep=lambda _: None)
        self.assertEqual(len(result['interface-messages']['keys']), 67)
        self.assertIn('parser-template-loop-warning', result['interface-messages']['keys'])
        self.assertEqual(len(transport.calls), 7)
        text = (args.output / 'interface-messages.tsv').read_text()
        for language in ('bn', 'fr'):
            self.assertIn(language + '\tparser-template-loop-warning\tV\t' +
                          capture.escaped('বাংলা parser-template-loop-warning\n\t\\ $1') + '\n', text)
        self.assertEqual(capture.verify(args.output), result)
        # Rehashing the paired manifests cannot launder a localized payload change.
        path = args.output / 'interface-messages.tsv'
        path.write_text(text.replace('বাংলা parser-template-loop-warning', 'changed warning', 1))
        self.rebind(args.output)
        with self.assertRaisesRegex(ValueError, 'Rendered TSV'):
            capture.verify(args.output)

    def test_prior_sixty_six_without_warning_and_new_required_selection(self):
        # Genuine synthetic previous-producer evidence can omit the new key.
        args = self.options(66, 'prior-sixty-six')
        args.messages = keys(66)
        original_required = capture.REQUIRED_MESSAGE_KEYS
        try:
            capture.REQUIRED_MESSAGE_KEYS = frozenset()
            capture.capture(args, transport=Transport(), sleep=lambda _: None)
        finally:
            capture.REQUIRED_MESSAGE_KEYS = original_required
        self.rebind(args.output, lambda value: value.update(
            generator_sha256=capture.PRE_LOOP_WARNING_GENERATOR_SHA256))
        self.assertEqual(len(capture.verify(args.output)['interface-messages']['keys']), 66)
        # The exact same evidence under the NEW producer must require the key.
        self.rebind(args.output, lambda value: value.update(
            generator_sha256=capture.producer()['generator_sha256']))
        with self.assertRaisesRegex(ValueError, 'Required parser message'):
            capture.verify(args.output)
        args = self.options(67, 'prior-over-limit')
        capture.capture(args, transport=Transport(), sleep=lambda _: None)
        self.rebind(args.output, lambda value: value.update(
            generator_sha256=capture.PRE_LOOP_WARNING_GENERATOR_SHA256))
        with self.assertRaisesRegex(ValueError, 'prior collector message scope'):
            capture.verify(args.output)

    def test_retry_evidence_is_preserved_across_chunks(self):
        args, transport, _ = self.collect(24, retry=True)
        self.assertEqual(len(transport.calls), 3)
        receipts = [json.loads(p.read_text()) for p in args.output.glob('*.receipt.json')]
        self.assertEqual(sum(not row['accepted'] for row in receipts), 1)
        self.assertTrue(capture.verify(args.output)['interface-messages']['candidate_queries_complete'])


if __name__ == '__main__':
    unittest.main()
