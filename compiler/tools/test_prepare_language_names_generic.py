"""Hermetic generic-profile tests; no network, compiler, or Lua."""
import argparse
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.parse

import prepare_language_names as legacy
import prepare_language_names_generic as names


ALIASES = {'en-simple': 'simple'}
TABLES = {
    'en': {'ca': 'Catalan', 'en': 'English', 'simple': 'Simple English',
           'en-simple': 'Simple English', 'he': 'Hebrew', 'xx': 'Unknown'},
    'ca': {'ca': 'català', 'en': 'anglès', 'simple': 'anglès simple'},
}
MW_KEYS = {'ca', 'en', 'simple', 'he'}


def response(display='ca'):
    raw = dict(TABLES['en'])
    raw.update(TABLES.get(display, {}))
    if display == 'ca':
        raw['ca'] = 'català'
    info = {k: {'code': k, 'name': raw.get(ALIASES.get(k, k), ''),
                'dir': 'rtl' if k == 'he' else 'ltr', 'fallbacks': []} for k in raw}
    return {'query': {'general': {'wikiid': 'cawiktionary', 'lang': 'ca', 'git-hash': names.CORE},
            'languageinfo': info, 'languages': [{'code': k, 'name': raw[k]} for k in sorted(MW_KEYS)]}}


def direction_fixture(root, core_tree):
    values = {
        'core-tree.json': core_tree,
        'wmf-config-tree.json': {'sha': 'cb5a4a08978a7c8a180837d8236afe616c619bf8', 'truncated': False, 'tree': []},
        'wmf-config-catalog.json': {'schema': 'wikidict.wmf-config-php-source.v1',
            'commit': 'cb5a4a08978a7c8a180837d8236afe616c619bf8', 'records': []},
    }
    pins = {}
    for name, value in values.items():
        raw = json.dumps(value).encode()
        (root/name).write_bytes(raw)
        pins[name] = names.evidence.digest(raw)
    return pins


class GenericTest(unittest.TestCase):
    def config(self):
        return {'wiki': 'cawiktionary', 'date': '20261001', 'content_language': 'ca', 'languages': ['ca', 'en'], 'core': names.CORE}

    def batches(self):
        return [(names.request_query(d, i == 0, {}), response(d)) for i, d in enumerate(('ca', 'en'))]

    def test_generic_ca_capture_implicit_english_and_unknown_code(self):
        profiles, directions = names.reconstruct(self.config(), self.batches(), ALIASES, TABLES)
        self.assertEqual(profiles['ca']['single']['en'], 'anglès')
        self.assertEqual(profiles['ca']['all']['en-simple'], 'Simple English')
        self.assertEqual(profiles['ca']['single']['en-simple'], 'anglès simple')
        self.assertEqual(profiles['ca']['all']['he'], 'Hebrew')
        self.assertNotIn('made-up', profiles['ca']['single'])
        self.assertEqual(directions['he'], 'rtl')
        self.assertNotIn(None, profiles)

    def test_real_cldr_raw_alias_differences_are_preserved(self):
        # These four distinctions occur in the pinned upstream CLDR datasets.
        for locale, alias, target, local, canonical in (
                ('eo', 'en-simple', 'simple', 'bazangla', 'Simple English'),
                ('mk', 'en-simple', 'simple', 'упростен англиски', 'Simple English'),
                ('he', 'cbk', 'cbk-zam', 'צ׳בקנית', 'צ׳בקנית זמבואנגית'),
                ('pa', 'cbk', 'cbk-zam', 'ਚਾਵਾਕਾਨੋ', 'Chavacano')):
            tables = {'en': {locale: locale, alias: canonical, target: canonical},
                      locale: {alias: local}}
            if locale == 'he':
                tables[locale][target] = canonical
            observed = {locale: locale, alias: canonical, target: canonical}
            result = names.finish_profile(observed, {locale: locale}, {alias: target},
                                          tables, locale, {locale: ()})
            self.assertEqual(result['all'][alias], local)
            self.assertEqual(result['single'][alias], canonical)

    def test_ordered_explicit_fallback_precedes_implicit_english(self):
        tables = {'en': {'ca': 'Catalan', 'fr': 'French', 'de': 'German'},
                  'fr': {'de': 'allemand'}, 'ca': {'fr': 'francès'}}
        observed = {'ca': 'català', 'fr': 'francès', 'de': 'allemand'}
        result = names.finish_profile(observed, {'ca': 'català'}, {}, tables, 'ca', {'ca': ('fr',)})
        self.assertEqual(result['all'], observed)
        with self.assertRaisesRegex(ValueError, 'derivation'):
            names.finish_profile(observed, {'ca': 'català'}, {}, tables, 'ca', {'ca': ('en', 'fr')})

    def test_catalog_absence_requires_captured_fallback_coverage(self):
        # A complete source catalog proves no locale file; this does not prove
        # its fallback chain. Both conditions are required before returning data.
        tables = {'en': {'zz': 'Zed', 'en': 'English'}}
        observed = {'zz': 'Zed', 'en': 'English'}
        result = names.finish_profile(observed, {'zz': 'Zed'}, {}, tables, 'zz', {'zz': ()})
        self.assertEqual(result['all'], observed)
        with self.assertRaisesRegex(ValueError, 'fallback coverage'):
            names.finish_profile(observed, {'zz': 'Zed'}, {}, tables, 'zz', {})

    def test_incomplete_or_excess_api_universe_and_changed_names_rejected(self):
        for mutation, pattern in (
                (lambda b: b[0][1]['query']['languageinfo'].pop('xx'), 'universe'),
                (lambda b: b[0][1]['query']['languageinfo']['xx'].update(name='fabricated'), 'derivation'),
                (lambda b: b[0][1]['query']['languageinfo']['ca'].update(fallbacks=['fr', 'fr']), 'fallback'),
                (lambda b: b[0][1]['query']['languageinfo']['ca'].pop('fallbacks'), 'fallback')):
            batches = copy.deepcopy(self.batches())
            mutation(batches)
            with self.assertRaisesRegex(ValueError, pattern):
                names.reconstruct(self.config(), batches, ALIASES, TABLES)
        tables = copy.deepcopy(TABLES)
        tables['ca']['extra'] = 'extra'
        profiles, _ = names.reconstruct(self.config(), self.batches(), ALIASES, tables)
        self.assertEqual(profiles['ca']['all']['extra'], 'extra')
        self.assertEqual(profiles['ca']['single']['extra'], 'extra')
        self.assertNotIn('extra', profiles['en']['all'])
        self.assertNotIn('extra', profiles['ca']['mw'])
        extra_api = copy.deepcopy(self.batches())
        extra_api[0][1]['query']['languageinfo']['extra'] = {
            'code': 'extra', 'name': 'extra', 'dir': 'ltr', 'fallbacks': []}
        with self.assertRaisesRegex(ValueError, 'universe'):
            names.reconstruct(self.config(), extra_api, ALIASES, tables)

    def test_disabled_pig_latin_direct_locale_and_unfiltered_fallback_differ(self):
        tables = {'en': {'en': 'English', 'ca': 'Catalan', 'en-x-piglatin': 'Pig Latin'},
                  'oc': {'en-x-piglatin': 'fallback Pig Latin'},
                  'ca': {'ca': 'català', 'en-x-piglatin': 'direct Pig Latin'}}
        observed = {'en': 'English', 'ca': 'català'}
        result = names.finish_profile(observed, {'ca': 'català'}, {}, tables,
                                      'ca', {'ca': ('oc',)})
        self.assertEqual(result['all']['en-x-piglatin'], 'fallback Pig Latin')
        self.assertEqual(result['single']['en-x-piglatin'], 'fallback Pig Latin')
        self.assertNotIn('en-x-piglatin', result['mw'])
        english = names.finish_profile({'en': 'English', 'ca': 'Catalan'},
            {'en': 'English'}, {}, tables, 'en', {'en': ()})
        self.assertNotIn('en-x-piglatin', english['all'])
        self.assertNotIn('en-x-piglatin', english['single'])

    def test_enabled_pig_latin_is_in_complete_api_universe(self):
        tables = {'en': {'en': 'English', 'ca': 'Catalan', 'en-x-piglatin': 'Pig Latin'},
                  'ca': {'ca': 'català', 'en-x-piglatin': 'direct Pig Latin'}}
        for display, observed in (
                ('en', {'en': 'English', 'ca': 'Catalan', 'en-x-piglatin': 'Pig Latin'}),
                ('ca', {'en': 'English', 'ca': 'català', 'en-x-piglatin': 'direct Pig Latin'})):
            with self.subTest(display=display):
                mw = {display: observed[display], 'en-x-piglatin': observed['en-x-piglatin']}
                result = names.finish_profile(observed, mw, {}, tables, display, {display: ()})
                self.assertEqual(result['all']['en-x-piglatin'], observed['en-x-piglatin'])
                self.assertEqual(result['single']['en-x-piglatin'], observed['en-x-piglatin'])
                incomplete = dict(observed); incomplete.pop('en-x-piglatin')
                with self.assertRaisesRegex(ValueError, 'universe'):
                    names.finish_profile(incomplete, mw, {}, tables, display, {display: ()})

    def test_disabled_pig_latin_api_presence_is_rejected(self):
        tables = {'en': {'en': 'English', 'en-x-piglatin': 'Pig Latin'}}
        with self.assertRaisesRegex(ValueError, 'universe'):
            names.finish_profile(dict(tables['en']), {'en': 'English'}, {},
                                 tables, 'en', {'en': ()})

    def test_normalized_display_uses_normalized_captured_chain(self):
        tables = {'en': {'gsw': 'Swiss', 'de': 'German'}, 'gsw': {'de': 'Düütsch'}}
        result = names.finish_profile({'gsw': 'Swiss', 'de': 'Düütsch'}, {'gsw': 'Swiss'},
                                      {'als': 'gsw'}, tables, 'als', {'gsw': ()})
        self.assertEqual(result['all']['de'], 'Düütsch')
        self.assertEqual(result['single']['als'], 'Swiss')

    def test_continuation_order_duplicate_and_fallback_completeness(self):
        first, last = response(), response()
        keys = sorted(first['query']['languageinfo'])
        first['query']['languageinfo'] = {k: first['query']['languageinfo'][k] for k in keys[:3]}
        last['query']['languageinfo'] = {k: last['query']['languageinfo'][k] for k in keys[3:]}
        first['continue'] = {'continue': '-||', 'licontinue': keys[3]}
        batches = [(names.request_query('ca', True, {}), first),
                   (names.request_query('ca', True, first['continue']), last), self.batches()[1]]
        self.assertEqual(names.reconstruct(self.config(), batches, ALIASES, TABLES),
                         names.reconstruct(self.config(), self.batches(), ALIASES, TABLES))
        with self.assertRaisesRegex(ValueError, 'Incomplete'):
            names.reconstruct(self.config(), batches[:1], ALIASES, TABLES)
        with self.assertRaisesRegex(ValueError, 'Reordered'):
            names.reconstruct(self.config(), list(reversed(batches)), ALIASES, TABLES)
        last['query']['languageinfo'].update(first['query']['languageinfo'])
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            names.reconstruct(self.config(), batches, ALIASES, TABLES)

    def test_full_offline_capture_verify_and_tamper_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            namespace = root / 'namespace-registry.tsv'
            namespace.write_text('# wikidict-namespace-registry-v1\n# wiki\tcawiktionary\n'
                                 '# dump-date\t20261001\n# content-language\tca\n')
            args = argparse.Namespace(wiki='cawiktionary', date='20261001', namespace_registry=namespace,
                primary_sources=root, output=root/'capture', languages=['ca', 'en'], delay=0, wall_seconds=60)
            calls = []
            def transport(url, timeout):
                query = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
                calls.append(query)
                return 200, {}, json.dumps(response(query['uselang'][0]), ensure_ascii=False).encode()
            with patch.object(names, 'primary_contract', return_value=({'fixture': b'source'}, ALIASES, TABLES)):
                manifest = names.capture(args, transport=transport, sleep=lambda _: None)
                self.assertEqual(manifest['schema'], names.SCHEMA)
                self.assertEqual(len(calls), 2)
                self.assertEqual(names.verify(args.output), manifest)
                self.assertEqual(names.capture_artifacts(args.output/'language-names.tsv', manifest),
                                 names.capture_artifacts(args.output/'language-names.tsv'))
                original = {p.name: p.read_bytes() for p in args.output.iterdir()}
                def restore():
                    for name, raw in original.items():
                        (args.output/name).write_bytes(raw)
                def reseal(value):
                    value['artifacts'] = names.payload(args.output)
                    path = args.output/'language-names.manifest.json'
                    path.write_bytes(names.evidence.encoded(value))
                    (args.output/names.COMPLETE).write_bytes(names.evidence.encoded({
                        'schema': names.SCHEMA, 'manifest_sha256': names.evidence.digest(path.read_bytes())}))
                historical = copy.deepcopy(manifest)
                historical['generator_sha256'] = 'a'*64
                historical['dependency_sha256'] = {name: 'b'*64 for name in manifest['dependency_sha256']}
                reseal(historical)
                self.assertEqual(names.verify(args.output), historical)
                self.assertEqual((args.output/'language-names.tsv').read_bytes(), original['language-names.tsv'])
                self.assertEqual(historical.get('retrieved_utc'), manifest.get('retrieved_utc'))
                for mutation in ('generator', 'roles', 'dependency', 'raw', 'receipt', 'query', 'reconstructed', 'tsv'):
                    restore(); changed = copy.deepcopy(historical)
                    record = changed['requests'][0]
                    receipt_path = args.output/record['accepted_receipt']
                    receipt = json.loads(receipt_path.read_bytes())
                    with self.subTest(mutation=mutation):
                        if mutation == 'generator':
                            changed['generator_sha256'] = 'A'*64
                        elif mutation == 'roles':
                            changed['dependency_sha256']['extra.py'] = 'c'*64
                        elif mutation == 'dependency':
                            changed['dependency_sha256']['download_wiktionaries.py'] = None
                        elif mutation == 'receipt':
                            receipt['accepted'] = False
                            receipt_path.write_bytes(names.evidence.encoded(receipt))
                        elif mutation == 'query':
                            path = args.output/record['request']; request = json.loads(path.read_bytes())
                            request['query']['uselang'] = 'de'
                            request['url'] = names.evidence.wiktionary_api(args.wiki) + '?' + urllib.parse.urlencode(sorted(request['query'].items()))
                            path.write_bytes(names.evidence.encoded(request))
                        elif mutation in ('raw', 'reconstructed'):
                            path = args.output/receipt['response']; raw = path.read_bytes()
                            if mutation == 'raw':
                                path.write_bytes(raw+b' ')
                            else:
                                value = json.loads(raw)
                                value['query']['languageinfo']['en']['name'] = 'altered'
                                raw = names.evidence.encoded(value); path.write_bytes(raw)
                                receipt['response_bytes'] = len(raw); receipt['response_sha256'] = names.evidence.digest(raw)
                                receipt_path.write_bytes(names.evidence.encoded(receipt))
                        else:
                            path = args.output/'language-names.tsv'; raw = path.read_bytes()+b'bad\n'; path.write_bytes(raw)
                            changed['output_bytes'] = len(raw); changed['output_sha256'] = names.evidence.digest(raw)
                        reseal(changed)
                        with self.assertRaises(ValueError):
                            names.verify(args.output)
                restore()
                (args.output/'language-names.source-fixture').write_bytes(b'tampered')
                with self.assertRaisesRegex(ValueError, 'inventory'):
                    names.verify(args.output)

    def test_catalog_skips_invalid_locale_without_normalizing_valid_lzz(self):
        catalog = {'schema': 'wikidict.cldr-language-names-source.v1',
                   'commit': 'bd57961ea538f51f992d911705bdd2b8ff666fe9',
                   'tables': {'en': {'en': 'English', 'lzz': 'Laz'},
                              'lzz': {'en': 'İngilizuri', 'lzz': 'Lazuri'},
                              # This filename is rejected before its rows are read.
                              'lzz.': {'lzz': None}}}
        raw = json.dumps(catalog, ensure_ascii=False, sort_keys=True).encode()
        names.source_catalog.cache_clear()
        self.addCleanup(names.source_catalog.cache_clear)
        tables = names.source_catalog(raw)
        self.assertEqual(set(tables), {'en', 'lzz'})
        self.assertEqual(tables['en']['lzz'], 'Laz')
        self.assertEqual(tables['lzz'], {'en': 'İngilizuri', 'lzz': 'Lazuri'})
        self.assertEqual(json.loads(raw)['tables']['lzz.'], {'lzz': None})
        self.assertEqual(names.source_catalog(raw), tables)
        invalid_valid_locale = copy.deepcopy(catalog)
        invalid_valid_locale['tables']['lzz']['lzz'] = None
        with self.assertRaisesRegex(ValueError, 'language-name row'):
            names.source_catalog(json.dumps(invalid_valid_locale).encode())

    def test_pinned_source_identity_checked_before_catalog_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'fixture').write_bytes(b'wrong')
            with patch.object(names, 'SOURCE_PINS', {'fixture': '0'*64}):
                with self.assertRaisesRegex(ValueError, 'Unreviewed primary'):
                    names.primary_contract(root)
        self.assertEqual(legacy.SCHEMA, 'wikidict.language-names-capture.v1')
        self.assertNotEqual(names.SCHEMA, legacy.SCHEMA)

    def test_builder_dispatch_is_schema_specific(self):
        import build_wiktionaries as builder
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'language-names.tsv'
            manifest = path.with_suffix('.manifest.json')
            for schema, expected in ((legacy.SCHEMA, legacy), (names.SCHEMA, names),
                                     ('unreviewed-future-schema', legacy)):
                manifest.write_text(json.dumps({'schema': schema}))
                self.assertIs(builder.auxiliary_capture_helper('language-names', path), expected)

    def test_extra_direction_request_and_conflicts_are_explicit(self):
        self.assertEqual(names.extra_direction_contract(None, [], {}), ({}, {}))
        self.assertEqual(names.merge_extra_directions({'ar': 'rtl'}, {}), {'ar': 'rtl'})
        for values in (['unknown'], ['rmq-x-other'], ['rmq', 'rmq'], ['roa-oca', 'rmq'], None):
            with self.subTest(values=values), self.assertRaises(ValueError):
                names.extra_direction_codes(values)
        with self.assertRaisesRegex(ValueError, 'primary'):
            names.extra_direction_contract(None, ['rmq'], {})
        with self.assertRaisesRegex(ValueError, 'conflicts'):
            names.merge_extra_directions({'en': 'rtl'}, {'rmq': 'ltr'})
        with self.assertRaisesRegex(ValueError, 'overlaps'):
            names.merge_extra_directions({'en': 'ltr', 'rmq': 'ltr'}, {'rmq': 'ltr'})

    def test_direction_config_requires_complete_canonical_request(self):
        self.assertEqual(names.direction_config({}), [])
        self.assertEqual(names.direction_config({'extra_direction_codes': ['rmq'],
                                                'direction_profile': names.DIRECTION_PROFILE}), ['rmq'])
        for config in ({'extra_direction_codes': ['rmq']},
                       {'direction_profile': names.DIRECTION_PROFILE},
                       {'extra_direction_codes': [], 'direction_profile': names.DIRECTION_PROFILE},
                       {'extra_direction_codes': ['rmq'], 'direction_profile': 'unreviewed'}):
            with self.subTest(config=config), self.assertRaises(ValueError):
                names.direction_config(config)

    def test_direction_source_tree_and_alias_absence_required(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for mutation in ('complete', 'truncated', 'support', 'alias'):
                tree = {'sha': names.CORE, 'truncated': mutation == 'truncated', 'tree': []}
                if mutation == 'support':
                    tree['tree'] = [{'path': 'languages/messages/MessagesRmq.php'}]
                raw = json.dumps(tree).encode()
                pins = direction_fixture(root, tree)
                with patch.object(names, 'DIRECTION_SOURCE_PINS', pins):
                    if mutation == 'complete':
                        sources, derived = names.extra_direction_contract(root, ['rmq'], {})
                        self.assertEqual(derived, {'rmq': 'ltr'})
                        self.assertEqual(sources['core-tree.json'], raw)
                        self.assertEqual(len(sources), 3)
                    else:
                        with self.assertRaises(ValueError):
                            names.extra_direction_contract(root, ['rmq'], {'rmq': 'ar'} if mutation == 'alias' else {})

    def test_full_capture_replays_extra_direction_proof_and_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            namespace = root/'namespace-registry.tsv'
            namespace.write_text('# wikidict-namespace-registry-v1\n# wiki\tcawiktionary\n'
                                 '# dump-date\t20261001\n# content-language\tca\n')
            proof = root/'proof'; proof.mkdir()
            raw = json.dumps({'sha': names.CORE, 'truncated': False, 'tree': []}).encode()
            pins = direction_fixture(proof, {'sha': names.CORE, 'truncated': False, 'tree': []})
            args = argparse.Namespace(wiki='cawiktionary', date='20261001', namespace_registry=namespace,
                primary_sources=root, output=root/'capture', languages=['ca', 'en'], delay=0, wall_seconds=60,
                extra_direction_codes=['roa-oca', 'rmq'], direction_primary_sources=proof)
            def transport(url, timeout):
                query = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
                return 200, {}, json.dumps(response(query['uselang'][0]), ensure_ascii=False).encode()
            with patch.object(names, 'primary_contract', return_value=({'fixture': b'source'}, ALIASES, TABLES)), \
                    patch.object(names, 'DIRECTION_SOURCE_PINS', pins):
                manifest = names.capture(args, transport=transport, sleep=lambda _: None)
                self.assertEqual(manifest['source_derived_directions'], {'rmq': 'ltr', 'roa-oca': 'ltr'})
                self.assertEqual(manifest['direction_provenance'], 'current-api-plus-pinned-core')
                self.assertEqual(manifest['extra_direction_codes'], ['rmq', 'roa-oca'])
                self.assertIn('language-names.direction-source-core-tree.json', manifest['artifacts'])
                self.assertEqual(names.verify(args.output), manifest)
                self.assertIn(b'D\trmq\tltr\n', (args.output/'language-names.tsv').read_bytes())
                def rewrite(path, value):
                    path.write_bytes(names.evidence.encoded(value))
                original = {p.name: p.read_bytes() for p in args.output.iterdir()}
                def restore():
                    for name, value in original.items():
                        (args.output/name).write_bytes(value)
                def reseal():
                    current = names.evidence.decode((args.output/'language-names.manifest.json').read_bytes())
                    current['artifacts'] = names.payload(args.output)
                    rewrite(args.output/'language-names.manifest.json', current)
                    rewrite(args.output/names.COMPLETE,
                        {'schema': names.SCHEMA, 'manifest_sha256': names.evidence.digest(
                            (args.output/'language-names.manifest.json').read_bytes())})
                for tamper in ('proof', 'config', 'manifest', 'tsv'):
                    restore()
                    if tamper == 'proof':
                        (args.output/'language-names.direction-source-core-tree.json').write_bytes(b'{}')
                    elif tamper == 'config':
                        config = names.evidence.decode((args.output/'language-names.requested.json').read_bytes())
                        config.pop('extra_direction_codes')
                        rewrite(args.output/'language-names.requested.json', config)
                    elif tamper == 'manifest':
                        bad = dict(manifest); bad['source_derived_directions'] = {'rmq': 'rtl'}
                        rewrite(args.output/'language-names.manifest.json', bad)
                    else:
                        path = args.output/'language-names.tsv'
                        path.write_bytes(path.read_bytes().replace(b'D\trmq\tltr\n', b'D\trmq\trtl\n'))
                    reseal()
                    with self.subTest(tamper=tamper), self.assertRaises(ValueError):
                        names.verify(args.output)

    def test_public_configuration_override_and_missing_record_rejected(self):
        import hashlib
        for source, missing in (('<?php $wgDummyLanguageCodes = [];', False),
                                ('<?php $unrelated = true;', True)):
            raw = source.encode()
            blob = hashlib.sha1(b'blob ' + str(len(raw)).encode() + b'\0' + raw).hexdigest()
            tree = {'sha': 'cb5a4a08978a7c8a180837d8236afe616c619bf8', 'truncated': False,
                    'tree': [{'path': 'wmf-config/InitialiseSettings.php', 'type': 'blob', 'sha': blob}]}
            row = {'path': 'wmf-config/InitialiseSettings.php', 'source': source, 'bytes': len(raw),
                   'sha256': names.evidence.digest(raw), 'blob_sha1': blob}
            catalog = {'schema': 'wikidict.wmf-config-php-source.v1',
                       'commit': tree['sha'], 'records': [] if missing else [row]}
            with self.subTest(missing=missing), self.assertRaisesRegex(ValueError, 'inventory' if missing else 'override'):
                names.public_direction_config({'wmf-config-tree.json': json.dumps(tree).encode(),
                                               'wmf-config-catalog.json': json.dumps(catalog).encode()})

    def test_reviewed_core_selection_is_exact_and_finite(self):
        new_core = '79b81ba96674efc8a803fc956bc501d347d440d2'
        for core in (names.CORE, new_core):
            current = response()
            current['query']['general']['git-hash'] = core
            self.assertEqual(names.parse_response(current, 'cawiktionary', 'ca', True, core)[0]['ca'], 'català')
            other = new_core if core == names.CORE else names.CORE
            with self.assertRaisesRegex(ValueError, 'source contract mismatch'):
                names.parse_response(current, 'cawiktionary', 'ca', True, other)
        for unknown in ('f'*40, new_core.upper(), '', None, [new_core]):
            with self.subTest(core=unknown), self.assertRaisesRegex(ValueError, 'Unreviewed core'):
                names.core_revision(unknown)

    def test_new_core_profiles_reject_mixed_revision_batches(self):
        new_core = '79b81ba96674efc8a803fc956bc501d347d440d2'
        config = self.config(); config['core'] = new_core
        batches = self.batches()
        for _, data in batches:
            data['query']['general']['git-hash'] = new_core
        self.assertEqual(names.reconstruct(config, batches, ALIASES, TABLES),
                         names.reconstruct(self.config(), self.batches(), ALIASES, TABLES))
        batches[1][1]['query']['general']['git-hash'] = names.CORE
        with self.assertRaisesRegex(ValueError, 'source contract mismatch'):
            names.reconstruct(config, batches, ALIASES, TABLES)

    def test_new_core_continuation_cannot_change_revision(self):
        new_core = '79b81ba96674efc8a803fc956bc501d347d440d2'
        first, last = response(), response()
        keys = sorted(first['query']['languageinfo'])
        first['query']['general']['git-hash'] = new_core
        first['query']['languageinfo'] = {k:first['query']['languageinfo'][k] for k in keys[:3]}
        first['continue'] = {'continue':'-||','licontinue':keys[3]}
        last['query']['languageinfo'] = {k:last['query']['languageinfo'][k] for k in keys[3:]}
        config = self.config();config['core'] = new_core
        batches = [(names.request_query('ca', True, {}), first),
                   (names.request_query('ca', True, first['continue']), last)]
        with self.assertRaisesRegex(ValueError, 'source contract mismatch'):
            names.reconstruct(config, batches, ALIASES, TABLES)

    def test_new_core_full_capture_and_replay_bind_actual_revision(self):
        new_core = '79b81ba96674efc8a803fc956bc501d347d440d2'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); namespace=root/'namespace-registry.tsv'
            namespace.write_text('# wikidict-namespace-registry-v1\n# wiki\tcawiktionary\n'
                                 '# dump-date\t20261001\n# content-language\tca\n')
            args=argparse.Namespace(wiki='cawiktionary',date='20261001',namespace_registry=namespace,
                primary_sources=root,output=root/'capture',languages=['ca','en'],delay=0,wall_seconds=60,core=new_core)
            def transport(url,timeout):
                display=urllib.parse.parse_qs(urllib.parse.urlparse(url).query)['uselang'][0]
                value=response(display);value['query']['general']['git-hash']=new_core
                return 200,{},json.dumps(value,ensure_ascii=False).encode()
            with patch.object(names,'primary_contract',return_value=({'fixture':b'source'},ALIASES,TABLES)):
                manifest=names.capture(args,transport=transport,sleep=lambda _:None)
                self.assertEqual(manifest['core'],new_core)
                self.assertEqual(names.verify(args.output),manifest)
                # Resealing outer manifests cannot relabel a capture of one core
                # as the other reviewed core: actual raw responses still decide.
                config=names.evidence.decode((args.output/'language-names.requested.json').read_bytes())
                config['core']=names.CORE
                (args.output/'language-names.requested.json').write_bytes(names.evidence.encoded(config))
                manifest['core']=names.CORE;manifest['artifacts']=names.payload(args.output)
                (args.output/'language-names.manifest.json').write_bytes(names.evidence.encoded(manifest))
                (args.output/names.COMPLETE).write_bytes(names.evidence.encoded({'schema':names.SCHEMA,
                    'manifest_sha256':names.evidence.digest((args.output/'language-names.manifest.json').read_bytes())}))
                with self.assertRaisesRegex(ValueError,'source contract mismatch'):
                    names.verify(args.output)

    def test_live_capture_core_change_retains_failed_response_without_completion(self):
        new_core = '79b81ba96674efc8a803fc956bc501d347d440d2'
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);namespace=root/'namespace-registry.tsv'
            namespace.write_text('# wikidict-namespace-registry-v1\n# wiki\tcawiktionary\n'
                                 '# dump-date\t20261001\n# content-language\tca\n')
            args=argparse.Namespace(wiki='cawiktionary',date='20261001',namespace_registry=namespace,
                primary_sources=root,output=root/'capture',languages=['ca','en'],delay=0,wall_seconds=60,core=new_core)
            def transport(url,timeout):
                display=urllib.parse.parse_qs(urllib.parse.urlparse(url).query)['uselang'][0]
                value=response(display)
                value['query']['general']['git-hash']=new_core if display=='ca' else names.CORE
                return 200,{},json.dumps(value).encode()
            with patch.object(names,'primary_contract',return_value=({'fixture':b'source'},ALIASES,TABLES)):
                with self.assertRaisesRegex(ValueError,'source contract mismatch'):
                    names.capture(args,transport=transport,sleep=lambda _:None)
            self.assertFalse((args.output/names.COMPLETE).exists())
            self.assertTrue((args.output/'language-names.0002-01.raw.json').is_file())
            receipt=json.loads((args.output/'language-names.0002-01.receipt.json').read_text())
            self.assertIs(receipt['accepted'],False)
            self.assertTrue((args.output/'language-names.failure.json').is_file())

    def test_new_core_direction_proof_uses_exact_revision_and_tree(self):
        new_core = '79b81ba96674efc8a803fc956bc501d347d440d2'
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            tree={'sha':new_core,'truncated':False,'tree':[]}
            pins=direction_fixture(root,tree)
            with patch.object(names,'DIRECTION_SOURCE_PINS',pins), \
                    patch.dict(names.CORE_TREE_SHA256,{new_core:pins['core-tree.json']}):
                self.assertEqual(names.extra_direction_contract(root,['rmq','roa-oca'],{},core=new_core)[1],
                                 {'rmq':'ltr','roa-oca':'ltr'})
                with self.assertRaisesRegex(ValueError,'Incomplete pinned core tree'):
                    names.extra_direction_contract(root,['rmq'],{},core=names.CORE)
                (root/'core-tree.json').write_text(json.dumps({'sha':names.CORE,'truncated':False,'tree':[]}))
                with self.assertRaisesRegex(ValueError,'Unreviewed direction primary'):
                    names.extra_direction_contract(root,['rmq'],{},core=new_core)





class CurrentCoreSourceTests(unittest.TestCase):
    def fixture(self, root):
        sources = {name: ('synthetic source ' + name).encode() for name in names.SOURCE_PINS}
        sources['LanguageCode.php'] = ("private const DEPRECATED_LANGUAGE_CODE_MAPPING = [\n\t];\n"
            "private const NON_STANDARD_LANGUAGE_CODE_MAPPING = [\n\t'simple' => 'en-simple',\n\t];\n").encode()
        historical = {name: names.evidence.digest(raw) for name, raw in sources.items()}
        current = {name: raw + b' current' for name, raw in sources.items()
                   if name in names.CURRENT_CORE_OVERRIDES}
        overrides = {name: names.evidence.digest(raw) for name, raw in current.items()}
        for name, raw in {**sources, **current}.items():
            (root / name).write_bytes(raw)
        rows = []
        for name, path in names.CORE_SOURCE_PATHS.items():
            raw = (root / name).read_bytes()
            rows.append(dict(file=name, source_path=path, status=200, bytes=len(raw),
                sha256=names.evidence.digest(raw),
                url=f'https://raw.githubusercontent.com/wikimedia/mediawiki/{names.CURRENT_CORE}/{path}'))
        receipt = dict(core=names.CURRENT_CORE, sources=rows)
        (root / names.CORE_RECEIPTS).write_text(json.dumps(receipt))
        return sources, historical, overrides, receipt

    def test_current_sources_are_distinct_and_historical_profile_is_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources, historical, overrides, receipt = self.fixture(root)
            with patch.dict(names.SOURCE_PINS, historical, clear=True), \
                    patch.dict(names.CURRENT_CORE_OVERRIDES, overrides, clear=True), \
                    patch.object(names, 'source_catalog', return_value=TABLES):
                observed, _, _ = names.primary_contract(root, core=names.CURRENT_CORE)
                self.assertIn(names.CORE_RECEIPTS, observed)
                with self.assertRaisesRegex(ValueError, 'Unreviewed primary source'):
                    names.primary_contract(root)
                for name, raw in sources.items():
                    (root / name).write_bytes(raw)
                self.assertEqual(names.primary_contract(root)[0], sources)
                with self.assertRaisesRegex(ValueError, 'Unreviewed primary source'):
                    names.primary_contract(root, core=names.CURRENT_CORE)

    def test_current_receipts_reject_rebound_roles_urls_core_and_bodies(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, historical, overrides, receipt = self.fixture(root)
            with patch.dict(names.SOURCE_PINS, historical, clear=True), \
                    patch.dict(names.CURRENT_CORE_OVERRIDES, overrides, clear=True), \
                    patch.object(names, 'source_catalog', return_value=TABLES):
                for field, value in (('file', 'other.php'), ('source_path', 'other.php'),
                        ('status', 404), ('bytes', 1), ('sha256', 'f'*64),
                        ('url', 'https://raw.githubusercontent.com/wikimedia/mediawiki/master/other.php')):
                    bad = copy.deepcopy(receipt); bad['sources'][0][field] = value
                    (root / names.CORE_RECEIPTS).write_text(json.dumps(bad))
                    with self.subTest(field=field), self.assertRaises(ValueError):
                        names.primary_contract(root, core=names.CURRENT_CORE)
                for bad in (dict(receipt, core=names.CORE), dict(receipt, sources=receipt['sources'][:-1]),
                            dict(receipt, sources=[receipt['sources'][0]]*len(receipt['sources'])), []):
                    (root / names.CORE_RECEIPTS).write_text(json.dumps(bad))
                    with self.assertRaises(ValueError):
                        names.primary_contract(root, core=names.CURRENT_CORE)

    def test_current_revision_does_not_accept_another_response_or_direction_tree(self):
        data = response(); data['query']['general']['git-hash'] = names.CURRENT_CORE
        self.assertEqual(names.parse_response(data, 'cawiktionary', 'ca', True, names.CURRENT_CORE)[0]['ca'], 'català')
        with self.assertRaisesRegex(ValueError, 'source contract mismatch'):
            names.parse_response(data, 'cawiktionary', 'ca', True, names.CORE)
        with self.assertRaisesRegex(ValueError, 'reviewed tree'):
            names.extra_direction_contract(None, ['rmq'], {}, core=names.CURRENT_CORE)
        self.assertEqual(names.extra_direction_contract(None, [], {}, core=names.CURRENT_CORE), ({}, {}))

    def test_current_core_does_not_waive_source_catalog_inventory(self):
        data = response(); data['query']['general']['git-hash'] = names.CURRENT_CORE
        data['query']['languageinfo']['bjj'] = dict(code='bjj', name='Kannauji', dir='ltr', fallbacks=[])
        config = dict(wiki='cawiktionary', content_language='ca', languages=['ca'], core=names.CURRENT_CORE)
        with self.assertRaisesRegex(ValueError, 'source key universe'):
            names.reconstruct(config, [(names.request_query('ca', True, {}), data)], ALIASES, TABLES)


class ItalianSourceProfileTests(unittest.TestCase):
    """Synthetic source contract; real retained-data replay is qualified separately."""
    def setUp(self):
        import hashlib
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.historical_sources, historical, overrides, _ = CurrentCoreSourceTests().fixture(self.root)
        tables = {
            'en': {'en': 'English', 'it': 'Italian', 'xx': 'Unknown', 'en-x-piglatin': 'Pig Latin'},
            'it': {'en': 'inglese', 'it': 'italiano', 'zz': '0', 'yy': '-', 'aa': ''},
        }
        for locale, table in tables.items():
            raw = names.evidence.encoded({'@metadata': {'authors': ['synthetic']},
                                         **{'cldr-language-name-' + k: v for k, v in table.items()}})
            (self.root / ('cldr-' + locale + '.json')).write_bytes(raw)
        blobs = []
        for name, path in names.ITALIAN_SOURCE_PATHS.items():
            raw = (self.root / name).read_bytes()
            blobs.append(dict(path=path, type='blob', size=len(raw),
                              sha=hashlib.sha1(b'blob ' + str(len(raw)).encode() + b'\0' + raw).hexdigest()))
        (self.root / 'cldr-tree.json').write_bytes(names.evidence.encoded(
            dict(sha=names.ITALIAN_CLDR_COMMIT, truncated=False, tree=blobs)))
        pins = {name: names.evidence.digest((self.root / name).read_bytes()) for name in names.ITALIAN_SOURCE_PINS}
        rows = []
        for name, path in {**names.ITALIAN_SOURCE_PATHS, 'cldr-tree.json': None}.items():
            raw = (self.root / name).read_bytes()
            url = (f'https://raw.githubusercontent.com/wikimedia/mediawiki-extensions-cldr/{names.ITALIAN_CLDR_COMMIT}/{path}'
                   if path else f'https://api.github.com/repos/wikimedia/mediawiki-extensions-cldr/git/trees/{names.ITALIAN_CLDR_COMMIT}?recursive=1')
            rows.append(dict(file=name, source_path=path, status=200, bytes=len(raw),
                             sha256=names.evidence.digest(raw), url=url))
        (self.root / names.CLDR_RECEIPTS).write_bytes(names.evidence.encoded(
            dict(commit=names.ITALIAN_CLDR_COMMIT, sources=rows)))
        for target, value in ((names.SOURCE_PINS, historical),
                              (names.CURRENT_CORE_OVERRIDES, overrides),
                              (names.ITALIAN_SOURCE_PINS, pins)):
            context = patch.dict(target, value, clear=True)
            context.start(); self.addCleanup(context.stop)

    def source_root(self):
        return self.root

    def observation(self):
        rows = {'en': 'inglese', 'it': 'italiano', 'xx': 'Unknown'}
        data = dict(query=dict(general={'wikiid': 'itwiktionary', 'lang': 'it', 'git-hash': names.CURRENT_CORE},
            languageinfo={k: dict(code=k, name=v, dir='ltr', fallbacks=[]) for k, v in rows.items()},
            languages=[dict(code=k, name=rows[k]) for k in ('en', 'it')]))
        config = dict(wiki='itwiktionary', content_language='it', languages=['it'], core=names.CURRENT_CORE)
        return names.select_name_source(config, names.ITALIAN_SOURCE_PROFILE), data

    def test_explicit_current_tables_leave_legacy_source_contract_unchanged(self):
        before = dict(names.SOURCE_PINS)
        sources, _, tables = names.primary_contract(self.source_root(), core=names.CURRENT_CORE,
                                                    name_source_profile=names.ITALIAN_SOURCE_PROFILE)
        self.assertEqual(set(tables), {'en', 'it'})
        self.assertEqual((len(tables['en']), len(tables['it'])), (4, 2))
        self.assertEqual(tables['it']['it'], 'italiano')
        self.assertIn(names.CLDR_RECEIPTS, sources)
        for name, raw in self.historical_sources.items():
            (self.root / name).write_bytes(raw)
        with patch.object(names, 'source_catalog', return_value=TABLES):
            _, _, old = names.primary_contract(self.root, core='79b81ba96674efc8a803fc956bc501d347d440d2')
        self.assertEqual(old, TABLES)
        self.assertEqual(names.SOURCE_PINS, before)

    def test_italian_response_reconstructs_from_complete_synthetic_tables(self):
        config, data = self.observation()
        _, aliases, tables = names.primary_contract(self.source_root(), core=names.CURRENT_CORE,
                                                    name_source_profile=names.ITALIAN_SOURCE_PROFILE)
        profiles, directions = names.reconstruct(config, [(names.request_query('it', True, {}), data)], aliases, tables)
        self.assertEqual(profiles['it']['single']['it'], 'italiano')
        self.assertEqual(profiles['it']['single']['en'], 'inglese')
        self.assertEqual(profiles['it']['single']['xx'], 'Unknown')
        self.assertEqual(directions['it'], 'ltr')
        changed = copy.deepcopy(data)
        changed['query']['languageinfo']['it']['name'] = 'invented label'
        with self.assertRaisesRegex(ValueError, 'API name differs'):
            names.reconstruct(config, [(names.request_query('it', True, {}), changed)], aliases, tables)

    def test_profile_context_and_uncaptured_fallback_refuse(self):
        config, data = self.observation()
        for field, value in (('core', names.CORE), ('languages', ['en', 'it']),
                             ('name_source_profile', 'other'), ('name_source_profile_scope', 'deployed')):
            changed = {**config, field: value}
            with self.assertRaisesRegex(ValueError, 'source profile'):
                names.name_source_config(changed)
        changed = dict(config); del changed['name_source_profile_scope']
        with self.assertRaisesRegex(ValueError, 'source profile'):
            names.name_source_config(changed)
        _, aliases, tables = names.primary_contract(self.source_root(), core=names.CURRENT_CORE,
                                                    name_source_profile=names.ITALIAN_SOURCE_PROFILE)
        data['query']['languageinfo']['it']['fallbacks'] = ['fr']
        with self.assertRaisesRegex(ValueError, 'fallback locale'):
            names.reconstruct(config, [(names.request_query('it', True, {}), data)], aliases, tables)

    def test_source_receipt_rebinding_and_changed_table_refuse(self):
        import shutil
        for field, value in (('status', 404), ('url', 'https://example.invalid/it.json'),
                             ('source_path', 'i18n/LanguageNames/fr.json'), ('sha256', '0' * 64)):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / 'sources'; shutil.copytree(self.source_root(), root)
                path = root / names.CLDR_RECEIPTS; record = json.loads(path.read_text())
                next(row for row in record['sources'] if row['file'] == 'cldr-it.json')[field] = value
                path.write_text(json.dumps(record))
                with self.assertRaisesRegex(ValueError, 'CLDR source receipt differs'):
                    names.primary_contract(root, core=names.CURRENT_CORE, name_source_profile=names.ITALIAN_SOURCE_PROFILE)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'sources'; shutil.copytree(self.source_root(), root)
            (root / 'cldr-it.json').write_text('{}')
            with self.assertRaisesRegex(ValueError, 'Unreviewed primary source'):
                names.primary_contract(root, core=names.CURRENT_CORE, name_source_profile=names.ITALIAN_SOURCE_PROFILE)


class EnglishSourceProfileTests(unittest.TestCase):
    """Original immutable PHP/CLDR sources, with independent receipt crossings."""
    def source_root(self):
        return Path(__file__).with_name('testdata') / 'en-september-language-names' / 'sources'

    def config(self):
        return names.select_name_source(dict(wiki='enwiktionary', content_language='en',
            languages=['en'], core=names.ENGLISH_CORE), names.ENGLISH_SOURCE_PROFILE)

    def test_original_source_tuple_has_complete_english_names(self):
        sources, aliases, tables = names.primary_contract(self.source_root(), core=names.ENGLISH_CORE,
                                                        name_source_profile=names.ENGLISH_SOURCE_PROFILE)
        self.assertEqual(len(sources), 15)
        self.assertEqual(set(tables), {'en'})
        self.assertEqual(len(tables['en']), 1504)
        self.assertEqual(tables['en']['en'], 'English')
        self.assertEqual(aliases['als'], 'gsw')

    def test_unreviewed_core_display_and_source_scope_are_rejected(self):
        config = self.config()
        for field, value in (('core', names.CURRENT_CORE), ('languages', ['it']),
                             ('languages', ['en', 'it']), ('name_source_profile', names.ITALIAN_SOURCE_PROFILE),
                             ('name_source_profile_scope', 'deployment-observation')):
            with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, 'source profile'):
                names.name_source_config({**config, field: value})
        for field in ('name_source_profile', 'name_source_profile_scope'):
            changed = dict(config); del changed[field]
            with self.subTest(missing=field), self.assertRaisesRegex(ValueError, 'source profile'):
                names.name_source_config(changed)
        with self.assertRaisesRegex(ValueError, 'source profile'):
            names.name_source_config({'core': names.ENGLISH_CORE})
        with self.assertRaisesRegex(ValueError, 'source profile'):
            names.primary_contract(self.source_root(), core=names.ENGLISH_CORE)
        with self.assertRaisesRegex(ValueError, 'reviewed tree'):
            names.extra_direction_contract(None, ['rmq'], {}, core=names.ENGLISH_CORE)

    def test_original_receipts_cannot_be_rebound_to_other_sources(self):
        import shutil
        for receipt_name, role, field, value, pattern in (
            (names.CORE_RECEIPTS, 'LocalisationCache.php', 'url',
             f'https://raw.githubusercontent.com/wikimedia/mediawiki/{names.CURRENT_CORE}/includes/Language/LocalisationCache.php', 'core source receipt'),
            (names.CORE_RECEIPTS, 'LanguageNameUtils.php', 'status', 404, 'core source receipt'),
            (names.CLDR_RECEIPTS, 'cldr-en.json', 'source_path', 'i18n/LanguageNames/it.json', 'CLDR source receipt'),
            (names.CLDR_RECEIPTS, 'cldr-tree.json', 'sha256', '0' * 64, 'CLDR source receipt'),
        ):
            with self.subTest(role=role, field=field), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / 'sources'; shutil.copytree(self.source_root(), root)
                path = root / receipt_name; record = json.loads(path.read_text())
                next(row for row in record['sources'] if row['file'] == role)[field] = value
                path.write_text(json.dumps(record))
                with self.assertRaisesRegex(ValueError, pattern):
                    names.primary_contract(root, core=names.ENGLISH_CORE, name_source_profile=names.ENGLISH_SOURCE_PROFILE)
        for role in ('LanguageLibrary.php', 'LocalisationCache.php', 'cldr-en.json', 'cldr-LanguageNames.php'):
            with self.subTest(changed=role), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / 'sources'; shutil.copytree(self.source_root(), root)
                with (root / role).open('ab') as stream:
                    stream.write(b'\nchanged\n')
                with self.assertRaisesRegex(ValueError, 'Unreviewed primary source'):
                    names.primary_contract(root, core=names.ENGLISH_CORE, name_source_profile=names.ENGLISH_SOURCE_PROFILE)


class ObservationReplayTests(unittest.TestCase):
    fixture = CurrentCoreSourceTests.fixture
    def observation_fixture(self, root):
        sources, historical, overrides, _ = self.fixture(root)
        origin = root / 'observation'; origin.mkdir()
        namespace = ('# wikidict-namespace-registry-v1\n# wiki\tcawiktionary\n'
                     '# dump-date\t20261001\n# content-language\tca\n').encode()
        config = dict(wiki='cawiktionary', date='20261001', content_language='ca', languages=['ca'],
            namespace_registry_sha256=names.evidence.digest(namespace),
            scope='explicit-display-mw-all-single-and-enumerated-directions', core=names.CORE)
        query = names.request_query('ca', True, {})
        data = response(); data['query']['general']['git-hash'] = names.CURRENT_CORE
        raw = names.evidence.encoded(data)
        receipt = dict(request=names.PREFIX+'0001.request.json', response=names.PREFIX+'0001-01.raw.json',
            status=200, accepted=False, error=names.CORE_MISMATCH, response_bytes=len(raw),
            response_sha256=names.evidence.digest(raw), started_utc='2026-01-01T00:00:00Z',
            ended_utc='2026-01-01T00:00:01Z')
        for name, value in sources.items():
            (origin / (names.PREFIX+'source-'+name)).write_bytes(value)
        (origin/(names.PREFIX+'namespace-registry.tsv')).write_bytes(namespace)
        for suffix, value in (('requested.json', config), ('0001-01.receipt.json', receipt),
                ('failure.json', dict(error=names.CORE_MISMATCH)),
                ('0001.request.json', dict(query=query, url=names.evidence.wiktionary_api(config['wiki'])+'?'+urllib.parse.urlencode(sorted(query.items()))))):
            (origin/(names.PREFIX+suffix)).write_bytes(names.evidence.encoded(value))
        (origin/(names.PREFIX+'0001-01.raw.json')).write_bytes(raw)
        generator = root/'historical-generator.py';generator.write_bytes(b'synthetic historical source')
        args = argparse.Namespace(observation=origin, observation_generator=generator,
            primary_sources=root, output=root/'replayed', core=names.CURRENT_CORE)
        return args, historical, overrides, names.evidence.digest(generator.read_bytes())

    def run_replay(self, root, inspect):
        args, historical, overrides, generator = self.observation_fixture(root)
        with patch.dict(names.SOURCE_PINS, historical, clear=True), \
                patch.dict(names.CURRENT_CORE_OVERRIDES, overrides, clear=True), \
                patch.object(names, 'source_catalog', return_value=TABLES), \
                patch.object(names, 'OBSERVATION_GENERATOR_PINS', frozenset((generator,))), \
                patch.object(names.evidence, 'get_response', side_effect=AssertionError('offline replay attempted HTTP')):
            inspect(args)

    def test_offline_replay_preserves_rejection_raw_source_and_original_times(self):
        with tempfile.TemporaryDirectory() as directory:
            def check(args):
                before = {p.name:p.read_bytes() for p in args.observation.iterdir()}
                manifest = names.replay_observation(args)
                self.assertEqual(names.verify(args.output), manifest)
                self.assertEqual({p.name:p.read_bytes() for p in args.observation.iterdir()}, before)
                for name, raw in before.items():
                    self.assertEqual((args.output/(names.OBSERVATION_PREFIX+name)).read_bytes(), raw)
                rejected = json.loads((args.output/(names.OBSERVATION_PREFIX+names.PREFIX+'0001-01.receipt.json')).read_text())
                self.assertIs(rejected['accepted'], False)
                self.assertEqual(manifest['retrieved_utc'], rejected['ended_utc'])
                self.assertEqual(manifest['started_utc'], rejected['started_utc'])
                record = json.loads((args.output/names.OBSERVATION_VALIDATION).read_text())
                self.assertIs(record['transport_repeated'], False)
                self.assertEqual(record['original_core'], names.CORE)
                self.assertEqual(record['selected_core'], names.CURRENT_CORE)
                self.assertIn(b'N\tca\tsingle\ten\tangl', (args.output/'language-names.tsv').read_bytes())
            self.run_replay(Path(directory), check)

    def test_resealed_offline_provenance_and_source_mutations_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            def check(args):
                names.replay_observation(args)
                original = {p.name:p.read_bytes() for p in args.output.iterdir()}
                def rewrite(name, mutate):
                    value = json.loads((args.output/name).read_text());mutate(value)
                    (args.output/name).write_bytes(names.evidence.encoded(value))
                def reseal():
                    def update(m): m['artifacts'] = names.payload(args.output)
                    rewrite('language-names.manifest.json', update)
                    (args.output/names.COMPLETE).write_bytes(names.evidence.encoded(dict(schema=names.SCHEMA,
                        manifest_sha256=names.evidence.digest((args.output/'language-names.manifest.json').read_bytes()))))
                for case in ('accepted', 'wrong-error', 'wrong-core', 'unreviewed-generator', 'future-epoch', 'continuation', 'query', 'source', 'extra'):
                    for p in args.output.iterdir():p.unlink()
                    for name, raw in original.items():(args.output/name).write_bytes(raw)
                    prefix = names.OBSERVATION_PREFIX+names.PREFIX
                    if case in ('accepted', 'wrong-error'):
                        rewrite(prefix+'0001-01.receipt.json', lambda r:r.update(accepted=True) if case=='accepted' else r.update(error='HTTP refusal'))
                    elif case=='wrong-core':
                        rewrite(prefix+'requested.json', lambda r:r.update(core=names.CURRENT_CORE))
                    elif case=='unreviewed-generator':
                        (args.output/names.OBSERVATION_GENERATOR).write_bytes(b'unknown source')
                        rewrite(names.OBSERVATION_VALIDATION, lambda r:r.update(original_generator_sha256=names.evidence.digest(b'unknown source')))
                    elif case=='future-epoch':
                        rewrite('language-names.manifest.json', lambda r:r.update(retrieved_utc='2027-01-01T00:00:00Z'))
                    elif case=='continuation':
                        rewrite(prefix+'0001-01.raw.json', lambda r:r.update(continue_={'licontinue':'xx'}))
                        # Use the actual protocol key, then coherently bind its receipt.
                        rewrite(prefix+'0001-01.raw.json', lambda r:r.update({'continue':r.pop('continue_')}))
                        raw=(args.output/(prefix+'0001-01.raw.json')).read_bytes()
                        rewrite(prefix+'0001-01.receipt.json', lambda r:r.update(response_bytes=len(raw), response_sha256=names.evidence.digest(raw)))
                    elif case=='query':
                        rewrite(prefix+'0001.request.json', lambda r:r['query'].update(uselang='en'))
                    elif case=='source':
                        (args.output/(prefix+'source-LanguageCode.php')).write_bytes(b'wrong source')
                    else:
                        (args.output/(names.OBSERVATION_PREFIX+'orphan.json')).write_bytes(b'{}')
                    # Rebind the outer inventory and archived descriptors too;
                    # semantic/source replay must reject, not just a stale hash.
                    def rebind(r):
                        for name in r['original_files']:
                            raw=(args.output/(names.OBSERVATION_PREFIX+name)).read_bytes()
                            r['original_files'][name]=dict(size=len(raw),sha256=names.evidence.digest(raw))
                    rewrite(names.OBSERVATION_VALIDATION,rebind);reseal()
                    with self.subTest(case=case), self.assertRaises(ValueError):names.verify(args.output)
            self.run_replay(Path(directory), check)

    def test_incomplete_or_other_failure_is_not_reclassified_as_core_mismatch(self):
        for case in ('continuation', 'other-failure', 'extra-request', 'source-universe'):
            with tempfile.TemporaryDirectory() as directory:
                def check(args):
                    if case=='other-failure':
                        p=args.observation/(names.PREFIX+'0001-01.receipt.json');r=json.loads(p.read_text());r['error']='HTTP403';p.write_bytes(names.evidence.encoded(r))
                    elif case=='extra-request':
                        (args.observation/(names.PREFIX+'0002.request.json')).write_bytes(b'{}')
                    else:
                        p=args.observation/(names.PREFIX+'0001-01.raw.json');r=json.loads(p.read_text())
                        if case=='continuation':r['continue']={'continue':'-||','licontinue':'xx'}
                        else:r['query']['languageinfo']['bjj']=dict(code='bjj',name='Kannauji',dir='ltr',fallbacks=[])
                        p.write_bytes(names.evidence.encoded(r));receipt=args.observation/(names.PREFIX+'0001-01.receipt.json');v=json.loads(receipt.read_text());v.update(response_bytes=p.stat().st_size,response_sha256=names.evidence.digest(p.read_bytes()));receipt.write_bytes(names.evidence.encoded(v))
                    with self.subTest(case=case), self.assertRaises(ValueError):names.replay_observation(args)
                    self.assertFalse(args.output.exists())
                self.run_replay(Path(directory),check)


def support_fixture(root, wiki='nlwiktionary', content='nl', prefix=None):
    prefix = names.SUPPORT_PREFIX if prefix is None else prefix
    source_data = {'LanguageNameUtils.php': b'reviewed synthetic positive-branch source', 'nl.json': b'{"test-message":"value"}'}
    pins = {name: (names.SUPPORT_SOURCES[name][0], names.evidence.digest(raw)) for name, raw in source_data.items()}
    receipts = {'core': names.SUPPORT_CORE, 'sources': []}
    for name, raw in source_data.items():
        (root / (prefix + name)).write_bytes(raw)
        path, digest = pins[name]
        receipts['sources'].append(dict(file=name, source_path=path,
            url=f'https://raw.githubusercontent.com/wikimedia/mediawiki/{names.SUPPORT_CORE}/{path}',
            status=200, bytes=len(raw), sha256=digest))
    (root / (prefix + 'source-receipts01.json')).write_text(json.dumps(receipts))
    namespace = f'# wikidict-namespace-registry-v1\n# wiki\t{wiki}\n# dump-date\t20261001\n# content-language\t{content}\n'.encode()
    site = json.dumps({'date': '20261001', 'content_language': content,
        'namespace_registry_sha256': names.evidence.digest(namespace),
        'query': {'general': {'wikiid': wiki, 'lang': content, 'git-hash': names.SUPPORT_CORE}}}).encode()
    (root / (prefix + 'namespace-registry.tsv')).write_bytes(namespace)
    (root / (prefix + 'namespace-siteinfo.raw.json')).write_bytes(site)
    profile = dict(id=names.SUPPORT_PROFILE, core=names.SUPPORT_CORE, codes=['nl'], scope=names.SUPPORT_SCOPE,
                   namespace_registry_sha256=names.evidence.digest(namespace), siteinfo_sha256=names.evidence.digest(site))
    return pins, profile


class SupportedLanguageSourceTests(unittest.TestCase):
    def test_positive_source_profile_is_not_known_code_or_negative_enumeration(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); pins, profile = support_fixture(root)
            with patch.object(names, 'SUPPORT_SOURCES', pins):
                self.assertEqual(names.supported_language_profile(root, profile, 'nlwiktionary', '20261001', 'nl'), {'nl': True})
                self.assertEqual(names.render_supported_languages({'nl': True}), b'S\tnl\t1\n')
                for codes in ([], ['qqq'], ['en-x-piglatin'], ['unknown'], ['nl', 'en'], ['nl', 'nl']):
                    with self.subTest(codes=codes), self.assertRaises(ValueError):
                        names.supported_language_profile(root, dict(profile, codes=codes), 'nlwiktionary', '20261001', 'nl')
        with self.assertRaises(ValueError): names.render_supported_languages({'qqq': True})
        with self.assertRaises(ValueError): names.render_supported_languages({'nl': 1})

    def test_source_tamper_and_unaccepted_or_misbound_receipts_reject(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); pins, profile = support_fixture(root)
            receipt_path = root / (names.SUPPORT_PREFIX + 'source-receipts01.json')
            original = json.loads(receipt_path.read_text())
            with patch.object(names, 'SUPPORT_SOURCES', pins):
                for field, value in [('status', 403), ('url', 'https://example.invalid/nl.json'), ('source_path', 'languages/i18n/en.json'), ('sha256', '0' * 64)]:
                    bad = copy.deepcopy(original); bad['sources'][1][field] = value; receipt_path.write_text(json.dumps(bad))
                    with self.subTest(field=field), self.assertRaises(ValueError):
                        names.supported_language_profile(root, profile, 'nlwiktionary', '20261001', 'nl')
                receipt_path.write_text(json.dumps(original))
                (root / (names.SUPPORT_PREFIX + 'nl.json')).write_bytes(b'{"test-message":"tampered"}')
                with self.assertRaises(ValueError):
                    names.supported_language_profile(root, profile, 'nlwiktionary', '20261001', 'nl')

    def test_selected_namespace_and_source_epoch_are_independently_checked(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); pins, profile = support_fixture(root)
            with patch.object(names, 'SUPPORT_SOURCES', pins):
                for changed in (dict(profile, core='1' * 40), dict(profile, scope='deployed-observation'), dict(profile, extra=True)):
                    with self.assertRaises(ValueError): names.supported_language_profile(root, changed, 'nlwiktionary', '20261001', 'nl')
                with self.assertRaises(ValueError): names.supported_language_profile(root, profile, 'enwiktionary', '20261001', 'en')
                site_path = root / (names.SUPPORT_PREFIX + 'namespace-siteinfo.raw.json')
                original = json.loads(site_path.read_text())
                for field, value in [('date', '20260901'), ('content_language', 'en'), ('namespace_registry_sha256', '0' * 64)]:
                    bad = copy.deepcopy(original); bad[field] = value
                    raw = json.dumps(bad).encode(); site_path.write_bytes(raw)
                    with self.subTest(field=field), self.assertRaises(ValueError):
                        names.supported_language_profile(root, dict(profile, siteinfo_sha256=names.evidence.digest(raw)), 'nlwiktionary', '20261001', 'nl')
                bad = copy.deepcopy(original); bad['query']['general']['git-hash'] = '1' * 40
                raw = json.dumps(bad).encode(); site_path.write_bytes(raw)
                with self.assertRaises(ValueError):
                    names.supported_language_profile(root, dict(profile, siteinfo_sha256=names.evidence.digest(raw)), 'nlwiktionary', '20261001', 'nl')

if __name__ == '__main__':
    unittest.main()
