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
        with self.assertRaisesRegex(ValueError, 'universe'):
            names.reconstruct(self.config(), self.batches(), ALIASES, tables)

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



if __name__ == '__main__':
    unittest.main()
