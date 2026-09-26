import bz2
import concurrent.futures
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
from unittest.mock import patch
import build_wiktionaries as b
import build_resource_limits as limits
from compress_blobs import compress, compress_many, default_workers

def decode_staged_dump(dump):
    compressed=dump.read_bytes()
    offsets=[int(line.split(':',1)[0]) for line in bz2.decompress(
        dump.with_name('pages-index.txt.bz2').read_bytes()).decode().splitlines()]
    frames=[compressed[start:end] for start,end in zip(offsets,offsets[1:]+[len(compressed)])]
    for frame in frames:
        assert zstd.get_frame_size(frame)==len(frame)
        assert zstd.get_frame_info(frame).decompressed_size<=64*1024*1024
    return b''.join(zstd.decompress(frame) for frame in frames)


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

class BuildTest(unittest.TestCase):
    def test_main_routes_interwiki_and_dated_auxiliary_snapshot_flags(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            name='enwiktionary-20260901-pages-meta-current.xml.bz2'
            item=dict(wiki='enwiktionary',date='20260901',name=name,
                      url='https://dumps.wikimedia.org/enwiktionary/20260901/'+name,
                      size=1,sha1='a'*40)
            (root/'manifest.json').write_text(json.dumps({'files':[item]}))
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
                'auxiliary_snapshots':{'category-stats':category.resolve()},
            })

    def test_watchdog_mode_is_explicit_locked_and_deadline_bounded(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            def supervised(**kwargs):
                self.assertEqual(kwargs,{'wall_seconds':7200})
                with self.assertRaises(limits.ContainmentUnavailable):
                    b.acquire_build_resource_lock(root/'.tmp/build-resources.lock')
                return 0
            with patch.object(b,'PROJECT',root),patch.object(sys,'argv',['build_wiktionaries.py','--resource-mode=watchdog']),patch.object(limits,'inside_watchdog',return_value=False),patch.object(limits,'supervise_watchdog',side_effect=supervised) as watchdog,patch.object(limits,'supervise') as strict,patch.object(b,'main') as main:
                with self.assertRaises(SystemExit) as result:b.cli()
                self.assertEqual(result.exception.code,0)
            watchdog.assert_called_once_with(wall_seconds=7200)
            strict.assert_not_called();main.assert_not_called()

    def test_eight_expansion_workers_request_eight_cpu_watchdog(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch.object(b,'PROJECT',Path(tmp)),patch.object(sys,'argv',[
                'build_wiktionaries.py','--resource-mode=watchdog','--expansion-workers=8']), \
                 patch.object(limits,'inside_watchdog',return_value=False), \
                 patch.object(limits,'supervise_watchdog',return_value=0) as watchdog:
                with self.assertRaises(SystemExit) as result:b.cli()
                self.assertEqual(result.exception.code,0)
            watchdog.assert_called_once_with(wall_seconds=7200,max_cpus=8)

    def test_high_expansion_count_keeps_single_job_and_four_build_workers(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'manifest.json').write_text('{"files":[]}')
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
            root=Path(tmp);(root/'manifest.json').write_text('{"files":[]}')
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

    def test_sharded_expansion_workers_do_not_widen_compiler_workers(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);workspace=root/'work';exp=workspace/'expander/.bundle-expander';exp.mkdir(parents=True)
            (exp/'page-index.tsv').write_text('# index\n\np0\n')
            (exp/'dict-bundle-expander').write_text('worker')
            cache=workspace/'input';cache.mkdir();(cache/'.complete.json').write_text(json.dumps({
                'source_pages':1,'dump_sha256':'a'*64,'index_sha256':'b'*64}))
            calls=[]
            def run(command):
                calls.append(command)
                if 'build-dictionary' in command:
                    exp.mkdir(parents=True,exist_ok=True)
                    (exp/'page-index.tsv').write_text('# index\n\np0\n')
                    (exp/'dict-bundle-expander').write_text('worker')
                if 'build-blobs' in command:
                    dest=Path(command[command.index('--')+2]);dest.mkdir(exist_ok=True);write_coverage(dest,command)
                if 'merge-blobs' in command:
                    Path(command[command.index('--')+1]).mkdir()
            with patch.object(b,'run_checked',side_effect=run):
                b.build_sharded(root/'dump',root/'staging',workspace,root/'registry','zig',4,
                                [{'wiki':'test','date':'20260901'}],123,8)
            compiler=next(c for c in calls if 'build-dictionary' in c)
            blob=next(c for c in calls if 'build-blobs' in c)
            self.assertEqual(compiler[compiler.index('--llvm-workers')+1],'4')
            self.assertEqual(compiler[compiler.index('--parse-workers')+1],'4')
            self.assertEqual(compiler[compiler.index('--page-workers')+1],'4')
            self.assertEqual(blob[blob.index('--workers')+1],'8')

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
            (exp/'dict-bundle-expander').write_text('worker')
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
            (exp/'dict-bundle-expander').write_text('worker')
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
            (exp/'dict-bundle-expander').write_text('worker')
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
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
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
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
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
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
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
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
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
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
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
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
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
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2';data=bz2.compress(b'<mediawiki/>');source=folder/name;source.write_bytes(data)
            scratch=root/'scratch';scratch.mkdir()
            dump=b.stage_seekable_dump([dict(wiki='testwiktionary',date='20260901',name=name)],root,scratch)
            self.assertEqual(decode_staged_dump(dump),b'<mediawiki/>')
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
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            (folder/name).write_bytes(bz2.compress(b'<mediawiki><page>unfinished'))
            scratch=root/'scratch';scratch.mkdir()
            with self.assertRaisesRegex(ValueError,'Truncated XML page'):
                b.stage_seekable_dump([dict(wiki='testwiktionary',date='20260901',name=name)],root,scratch)

    def test_seekable_repack_limits_four_jobs_and_writes_submission_order(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
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
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
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
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
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

    def test_cached_dump_requires_independent_nonnegative_integer_page_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
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
            (exp/'dict-bundle-expander').write_text('worker')
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
                    dest=Path(command[command.index('--')+2]);dest.mkdir(parents=True,exist_ok=True)
                    write_coverage(dest,command)
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
                    (exp/'dict-bundle-expander').write_text('worker')
                elif step=='build-blobs':
                    dest=Path(command[command.index('--')+2]);dest.mkdir(parents=True,exist_ok=True)
                    write_coverage(dest,command)
                    (dest/'fallback-pages.jsonl').write_text('')
                    (dest/'languages.tsv').write_text('heading\n')
                elif step=='merge-blobs':
                    dest=Path(command[command.index('--')+1]);dest.mkdir(parents=True)
                    (dest/'fallback-pages.jsonl').write_text('')
                    (dest/'languages.tsv').write_text('heading\n')
                    (dest/'merged.wikblb').write_bytes(b'WIKBLB08merged')
            with patch.object(b,'PROJECT',root),patch.object(b,'SHARD_THRESHOLD_COMPRESSED_BYTES',1),patch.object(b,'SHARD_PAGES',1),patch.object(b,'source_fingerprint',return_value='source'),patch.object(b.time,'time',return_value=123),patch.object(b,'run_checked',side_effect=run):
                b.build([item],root,root/'output','zig',2,interwiki_snapshot=interwiki,
                        auxiliary_snapshots={'category-stats':category})
            blob_calls=[c for c in calls if 'build-blobs' in c]
            expander_call=next(c for c in calls if 'build-dictionary' in c)
            self.assertTrue(calls)
            self.assertTrue(all(command[1:3]==['build','-j1'] for command in calls))
            self.assertIn('--extraction-cache-root',expander_call)
            self.assertIn('--verified-dump-sha256',expander_call)
            self.assertIn('--verified-index-sha256',expander_call)
            self.assertIn('--interwiki-map-snapshot',expander_call)
            self.assertIn('--category-stats-snapshot',expander_call)
            self.assertEqual((root/'output/testwiktionary/20260901/.interwiki-map.sha256').read_text().strip(),hashlib.sha256(interwiki.read_bytes()).hexdigest())
            self.assertEqual(json.loads((root/'output/testwiktionary/20260901/.auxiliary-snapshots.sha256.json').read_text()),
                             {'category-stats':hashlib.sha256(category.read_bytes()).hexdigest()})
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
            (source/'manifest.json').write_text(json.dumps({'files':[item]}))
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
            (source/'manifest.json').write_text(json.dumps({'files':items}))
            rendezvous=threading.Barrier(2)
            with patch.object(sys,'argv',['build_wiktionaries.py','--in',str(source),'--out',str(root/'output'),'--threads','2','--jobs','2']),patch.object(b.os,'cpu_count',return_value=32),patch.object(b,'load_average',return_value=0),patch.object(b,'build',side_effect=lambda *args:rendezvous.wait(timeout=2)) as build:
                b.main()
            self.assertEqual(build.call_count,2)
    def test_scheduler_rechecks_worker_budget_before_starting_next_edition(self):
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
            (source/'manifest.json').write_text(json.dumps({'files':[item]}))
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
            interwiki=root/'interwiki-map.tsv';interwiki.write_text('en\t1\t1\t0\t0\thttps://en.example/$1\n')
            calls=[]
            real_run=subprocess.run
            def run(command,**kwargs):
                if command[0]=='xz': return real_run(command,**kwargs)
                calls.append(command)
                if 'build-dictionary' in command:
                    dest=Path(command[command.index('--')+2]);dest.mkdir();(dest/'en.wikblb').write_bytes(b'WIKBLB08payload')
                    write_coverage(dest)
                    (dest/'fallback-pages.jsonl').write_text(
                        json.dumps({'namespace':0,'title':'quoted"title','reasons':['literal_markup']})+'\n'+
                        json.dumps({'namespace':0,'title':'timeout','reasons':['expansion_error','expansion_error:Timeout']})+'\n')
            with patch.object(b,'PROJECT',root),patch.object(b.subprocess,'run',side_effect=run):
                b.build([item],root,root/'output','zig',2,interwiki_snapshot=interwiki)
            self.assertIn('verify-blobs',calls[1]);self.assertTrue((root/'output/testwiktionary/20260901/complete.json').exists())
            self.assertTrue(all(command[1:3]==['build','-j1'] for command in calls))
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
            write_coverage(staging)
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
            self.assertEqual(meta['dump_codec'],'zstd')
            self.assertEqual(meta['dump_stream_kind'],'multistream-zstd')
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
                    write_coverage(dest)
            with patch.object(b,'PROJECT',root),patch.object(b.subprocess,'run',side_effect=run):
                b.build([item],root,root/'output','zig',2)
            final=root/'output/testwiktionary/20260901'
            self.assertEqual(json.loads((final/'complete.json').read_text())['status'],'empty')
            self.assertFalse((final/'old').exists())
if __name__=='__main__':unittest.main()
