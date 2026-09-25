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
from compress_blobs import compress, compress_many, default_workers

class BuildTest(unittest.TestCase):
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
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
            items=[]; members=[]
            for i,payload in enumerate((b'<mediawiki><page>a</page></mediawiki>',b'<mediawiki><page>b</page></mediawiki>')):
                name=f'testwiktionary-20260901-pages-meta-current{i}.xml-p{i}p{i}.bz2'
                data=bz2.compress(payload);members.append(data);(folder/name).write_bytes(data)
                items.append(dict(wiki='testwiktionary',date='20260901',name=name))
            scratch=root/'scratch';scratch.mkdir()
            dump=b.stage_seekable_dump(items,root,scratch)
            self.assertEqual(bz2.decompress(dump.read_bytes()),b''.join(bz2.decompress(member) for member in members))
            index=dump.with_name('pages-index.txt.bz2')
            rows=bz2.decompress(index.read_bytes()).decode().splitlines()
            self.assertEqual(rows,['0:1:member0'])

    def test_single_part_seekable_dump_preserves_xml(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2';data=bz2.compress(b'<mediawiki/>');source=folder/name;source.write_bytes(data)
            scratch=root/'scratch';scratch.mkdir()
            dump=b.stage_seekable_dump([dict(wiki='testwiktionary',date='20260901',name=name)],root,scratch)
            self.assertEqual(bz2.decompress(dump.read_bytes()),b'<mediawiki/>')
            self.assertEqual(bz2.decompress(dump.with_name('pages-index.txt.bz2').read_bytes()),b'0:1:member0\n')

    def test_seekable_dump_bounds_members_and_preserves_all_xml_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
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
            self.assertEqual(bz2.decompress(compressed),xml)
            offsets=[int(row.split(':',1)[0]) for row in rows]+[len(compressed)]
            for start,end in zip(offsets,offsets[1:]):
                decoder=bz2.BZ2Decompressor()
                member=decoder.decompress(compressed[start:end])
                self.assertTrue(decoder.eof)
                self.assertEqual(decoder.unused_data,b'')
                self.assertLessEqual(len(member),64*1024*1024)
                self.assertEqual(member.count(b'<page>'),member.count(b'</page>'))

    def test_seekable_dump_rejects_truncated_xml_page(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            (folder/name).write_bytes(bz2.compress(b'<mediawiki><page>unfinished'))
            scratch=root/'scratch';scratch.mkdir()
            with self.assertRaisesRegex(ValueError,'Truncated XML page'):
                b.stage_seekable_dump([dict(wiki='testwiktionary',date='20260901',name=name)],root,scratch)

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

    def test_source_and_registry_changes_keep_verified_dump_but_reset_native_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
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

    def test_cached_shard_dump_reuses_only_exact_verified_state_and_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
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
                changed=dict(expected,source='source-b')
                b.prepare_shard_workspace(workspace,changed)
                self.assertTrue((workspace/'input').is_dir())
                b.cached_shard_dump(items,root,workspace)
                self.assertEqual(stage.call_count,5)
                changed_items=[dict(items[0],sha1='0'*40)]
                b.cached_shard_dump(changed_items,root,workspace)
                self.assertEqual(stage.call_count,6)
                with patch.object(b,'DUMP_STAGING_VERSION','page-aligned-bz2-v2'):
                    b.cached_shard_dump(changed_items,root,workspace)
                self.assertEqual(stage.call_count,7)

    def test_partial_cached_repack_cannot_be_reused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            data=bz2.compress(b'<mediawiki/>')
            (folder/name).write_bytes(data)
            items=[dict(wiki='testwiktionary',date='20260901',name=name,
                        size=len(data),sha1=hashlib.sha1(data).hexdigest())]
            workspace=root/'output/20260901.shards'
            expected={'version':b.SHARD_STATE_VERSION,'source':'source-a'}
            b.prepare_shard_workspace(workspace,expected)
            def fail_stage(_items,_downloads,cache,_metadata):
                (cache/'pages.xml.bz2').write_bytes(b'partial')
                raise OSError('interrupted')
            with patch.object(b,'stage_seekable_dump',side_effect=fail_stage):
                with self.assertRaisesRegex(OSError,'interrupted'):
                    b.cached_shard_dump(items,root,workspace)
            self.assertFalse((workspace/'input/.complete.json').exists())
            with patch.object(b,'stage_seekable_dump',wraps=b.stage_seekable_dump) as stage:
                dump=b.cached_shard_dump(items,root,workspace)
                self.assertEqual(stage.call_count,1)
            self.assertEqual(bz2.decompress(dump.read_bytes()),b'<mediawiki/>')

    def test_failed_shard_merge_reuses_verified_repack_on_retry(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            data=bz2.compress(b'<mediawiki><page>word</page></mediawiki>')
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
                    (exp/'page-index.tsv').write_text('0\n')
                    (exp/'dict-bundle-expander').write_text('worker')
                elif 'build-blobs' in command:
                    dest=Path(command[command.index('--')+2]);dest.mkdir(parents=True)
                elif 'merge-blobs' in command:
                    merges.append(command)
                    if len(merges)==1:raise subprocess.CalledProcessError(1,command)
                    dest=Path(command[command.index('--')+1]);dest.mkdir()
                    (dest/'fallback-pages.jsonl').write_text('')
            real_stage=b.stage_seekable_dump
            with patch.object(b,'PROJECT',root),patch.object(b,'SHARD_THRESHOLD_COMPRESSED_BYTES',1), \
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
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            payload=b'<mediawiki><page></page><page></page></mediawiki>'
            data=bz2.compress(payload);(folder/name).write_bytes(data)
            item=dict(wiki='testwiktionary',date='20260901',name=name,url='https://dumps.wikimedia.org/testwiktionary/20260901/'+name,size=len(data),sha1=hashlib.sha1(data).hexdigest())
            (folder/'language-registry.tsv').write_text('# content-language\ten\nen\tEnglish\n')
            calls=[]
            def run(command):
                calls.append(command)
                step=next((x for x in ('build-dictionary','build-blobs','verify-blobs','merge-blobs') if x in command),None)
                if step=='build-dictionary':
                    dest=Path(command[command.index('--')+2]);exp=dest/'.bundle-expander';exp.mkdir(parents=True)
                    (dest/'.incomplete').write_text('expander ready')
                    (exp/'page-index.tsv').write_text('0\n1\n')
                    (exp/'dict-bundle-expander').write_text('worker')
                elif step=='build-blobs':
                    dest=Path(command[command.index('--')+2]);dest.mkdir(parents=True)
                    (dest/'fallback-pages.jsonl').write_text('')
                    (dest/'languages.tsv').write_text('heading\n')
                elif step=='merge-blobs':
                    dest=Path(command[command.index('--')+1]);dest.mkdir(parents=True)
                    (dest/'fallback-pages.jsonl').write_text('')
                    (dest/'languages.tsv').write_text('heading\n')
                    (dest/'merged.wikblb').write_bytes(b'WIKBLB08merged')
            with patch.object(b,'PROJECT',root),patch.object(b,'SHARD_THRESHOLD_COMPRESSED_BYTES',1),patch.object(b,'SHARD_PAGES',1),patch.object(b,'source_fingerprint',return_value='source'),patch.object(b.time,'time',return_value=123),patch.object(b,'run_checked',side_effect=run):
                b.build([item],root,root/'output','zig',2)
            blob_calls=[c for c in calls if 'build-blobs' in c]
            self.assertEqual(len(blob_calls),2)
            self.assertEqual([c[c.index('--start-page')+1] for c in blob_calls],['0','1'])
            self.assertEqual({c[c.index('--now-unix')+1] for c in blob_calls},{'123'})
            self.assertEqual(sum('merge-blobs' in c for c in calls),1)
            self.assertGreaterEqual(sum('verify-blobs' in c for c in calls),3)
            final=root/'output/testwiktionary/20260901'
            self.assertTrue((final/'complete.json').is_file())
            self.assertEqual(lzma.open(final/'merged.wikblb.xz').read(),b'WIKBLB08merged')
            self.assertFalse((root/'output/testwiktionary/20260901.shards').exists())

    def test_in_and_out_aliases(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            source=root/'input';source.mkdir()
            item=dict(wiki='testwiktionary',date='20260901',name='testwiktionary-20260901-pages-meta-current.xml.bz2',url='https://dumps.wikimedia.org/testwiktionary/20260901/testwiktionary-20260901-pages-meta-current.xml.bz2',size=1,sha1='a'*40)
            (source/'manifest.json').write_text(json.dumps({'files':[item]}))
            output=root/'output'
            with patch.object(sys,'argv',['build_wiktionaries.py','--in',str(source),'--out',str(output),'--threads','2']),patch.object(b,'available_memory_bytes',return_value=16*1024*1024*1024),patch.object(b,'load_average',return_value=0),patch.object(b,'build') as build:
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
            with patch.object(sys,'argv',['build_wiktionaries.py','--in',str(source),'--out',str(root/'output'),'--threads','2','--jobs','2']),patch.object(b,'available_memory_bytes',return_value=16*1024*1024*1024),patch.object(b,'load_average',return_value=0),patch.object(b,'build',side_effect=lambda *args:rendezvous.wait(timeout=2)) as build:
                b.main()
            self.assertEqual(build.call_count,2)
    def test_scheduler_rechecks_memory_before_starting_next_edition(self):
        groups={
            ('aawiktionary','20260901'):[dict(wiki='aawiktionary')],
            ('abwiktionary','20260901'):[dict(wiki='abwiktionary')],
        }
        started=[]
        budgets=iter((2,0,0))
        def fake_build(group,*args):started.append(group[0]['wiki'])
        with patch.object(b,'safe_worker_budget',side_effect=lambda _owned=0:next(budgets,0)),patch.object(b,'build',side_effect=fake_build):
            failures=b.build_groups(groups,Path('.'),Path('.'),'zig',2,1)
        self.assertEqual(started,['aawiktionary'])
        self.assertEqual(failures,[('abwiktionary','20260901')])

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

    def test_safe_worker_budget_caps_cpu_and_memory(self):
        with patch.object(b.os,'cpu_count',return_value=32),patch.object(b,'load_average',return_value=0),patch.object(b,'available_memory_bytes',return_value=8*1024*1024*1024):
            self.assertEqual(b.safe_worker_budget(),4)
            self.assertEqual(b.default_build_threads(),4)
        with patch.object(b.os,'cpu_count',return_value=2),patch.object(b,'load_average',return_value=0),patch.object(b,'available_memory_bytes',return_value=64*1024*1024*1024):
            self.assertEqual(b.safe_worker_budget(),1)
            self.assertEqual(b.default_build_threads(),1)

    def test_safe_worker_budget_reserves_cpu_for_other_work(self):
        with patch.object(b.os,'cpu_count',return_value=12),patch.object(b,'available_memory_bytes',return_value=64*1024*1024*1024),patch.object(b,'load_average',return_value=7.2):
            self.assertEqual(b.safe_worker_budget(),1)
            self.assertEqual(b.safe_worker_budget(4),5)
        with patch.object(b.os,'cpu_count',return_value=12),patch.object(b,'available_memory_bytes',return_value=64*1024*1024*1024),patch.object(b,'load_average',return_value=12.0):
            self.assertEqual(b.safe_worker_budget(),0)

    def test_main_refuses_to_start_below_memory_reserve(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);source=root/'input';source.mkdir()
            item=dict(wiki='testwiktionary',date='20260901',name='testwiktionary-20260901-pages-meta-current.xml.bz2',url='https://dumps.wikimedia.org/testwiktionary/20260901/testwiktionary-20260901-pages-meta-current.xml.bz2',size=1,sha1='a'*40)
            (source/'manifest.json').write_text(json.dumps({'files':[item]}))
            with patch.object(sys,'argv',['build_wiktionaries.py','--in',str(source)]),patch.object(b,'available_memory_bytes',return_value=b.MEMORY_RESERVE_BYTES+b.MEMORY_PER_BUILD_WORKER-1),patch.object(b,'load_average',return_value=0):
                with self.assertRaises(SystemExit): b.main()

    def test_main_rejects_aggregate_worker_oversubscription(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); source=root/'input'; source.mkdir()
            item=dict(wiki='testwiktionary',date='20260901',name='testwiktionary-20260901-pages-meta-current.xml.bz2',url='https://dumps.wikimedia.org/testwiktionary/20260901/testwiktionary-20260901-pages-meta-current.xml.bz2',size=1,sha1='a'*40)
            (source/'manifest.json').write_text(json.dumps({'files':[item]}))
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
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            data=bz2.compress(b'<mediawiki/>');(folder/name).write_bytes(data)
            item=dict(wiki='testwiktionary',date='20260901',name=name,url='https://dumps.wikimedia.org/testwiktionary/20260901/'+name,size=len(data),sha1=hashlib.sha1(data).hexdigest())
            registry=folder/'language-registry.tsv';registry.write_text('# content-language\ten\nen\tEnglish\n')
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
            self.assertIn('--language-registry-snapshot',calls[0])
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
            (folder/'language-registry.tsv').write_text('# content-language\ten\nen\tEnglish\n')
            staging=root/'output/testwiktionary/20260901.building';staging.mkdir(parents=True)
            (staging/'fallback-pages.jsonl').write_text('')
            (staging/'languages.tsv').write_text('heading\n')
            (staging/b.VERIFIED_MARKER).write_text(b.VERIFIED_CONTENT)
            first=staging/'first.wikblb';second=staging/'second.wikblb'
            first.write_bytes(b'WIKBLB08first');second.write_bytes(b'WIKBLB08second')
            compress(first,64*1024,1)
            real_run=subprocess.run
            def run(command,**kwargs):
                if command[0]=='xz':return real_run(command,**kwargs)
                raise AssertionError(f'unexpected rebuild command: {command}')
            with patch.object(b,'PROJECT',root),patch.object(b.subprocess,'run',side_effect=run):
                b.build([item],root,root/'output','zig',1)
            final=root/'output/testwiktionary/20260901'
            meta=json.loads((final/'complete.json').read_text())
            self.assertEqual(meta['blobs'],2)
            self.assertEqual(meta['dump_staging_version'],b.DUMP_STAGING_VERSION)
            self.assertFalse((final/b.VERIFIED_MARKER).exists())
            self.assertFalse((final/'first.wikblb').exists());self.assertFalse((final/'second.wikblb').exists())
            self.assertEqual(lzma.open(final/'first.wikblb.xz').read(),b'WIKBLB08first')
            self.assertEqual(lzma.open(final/'second.wikblb.xz').read(),b'WIKBLB08second')

    def test_old_complete_output_is_preserved_and_requires_new_output_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
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
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
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
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            data=bz2.compress(b'<mediawiki/>');(folder/name).write_bytes(data)
            item=dict(wiki='testwiktionary',date='20260901',name=name,url='https://dumps.wikimedia.org/testwiktionary/20260901/'+name,size=len(data),sha1=hashlib.sha1(data).hexdigest())
            (folder/'language-registry.tsv').write_text('# content-language\ten\nen\tEnglish\n')
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
