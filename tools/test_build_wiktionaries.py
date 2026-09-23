import bz2
import hashlib
import lzma
import subprocess
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import build_wiktionaries as b
from compress_blobs import compress

class BuildTest(unittest.TestCase):
    def test_extreme_compression_roundtrip(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'test.wikblb';raw=b'WIKBLB08'+b'payload'*20000;path.write_bytes(raw)
            compress(path,64*1024)
            self.assertEqual(lzma.open(str(path)+'.xz').read(),raw)
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
                    dest=Path(command[-1]);dest.mkdir();(dest/'en.wikblb').write_bytes(b'WIKBLB08payload')
            with patch.object(b,'PROJECT',root),patch.object(b.subprocess,'run',side_effect=run):
                b.build([item],root,root/'output','zig')
            self.assertIn('verify-blobs',calls[1]);self.assertTrue((root/'output/testwiktionary/20260901/complete.json').exists())
            self.assertFalse((root/'output/testwiktionary/20260901/en.wikblb').exists())
            self.assertEqual(lzma.open(root/'output/testwiktionary/20260901/en.wikblb.xz').read(),b'WIKBLB08payload')
            self.assertEqual(list((root/'.tmp').iterdir()),[])
if __name__=='__main__':unittest.main()
