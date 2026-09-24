import bz2
import hashlib
import lzma
import json
import subprocess
import sys
import threading
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import build_wiktionaries as b
from compress_blobs import compress, default_workers

class BuildTest(unittest.TestCase):
    def test_in_and_out_aliases(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            source=root/'input';source.mkdir()
            item=dict(wiki='testwiktionary',date='20260901',name='testwiktionary-20260901-pages-meta-current.xml.bz2',url='https://dumps.wikimedia.org/testwiktionary/20260901/testwiktionary-20260901-pages-meta-current.xml.bz2',size=1,sha1='a'*40)
            (source/'manifest.json').write_text(json.dumps({'files':[item]}))
            output=root/'output'
            with patch.object(sys,'argv',['build_wiktionaries.py','--in',str(source),'--out',str(output),'--threads','2']),patch.object(b,'build') as build:
                b.main()
            self.assertEqual(build.call_args.args[1:4],(source.resolve(),output.resolve(),b.shutil.which('zig') or 'zig'))
            self.assertEqual(build.call_args.args[4],2)
    def test_editions_build_concurrently(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);source=root/'input';source.mkdir()
            items=[]
            for wiki in ('aawiktionary','abwiktionary'):
                name=f'{wiki}-20260901-pages-meta-current.xml.bz2'
                items.append(dict(wiki=wiki,date='20260901',name=name,url=f'https://dumps.wikimedia.org/{wiki}/20260901/{name}',size=1,sha1='a'*40))
            (source/'manifest.json').write_text(json.dumps({'files':items}))
            rendezvous=threading.Barrier(2)
            with patch.object(sys,'argv',['build_wiktionaries.py','--in',str(source),'--out',str(root/'output'),'--threads','2','--jobs','2']),patch.object(b,'build',side_effect=lambda *args:rendezvous.wait(timeout=2)) as build:
                b.main()
            self.assertEqual(build.call_count,2)
    def test_running_edition_is_not_removed_by_retry(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);parent=root/'testwiktionary';parent.mkdir()
            staging=parent/'20260901.building';staging.mkdir()
            sentinel=staging/'active';sentinel.write_text('keep')
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            item=dict(wiki='testwiktionary',date='20260901',name=name,url='https://dumps.wikimedia.org/testwiktionary/20260901/'+name,size=1,sha1='a'*40)
            with (parent/'20260901.lock').open('a') as lock:
                b.fcntl.flock(lock,b.fcntl.LOCK_EX | b.fcntl.LOCK_NB)
                with self.assertRaisesRegex(ValueError,'Build already running'):
                    b.build([item],root,root,'zig',2)
            self.assertEqual(sentinel.read_text(),'keep')
    def test_extreme_compression_roundtrip(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'test.wikblb';raw=b'WIKBLB08'+b'payload'*20000;path.write_bytes(raw)
            compress(path,64*1024,2)
            self.assertEqual(lzma.open(str(path)+'.xz').read(),raw)
    def test_default_worker_count(self):
        with patch('compress_blobs.os.cpu_count',return_value=12):
            self.assertEqual(default_workers(),5)
        with patch('compress_blobs.os.cpu_count',return_value=None):
            self.assertEqual(default_workers(),1)
    def test_fallback_report_validation_rejects_malformed_and_duplicate_pages(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'fallback-pages.jsonl'
            path.write_text('{broken\n')
            with self.assertRaisesRegex(ValueError,'Invalid fallback report JSON'):
                b.validate_fallback_report(path)
            page={'namespace':0,'title':'same','reasons':['literal_markup']}
            path.write_text(json.dumps(page)+'\n'+json.dumps(page)+'\n')
            with self.assertRaisesRegex(ValueError,'Duplicate fallback page'):
                b.validate_fallback_report(path)
            path.write_text(json.dumps({'namespace':0,'title':'x','reasons':['literal_markup','literal_markup']})+'\n')
            with self.assertRaisesRegex(ValueError,'Duplicate fallback reason'):
                b.validate_fallback_report(path)
    def test_build_verify_compress_publish(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            data=bz2.compress(b'<mediawiki/>');(folder/name).write_bytes(data)
            item=dict(wiki='testwiktionary',date='20260901',name=name,url='https://dumps.wikimedia.org/testwiktionary/20260901/'+name,size=len(data),sha1=hashlib.sha1(data).hexdigest())
            calls=[]
            real_run=subprocess.run
            def run(command,**kwargs):
                if command[0]=='xz': return real_run(command,**kwargs)
                calls.append(command)
                if 'build-dictionary' in command:
                    dest=Path(command[command.index('--')+2]);dest.mkdir();(dest/'en.wikblb').write_bytes(b'WIKBLB08payload')
                    (dest/'fallback-pages.jsonl').write_text(
                        json.dumps({'namespace':0,'title':'quoted"title','reasons':['literal_markup']})+'\n'+
                        json.dumps({'namespace':0,'title':'timeout','reasons':['expansion_error','expansion_error:Timeout']})+'\n')
            with patch.object(b,'PROJECT',root),patch.object(b.subprocess,'run',side_effect=run):
                b.build([item],root,root/'output','zig',2)
            self.assertIn('verify-blobs',calls[1]);self.assertTrue((root/'output/testwiktionary/20260901/complete.json').exists())
            self.assertIn('--llvm-workers',calls[0])
            final=root/'output/testwiktionary/20260901'
            metadata=json.loads((final/'complete.json').read_text())
            self.assertEqual(metadata['fallback_pages'],2)
            self.assertEqual(metadata['fallback_report'],'fallback-pages.jsonl')
            self.assertEqual(len((final/'fallback-pages.jsonl').read_text().splitlines()),2)
            self.assertFalse((final/'en.wikblb').exists())
            self.assertEqual(lzma.open(final/'en.wikblb.xz').read(),b'WIKBLB08payload')
            self.assertEqual(list((root/'.tmp').iterdir()),[])
    def test_verified_partial_compression_resumes_without_rebuilding(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            data=bz2.compress(b'<mediawiki/>');(folder/name).write_bytes(data)
            item=dict(wiki='testwiktionary',date='20260901',name=name,url='https://dumps.wikimedia.org/testwiktionary/20260901/'+name,size=len(data),sha1=hashlib.sha1(data).hexdigest())
            staging=root/'output/testwiktionary/20260901.building';staging.mkdir(parents=True)
            (staging/'fallback-pages.jsonl').write_text('')
            (staging/'languages.tsv').write_text('heading\n')
            (staging/b.VERIFIED_MARKER).write_text('verified\n')
            first=staging/'first.wikblb';second=staging/'second.wikblb'
            first.write_bytes(b'WIKBLB08first');second.write_bytes(b'WIKBLB08second')
            compress(first,64*1024,1);first.unlink()
            real_run=subprocess.run
            def run(command,**kwargs):
                if command[0]=='xz':return real_run(command,**kwargs)
                raise AssertionError(f'unexpected rebuild command: {command}')
            with patch.object(b,'PROJECT',root),patch.object(b.subprocess,'run',side_effect=run):
                b.build([item],root,root/'output','zig',1)
            final=root/'output/testwiktionary/20260901'
            meta=json.loads((final/'complete.json').read_text())
            self.assertEqual(meta['blobs'],2)
            self.assertFalse((final/b.VERIFIED_MARKER).exists())
            self.assertFalse((final/'first.wikblb').exists());self.assertFalse((final/'second.wikblb').exists())
            self.assertEqual(lzma.open(final/'first.wikblb.xz').read(),b'WIKBLB08first')
            self.assertEqual(lzma.open(final/'second.wikblb.xz').read(),b'WIKBLB08second')
    def test_empty_edition_retries_stale_build_and_is_published(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            data=bz2.compress(b'<mediawiki/>');(folder/name).write_bytes(data)
            item=dict(wiki='testwiktionary',date='20260901',name=name,url='https://dumps.wikimedia.org/testwiktionary/20260901/'+name,size=len(data),sha1=hashlib.sha1(data).hexdigest())
            stale=root/'output/testwiktionary/20260901.building';stale.mkdir(parents=True)
            (stale/'old').write_text('failed')
            def run(command,**kwargs):
                if 'build-dictionary' in command:
                    dest=Path(command[command.index('--')+2]);dest.mkdir();(dest/'fallback-pages.jsonl').write_text('')
            with patch.object(b,'PROJECT',root),patch.object(b.subprocess,'run',side_effect=run):
                b.build([item],root,root/'output','zig',2)
            final=root/'output/testwiktionary/20260901'
            self.assertEqual(json.loads((final/'complete.json').read_text())['status'],'empty')
            self.assertFalse((final/'old').exists())
if __name__=='__main__':unittest.main()
