"""Strict bounded v2 message capture, paired profiles and exact chunk replay."""
import copy
import contextlib
import io
import hashlib
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
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
        self.assertEqual(capture.producer()['dependency_sha256']['tools/prepare_language_messages.py'],
                         hashlib.sha256(Path(legacy.__file__).read_bytes()).hexdigest())
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


    def test_normal_cli_plans_native_phonos_keys_without_changing_historical_scope(self):
        baseline, _, prior = self.collect(17, 'prior-explicit')
        before = {p.name: p.read_bytes() for p in baseline.output.iterdir()}
        output = self.base / 'normal-cli'
        transport = Transport()
        original = capture.capture
        def offline(args):
            return original(args, transport=transport, sleep=lambda _: None)
        argv = ['prepare_language_messages_v2.py', 'capture', '--wiki', WIKI,
                '--date', DATE, '--namespace-registry', str(self.namespace),
                '--output', str(output), '--languages', 'bn', 'en',
                '--messages', 'Phonos-aria-error', 'Key-003', '--delay', '1']
        with mock.patch.object(capture.sys, 'argv', argv), mock.patch.object(capture, 'capture', side_effect=offline), contextlib.redirect_stdout(io.StringIO()):
            capture.main()
        records = capture.verify(output)
        wanted = {'Phonos-aria-error', 'phonos-player-aria-description', 'Key-003', 'parser-template-loop-warning'}
        self.assertEqual(set(records['interface-messages']['keys']), wanted)
        self.assertEqual(records['interface-messages']['rows'], 8)
        rows = (output / 'interface-messages.tsv').read_text()
        for language in ('bn', 'en'):
            self.assertIn(language + '\tphonos-aria-error\tV\tবাংলা Phonos-aria-error', rows)
            self.assertIn(language + '\tphonos-player-aria-description\tV\tবাংলা phonos-player-aria-description', rows)
            self.assertIn(language + '\tkey-003\tM\n', rows)
        for kind in capture.KINDS:
            self.assertEqual(builder.validated_auxiliary_capture(kind, output / (kind + '.tsv'), WIKI, DATE)[0], records[kind])
        self.assertEqual(capture.verify(baseline.output), prior)
        self.assertEqual(before, {p.name: p.read_bytes() for p in baseline.output.iterdir()})
        self.assertNotIn('phonos-aria-error', prior['interface-messages']['keys'])

    def test_normal_cli_native_plan_preserves_bound_and_fails_before_transport(self):
        output = self.base / 'too-many-planned'
        transport = Transport()
        original = capture.capture
        def offline(args):
            return original(args, transport=transport, sleep=lambda _: None)
        argv = ['prepare_language_messages_v2.py', 'capture', '--wiki', WIKI,
                '--date', DATE, '--namespace-registry', str(self.namespace),
                '--output', str(output), '--messages', *keys(66)]
        with mock.patch.object(capture.sys, 'argv', argv), mock.patch.object(capture, 'capture', side_effect=offline):
            with self.assertRaisesRegex(ValueError, 'excessive requested'):
                capture.main()
        self.assertFalse(output.exists())
        self.assertEqual(transport.calls, [])


class CompleteTransport:
    core = '115ff4de72eec9482447f6ad2a93444f3f78fddd'

    def __init__(self, mutate=None):
        self.calls = []
        self.mutate = mutate

    def __call__(self, url, timeout):
        self.calls.append(url)
        q = {key: value[0] for key, value in parse_qs(urlsplit(url).query).items()}
        general = dict(wikiid=WIKI, lang='bn', **{'git-hash': self.core})
        value = {'query': {'general': general}, 'batchcomplete': True}
        if q['meta'] == 'siteinfo|languageinfo':
            codes = {'bn': []} if 'licontinue' not in q else {'en': [], 'fr': ['en']}
            value['query']['languageinfo'] = {k: dict(code=k, fallbacks=v) for k, v in codes.items()}
            if 'licontinue' not in q:
                value.pop('batchcomplete')
                value['continue'] = {'continue': '-||', 'licontinue': 'en'}
        elif q['ammessages'] == '*':
            assert q['amincludelocal'] == '1' and q['amcustomised'] == 'all'
            assert not set(q) & {'amenableparser', 'amargs', 'amfilter', 'amprefix', 'amto', 'amnocontent'}
            if 'amfrom' not in q:
                rows = [dict(name='Empty', normalizedname='empty', content=''),
                        dict(name='Gone', normalizedname='gone', missing=True)]
                value.pop('batchcomplete')
                value['continue'] = {'continue': '-||', 'amfrom': 'Show'}
            else:
                rows = [dict(name='Show', normalizedname='show', content='local ' + q['amlang'], default='default'),
                        dict(name='empty', normalizedname='empty', content=''),
                        dict(name='étiquette', normalizedname='étiquette', content='raw Unicode key')]
            value['query']['allmessages'] = rows
        else:
            value['query']['allmessages'] = [dict(name=k, normalizedname=capture.normalize_key(k), content='exact ' + k)
                                             for k in q['ammessages'].split('|')]
        if self.mutate: self.mutate(q, value)
        return 200, {'Content-Type': 'application/json'}, json.dumps(value, ensure_ascii=False).encode()


class CompleteMessageTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.namespace = self.base / 'namespace.tsv'
        self.namespace.write_text(NAMESPACE)
        self.sources = self.base / 'sources'; self.sources.mkdir()
        pins, records = {}, []
        # Synthetic source identities exercise the binding contract; production
        # pins remain the separately reviewed immutable MediaWiki source bytes.
        for name, (path, _) in capture.COMPLETE_SOURCE_PINS.items():
            raw = ('<?php /* synthetic ' + name + ' */').encode()
            (self.sources / name).write_bytes(raw)
            digest = capture.evidence.digest(raw); pins[name] = (path, digest)
            records.append(dict(file=name, source_path=path, status=200, bytes=len(raw), sha256=digest,
                retrieved_utc='2026-11-05T00:00:00+00:00',
                url=f'https://raw.githubusercontent.com/wikimedia/mediawiki/{CompleteTransport.core}/{path}'))
        (self.sources / 'source-receipts01.json').write_bytes(capture.evidence.encoded(dict(core=CompleteTransport.core, sources=records)))
        self.pins = mock.patch.dict(capture.COMPLETE_SOURCE_PINS, pins, clear=True)
        self.pins.start(); self.addCleanup(self.pins.stop)

    def collect(self, name='language-messages-loop-v1', mutate=None, **changes):
        args = SimpleNamespace(wiki=WIKI, date=DATE, namespace_registry=self.namespace,
            output=self.base / name, languages=['bn', 'en'], messages=[],
            delay=0, wall_seconds=60, complete_messages=True, api_sources=self.sources)
        for key, value in changes.items(): setattr(args, key, value)
        transport = CompleteTransport(mutate)
        result = capture.capture(args, transport=transport, sleep=lambda _: None)
        return args, transport, result

    def rebind(self, root, change=None):
        hashes = {}
        inventory = capture.owned_payload(root)
        for kind in capture.KINDS:
            path = root / (kind + '.manifest.json')
            value = json.loads(path.read_bytes()); value['artifacts'] = inventory
            raw = (root / (kind + '.tsv')).read_bytes()
            value.update(output_bytes=len(raw), output_sha256=capture.evidence.digest(raw))
            if change: change(value)
            path.write_bytes(capture.evidence.encoded(value)); hashes[path.name] = capture.evidence.digest(path.read_bytes())
        (root / capture.COMPLETE).write_bytes(capture.evidence.encoded(dict(schema=capture.COMPLETE_SCHEMA, manifests=hashes)))

    def test_complete_pagination_raw_unicode_empty_missing_and_normal_pair(self):
        args, transport, records = self.collect()
        self.assertEqual(len(transport.calls), 8)  # two fallback + two pages and one explicit supplement per language
        self.assertEqual(capture.verify(args.output), records)
        coverage = json.loads((args.output / (capture.PREFIX + 'coverage.json')).read_bytes())
        raw = (args.output / 'interface-messages.tsv').read_bytes()
        for lang in ('bn', 'en'):
            row = coverage[lang]
            self.assertEqual((row['api_rows'], row['explicit_missing'], row['empty_values'], row['normalization_alias_rows']), (5, 1, 2, 1))
            self.assertFalse(row['projection_complete_for_api_inventory'])
            self.assertEqual(row['unsupported_rows'][0]['name'], 'étiquette')
            self.assertIn(f'{lang}\tempty\tV\t\n'.encode(), raw)
            self.assertIn(f'{lang}\tgone\tM\n'.encode(), raw)
            self.assertNotIn(f'{lang}\tunobserved\tM'.encode(), raw)
        self.assertTrue(any('étiquette'.encode() in p.read_bytes() for p in args.output.glob('*.raw.json')))
        found = builder.discover_auxiliary_generation(self.base, args.output.name, capture.KINDS, WIKI, DATE)
        for kind in capture.KINDS:
            self.assertIs(builder.auxiliary_capture_helper(kind, found[kind]), capture)
            self.assertEqual(builder.validated_auxiliary_capture(kind, found[kind], WIKI, DATE)[0], records[kind])
        self.assertIsNone(records['interface-messages']['dump_date'])
        self.assertFalse(records['interface-messages']['corpus_query_closure_proven'])

    def test_only_missing_explicit_keys_supplement_enumeration(self):
        args, transport, _ = self.collect(messages=['show', 'hide'])
        explicit = [parse_qs(urlsplit(u).query)['ammessages'][0] for u in transport.calls if 'ammessages=' in u and 'ammessages=%2A' not in u]
        self.assertEqual(explicit, ['hide|parser-template-loop-warning'] * 2)
        self.assertIn(b'bn\thide\tV\texact hide\n', (args.output / 'interface-messages.tsv').read_bytes())

    def test_normal_pair_staging_preserves_evidence_and_rejects_crossed_generations(self):
        args, _, records = self.collect()
        snapshots = {kind: args.output / (kind + '.tsv') for kind in capture.KINDS}
        hashes = {name: capture.evidence.digest(path.read_bytes()) for name, path in snapshots.items()}
        destination = self.base / 'staged'
        pinned = builder.pinned_auxiliary_snapshots(snapshots, hashes, destination)
        self.assertEqual(capture.verify(destination), records)
        self.assertEqual(set(pinned), set(capture.KINDS))
        for name, metadata in records['interface-messages']['artifacts'].items():
            self.assertEqual(capture.evidence.digest((destination / name).read_bytes()), metadata['sha256'])
        other, _, _ = self.collect('other-generation', messages=['observed-extra'])
        snapshots['language-fallbacks'] = other.output / 'language-fallbacks.tsv'
        hashes['language-fallbacks'] = capture.evidence.digest(snapshots['language-fallbacks'].read_bytes())
        crossed = self.base / 'crossed'
        with self.assertRaisesRegex(ValueError, 'Conflicting auxiliary capture artifact'):
            builder.pinned_auxiliary_snapshots(snapshots, hashes, crossed)
        self.assertFalse(crossed.exists())

    def test_continuation_missing_terminal_core_normalization_and_duplicate_refusals(self):
        def mutation(mode):
            def mutate(q, value):
                if q.get('ammessages') != '*': return
                if mode == 'core': value['query']['general']['git-hash'] = 'b' * 40
                elif mode == 'no-terminal' and 'amfrom' in q: value.pop('batchcomplete')
                elif mode == 'skip-first' and 'amfrom' in q: value['query']['allmessages'].pop(0)
                elif mode == 'repeat' and 'amfrom' in q: value['query']['allmessages'].append(dict(name='Gone', normalizedname='gone', missing=True))
                elif mode == 'normalization': value['query']['allmessages'][0]['normalizedname'] = 'wrong'
                elif mode == 'conflict' and 'amfrom' in q: value['query']['allmessages'][1]['content'] = 'different'
                elif mode == 'bad-token': value['continue'] = {'continue': '-||', 'other': 'x'}
                elif mode == 'backward-token' and 'amfrom' not in q: value['continue']['amfrom'] = 'AA'
                elif mode == 'order' and 'amfrom' not in q: value['query']['allmessages'].reverse()
            return mutate
        for mode in ('core', 'no-terminal', 'skip-first', 'repeat', 'normalization', 'conflict', 'bad-token', 'backward-token', 'order'):
            with self.subTest(mode=mode), self.assertRaises(ValueError): self.collect(mode, mutation(mode))
            self.assertFalse((self.base / mode / capture.COMPLETE).exists())
            self.assertTrue((self.base / mode / (capture.PREFIX + 'failure.json')).is_file())

    def test_numeric_sort_domain_fails_with_raw_evidence_and_no_completion(self):
        for index, key in enumerate(('2', '-4', '+.5', '.1e99999', ' \t1.5 ', '0E0')):
            def mutate(q, value):
                if q.get('ammessages') == '*':
                    value['query']['allmessages'][0]['name'] = key
            name = 'numeric-' + str(index)
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'numeric-string'):
                self.collect(name, mutate)
            root = self.base / name
            self.assertTrue((root / 'language-messages.0003-01.raw.json').exists())
            self.assertFalse((root / capture.COMPLETE).exists())

    def test_leading_numeric_nonnumeric_names_have_normal_bytewise_projection(self):
        names = ['+local', '-local', '.local', '1e', '1movedto2', '2movedto1']
        for name in names: self.assertEqual(capture.complete_order_key(name), name.encode())
        def mutate(q, value):
            if q.get('ammessages') == '*' and 'amfrom' not in q:
                value['query']['allmessages'][:0] = [dict(name=name, normalizedname=name, content='synthetic '+name) for name in names]
        args, _, _ = self.collect('nonnumeric-prefixes', mutate)
        raw = (args.output / 'interface-messages.tsv').read_bytes()
        for name in names: self.assertIn(('bn\t'+name+'\tV\tsynthetic '+name+'\n').encode(), raw)
        capture.verify(args.output)

    def test_identical_source_bytes_at_another_core_preserve_both_epochs(self):
        path = self.sources / 'source-receipts01.json'; value = json.loads(path.read_bytes())
        old = value['core']; value['core'] = '0470f6c99a6456a366635bf25a517a1f951de6f5'
        previous, _, _ = self.collect('previous-core')
        previous_bytes = {p.name: p.read_bytes() for p in previous.output.iterdir()}
        for source in value['sources']: source['url'] = source['url'].replace(old, value['core'])
        path.write_bytes(capture.evidence.encoded(value))
        self.assertEqual(capture.complete_source_contract(self.sources), value['core'])
        with mock.patch.object(CompleteTransport, 'core', value['core']):
            current, _, records = self.collect('current-core')
        self.assertEqual(records['interface-messages']['api_core'], value['core'])
        self.assertEqual(capture.verify(current.output), records)
        self.assertEqual(capture.verify(previous.output)['interface-messages']['api_core'], old)
        self.assertEqual(previous_bytes, {p.name: p.read_bytes() for p in previous.output.iterdir()})

    def test_revision_shape_url_join_and_resealed_changed_source_are_rejected(self):
        path = self.sources / 'source-receipts01.json'; original = json.loads(path.read_bytes())
        for core in (None, 1, 'A' * 40, 'a' * 39, 'a' * 41, '../source'):
            value = copy.deepcopy(original); value['core'] = core
            path.write_bytes(capture.evidence.encoded(value))
            with self.subTest(core=core), self.assertRaisesRegex(ValueError, 'source revision'):
                capture.complete_source_contract(self.sources)
        value = copy.deepcopy(original); value['core'] = 'b' * 40
        path.write_bytes(capture.evidence.encoded(value))
        with self.assertRaisesRegex(ValueError, 'source identity'):
            capture.complete_source_contract(self.sources)
        for source in value['sources']:
            source['url'] = source['url'].replace(original['core'], value['core'])
        source = value['sources'][0]; changed = b'<?php /* changed semantics */'
        (self.sources / source['file']).write_bytes(changed)
        source.update(bytes=len(changed), sha256=capture.evidence.digest(changed))
        path.write_bytes(capture.evidence.encoded(value))
        with self.assertRaisesRegex(ValueError, 'source identity'):
            capture.complete_source_contract(self.sources)

    def test_same_source_new_revision_requires_matching_api_responses(self):
        path = self.sources / 'source-receipts01.json'; value = json.loads(path.read_bytes())
        old = value['core']; value['core'] = 'b' * 40
        for source in value['sources']: source['url'] = source['url'].replace(old, value['core'])
        path.write_bytes(capture.evidence.encoded(value))
        with self.assertRaisesRegex(ValueError, 'API source revision changed'):
            self.collect('response-core-mismatch')
        self.assertFalse((self.base / 'response-core-mismatch' / capture.COMPLETE).exists())
        self.assertTrue((self.base / 'response-core-mismatch' / (capture.PREFIX + 'failure.json')).exists())

    def test_resealed_query_receipt_raw_coverage_tsv_and_provenance_refused(self):
        for mode in ('query', 'receipt', 'raw', 'coverage', 'tsv', 'producer', 'source', 'requests'):
            with self.subTest(mode=mode):
                args, _, records = self.collect(mode)
                root = args.output; record = records['interface-messages']; batch = record['requests'][2]
                if mode == 'query':
                    path = root / batch['request']; value = json.loads(path.read_bytes()); value['query']['amincludelocal'] = '0'
                elif mode == 'receipt':
                    path = root / batch['accepted_receipt']; value = json.loads(path.read_bytes()); value['accepted'] = False
                elif mode == 'raw':
                    receiptpath = root / batch['accepted_receipt']; receipt = json.loads(receiptpath.read_bytes())
                    path = root / receipt['response']; value = json.loads(path.read_bytes()); value['query']['allmessages'][0]['content'] = 'resealed change'
                    changed = capture.evidence.encoded(value); receipt.update(response_bytes=len(changed), response_sha256=capture.evidence.digest(changed))
                    receiptpath.write_bytes(capture.evidence.encoded(receipt))
                elif mode == 'coverage':
                    path = root / (capture.PREFIX + 'coverage.json'); value = json.loads(path.read_bytes()); value['bn']['unsupported_rows'] = []
                elif mode == 'tsv':
                    path = root / 'interface-messages.tsv'; path.write_bytes(path.read_bytes().replace(b'local bn', b'changed'))
                elif mode == 'source':
                    path = root / (capture.PREFIX + 'source-ApiQueryAllMessages.php'); path.write_bytes(b'changed')
                if mode in ('query', 'receipt', 'raw', 'coverage'): path.write_bytes(capture.evidence.encoded(value))
                def change(value):
                    if mode == 'producer': value['dependency_sha256']['extra'] = '1' * 64
                    if mode == 'requests': value['requests'].append(copy.deepcopy(value['requests'][-1]))
                    if mode == 'coverage': value['coverage_sha256'] = capture.evidence.digest(path.read_bytes())
                self.rebind(root, change)
                with self.assertRaises(ValueError): capture.verify(root)

    def test_historical_provenance_preserved_without_changing_source_epoch(self):
        args, _, _ = self.collect()
        self.rebind(args.output, lambda value: value.update(generator_sha256='c' * 64,
            dependency_sha256={key: 'd' * 64 for key in value['dependency_sha256']}))
        before = {p.name: p.read_bytes() for p in args.output.iterdir()}
        result = capture.verify(args.output)['interface-messages']
        self.assertEqual(result['api_core'], CompleteTransport.core)
        self.assertEqual(result['generator_sha256'], 'c' * 64)
        self.assertEqual(before, {p.name: p.read_bytes() for p in args.output.iterdir()})

    def test_bounds_fail_closed_with_retained_response(self):
        for mode, setting in [('rows', {'COMPLETE_MAX_ROWS': 3}), ('response', {'COMPLETE_RESPONSE_BYTES': 64}),
                              ('total', {'COMPLETE_TOTAL_BYTES': 64}), ('requests', {'MAX_REQUESTS': 2})]:
            with self.subTest(mode=mode), mock.patch.multiple(capture, **setting), self.assertRaises(ValueError): self.collect(mode)
            self.assertFalse((self.base / mode / capture.COMPLETE).exists())
            self.assertTrue((self.base / mode / (capture.PREFIX + 'failure.json')).exists())


    def test_transport_response_limit_is_explicit_bounded_and_redirect_guard_unchanged(self):
        url = 'https://bn.wiktionary.org/w/api.php?action=query'
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.url, response.status, response.headers = url, 200, {}
        response.read.return_value = b'{}'
        with mock.patch.object(capture.evidence.urllib.request, 'urlopen', return_value=response) as opened:
            capture.evidence.get_response(url, 5)
            response.read.assert_called_with(capture.evidence.MAX_RESPONSE + 1)
            capture.complete_response(url, 5)
            response.read.assert_called_with(capture.COMPLETE_RESPONSE_BYTES + 1)
            self.assertEqual(capture.COMPLETE_RESPONSE_BYTES, 16 * 1024 * 1024)
            response.url = 'https://other.example/w/api.php'
            with self.assertRaisesRegex(ValueError, 'redirect endpoint'): capture.complete_response(url, 5)


    def test_normal_complete_cli_supplements_both_native_phonos_dependencies(self):
        output = self.base / 'normal-complete-cli'
        transport = CompleteTransport()
        original = capture.capture
        def offline(args):
            return original(args, transport=transport, sleep=lambda _: None)
        argv = ['prepare_language_messages_v2.py', 'capture', '--wiki', WIKI,
                '--date', DATE, '--namespace-registry', str(self.namespace),
                '--output', str(output), '--languages', 'bn', 'en',
                '--complete-messages', '--api-sources', str(self.sources)]
        with mock.patch.object(capture.sys, 'argv', argv), mock.patch.object(capture, 'capture', side_effect=offline), contextlib.redirect_stdout(io.StringIO()):
            capture.main()
        records = capture.verify(output)
        self.assertEqual(set(records['interface-messages']['extra_keys']),
                         {'parser-template-loop-warning', 'phonos-aria-error', 'phonos-player-aria-description'})
        rows = (output / 'interface-messages.tsv').read_text()
        for language in ('bn', 'en'):
            for key in ('phonos-aria-error', 'phonos-player-aria-description'):
                self.assertIn(language + '\t' + key + '\t', rows)
        for kind in capture.KINDS:
            self.assertEqual(builder.validated_auxiliary_capture(kind, output / (kind + '.tsv'), WIKI, DATE)[0], records[kind])


if __name__ == '__main__':
    unittest.main()
