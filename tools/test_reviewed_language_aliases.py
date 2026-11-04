"""Focused ordinary metadata producer binding checks; no network required."""
import hashlib
import copy
import bz2
import sys
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import download_wiktionaries as producer
import build_wiktionaries as builder

R=builder.PROJECT


class ReviewedAliasesTest(unittest.TestCase):
    def test_registered_target_and_digest_bind_every_reviewed_byte(self):
        raw = Path(producer.__file__).with_name('reviewed_language_aliases.json').read_bytes()
        rows = '# mediawiki\nur\tUrdu\n'
        result = producer.append_reviewed_language_aliases(rows)
        self.assertEqual(result, rows + '# reviewed-alias\tur\tاُردو\tnwe-urdu-exact-v1\t' + hashlib.sha256(raw).hexdigest() + '\n')
        self.assertEqual(producer.append_reviewed_language_aliases('fr\tFrench\n'), 'fr\tFrench\n')
        changed = json.loads(raw)
        changed['records'][0]['rationale'] += ' reviewed again'
        changed_raw = json.dumps(changed).encode()
        with patch.object(Path, 'read_bytes', return_value=changed_raw):
            self.assertNotEqual(producer.append_reviewed_language_aliases(rows), result)

    def test_resume_rejects_stale_registry_without_rewriting_it(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            old = 'ur\tUrdu\n'
            item = producer.write_language_registry(root, 'skrwiktionary', '20261001', old, 'skr')
            path = root / 'skrwiktionary' / '20261001' / 'language-registry.tsv'
            with self.assertRaisesRegex(ValueError, 'Stale reviewed'):
                producer.validate_registry_file(root, item)
            self.assertEqual(path.read_text(), old)
            derived = producer.append_reviewed_language_aliases(old)
            current = producer.write_language_registry(root, 'skrwiktionary', '20261001', derived, 'skr')
            self.assertEqual(producer.validate_registry_file(root, current), path)

    def test_missing_or_conflicting_provenance_rejected(self):
        raw = json.loads(Path(producer.__file__).with_name('reviewed_language_aliases.json').read_bytes())
        for mutation in ('duplicate', 'authority', 'separator'):
            document = json.loads(json.dumps(raw))
            if mutation == 'duplicate':
                document['records'].append(document['records'][0])
            elif mutation == 'authority':
                document['records'][0]['authority_kind'] = 'mediawiki'
            else:
                document['records'][0]['alias'] += '\t'
            with patch.object(Path, 'read_bytes', return_value=json.dumps(document).encode()):
                with self.assertRaises(ValueError):
                    producer.append_reviewed_language_aliases('ur\tUrdu\n')


class ReviewedRegistryAdmissionTests(unittest.TestCase):
    def setUp(self):
        (R/'.tmp').mkdir(exist_ok=True)
        self.tmp=tempfile.TemporaryDirectory(prefix='skr-derived-admission-',dir=R/'.tmp');self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.downloads=self.root/'selected';self.folder=self.downloads/'skrwiktionary/20261001';self.folder.mkdir(parents=True)
        original_root=self.root/'original';original_folder=original_root/'skrwiktionary/20261001';original_folder.mkdir(parents=True)
        self.original=('# wikidict-language-registry-v2\n# content-language\tskr\n# mediawiki\n'
                       'skr\tSaraiki\n' 'ur\tUrdu\n').encode()
        old_item=producer.write_language_registry(original_root,'skrwiktionary','20261001',self.original.decode(),'skr')
        self.original_path=original_folder/'language-registry.tsv'
        self.xml=bz2.compress(b'<mediawiki/>');name='skrwiktionary-20261001-pages-meta-current.xml.bz2'
        self.xml_original=original_folder/name;self.xml_original.write_bytes(self.xml)
        self.xml_selected=self.folder/name;self.xml_selected.write_bytes(self.xml)
        item=dict(wiki='skrwiktionary',date='20261001',name=name,size=len(self.xml),sha1=hashlib.sha1(self.xml).hexdigest(),
                  url='https://dumps.wikimedia.org/skrwiktionary/20261001/'+name)
        self.before=dict(requested_editions=['skrwiktionary'],files=[item],language_registries=[old_item],failures=[],auxiliary_capture_roots={})
        self.original_manifest_raw=(json.dumps(self.before)+'\n').encode()
        old_manifest=original_root/'manifest.json';old_manifest.write_bytes(self.original_manifest_raw)
        self.manifest_ref=dict(path=str(old_manifest),bytes=len(self.original_manifest_raw),sha256=hashlib.sha256(self.original_manifest_raw).hexdigest())
        self.after=copy.deepcopy(self.before);self.index=0
        self.reference=Path(producer.__file__).with_name('reviewed_language_aliases.json');self.reference_raw=self.reference.read_bytes()
        self.derived=producer.append_reviewed_language_aliases(self.original.decode()).encode()
        self.item=producer.write_language_registry(self.downloads,'skrwiktionary','20261001',self.derived.decode(),'skr')
        self.after['language_registries'][self.index]=self.item
        self.manifest=self.downloads/'manifest.json';self.write_manifest()

    def write_manifest(self):self.manifest.write_text(json.dumps(self.after)+'\n')

    def admit(self):
        with patch.object(sys,'argv',['download_wiktionaries.py','--resume','--plan','--output',str(self.downloads),'--wikis','skrwiktionary']), \
             patch.object(producer,'download_all',side_effect=AssertionError('no network/download in admission control')), \
             patch.object(producer,'language_registry_snapshot',side_effect=AssertionError('no API/source replacement')), \
             patch('builtins.print'):
            producer.main()

    def test_exact_derived_lineage_is_admitted_by_existing_resume_plan(self):
        marker=('# reviewed-alias\tur\tاُردو\tnwe-urdu-exact-v1\t'+hashlib.sha256(self.reference_raw).hexdigest()+'\n').encode()
        self.assertEqual(self.derived,self.original+marker)
        expected=copy.deepcopy(self.before);expected['language_registries'][self.index]=dict(self.before['language_registries'][self.index],size=len(self.derived),sha256=hashlib.sha256(self.derived).hexdigest())
        self.assertEqual(self.after,expected);self.assertEqual(self.after['files'],self.before['files'])
        self.admit()
        self.assertEqual(self.original_path.read_bytes(),self.original)
        self.assertEqual(Path(self.manifest_ref['path']).read_bytes(),self.original_manifest_raw)
        self.assertEqual(self.reference.read_bytes(),self.reference_raw)
        self.assertEqual(self.xml_original.read_bytes(),self.xml);self.assertEqual(self.xml_selected.read_bytes(),self.xml)

    def test_existing_builder_selects_derived_registry_and_rejects_inventory_tamper(self):
        namespace=self.folder/'namespace-registry.tsv';namespace.write_text('# wikidict-namespace-registry-v1\n# wiki\tskrwiktionary\n# dump-date\t20261001\n# content-language\tskr\n0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tentries\n')
        # Small metadata-only fixture avoids replaying unrelated retained captures.
        selected=dict(language_registries=[self.item],auxiliary_capture_roots={})
        options=builder.resolve_edition_snapshot_options(selected,{('skrwiktionary','20261001'):[]},self.downloads)
        self.assertEqual(options[('skrwiktionary','20261001')]['auxiliary_snapshots']['language-registry'],(self.folder/'language-registry.tsv').resolve())
        for field,value in [('sha256','0'*64),('size',len(self.derived)+1)]:
            changed=copy.deepcopy(selected);changed['language_registries'][0][field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):builder.resolve_edition_snapshot_options(changed,{('skrwiktionary','20261001'):[]},self.downloads)

    def test_stale_marker_reference_or_metadata_rejected_without_original_mutation(self):
        path=self.folder/'language-registry.tsv'
        for raw in (self.original,self.derived.replace(b'nwe-urdu-exact-v1',b'unknown-policy-v1')):
            path.write_bytes(raw);self.after['language_registries'][self.index]=dict(self.item,size=len(raw),sha256=hashlib.sha256(raw).hexdigest());self.write_manifest()
            with self.assertRaisesRegex(ValueError,'Stale reviewed'):self.admit()
        path.write_bytes(self.derived);self.after['language_registries'][self.index]=self.item;self.write_manifest()
        changed=json.loads(self.reference_raw);changed['records'][0]['rationale']+=' newly reviewed';changed_raw=json.dumps(changed).encode()
        original_read=Path.read_bytes
        def read(selected):return changed_raw if selected==self.reference else original_read(selected)
        with patch.object(Path,'read_bytes',read):
            with self.assertRaisesRegex(ValueError,'Stale reviewed'):self.admit()
        self.assertEqual(self.original_path.read_bytes(),self.original)
        self.assertEqual(Path(self.manifest_ref['path']).read_bytes(),self.original_manifest_raw)


class CombinedReviewedRecordsTest(unittest.TestCase):
    def test_all_eleven_records_share_current_document_digest(self):
        raw = Path(producer.__file__).with_name('reviewed_language_aliases.json').read_bytes()
        document = json.loads(raw)
        self.assertEqual([(r['code'], r['alias']) for r in document['records']], [('ur', 'اُردو'), ('ar', 'arabsczi'), ('sq', 'albańsczi'), ('ru', 'rusczi'), ('sr', 'serbsczi'), ('pl', 'pòlsczi'), ('ja', 'japòńsczi'), ('hsb', 'górnosorbsczi'), ('cs', 'czesczi'), ('ko', 'kòrejańsczi'), ('en', 'anielsczi')])
        rows = ''.join(code + '\tRegistered ' + code + '\n' for code in ['ur', 'ar', 'sq', 'ru', 'sr', 'pl', 'ja', 'hsb', 'cs', 'ko', 'en'])
        digest = hashlib.sha256(raw).hexdigest()
        expected = rows + ''.join('# reviewed-alias\t' + r['code'] + '\t' + r['alias'] + '\t' + r['id'] + '\t' + digest + '\n' for r in document['records'])
        self.assertEqual(producer.append_reviewed_language_aliases(rows), expected)


if __name__ == '__main__':
    unittest.main()
