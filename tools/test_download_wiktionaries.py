import hashlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import download_wiktionaries as d

class Response(io.BytesIO):
    def __init__(self, data, status=200, headers=None):
        super().__init__(data); self.status=status; self.headers=headers or {}

class DownloaderTest(unittest.TestCase):
    def test_resume_and_verify_existing_file(self):
        data=b"dictionary bytes"; item=dict(wiki="testwiktionary",date="20260901",name="test.bz2",url="https://example.test/dump",size=len(data),sha1=hashlib.sha1(data).hexdigest())
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); folder=root/item['wiki']/item['date'];folder.mkdir(parents=True)
            (folder/'test.bz2.part').write_bytes(data[:5])
            with patch.object(d,'request',return_value=Response(data[5:],206,{'Content-Range':f'bytes 5-{len(data)-1}/{len(data)}'})) as request:
                d.download(item,root);request.assert_called_once_with(item['url'],5)
            self.assertEqual((folder/'test.bz2').read_bytes(),data)
            with patch.object(d,'request') as request:
                d.download(item,root);request.assert_not_called()
    def test_range_ignored_restarts_cleanly(self):
        data=b'complete';item=dict(wiki='testwiktionary',date='20260901',name='test.bz2',url='https://example.test/dump',size=len(data),sha1=hashlib.sha1(data).hexdigest())
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/item['wiki']/item['date'];folder.mkdir(parents=True);(folder/'test.bz2.part').write_bytes(b'bad')
            with patch.object(d,'request',return_value=Response(data)):d.download(item,root)
            self.assertEqual((folder/'test.bz2').read_bytes(),data)
    def test_bad_resume_is_not_published(self):
        data=b'complete';item=dict(wiki='testwiktionary',date='20260901',name='test.bz2',url='https://example.test/dump',size=8,sha1=hashlib.sha1(data).hexdigest())
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/item['wiki']/item['date'];folder.mkdir(parents=True);(folder/'test.bz2.part').write_bytes(b'com')
            with patch.object(d,'request',return_value=Response(data,206,{'Content-Range':'bytes 0-7/8'})):
                with self.assertRaises(ValueError):d.download(item,root)
            self.assertFalse((folder/'test.bz2').exists())

if __name__=='__main__':unittest.main()
