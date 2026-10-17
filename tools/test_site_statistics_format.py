import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import urllib.parse

s=importlib.util.spec_from_file_location('capture',Path(__file__).with_name('prepare_site_statistics_format.py'))
m=importlib.util.module_from_spec(s);s.loader.exec_module(m)

class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.top=Path(self.tmp.name);self.addCleanup(self.tmp.cleanup)
        self.site=self.top/'site.json'
        value=dict(schema='wikidict.site-info.v2',wiki='enwiktionary',date='20261001',content_language='en',
          namespace_registry_sha256='a'*64,query=dict(general=dict(wikiid='enwiktionary',lang='en'),
          statistics={key:1234567 for key in m.profile.KEYS}))
        self.site.write_text(json.dumps(value));self.cfg=m.profile.configuration(value,m.digest(self.site.read_bytes()))
        self.calls=[]
    def transport(self,url,timeout):
        self.assertGreater(timeout,0);self.assertLessEqual(timeout,30)
        q=urllib.parse.parse_qs(urllib.parse.urlsplit(url).query);self.calls.append(q)
        if q['action']==['query']:
            value=dict(query=dict(general=dict(wikiid='enwiktionary',lang='en',generator='MediaWiki 1.45')))
        else:
            self.assertNotIn('NUMBEROF',q['text'][0]);self.assertEqual(q['text'][0],m.profile.query(self.cfg)['text'])
            lines=[m.profile.BEGIN]
            for key in m.profile.KEYS:lines.extend((key+'=1,234,567',key+'-RAW=1234567'))
            value=dict(expandtemplates=dict(wikitext='\n'.join(lines+[m.profile.END])))
        return 200,{},json.dumps(value).encode()
    def capture(self,transport=None):
        return m.capture(self.site,self.top/'out',transport=transport or self.transport,delay=0,sleep=lambda _:None)
    def test_capture_and_offline_replay(self):
        self.capture();self.assertEqual(len(self.calls),3);m.verify(self.top/'out')
        self.assertTrue((self.top/'out'/m.COMPLETE).is_file())
        self.assertEqual(self.site.read_bytes(),(self.top/'out'/'original-site-info.json').read_bytes())
    def test_changed_formatted_artifact_refused(self):
        self.capture();(self.top/'out'/m.OUTPUT).write_text('{}')
        with self.assertRaises(ValueError):m.verify(self.top/'out')
    def test_changed_raw_response_refused(self):
        self.capture();(self.top/'out'/'02-01.raw.json').write_text('{}')
        with self.assertRaises(ValueError):m.verify(self.top/'out')
    def test_identity_change_retains_failure_no_completion(self):
        def transport(url,timeout):
            status,headers,raw=self.transport(url,timeout)
            if len(self.calls)==3:
                value=json.loads(raw);value['query']['general']['generator']='changed';raw=json.dumps(value).encode()
            return status,headers,raw
        with self.assertRaisesRegex(ValueError,'identity changed'):self.capture(transport)
        self.assertTrue((self.top/'out'/'failure.json').is_file());self.assertFalse((self.top/'out'/m.COMPLETE).exists())
    def test_pinned_source_change_refused(self):
        def transport(url,timeout):
            answer=self.transport(url,timeout)
            if len(self.calls)==2:self.site.write_text('{}')
            return answer
        with self.assertRaisesRegex(ValueError,'Pinned input'):self.capture(transport)
        self.assertFalse((self.top/'out'/m.COMPLETE).exists())
    def test_bounded_retry_retains_rejected_receipt(self):
        attempts=[0];waits=[]
        def transport(url,timeout):
            attempts[0]+=1
            if attempts[0]==1:return 503,{'Retry-After':'1'},b'{}'
            return self.transport(url,timeout)
        m.capture(self.site,self.top/'out',transport=transport,delay=0,sleep=waits.append)
        self.assertEqual(waits,[1,0,0]);m.verify(self.top/'out')
        self.assertFalse(json.loads((self.top/'out'/'01-01.receipt.json').read_text())['accepted'])
    def test_bad_raw_control_never_completes(self):
        def transport(url,timeout):
            status,headers,raw=self.transport(url,timeout)
            return status,headers,raw.replace(b'pages-RAW=1234567',b'pages-RAW=1234568')
        with self.assertRaises(ValueError):self.capture(transport)
        self.assertFalse((self.top/'out'/m.COMPLETE).exists())
    def test_existing_output_refused(self):
        (self.top/'out').mkdir()
        with self.assertRaises(FileExistsError):self.capture()
    def test_rebound_archived_producer_refused(self):
        self.capture();root=self.top/'out'
        (root/'profile-producer.py').write_text('# changed producer\n')
        manifest=json.loads((root/m.MANIFEST).read_text());manifest['artifacts']=m.artifacts(root)
        (root/m.MANIFEST).write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError,'producer identity'):m.verify(root,complete=False)

if __name__=='__main__':unittest.main()
