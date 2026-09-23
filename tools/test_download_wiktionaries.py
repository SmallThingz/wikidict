import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import download_wiktionaries as d

class DownloaderTest(unittest.TestCase):
    def item(self):
        return dict(wiki='testwiktionary',date='20260901',name='test.bz2',url='https://dumps.wikimedia.org/testwiktionary/20260901/test.bz2',size=4,sha1=hashlib.sha1(b'data').hexdigest())
    def test_queue_has_checksum_and_partial_destination(self):
        queue=d.aria2_queue([self.item()],Path('data/dumps'))
        self.assertIn('out=test.bz2.part',queue)
        self.assertIn('checksum=sha-1='+self.item()['sha1'],queue)
    def test_queue_rejects_option_injection(self):
        item=self.item();item['name']='bad\n  dir=/elsewhere'
        with self.assertRaises(ValueError):d.aria2_queue([item],Path('data'))
    def test_verified_publication_and_bounded_connections(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);item=self.item();folder=root/item['wiki']/item['date'];folder.mkdir(parents=True)
            def run(command):
                self.assertIn('--continue=true',command);self.assertIn('--split=1',command);self.assertIn('--max-concurrent-downloads=2',command)
                (folder/'test.bz2.part').write_bytes(b'data')
                class Result:returncode=0
                return Result()
            with patch.object(d.shutil,'which',return_value='/usr/bin/aria2c'),patch.object(d.subprocess,'run',side_effect=run):d.download_all([item],root,2)
            self.assertEqual((folder/'test.bz2').read_bytes(),b'data')
    def test_incomplete_retains_resume_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);item=self.item();folder=root/item['wiki']/item['date'];folder.mkdir(parents=True)
            (folder/'test.bz2.part').write_bytes(b'da');(folder/'test.bz2.part.aria2').write_bytes(b'state')
            class Result:returncode=1
            with patch.object(d.shutil,'which',return_value='/usr/bin/aria2c'),patch.object(d.subprocess,'run',return_value=Result()):
                with self.assertRaises(SystemExit):d.download_all([item],root,2)
            self.assertTrue((folder/'test.bz2.part.aria2').exists());self.assertFalse((folder/'test.bz2').exists())
if __name__=='__main__':unittest.main()
