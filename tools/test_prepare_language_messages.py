import copy
import json
from pathlib import Path
import shutil
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
from urllib.parse import parse_qs, urlsplit

import prepare_language_messages as capture


WIKI = 'arwiktionary'
DATE = '20261001'
KEYS = ['And', 'Word-separator', 'Bridge', 'Missing']
NAMESPACE = (
    '# wikidict-namespace-registry-v1\n# wiki\tarwiktionary\n'
    '# dump-date\t20261001\n# content-language\tar\n'
)
SOURCES = {'And': 'و', 'Word-separator': ' ', 'Bridge': '{{WBREPONAME}} $1\n\t\\', 'Missing': None}


def fallback_response(rows=None, continuation=None):
    data = {'query': {'general': {'wikiid': WIKI, 'lang': 'ar'}, 'languageinfo': {
        code: {'code': code, 'fallbacks': chain}
        for code, chain in (rows if rows is not None else {'ar': [], 'en': [], 'fr': ['de', 'it']}).items()
    }}}
    if continuation is not None:
        data['continue'] = continuation
    return data


def message_response(keys=KEYS):
    return {'query': {'general': {'wikiid': WIKI, 'lang': 'ar'}, 'allmessages': [
        {'name': key, 'normalizedname': capture.normalize_key(key),
         **({'missing': True} if SOURCES.get(key) is None else {'content': SOURCES[key]})}
        for key in keys
    ]}}


class Transport:
    def __init__(self, pages=None, first_error=None):
        self.calls = []
        self.pages = copy.deepcopy(pages or [fallback_response()])
        self.first_error = first_error

    def __call__(self, url, timeout):
        self.calls.append(url)
        query = parse_qs(urlsplit(url).query)
        if self.first_error is not None:
            value, self.first_error = self.first_error, None
            if isinstance(value, Exception):
                raise value
            return value
        if query['meta'] == ['siteinfo|languageinfo']:
            assert query['licode'] == ['*']
            value = self.pages.pop(0)
        else:
            assert query['meta'] == ['siteinfo|allmessages']
            assert 'amenableparser' not in query and 'amargs' not in query
            value = message_response(query['ammessages'][0].split('|'))
        return 200, {'Date': 'Mon, 05 Oct 2026 00:00:00 GMT', 'Content-Type': 'application/json'}, json.dumps(value).encode()


class ParseTest(unittest.TestCase):
    def test_normalization_matches_ascii_first_letter_only(self):
        self.assertEqual(capture.normalize_key('Comma-separator'), 'comma-separator')
        self.assertEqual(capture.normalize_key('Foo BAR'), 'foo_BAR')
        for value in ('', 'éxample', 'A|B', 'bad\nkey'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                capture.normalize_key(value)

    def test_plain_messages_preserve_whitespace_placeholders_and_missing(self):
        value = capture.parse_messages(message_response(), 'ar', KEYS, WIKI, 'ar')
        self.assertEqual(value['word-separator'], ' ')
        self.assertEqual(value['bridge'], '{{WBREPONAME}} $1\n\t\\')
        self.assertIsNone(value['missing'])
        text = capture.render_messages({('ar', k): v for k, v in value.items()}, WIKI, DATE, 'ar').decode()
        self.assertIn('ar\tword-separator\tV\t \n', text)
        self.assertIn('ar\tmissing\tM\n', text)
        self.assertIn('{{WBREPONAME}} $1\\n\\t\\\\', text)

    def test_strict_chain_preserves_order_and_explicit_empty(self):
        rows, continuation = capture.parse_fallbacks(fallback_response({'ar': [], 'fr': ['en', 'de', 'de']}), WIKI, 'ar')
        self.assertEqual(rows, {'ar': [], 'fr': ['en', 'de', 'de']})
        self.assertEqual(continuation, {})
        self.assertIn(b'ar\t\n', capture.render_fallbacks(rows, WIKI, DATE, 'ar'))
        self.assertIn(b'fr\ten\tde\tde\n', capture.render_fallbacks(rows, WIKI, DATE, 'ar'))

    def test_incomplete_or_ambiguous_messages_fail(self):
        cases = []
        data = message_response(); data['query']['allmessages'].pop(); cases.append(data)
        data = message_response(); data['query']['allmessages'][0]['normalizedname'] = 'And'; cases.append(data)
        data = message_response(); data['query']['allmessages'][0]['missing'] = True; cases.append(data)
        data = message_response(); data['query']['allmessages'][3]['missing'] = False; cases.append(data)
        data = message_response(); data['query']['allmessages'][0].pop('content'); cases.append(data)
        data = message_response(); data['continue'] = {'amfrom': 'And'}; cases.append(data)
        for data in cases:
            with self.subTest(data=data), self.assertRaises(ValueError):
                capture.parse_messages(data, 'ar', KEYS, WIKI, 'ar')

    def test_wrong_wiki_language_errors_and_warnings_fail(self):
        for field, value in (('wikiid', 'enwiktionary'), ('lang', 'en')):
            data = fallback_response(); data['query']['general'][field] = value
            with self.assertRaises(ValueError):
                capture.parse_fallbacks(data, WIKI, 'ar')
        for field in ('error', 'errors', 'warnings'):
            data = fallback_response(); data[field] = {}
            with self.assertRaises(ValueError):
                capture.parse_fallbacks(data, WIKI, 'ar')

    def test_missing_fallback_list_and_invalid_continuation_fail(self):
        cases = []
        data = fallback_response(); data['query']['languageinfo']['ar'].pop('fallbacks'); cases.append(data)
        cases.append(fallback_response({'en': ['fr']}))
        cases.append(fallback_response({'ar': ['invalid!']}))
        cases.append(fallback_response(continuation={'licontinue': 'fr'}))
        cases.append(fallback_response(continuation={'continue': '-||', 'licontinue': 3}))
        for data in cases:
            with self.subTest(data=data), self.assertRaises(ValueError):
                capture.parse_fallbacks(data, WIKI, 'ar')


class CaptureTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        namespace = self.base / 'namespace.tsv'
        namespace.write_text(NAMESPACE)
        self.args = SimpleNamespace(wiki=WIKI, date=DATE, namespace_registry=namespace,
            output=self.base / 'generation', languages=['ar', 'en'], messages=KEYS, delay=0, wall_seconds=60)

    def collect(self, transport=None):
        return capture.capture(self.args, transport or Transport(), sleep=lambda _: None)

    def rebind(self):
        # Rebind integrity hashes to test semantic replay independently of hash checks.
        inventory = capture.owned_payload(self.args.output)
        hashes = {}
        for kind in capture.KINDS:
            path = self.args.output / (kind + '.manifest.json')
            manifest = json.loads(path.read_text())
            manifest['artifacts'] = inventory
            path.write_bytes(capture.evidence.encoded(manifest))
            hashes[path.name] = capture.evidence.digest(path.read_bytes())
        (self.args.output / capture.COMPLETE).write_bytes(capture.evidence.encoded({
            'schema': capture.SCHEMA, 'manifests': hashes}))

    def test_roundtrip_all_fallbacks_small_message_selection_and_pin_copy(self):
        records = self.collect()
        self.assertEqual(records['language-fallbacks']['rows'], 3)
        self.assertEqual(records['interface-messages']['rows'], 8)
        self.assertEqual(records['language-fallbacks']['fallback_languages'], ['ar', 'en', 'fr'])
        self.assertEqual(records['language-fallbacks']['fallback_scope'], 'all-supported-api-languages')
        self.assertIsNone(records['language-fallbacks']['dump_date'])
        self.assertFalse(records['language-fallbacks']['corpus_query_closure_proven'])
        snapshot = self.args.output / 'interface-messages.tsv'
        inventory = capture.capture_artifacts(snapshot, records['interface-messages'])
        pinned = self.base / 'pinned'; pinned.mkdir()
        for name in inventory:
            shutil.copyfile(self.args.output / name, pinned / name)
        self.assertEqual(capture.validate_snapshot(pinned / snapshot.name, WIKI, DATE), records['interface-messages'])
        self.assertIn(capture.COMPLETE, inventory)
        with self.assertRaises(ValueError):
            capture.validate_snapshot(snapshot, 'enwiktionary', DATE)

    def test_complete_continuation_stream_keeps_all_raw_responses(self):
        token = {'continue': '-||', 'licontinue': 'fr'}
        transport = Transport([fallback_response({'ar': [], 'en': []}, token),
                               fallback_response({'fr': ['de', 'it']})])
        records = self.collect(transport)
        self.assertEqual(records['language-fallbacks']['rows'], 3)
        self.assertEqual(len(transport.calls), 4)
        self.assertEqual(parse_qs(urlsplit(transport.calls[1]).query)['licontinue'], ['fr'])
        self.assertEqual(len(list(self.args.output.glob('*.raw.json'))), 4)
        capture.verify(self.args.output)

    def test_repeated_or_duplicate_continuation_fails_without_publication(self):
        token = {'continue': '-||', 'licontinue': 'fr'}
        for suffix, pages in (
                ('repeat', [fallback_response({'ar': [], 'en': []}, token), fallback_response({'fr': []}, token)]),
                ('duplicate', [fallback_response({'ar': [], 'en': []}, token), fallback_response({'ar': []})])):
            self.args.output = self.base / suffix
            with self.subTest(suffix=suffix), self.assertRaises(ValueError):
                self.collect(Transport(pages))
            self.assertFalse((self.args.output / capture.COMPLETE).exists())
            self.assertFalse((self.args.output / 'language-fallbacks.tsv').exists())
            self.assertTrue((self.args.output / (capture.PREFIX + 'failure.json')).exists())

    def test_uncaptured_selected_language_not_inferred(self):
        with self.assertRaisesRegex(ValueError, 'Selected language missing'):
            self.collect(Transport([fallback_response({'en': []})]))

    def test_failed_retry_evidence_retained(self):
        raw = json.dumps({'error': {'code': 'maxlag'}}).encode()
        transport = Transport(first_error=(200, {'Retry-After': '1'}, raw))
        sleeps = []
        capture.capture(self.args, transport, sleep=sleeps.append)
        receipts = [json.loads(p.read_text()) for p in self.args.output.glob('*.receipt.json')]
        self.assertEqual(sum(not r['accepted'] for r in receipts), 1)
        self.assertIn(1, sleeps)
        capture.verify(self.args.output)

    def test_network_failure_retries_bounded_and_retained(self):
        transport = mock.Mock(side_effect=OSError('offline'))
        with self.assertRaises(OSError):
            self.collect(transport)
        self.assertEqual(transport.call_count, 4)
        self.assertEqual(len(list(self.args.output.glob('*.receipt.json'))), 4)
        self.assertFalse((self.args.output / capture.COMPLETE).exists())

    def test_mutated_source_guard_fails(self):
        transport = Transport()
        def changing(url, timeout):
            result = transport(url, timeout)
            self.args.namespace_registry.write_text(NAMESPACE + '# changed\n')
            return result
        with self.assertRaisesRegex(ValueError, 'changed during capture'):
            self.collect(changing)
        self.assertFalse((self.args.output / capture.COMPLETE).exists())

    def test_raw_tsv_or_marker_tampering_rejected(self):
        self.collect()
        for name in ('language-messages.0001-01.raw.json', 'interface-messages.tsv', capture.COMPLETE):
            path = self.args.output / name
            original = path.read_bytes()
            path.write_bytes(original.replace(b'"schema"', b'"invalid_schema"') if name == capture.COMPLETE else original + b' ')
            with self.subTest(name=name), self.assertRaises(ValueError):
                capture.verify(self.args.output)
            path.write_bytes(original)

    def test_missing_completion_and_symlink_payload_rejected(self):
        self.collect()
        marker = self.args.output / capture.COMPLETE
        original = marker.read_bytes(); marker.unlink()
        with self.assertRaises((OSError, ValueError)):
            capture.verify(self.args.output)
        marker.write_bytes(original)
        payload = self.args.output / 'language-messages.0001-01.raw.json'
        saved = self.base / 'saved.json'; payload.rename(saved); payload.symlink_to(saved)
        with self.assertRaises((OSError, ValueError)):
            capture.verify(self.args.output)

    def test_semantic_replay_rejects_wrong_parser_mode(self):
        self.collect()
        request = self.args.output / 'language-messages.0002.request.json'
        data = json.loads(request.read_text())
        data['query']['amenableparser'] = '1'
        data['url'] = capture.query_url(WIKI, data['query'])
        request.write_bytes(capture.evidence.encoded(data))
        self.rebind()
        with self.assertRaisesRegex(ValueError, 'API semantics'):
            capture.verify(self.args.output)

    def test_semantic_replay_rejects_removed_continuation_evidence(self):
        token = {'continue': '-||', 'licontinue': 'fr'}
        self.collect(Transport([fallback_response({'ar': [], 'en': []}, token), fallback_response({'fr': []})]))
        hashes = {}
        for kind in capture.KINDS:
            path = self.args.output / (kind + '.manifest.json')
            data = json.loads(path.read_text()); data['requests'].pop(1)
            path.write_bytes(capture.evidence.encoded(data))
            hashes[path.name] = capture.evidence.digest(path.read_bytes())
        (self.args.output / capture.COMPLETE).write_bytes(capture.evidence.encoded({'schema': capture.SCHEMA, 'manifests': hashes}))
        with self.assertRaisesRegex(ValueError, 'Incomplete'):
            capture.verify(self.args.output)

    def test_thirteen_key_profile_roundtrips_and_old_profile_cannot_claim_it(self):
        extra = ['jsonconfig-license-name-CC0-1.0', 'jsonconfig-license-url-CC0-1.0', 'formatnum-nan']
        keys = KEYS + [f'Existing-{i}' for i in range(6)] + extra
        self.assertEqual(len(keys), 13)
        self.args.messages = keys
        with mock.patch.dict(SOURCES, {key: 'captured ' + key for key in keys if key not in SOURCES}):
            records = self.collect()
        self.assertEqual(records['interface-messages']['rows'], 26)
        capture.verify(self.args.output)
        for kind in capture.KINDS:
            path = self.args.output / (kind + '.manifest.json')
            manifest = json.loads(path.read_text())
            manifest['generator_sha256'] = capture.LEGACY_GENERATOR_SHA256
            path.write_bytes(capture.evidence.encoded(manifest))
        self.rebind()
        with self.assertRaisesRegex(ValueError, 'original collector'):
            capture.verify(self.args.output)

    def test_exact_legacy_collector_replays_but_unknown_hash_or_dependencies_fail(self):
        self.collect()
        original = {}
        for kind in capture.KINDS:
            path = self.args.output / (kind + '.manifest.json')
            manifest = json.loads(path.read_text())
            manifest['generator_sha256'] = capture.LEGACY_GENERATOR_SHA256
            original[kind] = copy.deepcopy(manifest)
            path.write_bytes(capture.evidence.encoded(manifest))
        self.rebind()
        capture.verify(self.args.output)
        for corruption in ('generator', 'dependency'):
            for kind in capture.KINDS:
                manifest = copy.deepcopy(original[kind])
                if corruption == 'generator':
                    manifest['generator_sha256'] = '0' * 64
                else:
                    manifest['dependency_sha256']['tools/prepare_file_metadata.py'] = '0' * 64
                (self.args.output / (kind + '.manifest.json')).write_bytes(capture.evidence.encoded(manifest))
            self.rebind()
            with self.assertRaisesRegex(ValueError, 'original collector'):
                capture.verify(self.args.output)

    def test_new_generation_required_and_excess_keys_fail_before_requests(self):
        self.collect()
        with self.assertRaises(FileExistsError):
            self.collect()
        self.args.output = self.base / 'excess'
        self.args.messages = [f'Key-{i}' for i in range(capture.MAX_MESSAGE_KEYS + 1)]
        transport = mock.Mock()
        with self.assertRaises(ValueError):
            self.collect(transport)
        transport.assert_not_called()

    def test_bounded_requests_and_deadline_fail_without_publication(self):
        with mock.patch.object(capture, 'MAX_REQUESTS', 1):
            with self.assertRaisesRegex(ValueError, 'request bound'):
                self.collect()
        self.assertFalse((self.args.output / capture.COMPLETE).exists())
        self.args.output = self.base / 'deadline'
        with mock.patch.object(capture.time, 'monotonic', side_effect=[0, 100]):
            with self.assertRaisesRegex(ValueError, 'deadline'):
                self.collect()



    def test_exact_replay_reuse_returns_fresh_manifests_and_keeps_bounds(self):
        self.collect()
        capture._VALIDATED_REPLAY_KEYS.clear()
        with mock.patch.object(capture, 'parse_fallbacks', wraps=capture.parse_fallbacks) as replay:
            first = capture.verify(self.args.output)
            expected = copy.deepcopy(first)
            first['language-fallbacks']['artifacts'].clear()
            first['interface-messages']['keys'].clear()
            self.assertEqual(capture.verify(self.args.output), expected)
            self.assertEqual(replay.call_count, 1)
        with mock.patch.object(capture, 'MAX_FALLBACK_ROWS', 1):
            with self.assertRaisesRegex(ValueError, 'excessive language metadata'):
                capture.verify(self.args.output)

    def test_exact_replay_reuse_still_hashes_raw_bytes_and_rebound_projections(self):
        self.collect()
        capture.verify(self.args.output)
        raw = self.args.output / 'language-messages.0001-01.raw.json'
        raw.write_bytes(raw.read_bytes() + b' ')
        with self.assertRaisesRegex(ValueError, 'inventory/hash mismatch'):
            capture.verify(self.args.output)
        # Rebinding semantically equivalent raw JSON requires a new replay.
        self.rebind()
        receipt = self.args.output / 'language-messages.0001-01.receipt.json'
        record = json.loads(receipt.read_text())
        record.update(response_bytes=raw.stat().st_size,
                      response_sha256=capture.evidence.digest(raw.read_bytes()))
        receipt.write_bytes(capture.evidence.encoded(record))
        self.rebind()
        with mock.patch.object(capture, 'parse_fallbacks', wraps=capture.parse_fallbacks) as replay:
            capture.verify(self.args.output)
            self.assertEqual(replay.call_count, 1)
        output = self.args.output / 'language-fallbacks.tsv'
        output.write_bytes(output.read_bytes().replace(b'fr\tde\tit', b'fr\tit\tde'))
        self.rebind()
        with self.assertRaisesRegex(ValueError, 'Rendered TSV differs'):
            capture.verify(self.args.output)

    def test_exact_pre_cache_thirteen_key_capture_replays_without_rewriting(self):
        self.args.messages = KEYS + [f'Extra-{i}' for i in range(9)]
        self.collect()
        for kind in capture.KINDS:
            path = self.args.output / (kind + '.manifest.json')
            manifest = json.loads(path.read_text())
            manifest['generator_sha256'] = capture.PRE_CACHE_GENERATOR_SHA256
            path.write_bytes(capture.evidence.encoded(manifest))
        self.rebind()
        before = {path.name: path.read_bytes() for path in self.args.output.iterdir()}
        capture._VALIDATED_REPLAY_KEYS.clear()
        with mock.patch.object(capture, 'parse_fallbacks', wraps=capture.parse_fallbacks) as replay:
            first = capture.verify(self.args.output)
            self.assertEqual(capture.verify(self.args.output), first)
            self.assertEqual(replay.call_count, 1)
        self.assertEqual({path.name: path.read_bytes() for path in self.args.output.iterdir()}, before)
        for kind in capture.KINDS:
            path = self.args.output / (kind + '.manifest.json')
            manifest = json.loads(path.read_text())
            manifest['keys'] += ['Fourteen', 'Fifteen', 'Sixteen', 'Seventeen']
            path.write_bytes(capture.evidence.encoded(manifest))
        self.rebind()
        with self.assertRaisesRegex(ValueError, 'original collector'):
            capture.verify(self.args.output)

    def test_exact_replay_does_not_hide_completion_or_payload_symlinks(self):
        self.collect()
        capture.verify(self.args.output)
        marker = self.args.output / capture.COMPLETE
        original = marker.read_bytes()
        marker.write_bytes(capture.evidence.encoded({'schema': capture.SCHEMA, 'manifests': {}}))
        with self.assertRaisesRegex(ValueError, 'completion marker mismatch'):
            capture.verify(self.args.output)
        marker.write_bytes(original)
        payload = self.args.output / 'language-messages.0001-01.raw.json'
        saved = self.base / 'same-raw.json'
        payload.rename(saved)
        payload.symlink_to(saved)
        with self.assertRaises((ValueError, OSError)):
            capture.verify(self.args.output)

if __name__ == '__main__':
    unittest.main()

