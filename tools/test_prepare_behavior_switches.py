import importlib.util
import json
from pathlib import Path
import tempfile
import shutil
import unittest
import prepare_behavior_switches as behavior

def hermetic_capture(parent):
    magic=behavior.magic
    wiki,date,lang='jawiktionary','20261001','ja'
    root=parent/'source';root.mkdir()
    namespace_raw=magic.document({'query':{'general':{'wikiid':wiki,'lang':lang}}})
    dumped=b'<siteinfo />'
    (root/'namespace-siteinfo.raw.json').write_bytes(namespace_raw)
    (root/'dump-siteinfo.xml').write_bytes(dumped)
    (root/'capture.complete.json').write_bytes(magic.document(dict(wiki=wiki,date=date,artifacts={'namespace-siteinfo.raw.json':magic.digest(namespace_raw),'dump-siteinfo.xml':magic.digest(dumped)})))
    tsv=('# wikidict-namespace-registry-v1\n# wiki\t'+wiki+'\n# dump-date\t'+date+'\n0\tmain\n').encode()
    (root/'namespace-registry.tsv').write_bytes(tsv)
    (root/'namespace-registry.manifest.json').write_bytes(magic.document(dict(wiki=wiki,date=date,output_sha256=magic.digest(tsv),raw_siteinfo_sha256=magic.digest(namespace_raw),dump_siteinfo_sha256=magic.digest(dumped))))
    words=[{'name':name,'case-sensitive':True,'aliases':[name.upper()]} for name in sorted(magic.SUPPORTED)]
    words += [{'name':name,'case-sensitive':False,'aliases':['__'+name.upper()+'__']} for name in ['notoc','forcetoc','toc','noeditsection']]
    words += [{'name':'notalk','case-sensitive':False,'aliases':['＿＿目次非表示＿＿','__لاتحريرقسم__']}]
    raw=magic.document({'query':{'general':{'wikiid':wiki,'lang':lang},'magicwords':words}})
    def fetch(url):
        return raw,dict(source_url=url,response_url=url,status=200,started_utc='2026-10-05T06:00:00+00:00',retrieved_utc='2026-10-05T06:00:01+00:00',raw_sha256=magic.digest(raw),raw_bytes=len(raw))
    magic.capture_snapshot(root,wiki,date,fetcher=fetch)
    output=parent/'behavior'
    behavior.derive_snapshot(root/'magic-words',output,namespace_registry=root/'namespace-registry.tsv')
    return output

class BehaviorTests(unittest.TestCase):
    def raw(self):
        return json.dumps({'query':{'general':{'wikiid':'jawiktionary','lang':'ja'},'magicwords':[{'name':x,'aliases':['__'+x.upper()+'__'],'case-sensitive':False} for x in ['notoc','toc','forcetoc','noeditsection']] + [{'name':'index','aliases':['__INDEX__'],'case-sensitive':True},{'name':'notalk','aliases':['＿＿目次非表示＿＿','__لاتحريرقسم__'],'case-sensitive':False}]}}).encode()
    def test_exact_aliases_and_flags(self):
        t=behavior.render(self.raw(),'jawiktionary','20261001','ja').decode()
        self.assertIn('index\t1\t__INDEX__\n',t)
        self.assertIn('notalk\t0\t＿＿目次非表示＿＿\n',t)
        self.assertIn('__لاتحريرقسم__',t)
    def test_wrong_identity_and_duplicates_rejected(self):
        with self.assertRaises(ValueError):behavior.render(self.raw(),'arwiktionary','20261001','ar')
        d=json.loads(self.raw());d['query']['magicwords'].append(d['query']['magicwords'][0])
        with self.assertRaises(ValueError):behavior.render(json.dumps(d).encode(),'jawiktionary','20261001','ja')
    def test_missing_inventory_and_unsafe_alias_rejected(self):
        d=json.loads(self.raw());d['query']['magicwords'][0]['aliases']=['bad\talias']
        with self.assertRaises(ValueError):behavior.render(json.dumps(d).encode(),'jawiktionary','20261001','ja')
        d=json.loads(self.raw());d['query']['magicwords']=d['query']['magicwords'][1:]
        with self.assertRaises(ValueError):behavior.render(json.dumps(d).encode(),'jawiktionary','20261001','ja')
    def test_native_row_bound(self):
        d=json.loads(self.raw())
        base=sum(len(w['aliases']) for w in d['query']['magicwords'])
        d['query']['magicwords'][0]['aliases'] += ['__x%d__'%i for i in range(10000-base)]
        behavior.render(json.dumps(d).encode(),'jawiktionary','20261001','ja')
        d['query']['magicwords'][0]['aliases'].append('__over_limit__')
        with self.assertRaisesRegex(ValueError,'row bound'):
            behavior.render(json.dumps(d).encode(),'jawiktionary','20261001','ja')
    def test_retained_capture_provenance_tampering(self):
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup)
        original=hermetic_capture(Path(temporary.name))/'behavior-switches.manifest.json'
        behavior.validate_snapshot(original.parent)
        mutations={'version':True,'raw_sha256':'0'*64,'temporal_scope':'false scope','retrieved_utc':'1900-01-01T00:00:00Z','namespace_registry_sha256':'0'*64,'generator_sha256':'0'*64}
        for key,value in mutations.items():
            with self.subTest(field=key),tempfile.TemporaryDirectory() as tmp:
                dst=Path(tmp)/'capture';shutil.copytree(original.parent,dst)
                record=json.loads(original.read_bytes());record[key]=value
                (dst/original.name).write_text(json.dumps(record))
                with self.assertRaises(ValueError):behavior.validate_snapshot(dst)
        for name in ['behavior-source-namespace-registry.tsv','behavior-source-namespace-registry.manifest.json','behavior-switches.tsv']:
            with self.subTest(artifact=name),tempfile.TemporaryDirectory() as tmp:
                dst=Path(tmp)/'capture';shutil.copytree(original.parent,dst)
                file=dst/name
                if name.endswith('.json'):
                    data=json.loads(file.read_bytes());data['raw_siteinfo_sha256']='0'*64;file.write_text(json.dumps(data))
                else:file.write_bytes(file.read_bytes()+b'changed\n')
                with self.assertRaises(ValueError):behavior.validate_snapshot(dst)
if __name__=='__main__':unittest.main()
