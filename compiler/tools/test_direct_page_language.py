"""Offline package contracts; native code remains the HTML/source authority."""
import copy
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest

import page_language_snapshot as p
import build_wiktionaries as b


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True) + '\n')


def fixture(root):
    source = root / 'source'
    source.mkdir()
    ns = root / 'namespace-registry.tsv'
    ns.write_bytes(b'# wikidict-namespace-registry-v1\n# wiki\ttestwiktionary\n# dump-date\t20261001\n')
    html = '<html lang="test"><body>controlled package, not native semantics</body></html>'
    url = 'https://test.wiktionary.org/wiki/word'
    receipt = dict(core=None, historical_equality_proven=False, unrequested=[], sources=[dict(
        accept_encoding='gzip', accepted=True, bytes=len(html.encode()), content_encoding='gzip',
        encoded=dict(bytes=30, path='/controlled/response.gz', sha256='a'*64), file='response.html',
        final_url=url, headers={'content-type': 'text/html; charset=UTF-8', 'content-encoding': 'gzip'},
        request_count=1, response_complete=True, retrieved_utc='2026-11-19T03:09:06.649850+00:00',
        sha256=digest(html.encode()), source_path='controlled source', status=200,
        unknown_response_outcome=False, url=url, user_agent='Wikidict/1.0 (https://github.com/SmallThingz/wikidict)')])
    row = dict(profile='source-parent-direct-get-v1',
               page=dict(id=10, revision=20, namespace=0, title='word', model='wikitext', raw_sha256='1'*64, expanded_sha256='2'*64),
               mode='current-canonical', response_kind='complete-response', response=html, prefix='<html lang="test">',
               receipt=json.dumps(receipt), styles=dict(responses=[], receipt=''))
    index = dict(schema='wikidict.page-language-index.v1', wiki='testwiktionary', core_revision=None,
                 namespace_registry_sha256=digest(ns.read_bytes()), historical_page_language_proven=False,
                 source_profile=None, responses=[], records=[], direct_get_contexts=[row])
    write_json(source / p.SNAPSHOT, index)
    (source / p.RAW).write_bytes(b'')
    return source / p.SNAPSHOT, ns, index


class DirectPageLanguageTests(unittest.TestCase):
    def test_supplemental_package_preserves_namespaced_identity_and_url(self):
        data = Path(__file__).with_name('testdata')
        selected = data / 'controlled-fr-supplemental' / p.SNAPSHOT
        ns = data / 'fr-table-root' / 'namespace-registry.tsv'
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / p.SNAPSHOT
            source.write_bytes(selected.read_bytes())
            source.with_name(p.RAW).write_bytes(b'')
            packed = p.pack_snapshot(source, ns, root/'packed', wiki='frwiktionary', date='20261001')
            self.assertEqual(packed.read_bytes(), selected.read_bytes())
            index = json.loads(packed.read_bytes())
            row = index['direct_get_contexts'][0]
            title = row['page']['title']
            self.assertEqual((118, 'Racine:alpha/beta gamma'), (row['page']['namespace'], title))
            for namespace, name in ((-1, title), (2**31, title), (118, 'word'), (118, ':arabe'), (118, 'Racine:')):
                with self.subTest(namespace=namespace, name=name):
                    row['page'].update(namespace=namespace, title=name)
                    with self.assertRaisesRegex(ValueError, 'identity|namespace prefix'):
                        p._direct_records(index)

    def test_complete_response_package_preserves_every_byte_and_absence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, ns, _ = fixture(root)
            before = source.read_bytes()
            result = p.pack_snapshot(source, ns, root/'packed', wiki='testwiktionary', date='20261001')
            manifest, inventory = p.validated_capture(result, 'testwiktionary', '20261001')
            self.assertEqual(before, result.read_bytes())
            self.assertEqual(b'', result.with_name(p.RAW).read_bytes())
            self.assertFalse(result.with_name(p.HTML).exists())
            self.assertEqual(1, manifest['record_count'])
            self.assertEqual({p.SNAPSHOT, p.RAW, p.MANIFEST}, set(inventory))
            self.assertEqual(before, source.read_bytes())

    def test_transport_and_identity_refuse_before_writing(self):
        mutations = [
            lambda x: x.update(core_revision='a'*40),
            lambda x: x.update(historical_page_language_proven=True),
            lambda x: x.update(source_profile={'invented': True}),
            lambda x: x['direct_get_contexts'][0].update(mode='historical-oldid'),
            lambda x: x['direct_get_contexts'][0].update(response_kind='saved-gzip-prefix'),
            lambda x: x['direct_get_contexts'][0]['page'].update(revision=0),
            lambda x: x['direct_get_contexts'][0]['page'].update(expanded_sha256=None),
            lambda x: x['direct_get_contexts'][0]['page'].update(namespace=True),
            lambda x: x['direct_get_contexts'][0].update(styles={'responses': ['unearned CSS'], 'receipt': ''}),
            lambda x: x['direct_get_contexts'].append(copy.deepcopy(x['direct_get_contexts'][0])),
            lambda x: x.update(direct_get_contexts=[]),
        ]
        for number, mutate in enumerate(mutations):
            with self.subTest(number=number), tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp); source, ns, index=fixture(root); mutate(index); write_json(source,index)
                with self.assertRaises(ValueError):
                    p.pack_snapshot(source,ns,root/'packed',wiki='testwiktionary',date='20261001')
                self.assertFalse((root/'packed').exists())

    def test_complete_receipt_and_prefix_are_not_reinterpreted(self):
        mutations = [('accepted', False), ('response_complete', False), ('unknown_response_outcome', True),
                     ('request_count', 2), ('status', 302), ('sha256', '0'*64), ('bytes', True),
                     ('url', 'https://other.wiktionary.org/wiki/word'),
                     ('final_url', 'https://test.wiktionary.org/wiki/other')]
        for key,value in mutations:
            with self.subTest(key=key), tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp); source,ns,index=fixture(root); row=index['direct_get_contexts'][0]
                receipt=json.loads(row['receipt']);receipt['sources'][0][key]=value;row['receipt']=json.dumps(receipt);write_json(source,index)
                with self.assertRaises(ValueError):p.pack_snapshot(source,ns,root/'packed',wiki='testwiktionary',date='20261001')
        for field,value in [('prefix','unrelated prefix'),('response','changed response')]:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);source,ns,index=fixture(root);index['direct_get_contexts'][0][field]=value;write_json(source,index)
                with self.assertRaises(ValueError):p.pack_snapshot(source,ns,root/'packed',wiki='testwiktionary',date='20261001')

    def test_companion_namespace_and_no_overwrite_contract(self):
        for member in (p.RAW,p.HTML,'namespace'):
            with self.subTest(member=member),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);source,ns,_=fixture(root)
                (ns if member=='namespace' else source.with_name(member)).write_bytes(b'changed')
                with self.assertRaises(ValueError):p.pack_snapshot(source,ns,root/'packed',wiki='testwiktionary',date='20261001')
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);source,ns,_=fixture(root);(root/'packed').mkdir();(root/'packed/keep').write_bytes(b'keep')
            with self.assertRaises(FileExistsError):p.pack_snapshot(source,ns,root/'packed',wiki='testwiktionary',date='20261001')
            self.assertEqual(b'keep',(root/'packed/keep').read_bytes())

    def test_normal_builder_pins_complete_direct_capture(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);source,ns,_=fixture(root)
            packed=p.pack_snapshot(source,ns,root/'packed',wiki='testwiktionary',date='20261001')
            snapshots={'page-language':packed,'namespace-registry':ns}
            hashes=b.verified_auxiliary_hashes(snapshots,'testwiktionary','20261001')
            manifests,artifacts=b.auxiliary_capture_identities(snapshots)
            result=b.pinned_auxiliary_snapshots(snapshots,hashes,root/'pinned',manifests,artifacts)
            self.assertEqual(source.read_bytes(),result['page-language'].read_bytes())
            self.assertEqual(b'',result['page-language'].with_name(p.RAW).read_bytes())
            self.assertFalse(result['page-language'].with_name(p.HTML).exists())

    @unittest.skipUnless(os.environ.get('WIKIDICT_TEST_FR_CAPTURE') == '1',
                         'requires retained French capture inputs')
    def test_genuine_fr_ordinary_snapshot_offline_package(self):
        repo=Path(__file__).resolve().parents[2]
        source=repo/'.tmp/renderer-core-oct28/fr-kusuriyubi233-structure01/ordinary-source51-01/root-language07/input-package01/page-language.json'
        command=json.loads((repo/'.tmp/figure-normal-inputs01/shared-provider01/retained-bundle-driver01/fr-kusuriyubi-qualified49-ordinary-binding01/command02.json').read_text())
        ns=(Path(command['normal_input_context']['expander_root'])/'namespace-registry.tsv').resolve(strict=True)
        self.assertEqual('94b45767bf5ded37bfcbd7498b285143e7cfc99fdbe7ae36846dd9407a89099e',digest(source.read_bytes()))
        with tempfile.TemporaryDirectory() as tmp:
            result=p.pack_snapshot(source,ns,Path(tmp)/'packed',wiki='frwiktionary',date='20261001')
            manifest,_=p.validated_capture(result,'frwiktionary','20261001')
            self.assertEqual(1,manifest['record_count'])
            self.assertEqual(source.read_bytes(),result.read_bytes())
            record=json.loads(result.read_text())['direct_get_contexts'][0]
            self.assertEqual((1519985,39383157),(record['page']['id'],record['page']['revision']))
            self.assertEqual('current-canonical',record['mode'])
            self.assertIsNone(json.loads(result.read_text())['core_revision'])
