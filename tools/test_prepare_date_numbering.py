import copy
import json
from pathlib import Path
import shutil
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
from urllib.parse import parse_qs, urlsplit

import prepare_date_numbering as capture

WIKI = 'bnwiktionary'
DATE = '20261001'
NAMESPACE = ('# wikidict-namespace-registry-v1\n# wiki\tbnwiktionary\n'
             '# dump-date\t20261001\n# content-language\tbn\n')
BENGALI = list('০১২৩৪৫৬৭৮৯')


def site_response(languages=None, timezone='UTC'):
    query = {'general': {'wikiid': WIKI, 'lang': 'bn', 'timezone': timezone,
                         'generator': 'MediaWiki 1.47.0-wmf.22', 'git-hash': 'a' * 40}}
    if languages is not None:
        query['languageinfo'] = {code: {'code': code} for code in languages}
    return {'query': query}


def oracle_response(digits=None, values=None):
    digits = list(digits or BENGALI)
    composite = ''.join(digits[1:] + digits[:1])
    fields = dict(zip(capture.FIELDS, digits + [composite, '1234567890', '-1', composite]))
    fields.update(values or {})
    return {'expandtemplates': {'wikitext': '\n'.join([
        capture.BEGIN, *(key + '=' + fields[key] for key in capture.FIELDS), capture.END])}}


class Transport:
    def __init__(self, first_error=None, final_timezone='UTC', oracle=None, known=True):
        self.calls = []
        self.first_error = first_error
        self.final_timezone = final_timezone
        self.oracle = oracle
        self.known = known

    def __call__(self, url, timeout):
        self.calls.append((url, timeout))
        if self.first_error is not None:
            result, self.first_error = self.first_error, None
            if isinstance(result, Exception):
                raise result
            return result
        query = parse_qs(urlsplit(url).query)
        if query['action'] == ['expandtemplates']:
            assert query['prop'] == ['wikitext'] and query['title'] == ['API']
            result = self.oracle or oracle_response()
        elif query['meta'] == ['siteinfo|languageinfo']:
            codes = query['licode'][0].split('|')
            result = site_response(codes if self.known else [])
        else:
            assert query['meta'] == ['siteinfo']
            result = site_response(timezone=self.final_timezone)
        return 200, {'Date': 'Tue, 06 Oct 2026 00:00:00 GMT'}, capture.evidence.encoded(result)


class ParseTest(unittest.TestCase):
    def test_exact_framing_contains_fourteen_fields_and_explicit_locale(self):
        text = capture.oracle_text('bn')
        self.assertEqual(len(text.split('\n')), 16)
        self.assertTrue(text.startswith(capture.BEGIN + '\nD0={{#time:U|@0|bn}}\n'))
        self.assertIn('\nRAW={{#time:xnU|@1234567890|bn}}\n', text)
        self.assertIn('\nNEGATIVE={{#time:U|@-1|bn}}\n', text)
        self.assertTrue(text.endswith('\n' + capture.END))
        for code in ('b', 'BN', 'bn|en', 'bn\n', '', 'a' * 65):
            with self.subTest(code=code), self.assertRaises(ValueError):
                capture.oracle_text(code)

    def test_ascii_bengali_and_variable_width_multiscalar_profiles(self):
        for digits in (list('0123456789'), BENGALI, [x + '\u0301' for x in BENGALI]):
            with self.subTest(digits=digits):
                self.assertEqual(capture.parse_oracle(oracle_response(digits)), ('D', digits))

    def test_unicode16_scalar_and_byte_limits_match_native(self):
        for lo, hi in capture.EXCLUDED_SCALARS:
            for cp in (lo, hi):
                with self.subTest(cp=cp):
                    self.assertFalse(capture.glyph('০' + chr(cp)))
        for value in ('', '\\', 'A', '1,', '১\t', '০' * 11, '\ud800'):
            with self.subTest(value=repr(value)):
                self.assertFalse(capture.glyph(value))
        self.assertTrue(capture.glyph('০' * 10 + '12'))
        self.assertFalse(capture.glyph('০' * 10 + '123'))
        self.assertTrue(capture.glyph('一'))

    def test_each_nonconforming_wellframed_oracle_is_explicit_unsupported(self):
        cases = ({'D0': 'bad'}, {'COMPOSITE': 'bad'}, {'RAW': 'bad'},
                 {'NEGATIVE': '−১'}, {'REPEAT': 'bad'})
        for values, reason in zip(cases, capture.REASONS):
            with self.subTest(reason=reason):
                self.assertEqual(capture.parse_oracle(oracle_response(values=values)), ('U', reason))
        self.assertEqual(capture.parse_oracle(oracle_response(values={'D0': BENGALI[1]})),
                         ('U', 'invalid-glyphs'))

    def test_malformed_api_or_frame_never_becomes_unsupported(self):
        good = oracle_response()
        bad = [{}, {'error': {'code': 'badvalue'}}, {'warnings': {}, **good},
               {'continue': {}, **good}, {'expandtemplates': {'wikitext': 1}}]
        for text in (good['expandtemplates']['wikitext'] + '\n',
                     good['expandtemplates']['wikitext'].replace('D0=', 'D1=', 1),
                     good['expandtemplates']['wikitext'].replace('\nD1=', '\r\nD1=', 1),
                     good['expandtemplates']['wikitext'].replace('D0=', 'D0=\n', 1)):
            bad.append({'expandtemplates': {'wikitext': text}})
        for data in bad:
            with self.subTest(data=data), self.assertRaises(ValueError):
                capture.parse_oracle(data)

    def test_known_language_identity_and_timezone_are_explicit(self):
        self.assertEqual(capture.parse_siteinfo(site_response(['bn']), WIKI, 'bn', ['bn'])['timezone'], 'UTC')
        for data in (site_response([]), site_response(['en']), site_response(['bn'], 'UTC\\x')):
            with self.assertRaises(ValueError):
                capture.parse_siteinfo(data, WIKI, 'bn', ['bn'])
        data = site_response(['bn']); data['query']['general']['wikiid'] = 'enwiktionary'
        with self.assertRaises(ValueError):
            capture.parse_siteinfo(data, WIKI, 'bn', ['bn'])

    def test_native_wire_is_sorted_exact_and_counts_both_kinds(self):
        raw = capture.render({'bn': ('D', BENGALI), 'ar': ('U', 'invalid-glyphs')},
                             WIKI, DATE, 'bn', 'UTC')
        self.assertEqual(raw.decode().splitlines()[:6], [
            '# wikidict-date-numbering-v1', '# wiki\t' + WIKI, '# dump-date\t' + DATE,
            '# content-language\tbn', '# timezone\tUTC', '# profiles\t2'])
        self.assertIn(b'\nU\tar\tinvalid-glyphs\nD\tbn\t', raw)
        self.assertTrue(raw.endswith('\n'.encode()))
        self.assertFalse(raw.endswith(b'\n\n'))
        with self.assertRaises(ValueError):
            capture.render({'bn': ('U', 'invented')}, WIKI, DATE, 'bn', 'UTC')


class CaptureTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        namespace = self.base / 'namespace.tsv'
        namespace.write_text(NAMESPACE)
        # Small controlled source fixtures exercise portable evidence and exact
        # source-pin enforcement without network or a checkout of MediaWiki.
        source_root = self.base / 'sources'; source_root.mkdir()
        references, rows = {}, []
        for role in capture.SOURCE_CONTRACT:
            raw = ('<?php /* fixture ' + role + ' */\n').encode()
            name = role + '.php'
            (source_root / name).write_bytes(raw)
            url = 'https://raw.githubusercontent.com/wikimedia/test/' + role
            sha = capture.evidence.digest(raw)
            references[role] = (url, sha)
            rows.append({'role': role, 'path': name, 'url': url, 'sha256': sha})
        proof = source_root / 'core-proof.json'
        proof.write_bytes(capture.evidence.encoded({'schema': capture.PROOF_SCHEMA, 'sources': rows}))
        patcher = mock.patch.object(capture, 'SOURCE_CONTRACT', references)
        patcher.start(); self.addCleanup(patcher.stop)
        self.args = SimpleNamespace(wiki=WIKI, date=DATE, namespace_registry=namespace,
            core_proof=proof, output=self.base / 'generation', languages=[], delay=0, wall_seconds=60)

    def collect(self, transport=None):
        return capture.capture(self.args, transport or Transport(), sleep=lambda _: None)

    def rebind(self):
        path = self.args.output / capture.MANIFEST
        manifest = capture.evidence.decode(path.read_bytes())
        manifest['artifacts'] = capture.owned_payload(self.args.output)
        raw = capture.evidence.encoded(manifest)
        path.write_bytes(raw)
        (self.args.output / capture.COMPLETE).write_bytes(capture.evidence.encoded(
            {'schema': capture.SCHEMA, 'manifest_sha256': capture.evidence.digest(raw)}))

    def test_roundtrip_portable_pinning_and_explicit_current_scope(self):
        manifest = self.collect()
        self.assertEqual(manifest['rows'], 1)
        self.assertEqual((manifest['supported_rows'], manifest['unknown_rows']), (1, 0))
        self.assertEqual(manifest['languages'], ['bn'])
        self.assertEqual(manifest['siteinfo_identity']['timezone'], 'UTC')
        self.assertIsNone(manifest['dump_date'])
        self.assertFalse(manifest['corpus_query_closure_proven'])
        self.assertEqual(manifest['reference_scope'], 'reviewed-reference-semantics-not-server-commit')
        self.assertEqual(capture.verify(self.args.output), manifest)
        snapshot = self.args.output / capture.SNAPSHOT
        inventory = capture.capture_artifacts(snapshot, manifest)
        pinned = self.base / 'pinned'; pinned.mkdir()
        for name in inventory:
            shutil.copyfile(self.args.output / name, pinned / name)
        shutil.rmtree(self.base / 'sources')
        self.assertEqual(capture.validate_snapshot(pinned / capture.SNAPSHOT, WIKI, DATE), manifest)
        with self.assertRaises(ValueError):
            capture.validate_snapshot(pinned / capture.SNAPSHOT, 'enwiktionary', DATE)

    def test_wellformed_unsupported_observation_is_retained_and_replayed(self):
        manifest = self.collect(Transport(oracle=oracle_response(values={'NEGATIVE': '−১'})))
        self.assertEqual((manifest['supported_rows'], manifest['unknown_rows']), (0, 1))
        self.assertIn(b'\nU\tbn\tnegative-mismatch\n', (self.args.output / capture.SNAPSHOT).read_bytes())
        self.assertEqual(capture.verify(self.args.output), manifest)

    def test_unknown_language_and_final_identity_drift_fail_without_publication(self):
        for suffix, transport in (('unknown', Transport(known=False)),
                                  ('drift', Transport(final_timezone='Europe/Paris'))):
            self.args.output = self.base / suffix
            with self.subTest(suffix=suffix), self.assertRaises(ValueError):
                self.collect(transport)
            self.assertFalse((self.args.output / capture.COMPLETE).exists())
            self.assertFalse((self.args.output / capture.SNAPSHOT).exists())
            self.assertTrue((self.args.output / (capture.PREFIX + 'failure.json')).exists())

    def test_retries_are_bounded_and_keep_failed_raw_receipts(self):
        first = (200, {'Retry-After': '1'}, b'{"error":{"code":"maxlag"}}')
        transport, sleeps = Transport(first_error=first), []
        capture.capture(self.args, transport, sleep=sleeps.append)
        self.assertIn(1, sleeps)
        self.assertEqual(len(transport.calls), 4)
        self.assertTrue((self.args.output / 'date-numbering.0001-01.raw.json').exists())
        self.assertTrue((self.args.output / 'date-numbering.0001-02.raw.json').exists())
        self.assertTrue(all(0 < timeout <= 30 for _, timeout in transport.calls))
        capture.verify(self.args.output)

    def test_server_retry_after_above_bound_fails(self):
        transport = Transport(first_error=(429, {'Retry-After': '61'}, b'{}'))
        with self.assertRaisesRegex(ValueError, 'Retry exceeds'):
            self.collect(transport)
        self.assertEqual(len(transport.calls), 1)
        self.assertFalse((self.args.output / capture.COMPLETE).exists())

    def test_raw_response_integrity_and_semantic_replay_are_separate_checks(self):
        self.collect()
        path = self.args.output / 'date-numbering.0002-01.raw.json'
        path.write_bytes(capture.evidence.encoded(oracle_response(values={'RAW': 'bad'})))
        with self.assertRaisesRegex(ValueError, 'inventory'):
            capture.verify(self.args.output)
        receipt_path = self.args.output / 'date-numbering.0002-01.receipt.json'
        receipt = capture.evidence.decode(receipt_path.read_bytes())
        receipt.update(response_bytes=path.stat().st_size, response_sha256=capture.evidence.digest(path.read_bytes()))
        receipt_path.write_bytes(capture.evidence.encoded(receipt))
        self.rebind()
        with self.assertRaisesRegex(ValueError, 'TSV differs'):
            capture.verify(self.args.output)

    def test_hash_rebound_query_cannot_change_oracle_semantics(self):
        self.collect()
        path = self.args.output / 'date-numbering.0002.request.json'
        request = capture.evidence.decode(path.read_bytes())
        request['query']['text'] = '{{#time:U|@1234567890|en}}'
        path.write_bytes(capture.evidence.encoded(request))
        self.rebind()
        with self.assertRaisesRegex(ValueError, 'oracle semantics'):
            capture.verify(self.args.output)

    def test_hash_rebound_primary_source_cannot_change_reference_contract(self):
        self.collect()
        path = self.args.output / 'date-numbering.source.language.php'
        path.write_text('<?php changed\n')
        self.rebind()
        with self.assertRaisesRegex(ValueError, 'source bytes'):
            capture.verify(self.args.output)

    def test_missing_marker_dependency_drift_and_symlink_fail(self):
        manifest = self.collect()
        with mock.patch.object(capture, 'producer', return_value={
                'generator_sha256': '0' * 64, 'dependency_sha256': manifest['dependency_sha256']}):
            with self.assertRaisesRegex(ValueError, 'original collector'):
                capture.verify(self.args.output)
        (self.args.output / capture.COMPLETE).unlink()
        with self.assertRaises(OSError):
            capture.verify(self.args.output)
        link = self.base / 'link'; link.symlink_to(self.args.output, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'Unsafe'):
            capture.verify(link)

    def test_maximum_64_profiles_capture_and_replay_below_manifest_limit(self):
        self.args.languages = ['x' + str(i).zfill(2) for i in range(64)]
        transport = Transport()
        manifest = self.collect(transport)
        self.assertEqual(len(transport.calls), 69)
        self.assertEqual((manifest['rows'], manifest['supported_rows'], manifest['unknown_rows']), (64, 64, 0))
        self.assertLess((self.args.output / capture.MANIFEST).stat().st_size, capture.MAX_MANIFEST)
        self.assertEqual(capture.verify(self.args.output), manifest)

    def test_selection_and_request_limits_are_bounded(self):
        self.assertEqual(len(capture.specifications(['bn'])), 3)
        codes = ['x' + str(i).zfill(2) for i in range(64)]
        self.assertEqual(len(capture.specifications(codes)), 69)
        for selected in (['bn', 'bn'], ['BN'], codes + ['zz']):
            self.args.languages = selected
            with self.subTest(selected=selected), self.assertRaises(ValueError):
                self.collect()
        for delay in (float('nan'), float('inf'), -1, 61):
            self.args.languages = []; self.args.delay = delay
            with self.subTest(delay=delay), self.assertRaises(ValueError):
                self.collect()


    def test_builder_namespace_binding_rejects_other_bytes(self):
        import build_wiktionaries as builder
        self.collect()
        snapshots = {'date-numbering': self.args.output / capture.SNAPSHOT,
                     'namespace-registry': self.args.namespace_registry}
        hashes = builder.verified_auxiliary_hashes(snapshots, WIKI, DATE)
        self.assertEqual(hashes['namespace-registry'], capture.evidence.digest(NAMESPACE.encode()))
        self.args.namespace_registry.write_text(NAMESPACE + '# changed\n')
        with self.assertRaisesRegex(ValueError, 'different namespace registry'):
            builder.verified_auxiliary_hashes(snapshots, WIKI, DATE)

    def test_builder_pins_complete_provider_in_dedicated_directory(self):
        import build_wiktionaries as builder
        manifest = self.collect()
        snapshots = {'date-numbering': self.args.output / capture.SNAPSHOT}
        hashes = builder.verified_auxiliary_hashes(snapshots, WIKI, DATE)
        identities = builder.auxiliary_capture_identities(snapshots)
        target = self.base / 'build'
        pinned = builder.pinned_auxiliary_snapshots(snapshots, hashes, target, *identities)
        self.assertEqual(pinned['date-numbering'], target / 'date-numbering' / capture.SNAPSHOT)
        self.assertEqual(capture.validate_snapshot(pinned['date-numbering'], WIKI, DATE), manifest)
        self.assertEqual(builder.verified_auxiliary_hashes(pinned, WIKI, DATE), hashes)
        self.assertIn('--date-numbering-snapshot', builder.auxiliary_snapshot_args(pinned))

    def test_builder_discovers_actual_preferred_generation_and_replays_it(self):
        import build_wiktionaries as builder
        outer = self.base / 'capture'
        self.args.output = outer / 'date-numbering'
        self.collect()
        result = builder.discover_auxiliary_generation(outer, 'date-numbering', ('date-numbering',), WIKI, DATE)
        self.assertEqual(result, {'date-numbering': self.args.output / capture.SNAPSHOT})
        (self.args.output / capture.COMPLETE).unlink()
        with self.assertRaises((ValueError, OSError)):
            builder.discover_auxiliary_generation(outer, 'date-numbering', ('date-numbering',), WIKI, DATE)


if __name__ == '__main__':
    unittest.main()
