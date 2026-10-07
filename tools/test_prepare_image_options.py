import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch
import build_wiktionaries as builder
import prepare_image_options as image
from test_prepare_behavior_switches import hermetic_capture

def image_words():
    return [dict(name='img_alt', **{'case-sensitive':True}, aliases=['بديل=$1','代替文=$1','alt=$1','अङ्गुष्ठचित्रम्=\n$1','literal\\backslash=$1','literal\ttab=$1']),
            dict(name='img_width', **{'case-sensitive':True}, aliases=['$1px']),
            dict(name='img_thumbnail', **{'case-sensitive':True}, aliases=['miniatur','thumb']),
            dict(name='timedmedia_loop', **{'case-sensitive':False}, aliases=['loop'])]

def image_capture(parent, retrieved=None):
    magic=image.magic;original=magic.capture_snapshot
    def capture(root,wiki,date,**kwargs):
        fetch=kwargs['fetcher']
        def enriched(url):
            raw,receipt=fetch(url);record=json.loads(raw)
            record['query']['magicwords']+=image_words();raw=magic.document(record)
            return raw,{**receipt,'raw_sha256':magic.digest(raw),'raw_bytes':len(raw),**({'retrieved_utc':retrieved} if retrieved is not None else {})}
        return original(root,wiki,date,**{**kwargs,'fetcher':enriched})
    with patch.object(magic,'capture_snapshot',side_effect=capture):return hermetic_capture(parent)

class ImageOptionsTests(unittest.TestCase):
    def raw(self):return image.magic.document({'query':{'general':{'wikiid':'jawiktionary','lang':'ja'},'magicwords':image_words()}})
    def render(self,raw=None):return image.render(self.raw() if raw is None else raw,'jawiktionary','20261001','ja','0'*64,'1'*64)
    def test_exact_case_patterns_and_order(self):
        text=self.render().decode();rows=[line.split('\t',2) for line in text.splitlines() if not line.startswith('#')]
        self.assertEqual([json.loads(row[2]) for row in rows if row[0]=='img_alt'],image_words()[0]['aliases'])
        self.assertLess(text.index('img_thumbnail\t'),text.index('img_alt\t'));self.assertLess(text.index('img_alt\t'),text.index('img_width\t'))
        self.assertIn('timedmedia_loop\t0\t"loop"\n',text)
    def test_invalid_patterns_identity_and_bounds(self):
        for alias in ('$1$1px','$2px','bad\x00alias','x'*1025):
            d=json.loads(self.raw());d['query']['magicwords'][0]['aliases']=[alias]
            with self.subTest(alias=alias),self.assertRaises(ValueError):self.render(image.magic.document(d))
        for field,value in [('wikiid','otherwiktionary'),('lang','ar')]:
            d=json.loads(self.raw());d['query']['general'][field]=value
            with self.assertRaises(ValueError):self.render(image.magic.document(d))
        for mutation in ('flag','duplicate','missing'):
            d=json.loads(self.raw())
            if mutation=='flag':d['query']['magicwords'][0]['case-sensitive']=1
            elif mutation=='duplicate':d['query']['magicwords'].append(d['query']['magicwords'][0])
            else:d['query']['magicwords']=d['query']['magicwords'][1:]
            with self.assertRaises(ValueError):self.render(image.magic.document(d))
        d=json.loads(self.raw());base=sum(len(w['aliases']) for w in d['query']['magicwords']);d['query']['magicwords'][0]['aliases']+=['alias%d'%i for i in range(10000-base)]
        self.render(image.magic.document(d));d['query']['magicwords'][0]['aliases'].append('overlimit')
        with self.assertRaisesRegex(ValueError,'row bound'):self.render(image.magic.document(d))
    def test_authenticated_reuse_and_provenance_tampering(self):
        with tempfile.TemporaryDirectory() as tmp:
            parent=Path(tmp);prior=image_capture(parent);output=parent/'image'
            manifest=image.derive_snapshot(prior,output)
            self.assertEqual(sorted(p.name for p in output.iterdir()),['image-options.manifest.json','image-options.tsv'])
            self.assertEqual(len(image.capture_artifacts(output,manifest,behavior_capture=prior)),len(image.behavior.capture_artifacts(prior))+2)
            for file in output.iterdir():shutil.copyfile(file,prior/file.name)
            image.validate_snapshot(prior)
            original=(prior/'image-options.manifest.json').read_bytes()
            for key,value in {'version':True,'wiki':'otherwiktionary','generator_sha256':'0'*64,'raw_sha256':'0'*64,'behavior_manifest_sha256':'0'*64,'behavior_switches_sha256':'0'*64,'namespace_registry_sha256':'0'*64,'retrieved_utc':'1900','temporal_scope':'false'}.items():
                record=json.loads(original);record[key]=value;(prior/'image-options.manifest.json').write_bytes(image.magic.document(record))
                with self.subTest(field=key),self.assertRaises(ValueError):image.validate_snapshot(prior)
            (prior/'image-options.manifest.json').write_bytes(original)
            table=prior/'image-options.tsv';table.write_bytes(table.read_bytes()+b'changed\n')
            with self.assertRaises(ValueError):image.validate_snapshot(prior)
    def test_builder_selected_pair_and_deduplicated_pinning(self):
        with tempfile.TemporaryDirectory() as tmp:
            parent=Path(tmp);prior=image_capture(parent);output=parent/'image'
            image.derive_snapshot(prior,output)
            for file in output.iterdir():shutil.copyfile(file,prior/file.name)
            snapshots={'behavior-switches':prior/'behavior-switches.tsv','image-options':prior/'image-options.tsv','namespace-registry':prior/'behavior-source-namespace-registry.tsv'}
            record=image.validate_snapshot(prior)
            hashes=builder.verified_auxiliary_hashes(snapshots,record['wiki'],record['date'])
            pinned=builder.pinned_auxiliary_snapshots(snapshots,hashes,parent/'pinned')
            self.assertEqual(builder.verified_auxiliary_hashes(pinned,record['wiki'],record['date']),hashes)
            self.assertEqual(len(list((parent/'pinned').iterdir())),len(image.capture_artifacts(prior))+1)
            self.assertIn('--image-options-snapshot',builder.auxiliary_snapshot_args(snapshots))
            with self.assertRaisesRegex(ValueError,'selected behavior'):
                builder.verified_auxiliary_hashes({'image-options':snapshots['image-options']})
            wrong=parent/'namespace-registry.tsv';wrong.write_bytes(snapshots['namespace-registry'].read_bytes()+b'0\t0\tDifferent\n')
            with self.assertRaisesRegex(ValueError,'different namespace'):
                builder.verified_auxiliary_hashes({**snapshots,'namespace-registry':wrong})
            # Distinct authenticated receipt, identical behavior TSV: pairing
            # requires the selected full capture manifest, not only table bytes.
            second=parent/'second';second.mkdir()
            alternate=image_capture(second,'2026-10-05T06:00:02+00:00')
            self.assertEqual((alternate/'behavior-switches.tsv').read_bytes(),snapshots['behavior-switches'].read_bytes())
            self.assertNotEqual(image.magic.digest((alternate/'behavior-switches.manifest.json').read_bytes()),record['behavior_manifest_sha256'])
            with self.assertRaisesRegex(ValueError,'selected behavior'):
                builder.verified_auxiliary_hashes({**snapshots,'behavior-switches':alternate/'behavior-switches.tsv'})

    def test_builder_selected_namespace_capture_branches(self):
        with tempfile.TemporaryDirectory() as tmp:
            parent=Path(tmp);prior=image_capture(parent);output=parent/'image'
            image.derive_snapshot(prior,output)
            for file in output.iterdir():shutil.copyfile(file,prior/file.name)
            record=image.validate_snapshot(prior);source=parent/'source';path=prior/'image-options.tsv'
            builder.validate_captured_snapshot('image-options',path,record,[],source)
            for name,expected in [('namespace-registry.tsv','selected namespace'),('namespace-siteinfo.raw.json','namespace capture'),('capture.complete.json','namespace capture')]:
                file=source/name;old=file.read_bytes();file.write_bytes(old+b'changed')
                with self.subTest(name=name),self.assertRaisesRegex(ValueError,expected):
                    builder.validate_captured_snapshot('image-options',path,record,[],source)
                file.write_bytes(old)

if __name__=='__main__':unittest.main()
