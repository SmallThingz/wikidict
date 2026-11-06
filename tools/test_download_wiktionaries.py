import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import sys
import download_wiktionaries as d

class DownloaderTest(unittest.TestCase):
    def test_current_interwiki_capture_preserves_raw_response_and_flags(self):
        response={'query':{'general':{'interwikimagic':True},'interwikimap':[
            {'prefix':'en','local':True,'localinterwiki':True,'url':'https://en.wiktionary.org/wiki/$1','protorel':False,'language':'English'},
            {'prefix':'w','url':'//en.wikipedia.org/wiki/$1','protorel':True},
        ]}}
        raw=json.dumps(response,separators=(',',':')).encode()
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            with patch.object(d.urllib.request,'urlopen',return_value=io.BytesIO(raw)) as fetch:
                path,provenance=d.interwiki_map_snapshot('enwiktionary',root)
            self.assertEqual(fetch.call_args.kwargs['timeout'],30)
            self.assertEqual(d.urllib.parse.parse_qs(d.urllib.parse.urlparse(fetch.call_args.args[0].full_url).query)['siprop'],['general|interwikimap'])
            self.assertEqual(path.read_text().splitlines(),[
                '# interwiki-magic\t1',
                'en\t1\t1\t0\t0\thttps://en.wiktionary.org/wiki/$1\t1',
                'w\t0\t0\t1\t0\t//en.wikipedia.org/wiki/$1\t0',
            ])
            self.assertEqual((path.parent/'interwiki-map.raw.json').read_bytes(),raw)
            self.assertEqual(provenance['raw_sha256'],hashlib.sha256(raw).hexdigest())
            self.assertEqual(provenance['tsv_sha256'],hashlib.sha256(path.read_bytes()).hexdigest())
            self.assertIsNone(provenance['dump_date'])
            with patch.object(d.urllib.request,'urlopen',return_value=io.BytesIO(raw)):
                with self.assertRaisesRegex(ValueError,'already exists'):
                    d.interwiki_map_snapshot('enwiktionary',root)

    def test_current_interwiki_capture_rejects_invalid_and_oversized_response(self):
        for raw in (b'{"query":{"interwikimap":[]}}',
                    b'{"query":{"interwikimap":[{"prefix":"en","url":"x","local":"yes"}]}}',
                    b'x'*(2*1024*1024+1)):
            with self.subTest(raw_size=len(raw)),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp)
                with patch.object(d.urllib.request,'urlopen',return_value=io.BytesIO(raw)):
                    with self.assertRaises(ValueError): d.interwiki_map_snapshot('enwiktionary',root)
                self.assertFalse((root/'enwiktionary').exists())
    def test_interwiki_metadata_preserves_true_false_missing_and_extra_language_identity(self):
        rows=[{'prefix':'en','url':'https://en.example/$1','language':'English'},
              {'prefix':'extra','url':'https://extra.example/$1','extralanglink':True},
              {'prefix':'empty','url':'https://empty.example/$1','language':''},
              {'prefix':'local','url':'https://local.example/$1','local':True,'localinterwiki':True},
              {'prefix':'w','url':'//w.example/$1','protorel':True,'trans':True}]
        for magic in (True,False,None):
            query={'interwikimap':rows}
            if magic is not None:query['general']={'interwikimagic':magic}
            raw,count=d.render_interwiki_map({'query':query})
            lines=raw.decode().splitlines()
            if magic is None:self.assertFalse(any(line.startswith('# interwiki-magic')for line in lines))
            else:self.assertEqual(lines.pop(0),'# interwiki-magic\t'+str(int(magic)))
            self.assertEqual(count,5)
            self.assertEqual([line.split('\t')[-1]for line in lines],['1','1','0','0','0'])
            self.assertEqual(lines[3],'local\t1\t1\t0\t0\thttps://local.example/$1\t0')
            self.assertEqual(lines[4],'w\t0\t0\t1\t1\t//w.example/$1\t0')

    def test_interwiki_metadata_rejects_malformed_optional_flags_and_language(self):
        for field,values in [('language',[None,True,1,[],{}]),('extralanglink',[None,'1',1,[],{}])]:
            for value in values:
                with self.subTest(field=field,value=value),self.assertRaises(ValueError):
                    d.render_interwiki_map({'query':{'interwikimap':[dict(prefix='en',url='https://e/$1',**{field:value})]}})
        for value in (None,1,'true',[],{}):
            with self.subTest(magic=value),self.assertRaises(ValueError):
                d.render_interwiki_map({'query':{'general':{'interwikimagic':value},'interwikimap':[{'prefix':'en','url':'x'}]}})
        with self.assertRaises(ValueError):d.render_interwiki_map({'query':{'general':True,'interwikimap':[{'prefix':'en','url':'x'}]}})

    def test_retained_auxiliary_interwiki_writer_uses_same_metadata_contract(self):
        import prepare_auxiliary_snapshots as auxiliary
        data={'query':{'general':{'wikiid':'amwiktionary','interwikimagic':True},
                       'interwikimap':[{'prefix':'en','local':True,'language':'English','url':'https://en.wiktionary.org/wiki/$1'}]}}
        raw=json.dumps(data,separators=(',',':')).encode()
        record=dict(wiki='amwiktionary',retrieved_utc='2026-10-01T00:00:00Z',siteinfo_source_url='https://am.wiktionary.org/w/api.php',artifacts={'namespace-siteinfo.raw.json':hashlib.sha256(raw).hexdigest()})
        with tempfile.TemporaryDirectory() as tmp:
            capture=Path(tmp);(capture/'namespace-siteinfo.raw.json').write_bytes(raw)
            self.assertEqual(auxiliary.interwiki(capture,record),1)
            self.assertEqual((capture/'interwiki-map.raw.json').read_bytes(),raw)
            self.assertEqual((capture/'interwiki-map.tsv').read_text(),'# interwiki-magic\t1\nen\t1\t0\t0\t0\thttps://en.wiktionary.org/wiki/$1\t1\n')
            proof=json.loads((capture/'interwiki-map.provenance.json').read_text())
            self.assertEqual(proof['raw_sha256'],hashlib.sha256(raw).hexdigest())
            self.assertEqual(proof['tsv_sha256'],hashlib.sha256((capture/'interwiki-map.tsv').read_bytes()).hexdigest())

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
            base={'general':{'lang':'nl','linktrail':'/^([a-zäö]+)(.*)$/sDu'},'languages':[
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
            self.assertIn('# link-trail-ranges\t0061-007A,00E4,00F6\n',text)
            self.assertIn('nl\tNederlands\tnl\tDutch\tnld\tdut\n',text)
            self.assertIn('en\tEngels\tEnglish\ten\n',text)
            self.assertIn('aiw\tAari\taiw\n',text)

    def test_language_registry_rejects_inconsistent_siteinfo(self):
        base={'general':{'lang':'en','linktrail':'/^([a-z]+)(.*)$/sD'},'languages':[{'code':'en','name':'English'}]}
        localized={'languages':[{'code':'fr','name':'French'}]}
        with patch.object(d,'siteinfo',side_effect=[base,localized]),patch.object(d,'iso_639_3',return_value=[]):
            with self.assertRaisesRegex(ValueError,'Inconsistent localized'):
                d.language_registry_snapshot('enwiktionary')

    def test_linktrail_registry_canonicalizes_unicode_ranges(self):
        self.assertEqual(
            d.canonical_linktrail_ranges('/^([a-zабвгдеёжзийклмнопрстуфхцчшщъыьэюя]+)(.*)$/sDu'),
            '0061-007A,0430-044F,0451',
        )
        self.assertEqual(
            d.canonical_linktrail_ranges('/^([a-z\\x{0900}-\\x{0963}\\x{0966}-\\x{096F}]+)(.*)$/sDu'),
            '0061-007A,0900-0963,0966-096F',
        )
        self.assertEqual(d.canonical_linktrail_ranges('/^()(.*)$/sD'), '')
        ranges,sequences,guarded=d.canonical_linktrail_metadata("/^((?:c\\'h|c’h|[a-z])+)(.*)$/sDu")
        self.assertEqual(ranges,'0061-007A')
        self.assertEqual(sequences,'0063+0027+0068,0063+2019+0068')
        self.assertEqual(guarded,'')
        ranges,sequences,guarded=d.canonical_linktrail_metadata("/^((?:[a-zàèé]|'(?!'))+)(.*)$/sDu")
        self.assertEqual(ranges,'0061-007A,00E0,00E8-00E9')
        self.assertEqual(sequences,'')
        self.assertEqual(guarded,'0027')
        letters=d.canonical_linktrail_ranges(r'/^(\p{L}+)(.*)$/sDu')
        self.assertIn('0041-005A',letters)
        self.assertIn('0061-007A',letters)
        with self.assertRaisesRegex(ValueError, 'Unsupported MediaWiki linktrail'):
            d.canonical_linktrail_ranges('/^([a-z]+)$/u')
        for unsupported in (
            '/^([^a]+)(.*)$/sDu',
            '/^((?:c.h|[a-z])+)(.*)$/sDu',
            '/^((?:c^h|[a-z])+)(.*)$/sDu',
            '/^((?:c$h|[a-z])+)(.*)$/sDu',
            '/^([a-z]+)(.*)$/isDu',
        ):
            with self.subTest(pattern=unsupported), self.assertRaises(ValueError):
                d.canonical_linktrail_metadata(unsupported)

    def test_single_scalar_alternative_serializes_as_range(self):
        pattern='/^((?:ä|[a-z])+)(.*)$/sDu'
        self.assertEqual(d.canonical_linktrail_metadata(pattern),('0061-007A,00E4','',''))
        base={'general':{'lang':'en','linktrail':pattern},
              'languages':[{'code':'en','name':'English'}]}
        localized={'languages':[{'code':'en','name':'English'}]}
        with patch.object(d,'siteinfo',side_effect=[base,localized]), \
             patch.object(d,'iso_639_3',return_value=[]):
            _,text=d.language_registry_snapshot('enwiktionary')
        self.assertIn('# link-trail-ranges\t0061-007A,00E4\n',text)
        self.assertNotIn('# link-trail-sequences\t',text)

    def test_linktrail_ranges_reject_surrogate_scalars_and_crossings(self):
        for pattern in (
            r'/^([\x{D7FF}-\x{E000}]+)(.*)$/sDu',
            '/^([\ud800]+)(.*)$/sDu',
        ):
            with self.subTest(pattern=repr(pattern)), self.assertRaises(ValueError):
                d.canonical_linktrail_metadata(pattern)

    def test_wiktionary_api_translates_dump_edition_ids(self):
        self.assertEqual(d.wiktionary_api('zh_min_nanwiktionary'),'https://zh-min-nan.wiktionary.org/w/api.php')
        with self.assertRaises(ValueError):
            d.wiktionary_api('../badwiktionary')

    def test_resume_rejects_missing_registry_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            registry={'wiki':'testwiktionary','date':'20260901','name':'language-registry.tsv','content_language':'en','size':1,'sha256':'a'*64}
            (root/'manifest.json').write_text(__import__('json').dumps({'files':[self.item()],'language_registries':[registry]}))
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

class ReviewedRegistryDerivationTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.downloads=self.root/'downloads';self.downloads.mkdir()
        self.output=self.root/'derived'
        self.old=('# wikidict-language-registry-v2\n# content-language\tur\n# mediawiki\n'
                  'ur\tUrdu\tur\n# reviewed-alias\tur\tOld reviewed spelling\told-policy\t'+'0'*64+'\n').encode()
        self.row=d.write_language_registry(self.downloads,'testwiktionary','20261001',self.old.decode(),'ur')
        self.source=self.downloads/'testwiktionary/20261001/language-registry.tsv'
        item=dict(wiki='testwiktionary',date='20261001',name='testwiktionary-20261001-pages-meta-current.xml.bz2',
                  url=d.BASE+'/testwiktionary/20261001/testwiktionary-20261001-pages-meta-current.xml.bz2',size=4,sha1='a'*40)
        self.manifest=dict(requested_editions=['testwiktionary'],files=[item],language_registries=[self.row],
                           failures=[],auxiliary_capture_roots={})
        self.manifest_path=self.downloads/'manifest.json';self.manifest_path.write_text(json.dumps(self.manifest)+'\n')
        self.raw=self.manifest_path.read_bytes();self.sha=hashlib.sha256(self.raw).hexdigest()
        self.original_stat=self.source.stat()

    def derive(self, selected=None):
        return d.derive_reviewed_language_registries(self.manifest_path,self.sha,self.downloads,self.output,
                                                   ['testwiktionary'],selected)

    def test_stale_registry_derives_immutable_manifest_and_existing_profile_lineage(self):
        with self.assertRaisesRegex(ValueError,'Stale reviewed'):d.validate_registry_file(self.downloads,self.row)
        path=self.derive();document=json.loads(path.read_bytes())
        selected=d.derived_registry_paths(document,self.downloads)[('testwiktionary','20261001')]
        expected=d.append_reviewed_language_aliases(''.join(line for line in self.old.decode().splitlines(keepends=True)
                                                          if not line.startswith('# reviewed-alias'))).encode()
        self.assertEqual(selected.read_bytes(),expected)
        row=document['language_registries'][0]
        self.assertEqual(d.validate_registry_file(self.downloads,row,document),selected)
        self.assertEqual(document['files'],self.manifest['files'])
        self.assertEqual(self.source.read_bytes(),self.old);self.assertEqual(self.manifest_path.read_bytes(),self.raw)
        self.assertEqual(self.source.stat().st_ino,self.original_stat.st_ino)
        lineage=json.loads(Path(row['derived_registry_lineage']['path']).read_bytes())
        rows=json.loads(Path(row['derived_registry_manifest']['path']).read_bytes())
        self.assertEqual(lineage['status'],'PASS');self.assertTrue(lineage['original_bytes_inodes_preserved'])
        self.assertEqual(lineage['source_row'],self.row);self.assertEqual(lineage['source']['sha256'],self.row['sha256'])
        self.assertEqual(lineage['rows'],row['derived_registry_manifest']);self.assertEqual(rows[0]['sha256'],row['sha256'])
        self.assertEqual(lineage['target']['sha256'],row['sha256'])
        # The maintained resolver consumes only the authenticated derived path;
        # normal namespace and manifest checks remain in force.
        import build_wiktionaries as builder
        namespace=self.downloads/'testwiktionary/20261001/namespace-registry.tsv'
        namespace.write_text('# wikidict-namespace-registry-v1\n# wiki\ttestwiktionary\n# dump-date\t20261001\n0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tentries\n')
        actual=builder.resolve_edition_snapshot_options(document,{('testwiktionary','20261001'):[]},self.downloads)
        self.assertEqual(actual[('testwiktionary','20261001')]['auxiliary_snapshots']['language-registry'],selected)

    def test_source_authentication_tamper_conflicts_and_lineage_tamper_are_rejected(self):
        with self.assertRaisesRegex(ValueError,'authentication'):d.derive_reviewed_language_registries(
            self.manifest_path,'0'*64,self.downloads,self.output,['testwiktionary'])
        self.assertFalse(self.output.exists())
        self.source.write_bytes(self.old+b'changed')
        with self.assertRaisesRegex(ValueError,'differs from manifest'):self.derive()
        self.source.write_bytes(self.old)
        path=self.derive();document=json.loads(path.read_bytes())
        changed=json.loads(json.dumps(document));changed['language_registries'][0]['sha256']='0'*64
        with self.assertRaisesRegex(ValueError,'lineage or manifest'):d.derived_registry_paths(changed,self.downloads)
        selected=Path(document['language_registries'][0]['derived_registry']);selected.write_bytes(b'conflicting output')
        with self.assertRaisesRegex(ValueError,'Conflicting'):self.derive()
        self.assertEqual(selected.read_bytes(),b'conflicting output')
        self.assertEqual(self.source.read_bytes(),self.old);self.assertEqual(self.manifest_path.read_bytes(),self.raw)

    def test_exact_output_reconciliation_keeps_bytes_inodes_and_revalidates_authority(self):
        path=self.derive();files={str(p.relative_to(self.output)):(p.read_bytes(),p.stat().st_ino)for p in self.output.rglob('*')if p.is_file()}
        self.assertEqual(self.derive(),path)
        self.assertEqual(files,{str(p.relative_to(self.output)):(p.read_bytes(),p.stat().st_ino)for p in self.output.rglob('*')if p.is_file()})
        self.source.write_bytes(self.old.replace(b'Urdu',b'TAMP'))
        with self.assertRaisesRegex(ValueError,'differs from manifest'):self.derive()
        self.assertEqual(files,{str(p.relative_to(self.output)):(p.read_bytes(),p.stat().st_ino)for p in self.output.rglob('*')if p.is_file()})

    def test_explicit_capture_override_is_distinct_and_must_match_size_hash_and_header(self):
        capture=self.root/'captured-registry.tsv';captured=self.old.replace(b'Urdu',b'Captured Urdu')
        capture.write_bytes(captured);source=d._registry_reference(capture,captured)
        with patch.object(sys,'argv',['download_wiktionaries.py','--derive-reviewed-language-aliases',str(self.manifest_path),
                                     '--source-manifest-sha256',self.sha,'--output',str(self.output),
                                     '--source-registry',str(capture),'--source-registry-sha256',source['sha256']]), \
             patch.object(sys,'stderr',io.StringIO()):
            with self.assertRaises(SystemExit):d.main()
        self.assertFalse(self.output.exists())
        wrong=dict(source,sha256='0'*64)
        with self.assertRaisesRegex(ValueError,'descriptor mismatch'):self.derive(wrong)
        with self.assertRaisesRegex(ValueError,'descriptor mismatch'):self.derive(dict(source,bytes=len(captured)+1))
        bad=captured.replace(b'# content-language\tur',b'# content-language\tfr');capture.write_bytes(bad)
        with self.assertRaisesRegex(ValueError,'content language'):self.derive(d._registry_reference(capture,bad))
        capture.write_bytes(captured);path=self.derive(source);doc=json.loads(path.read_bytes())
        row=doc['language_registries'][0];lineage=json.loads(Path(row['derived_registry_lineage']['path']).read_bytes())
        self.assertTrue(lineage['explicit_capture_source']);self.assertEqual(lineage['source'],source)
        self.assertEqual(lineage['original_manifest_row'],self.row)
        self.assertNotEqual(lineage['source_row']['sha256'],self.row['sha256'])
        self.assertEqual(self.source.read_bytes(),self.old);self.assertEqual(capture.read_bytes(),captured)

    def test_maintained_cli_derives_then_resume_plan_uses_authenticated_manifest_without_network(self):
        with patch.object(sys,'argv',['download_wiktionaries.py','--derive-reviewed-language-aliases',str(self.manifest_path),
                                     '--source-manifest-sha256',self.sha,'--output',str(self.output),'--wikis','testwiktionary']), \
             patch.object(d,'snapshot',side_effect=AssertionError('no discovery')), \
             patch.object(d,'download_all',side_effect=AssertionError('no download')),patch('builtins.print'):
            d.main()
        path=self.output/'manifest.json';sha=hashlib.sha256(path.read_bytes()).hexdigest()
        with patch.object(sys,'argv',['download_wiktionaries.py','--resume','--plan','--output',str(self.downloads),
                                     '--input-manifest',str(path),'--input-manifest-sha256',sha,'--wikis','testwiktionary']), \
             patch.object(d,'download_all',side_effect=AssertionError('no download')),patch('builtins.print'):
            d.main()
        self.assertEqual(self.manifest_path.read_bytes(),self.raw)
        with self.assertRaisesRegex(ValueError,'Selected input manifest authentication'):d.load_input_manifest(path,'0'*64,self.downloads)


    def test_captured_resolver_uses_derived_registry_and_preserves_original_capture_guards(self):
        import build_wiktionaries as builder
        import namespace_registry_snapshot as namespace_projection
        from test_build_wiktionaries import write_magic_fixture
        import prepare_magic_words_int as int_magic
        import prepare_magic_words_language as language_magic
        import prepare_magic_words_lst as lst_magic
        root=self.root/'captured';root.mkdir();wiki,date='testwiktionary','20261001'
        item=self.manifest['files'][0]
        namespaces={str(i):dict(id=i,name=name,canonical=name,case='case-sensitive',content=i==0,
                                defaultcontentmodel='wikitext')for i,name in ((0,''),(10,'Template'),(14,'Category'))}
        inventory=[dict(id=row['id'],name=row['name'],case=row['case'])for row in namespaces.values()]
        query=dict(general=dict(wikiid=wiki,lang='ur',server='//test.wiktionary.org'),namespaces=namespaces,namespacealiases=[])
        xml=('<mediawiki><siteinfo><dbname>'+wiki+'</dbname><namespaces>'+''.join(
            '<namespace key="'+str(row['id'])+'" case="'+row['case']+'">'+row['name']+'</namespace>'
            for row in inventory)+'</namespaces></siteinfo></mediawiki>').encode()
        for name,raw in [('dump-siteinfo.xml',xml),('namespace-siteinfo.raw.json',json.dumps(dict(query=query)).encode()),
                         ('pagetable-dumpstatus.raw.json',b'{}'),('language-registry.tsv',self.old)]:
            (root/name).write_bytes(raw)
        sidecar=dict(wiki=wiki,date=date,output_sha256=hashlib.sha256(self.old).hexdigest())
        (root/'language-registry.manifest.json').write_text(json.dumps(sidecar))
        artifacts={name:builder.sha256_file(root/name)for name in ('dump-siteinfo.xml','namespace-siteinfo.raw.json',
                    'pagetable-dumpstatus.raw.json','language-registry.tsv','language-registry.manifest.json')}
        capture=dict(wiki=wiki,date=date,source_xml=item,namespace_mismatches=[],artifacts=artifacts,
                     dump_namespace_inventory=inventory,retrieved_utc='2026-10-18T00:00:00Z',
                     siteinfo_source_url='https://test.wiktionary.org/w/api.php',siteinfo_temporal_scope='synthetic-local-fixture')
        (root/'capture.complete.json').write_text(json.dumps(capture));namespace_projection.build(root)
        magic=write_magic_fixture(self.root/'magic-capture',wiki,date,parser_functions=True,content_language='ur',complete_magic_projection=True)
        int_root=magic.parent.parent/int_magic.DERIVED_DIRECTORY;int_magic.derive_snapshot(magic,int_root)
        language_root=magic.parent.parent/language_magic.DERIVED_DIRECTORY;language_magic.derive_snapshot(int_root,language_root)
        lst_magic.derive_snapshot(language_root,root/lst_magic.DERIVED_DIRECTORY)
        self.manifest['auxiliary_capture_roots']={wiki:'captured'}
        self.manifest_path.write_text(json.dumps(self.manifest)+'\n');self.raw=self.manifest_path.read_bytes();self.sha=hashlib.sha256(self.raw).hexdigest()
        path=self.derive();document=json.loads(path.read_bytes());selected=Path(document['language_registries'][0]['derived_registry'])
        options=builder.resolve_edition_snapshot_options(document,{(wiki,date):[item]},self.downloads,workspace=self.root)
        self.assertEqual(options[(wiki,date)]['auxiliary_snapshots']['language-registry'],selected)
        self.assertEqual((root/'language-registry.tsv').read_bytes(),self.old)
        with self.assertRaisesRegex(ValueError,'differs from pinned inventory'):
            builder.resolve_edition_snapshot_options(document,{(wiki,date):[item]},self.downloads,
                {'language-registry':root/'language-registry.tsv'},workspace=self.root)
        # Selecting the new registry must not exempt original captured artifacts.
        (root/'pagetable-dumpstatus.raw.json').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError,'changed capture artifact'):
            builder.resolve_edition_snapshot_options(document,{(wiki,date):[item]},self.downloads,workspace=self.root)


    def test_multi_edition_resume_authenticates_derivative_once_and_keeps_outputs_unchanged(self):
        other='otherwiktionary'
        other_old=self.old.replace(b'Urdu',b'Second Urdu')
        other_row=d.write_language_registry(self.downloads,other,'20261001',other_old.decode(),'ur')
        item=dict(self.manifest['files'][0],wiki=other,name=other+'-20261001-pages-meta-current.xml.bz2',
                  url=d.BASE+'/'+other+'/20261001/'+other+'-20261001-pages-meta-current.xml.bz2')
        self.manifest['requested_editions'].append(other);self.manifest['files'].append(item)
        self.manifest['language_registries'].append(other_row)
        self.manifest_path.write_text(json.dumps(self.manifest)+'\n')
        self.raw=self.manifest_path.read_bytes();self.sha=hashlib.sha256(self.raw).hexdigest()
        path=d.derive_reviewed_language_registries(self.manifest_path,self.sha,self.downloads,self.output,['testwiktionary',other])
        before={str(p.relative_to(self.output)):(p.read_bytes(),p.stat().st_ino)for p in self.output.rglob('*')if p.is_file()}
        document=json.loads(path.read_bytes());sha=hashlib.sha256(path.read_bytes()).hexdigest()
        with patch.object(sys,'argv',['download_wiktionaries.py','--resume','--plan','--output',str(self.downloads),
                                     '--input-manifest',str(path),'--input-manifest-sha256',sha,
                                     '--wikis','testwiktionary',other]), \
             patch.object(d,'derived_registry_paths',wraps=d.derived_registry_paths) as authenticated, \
             patch.object(d,'_reviewed_registry_plan',wraps=d._reviewed_registry_plan) as plans, \
             patch.object(d,'_validate_registry_file_path',wraps=d._validate_registry_file_path) as files, \
             patch.object(d,'download_all',side_effect=AssertionError('no download')),patch('builtins.print'):
            d.main()
        self.assertEqual(authenticated.call_count,1);self.assertEqual(plans.call_count,1)
        self.assertEqual(files.call_count,2)
        self.assertEqual({call.args[0]for call in files.call_args_list},
                         {Path(row['derived_registry'])for row in document['language_registries']})
        self.assertEqual(before,{str(p.relative_to(self.output)):(p.read_bytes(),p.stat().st_ino)for p in self.output.rglob('*')if p.is_file()})
        self.assertEqual(self.manifest_path.read_bytes(),self.raw);self.assertEqual(self.source.read_bytes(),self.old)
        self.assertEqual((self.downloads/other/'20261001/language-registry.tsv').read_bytes(),other_old)
        # The public API still authenticates lineage; it accepts no trusted map.
        forged=json.loads(json.dumps(document));forged['language_registries'][0]['derived_registry']=str(self.source)
        with self.assertRaisesRegex(ValueError,'lineage or manifest'):
            d.validate_registry_file(self.downloads,forged['language_registries'][0],forged)


if __name__=='__main__':unittest.main()

class ManifestSelectionTest(unittest.TestCase):
    @staticmethod
    def file(wiki):
        return dict(wiki=wiki,date='20261001',name=wiki+'-20261001-pages-meta-current.xml.bz2',url='https://dumps.wikimedia.org/'+wiki+'/20261001/'+wiki+'-20261001-pages-meta-current.xml.bz2',size=4,sha1='a'*40)
    def test_all_fails_on_discovery_failure_and_missing_inventory(self):
        files=[self.file('enwiktionary')]
        with self.assertRaisesRegex(ValueError,'Incomplete edition discovery'):
            d.select_manifest_files(dict(files=files,failures=['frwiktionary: unavailable']))
        with self.assertRaisesRegex(ValueError,'Unknown editions'):
            d.select_manifest_files(dict(files=files,requested_editions=['enwiktionary','frwiktionary']))
    def test_explicit_subset_does_not_download_unrequested_editions(self):
        en=self.file('enwiktionary');fr=self.file('frwiktionary')
        self.assertEqual(d.select_manifest_files(dict(files=[en,fr]),['enwiktionary']),[en])
        self.assertEqual(d.select_manifest_files(dict(files=[en],requested_editions=['enwiktionary','frwiktionary'],failures=['frwiktionary: unavailable']),['enwiktionary']),[en])
        with self.assertRaisesRegex(ValueError,'Selected edition discovery failed'):
            d.select_manifest_files(dict(files=[en],failures=['enwiktionary: unavailable']),['enwiktionary'])
    def test_empty_and_undeclared_manifests_are_not_success(self):
        with self.assertRaises(ValueError):d.select_manifest_files(dict(files=[]))
        with self.assertRaisesRegex(ValueError,'undeclared'):
            d.select_manifest_files(dict(files=[self.file('enwiktionary')],requested_editions=['frwiktionary']))
    def test_required_jobs_include_page_table_for_category_tree(self):
        self.assertIn('pagetable',d.JOBS)
