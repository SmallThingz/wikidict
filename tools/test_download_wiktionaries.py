import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import download_wiktionaries as d

class DownloaderTest(unittest.TestCase):
    def item(self):
        return dict(wiki='testwiktionary',date='20260901',name='test.bz2',url='https://dumps.wikimedia.org/testwiktionary/20260901/test.bz2',size=4,sha1=hashlib.sha1(b'data').hexdigest())
    def test_progress_includes_destination_and_fraction(self):
        item=self.item()
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/item['wiki']/item['date'];folder.mkdir(parents=True)
            (folder/(item['name']+'.part')).write_bytes(b'da')
            done,active,state=d.transfer_progress([item],root)
            self.assertEqual(done,2)
            self.assertIn('50.0%',d.progress_line(done,4,folder/item['name']))
            self.assertIn(str(folder/item['name']),d.progress_line(done,4,folder/item['name']))
            self.assertIn(str(root.resolve()),d.discovery_line(1,2,item['wiki'],root))
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
            def run(command, files, root):
                self.assertIn('--continue=true',command);self.assertIn('--split=1',command);self.assertIn('--max-concurrent-downloads=2',command)
                (folder/'test.bz2.part').write_bytes(b'data')
                return 0
            with patch.object(d.shutil,'which',return_value='/usr/bin/aria2c'),patch.object(d,'run_aria2',side_effect=run):d.download_all([item],root,2)
            self.assertEqual((folder/'test.bz2').read_bytes(),b'data')
    def test_incomplete_retains_resume_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);item=self.item();folder=root/item['wiki']/item['date'];folder.mkdir(parents=True)
            (folder/'test.bz2.part').write_bytes(b'da');(folder/'test.bz2.part.aria2').write_bytes(b'state')
            with patch.object(d.shutil,'which',return_value='/usr/bin/aria2c'),patch.object(d,'run_aria2',return_value=1):
                with self.assertRaises(SystemExit):d.download_all([item],root,2)
            self.assertTrue((folder/'test.bz2.part.aria2').exists());self.assertFalse((folder/'test.bz2').exists())
if __name__=='__main__':unittest.main()
