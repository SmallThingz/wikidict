import bz2
import concurrent.futures
import contextlib
from compression import zstd
import hashlib
import io
import lzma
import json
import os
import subprocess
import sys
import threading
from pathlib import Path
import tempfile
import time
import unittest
import urllib.parse
from unittest.mock import patch
from types import SimpleNamespace
import build_wiktionaries as b
import build_resource_limits as limits
from compress_blobs import compress, compress_many, default_workers

def write_namespace_fixture(folder, edition=None, date=None):
    folder.mkdir(parents=True,exist_ok=True)
    edition=edition or (folder.parent.name if folder.name.isdigit() else 'testwiktionary')
    date=date or (folder.name if folder.name.isdigit() else '20260901')
    namespace=folder/'namespace-registry.tsv'
    namespace.write_text('# wikidict-namespace-registry-v1\n# wiki\t'+edition+'\n# dump-date\t'+date+'\n# content-language\ten\n0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tentries\n10\tTemplate\tTemplate\tcase-sensitive\t1\t0\t0\t\tcompile_only\tinput\n14\tCategory\tCategory\tcase-sensitive\t0\t0\t0\t\tcompile_only\tinput\n')
    language=folder/'language-registry.tsv'
    if not language.exists():language.write_text('# content-language\ten\nen\tEnglish\n')
    return {'namespace-registry':namespace,'language-registry':language}


def write_magic_fixture(folder, edition='arwiktionary', date='20261001', observation='first', alias='اسم_الصفحة', parser_functions=False):
    import prepare_magic_words as magic
    folder.mkdir(parents=True,exist_ok=True)
    namespace=magic.document({'query':{'general':{'wikiid':edition,'lang':'ar'}}})
    (folder/'namespace-siteinfo.raw.json').write_bytes(namespace)
    (folder/'capture.complete.json').write_bytes(magic.document(dict(wiki=edition,date=date,
        artifacts={'namespace-siteinfo.raw.json':magic.digest(namespace)})))
    words=[{'name':name,'case-sensitive':True,'aliases':[name.upper()]+([alias] if name=='pagename' else [])}
           for name in sorted(magic.SUPPORTED)]
    if parser_functions:
        words += [{'name':name,'aliases':[name]+(['استدعاء'] if name=='invoke' else [])}
                  for name in sorted(magic.PARSER_FUNCTIONS)]
    raw=magic.document({'query':{'general':{'wikiid':edition,'lang':'ar','sitename':observation},'magicwords':words}})
    def fetcher(url):
        return raw,dict(source_url=url,response_url=url,status=200,
            started_utc='2026-10-05T00:00:00+00:00',retrieved_utc='2026-10-05T00:00:01+00:00',
            raw_sha256=magic.digest(raw),raw_bytes=len(raw))
    magic.capture_snapshot(folder,edition,date,fetcher=fetcher)
    return folder/'magic-words'/'magic-words.tsv'


def write_wikibase_capture_fixture(folder, minute='01'):
    from test_prepare_wikibase_entities import WikibaseCaptureTests
    fixture=WikibaseCaptureTests()
    fetcher=fixture.fetcher()
    def fetch(url):
        raw,receipt=fetcher(url)
        receipt['retrieved_utc']='2026-10-05T09:'+minute+':01+00:00'
        return raw,receipt
    fixture.capture(folder,fetcher=fetch)
    return {name:folder/'wikibase-entities'/(name+'.tsv')
            for name in ('wikibase-entities','wikibase-entity-terms')}


def write_language_messages_fixture(folder):
    import prepare_language_messages as messages
    namespace=write_namespace_fixture(folder,'arwiktionary','20261001')['namespace-registry']
    namespace.write_text(namespace.read_text().replace('# content-language\ten\n','# content-language\tar\n'))
    args=SimpleNamespace(wiki='arwiktionary',date='20261001',namespace_registry=namespace,
        output=folder/'language-messages',languages=['ar'],messages=['parentheses'],delay=0,wall_seconds=30)
    def transport(url,timeout):
        params=urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)
        query={'general':{'wikiid':'arwiktionary','lang':'ar'}}
        if params['meta']==['siteinfo|languageinfo']:
            query['languageinfo']={code:{'code':code,'fallbacks':[]} for code in ('ar','en')}
        elif params['meta']==['siteinfo|allmessages']:
            query['allmessages']=[{'name':'parentheses','normalizedname':'parentheses','content':'($1)','default':'($1)'}]
        else:
            raise AssertionError('Unexpected fixture request')
        return 200,{'content-type':'application/json'},json.dumps({'query':query}).encode()
    with contextlib.redirect_stdout(io.StringIO()):
        messages.capture(args,transport=transport)
    return {name:args.output/(name+'.tsv') for name in ('language-fallbacks','interface-messages')}


def write_test_manifest(root, manifest):
    records=[]
    for item in manifest.get('files',[]):
        if not isinstance(item,dict) or not item.get('wiki') or not item.get('date'):continue
        folder=root/item['wiki']/item['date']
        snapshots=write_namespace_fixture(folder,item['wiki'],item['date'])
        path=snapshots['language-registry']
        records.append(dict(wiki=item['wiki'],date=item['date'],name=path.name,size=path.stat().st_size,sha256=b.sha256_file(path)))
    manifest=dict(manifest,language_registries=list({(r['wiki'],r['date']):r for r in records}.values()))
    (root/'manifest.json').write_text(json.dumps(manifest))


def decode_staged_dump(dump):
    compressed=dump.read_bytes()
    offsets=[int(line.split(':',1)[0]) for line in bz2.decompress(
        dump.with_name('pages-index.txt.bz2').read_bytes()).decode().splitlines()]
    frames=[compressed[start:end] for start,end in zip(offsets,offsets[1:]+[len(compressed)])]
    for frame in frames:
        assert zstd.get_frame_size(frame)==len(frame)
        assert zstd.get_frame_info(frame).decompressed_size<=64*1024*1024
    return b''.join(zstd.decompress(frame) for frame in frames)


def write_namespace_coverage(root, count):
    (root/'languages').mkdir(exist_ok=True)
    if not (root/'fallback-pages.jsonl').exists():(root/'fallback-pages.jsonl').write_text('')
    if not (root/'languages.tsv').exists():(root/'languages.tsv').write_text('heading\n')
    rows=[] if count==0 else [dict(id=0,name='',kind='language',input_rows=count,compile_only_rows=0,source_unavailable_rows=0,dispatched_rows=count,expanded_pages=count,fallback_pages=0,duplicate_rows=0)]
    candidates=list(b.PROJECT.glob('*wiktionary/[0-9]*/namespace-registry.tsv'))
    record=dict(version=1,namespaces=rows)
    if len(candidates)==1:record['registry_sha256']=b.sha256_file(candidates[0])
    (root/'namespace-coverage.json').write_text(json.dumps(record))


def write_coverage(root, command=None):
    if command and '--shard-pages' in command:
        index=Path(command[command.index('--expander-root')+1])/'page-index.tsv'
        inspected=b.inspect_page_index(index)
        start=int(command[command.index('--start-page')+1])
        total=int(command[command.index('--limit-pages')+1])
        step=int(command[command.index('--shard-pages')+1])
        for shard_start in range(start,start+total,step):
            shard=root/f'{shard_start:08d}'
            shard.mkdir(parents=True,exist_ok=True)
            record=dict(version=1,start_page=shard_start,
                        requested_limit=min(step,start+total-shard_start),
                        pages_seen=min(step,start+total-shard_start),
                        index_byte_offset=inspected['offsets'][shard_start],
                        page_index_identity=inspected['identity'])
            (shard/'page-coverage.json').write_text(json.dumps(record))
            write_namespace_coverage(shard,record['pages_seen'])
        return
    start=limit=offset=0
    identity=dict(device_major=0,device_minor=0,inode=0,size=0,mtime_ns=0)
    if command and '--expander-root' in command:
        index=Path(command[command.index('--expander-root')+1])/'page-index.tsv'
        identity=b.index_identity(index.stat())
        start=int(command[command.index('--start-page')+1])
        limit=int(command[command.index('--limit-pages')+1])
        offset=int(command[command.index('--index-byte-offset')+1])
    else: limit=None
    record=dict(version=1,start_page=start,requested_limit=limit,pages_seen=limit or 0,
                index_byte_offset=offset,page_index_identity=identity)
    if limit is None: record['expected_input_pages']=0
    (root/'page-coverage.json').write_text(json.dumps(record))
    write_namespace_coverage(root,record['pages_seen'])


class ProvenanceBindingTests(unittest.TestCase):
    def test_paired_captures_pin_every_validated_artifact_once_without_network(self):
        import prepare_language_messages as messages
        import prepare_wikibase_entities as entities
        for fixture,helper in ((write_wikibase_capture_fixture,entities),(write_language_messages_fixture,messages)):
            with self.subTest(helper=helper.__name__),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);snapshots=fixture(root/'capture')
                first=next(iter(snapshots.values()))
                inventory=helper.capture_artifacts(first)
                with patch.object(entities,'fetch_response',side_effect=AssertionError('unexpected network')), \
                        patch.object(messages.evidence,'get_response',side_effect=AssertionError('unexpected network')):
                    hashes=b.verified_auxiliary_hashes(snapshots,'arwiktionary','20261001')
                    manifests,artifacts=b.auxiliary_capture_identities(snapshots)
                    destination=root/'pinned'
                    with patch.object(b,'copy_verified_snapshot',wraps=b.copy_verified_snapshot) as copy:
                        pinned=b.pinned_auxiliary_snapshots(snapshots,hashes,destination,manifests,artifacts)
                    self.assertEqual(copy.call_count,len(inventory))
                    self.assertEqual(set(p.name for p in destination.iterdir()),set(inventory))
                    self.assertEqual(hashes,b.verified_auxiliary_hashes(pinned,'arwiktionary','20261001'))
                    for name,digest in inventory.items():self.assertEqual(b.sha256_file(destination/name),digest)
                    raw=next(destination/name for name in inventory if name.endswith('.raw.json'))
                    raw.chmod(0o644);raw.write_bytes(raw.read_bytes()+b' ')
                    with self.assertRaises(ValueError):b.verified_auxiliary_hashes(pinned)

    def test_capture_receipts_bind_build_shard_and_publication_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);first=write_wikibase_capture_fixture(root/'first')
            other=write_wikibase_capture_fixture(root/'other',minute='02')
            hashes=b.verified_auxiliary_hashes(first)
            self.assertEqual(hashes,b.verified_auxiliary_hashes(other))
            tool=root/'zig';tool.write_bytes(b'tool')
            registry=root/'language.tsv';registry.write_text('ar\tالعربية\n')
            item=dict(wiki='arwiktionary',date='20261001',name='dump',size=1,sha1='a')
            with patch.object(b.shutil,'which',return_value=str(tool)),patch.object(b,'source_fingerprint',return_value='source'):
                identity=b.build_input_identity([item],'zig',hashes,None,None,first)
                changed=b.build_input_identity([item],'zig',hashes,None,None,other)
                self.assertNotEqual(b.shard_state([item],registry,auxiliary_snapshots=first),
                                    b.shard_state([item],registry,auxiliary_snapshots=other))
            self.assertLess(len(json.dumps(identity)),64*1024)
            for digest in identity['auxiliary_capture_artifact_sha256'].values():self.assertRegex(digest,r'^[0-9a-f]{64}$')
            with self.assertRaisesRegex(ValueError,'Build inputs or compiler changed'):b.require_build_identity(identity,changed)
            b.require_auxiliary_capture_identity(first,identity)
            with self.assertRaisesRegex(ValueError,'capture changed during build'):b.require_auxiliary_capture_identity(other,identity)
            with self.assertRaisesRegex(ValueError,'capture changed before pinning'):
                b.pinned_auxiliary_snapshots(other,hashes,root/'rejected',identity['auxiliary_capture_sha256'],
                    identity['auxiliary_capture_artifact_sha256'])
            self.assertFalse((root/'rejected').exists())

    def test_mixed_paired_capture_generations_reject_before_copying(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);first=write_wikibase_capture_fixture(root/'first')
            other=write_wikibase_capture_fixture(root/'other',minute='02')
            mixed={'wikibase-entities':first['wikibase-entities'],'wikibase-entity-terms':other['wikibase-entity-terms']}
            with self.assertRaisesRegex(ValueError,'Conflicting auxiliary capture artifact'):
                b.pinned_auxiliary_snapshots(mixed,b.verified_auxiliary_hashes(mixed),root/'rejected')
            self.assertFalse((root/'rejected').exists())

    def test_preferred_capture_generations_fail_closed_and_bind_outer_namespace(self):
        for fixture,directory,names in (
                (write_wikibase_capture_fixture,'wikibase-entities',('wikibase-entities','wikibase-entity-terms')),
                (write_language_messages_fixture,'language-messages',('language-fallbacks','interface-messages'))):
            with self.subTest(directory=directory),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);self.assertEqual(b.discover_auxiliary_generation(root,directory,names,'arwiktionary','20261001'),{})
                outer=root/'capture';snapshots=fixture(outer)
                self.assertEqual(b.discover_auxiliary_generation(outer,directory,names,'arwiktionary','20261001'),snapshots)
                capture={'wiki':'arwiktionary','date':'20261001'}
                for name,path in snapshots.items():b.validate_captured_snapshot(name,path,capture,[],outer)
                original=outer/('capture.complete.json' if directory=='wikibase-entities' else 'namespace-registry.tsv')
                if directory=='language-messages':
                    b.verified_auxiliary_hashes({**snapshots,'namespace-registry':original})
                original.write_bytes(original.read_bytes()+b' ')
                with self.assertRaisesRegex(ValueError,'namespace source differs'):
                    b.validate_captured_snapshot(names[0],snapshots[names[0]],capture,[],outer)
                if directory=='language-messages':
                    with self.assertRaisesRegex(ValueError,'different namespace registry'):
                        b.verified_auxiliary_hashes({**snapshots,'namespace-registry':original})
                manifest=snapshots[names[1]].with_name(names[1]+'.manifest.json')
                manifest.unlink()
                with self.assertRaises((ValueError,OSError)):
                    b.discover_auxiliary_generation(outer,directory,names,'arwiktionary','20261001')
                link=root/'linked';link.mkdir();(link/directory).symlink_to(outer/directory,target_is_directory=True)
                with self.assertRaisesRegex(ValueError,'Unsafe auxiliary capture generation'):
                    b.discover_auxiliary_generation(link,directory,names,'arwiktionary','20261001')

    def test_legacy_interface_messages_remain_supported_and_schema_cannot_downgrade(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);legacy=root/'interface-messages.tsv';legacy.write_text('en\tparentheses\t($1)\n')
            expected={'interface-messages':b.sha256_file(legacy)}
            self.assertEqual(b.verified_auxiliary_hashes({'interface-messages':legacy}),expected)
            legacy_manifest=legacy.with_name('interface-messages.manifest.json')
            record=dict(wiki='arwiktionary',date='20261001',output_sha256=expected['interface-messages'])
            legacy_manifest.write_text(json.dumps(record))
            self.assertEqual(b.verified_auxiliary_hashes({'interface-messages':legacy},'arwiktionary','20261001'),expected)
            legacy_manifest.write_text(json.dumps(dict(record,schema='unsupported-capture-version')))
            with self.assertRaises(ValueError):b.verified_auxiliary_hashes({'interface-messages':legacy})
            snapshots=write_language_messages_fixture(root/'capture')
            manifests,artifacts=b.auxiliary_capture_identities(snapshots)
            first=snapshots['interface-messages'];sidecar=first.with_name('interface-messages.manifest.json')
            modern=json.loads(sidecar.read_bytes());del modern['schema'];sidecar.chmod(0o644);sidecar.write_text(json.dumps(modern))
            with self.assertRaises(ValueError):
                b.discover_auxiliary_generation(root/'capture','language-messages',
                    ('language-fallbacks','interface-messages'),'arwiktionary','20261001')
            with self.assertRaisesRegex(ValueError,'capture disappeared before pinning'):
                b.pinned_auxiliary_snapshots({'interface-messages':first},
                    {'interface-messages':b.sha256_file(first)},root/'rejected',manifests,artifacts)
            self.assertFalse((root/'rejected').exists())

    def test_source_identity_checks_every_selected_field(self):
        item=dict(wiki='testwiktionary',date='20261001',name='testwiktionary-20261001-page.sql.gz',url='https://example.test/page.sql.gz',size=1,sha1='a'*40)
        self.assertEqual(b.selected_source(item,[item]),item)
        for field in b.SOURCE_FIELDS:
            bad=dict(item);bad[field]=2 if field=='size' else 'changed'
            with self.subTest(field=field),self.assertRaises(ValueError):b.selected_source(bad,[item])
        with self.assertRaises(ValueError):b.selected_source(item,[item,item])

    def test_capture_artifacts_are_complete_safe_and_hash_bound(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);path=root/'site.json';path.write_text('{}')
            record={'artifacts':{'site.json':b.sha256_file(path)}}
            b.validate_capture_artifacts(root,record,('site.json',))
            with self.assertRaises(ValueError):b.validate_capture_artifacts(root,record,('missing.json',))
            path.write_text('{"changed":true}')
            with self.assertRaises(ValueError):b.validate_capture_artifacts(root,record)
            for name in ('../site.json','/site.json','.'):
                with self.subTest(name=name),self.assertRaises(ValueError):b.validate_capture_artifacts(root,{'artifacts':{name:'x'}})

    def test_build_identity_refuses_source_dump_and_deadline_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);tool=root/'zig';tool.write_bytes(b'tool')
            item=dict(wiki='testwiktionary',date='20261001',name='dump',size=1,sha1='a')
            with patch.object(b.shutil,'which',return_value=str(tool)),patch.object(b,'source_fingerprint',return_value='source'):
                identity=b.build_input_identity([item],'zig',{'namespace-registry':'n'},'i',100)
                b.persist_build_identity(root,identity)
                b.require_build_identity(b.read_small_json(root/b.BUILD_IDENTITY_NAME),identity)
                changed=b.build_input_identity([dict(item,sha1='b')],'zig',{'namespace-registry':'n'},'i',100)
                with self.assertRaises(ValueError):b.require_build_identity(changed,identity)
                changed=b.build_input_identity([item],'zig',{'namespace-registry':'n'},'i',101)
                with self.assertRaises(ValueError):b.require_build_identity(changed,identity)
            with patch.object(b,'source_fingerprint',return_value='changed'),self.assertRaises(ValueError):b.persist_build_identity(root,identity)
            self.assertEqual(b.read_small_json(root/b.BUILD_IDENTITY_NAME),identity)

    def test_expander_reuse_is_bound_to_interwiki_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);exp=root/'.bundle-expander';exp.mkdir()
            (root/'.incomplete').write_text('expander ready')
            for name in ('page-index.tsv','dict-bundle-expander','namespace-registry.tsv'):(exp/name).write_text('fixture')
            self.assertTrue(b.expander_ready(root))
            path=exp/'interwiki-map.tsv';path.write_text('map')
            digest=b.sha256_file(path)
            self.assertFalse(b.expander_ready(root))
            self.assertTrue(b.expander_ready(root,interwiki_sha=digest))
            path.write_text('changed')
            self.assertFalse(b.expander_ready(root,interwiki_sha=digest))

    def test_title_magic_snapshot_identity_invalidates_resumed_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);tool=root/'zig';tool.write_bytes(b'tool')
            item=dict(wiki='arwiktionary',date='20261001',name='dump',size=1,sha1='a')
            with patch.object(b.shutil,'which',return_value=str(tool)),patch.object(b,'source_fingerprint',return_value='source'):
                original=b.build_input_identity([item],'zig',{'magic-words':'first-capture'},None,None)
                changed=b.build_input_identity([item],'zig',{'magic-words':'changed-aliases'},None,None)
                with self.assertRaisesRegex(ValueError,'Build inputs or compiler changed'):
                    b.require_build_identity(original,changed)

    def test_title_magic_capture_is_pinned_and_raw_observation_is_bound(self):
        import prepare_magic_words as magic
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);tool=root/'zig';tool.write_bytes(b'tool')
            first=write_magic_fixture(root/'first')
            other=write_magic_fixture(root/'other',observation='second')
            snapshots={'magic-words':first}
            hashes=b.verified_auxiliary_hashes(snapshots,'arwiktionary','20261001')
            self.assertEqual(hashes,b.verified_auxiliary_hashes({'magic-words':other}))
            item=dict(wiki='arwiktionary',date='20261001',name='dump',size=1,sha1='a')
            with patch.object(b.shutil,'which',return_value=str(tool)),patch.object(b,'source_fingerprint',return_value='source'):
                original=b.build_input_identity([item],'zig',hashes,None,None,snapshots)
                changed=b.build_input_identity([item],'zig',hashes,None,None,{'magic-words':other})
            with self.assertRaisesRegex(ValueError,'Build inputs or compiler changed'):
                b.require_build_identity(original,changed)
            destination=root/'pinned';destination.mkdir()
            pinned=b.pinned_auxiliary_snapshots(snapshots,hashes,destination,original['auxiliary_capture_sha256'])
            self.assertEqual(hashes,b.verified_auxiliary_hashes(pinned))
            self.assertEqual(set(path.name for path in destination.iterdir()),magic.ARTIFACTS|{'magic-words.manifest.json'})
            with self.assertRaises(ValueError):
                b.pinned_auxiliary_snapshots({'magic-words':other},hashes,destination,original['auxiliary_capture_sha256'])
            raw=destination/'magic-words.raw.json';raw.write_bytes(raw.read_bytes()+b' ')
            with self.assertRaisesRegex(ValueError,'Changed magic-word capture artifact'):
                b.verified_auxiliary_hashes(pinned)

    def test_title_magic_alias_change_invalidates_shards_and_expander_reuse(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            first=write_magic_fixture(root/'first')
            other=write_magic_fixture(root/'other',alias='اسم_آخر')
            language=root/'language.tsv';language.write_text('ar\tالعربية\n')
            item=dict(wiki='arwiktionary',date='20261001',name='dump',size=1,sha1='a')
            snapshots={'magic-words':first};changed={'magic-words':other}
            with patch.object(b,'source_fingerprint',return_value='source'):
                self.assertNotEqual(b.shard_state([item],language,auxiliary_snapshots=snapshots),
                                    b.shard_state([item],language,auxiliary_snapshots=changed))
            exp=root/'.bundle-expander';exp.mkdir();(root/'.incomplete').write_text('expander ready')
            for name in ('page-index.tsv','dict-bundle-expander','namespace-registry.tsv'):(exp/name).write_text('fixture')
            (exp/'magic-words.tsv').write_bytes(first.read_bytes())
            self.assertTrue(b.expander_ready(root,b.verified_auxiliary_hashes(snapshots)))
            self.assertFalse(b.expander_ready(root,b.verified_auxiliary_hashes(changed)))

    def test_expanded_magic_capture_pins_embedded_original_and_binds_profile_identity(self):
        import prepare_magic_words as magic
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); tool=root/'zig'; tool.write_bytes(b'tool')
            original=write_magic_fixture(root/'capture',parser_functions=True)
            expanded=root/'capture'/magic.DERIVED_DIRECTORY
            manifest,_=magic.derive_snapshot(original,expanded)
            self.assertEqual(magic.selected_snapshot_root(root/'capture'),expanded)
            snapshots={'magic-words':expanded/'magic-words.tsv'}
            hashes=b.verified_auxiliary_hashes(snapshots,'arwiktionary','20261001')
            item=dict(wiki='arwiktionary',date='20261001',name='dump',size=1,sha1='a')
            with patch.object(b.shutil,'which',return_value=str(tool)),patch.object(b,'source_fingerprint',return_value='source'):
                identity=b.build_input_identity([item],'zig',hashes,None,None,snapshots)
                old=b.build_input_identity([item],'zig',b.verified_auxiliary_hashes({'magic-words':original}),None,None,{'magic-words':original})
            with self.assertRaisesRegex(ValueError,'Build inputs or compiler changed'):
                b.require_build_identity(identity,old)
            destination=root/'pinned'; destination.mkdir()
            pinned=b.pinned_auxiliary_snapshots(snapshots,hashes,destination,identity['auxiliary_capture_sha256'])
            self.assertEqual(magic.validate_snapshot(pinned['magic-words']),manifest)
            self.assertEqual(set(path.name for path in destination.iterdir()),magic.DERIVED_ARTIFACTS|{'magic-words.manifest.json'})
            for name in magic.DERIVED_ARTIFACTS:
                self.assertEqual((destination/name).read_bytes(),(expanded/name).read_bytes())
            source_manifest=destination/magic.SOURCE_MANIFEST
            source_manifest.write_bytes(source_manifest.read_bytes()+b' ')
            with self.assertRaisesRegex(ValueError,'Changed magic-word capture artifact'):
                b.verified_auxiliary_hashes(pinned)


class BuildTest(unittest.TestCase):
    def test_main_routes_interwiki_and_dated_auxiliary_snapshot_flags(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            name='enwiktionary-20260901-pages-meta-current.xml.bz2'
            item=dict(wiki='enwiktionary',date='20260901',name=name,
                      url='https://dumps.wikimedia.org/enwiktionary/20260901/'+name,
                      size=1,sha1='a'*40)
            write_test_manifest(root,{'files':[item]})
            interwiki=root/'interwiki-map.tsv';interwiki.write_text('en\t1\t1\t0\t0\tx\n')
            category=root/'category-stats.tsv';category.write_text('x\t1\t0\t0\n')
            argv=['build_wiktionaries.py','--downloads',str(root),'--output',str(root/'out'),
                  '--wikis','enwiktionary','--threads','1','--jobs','1',
                  '--interwiki-map-snapshot',str(interwiki),
                  '--category-stats-snapshot',str(category)]
            with patch.object(sys,'argv',argv),patch.object(b,'safe_worker_budget',return_value=4), \
                 patch.object(b,'build_groups',return_value=[]) as groups:
                b.main()
            self.assertEqual(groups.call_args.kwargs,{
                'interwiki_snapshot':interwiki.resolve(),
                'edition_options':{('enwiktionary','20260901'):{'interwiki_snapshot':interwiki.resolve(),'auxiliary_snapshots':{'category-stats':category.resolve(),**{k:v.resolve() for k,v in write_namespace_fixture(root/'enwiktionary/20260901').items()}}}},
            })

    def test_watchdog_mode_is_explicit_locked_and_deadline_bounded(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            def supervised(**kwargs):
                self.assertEqual(kwargs,{'wall_seconds':7200,'disk_paths':(root/'.tmp',root/'data/dictionaries')})
                with self.assertRaises(limits.ContainmentUnavailable):
                    b.acquire_build_resource_lock(root/'.tmp/build-resources.lock')
                return 0
            with patch.object(b,'PROJECT',root),patch.object(sys,'argv',['build_wiktionaries.py','--resource-mode=watchdog']),patch.object(limits,'inside_watchdog',return_value=False),patch.object(limits,'supervise_watchdog',side_effect=supervised) as watchdog,patch.object(limits,'supervise') as strict,patch.object(b,'main') as main:
                with self.assertRaises(SystemExit) as result:b.cli()
                self.assertEqual(result.exception.code,0)
            watchdog.assert_called_once_with(wall_seconds=7200,disk_paths=(root/'.tmp',root/'data/dictionaries'))
            strict.assert_not_called();main.assert_not_called()

    def test_eight_expansion_workers_request_eight_cpu_watchdog(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch.object(b,'PROJECT',Path(tmp)),patch.object(sys,'argv',[
                'build_wiktionaries.py','--resource-mode=watchdog','--expansion-workers=8']), \
                 patch.object(limits,'inside_watchdog',return_value=False), \
                 patch.object(limits,'supervise_watchdog',return_value=0) as watchdog:
                with self.assertRaises(SystemExit) as result:b.cli()
                self.assertEqual(result.exception.code,0)
            watchdog.assert_called_once_with(wall_seconds=7200,disk_paths=(Path(tmp)/'.tmp',Path(tmp)/'data/dictionaries'),max_cpus=8)

    def test_high_expansion_count_keeps_single_job_and_four_build_workers(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);write_test_manifest(root,{'files':[dict(wiki='testwiktionary',date='20261001',name='test.xml.bz2',url='https://dumps.wikimedia.org/testwiktionary/20261001/test.xml.bz2',size=1,sha1='a'*40)]})
            argv=['build_wiktionaries.py','--resource-mode=watchdog','--downloads',str(root),
                  '--output',str(root),'--threads','4','--expansion-workers','8']
            with patch.object(sys,'argv',argv),patch.object(b,'safe_worker_budget',return_value=5), \
                 patch.object(b.os,'sched_getaffinity',return_value=set(range(8))), \
                 patch.object(b,'build_groups',return_value=[]) as groups:
                b.main()
            self.assertEqual(groups.call_args.args[4:],(4,1,8))
            with patch.object(sys,'argv',argv+['--jobs','2']),patch.object(b,'safe_worker_budget',return_value=5), \
                 patch.object(b.os,'sched_getaffinity',return_value=set(range(8))):
                with self.assertRaises(SystemExit):b.main()
            with patch.object(sys,'argv',[x for x in argv if x!='--resource-mode=watchdog']), \
                 patch.object(b,'safe_worker_budget',return_value=5):
                with self.assertRaises(SystemExit):b.main()

    def test_expansion_workers_within_four_charge_the_actual_job_budget(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);write_test_manifest(root,{'files':[dict(wiki='testwiktionary',date='20261001',name='test.xml.bz2',url='https://dumps.wikimedia.org/testwiktionary/20261001/test.xml.bz2',size=1,sha1='a'*40)]})
            argv=['build_wiktionaries.py','--downloads',str(root),'--output',str(root),
                  '--threads','1','--expansion-workers','4']
            with patch.object(sys,'argv',argv+['--jobs','2']), \
                 patch.object(b,'safe_worker_budget',return_value=5):
                with self.assertRaises(SystemExit):b.main()
            with patch.object(sys,'argv',argv),patch.object(b,'safe_worker_budget',return_value=5), \
                 patch.object(b,'build_groups',return_value=[]) as groups:
                b.main()
            self.assertEqual(groups.call_args.args[4:],(1,1,4))

    def test_dynamic_queue_charges_expansion_workers_within_four(self):
        groups={(f'wiki{n}','20260901'):[{'wiki':f'wiki{n}'}] for n in range(2)}
        started=[]
        gate=threading.Event()
        def fake_build(group,*args,**kwargs):
            started.append(group[0]['wiki']);gate.wait(0.2)
        release=threading.Timer(0.05,gate.set)
        release.start()
        try:
            with patch.object(b,'safe_worker_budget',return_value=5) as budget, \
                 patch.object(b,'build',side_effect=fake_build):
                failures=b.build_groups(groups,Path('.'),Path('.'),'zig',1,2,4)
        finally:
            gate.set();release.join()
        self.assertEqual(failures,[])
        self.assertEqual(len(started),2)
        self.assertIn(4,[call.args[0] for call in budget.call_args_list])

    def test_merge_disk_rejection_preserves_verified_shards_before_native_merge(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);workspace=root/'work';exp=workspace/'expander/.bundle-expander'
            exp.mkdir(parents=True)
            (workspace/'expander/.incomplete').write_text('expander ready')
            (exp/'page-index.tsv').write_text('p0\n')
            (exp/'dict-bundle-expander').write_text('worker');write_namespace_fixture(exp)
            cache=workspace/'input';cache.mkdir()
            (cache/'.complete.json').write_text(json.dumps({'source_pages':1}))
            calls=[]
            def run(command):
                calls.append(command)
                if 'build-blobs' in command:
                    dest=Path(command[command.index('--')+2]);dest.mkdir(exist_ok=True)
                    write_coverage(dest,command)
                elif 'merge-blobs' in command:
                    self.fail('Native merge must not start without admitted disk space')
            with patch.object(b,'run_checked',side_effect=run), \
                 patch('build_disk_limits.os.statvfs',return_value=SimpleNamespace(f_bavail=0,f_frsize=4096)):
                with self.assertRaisesRegex(ValueError,'Insufficient merge disk space'):
                    b.build_sharded(root/'dump',root/'staging',workspace,root/'registry','zig',1,
                                    [{'wiki':'test','date':'20260901'}],123)
            shard=workspace/'shards/00000000'
            self.assertEqual((shard/'.verified').read_text(),'verified\n')
            self.assertEqual(json.loads((shard/'page-coverage.json').read_text())['pages_seen'],1)
            self.assertTrue((shard/'namespace-coverage.json').is_file())
            self.assertFalse((root/'staging').exists())
            self.assertFalse(any('merge-blobs' in command for command in calls))

    def test_sharded_expansion_workers_do_not_widen_compiler_workers(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);workspace=root/'work';exp=workspace/'expander/.bundle-expander';exp.mkdir(parents=True)
            (exp/'page-index.tsv').write_text('# index\n\np0\n')
            (exp/'dict-bundle-expander').write_text('worker');write_namespace_fixture(exp)
            cache=workspace/'input';cache.mkdir();(cache/'.complete.json').write_text(json.dumps({
                'source_pages':1,'dump_sha256':'a'*64,'index_sha256':'b'*64}))
            calls=[]
            def run(command):
                calls.append(command)
                if 'build-dictionary' in command:
                    exp.mkdir(parents=True,exist_ok=True)
                    (exp/'page-index.tsv').write_text('# index\n\np0\n')
                    (exp/'dict-bundle-expander').write_text('worker');write_namespace_fixture(exp)
                if 'build-blobs' in command:
                    dest=Path(command[command.index('--')+2]);dest.mkdir(exist_ok=True);write_coverage(dest,command)
                if 'merge-blobs' in command:
                    Path(command[command.index('--')+1]).mkdir()
            with patch.object(b,'run_checked',side_effect=run):
                b.build_sharded(root/'dump',root/'staging',workspace,root/'registry','zig',4,
                                [{'wiki':'test','date':'20260901'}],123,8,expansion_timeout_ms=600000)
            compiler=next(c for c in calls if 'build-dictionary' in c)
            blob=next(c for c in calls if 'build-blobs' in c)
            self.assertEqual(compiler[compiler.index('--llvm-workers')+1],'4')
            self.assertEqual(compiler[compiler.index('--parse-workers')+1],'4')
            self.assertEqual(compiler[compiler.index('--page-workers')+1],'4')
            self.assertEqual(blob[blob.index('--workers')+1],'8')
            self.assertEqual(blob[blob.index('--expansion-timeout-ms')+1],'600000')

    def test_only_verified_watchdog_child_enters_main(self):
        with patch.object(sys,'argv',['build_wiktionaries.py','--resource-mode','watchdog']),patch.object(limits,'inside_watchdog',return_value=True),patch.object(limits,'inside_envelope') as envelope,patch.object(limits,'supervise_watchdog') as watchdog,patch.object(b,'main') as main:
            b.cli()
            main.assert_called_once();watchdog.assert_not_called();envelope.assert_not_called()
        with patch.object(sys,'argv',['build_wiktionaries.py','--resource-mode=watchdog']),patch.object(limits,'inside_watchdog',side_effect=limits.ContainmentUnavailable('invalid watchdog marker')),patch.object(limits,'supervise_watchdog') as watchdog,patch.object(b,'main') as main:
            with self.assertRaisesRegex(SystemExit,'invalid watchdog marker'):b.cli()
            main.assert_not_called();watchdog.assert_not_called()

    def test_default_mode_never_falls_back_to_watchdog(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch.object(b,'PROJECT',Path(tmp)),patch.object(sys,'argv',['build_wiktionaries.py']),patch.object(limits,'inside_watchdog',return_value=False),patch.object(limits,'inside_envelope',return_value=False),patch.object(limits,'supervise',side_effect=limits.ContainmentUnavailable('cgroup required')),patch.object(limits,'supervise_watchdog') as watchdog,patch.object(b,'main') as main:
                with self.assertRaisesRegex(SystemExit,'cgroup required'):b.cli()
                watchdog.assert_not_called();main.assert_not_called()

    def test_page_index_offsets_hash_and_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'index';data=b'# header\n\na\nb\n# skip\nc\n';path.write_bytes(data)
            with patch.object(b,'SHARD_PAGES',2): result=b.inspect_page_index(path)
            self.assertEqual(result['rows'],3)
            self.assertEqual(result['offsets'],{0:0,2:data.index(b'c\n')})
            self.assertEqual(result['sha256'],hashlib.sha256(data).hexdigest())
            b.require_index_identity(path,result)
            path.write_bytes(data+b'd\n')
            with self.assertRaisesRegex(ValueError,'changed'): b.require_index_identity(path,result)

    def test_index_and_coverage_read_sizes_are_bounded(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);path=root/'index';path.write_bytes(b'x'*65)
            with patch.object(b,'MAX_PAGE_INDEX_LINE_BYTES',64):
                with self.assertRaisesRegex(ValueError,'line exceeds'): b.inspect_page_index(path)
            (root/'page-coverage.json').write_bytes(b' '*65)
            with patch.object(b,'MAX_PAGE_COVERAGE_BYTES',64):
                with self.assertRaisesRegex(ValueError,'Missing or invalid'): b.validate_page_coverage(root)

    def test_full_receipt_requires_explicit_limit_and_verified_total(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);write_coverage(root);path=root/'page-coverage.json'
            valid=json.loads(path.read_text())
            for field in ('requested_limit','expected_input_pages'):
                broken=dict(valid);del broken[field];path.write_text(json.dumps(broken))
                with self.assertRaises(ValueError): b.validate_page_coverage(root,require_total=True)
            for extra in ({'pages_seen':1},{'expected_input_pages':True},{'page_index_rows':1}):
                path.write_text(json.dumps(dict(valid,**extra)))
                with self.assertRaises(ValueError): b.validate_page_coverage(root,require_total=True)

    def test_default_threads_respects_pipeline_cap_when_budget_is_eight(self):
        with patch.object(b,'safe_worker_budget',return_value=8):
            self.assertEqual(b.default_build_threads(),4)

    def test_page_coverage_rejects_missing_truncated_wrong_selection_and_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            with self.assertRaisesRegex(ValueError,'Missing'): b.validate_page_coverage(root)
            write_coverage(root)
            path=root/'page-coverage.json';record=json.loads(path.read_text())
            record.update(start_page=2,requested_limit=3,pages_seen=3,index_byte_offset=8)
            expected=dict(rows=5,identity=record['page_index_identity'])
            path.write_text(json.dumps(record))
            b.validate_page_coverage(root,2,3,expected,8)
            for field,value,message in [('pages_seen',2,'Incomplete'),('start_page',1,'selection'),('index_byte_offset',7,'selection'),('pages_seen',True,'Invalid')]:
                broken=dict(record);broken[field]=value;path.write_text(json.dumps(broken))
                with self.assertRaisesRegex(ValueError,message): b.validate_page_coverage(root,2,3,expected,8)
            broken=dict(record,page_index_identity=dict(record['page_index_identity'],inode=99))
            path.write_text(json.dumps(broken))
            with self.assertRaisesRegex(ValueError,'identity mismatch'): b.validate_page_coverage(root,2,3,expected,8)

    def test_full_coverage_must_match_source_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);write_coverage(root)
            b.validate_page_coverage(root,source_pages=0)
            with self.assertRaisesRegex(ValueError,'Incomplete'): b.validate_page_coverage(root,source_pages=1)

    def test_missing_resumed_receipt_rebuilds_shard_with_bounded_workers(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);workspace=root/'work';exp=workspace/'expander/.bundle-expander';exp.mkdir(parents=True)
            (workspace/'expander/.incomplete').write_text('expander ready')
            (exp/'page-index.tsv').write_text('# index\n\np0\n')
            (exp/'dict-bundle-expander').write_text('worker');write_namespace_fixture(exp)
            cache=workspace/'input';cache.mkdir();(cache/'.complete.json').write_text(json.dumps({'source_pages':1}))
            shard=workspace/'shards/00000000';shard.mkdir(parents=True);(shard/'.verified').write_text('verified')
            calls=[]
            def run(command):
                calls.append(command)
                if 'build-blobs' in command:
                    dest=Path(command[command.index('--')+2]);dest.mkdir(exist_ok=True);write_coverage(dest,command)
                if 'merge-blobs' in command:
                    Path(command[command.index('--')+1]).mkdir()
            with patch.object(b,'run_checked',side_effect=run):
                b.build_sharded(root/'dump',root/'staging',workspace,root/'registry','zig',8,[{'wiki':'test','date':'20260901'}],123)
            builds=[c for c in calls if 'build-blobs' in c]
            self.assertEqual(len(builds),1)
            self.assertEqual(builds[0][builds[0].index('--workers')+1],'4')
            self.assertEqual(builds[0][builds[0].index('--index-byte-offset')+1],'0')
            self.assertEqual(json.loads((root/'staging/page-coverage.json').read_text())['pages_seen'],1)

    def test_partial_shard_with_live_writer_pid_is_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            shards=Path(tmp)
            active=shards/f'.00000000.part-{os.getpid()}'
            active.mkdir();(active/'sentinel').write_text('active')
            with self.assertRaisesRegex(ValueError,'PID still exists'):
                b.cleanup_dead_private_shards(shards)
            self.assertEqual((active/'sentinel').read_text(),'active')

    def test_partial_shard_with_absent_writer_pid_is_cleaned(self):
        with tempfile.TemporaryDirectory() as tmp:
            shards=Path(tmp)
            stale=shards/'.00000000.part-999999999'
            stale.mkdir();(stale/'sentinel').write_text('stale')
            b.cleanup_dead_private_shards(shards)
            self.assertFalse(stale.exists())

    def test_resumed_prefix_verifier_failure_preserves_valid_shard(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);workspace=root/'work';exp=workspace/'expander/.bundle-expander'
            exp.mkdir(parents=True)
            (workspace/'expander/.incomplete').write_text('expander ready')
            (exp/'page-index.tsv').write_text('p0\n')
            (exp/'dict-bundle-expander').write_text('worker');write_namespace_fixture(exp)
            cache=workspace/'input';cache.mkdir()
            (cache/'.complete.json').write_text(json.dumps({'source_pages':1}))
            shard=workspace/'shards/00000000';shard.mkdir(parents=True)
            command=['--expander-root',str(exp),'--start-page','0',
                     '--limit-pages','1','--index-byte-offset','0']
            write_coverage(shard,command)
            (shard/'.verified').write_text('verified\n')
            (shard/'sentinel').write_text('retain')
            calls=[]
            def run(command):
                calls.append(command)
                if 'verify-blobs' in command:
                    raise subprocess.CalledProcessError(137,command)
                self.fail('No rebuild or merge should follow a verifier tool failure')
            with patch.object(b,'run_checked',side_effect=run):
                with self.assertRaises(subprocess.CalledProcessError):
                    b.build_sharded(root/'dump',root/'staging',workspace,root/'registry','zig',4,
                                    [{'wiki':'test','date':'20260901'}],123)
            self.assertEqual((shard/'sentinel').read_text(),'retain')
            self.assertTrue((shard/'page-coverage.json').is_file())
            self.assertFalse(any('build-blobs' in c or 'merge-blobs' in c for c in calls))
            with patch.object(b,'require_index_identity',side_effect=ValueError('index changed')):
                with self.assertRaisesRegex(ValueError,'index changed'):
                    b.build_sharded(root/'dump',root/'staging',workspace,root/'registry','zig',4,
                                    [{'wiki':'test','date':'20260901'}],123)
            self.assertEqual((shard/'sentinel').read_text(),'retain')

    def test_noncontiguous_resumed_verifier_failure_preserves_later_shard(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);workspace=root/'work';exp=workspace/'expander/.bundle-expander'
            exp.mkdir(parents=True)
            (workspace/'expander/.incomplete').write_text('expander ready')
            (exp/'page-index.tsv').write_text('p0\np1\np2\n')
            (exp/'dict-bundle-expander').write_text('worker');write_namespace_fixture(exp)
            cache=workspace/'input';cache.mkdir()
            (cache/'.complete.json').write_text(json.dumps({'source_pages':3}))
            shards=workspace/'shards';shards.mkdir()
            with patch.object(b,'SHARD_PAGES',1):
                offsets=b.inspect_page_index(exp/'page-index.tsv')['offsets']
            for start in (0,2):
                shard=shards/f'{start:08d}';shard.mkdir()
                command=['--expander-root',str(exp),'--start-page',str(start),
                         '--limit-pages','1','--index-byte-offset',str(offsets[start])]
                write_coverage(shard,command)
                (shard/'.verified').write_text('verified\n')
            (shards/'00000002/sentinel').write_text('retain')
            calls=[]
            def run(command):
                calls.append(command)
                if 'build-blobs' in command:
                    dest=Path(command[command.index('--')+2]);dest.mkdir()
                    write_coverage(dest,command)
                elif 'verify-blobs' in command and str(shards/'00000002') in command:
                    raise subprocess.CalledProcessError(137,command)
                elif 'merge-blobs' in command:
                    self.fail('Merge must not run after a verifier failure')
            with patch.object(b,'SHARD_PAGES',1),patch.object(b,'run_checked',side_effect=run):
                with self.assertRaises(subprocess.CalledProcessError):
                    b.build_sharded(root/'dump',root/'staging',workspace,root/'registry','zig',4,
                                    [{'wiki':'test','date':'20260901'}],123)
            self.assertEqual((shards/'00000002/sentinel').read_text(),'retain')
            self.assertFalse(any('merge-blobs' in c for c in calls))

    def test_verified_publication_missing_coverage_preserves_staging(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);staging=root/'staging';staging.mkdir()
            (staging/b.VERIFIED_MARKER).write_text(b.VERIFIED_CONTENT)
            with self.assertRaisesRegex(ValueError,'Missing or invalid page coverage'):
                b._publish_verified_staging(staging,root/'final','test','20260901',1)
            self.assertTrue((staging/b.VERIFIED_MARKER).exists())
            self.assertFalse((root/'final').exists())

    def test_timed_native_command_logs_success_and_preserves_command(self):
        command=['zig','build','build-blobs','--','dump','shard']
        output=io.StringIO()
        with patch.object(b,'run_checked') as run, patch('sys.stdout',output), \
             patch.object(b.time,'monotonic',side_effect=[10.0,12.5]):
            b.timed_run(command,'enwiktionary','20260901','shard_build',
                        start_page=100000,pages=100000,attempt=2)
        run.assert_called_once_with(command)
        events=[json.loads(line.removeprefix('BUILD_PHASE ')) for line in output.getvalue().splitlines()]
        self.assertEqual([record['event'] for record in events],['start','end'])
        self.assertEqual(events[0]['edition'],'enwiktionary')
        self.assertEqual(events[0]['date'],'20260901')
        self.assertEqual(events[0]['start_page'],100000)
        self.assertEqual(events[0]['attempt'],2)
        self.assertEqual(events[1]['status'],'success')
        self.assertEqual(events[1]['seconds'],2.5)

    def test_timed_native_command_preserves_failure_even_if_logging_breaks(self):
        command=['zig','build','build-blobs','--','dump','shard']
        failure=subprocess.CalledProcessError(3,command)
        output=io.StringIO()
        with patch.object(b,'run_checked',side_effect=failure) as run, patch('sys.stdout',output):
            with self.assertRaises(subprocess.CalledProcessError) as raised:
                b.timed_run(command,'enwiktionary','20260901','shard_build',attempt=1)
        self.assertIs(raised.exception,failure)
        run.assert_called_once_with(command)
        events=[json.loads(line.removeprefix('BUILD_PHASE ')) for line in output.getvalue().splitlines()]
        self.assertEqual(events[1]['status'],'failure')
        with patch.object(b,'run_checked',side_effect=failure) as run, \
             patch('builtins.print',side_effect=BrokenPipeError('closed log')):
            with self.assertRaises(subprocess.CalledProcessError) as raised:
                b.timed_run(command,'enwiktionary','20260901','shard_build',attempt=1)
        self.assertIs(raised.exception,failure)
        run.assert_called_once_with(command)

    def test_phase_logging_preserves_manifest_validation_errors(self):
        for build in (b.build,b.build_locked):
            failure=ValueError('invalid manifest item')
            with self.subTest(build=build.__name__), \
                 patch.object(b,'validate_item',side_effect=failure), \
                 patch('sys.stdout',io.StringIO()):
                with self.assertRaises(ValueError) as raised:
                    build([{}],Path('unused'),Path('unused'),'zig',1)
            self.assertIs(raised.exception,failure)

    def test_phase_logging_preserves_empty_cached_input_error(self):
        with tempfile.TemporaryDirectory() as tmp, patch('sys.stdout',io.StringIO()):
            with self.assertRaisesRegex(ValueError,'No dump parts'):
                b.cached_shard_dump([],Path(tmp),Path(tmp))

    def test_large_batch_compression_removes_verified_raw(self):
        with tempfile.TemporaryDirectory() as tmp:
            raw=Path(tmp)/'large.wikblb'
            payload=b'WIKBLB08'+b'x'*4096
            raw.write_bytes(payload)
            compress_many([raw],64*1024,1,small_limit=1)
            target=Path(str(raw)+'.xz')
            self.assertFalse(raw.exists())
            self.assertEqual(lzma.open(target).read(),payload)
    def test_language_registry_is_generated_once_and_cached(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            with patch.object(b,'language_registry_snapshot',return_value=('en','# content-language\ten\nen\tEnglish\n')) as generate:
                first=b.ensure_language_registry(root,root/'output','testwiktionary','20260901')
                second=b.ensure_language_registry(root,root/'output','testwiktionary','20260901')
            self.assertEqual(first,second)
            self.assertEqual(generate.call_count,1)
            self.assertIn('English',first.read_text())
            self.assertTrue(str(first).endswith('output/testwiktionary/20260901.language-registry.tsv'))

    def test_seekable_dump_stages_compressed_members_without_decompressed_copy(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True);write_namespace_fixture(folder)
            items=[]; members=[]
            for i,payload in enumerate((b'<mediawiki><page>a</page></mediawiki>',b'<mediawiki><page>b</page></mediawiki>')):
                name=f'testwiktionary-20260901-pages-meta-current{i}.xml-p{i}p{i}.bz2'
                data=bz2.compress(payload);members.append(data);(folder/name).write_bytes(data)
                items.append(dict(wiki='testwiktionary',date='20260901',name=name))
            scratch=root/'scratch';scratch.mkdir()
            dump=b.stage_seekable_dump(items,root,scratch)
            self.assertEqual(decode_staged_dump(dump),b''.join(bz2.decompress(member) for member in members))
            index=dump.with_name('pages-index.txt.bz2')
            rows=bz2.decompress(index.read_bytes()).decode().splitlines()
            self.assertEqual(len(rows),2)
            self.assertEqual([row.split(':',1)[1] for row in rows],['1:member0','2:member1'])

    def test_parallel_part_decode_preserves_input_order(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True);write_namespace_fixture(folder)
            items=[];parts=[]
            for i in range(4):
                name=f'testwiktionary-20260901-pages-meta-current{i}.xml-p{i}p{i}.bz2'
                raw=b'<mediawiki><page>'+bytes([65+i])*4096+b'</page></mediawiki>'
                (folder/name).write_bytes(bz2.compress(raw));parts.append(raw)
                items.append(dict(wiki='testwiktionary',date='20260901',name=name))
            barrier=threading.Barrier(4)
            original=zstd.compress
            seen=[];lock=threading.Lock()
            def concurrent_compress(raw,level=1):
                with lock: seen.append(threading.current_thread().name)
                barrier.wait(timeout=10)
                return original(raw,level=level)
            scratch=root/'scratch';scratch.mkdir()
            metadata={}
            with patch.object(b.zstd,'compress',side_effect=concurrent_compress):
                dump=b.stage_seekable_dump(items,root,scratch,metadata)
            self.assertEqual(len(set(seen)),4)
            self.assertEqual(decode_staged_dump(dump),b''.join(parts))
            packed=dump.read_bytes();index=(scratch/'pages-index.txt.bz2').read_bytes()
            rows=bz2.decompress(index).decode().splitlines()
            self.assertEqual(len(rows),4)
            offsets=[int(row.split(':',1)[0]) for row in rows]+[len(packed)]
            self.assertEqual(offsets,sorted(offsets))
            for start,end in zip(offsets,offsets[1:]):
                self.assertEqual(zstd.get_frame_size(packed[start:end]),end-start)
            self.assertEqual(metadata['source_pages'],4)
            self.assertEqual(metadata['dump_size'],len(packed))
            self.assertEqual(metadata['dump_sha256'],hashlib.sha256(packed).hexdigest())
            self.assertEqual(metadata['index_size'],len(index))
            self.assertEqual(metadata['index_sha256'],hashlib.sha256(index).hexdigest())

    def test_parallel_part_boundary_page_uses_serial_framer(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True);write_namespace_fixture(folder)
            parts=(b'<mediawiki><page>abc',b'def</page></mediawiki>')
            items=[]
            for i,raw in enumerate(parts):
                name=f'testwiktionary-20260901-pages-meta-current{i}.xml-p{i}p{i}.bz2'
                (folder/name).write_bytes(bz2.compress(raw))
                items.append(dict(wiki='testwiktionary',date='20260901',name=name))
            scratch=root/'scratch';scratch.mkdir()
            dump=b.stage_seekable_dump(items,root,scratch)
            self.assertEqual(decode_staged_dump(dump),b''.join(parts))
            self.assertEqual(len(bz2.decompress((scratch/'pages-index.txt.bz2').read_bytes()).splitlines()),1)

    def test_parallel_nine_part_submission_stays_within_ordered_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True);write_namespace_fixture(folder)
            items=[];parts=[]
            for i in range(9):
                name=f'testwiktionary-20260901-pages-meta-current{i}.xml-p{i}p{i}.bz2'
                raw=b'<page>'+bytes([65+i])*4096+b'</page>'
                (folder/name).write_bytes(bz2.compress(raw))
                items.append(dict(wiki='testwiktionary',date='20260901',name=name))
                parts.append(raw)
            completed=0
            original_get=b._PartFrameQueue.get
            def tracked_get(queue):
                nonlocal completed
                value=original_get(queue)
                if isinstance(value,tuple): completed+=1
                return value
            base=concurrent.futures.ThreadPoolExecutor
            class WindowCheckingPool(base):
                submissions=0
                def submit(self,*args,**kwargs):
                    index=self.submissions
                    self.submissions+=1
                    if index>=4:
                        if completed<index-3:
                            raise AssertionError('producer submitted ahead of ordered window')
                    return super().submit(*args,**kwargs)
            original_compress=zstd.compress
            def skewed_compress(raw,level=1):
                if b'<page>AAAA' in raw: time.sleep(0.05)
                return original_compress(raw,level=level)
            scratch=root/'scratch';scratch.mkdir()
            with patch.object(b._PartFrameQueue,'get',tracked_get), \
                 patch.object(b.concurrent.futures,'ThreadPoolExecutor',WindowCheckingPool), \
                 patch.object(b.zstd,'compress',side_effect=skewed_compress):
                dump=b.stage_seekable_dump(items,root,scratch)
            self.assertEqual(completed,9)
            self.assertEqual(decode_staged_dump(dump),b''.join(parts))

    def test_parallel_submit_failure_cancels_blocked_producer_and_removes_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True);write_namespace_fixture(folder)
            items=[]
            for i in range(2):
                name=f'testwiktionary-20260901-pages-meta-current{i}.xml-p{i}p{i}.bz2'
                (folder/name).write_bytes(bz2.compress(b'<page>body</page>'))
                items.append(dict(wiki='testwiktionary',date='20260901',name=name))
            base=concurrent.futures.ThreadPoolExecutor
            class FailSecondSubmit(base):
                def __init__(self,*args,**kwargs):
                    super().__init__(*args,**kwargs);self.submissions=0
                def submit(self,*args,**kwargs):
                    self.submissions+=1
                    if self.submissions==2: raise OSError('injected second submission failure')
                    return super().submit(*args,**kwargs)
            scratch=root/'scratch';scratch.mkdir()
            started=time.monotonic()
            with patch.object(b.concurrent.futures,'ThreadPoolExecutor',FailSecondSubmit), \
                 patch.object(b,'STAGE_PART_QUEUE_BYTES',1):
                with self.assertRaisesRegex(OSError,'injected second submission failure'):
                    b.stage_seekable_dump(items,root,scratch)
            self.assertLess(time.monotonic()-started,5)
            self.assertFalse((scratch/'pages.xml.zst').exists())
            self.assertFalse((scratch/'pages-index.txt.bz2').exists())

    def test_parallel_empty_parts_emit_one_known_size_frame(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True);write_namespace_fixture(folder)
            items=[]
            for i in range(2):
                name=f'testwiktionary-20260901-pages-meta-current{i}.xml-p{i}p{i}.bz2'
                (folder/name).write_bytes(bz2.compress(b''))
                items.append(dict(wiki='testwiktionary',date='20260901',name=name))
            scratch=root/'scratch';scratch.mkdir()
            dump=b.stage_seekable_dump(items,root,scratch)
            self.assertEqual(decode_staged_dump(dump),b'')
            self.assertEqual(bz2.decompress((scratch/'pages-index.txt.bz2').read_bytes()),b'0:1:member0\n')

    def test_single_part_seekable_dump_preserves_xml(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True);write_namespace_fixture(folder)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2';data=bz2.compress(b'<mediawiki/>');source=folder/name;source.write_bytes(data)
            scratch=root/'scratch';scratch.mkdir()
            dump=b.stage_seekable_dump([dict(wiki='testwiktionary',date='20260901',name=name)],root,scratch)
            self.assertEqual(decode_staged_dump(dump),b'<mediawiki/>')
            self.assertEqual(bz2.decompress(dump.with_name('pages-index.txt.bz2').read_bytes()),b'0:1:member0\n')

    def test_seekable_dump_bounds_members_and_preserves_all_xml_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True);write_namespace_fixture(folder)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            page=b'<page>'+bytes(range(256))*16384+b'</page>'
            xml=b'<mediawiki>'+page+page+b'</mediawiki>'
            # The source itself contains two bzip2 members inside one downloaded part.
            (folder/name).write_bytes(bz2.compress(xml[:len(xml)//2])+bz2.compress(xml[len(xml)//2:]))
            scratch=root/'scratch';scratch.mkdir()
            dump=b.stage_seekable_dump([dict(wiki='testwiktionary',date='20260901',name=name)],root,scratch)
            rows=bz2.decompress(dump.with_name('pages-index.txt.bz2').read_bytes()).decode().splitlines()
            self.assertEqual(len(rows),3)
            self.assertEqual(rows[0],'0:1:member0')
            compressed=dump.read_bytes()
            self.assertEqual(decode_staged_dump(dump),xml)
            offsets=[int(row.split(':',1)[0]) for row in rows]+[len(compressed)]
            for start,end in zip(offsets,offsets[1:]):
                frame=compressed[start:end]
                self.assertEqual(zstd.get_frame_size(frame),len(frame))
                self.assertLessEqual(zstd.get_frame_info(frame).decompressed_size,64*1024*1024)
                member=zstd.decompress(frame)
                self.assertLessEqual(len(member),64*1024*1024)
                self.assertEqual(member.count(b'<page>'),member.count(b'</page>'))

    def test_seekable_dump_rejects_truncated_xml_page(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True);write_namespace_fixture(folder)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            (folder/name).write_bytes(bz2.compress(b'<mediawiki><page>unfinished'))
            scratch=root/'scratch';scratch.mkdir()
            with self.assertRaisesRegex(ValueError,'Truncated XML page'):
                b.stage_seekable_dump([dict(wiki='testwiktionary',date='20260901',name=name)],root,scratch)

    def test_seekable_repack_limits_four_jobs_and_writes_submission_order(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True);write_namespace_fixture(folder)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            pages=[b'<page>'+bytes([65+i])*1024+b'</page>' for i in range(5)]
            xml=b'<mediawiki>'+b''.join(pages)+b'</mediawiki>'
            (folder/name).write_bytes(bz2.compress(xml))
            scratch=root/'scratch';scratch.mkdir()
            item=dict(wiki='testwiktionary',date='20260901',name=name)
            original_compress=zstd.compress
            lock=threading.Lock();barrier=threading.Barrier(4);others_done=threading.Event()
            calls=active=peak=completed_others=0
            completion=[]
            def controlled_compress(raw,level=1):
                nonlocal calls,active,peak,completed_others
                with lock:
                    ordinal=calls;calls+=1;active+=1;peak=max(peak,active)
                try:
                    if ordinal<4: barrier.wait(timeout=10)
                    if ordinal==0:
                        if not others_done.wait(timeout=10): raise AssertionError('Other compression jobs did not finish')
                    member=original_compress(raw,level=level)
                    with lock:
                        completion.append(ordinal)
                        if 0<ordinal<4:
                            completed_others+=1
                            if completed_others==3: others_done.set()
                    return member
                finally:
                    with lock: active-=1
            metadata={}
            with patch.object(b,'STAGE_TARGET_BYTES',1024), patch.object(b,'STAGE_PARALLEL_MAX_BYTES',2048), \
                 patch.object(b,'STAGE_MAX_MEMBER_BYTES',65536), patch.object(b.zstd,'compress',side_effect=controlled_compress):
                dump=b.stage_seekable_dump([item],root,scratch,metadata)
            self.assertEqual(calls,6)
            self.assertEqual(peak,4)
            self.assertLess(completion.index(1),completion.index(0))
            compressed=dump.read_bytes()
            index_bytes=dump.with_name('pages-index.txt.bz2').read_bytes()
            rows=bz2.decompress(index_bytes).decode().splitlines()
            self.assertEqual(len(rows),6)
            self.assertEqual([row.split(':',1)[1] for row in rows],[f'{i+1}:member{i}' for i in range(6)])
            offsets=[int(row.split(':',1)[0]) for row in rows]+[len(compressed)]
            self.assertEqual(offsets,sorted(offsets))
            self.assertEqual(b''.join(zstd.decompress(compressed[a:z]) for a,z in zip(offsets,offsets[1:])),xml)
            self.assertEqual(metadata['dump_size'],len(compressed))
            self.assertEqual(metadata['dump_sha256'],hashlib.sha256(compressed).hexdigest())
            self.assertEqual(metadata['index_size'],len(index_bytes))
            self.assertEqual(metadata['index_sha256'],hashlib.sha256(index_bytes).hexdigest())

    def test_seekable_repack_drains_before_oversized_member(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True);write_namespace_fixture(folder)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            sizes=[1024,1024,9*1024,1024]
            pages=[b'<page>'+bytes([65+i])*size+b'</page>' for i,size in enumerate(sizes)]
            xml=b'<mediawiki>'+b''.join(pages)+b'</mediawiki>'
            (folder/name).write_bytes(bz2.compress(xml))
            scratch=root/'scratch';scratch.mkdir()
            original_compress=zstd.compress;main_thread=threading.current_thread();oversized_on_main=[]
            def controlled_compress(raw,level=1):
                if len(raw)>2048: oversized_on_main.append(threading.current_thread() is main_thread)
                return original_compress(raw,level=level)
            with patch.object(b,'STAGE_TARGET_BYTES',1024), patch.object(b,'STAGE_PARALLEL_MAX_BYTES',2048), \
                 patch.object(b,'STAGE_MAX_MEMBER_BYTES',65536), patch.object(b.zstd,'compress',side_effect=controlled_compress):
                dump=b.stage_seekable_dump([dict(wiki='testwiktionary',date='20260901',name=name)],root,scratch)
            self.assertEqual(oversized_on_main,[True])
            compressed=dump.read_bytes()
            rows=bz2.decompress(dump.with_name('pages-index.txt.bz2').read_bytes()).decode().splitlines()
            self.assertEqual(len(rows),5)
            offsets=[int(row.split(':',1)[0]) for row in rows]+[len(compressed)]
            self.assertEqual(b''.join(zstd.decompress(compressed[a:z]) for a,z in zip(offsets,offsets[1:])),xml)

    def test_seekable_repack_deferred_compression_error_removes_partial_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True);write_namespace_fixture(folder)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            xml=b'<mediawiki>'+b''.join(b'<page>'+bytes([65+i])*1024+b'</page>' for i in range(3))+b'</mediawiki>'
            (folder/name).write_bytes(bz2.compress(xml))
            scratch=root/'scratch';scratch.mkdir()
            original_compress=zstd.compress;lock=threading.Lock();calls=0
            def fail_second(raw,level=1):
                nonlocal calls
                with lock: ordinal=calls;calls+=1
                if ordinal==1: raise OSError('deferred compression failure')
                return original_compress(raw,level=level)
            metadata={}
            with patch.object(b,'STAGE_TARGET_BYTES',1024), patch.object(b,'STAGE_PARALLEL_MAX_BYTES',2048), \
                 patch.object(b,'STAGE_MAX_MEMBER_BYTES',65536), patch.object(b.zstd,'compress',side_effect=fail_second):
                with self.assertRaisesRegex(OSError,'deferred compression failure'):
                    b.stage_seekable_dump([dict(wiki='testwiktionary',date='20260901',name=name)],root,scratch,metadata)
            self.assertGreaterEqual(calls,2)
            self.assertEqual(metadata,{})
            self.assertFalse((scratch/'pages.xml.zst').exists())
            self.assertFalse((scratch/'pages-index.txt.bz2').exists())

    def test_page_index_row_count_ignores_multistream_header_and_blanks(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'page-index.tsv'
            path.write_bytes(b'# dict-page-index-v2\tmultistream-bz2\n0\t0\t1\ta\n\n1\t0\t1\tb\n')
            self.assertEqual(b.count_page_index_rows(path),2)

    def test_shard_workspace_resumes_only_matching_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            workspace=Path(tmp)/'work'
            expected={'version':1,'edition':'x','date':'20260901','files':[],'registry_sha256':'a','source':'b','shard_pages':100}
            with patch.object(b.time,'time',return_value=123):
                self.assertEqual(b.prepare_shard_workspace(workspace,expected),123)
            sentinel=workspace/'keep';sentinel.write_text('yes')
            self.assertEqual(b.prepare_shard_workspace(workspace,expected),123)
            self.assertTrue(sentinel.exists())
            changed=dict(expected,registry_sha256='different')
            with patch.object(b.time,'time',return_value=456):
                self.assertEqual(b.prepare_shard_workspace(workspace,changed),456)
            self.assertFalse(sentinel.exists())
            alias=Path(tmp)/'alias';alias.symlink_to(workspace,target_is_directory=True)
            with self.assertRaisesRegex(ValueError,'Unsafe shard workspace'):
                b.prepare_shard_workspace(alias,changed)

    def test_interwiki_snapshot_bytes_invalidate_shards_and_are_pinned(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            registry=root/'language-registry.tsv';registry.write_text('en\tEnglish\n')
            source=root/'interwiki-map.tsv';source.write_text('en\t1\t1\t0\t0\thttps://en.example/$1\n')
            items=[dict(wiki='enwiktionary',date='20260901',name='dump.bz2',size=1,sha1='a'*40)]
            with patch.object(b,'source_fingerprint',return_value='compiler'):
                initial=b.shard_state(items,registry,interwiki_snapshot=source)
                pinned=b.copy_verified_snapshot(source,root/'work/interwiki-map.tsv',initial['interwiki_map_sha256'])
                self.assertEqual(pinned.read_bytes(),source.read_bytes())
                with patch.object(b.time,'time',return_value=111):
                    self.assertEqual(b.prepare_shard_workspace(root/'state',initial),111)
                (root/'state/expander').mkdir()
                source.write_text('w\t1\t0\t0\t0\thttps://en.example/$1\n')
                changed=b.shard_state(items,registry,interwiki_snapshot=source)
                self.assertNotEqual(changed['interwiki_map_sha256'],initial['interwiki_map_sha256'])
                with patch.object(b.time,'time',return_value=222):
                    self.assertEqual(b.prepare_shard_workspace(root/'state',changed),222)
                self.assertFalse((root/'state/expander').exists())
                with self.assertRaisesRegex(ValueError,'changed while copying'):
                    b.copy_verified_snapshot(source,root/'bad.tsv',initial['interwiki_map_sha256'])

    def test_dated_auxiliary_manifest_binds_bytes_edition_and_date(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            snapshot=root/'category-stats.tsv';snapshot.write_text('English nouns\t42\t0\t0\n')
            record=dict(wiki='enwiktionary',date='20260901',
                        output_sha256=hashlib.sha256(snapshot.read_bytes()).hexdigest())
            manifest=root/'category-stats.manifest.json';manifest.write_text(json.dumps(record))
            self.assertEqual(b.verified_auxiliary_hashes({'category-stats':snapshot},'enwiktionary','20260901'),
                             {'category-stats':record['output_sha256']})
            with self.assertRaisesRegex(ValueError,'differs from provenance'):
                b.verified_auxiliary_hashes({'category-stats':snapshot},'enwiktionary','20261001')
            manifest.write_bytes(b' '*(64*1024+1))
            with self.assertRaisesRegex(ValueError,'Oversized'):
                b.verified_auxiliary_hashes({'category-stats':snapshot},'enwiktionary','20260901')

    def test_source_and_registry_changes_keep_verified_dump_but_reset_native_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True);write_namespace_fixture(folder)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            data=bz2.compress(b'<mediawiki><page>word</page></mediawiki>')
            (folder/name).write_bytes(data)
            items=[dict(wiki='testwiktionary',date='20260901',name=name,
                        size=len(data),sha1=hashlib.sha1(data).hexdigest())]
            workspace=root/'output/20260901.shards'
            initial=dict(version=b.SHARD_STATE_VERSION,source='compiler-a',registry_sha256='registry-a')
            with patch.object(b.time,'time',return_value=111):
                self.assertEqual(b.prepare_shard_workspace(workspace,initial),111)
            with patch.object(b,'stage_seekable_dump',wraps=b.stage_seekable_dump) as stage:
                dump=b.cached_shard_dump(items,root,workspace)
                self.assertEqual(stage.call_count,1)
                original_inode=dump.stat().st_ino
                (workspace/'expander').mkdir()
                (workspace/'shards').mkdir()
                (workspace/'shards/old').write_text('stale')
                changed=dict(initial,source='compiler-b',registry_sha256='registry-b')
                with patch.object(b.time,'time',return_value=222):
                    self.assertEqual(b.prepare_shard_workspace(workspace,changed),222)
                self.assertFalse((workspace/'expander').exists())
                self.assertFalse((workspace/'shards').exists())
                self.assertEqual(dump.stat().st_ino,original_inode)
                self.assertEqual(json.loads((workspace/'state.json').read_text())['now_unix'],222)
                self.assertEqual(b.cached_shard_dump(items,root,workspace),dump)
                self.assertEqual(stage.call_count,1)

    def test_shard_workspace_rejects_symlinked_input_before_reset(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);workspace=root/'work';workspace.mkdir()
            external=root/'external';external.mkdir()
            (external/'keep').write_text('safe')
            (workspace/'input').symlink_to(external,target_is_directory=True)
            (workspace/'shards').mkdir()
            with self.assertRaisesRegex(ValueError,'Unsafe cached dump path'):
                b.prepare_shard_workspace(workspace,{'source':'new'})
            self.assertTrue((workspace/'shards').is_dir())
            self.assertEqual((external/'keep').read_text(),'safe')

    def test_cached_dump_requires_independent_nonnegative_integer_page_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True);write_namespace_fixture(folder)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            data=bz2.compress(b'<mediawiki><page>word</page></mediawiki>');(folder/name).write_bytes(data)
            items=[dict(wiki='testwiktionary',date='20260901',name=name,size=len(data),sha1=hashlib.sha1(data).hexdigest())]
            workspace=root/'work';workspace.mkdir()
            with patch.object(b,'stage_seekable_dump',wraps=b.stage_seekable_dump) as stage:
                b.cached_shard_dump(items,root,workspace)
                marker=workspace/'input/.complete.json'
                for count,value in enumerate((None,True,'1',-1,1.0),2):
                    with self.subTest(value=value):
                        record=json.loads(marker.read_text())
                        if value is None: del record['source_pages']
                        else: record['source_pages']=value
                        marker.write_text(json.dumps(record))
                        b.cached_shard_dump(items,root,workspace)
                        self.assertEqual(stage.call_count,count)
                        self.assertEqual(json.loads(marker.read_text())['source_pages'],1)
                b.cached_shard_dump(items,root,workspace)
                self.assertEqual(stage.call_count,6)

    def test_sharded_count_cannot_self_certify_truncated_index(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);workspace=root/'work';exp=workspace/'expander/.bundle-expander';exp.mkdir(parents=True)
            (workspace/'expander/.incomplete').write_text('expander ready')
            (exp/'dict-bundle-expander').write_text('worker');write_namespace_fixture(exp)
            (exp/'page-index.tsv').write_text('only-one-page\n')
            cache=workspace/'input';cache.mkdir();marker=cache/'.complete.json'
            for record in ({},{'source_pages':True},{'source_pages':-1},{'source_pages':2}):
                with self.subTest(record=record),patch.object(b,'run_checked') as run:
                    marker.write_text(json.dumps(record))
                    with self.assertRaisesRegex(ValueError,'source page|source pages'):
                        b.build_sharded(root/'dump',root/'staging',workspace,root/'registry','zig',1,[{'wiki':'test','date':'20260901'}],123)
                    run.assert_not_called()

    def test_cached_shard_dump_reuses_only_exact_verified_state_and_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True);write_namespace_fixture(folder)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            data=bz2.compress(b'<mediawiki><page>word</page></mediawiki>')
            (folder/name).write_bytes(data)
            items=[dict(wiki='testwiktionary',date='20260901',name=name,
                        size=len(data),sha1=hashlib.sha1(data).hexdigest())]
            workspace=root/'output/20260901.shards'
            expected=dict(version=b.SHARD_STATE_VERSION,source='source-a',files=[name])
            b.prepare_shard_workspace(workspace,expected)
            real_stage=b.stage_seekable_dump
            with patch.object(b,'stage_seekable_dump',wraps=real_stage) as stage:
                dump=b.cached_shard_dump(items,root,workspace)
                self.assertEqual(stage.call_count,1)
                self.assertEqual(b.cached_shard_dump(items,root,workspace),dump)
                self.assertEqual(stage.call_count,1)
                damaged=bytearray(dump.read_bytes());damaged[len(damaged)//2]^=1
                dump.write_bytes(damaged)
                b.cached_shard_dump(items,root,workspace)
                self.assertEqual(stage.call_count,2)
                index=workspace/'input/pages-index.txt.bz2'
                damaged=bytearray(index.read_bytes());damaged[len(damaged)//2]^=1
                index.write_bytes(damaged)
                b.cached_shard_dump(items,root,workspace)
                self.assertEqual(stage.call_count,3)
                marker=workspace/'input/.complete.json'
                marker.write_text('{partial')
                b.cached_shard_dump(items,root,workspace)
                self.assertEqual(stage.call_count,4)
                record=json.loads(marker.read_text())
                record['input_sha256']='0'*64
                marker.write_text(json.dumps(record)+'\n')
                b.cached_shard_dump(items,root,workspace)
                self.assertEqual(stage.call_count,5)
                old_record=json.loads(marker.read_text())
                old_record['version']='page-aligned-bz2-v1'
                old_record['dump_codec']='bz2'
                old_record['dump_stream_kind']='multistream-bz2'
                marker.write_text(json.dumps(old_record)+'\n')
                b.cached_shard_dump(items,root,workspace)
                self.assertEqual(stage.call_count,6)
                changed=dict(expected,source='source-b')
                b.prepare_shard_workspace(workspace,changed)
                self.assertTrue((workspace/'input').is_dir())
                b.cached_shard_dump(items,root,workspace)
                self.assertEqual(stage.call_count,6)
                changed_items=[dict(items[0],sha1='0'*40)]
                b.cached_shard_dump(changed_items,root,workspace)
                self.assertEqual(stage.call_count,7)
                with patch.object(b,'DUMP_STAGING_VERSION','page-aligned-zstd-parallel-v3'):
                    b.cached_shard_dump(changed_items,root,workspace)
                self.assertEqual(stage.call_count,8)

    def test_partial_cached_repack_cannot_be_reused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True);write_namespace_fixture(folder)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            data=bz2.compress(b'<mediawiki/>')
            (folder/name).write_bytes(data)
            items=[dict(wiki='testwiktionary',date='20260901',name=name,
                        size=len(data),sha1=hashlib.sha1(data).hexdigest())]
            workspace=root/'output/20260901.shards'
            expected={'version':b.SHARD_STATE_VERSION,'source':'source-a'}
            b.prepare_shard_workspace(workspace,expected)
            def fail_stage(_items,_downloads,cache,_metadata):
                (cache/'pages.xml.zst').write_bytes(b'partial')
                raise OSError('interrupted')
            with patch.object(b,'stage_seekable_dump',side_effect=fail_stage):
                with self.assertRaisesRegex(OSError,'interrupted'):
                    b.cached_shard_dump(items,root,workspace)
            self.assertFalse((workspace/'input/.complete.json').exists())
            with patch.object(b,'stage_seekable_dump',wraps=b.stage_seekable_dump) as stage:
                dump=b.cached_shard_dump(items,root,workspace)
                self.assertEqual(stage.call_count,1)
            self.assertEqual(decode_staged_dump(dump),b'<mediawiki/>')

    def test_failed_shard_merge_reuses_verified_repack_on_retry(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True);write_namespace_fixture(folder)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            data=bz2.compress(b'<mediawiki><page>word</page><page>second</page></mediawiki>')
            (folder/name).write_bytes(data)
            item=dict(wiki='testwiktionary',date='20260901',name=name,
                      url='https://dumps.wikimedia.org/testwiktionary/20260901/'+name,
                      size=len(data),sha1=hashlib.sha1(data).hexdigest())
            (folder/'language-registry.tsv').write_text('# content-language\ten\nen\tEnglish\n')
            merges=[]
            def run(command):
                if 'build-dictionary' in command:
                    dest=Path(command[command.index('--')+2]);exp=dest/'.bundle-expander';exp.mkdir(parents=True)
                    (dest/'.incomplete').write_text('expander ready')
                    (exp/'page-index.tsv').write_text('0\n1\n')
                    (exp/'dict-bundle-expander').write_text('worker');write_namespace_fixture(exp)
                elif 'build-blobs' in command:
                    dest=Path(command[command.index('--')+2]);dest.mkdir(parents=True,exist_ok=True)
                    write_coverage(dest,command)
                elif 'merge-blobs' in command:
                    merges.append(command)
                    if len(merges)==1:raise subprocess.CalledProcessError(1,command)
                    dest=Path(command[command.index('--')+1]);dest.mkdir()
                    (dest/'fallback-pages.jsonl').write_text('')
                    if 'merge-blobs' in command:write_namespace_coverage(dest,sum(json.loads((Path(x)/'page-coverage.json').read_text())['pages_seen'] for x in command[command.index('--')+2:]))
            real_stage=b.stage_seekable_dump
            with patch.object(b,'PROJECT',root), \
                 patch.object(b,'SHARD_PAGES',1),patch.object(b,'source_fingerprint',return_value='source'), \
                 patch.object(b.time,'time',return_value=123),patch.object(b,'run_checked',side_effect=run), \
                 patch.object(b,'stage_seekable_dump',wraps=real_stage) as stage:
                with self.assertRaises(subprocess.CalledProcessError):
                    b.build([item],root,root/'output','zig',1)
                workspace=root/'output/testwiktionary/20260901.shards'
                self.assertTrue((workspace/'input/.complete.json').is_file())
                self.assertEqual(stage.call_count,1)
                b.build([item],root,root/'output','zig',1)
                self.assertEqual(stage.call_count,1)
                self.assertEqual(len(merges),2)
                self.assertFalse(workspace.exists())
                self.assertTrue((root/'output/testwiktionary/20260901/complete.json').is_file())

    def test_large_edition_builds_verified_shards_then_merges(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True);write_namespace_fixture(folder)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            payload=b'<mediawiki><page></page><page></page></mediawiki>'
            data=bz2.compress(payload);(folder/name).write_bytes(data)
            item=dict(wiki='testwiktionary',date='20260901',name=name,url='https://dumps.wikimedia.org/testwiktionary/20260901/'+name,size=len(data),sha1=hashlib.sha1(data).hexdigest())
            (folder/'language-registry.tsv').write_text('# content-language\ten\nen\tEnglish\n')
            interwiki=root/'interwiki-map.tsv';interwiki.write_text('en\t1\t1\t0\t0\thttps://en.example/$1\n')
            category=root/'category-stats.tsv';category.write_text('Category:English nouns\t42\t0\t0\n')
            calls=[]
            def run(command):
                calls.append(command)
                step=next((x for x in ('build-dictionary','build-blobs','verify-blobs','merge-blobs') if x in command),None)
                if step=='build-dictionary':
                    dest=Path(command[command.index('--')+2]);exp=dest/'.bundle-expander';exp.mkdir(parents=True)
                    (dest/'.incomplete').write_text('expander ready')
                    (exp/'page-index.tsv').write_text('0\n1\n')
                    (exp/'dict-bundle-expander').write_text('worker');write_namespace_fixture(exp)
                elif step=='build-blobs':
                    dest=Path(command[command.index('--')+2]);dest.mkdir(parents=True,exist_ok=True)
                    write_coverage(dest,command)
                    (dest/'fallback-pages.jsonl').write_text('')
                    if 'merge-blobs' in command:write_namespace_coverage(dest,sum(json.loads((Path(x)/'page-coverage.json').read_text())['pages_seen'] for x in command[command.index('--')+2:]))
                    (dest/'languages.tsv').write_text('heading\n')
                elif step=='merge-blobs':
                    dest=Path(command[command.index('--')+1]);dest.mkdir(parents=True)
                    (dest/'fallback-pages.jsonl').write_text('')
                    if 'merge-blobs' in command:write_namespace_coverage(dest,sum(json.loads((Path(x)/'page-coverage.json').read_text())['pages_seen'] for x in command[command.index('--')+2:]))
                    (dest/'languages.tsv').write_text('heading\n')
                    (dest/'merged.wikblb').write_bytes(b'WIKBLB08merged')
            with patch.object(b,'PROJECT',root),patch.object(b,'SHARD_PAGES',1),patch.object(b,'source_fingerprint',return_value='source'),patch.object(b.time,'time',return_value=123),patch.object(b,'run_checked',side_effect=run):
                b.build([item],root,root/'output','zig',2,interwiki_snapshot=interwiki,
                        auxiliary_snapshots={'category-stats':category})
            blob_calls=[c for c in calls if 'build-blobs' in c]
            expander_call=next(c for c in calls if 'build-dictionary' in c)
            self.assertTrue(calls)
            self.assertTrue(all(command[1:4]==['build','-j1','-Doptimize=fast'] for command in calls))
            self.assertIn('--extraction-cache-root',expander_call)
            self.assertIn('--verified-dump-sha256',expander_call)
            self.assertIn('--verified-index-sha256',expander_call)
            self.assertIn('--interwiki-map-snapshot',expander_call)
            self.assertIn('--category-stats-snapshot',expander_call)
            self.assertEqual((root/'output/testwiktionary/20260901/.interwiki-map.sha256').read_text().strip(),hashlib.sha256(interwiki.read_bytes()).hexdigest())
            self.assertEqual(json.loads((root/'output/testwiktionary/20260901/.auxiliary-snapshots.sha256.json').read_text()),
                             {'category-stats':hashlib.sha256(category.read_bytes()).hexdigest(),**{name:b.sha256_file(folder/(name+'.tsv')) for name in ('namespace-registry','language-registry')}})
            for flag in ('--verified-dump-sha256','--verified-index-sha256'):
                self.assertRegex(expander_call[expander_call.index(flag)+1],r'^[0-9a-f]{64}$')
            self.assertEqual(len(blob_calls),1)
            self.assertEqual(blob_calls[0][blob_calls[0].index('--start-page')+1],'0')
            self.assertEqual(blob_calls[0][blob_calls[0].index('--index-byte-offset')+1],'0')
            self.assertEqual(blob_calls[0][blob_calls[0].index('--shard-pages')+1],'1')
            self.assertEqual({c[c.index('--now-unix')+1] for c in blob_calls},{'123'})
            self.assertEqual(sum('merge-blobs' in c for c in calls),1)
            self.assertGreaterEqual(sum('verify-blobs' in c for c in calls),3)
            final=root/'output/testwiktionary/20260901'
            self.assertTrue((final/'complete.json').is_file())
            self.assertEqual(json.loads((final/'complete.json').read_text())['input_pages'],2)
            self.assertEqual(lzma.open(final/'merged.wikblb.xz').read(),b'WIKBLB08merged')
            self.assertFalse((root/'output/testwiktionary/20260901.shards').exists())

    def test_in_and_out_aliases(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            source=root/'input';source.mkdir()
            item=dict(wiki='testwiktionary',date='20260901',name='testwiktionary-20260901-pages-meta-current.xml.bz2',url='https://dumps.wikimedia.org/testwiktionary/20260901/testwiktionary-20260901-pages-meta-current.xml.bz2',size=1,sha1='a'*40)
            write_test_manifest(source,{'files':[item]})
            output=root/'output'
            with patch.object(sys,'argv',['build_wiktionaries.py','--in',str(source),'--out',str(output),'--threads','2']),patch.object(b.os,'cpu_count',return_value=32),patch.object(b,'load_average',return_value=0),patch.object(b,'build') as build:
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
            write_test_manifest(source,{'files':items})
            rendezvous=threading.Barrier(2)
            with patch.object(sys,'argv',['build_wiktionaries.py','--in',str(source),'--out',str(root/'output'),'--threads','2','--jobs','2']),patch.object(b.os,'cpu_count',return_value=32),patch.object(b,'load_average',return_value=0),patch.object(b,'build',side_effect=lambda *args,**kwargs:rendezvous.wait(timeout=2)) as build:
                b.main()
            self.assertEqual(build.call_count,2)
            received={call.args[0][0]['wiki']:call.kwargs['auxiliary_snapshots'] for call in build.call_args_list}
            self.assertNotEqual(received['aawiktionary']['namespace-registry'],received['abwiktionary']['namespace-registry'])
            for wiki,snapshots in received.items():self.assertIn('# wiki\t'+wiki,snapshots['namespace-registry'].read_text())
    def test_scheduler_rechecks_worker_budget_before_starting_next_edition(self):
        groups={
            ('aawiktionary','20260901'):[dict(wiki='aawiktionary')],
            ('abwiktionary','20260901'):[dict(wiki='abwiktionary')],
        }
        started=[]
        clock=[0]
        def budget(_owned=0):return 0 if started and clock[0]<10 else 2
        def fake_build(group,*args):
            self.assertGreaterEqual(budget(),2)
            started.append(group[0]['wiki'])
        with patch.object(b,'safe_worker_budget',side_effect=budget), \
             patch.object(b,'build',side_effect=fake_build), \
             patch.object(b.time,'monotonic',side_effect=lambda:clock[0]), \
             patch.object(b.time,'sleep',side_effect=lambda seconds:clock.__setitem__(0,clock[0]+seconds)) as sleep:
            failures=b.build_groups(groups,Path('.'),Path('.'),'zig',2,1)
        self.assertEqual(started,['aawiktionary','abwiktionary'])
        self.assertEqual(failures,[])
        self.assertEqual([call.args[0] for call in sleep.call_args_list],[5,5])

    def test_scheduler_preserves_failed_edition_while_waiting_for_later_jobs(self):
        groups={(wiki,'20260901'):[dict(wiki=wiki)] for wiki in
                ('aawiktionary','abwiktionary','acwiktionary')}
        started=[];clock=[0]
        def budget(_owned=0):return 3 if started and clock[0]<10 else 4
        def fake_build(group,*args):
            self.assertGreaterEqual(budget(),4)
            started.append(group[0]['wiki'])
            if group[0]['wiki']=='aawiktionary':raise ValueError('edition failed')
        with patch.object(b,'safe_worker_budget',side_effect=budget), \
             patch.object(b,'build',side_effect=fake_build), \
             patch.object(b.time,'monotonic',side_effect=lambda:clock[0]), \
             patch.object(b.time,'sleep',side_effect=lambda seconds:clock.__setitem__(0,clock[0]+seconds)):
            failures=b.build_groups(groups,Path('.'),Path('.'),'zig',4,1)
        self.assertEqual(started,['aawiktionary','abwiktionary','acwiktionary'])
        self.assertEqual(failures,[('aawiktionary','20260901')])

    def test_scheduler_does_not_admit_jobs_after_resource_wait_expires(self):
        groups={(wiki,'20260901'):[dict(wiki=wiki)] for wiki in
                ('aawiktionary','abwiktionary','acwiktionary')}
        started=[];clock=[0]
        def budget(_owned=0):return 3 if started and clock[0]<7 else 4
        def fake_build(group,*args):started.append(group[0]['wiki'])
        with patch.object(b,'safe_worker_budget',side_effect=budget), \
             patch.object(b,'build',side_effect=fake_build), \
             patch.object(b.time,'monotonic',side_effect=lambda:clock[0]), \
             patch.object(b.time,'sleep',side_effect=lambda seconds:clock.__setitem__(0,clock[0]+seconds)) as sleep:
            failures=b.build_groups(groups,Path('.'),Path('.'),'zig',4,1,admission_wait_seconds=7)
        self.assertEqual(started,['aawiktionary'])
        self.assertEqual(failures,[('abwiktionary','20260901'),('acwiktionary','20260901')])
        self.assertEqual([call.args[0] for call in sleep.call_args_list],[5,2])

    def test_scheduler_requires_a_finite_resource_admission_wait(self):
        for seconds in (0,-1,True,float('inf'),float('nan'),limits.MAX_WATCHDOG_WALL_SECONDS+1):
            with self.subTest(seconds=seconds),self.assertRaisesRegex(ValueError,'Resource admission wait'):
                b.build_groups({},Path('.'),Path('.'),'zig',1,1,admission_wait_seconds=seconds)

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
    def test_release_compression_roundtrip(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'test.wikblb';raw=b'WIKBLB08'+b'payload'*20000;path.write_bytes(raw)
            compress(path,64*1024,2)
            self.assertEqual(lzma.open(str(path)+'.xz').read(),raw)
    def test_default_worker_count(self):
        with patch('compress_blobs.os.cpu_count',return_value=12):
            self.assertEqual(default_workers(),4)
        with patch('compress_blobs.os.cpu_count',return_value=None):
            self.assertEqual(default_workers(),1)

    def test_safe_worker_budget_caps_cpu_and_fixed_memory_without_meminfo(self):
        with patch.dict(b.os.environ,{},clear=True),patch.object(b.os,'cpu_count',return_value=32),patch.object(b,'load_average',return_value=0),patch.object(Path,'read_text',side_effect=AssertionError('must not read MemAvailable')):
            self.assertEqual(b.safe_worker_budget(),5)
            self.assertEqual(b.default_build_threads(),4)
        with patch.dict(b.os.environ,{},clear=True),patch.object(b.os,'cpu_count',return_value=2),patch.object(b,'load_average',return_value=0):
            self.assertEqual(b.safe_worker_budget(),1)
            self.assertEqual(b.default_build_threads(),1)

    def test_worker_budget_respects_verified_child_cap_and_fails_closed(self):
        with patch.dict(b.os.environ,{limits.CHILD_CGROUP:'/private/build'}),patch.object(b.os,'cpu_count',return_value=32),patch.object(b,'load_average',return_value=0):
            for cap,expected in ((8*1024**3,5),(4*1024**3,2),(256*1024**2,0),(None,0),(0,0),(True,0)):
                with self.subTest(cap=cap),patch.object(limits,'child_memory_limit_bytes',return_value=cap):
                    self.assertEqual(b.safe_worker_budget(),expected)
            for error in (OSError('unreadable'),ValueError('unbounded')):
                with patch.object(limits,'child_memory_limit_bytes',side_effect=error):
                    self.assertEqual(b.safe_worker_budget(),0)

    def test_safe_worker_budget_reserves_cpu_for_other_work(self):
        with patch.dict(b.os.environ,{},clear=True),patch.object(b.os,'cpu_count',return_value=12),patch.object(b,'load_average',return_value=7.2):
            self.assertEqual(b.safe_worker_budget(),1)
            self.assertEqual(b.safe_worker_budget(4),5)
        with patch.dict(b.os.environ,{},clear=True),patch.object(b.os,'cpu_count',return_value=12),patch.object(b,'load_average',return_value=12.0):
            self.assertEqual(b.safe_worker_budget(),0)

    def test_main_admits_fixed_budget_even_if_memavailable_is_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);source=root/'input';source.mkdir()
            item=dict(wiki='testwiktionary',date='20260901',name='testwiktionary-20260901-pages-meta-current.xml.bz2',url='https://dumps.wikimedia.org/testwiktionary/20260901/testwiktionary-20260901-pages-meta-current.xml.bz2',size=1,sha1='a'*40)
            write_test_manifest(source,{'files':[item]})
            original=Path.read_text
            def read(path,*args,**kwargs):
                if str(path)=='/proc/meminfo': return 'MemAvailable: 0 kB\n'
                return original(path,*args,**kwargs)
            with patch.dict(b.os.environ,{},clear=True),patch.object(sys,'argv',['build_wiktionaries.py','--in',str(source)]),patch.object(Path,'read_text',read),patch.object(b.os,'cpu_count',return_value=32),patch.object(b,'load_average',return_value=0),patch.object(b,'build') as build:
                b.main()
            build.assert_called_once()

    def test_cli_reaches_supervisor_under_lock_without_host_memory_admission(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            def supervised():
                with self.assertRaises(limits.ContainmentUnavailable):
                    b.acquire_build_resource_lock(root/'.tmp/build-resources.lock')
                raise limits.ContainmentUnavailable('delegation required')
            with patch.object(b,'PROJECT',root),patch.object(sys,'argv',['build_wiktionaries.py']),patch.object(limits,'inside_envelope',return_value=False),patch.object(limits,'supervise',side_effect=supervised) as supervise,patch.object(b,'safe_worker_budget',return_value=0),patch.object(b,'main') as main:
                with self.assertRaisesRegex(SystemExit,'delegation required'): b.cli()
            supervise.assert_called_once_with()
            main.assert_not_called()

    def test_main_rejects_aggregate_worker_oversubscription(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); source=root/'input'; source.mkdir()
            item=dict(wiki='testwiktionary',date='20260901',name='testwiktionary-20260901-pages-meta-current.xml.bz2',url='https://dumps.wikimedia.org/testwiktionary/20260901/testwiktionary-20260901-pages-meta-current.xml.bz2',size=1,sha1='a'*40)
            write_test_manifest(source,{'files':[item]})
            with patch.object(sys,'argv',['build_wiktionaries.py','--in',str(source),'--threads','4','--jobs','2']),patch.object(b,'safe_worker_budget',return_value=6):
                with self.assertRaises(SystemExit): b.main()
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
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True);write_namespace_fixture(folder)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            data=bz2.compress(b'<mediawiki><page></page><page></page></mediawiki>');(folder/name).write_bytes(data)
            item=dict(wiki='testwiktionary',date='20260901',name=name,url='https://dumps.wikimedia.org/testwiktionary/20260901/'+name,size=len(data),sha1=hashlib.sha1(data).hexdigest())
            registry=folder/'language-registry.tsv';registry.write_text('# content-language\ten\nen\tEnglish\n')
            interwiki=root/'interwiki-map.tsv';interwiki.write_text('en\t1\t1\t0\t0\thttps://en.example/$1\n')
            calls=[]
            real_run=subprocess.run
            def run(command,**kwargs):
                if command[0]=='xz':
                    self.assertFalse((root/'output/testwiktionary/20260901.shards').exists())
                    return real_run(command,**kwargs)
                calls.append(command)
                if 'build-dictionary' in command:
                    dest=Path(command[command.index('--')+2]);dest.mkdir();(dest/'en.wikblb').write_bytes(b'WIKBLB08payload')
                    write_coverage(dest)
                    coverage=json.loads((dest/'page-coverage.json').read_text());coverage.update(pages_seen=2,expected_input_pages=2)
                    (dest/'page-coverage.json').write_text(json.dumps(coverage))
                    write_namespace_coverage(dest,2)
                    coverage=json.loads((dest/'namespace-coverage.json').read_text());coverage['namespaces'][0].update(expanded_pages=0,fallback_pages=2)
                    (dest/'namespace-coverage.json').write_text(json.dumps(coverage))
                    (dest/'fallback-pages.jsonl').write_text(
                        json.dumps({'namespace':0,'title':'quoted"title','reasons':['literal_markup']})+'\n'+
                        json.dumps({'namespace':0,'title':'failed expansion','reasons':['expansion_error','expansion_error:ExpansionFailed']})+'\n')
            with patch.object(b,'PROJECT',root),patch.object(b.subprocess,'run',side_effect=run):
                b.build([item],root,root/'output','zig',2,interwiki_snapshot=interwiki,now_unix=1791072000)
            self.assertIn('verify-blobs',calls[1]);self.assertTrue((root/'output/testwiktionary/20260901/complete.json').exists())
            self.assertTrue(all(command[1:4]==['build','-j1','-Doptimize=fast'] for command in calls))
            self.assertEqual(calls[0][calls[0].index('--now-unix')+1],'1791072000')
            self.assertEqual(json.loads((root/'output/testwiktionary/20260901/complete.json').read_text())['now_unix'],1791072000)
            self.assertIn('--llvm-workers',calls[0])
            self.assertIn('--language-registry-snapshot',calls[0])
            self.assertIn('--interwiki-map-snapshot',calls[0])
            final=root/'output/testwiktionary/20260901'
            metadata=json.loads((final/'complete.json').read_text())
            self.assertEqual(metadata['interwiki_map_sha256'],hashlib.sha256(interwiki.read_bytes()).hexdigest())
            interwiki.write_text('w\t0\t0\t0\t0\thttps://en.example/$1\n')
            with patch.object(b,'PROJECT',root):
                with self.assertRaisesRegex(ValueError,'different interwiki map'):
                    b.build([item],root,root/'output','zig',2,interwiki_snapshot=interwiki)
            self.assertEqual(metadata['fallback_pages'],2)
            self.assertEqual(metadata['fallback_report'],'fallback-pages.jsonl')
            self.assertEqual(len((final/'fallback-pages.jsonl').read_text().splitlines()),2)
            self.assertFalse((final/'en.wikblb').exists())
            self.assertEqual(lzma.open(final/'en.wikblb.xz').read(),b'WIKBLB08payload')
            self.assertTrue(not (root/'.tmp').exists() or not any((root/'.tmp').iterdir()))
    def test_verified_partial_compression_resumes_without_rebuilding(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True);write_namespace_fixture(folder)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            data=bz2.compress(b'<mediawiki/>');(folder/name).write_bytes(data)
            item=dict(wiki='testwiktionary',date='20260901',name=name,url='https://dumps.wikimedia.org/testwiktionary/20260901/'+name,size=len(data),sha1=hashlib.sha1(data).hexdigest())
            (folder/'language-registry.tsv').write_text('# content-language\ten\nen\tEnglish\n')
            staging=root/'output/testwiktionary/20260901.building';staging.mkdir(parents=True)
            (staging/'fallback-pages.jsonl').write_text('')
            (staging/'languages.tsv').write_text('heading\n')
            (staging/b.VERIFIED_MARKER).write_text(b.VERIFIED_CONTENT)
            (staging/b.AUXILIARY_SHA_NAME).write_text(json.dumps({name:b.sha256_file(folder/(name+'.tsv')) for name in ('namespace-registry','language-registry')}))
            with patch.object(b,'PROJECT',root):write_coverage(staging)
            first=staging/'first.wikblb';second=staging/'second.wikblb'
            first.write_bytes(b'WIKBLB08first');second.write_bytes(b'WIKBLB08second')
            compress(first,64*1024,1)
            real_run=subprocess.run
            def run(command,**kwargs):
                if command[0]=='xz':return real_run(command,**kwargs)
                raise AssertionError(f'unexpected rebuild command: {command}')
            with patch.object(b,'PROJECT',root),patch.object(b.subprocess,'run',side_effect=run):
                b.persist_build_identity(staging,b.build_input_identity([item],'zig',b.verified_auxiliary_hashes(write_namespace_fixture(folder)),None,None))
                b.build([item],root,root/'output','zig',1)
            final=root/'output/testwiktionary/20260901'
            meta=json.loads((final/'complete.json').read_text())
            self.assertEqual(meta['blobs'],2)
            self.assertEqual(meta['dump_staging_version'],b.DUMP_STAGING_VERSION)
            self.assertEqual(meta['dump_codec'],'zstd')
            self.assertEqual(meta['dump_stream_kind'],'multistream-zstd')
            self.assertFalse((final/b.VERIFIED_MARKER).exists())
            self.assertFalse((final/'first.wikblb').exists());self.assertFalse((final/'second.wikblb').exists())
            self.assertEqual(lzma.open(final/'first.wikblb.xz').read(),b'WIKBLB08first')
            self.assertEqual(lzma.open(final/'second.wikblb.xz').read(),b'WIKBLB08second')

    def test_old_complete_output_is_preserved_and_requires_new_output_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True);write_namespace_fixture(folder)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            data=bz2.compress(b'<mediawiki/>');(folder/name).write_bytes(data)
            item=dict(wiki='testwiktionary',date='20260901',name=name,url='https://dumps.wikimedia.org/testwiktionary/20260901/'+name,size=len(data),sha1=hashlib.sha1(data).hexdigest())
            target=root/'output/testwiktionary/20260901';target.mkdir(parents=True)
            complete=target/'complete.json';complete.write_text(json.dumps({'edition':'testwiktionary','status':'built'})+'\n')
            with patch.object(b,'run_checked') as run:
                with self.assertRaisesRegex(ValueError,'rebuild in a new output directory'):
                    b.build([item],root,root/'output','zig',1)
            run.assert_not_called()
            self.assertTrue(complete.is_file())

    def test_old_verified_staging_is_preserved_and_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True);write_namespace_fixture(folder)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            data=bz2.compress(b'<mediawiki/>');(folder/name).write_bytes(data)
            item=dict(wiki='testwiktionary',date='20260901',name=name,url='https://dumps.wikimedia.org/testwiktionary/20260901/'+name,size=len(data),sha1=hashlib.sha1(data).hexdigest())
            staging=root/'output/testwiktionary/20260901.building';staging.mkdir(parents=True)
            marker=staging/b.VERIFIED_MARKER;marker.write_text('verified\n')
            with patch.object(b,'run_checked') as run:
                with self.assertRaisesRegex(ValueError,'rebuild in a new output directory'):
                    b.build([item],root,root/'output','zig',1)
            run.assert_not_called()
            self.assertEqual(marker.read_text(),'verified\n')
    def test_empty_edition_retries_stale_build_and_is_published(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True);write_namespace_fixture(folder)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            data=bz2.compress(b'<mediawiki/>');(folder/name).write_bytes(data)
            item=dict(wiki='testwiktionary',date='20260901',name=name,url='https://dumps.wikimedia.org/testwiktionary/20260901/'+name,size=len(data),sha1=hashlib.sha1(data).hexdigest())
            (folder/'language-registry.tsv').write_text('# content-language\ten\nen\tEnglish\n')
            stale=root/'output/testwiktionary/20260901.building';stale.mkdir(parents=True)
            (stale/'old').write_text('failed')
            def run(command,**kwargs):
                if 'build-dictionary' in command:
                    dest=Path(command[command.index('--')+2]);dest.mkdir();(dest/'fallback-pages.jsonl').write_text('')
                    write_coverage(dest)
            with patch.object(b,'PROJECT',root),patch.object(b.subprocess,'run',side_effect=run):
                b.build([item],root,root/'output','zig',2)
            final=root/'output/testwiktionary/20260901'
            self.assertEqual(json.loads((final/'complete.json').read_text())['status'],'empty')
            self.assertFalse((final/'old').exists())


class PublicationResumeTests(unittest.TestCase):
    def prepare(self, root, publish=True):
        folder=root/'testwiktionary/20260901'
        snapshots=write_namespace_fixture(folder)
        name='testwiktionary-20260901-pages-meta-current.xml.bz2'
        data=bz2.compress(b'<mediawiki/>');(folder/name).write_bytes(data)
        item=dict(wiki='testwiktionary',date='20260901',name=name,
                  url='https://dumps.wikimedia.org/testwiktionary/20260901/'+name,
                  size=len(data),sha1=hashlib.sha1(data).hexdigest())
        staging=root/'output/testwiktionary/20260901.building';staging.mkdir(parents=True)
        target=staging.with_name('20260901')
        write_coverage(staging)
        (staging/'fallback-pages.jsonl').write_text('')
        (staging/'supplemental.wikblb').write_bytes(b'WIKBLB08fixture')
        (staging/b.VERIFIED_MARKER).write_text(b.VERIFIED_CONTENT)
        hashes=b.verified_auxiliary_hashes(snapshots)
        (staging/b.AUXILIARY_SHA_NAME).write_text(json.dumps(hashes))
        identity=b.build_input_identity([item],'zig',hashes,None,None)
        b.persist_build_identity(staging,identity)
        if publish:
            b._publish_verified_staging(staging,target,'testwiktionary','20260901',1,
                auxiliary_hashes=hashes,build_identity=identity,namespace_snapshot=snapshots['namespace-registry'])
        workspace=target.with_name('20260901.shards');workspace.mkdir()
        (workspace/'sentinel').write_text('keep until publication is verified')
        return item,target,workspace

    def test_valid_published_resume_verifies_bytes_then_removes_workspace(self):
        with tempfile.TemporaryDirectory() as tmp,patch.object(b,'run_checked') as run:
            root=Path(tmp)
            with patch.object(b,'PROJECT',root):
                item,target,workspace=self.prepare(root)
                metadata=json.loads((target/'complete.json').read_text())
                files=metadata['publication_files']
                self.assertEqual(files['supplemental.wikblb.xz']['sha256'],b.sha256_file(target/'supplemental.wikblb.xz'))
                self.assertIn('languages.tsv',files)
                indexes=[]
                for name in ('.dict-cache/supplemental.wikblb.xz.idx',
                             'languages/.dict-cache/'+hashlib.sha256(b'English').hexdigest()+'.wikblb.xz.idx'):
                    index=target/name;index.parent.mkdir(parents=True)
                    index.write_bytes(b'derived reader index');indexes.append(index)
                self.assertEqual(b.build_locked([item],root,root/'output','zig',1),'existing_output')
                self.assertFalse(workspace.exists())
                for index in indexes:
                    self.assertEqual(index.read_bytes(),b'derived reader index')
                    self.assertNotIn(index.relative_to(target).as_posix(),files)
                self.assertEqual(b.publication_inventory(target),files)
            run.assert_not_called()

    def test_published_resume_rejects_cache_symlinks_and_unexpected_artifacts(self):
        cases=[('symlink',name) for name in ('.dict-cache','languages/.dict-cache')]
        cases += [('file',name) for name in ('other/.dict-cache/reader.idx',
                    'languages/other/.dict-cache/reader.idx','reader.py','languages/reader.so')]
        for kind,name in cases:
            with self.subTest(kind=kind,name=name),tempfile.TemporaryDirectory() as tmp, \
                 patch.object(b,'run_checked') as run:
                root=Path(tmp)
                with patch.object(b,'PROJECT',root):
                    item,target,workspace=self.prepare(root)
                    path=target/name;path.parent.mkdir(parents=True,exist_ok=True)
                    if kind=='symlink':
                        cache=root/'outside-cache';cache.mkdir();path.symlink_to(cache.resolve(),target_is_directory=True)
                    else:path.write_bytes(b'unexpected artifact')
                    with self.assertRaises(ValueError):b.build_locked([item],root,root/'output','zig',1)
                    self.assertTrue((workspace/'sentinel').is_file())
                run.assert_not_called()

    def test_published_resume_rejects_changed_source_or_compiler_and_preserves_output(self):
        for changed in ('source','compiler'):
            with self.subTest(changed=changed),tempfile.TemporaryDirectory() as tmp, \
                 patch.object(b,'run_checked') as run:
                root=Path(tmp)
                with patch.object(b,'PROJECT',root):
                    item,target,workspace=self.prepare(root)
                    marker=(target/'complete.json').read_bytes()
                    inventory=b.publication_inventory(target)
                    zig='zig'
                    if changed=='source':
                        source=root/'src/runtime.zig';source.parent.mkdir()
                        source.write_text('changed compiler runtime')
                    else:
                        compiler=root/'changed-zig';compiler.write_bytes(b'changed Zig compiler')
                        compiler.chmod(0o700);zig=str(compiler)
                    with self.assertRaisesRegex(ValueError,'Build inputs or compiler changed'):
                        b.build_locked([item],root,root/'output',zig,1)
                    self.assertEqual((target/'complete.json').read_bytes(),marker)
                    self.assertEqual(b.publication_inventory(target),inventory)
                    self.assertTrue((workspace/'sentinel').is_file())
                run.assert_not_called()

    def test_damaged_published_artifacts_preserve_workspace(self):
        cases=[('missing',name) for name in ('supplemental.wikblb.xz','languages.tsv',
                'page-coverage.json','namespace-coverage.json','fallback-pages.jsonl')]
        cases += [('changed',name) for name in ('supplemental.wikblb.xz','languages.tsv')]
        cases += [('extra','extra.wikblb.xz'),('symlink','languages.tsv')]
        for action,name in cases:
            with self.subTest(action=action,name=name),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp)
                with patch.object(b,'PROJECT',root):
                    item,target,workspace=self.prepare(root)
                    path=target/name
                    if action=='missing':path.unlink()
                    elif action=='changed':
                        data=bytearray(path.read_bytes());data[len(data)//2]^=1;path.write_bytes(data)
                    elif action=='extra':path.write_bytes((target/'supplemental.wikblb.xz').read_bytes())
                    else:
                        other=root/'language-copy.tsv';other.write_bytes(path.read_bytes());path.unlink();path.symlink_to(other.resolve())
                    with self.assertRaises(ValueError):b.build_locked([item],root,root/'output','zig',1)
                    self.assertEqual((workspace/'sentinel').read_text(),'keep until publication is verified')
                    self.assertTrue((target/'complete.json').is_file())

    def test_inconsistent_completion_metadata_preserves_workspace(self):
        cases={'edition':'otherwiktionary','date':'20261001','status':'empty','blobs':0,
               'input_pages':1,'fallback_pages':1,'namespace_coverage_totals':{},
               'page_coverage_report':'other.json','namespace_coverage_report':'other.json',
               'fallback_report':'other.json','publication_files':None}
        for field,value in cases.items():
            with self.subTest(field=field),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp)
                with patch.object(b,'PROJECT',root):
                    item,target,workspace=self.prepare(root)
                    path=target/'complete.json';metadata=json.loads(path.read_text());metadata[field]=value
                    path.write_text(json.dumps(metadata))
                    with self.assertRaises(ValueError):b.build_locked([item],root,root/'output','zig',1)
                    self.assertTrue((workspace/'sentinel').is_file())

    def test_interrupted_publication_keeps_verified_staging_resumable(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            with patch.object(b,'PROJECT',root):
                item,target,workspace=self.prepare(root,publish=False)
                with patch.object(b.os,'rename',side_effect=OSError('publication interrupted')):
                    with self.assertRaisesRegex(OSError,'publication interrupted'):
                        b.build_locked([item],root,root/'output','zig',1)
                staging=target.with_name('20260901.building')
                self.assertTrue((staging/b.VERIFIED_MARKER).is_file())
                self.assertTrue((staging/'complete.json').is_file())
                with patch.object(b,'run_checked') as run:
                    self.assertEqual(b.build_locked([item],root,root/'output','zig',1),'resumed_publication')
                    run.assert_not_called()
                self.assertFalse((target/b.VERIFIED_MARKER).exists())


class ExpansionDeadlineTests(unittest.TestCase):
    def test_remote_operational_fallbacks_cannot_be_published(self):
        for reason in ('expansion_error:OutOfMemory', 'expansion_error:expand:OutOfMemory',
                       'expansion_error:assets:OutOfMemory', 'expansion_error:expand:Timeout'):
            with self.subTest(reason=reason), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); staging = root / 'staging'; staging.mkdir()
                (staging / b.VERIFIED_MARKER).write_text(b.VERIFIED_CONTENT)
                write_coverage(staging)
                (staging / 'fallback-pages.jsonl').write_text(json.dumps({
                    'namespace': 0, 'title': 'failed', 'reasons': ['expansion_error', reason]}) + '\n')
                with patch.object(b, 'compress_many') as compress:
                    with self.assertRaisesRegex(ValueError, 'Operational expansion'):
                        b._publish_verified_staging(staging, root / 'final', 'test', '20260901')
                    compress.assert_not_called()
                self.assertFalse((root / 'final').exists())

    def test_old_timeout_staging_cannot_be_published(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); staging=root/'staging'; staging.mkdir()
            (staging/b.VERIFIED_MARKER).write_text(b.VERIFIED_CONTENT)
            write_coverage(staging)
            (staging/'fallback-pages.jsonl').write_text(json.dumps({
                'namespace':0,'title':'timed out','reasons':['expansion_error','expansion_error:Timeout']})+'\n')
            with patch.object(b,'compress_many') as compress:
                with self.assertRaisesRegex(ValueError,'Operational expansion timeout'):
                    b._publish_verified_staging(staging,root/'final','test','20260901')
                compress.assert_not_called()
            self.assertTrue((staging/b.VERIFIED_MARKER).exists())
            self.assertFalse((root/'final').exists())

    def test_bounded_optional_timeout_arguments(self):
        self.assertEqual(b.expansion_deadline_args(None),[])
        self.assertEqual(b.expansion_deadline_args(600000),['--expansion-timeout-ms','600000'])
        for value in (0,-1,3600001,True,'600000'):
            with self.assertRaises(ValueError): b.expansion_deadline_args(value)

if __name__=='__main__':unittest.main()

class ReproducibleBuildTimeTest(unittest.TestCase):
    def test_explicit_time_reuses_only_identical_shards_and_preserves_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            workspace=Path(tmp)/'work'
            self.assertEqual(b.prepare_shard_workspace(workspace,{'source':'same'},123),123)
            (workspace/'input').mkdir();(workspace/'input/keep').write_text('source')
            (workspace/'old-shard').write_text('old')
            self.assertEqual(b.prepare_shard_workspace(workspace,{'source':'same'},123),123)
            self.assertTrue((workspace/'old-shard').exists())
            self.assertEqual(b.prepare_shard_workspace(workspace,{'source':'same'},456),456)
            self.assertFalse((workspace/'old-shard').exists())
            self.assertEqual((workspace/'input/keep').read_text(),'source')
            self.assertEqual(b.prepare_shard_workspace(workspace,{'source':'same'}),456)
    def test_invalid_timestamps_are_rejected(self):
        for bad in [0,-1,True,1.5,'123',1<<63]:
            with self.subTest(value=bad),self.assertRaises(ValueError):b.validate_now_unix(bad)
        self.assertIsNone(b.validate_now_unix(None))
        self.assertEqual(b.validate_now_unix((1<<63)-1),(1<<63)-1)
    def test_conflicting_embedded_timestamp_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError,'Conflicting'):
                b.prepare_shard_workspace(Path(tmp)/'work',{'now_unix':123},456)
    def test_main_forwards_pinned_time(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            item=dict(wiki='testwiktionary',date='20261001',name='test.xml.bz2',url='https://dumps.wikimedia.org/testwiktionary/20261001/test.xml.bz2',size=1,sha1='a'*40)
            write_test_manifest(root,{'files':[item]})
            with patch.object(sys,'argv',['build_wiktionaries.py','--in',str(root),'--threads','1','--jobs','1','--now-unix','1791072000']),patch.object(b,'safe_worker_budget',return_value=4),patch.object(b,'build_groups',return_value=[]) as groups:
                b.main()
            self.assertEqual(groups.call_args.kwargs['now_unix'],1791072000)

class LongBuildDeadlineTest(unittest.TestCase):
    def test_watchdog_admission_wait_uses_the_configured_global_deadline(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            write_test_manifest(root,{'files':[dict(wiki='testwiktionary',date='20261001',name='test.xml.bz2',url='https://dumps.wikimedia.org/testwiktionary/20261001/test.xml.bz2',size=1,sha1='a'*40)]})
            for seconds in (None,14400):
                argv=['build_wiktionaries.py','--resource-mode=watchdog','--downloads',str(root),'--threads','1','--jobs','1']
                if seconds is not None:argv+=['--build-timeout-seconds',str(seconds)]
                with self.subTest(seconds=seconds),patch.object(sys,'argv',argv), \
                     patch.object(b,'safe_worker_budget',return_value=4), \
                     patch.object(b,'build_groups',return_value=[]) as groups:
                    b.main()
                self.assertEqual(groups.call_args.kwargs['admission_wait_seconds'],seconds or limits.WATCHDOG_WALL_SECONDS)

    def test_explicit_long_deadline_keeps_watchdog_and_default_memory_envelope(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch.object(b,'PROJECT',Path(tmp)),patch.object(sys,'argv',['build_wiktionaries.py','--resource-mode=watchdog','--build-timeout-seconds','14400']),patch.object(limits,'inside_watchdog',return_value=False),patch.object(limits,'supervise_watchdog',return_value=0) as watchdog:
                with self.assertRaises(SystemExit) as result:b.cli()
                self.assertEqual(result.exception.code,0)
            watchdog.assert_called_once_with(wall_seconds=14400,disk_paths=(Path(tmp)/'.tmp',Path(tmp)/'data/dictionaries'))
    def test_long_deadlines_remain_explicit_finite_and_watchdog_only(self):
        for argv in [ ['--build-timeout-seconds','14400'], ['--resource-mode=watchdog','--build-timeout-seconds','0'], ['--resource-mode=watchdog','--build-timeout-seconds',str(limits.MAX_WATCHDOG_WALL_SECONDS+1)] ]:
            with self.subTest(argv=argv),patch.object(sys,'argv',['build_wiktionaries.py',*argv]),patch.object(limits,'supervise_watchdog') as run:
                with self.assertRaises(SystemExit):b.cli()
                run.assert_not_called()


class PageCountRoutingTests(unittest.TestCase):
    class RouteReached(RuntimeError):
        pass

    def _check_route(self, pages, attempts=1):
        # Real small compressed input and real verified repack: the branch must
        # depend on the staged source count, not compression ratio or file size.
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            folder=root/'testwiktionary/20260901'
            write_namespace_fixture(folder)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            raw=b'<mediawiki>'+b'<page>word</page>'*pages+b'</mediawiki>'
            data=bz2.compress(raw)
            self.assertLess(len(data),512*1024*1024)
            (folder/name).write_bytes(data)
            item=dict(wiki='testwiktionary',date='20260901',name=name,
                      url='https://dumps.wikimedia.org/testwiktionary/20260901/'+name,
                      size=len(data),sha1=hashlib.sha1(data).hexdigest())
            tool=root/'zig'
            tool.write_bytes(b'fixture identity only; never executed')
            tool.chmod(0o700)
            workspace=root/'output/testwiktionary/20260901.shards'
            dump=workspace/'input/pages.xml.zst'
            calls=[]
            def stop_one_shot(command, edition, date, phase, **fields):
                self.assertEqual(phase,'dictionary_build')
                self.assertIn('build-dictionary',command)
                self.assertNotIn('--expander-only',command)
                actual=Path(command[command.index('--')+1])
                calls.append(('one-shot',actual))
                self.assertEqual(actual,dump)
                self.assertTrue(actual.is_file())
                raise self.RouteReached()
            def stop_sharded(actual, staging, actual_workspace, *args, **kwargs):
                calls.append(('sharded',Path(actual)))
                self.assertEqual(Path(actual),dump)
                self.assertEqual(actual_workspace,workspace)
                self.assertTrue(Path(actual).is_file())
                raise self.RouteReached()
            real_prepare=b.prepare_shard_workspace
            real_cached=b.cached_shard_dump
            real_stage=b.stage_seekable_dump
            with patch.object(b,'PROJECT',root), \
                 patch.object(b,'source_fingerprint',return_value='source'), \
                 patch.object(b.time,'time',return_value=123), \
                 patch.object(b,'prepare_shard_workspace',wraps=real_prepare) as prepare, \
                 patch.object(b,'cached_shard_dump',wraps=real_cached) as cached, \
                 patch.object(b,'stage_seekable_dump',wraps=real_stage) as stage, \
                 patch.object(b,'timed_run',side_effect=stop_one_shot), \
                 patch.object(b,'build_sharded',side_effect=stop_sharded):
                for attempt in range(attempts):
                    with self.assertRaises(self.RouteReached):
                        b.build([item],root,root/'output',str(tool),1)
                    # A dispatch failure retains the same verified input for
                    # retry, and one-shot must never create a second repack.
                    self.assertEqual(prepare.call_count,attempt+1)
                    self.assertEqual(cached.call_count,attempt+1)
                    self.assertEqual(stage.call_count,1)
                    self.assertEqual(stage.call_args.args[:3],([item],root,workspace/'input'))
                    cached.assert_called_with([item],root,workspace)
                    source=json.loads((workspace/'input/.complete.json').read_text())
                    self.assertEqual(source['source_pages'],pages)
                    self.assertEqual(source['dump_sha256'],b.sha256_file(dump))
                    self.assertEqual(source['index_sha256'],b.sha256_file(dump.with_name('pages-index.txt.bz2')))
            expected='sharded' if pages>100_000 else 'one-shot'
            self.assertEqual(calls,[(expected,dump)]*attempts)

    def test_verified_source_page_count_boundary_routes_zero_and_exact_shard_once(self):
        self.assertEqual(b.SHARD_PAGES,100_000)
        for pages in (0,100_000,100_001):
            with self.subTest(pages=pages):
                self._check_route(pages)

    def test_failed_dispatch_reuses_verified_staging_for_both_routes(self):
        self.assertEqual(b.SHARD_PAGES,100_000)
        for pages in (1,100_001):
            with self.subTest(pages=pages):
                self._check_route(pages,attempts=2)
