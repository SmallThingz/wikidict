import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import prepare_language_names_autonyms as m


def response():
    return {'query': {'general': {'wikiid': 'arwiktionary', 'lang': 'ar', 'git-hash': m.CORE},
                      'languageinfo': {'en': {'code': 'en', 'autonym': 'English'},
                                       'ar': {'code': 'ar', 'autonym': 'العربية'},
                                       'zz': {'code': 'zz', 'autonym': ''}},
                      'languages': [{'code': 'en', 'name': 'translated English'},
                                    {'code': 'ar', 'name': 'translated Arabic'}]}}


class AutonymCaptureTests(unittest.TestCase):
    def test_continued_capture_waits_before_the_next_request(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); sources = root / 'sources'; sources.mkdir()
            source = b"private const DEPRECATED_LANGUAGE_CODE_MAPPING = [\n\t];\nprivate const NON_STANDARD_LANGUAGE_CODE_MAPPING = [\n\t];\n"
            builtin = b"public const NAMES = [\n\t'en' => 'English',\n\t'ar' => 'Arabic',\n\t];\n"
            (sources / 'LanguageCode.php').write_bytes(source)
            (sources / 'Names.php').write_bytes(builtin)
            namespace = root / 'namespace.tsv'
            namespace.write_text('# wikidict-namespace-registry-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n')
            first, second = response(), response()
            first['query']['languageinfo'] = {'ar': first['query']['languageinfo']['ar']}
            first['continue'] = {'continue': '-||', 'licontinue': 'en'}
            del second['query']['languageinfo']['ar']
            pending, events = [first, second], []
            def transport(url, timeout):
                events.append('request')
                return 200, {}, json.dumps(pending.pop(0)).encode()
            def sleep(delay):
                events.append(('wait', delay))
            with mock.patch.object(m, 'SOURCE_PINS', {'LanguageCode.php': hashlib.sha256(source).hexdigest(),
                                                     'Names.php': hashlib.sha256(builtin).hexdigest()}):
                observed = m.capture_observation('arwiktionary', '20261001', namespace, sources,
                                                root / 'capture', transport=transport, sleep=sleep)
                self.assertEqual(events, ['request', ('wait', 1), 'request'])
                self.assertEqual(observed['observed_codes'], 3)
                self.assertEqual(m.replay_observation(root / 'capture', observed)[1]['ar'], 'العربية')

    def test_genuine_autonyms_ignore_translated_siteinfo_values(self):
        names, mw, _, continuation = m.parse_response(response(), 'arwiktionary', 'ar')
        self.assertEqual(names['ar'], 'العربية')
        self.assertNotEqual(names['ar'], mw['ar'])
        self.assertEqual(names['zz'], '')
        self.assertEqual(continuation, {})

    def test_exact_site_and_core_identity_required(self):
        for key, value in [('wikiid', 'enwiktionary'), ('lang', 'en'), ('git-hash', '0' * 40)]:
            data = response()
            data['query']['general'][key] = value
            with self.assertRaises(ValueError):
                m.parse_response(data, 'arwiktionary', 'ar')

        second = '1' * 40
        data = response(); data['query']['general']['git-hash'] = second
        self.assertEqual(m.parse_response(data, 'arwiktionary', 'ar', core=second)[0]['en'], 'English')
        with self.assertRaises(ValueError):
            m.parse_response(data, 'arwiktionary', 'ar', core='2' * 40)
        with self.assertRaises(ValueError):
            m.parse_response(data, 'arwiktionary', 'ar', core='not-a-revision')
        current = m.producer()
        legacy = dict(current, generator_sha256=m.LEGACY_GENERATOR_SHA256, core=m.CORE)
        self.assertTrue(m.accepted_producer(legacy))
        # Core/source authority is checked by replay, not producer identity.
        self.assertTrue(m.accepted_producer(dict(legacy, core=second)))
        self.assertFalse(m.accepted_producer(dict(legacy, dependency_sha256={})))
        self.assertTrue(m.accepted_producer(dict(legacy, generator_sha256='0' * 64)))

    def test_recorded_provenance_is_strict_but_not_current_code_identity(self):
        record = m.producer()
        for name, value in record['dependency_sha256'].items():
            self.assertEqual(value, m.evidence.digest(m.evidence.small(Path(m.evidence.__file__).with_name(name))))
        historical = copy.deepcopy(record)
        historical['generator_sha256'] = 'a' * 64
        historical['dependency_sha256'] = {name: 'b' * 64 for name in m.DEPENDENCIES}
        self.assertTrue(m.accepted_producer(historical))
        for value in ('A' * 64, 'g' * 64, '0' * 63, None, 1, []):
            with self.subTest(value=value):
                self.assertFalse(m.accepted_producer(dict(historical, generator_sha256=value)))
                bad = copy.deepcopy(historical)
                bad['dependency_sha256']['download_wiktionaries.py'] = value
                self.assertFalse(m.accepted_producer(bad))
        for value in ({}, [], None, dict(historical['dependency_sha256'], unexpected='c' * 64)):
            self.assertFalse(m.accepted_producer(dict(historical, dependency_sha256=value)))

    def test_warning_and_duplicate_mw_code_refused(self):
        data = response(); data['warnings'] = {}
        with self.assertRaises(ValueError):
            m.parse_response(data, 'arwiktionary', 'ar')
        data = response(); data['query']['languages'].append(data['query']['languages'][0])
        with self.assertRaises(ValueError):
            m.parse_response(data, 'arwiktionary', 'ar')

    def test_missing_autonym_and_mismatched_code_refused(self):
        for change in ('missing', 'code'):
            data = response()
            if change == 'missing':
                del data['query']['languageinfo']['en']['autonym']
            else:
                data['query']['languageinfo']['en']['code'] = 'de'
            with self.assertRaises(ValueError):
                m.parse_response(data, 'arwiktionary', 'ar')

    def test_continuation_shape_is_finite_and_exact(self):
        data = response(); data['continue'] = {'continue': '-||', 'licontinue': 'en'}
        self.assertEqual(m.parse_response(data, 'arwiktionary', 'ar')[3], data['continue'])
        data['continue']['extra'] = 'x'
        with self.assertRaises(ValueError):
            m.parse_response(data, 'arwiktionary', 'ar')

    def test_alias_union_uses_only_normalized_genuine_targets(self):
        names = {'en': 'English', 'ar': 'العربية', 'zz': ''}
        single = m.finish(names, {'en': 'not autonym', 'ar': 'not autonym'}, {'eng': 'en', 'unknown-alias': 'missing'}, {'en', 'ar'})
        self.assertEqual(single['eng'], 'English')
        self.assertEqual(single['unknown-alias'], '')
        with self.assertRaises(ValueError):
            m.finish({'en': 'English', 'eng': 'different'}, {'en': 'English'}, {'eng': 'en'}, {'en'})

    def test_positive_unobserved_language_is_not_guessed(self):
        with self.assertRaises(ValueError):
            m.finish({'en': 'English', 'xx': 'invented'}, {'en': 'English'}, {}, {'en'})
        with self.assertRaises(ValueError):
            m.finish({'en': 'English'}, {'en': 'English', 'ar': 'العربية'}, {}, {'en', 'ar'})

        # Removing the same built-in code from both API arrays must still fail.
        with self.assertRaisesRegex(ValueError, 'Incomplete built-in MW inventory'):
            m.finish({'en': 'English'}, {'en': 'English'}, {}, {'en', 'ar'})

    def test_null_single_serialization_keeps_empty_and_escapes(self):
        raw = m.render_profile({'ar': 'العربية', 'zz': '', 'xx': 'a\tb\nc\\d'})
        self.assertEqual(raw.splitlines()[0], b'C\t-\tsingle\t3')
        self.assertIn(b'N\t-\tsingle\tzz\t\n', raw)
        self.assertIn(b'N\t-\tsingle\txx\ta\\tb\\nc\\\\d\n', raw)

    def test_legacy_schema_dispatch_is_preserved_and_unknown_refused(self):
        self.assertIs(m.previous_helper('wikidict.language-names-capture.v1'), m.legacy)
        self.assertEqual(m.previous_helper('wikidict.language-names-capture.v2').SCHEMA, 'wikidict.language-names-capture.v2')
        self.assertEqual(m.previous_helper('wikidict.language-names-translate-capture.v1').SCHEMA, 'wikidict.language-names-translate-capture.v1')
        with self.assertRaises(ValueError):
            m.previous_helper('unknown')

    def test_capture_records_one_http_observation_and_replays_offline(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); sources = root / 'sources'; sources.mkdir()
            code = b"private const DEPRECATED_LANGUAGE_CODE_MAPPING = [\n\t];\nprivate const NON_STANDARD_LANGUAGE_CODE_MAPPING = [\n\t];\n"
            (sources / 'LanguageCode.php').write_bytes(code)
            names_source = b"public const NAMES = [\n\t\t'en' => 'English',\n\t\t'ar' => 'unused value',\n\t\t'en-x-piglatin' => 'optional testing language',\n\t];\n"
            (sources / 'Names.php').write_bytes(names_source)
            namespace = root / 'namespace.tsv'
            namespace.write_text('# wikidict-namespace-registry-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n')
            raw = json.dumps(response(), ensure_ascii=False).encode()
            calls = []
            def transport(url, timeout):
                calls.append((url, timeout))
                return 200, {}, raw
            with mock.patch.object(m, 'SOURCE_PINS', {'LanguageCode.php': hashlib.sha256(code).hexdigest(), 'Names.php': hashlib.sha256(names_source).hexdigest()}):
                observed = m.capture_observation('arwiktionary', '20261001', namespace, sources, root / 'out', transport=transport)
                self.assertEqual(len(calls), 1)
                self.assertIn('liprop=code%7Cautonym', calls[0][0])
                self.assertLessEqual(calls[0][1], 30)
                self.assertEqual(observed['observed_codes'], 3)
                self.assertEqual(observed['observed_empty'], 1)
                self.assertEqual(m.replay_observation(root / 'out', observed)[1]['ar'], 'العربية')
                historical = copy.deepcopy(observed)
                historical['generator_sha256'] = 'a' * 64
                historical['dependency_sha256'] = {name: 'b' * 64 for name in m.DEPENDENCIES}
                self.assertTrue(m.accepted_producer(historical))
                self.assertEqual(m.replay_observation(root/'out', historical), m.replay_observation(root/'out', observed))
                request_path = root/'out'/observed['requests'][0]['request']
                request_before = request_path.read_bytes()
                bad_request = json.loads(request_before); bad_request['query']['liprop'] = 'code|name'
                request_path.write_text(json.dumps(bad_request))
                with self.assertRaises(ValueError):
                    m.replay_observation(root/'out', historical)
                request_path.write_bytes(request_before)
                receipt_path = root/'out'/observed['requests'][0]['accepted_receipt']
                receipt_before = receipt_path.read_bytes()
                bad_receipt = json.loads(receipt_before); bad_receipt['accepted'] = False
                receipt_path.write_text(json.dumps(bad_receipt))
                with self.assertRaises(ValueError):
                    m.replay_observation(root/'out', historical)
                receipt_path.write_bytes(receipt_before)
                second = '1' * 40
                second_data = response(); second_data['query']['general']['git-hash'] = second
                second_raw = json.dumps(second_data, ensure_ascii=False).encode()
                comparison = dict(schema='wikidict.observed-core-source-comparison.v1',
                    outcome='completed-source-comparison', core=second, previous_core=m.CORE,
                    all_five_byte_identical=True, source_requests=len(m.SOURCE_PINS), api_requests=0,
                    files=[dict(url='https://raw.githubusercontent.com/wikimedia/mediawiki/' + second + '/' + m.SOURCE_PATHS[name],
                        core=second, status=200, bytes=(sources/name).stat().st_size, sha256=pin,
                        previous_sha256=pin, byte_identical_to_previous=True) for name,pin in m.SOURCE_PINS.items()])
                # A mismatched live observation remains genuinely rejected; offline adoption must retain it.
                saved = root/'rejected'
                with self.assertRaises(Exception):
                    m.capture_observation('arwiktionary', '20261001', namespace, sources, saved,
                        transport=lambda url,timeout:(200,{},second_raw), sleep=lambda delay:None)
                receipt_name=m.PREFIX+'0001-01.receipt.json'
                original_receipt=(saved/receipt_name).read_bytes()
                self.assertIs(json.loads(original_receipt)['accepted'], False)
                (sources/'comparison.json').write_text(json.dumps(comparison))
                fresh=m.capture_observation('arwiktionary','20261001',namespace,sources,root/'second',
                    transport=lambda url,timeout:(200,{},second_raw))
                self.assertEqual(fresh['config']['core'],second)
                with mock.patch.object(m.evidence,'get_response',side_effect=AssertionError('offline replay called network')):
                    self.assertEqual(m.replay_observation(root/'second',fresh)[1]['ar'],'العربية')
                for layout in (m.PREFIX,'language-names.'):
                    retained=root/('saved-'+layout);retained.mkdir()
                    for item in saved.iterdir():
                        if item.name.startswith(m.PREFIX):
                            name=layout+item.name[len(m.PREFIX):]
                            value=item.read_bytes()
                            if item.name==receipt_name:
                                doc=json.loads(value);doc['request']=layout+'0001.request.json';doc['response']=layout+'0001-01.raw.json'
                                value=json.dumps(doc).encode()
                            (retained/name).write_bytes(value)
                    before_receipt=(retained/(layout+'0001-01.receipt.json')).read_bytes()
                    before_request=(retained/(layout+'requested.json')).read_bytes()
                    adopted_root=root/('adopted-'+layout)
                    adopted=m.adopt_observation('arwiktionary','20261001',retained,sources,sources/'comparison.json',adopted_root)
                    self.assertEqual((adopted_root/(layout+'0001-01.receipt.json')).read_bytes(),before_receipt)
                    self.assertIs(json.loads(before_receipt)['accepted'],False)
                    self.assertEqual((adopted_root/(m.PREFIX+'original-requested.json')).read_bytes(),before_request)
                    self.assertEqual((adopted_root/(layout+'0001-01.raw.json')).read_bytes(),second_raw)
                    self.assertEqual(m.replay_observation(adopted_root,adopted)[1]['en'],'English')
                proof=root/'second'/(m.PREFIX+'source-comparison.json')
                proof.unlink()
                with self.assertRaises(ValueError):m.replay_observation(root/'second',fresh)
                mutations=[]
                bad=copy.deepcopy(comparison);bad['files'].pop();mutations.append(bad)
                bad=copy.deepcopy(comparison);bad['files'][1]=copy.deepcopy(bad['files'][0]);mutations.append(bad)
                for field,value in [('sha256','0'*64),('previous_sha256','0'*64),('url','https://invalid/Names.php'),('status',404)]:
                    bad=copy.deepcopy(comparison);bad['files'][0][field]=value;mutations.append(bad)
                for bad in mutations:
                    proof.write_text(json.dumps(bad))
                    with self.assertRaises(ValueError):m.replay_observation(root/'second',fresh)
                proof.write_text(json.dumps(comparison))
                source_file=root/'second'/(m.PREFIX+'source-Names.php');source_file.write_bytes(names_source+b' ')
                with self.assertRaises(ValueError):m.replay_observation(root/'second',fresh)
                record = observed['requests'][0]
                receipt_path = root / 'out' / record['accepted_receipt']
                receipt = json.loads(receipt_path.read_text())
                self.assertTrue(receipt['accepted'])
                body = root / 'out' / receipt['response']
                body.write_bytes(raw + b' ')
                with self.assertRaises(ValueError):
                    m.replay_observation(root / 'out', observed)

    def test_rejected_http_receipt_cannot_be_silently_promoted(self):
        receipt = {'accepted': False, 'error': 'something else'}
        with self.assertRaises(ValueError):
            m.accepted_receipt(Path('.'), {'request': 'a', 'accepted_receipt': 'b'}, receipt)

    def test_unsafe_evidence_names_and_changed_previous_bytes_refused(self):
        for name in ('../response', '/response', '..'):
            with self.assertRaises(ValueError):
                m.safe_name(name)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'previous.language-names.tsv').write_bytes(b'changed')
            manifest = {'previous': {'language-names.tsv': {'size': 3, 'sha256': '0' * 64}},
                        'wiki': 'arwiktionary', 'date': '20261001'}
            with self.assertRaises(ValueError):
                m.replay_previous(root, manifest)




class CurrentSourceContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        fixture = Path(__file__).with_name('testdata') / 'en-september-language-names'
        for name in m.CURRENT_SOURCE_PINS:
            (self.root / (m.PREFIX + 'source-' + name)).write_bytes((fixture / 'sources' / name).read_bytes())
        self.comparison = json.loads((fixture / 'autonyms-comparison.json').read_text())
        self.proof = self.root / (m.PREFIX + 'source-comparison.json')
        self.proof.write_text(json.dumps(self.comparison))

    def test_current_profile_rejects_offline_revalidation_of_genuinely_refused_capture(self):
        fixture = Path(__file__).with_name('testdata') / 'en-september-language-names'
        current_sources, old_sources = self.root / 'current-sources', self.root / 'old-sources'
        current_sources.mkdir(); old_sources.mkdir()
        for name in m.CURRENT_SOURCE_PINS:
            raw = (fixture / 'sources' / name).read_bytes()
            (current_sources / name).write_bytes(raw)
            if name == 'LanguageNameUtils.php':
                raw = (fixture / 'previous-LanguageNameUtils.php').read_bytes()
            self.assertEqual(hashlib.sha256(raw).hexdigest(), m.SOURCE_PINS[name])
            (old_sources / name).write_bytes(raw)
        (current_sources / 'comparison.json').write_text(json.dumps(self.comparison))
        namespace = self.root / 'namespace.tsv'
        namespace.write_text('# wikidict-namespace-registry-v1\n# wiki\tenwiktionary\n# dump-date\t20260901\n# content-language\ten\n')
        aliases, required = m.validate_source_contract(self.root, m.CURRENT_CORE)
        codes = sorted(required | set(aliases.values()))
        raw = json.dumps({'query': {'general': {'wikiid': 'enwiktionary', 'lang': 'en', 'git-hash': m.CURRENT_CORE},
            'languageinfo': {code: {'code': code, 'autonym': 'synthetic test'} for code in codes},
            'languages': [{'code': code, 'name': 'synthetic test'} for code in codes]}}).encode()
        def transport(url, timeout):
            return 200, {}, raw
        current, old = self.root / 'current', self.root / 'old'
        observed = m.capture_observation('enwiktionary', '20260901', namespace, current_sources, current, transport=transport)
        self.assertEqual(len(m.replay_observation(current, observed)[0]), len(codes))
        with self.assertRaisesRegex(ValueError, '^Exact API wiki/content/core identity changed$'):
            m.capture_observation('enwiktionary', '20260901', namespace, old_sources, old, transport=transport)
        with self.assertRaisesRegex(ValueError, 'Unreviewed adoption source'):
            m.adopt_observation('enwiktionary', '20260901', old, current_sources, current_sources / 'comparison.json', self.root / 'adopt')
        record, = observed['requests']
        for name in (record['request'], m.PREFIX + '0001-01.raw.json'):
            self.assertEqual((current / name).read_bytes(), (old / name).read_bytes())
        requested, proof = m.PREFIX + 'original-requested.json', m.PREFIX + 'offline-revalidation.json'
        (current / record['accepted_receipt']).write_bytes((old / record['accepted_receipt']).read_bytes())
        (current / requested).write_bytes((old / (m.PREFIX + 'requested.json')).read_bytes())
        digest = lambda name: m.evidence.digest((current / name).read_bytes())
        m.evidence.document(current / proof, dict(schema='wikidict.autonym-core-revalidation.v2',
            original_receipt_sha256=digest(record['accepted_receipt']), original_requested_sha256=digest(requested),
            source_comparison_sha256=digest(m.PREFIX + 'source-comparison.json'),
            previous_core=m.CORE, core=m.CURRENT_CORE, original_receipt_accepted=False))
        record['offline_revalidation'] = proof
        with self.assertRaisesRegex(ValueError, 'Current autonym source profile requires an accepted observation'):
            m.replay_observation(current, observed)

    def test_original_sources_use_the_reviewed_cache_initialization_profile(self):
        aliases, required = m.validate_source_contract(self.root, m.CURRENT_CORE)
        self.assertEqual(aliases['als'], 'gsw')
        self.assertGreater(len(required), 500)
        self.assertNotIn('en-x-piglatin', required)
        self.assertIn('en', required)
        with self.assertRaisesRegex(ValueError, 'Unreviewed autonym source'):
            m.validate_source_contract(self.root, m.CORE)

    def test_current_profile_cannot_claim_identical_source_or_other_revision(self):
        for key, value in (('core', m.CORE), ('previous_core', '0' * 40),
                           ('source_profile_scope', 'deployment-observation'),
                           ('all_five_byte_identical', True), ('changed_files', []),
                           ('source_profile', 'unknown')):
            changed = {**self.comparison, key: value}; self.proof.write_text(json.dumps(changed))
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'source profile'):
                m.validate_source_contract(self.root, m.CURRENT_CORE)

    def test_original_receipts_and_source_members_are_independently_checked(self):
        for field, value in (('status', 404), ('source_path', 'includes/Language/Other.php'),
                             ('previous_sha256', '0' * 64), ('byte_identical_to_previous', True)):
            changed = copy.deepcopy(self.comparison)
            next(row for row in changed['files'] if row['file'] == 'LanguageNameUtils.php')[field] = value
            self.proof.write_text(json.dumps(changed))
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'source receipt'):
                m.validate_source_contract(self.root, m.CURRENT_CORE)
        changed = copy.deepcopy(self.comparison); changed['files'][1] = changed['files'][0]
        self.proof.write_text(json.dumps(changed))
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            m.validate_source_contract(self.root, m.CURRENT_CORE)
        self.proof.write_text(json.dumps(self.comparison))
        with (self.root / (m.PREFIX + 'source-LanguageNameUtils.php')).open('ab') as stream:
            stream.write(b'\nchanged\n')
        with self.assertRaisesRegex(ValueError, 'Unreviewed autonym source'):
            m.validate_source_contract(self.root, m.CURRENT_CORE)


class SupportProjectionTests(unittest.TestCase):
    def fixture(self, root):
        # Parent replay is independently covered by the existing capture suite.
        # These controls exercise the real projection/inventory/parent joins.
        previous = root / 'previous'; previous.mkdir()
        child = b'# wikidict-language-names-v1\n# wiki\tnlwiktionary\n# dump-date\t20261001\n# content-language\tnl\nC\ten\tsingle\t1\nN\ten\tsingle\tnl\tDutch\nC\t-\tdir\t1\nD\tnl\tltr\n'
        single = {'nl': 'Nederlands', 'xx': ''}
        old = child + m.render_profile(single)
        config = dict(wiki='nlwiktionary', date='20261001', content_language='nl', core='9' * 40)
        counts = dict(observed_codes=2, observed_positive=1, observed_empty=1, singular_codes=2, singular_positive=1, singular_empty=1)
        observation = dict(schema=m.OBSERVATION_SCHEMA, config=config, **m.producer(), **counts, retrieved_utc='2026-10-01T00:00:00+00:00')
        m.evidence.document(previous / (m.PREFIX + 'observation.json'), observation)
        m.evidence.put(previous / (m.KIND + '.tsv'), old)
        parent = dict(schema=m.SCHEMA, kind=m.KIND, header_version=1, **config, **m.producer(), previous={},
            observation=m.PREFIX + 'observation.json', old_output_sha256=m.evidence.digest(child), output_bytes=len(old),
            output_sha256=m.evidence.digest(old), singular_codes=2, singular_positive=1, singular_empty=1,
            native_resolution_proven=False, corpus_query_closure_proven=False, temporal_scope='current-api-observation', artifacts=m.inventory(previous))
        m.evidence.document(previous / (m.KIND + '.manifest.json'), parent)
        m.evidence.document(previous / m.COMPLETE, dict(schema=m.SCHEMA, manifest_sha256=m.evidence.digest(m.regular(previous / (m.KIND + '.manifest.json')))))
        return previous, child, single, old

    def test_offline_support_derivation_preserves_all_null_rows_and_old_observation_epoch(self):
        import prepare_language_names_generic as generic
        from test_prepare_language_names_generic import support_fixture
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); previous, child, single, old = self.fixture(root)
            sources = root / 'sources'; sources.mkdir(); pins, _ = support_fixture(sources, prefix='')
            before = {p.name: p.read_bytes() for p in previous.iterdir()}
            with mock.patch.object(generic, 'SUPPORT_SOURCES', pins), mock.patch.object(m, 'replay_previous', return_value=(child, dict(wiki='nlwiktionary', date='20261001', content_language='nl'))), mock.patch.object(m, 'replay_observation', return_value=(single, single)):
                self.assertEqual(m.validate_snapshot(previous / 'language-names.tsv')['core'], '9' * 40)
                result = m.derive_support(previous, sources, sources / 'namespace-registry.tsv', sources / 'namespace-siteinfo.raw.json', root / 'out')
                self.assertEqual((root / 'out/language-names.tsv').read_bytes(), old + b'S\tnl\t1\n')
                self.assertEqual(result['core'], '9' * 40)
                self.assertEqual(result['support_profile']['core'], generic.SUPPORT_CORE)
                self.assertEqual(result['source_derived_support'], {'nl': True})
                self.assertEqual({p.name: p.read_bytes() for p in previous.iterdir()}, before)
                self.assertEqual((root / 'out' / (m.PREFIX + 'observation.json')).read_bytes(), before[m.PREFIX + 'observation.json'])
                with self.assertRaises(ValueError):
                    m.derive_support(root / 'out', sources, sources / 'namespace-registry.tsv', sources / 'namespace-siteinfo.raw.json', root / 'duplicate')

    def test_resealed_output_and_prior_artifact_changes_cannot_invent_support(self):
        import prepare_language_names_generic as generic
        from test_prepare_language_names_generic import support_fixture
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); previous, child, single, old = self.fixture(root)
            sources = root / 'sources'; sources.mkdir(); pins, _ = support_fixture(sources, prefix='')
            with mock.patch.object(generic, 'SUPPORT_SOURCES', pins), mock.patch.object(m, 'replay_previous', return_value=(child, dict(wiki='nlwiktionary', date='20261001', content_language='nl'))), mock.patch.object(m, 'replay_observation', return_value=(single, single)):
                out = root / 'out'; result = m.derive_support(previous, sources, sources / 'namespace-registry.tsv', sources / 'namespace-siteinfo.raw.json', out)
                manifest_path = out / 'language-names.manifest.json'
                def reseal(value):
                    value['artifacts'] = m.inventory(out)
                    manifest_path.write_bytes(m.evidence.encoded(value))
                    (out / m.COMPLETE).write_bytes(m.evidence.encoded(dict(schema=m.SCHEMA, manifest_sha256=m.evidence.digest(manifest_path.read_bytes()))))
                for suffix, claimed in [(b'S\tnl\t0\n', {'nl': False}), (b'S\tnl\t1\n', {'nl': 1}), (b'S\tnl\t1\nS\tqqq\t1\n', {'nl': True, 'qqq': True})]:
                    raw = old + suffix; (out / 'language-names.tsv').write_bytes(raw)
                    bad = dict(result, source_derived_support=claimed, output_bytes=len(raw), output_sha256=m.evidence.digest(raw)); reseal(bad)
                    with self.assertRaises(ValueError): m.validate_snapshot(out / 'language-names.tsv')
                (out / 'language-names.tsv').write_bytes(old + b'S\tnl\t1\n')
                old_observation = out / (m.PREFIX + 'observation.json'); value = json.loads(old_observation.read_text()); value['retrieved_utc'] = '2026-11-01T00:00:00+00:00'; old_observation.write_text(json.dumps(value))
                reseal(dict(result))
                with self.assertRaises(ValueError): m.validate_snapshot(out / 'language-names.tsv')

if __name__ == '__main__':
    unittest.main()
