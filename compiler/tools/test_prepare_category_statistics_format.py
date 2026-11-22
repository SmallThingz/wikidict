import copy
import json
from pathlib import Path
import re
import tempfile
import unittest
import urllib.parse
import prepare_category_statistics_format as capture

class CategoryFormattingTests(unittest.TestCase):
    def site(self):
        return dict(schema='wikidict.site-info.v2',wiki='arwiktionary',date='20261001',content_language='ar',
            namespace_registry_sha256='a'*64,query=dict(general=dict(wikiid='arwiktionary',lang='ar',generator='MediaWiki 1.47.0-wmf.22'),
            statistics={k:1 for k in capture.prior.profile.KEYS}))
    def raw_site(self):return json.dumps(self.site()).encode()
    def stats(self):return b'A\t10\t2\t3\nB\t5\t0\t0\n'
    def response(self,cfg,number):
        query=capture.queries(cfg)[number-1];lines=query['text'].split('\n');out=[lines[0]]
        for line in lines[1:-1]:
            key,expression=line.split('=',1);raw=re.search(r'formatnum:([0-9]+)',expression).group(1)
            out.append(key+'='+raw)
        return dict(expandtemplates=dict(wikitext='\n'.join(out+[lines[-1]])))

    def test_exact_dated_domain_batches_and_no_category_queries(self):
        cfg=capture.configuration(self.raw_site(),self.stats())
        self.assertEqual(cfg['raw_values'],['0','2','3','5','10'])
        self.assertEqual(cfg['category_stats_sha256'],capture.digest(self.stats()))
        stats=''.join('K'+str(i)+'\t'+str(i)+'\t0\t0\n' for i in range(1,474)).encode()
        large=capture.configuration(self.raw_site(),stats);queries=capture.queries(large)
        self.assertEqual(len(large['raw_values']),474);self.assertEqual(len(queries),15)
        english_sized=''.join('E'+str(i)+'\t'+str(i)+'\t0\t0\n' for i in range(1,5209)).encode()
        english_cfg=capture.configuration(self.raw_site(),english_sized)
        self.assertEqual(len(english_cfg['raw_values']),5209);self.assertEqual(len(capture.queries(english_cfg)),163)
        for query in queries:
            self.assertEqual(query['action'],'expandtemplates');self.assertNotIn('PAGESINCATEGORY',query['text'])
            self.assertLessEqual((len(query['text'].split('\n'))-2)//2,32)
        for invalid in (b'A\t1\t1\t1\n',b'A\t01\t0\t0\n',b'A\t1\t0\t0\nA\t1\t0\t0\n',b'A\t1\t0\t0'):
            with self.assertRaises(ValueError):capture.configuration(self.raw_site(),invalid)

    def test_exact_response_domain_raw_controls_and_incomplete_frame(self):
        cfg=capture.configuration(self.raw_site(),self.stats());data=self.response(cfg,1)
        values=capture.batch_profile(cfg,1,data);self.assertEqual([x['raw'] for x in values],cfg['raw_values'])
        value=capture.output(cfg,values);self.assertEqual(value['schema'],capture.SCHEMA)
        for text in (data['expandtemplates']['wikitext'].replace('0-RAW=0','0-RAW=1'),
                     data['expandtemplates']['wikitext']+'\n',data['expandtemplates']['wikitext'].replace('0=0','0=<b>0</b>')):
            with self.assertRaises(ValueError):capture.batch_profile(cfg,1,dict(expandtemplates=dict(wikitext=text)))
        with self.assertRaises(ValueError):capture.output(cfg,values[:-1])

    def test_saved_capture_replays_all17_requests_and_refuses_changed_stats(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);site=root/'site.json';stats=root/'stats.tsv';site.write_bytes(self.raw_site())
            stats.write_text(''.join('K'+str(i)+'\t'+str(i)+'\t0\t0\n' for i in range(1,474)))
            calls=[]
            def transport(url,timeout):
                query={k:v[0] for k,v in urllib.parse.parse_qs(urllib.parse.urlsplit(url).query).items()};calls.append(query)
                if query['action']=='query':value=dict(query=dict(general=dict(self.site()['query']['general'],generator='MediaWiki 1.47.0-wmf.24')))
                else:
                    text=query['text'];number=int(text.split('\n')[0].rsplit('-',1)[1]);cfg=capture.configuration(site.read_bytes(),stats.read_bytes());value=self.response(cfg,number)
                return 200,{},json.dumps(value).encode()
            output=root/'capture';manifest=capture.capture(site,stats,output,delay=0,transport=transport,sleep=lambda _:None)
            self.assertEqual(len(calls),17);self.assertEqual(capture.verify(output),manifest)
            self.assertEqual(manifest['configuration']['source_server_identity']['generator'],'MediaWiki 1.47.0-wmf.22')
            self.assertEqual(manifest['server_identity']['generator'],'MediaWiki 1.47.0-wmf.24')
            self.assertEqual(stats.read_text().splitlines()[0],'K1\t1\t0\t0')
            (output/'original-category-stats.tsv').write_bytes(self.stats())
            with self.assertRaises(ValueError):capture.verify(output)

    def test_changed_current_generator_is_recorded_failure_not_relabelled(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);site=root/'site.json';stats=root/'stats.tsv';site.write_bytes(self.raw_site());stats.write_bytes(self.stats());calls=[]
            def transport(url,timeout):
                calls.append(url);query={k:v[0] for k,v in urllib.parse.parse_qs(urllib.parse.urlsplit(url).query).items()}
                if query['action']=='query':
                    generator='MediaWiki 1.47.0-wmf.22' if len(calls)==1 else 'MediaWiki 1.47.0-wmf.24'
                    value=dict(query=dict(general=dict(self.site()['query']['general'],generator=generator)))
                else:value=self.response(capture.configuration(site.read_bytes(),stats.read_bytes()),1)
                return 200,{},json.dumps(value).encode()
            output=root/'capture'
            with self.assertRaisesRegex(ValueError,'Server identity changed during capture'):
                capture.capture(site,stats,output,delay=0,transport=transport,sleep=lambda _:None)
            self.assertEqual(len(calls),3);self.assertFalse((output/capture.COMPLETE).exists())
            self.assertTrue((output/'failure.json').is_file());self.assertTrue(any(output.glob('*.raw.json')))

    def captured(self,root):
        site=root/'site.json';stats=root/'stats.tsv';site.write_bytes(self.raw_site());stats.write_bytes(self.stats())
        cfg=capture.configuration(site.read_bytes(),stats.read_bytes())
        def transport(url,timeout):
            query={k:v[0]for k,v in urllib.parse.parse_qs(urllib.parse.urlsplit(url).query).items()}
            value=dict(query=dict(general=self.site()['query']['general']))if query['action']=='query'else self.response(cfg,int(query['text'].split('\n')[0].rsplit('-',1)[1]))
            return 200,{},json.dumps(value).encode()
        out=root/'capture';capture.capture(site,stats,out,delay=0,transport=transport,sleep=lambda _:None);return out
    def reseal(self,root,change=None):
        manifest=json.loads((root/capture.MANIFEST).read_bytes())
        if change:change(manifest)
        manifest['artifacts']=capture.artifacts(root)
        (root/capture.MANIFEST).write_bytes(capture.e.encoded(manifest))
        (root/capture.COMPLETE).write_bytes(capture.e.encoded(dict(schema=manifest['schema'],manifest_sha256=capture.digest((root/capture.MANIFEST).read_bytes()))))
        return manifest
    def test_recorded_category_provenance_replays_without_relabeling(self):
        with tempfile.TemporaryDirectory()as temp:
            out=self.captured(Path(temp));original=json.loads((out/capture.MANIFEST).read_bytes())
            (out/'statistics-capture-helper.py').write_text('# recorded original helper\n')
            manifest=self.reseal(out);before={p.name:p.read_bytes()for p in out.iterdir()}
            self.assertEqual(capture.verify(out),manifest)
            self.assertEqual({p.name:p.read_bytes()for p in out.iterdir()},before)
            for key in ('retrieved_utc','server_identity','requests','temporal_scope'):self.assertEqual(original[key],manifest[key])
    def test_changed_category_provenance_cannot_hide_resealed_evidence(self):
        for mode in ('query','receipt','raw','control','bracket','output','stats','reordered','missing-producer'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory()as temp:
                out=self.captured(Path(temp));(out/'capture-producer.py').write_text('# historical observation producer\n')
                if mode=='query':
                    path=out/'02.request.json';v=json.loads(path.read_bytes());v['query']['title']='wrong';path.write_bytes(capture.e.encoded(v))
                elif mode=='receipt':
                    path=out/'02-01.receipt.json';v=json.loads(path.read_bytes());v['accepted']=False;path.write_bytes(capture.e.encoded(v))
                elif mode in ('raw','control','bracket'):
                    number='03'if mode=='bracket'else'02';path=out/(number+'-01.raw.json');v=json.loads(path.read_bytes())
                    if mode=='bracket':v['query']['general']['generator']='changed server'
                    elif mode=='control':v['expandtemplates']['wikitext']=v['expandtemplates']['wikitext'].replace('0-RAW=0','0-RAW=1')
                    else:v['expandtemplates']['wikitext']=v['expandtemplates']['wikitext'].replace('0=0','0=9')
                    path.write_bytes(capture.e.encoded(v));receipt=out/(number+'-01.receipt.json');rv=json.loads(receipt.read_bytes());rv.update(response_bytes=path.stat().st_size,response_sha256=capture.digest(path.read_bytes()));receipt.write_bytes(capture.e.encoded(rv))
                elif mode=='output':(out/capture.OUTPUT).write_bytes(b'{}\n')
                elif mode=='stats':(out/'original-category-stats.tsv').write_bytes(b'A\t9\t2\t3\n')
                elif mode=='missing-producer':(out/'statistics-profile-helper.py').unlink()
                self.reseal(out,(lambda v:v['requests'].reverse())if mode=='reordered'else None)
                with self.assertRaises(ValueError):capture.verify(out)
