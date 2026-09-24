import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import sys
import download_wiktionaries as d

class DownloaderTest(unittest.TestCase):
    def item(self):
        return dict(wiki='testwiktionary',date='20260901',name='test.bz2',url='https://dumps.wikimedia.org/testwiktionary/20260901/test.bz2',size=4,sha1=hashlib.sha1(b'data').hexdigest())
    def test_output_exists_before_snapshot_discovery(self):
        with tempfile.TemporaryDirectory() as tmp:
            output=Path(tmp)/'new'/'dumps'
            def snapshot(wiki,jobs):
                self.assertTrue(output.is_dir())
                return [self.item()]
            registry='# wikidict-language-registry-v2\n# content-language\ten\n# mediawiki\nen\tEnglish\ten\n# iso-639-3\neng\tEnglish\teng\n'
            with patch.object(sys,'argv',['download_wiktionaries.py','--out',str(output),'--wikis','testwiktionary','--plan']),patch.object(d,'snapshot',side_effect=snapshot),patch.object(d,'language_registry_snapshot',return_value=('en',registry)):
                d.main()
            manifest=__import__('json').loads((output/'manifest.json').read_text())
            self.assertEqual(manifest['language_registries'][0]['content_language'],'en')
            self.assertTrue((output/'testwiktionary/20260901/language-registry.tsv').is_file())
    def test_language_registry_combines_site_and_iso_aliases(self):
        with tempfile.TemporaryDirectory() as tmp:
            iso=Path(tmp)/'iso.json'
            iso.write_text(__import__('json').dumps({'639-3':[
                {'alpha_3':'nld','alpha_2':'nl','bibliographic':'dut','name':'Dutch','scope':'I','type':'L'},
                {'alpha_3':'aiw','name':'Aari','scope':'I','type':'L'},
            ]}))
            base={'general':{'lang':'nl'},'languages':[
                {'code':'nl','name':'Nederlands'},
                {'code':'en','name':'English'},
            ]}
            localized={'languages':[
                {'code':'nl','name':'Nederlands'},
                {'code':'en','name':'Engels'},
            ]}
            with patch.object(d,'siteinfo',side_effect=[base,localized]):
                content,text=d.language_registry_snapshot('nlwiktionary',iso)
            self.assertEqual(content,'nl')
            self.assertIn('# content-language\tnl\n',text)
            self.assertIn('nl\tNederlands\tnl\tDutch\tnld\tdut\n',text)
            self.assertIn('en\tEngels\tEnglish\ten\n',text)
            self.assertIn('aiw\tAari\taiw\n',text)

    def test_language_registry_rejects_inconsistent_siteinfo(self):
        base={'general':{'lang':'en'},'languages':[{'code':'en','name':'English'}]}
        localized={'languages':[{'code':'fr','name':'French'}]}
        with patch.object(d,'siteinfo',side_effect=[base,localized]),patch.object(d,'iso_639_3',return_value=[]):
            with self.assertRaisesRegex(ValueError,'Inconsistent localized'):
                d.language_registry_snapshot('enwiktionary')

    def test_wiktionary_api_translates_dump_edition_ids(self):
        self.assertEqual(d.wiktionary_api('zh_min_nanwiktionary'),'https://zh-min-nan.wiktionary.org/w/api.php')
        with self.assertRaises(ValueError):
            d.wiktionary_api('../badwiktionary')

    def test_resume_rejects_missing_registry_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            registry={'wiki':'testwiktionary','date':'20260901','name':'language-registry.tsv','content_language':'en','size':1,'sha256':'a'*64}
            (root/'manifest.json').write_text(__import__('json').dumps({'files':[],'language_registries':[registry]}))
            with patch.object(sys,'argv',['download_wiktionaries.py','--out',str(root),'--resume','--plan']):
                with self.assertRaisesRegex(ValueError,'Missing or unverified language registry'):
                    d.main()

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
