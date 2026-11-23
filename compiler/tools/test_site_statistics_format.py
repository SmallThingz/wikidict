import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import urllib.parse
from unittest import mock

s=importlib.util.spec_from_file_location('capture',Path(__file__).with_name('prepare_site_statistics_format.py'))
m=importlib.util.module_from_spec(s);s.loader.exec_module(m)

class ToolDiscoveryTests(unittest.TestCase):
    def test_nearest_private_tools_win_and_current_checkout_beats_retained_tools(self):
        import ast
        tree = ast.parse(Path(m.__file__).read_text())
        assignment = next(node for node in tree.body if isinstance(node, ast.Assign)
                          and any(isinstance(target, ast.Name) and target.id == 'TOOLS'
                                  for target in node.targets))
        code = compile(ast.Module(body=[assignment], type_ignores=[]), str(m.__file__), 'exec')
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            for name in ('tools', 'compiler/tools'):
                path = root / name / 'prepare_date_numbering.py'
                path.parent.mkdir(parents=True); path.write_text('selected fixture only')
            origin = root / '.tmp/private/prepare_site_statistics_format.py'
            namespace = {'Path': Path, '__file__': str(origin)}
            exec(code, namespace)
            self.assertEqual(namespace['TOOLS'], root / 'compiler/tools')
            private = origin.parent / 'tools/prepare_date_numbering.py'
            private.parent.mkdir(parents=True); private.write_text('private fixture only')
            exec(code, namespace)
            self.assertEqual(namespace['TOOLS'], private.parent)

    def test_prepared_import_preserves_bound_path_and_uses_imported_profile(self):
        import sys
        before = [sys._stdlib_dir, sys._stdlib_dir + '/lib-dynload', str(m.TOOLS)]
        spec = importlib.util.spec_from_file_location('prepared_capture', m.__file__)
        helper = importlib.util.module_from_spec(spec)
        with mock.patch.object(sys, '_xoptions', {'wikidict_prepared_source': '1'}), \
             mock.patch.object(sys, 'path', before.copy()):
            spec.loader.exec_module(helper)
            self.assertEqual(sys.path, before)
            self.assertIs(helper.profile, sys.modules['prepare_site_statistics_format_profile'])
            self.assertEqual(Path(helper.profile.__file__), m.TOOLS / 'prepare_site_statistics_format_profile.py')


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
    def reseal(self,root,change=None):
        manifest=json.loads((root/m.MANIFEST).read_bytes())
        if change:change(manifest)
        manifest['artifacts']=m.artifacts(root)
        (root/m.MANIFEST).write_bytes(m.e.encoded(manifest))
        (root/m.COMPLETE).write_bytes(m.e.encoded(dict(schema=manifest['schema'],manifest_sha256=m.digest((root/m.MANIFEST).read_bytes()))))
        return manifest
    def test_recorded_producer_provenance_replays_without_relabeling(self):
        self.capture();root=self.top/'out'
        original=json.loads((root/m.MANIFEST).read_bytes())
        (root/'profile-producer.py').write_text('# recorded historical producer\n')
        manifest=self.reseal(root)
        before={p.name:p.read_bytes()for p in root.iterdir()}
        changed_current=self.top/'future-date-helper.py';changed_current.write_text('# current helper maintenance\n')
        with mock.patch.object(m.date,'__file__',str(changed_current)):
            self.assertEqual(m.verify(root),manifest)
        self.assertEqual({p.name:p.read_bytes()for p in root.iterdir()},before)
        for key in ('retrieved_utc','server_identity','requests','temporal_scope'):
            self.assertEqual(manifest[key],original[key])
    def test_recorded_producer_roles_and_descriptors_stay_bounded(self):
        roles=('capture-producer.py','profile-producer.py','date-numbering-helper.py','capture-evidence-helper.py')
        good={name:dict(bytes=1,sha256='a'*64)for name in roles}
        m.validate_provenance(good,roles)
        for mode in ('missing','extra','boolean','empty','oversize','hash'):
            with self.subTest(mode=mode):
                value=json.loads(json.dumps(good))
                if mode=='missing':value.pop(roles[0])
                elif mode=='extra':value['unknown-helper.py']=dict(bytes=1,sha256='a'*64)
                elif mode=='boolean':value[roles[0]]['bytes']=True
                elif mode=='empty':value[roles[0]]['bytes']=0
                elif mode=='oversize':value[roles[0]]['bytes']=128*1024+1
                else:value[roles[0]]['sha256']='A'*64
                with self.assertRaisesRegex(ValueError,'producer provenance'):m.validate_provenance(value,roles)
    def test_changed_provenance_does_not_hide_resealed_evidence_changes(self):
        for mode in ('query','url','receipt','raw','control','bracket','output','reordered','missing-producer'):
            with self.subTest(mode=mode):
                self.capture();root=self.top/'out'
                (root/'capture-producer.py').write_text('# recorded prior version\n')
                if mode in ('query','url'):
                    path=root/'02.request.json';v=json.loads(path.read_bytes())
                    if mode=='query':v['query']['uselang']='wrong'
                    else:v['url']='https://example.invalid/api.php'
                    path.write_bytes(m.e.encoded(v))
                elif mode=='receipt':
                    path=root/'02-01.receipt.json';v=json.loads(path.read_bytes());v['status']=503;path.write_bytes(m.e.encoded(v))
                elif mode in ('raw','control','bracket'):
                    number='03'if mode=='bracket'else'02';path=root/(number+'-01.raw.json');v=json.loads(path.read_bytes())
                    if mode=='bracket':v['query']['general']['generator']='changed server'
                    elif mode=='control':v['expandtemplates']['wikitext']=v['expandtemplates']['wikitext'].replace('pages-RAW=1234567','pages-RAW=1234568')
                    else:v['expandtemplates']['wikitext']=v['expandtemplates']['wikitext'].replace('pages=1,234,567','pages=9')
                    path.write_bytes(m.e.encoded(v));receipt=root/(number+'-01.receipt.json');rv=json.loads(receipt.read_bytes());rv.update(response_bytes=path.stat().st_size,response_sha256=m.digest(path.read_bytes()));receipt.write_bytes(m.e.encoded(rv))
                elif mode=='output':(root/m.OUTPUT).write_bytes(b'{}\n')
                elif mode=='missing-producer':(root/'date-numbering-helper.py').unlink()
                self.reseal(root,(lambda v:v['requests'].reverse())if mode=='reordered'else None)
                with self.assertRaises(ValueError):m.verify(root)
                # Existing capture() requires a fresh owned output directory.
                __import__('shutil').rmtree(root)

if __name__=='__main__':unittest.main()
