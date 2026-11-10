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


def fixture_blob_tool(root, name='dict-blob-build'):
    path=root/'test-blob-tools'/name
    path.parent.mkdir(parents=True,exist_ok=True)
    if not path.exists():
        path.write_bytes(b'fixture executable; native execution is mocked\n')
        path.chmod(0o555)
    return b.PreparedBlobTool(path)


def blob_command(command, name):
    native={'build-blobs':'dict-blob-build','verify-blobs':'dict-blob-verify','merge-blobs':'dict-blob-merge'}
    return bool(command) and (Path(command[0]).name==native[name] or name in command)


def tool_arguments(command):
    if command and Path(command[0]).name in b.BLOB_TOOL_NAMES:return command[1:]
    return command[command.index('--')+1:]


class PreparedToolsFixture(unittest.TestCase):
    def setUp(self):
        super().setUp()
        # Existing orchestration tests mock native subprocesses. Give that path
        # real read-only bindings while testing preparation separately below.
        def prepare(workspace,zig,edition,date,build_identity=None,*,expander_args=None,figure_inputs=None):
            if expander_args is not None:
                b.timed_run([zig,'build','-j1','-Doptimize=fast','--prefix',str(workspace/'native-blob-tools'),
                             'prepare-blob-tools','--summary','all','build-dictionary','--',*expander_args],
                            edition,date,'expander_and_blob_tools_prepare')
            return {name:fixture_blob_tool(workspace,name) for name in b.BLOB_TOOL_NAMES}
        mock=patch.object(b,'prepare_blob_tools',side_effect=prepare)
        mock.start();self.addCleanup(mock.stop)


class ShardSourceIdentityTests(PreparedToolsFixture):
    def fixture(self, root):
        sources={
            'build.zig':b'build graph', 'build.zig.zon':b'package dependencies',
            'src/producer.zig':b'ordinary producer', 'src/lua/runtime/abi.h':b'ABI layout',
            'tools/extraction_cache.py':b'production cache helper',
            'tools/corpus_controller.py':b'controller timing',
            'tools/test_corpus_controller.py':b'controller timing tests',
            'tools/native_qualification.py':b'standalone native qualification',
            'tools/test_native_qualification.py':b'qualification controls',
            'tools/nested/native_qualification.py':b'unreviewed same basename remains included',
            'tools/nested/test_native_qualification.py':b'unreviewed nested test remains included',
            'tools/nested/corpus_controller.py':b'unreviewed same basename remains included',
            'tools/test_other.py':b'unreviewed test dependency remains included',
        }
        for name,data in sources.items():
            path=root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
        registry=root/'languages.tsv';registry.write_bytes(b'en\tEnglish\n')
        items=[dict(wiki='testwiktionary',date='20261001',name='dump.bz2',size=1,sha1='a'*40)]
        return sources,registry,items

    def seed(self, workspace, state):
        self.assertEqual(b.prepare_shard_workspace(workspace,state,123),123)
        retained={
            'input/verified-dump':b'unchanged staged input',
            'expander/compiled':b'compiled producer',
            'shards/00000000/blob':b'completed shard',
            'shards/00000000/.verified':b'verified\n',
        }
        for name,data in retained.items():
            path=workspace/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
        return retained

    def test_controller_only_edits_reuse_state_and_preserve_original_audit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);sources,registry,items=self.fixture(root)
            with patch.object(b,'PROJECT',root):
                initial=b.shard_state(items,registry);workspace=root/'work'
                retained=self.seed(workspace,initial)
                marker=(workspace/'state.json').read_bytes();inode=(workspace/'state.json').stat().st_ino
                for name in ('tools/corpus_controller.py','tools/test_corpus_controller.py'):
                    with self.subTest(name=name):
                        (root/name).write_bytes(sources[name]+b' changed reporting')
                        current=b.shard_state(items,registry)
                        self.assertNotEqual(initial['source'],current['source'])
                        self.assertEqual(initial['production_source'],current['production_source'])
                        with patch.object(b.time,'time',return_value=456):
                            self.assertEqual(b.prepare_shard_workspace(workspace,current),123)
                        self.assertEqual((workspace/'state.json').read_bytes(),marker)
                        self.assertEqual((workspace/'state.json').stat().st_ino,inode)
                        for relative,data in retained.items():self.assertEqual((workspace/relative).read_bytes(),data)

    def test_qualification_edits_reuse_workspace_but_keep_audit_and_publication_guards(self):
        for name in ('tools/native_qualification.py','tools/test_native_qualification.py'):
            with self.subTest(name=name),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);sources,registry,items=self.fixture(root)
                tool=root/'zig';tool.write_bytes(b'unchanged compiler executable')
                staging=root/'staging';staging.mkdir();target=root/'published'
                with patch.object(b,'PROJECT',root),patch.object(b.shutil,'which',return_value=str(tool)):
                    initial=b.shard_state(items,registry);workspace=root/'work'
                    retained=self.seed(workspace,initial)
                    marker=(workspace/'state.json').read_bytes();inode=(workspace/'state.json').stat().st_ino
                    retained_inodes={relative:(workspace/relative).stat().st_ino for relative in retained}
                    identity=b.build_input_identity(items,'zig',{},None,100)
                    b.persist_build_identity(staging,identity)
                    original=(staging/b.BUILD_IDENTITY_NAME).read_bytes()
                    (staging/b.VERIFIED_MARKER).write_text(b.VERIFIED_CONTENT)
                    (root/name).write_bytes(sources[name]+b' changed qualification only')
                    current=b.shard_state(items,registry)
                    self.assertNotEqual(initial['source'],current['source'])
                    self.assertEqual(initial['production_source'],current['production_source'])
                    current_identity=b.build_input_identity(items,'zig',{},None,100)
                    self.assertEqual(current_identity,dict(identity,source=current['source']))
                    with self.assertRaisesRegex(ValueError,'Build inputs or compiler changed'):
                        b.require_build_identity(identity,current_identity)
                    with patch.object(b.time,'time',return_value=456):
                        self.assertEqual(b.prepare_shard_workspace(workspace,current),123)
                    self.assertEqual((workspace/'state.json').read_bytes(),marker)
                    self.assertEqual((workspace/'state.json').stat().st_ino,inode)
                    for relative,data in retained.items():
                        self.assertEqual((workspace/relative).read_bytes(),data)
                        self.assertEqual((workspace/relative).stat().st_ino,retained_inodes[relative])
                    with self.assertRaisesRegex(ValueError,'Compiler source changed'):
                        b.persist_build_identity(staging,identity)
                    with self.assertRaisesRegex(ValueError,'Compiler source changed'):
                        b._publish_verified_staging(staging,target,'testwiktionary','20261001',build_identity=identity)
                    self.assertEqual((staging/b.BUILD_IDENTITY_NAME).read_bytes(),original)
                    self.assertFalse(target.exists())

    def test_normal_failed_merge_resume_reuses_expander_and_shards_after_controller_edit(self):
        # Exercise the ordinary Python producer/verification/publication route.
        # Only native child execution is replaced, as in the existing merge
        # recovery fixture; this test earns no native dictionary acceptance.
        for compressed in (False,True):
            with self.subTest(compressed=compressed),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);self.fixture(root)
                folder=root/'testwiktionary/20260901';write_namespace_fixture(folder)
                name='testwiktionary-20260901-pages-meta-current.xml.bz2'
                data=bz2.compress(b'<mediawiki><page>word</page><page>second</page></mediawiki>')
                (folder/name).write_bytes(data)
                item=dict(wiki='testwiktionary',date='20260901',name=name,
                    url='https://dumps.wikimedia.org/testwiktionary/20260901/'+name,
                    size=len(data),sha1=hashlib.sha1(data).hexdigest())
                tool=root/'zig';tool.write_bytes(b'unchanged compiler executable')
                workspace=root/'output/testwiktionary/20260901.shards'
                calls=[];merges=[];retained={}
                def run(command):
                    calls.append(list(command))
                    if 'build-dictionary' in command:
                        dest=Path(tool_arguments(command)[1]);exp=dest/'.bundle-expander';exp.mkdir(parents=True)
                        (dest/'.incomplete').write_text('expander ready')
                        (exp/'page-index.tsv').write_text('0\n1\n')
                        (exp/'dict-bundle-expander').write_text('worker');write_namespace_fixture(exp)
                    elif blob_command(command,'build-blobs'):
                        dest=Path(tool_arguments(command)[1]);dest.mkdir(parents=True,exist_ok=True)
                        write_coverage(dest,command)
                    elif blob_command(command,'merge-blobs'):
                        merges.append(list(command))
                        if len(merges)==1:raise subprocess.CalledProcessError(1,command)
                        for relative,(contents,inode) in retained.items():
                            path=workspace/relative
                            self.assertEqual(path.read_bytes(),contents)
                            self.assertEqual(path.stat().st_ino,inode)
                        args=tool_arguments(command)
                        if args[0]=='--compress-output':args=args[1:]
                        dest=Path(args[0]);dest.mkdir()
                        write_namespace_coverage(dest,sum(json.loads((Path(p)/'page-coverage.json').read_text())['pages_seen'] for p in args[1:]))
                with patch.object(b,'PROJECT',root),patch.object(b,'SHARD_PAGES',1), \
                     patch.object(b.shutil,'which',return_value=str(tool)), \
                     patch.object(b.time,'time',return_value=123),patch.object(b,'run_checked',side_effect=run):
                    audit_before=b.source_fingerprint()
                    with self.assertRaises(subprocess.CalledProcessError):
                        b.build([item],root,root/'output','zig',1,compress_shards=compressed)
                    state=json.loads((workspace/'state.json').read_text())
                    self.assertEqual(state['source'],audit_before)
                    for relative in ('state.json','input/.complete.json','expander/.incomplete',
                                     'expander/.bundle-expander/page-index.tsv','expander/.bundle-expander/dict-bundle-expander',
                                     'shards/00000000/page-coverage.json','shards/00000000/.verified',
                                     'shards/00000001/page-coverage.json','shards/00000001/.verified'):
                        path=workspace/relative;retained[relative]=(path.read_bytes(),path.stat().st_ino)
                    first_builds=[c for c in calls if 'build-dictionary' in c or blob_command(c,'build-blobs')]
                    boundary=len(calls)
                    (root/'tools/corpus_controller.py').write_bytes(b'changed reporting only')
                    audit_after=b.source_fingerprint();self.assertNotEqual(audit_before,audit_after)
                    b.build([item],root,root/'output','zig',1,compress_shards=compressed)
                    self.assertEqual([c for c in calls if 'build-dictionary' in c or blob_command(c,'build-blobs')],first_builds)
                    verified={Path(tool_arguments(c)[0]) for c in calls[boundary:] if blob_command(c,'verify-blobs')}
                    self.assertTrue({workspace/'shards/00000000',workspace/'shards/00000001'}<=verified)
                    self.assertEqual(len(merges),2)
                    self.assertFalse(workspace.exists())
                    complete=json.loads((root/'output/testwiktionary/20260901/complete.json').read_text())
                    self.assertEqual(complete['input_pages'],2)
                    self.assertEqual(complete['build_inputs']['source'],audit_after)
                    self.assertEqual(complete['build_inputs']['zig_sha256'],hashlib.sha256(tool.read_bytes()).hexdigest())

    def test_producer_abi_other_tests_and_input_changes_invalidate_native_state(self):
        changes=('src/producer.zig','src/lua/runtime/abi.h','tools/extraction_cache.py',
                 'tools/test_other.py','tools/nested/corpus_controller.py',
                 'tools/nested/native_qualification.py','tools/nested/test_native_qualification.py','registry','dump')
        for changed in changes:
            with self.subTest(changed=changed),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);sources,registry,items=self.fixture(root)
                with patch.object(b,'PROJECT',root):
                    initial=b.shard_state(items,registry);workspace=root/'work'
                    retained=self.seed(workspace,initial)
                    if changed=='registry':registry.write_bytes(b'fr\tFrench\n')
                    elif changed=='dump':items=[dict(items[0],sha1='b'*40)]
                    else:(root/changed).write_bytes(sources[changed]+b' changed production')
                    current=b.shard_state(items,registry)
                    if changed in sources:self.assertNotEqual(initial['production_source'],current['production_source'])
                    else:self.assertEqual(initial['production_source'],current['production_source'])
                    with patch.object(b.time,'time',return_value=456):
                        self.assertEqual(b.prepare_shard_workspace(workspace,current),456)
                    self.assertFalse((workspace/'expander').exists())
                    self.assertFalse((workspace/'shards').exists())
                    self.assertEqual((workspace/'input/verified-dump').read_bytes(),retained['input/verified-dump'])

    def test_full_audit_framing_and_publication_guard_still_include_controller(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);sources,registry,items=self.fixture(root)
            legacy=hashlib.sha256()
            for name,data in sorted(sources.items()):legacy.update(name.encode()+b'\0'+data+b'\0')
            tool=root/'zig';tool.write_bytes(b'compiler executable')
            staging=root/'staging';staging.mkdir();target=root/'published'
            with patch.object(b,'PROJECT',root),patch.object(b.shutil,'which',return_value=str(tool)):
                self.assertEqual(b.source_fingerprint(),legacy.hexdigest())
                before=b.shard_state(items,registry)
                identity=b.build_input_identity(items,'zig',{},None,100)
                b.persist_build_identity(staging,identity)
                original=(staging/b.BUILD_IDENTITY_NAME).read_bytes()
                (staging/b.VERIFIED_MARKER).write_text(b.VERIFIED_CONTENT)
                (root/'tools/corpus_controller.py').write_bytes(b'changed controller reporting')
                after=b.shard_state(items,registry)
                self.assertEqual(before['production_source'],after['production_source'])
                self.assertNotEqual(identity['source'],b.source_fingerprint())
                with self.assertRaisesRegex(ValueError,'Compiler source changed'):
                    b.persist_build_identity(staging,identity)
                with self.assertRaisesRegex(ValueError,'Compiler source changed'):
                    b._publish_verified_staging(staging,target,'testwiktionary','20261001',build_identity=identity)
                self.assertEqual((staging/b.BUILD_IDENTITY_NAME).read_bytes(),original)
                self.assertFalse(target.exists())

    def test_historical_state_is_not_upgraded_or_given_production_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);_,registry,items=self.fixture(root)
            with patch.object(b,'PROJECT',root):
                current=b.shard_state(items,registry)
                legacy={k:v for k,v in current.items() if k!='production_source'};legacy['version']=2
                workspace=root/'work';retained=self.seed(workspace,legacy)
                marker=(workspace/'state.json').read_bytes()
                self.assertEqual(b.prepare_shard_workspace(workspace,legacy),123)
                with self.assertRaisesRegex(ValueError,'Legacy shard source identity'):
                    b.prepare_shard_workspace(workspace,current)
                self.assertEqual((workspace/'state.json').read_bytes(),marker)
                for relative,data in retained.items():self.assertEqual((workspace/relative).read_bytes(),data)

    def test_legacy_comparison_never_ignores_changed_audit_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            workspace=Path(tmp)/'work';legacy=dict(version=2,source='old-audit',production_source='a'*64)
            self.seed(workspace,legacy)
            with patch.object(b.time,'time',return_value=456):
                self.assertEqual(b.prepare_shard_workspace(workspace,dict(legacy,source='changed-audit')),456)
            self.assertFalse((workspace/'expander').exists())
            self.assertFalse((workspace/'shards').exists())

    def test_incomplete_new_identity_is_rejected_without_mutating_workspace(self):
        for field in ('source','production_source'):
            for value in (None,'','g'*64,'a'*63,'missing'):
                with self.subTest(field=field,value=value),tempfile.TemporaryDirectory() as tmp:
                    root=Path(tmp);_,registry,items=self.fixture(root)
                    with patch.object(b,'PROJECT',root):
                        state=b.shard_state(items,registry);workspace=root/'work';self.seed(workspace,state)
                        malformed=dict(state,now_unix=123);malformed[field]=value
                        if value=='missing':del malformed[field]
                        marker=json.dumps(malformed,sort_keys=True).encode();(workspace/'state.json').write_bytes(marker)
                        with self.assertRaisesRegex(ValueError,'Invalid shard source identity'):
                            b.prepare_shard_workspace(workspace,state)
                        self.assertEqual((workspace/'state.json').read_bytes(),marker)
                        self.assertEqual((workspace/'shards/00000000/blob').read_bytes(),b'completed shard')


class PresentationRetryPolicyTests(unittest.TestCase):
    def exercise(self, mode):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);shard=root/'00000000';calls=[];validated=[]
            tool=fixture_blob_tool(root);command=['dump',str(shard),'--start-page','0','--limit-pages','2']
            def run(argv, *args, **kwargs):
                calls.append(argv);shard.mkdir();(shard/'partial').write_text('retained failure bytes')
                if len(calls)>1: return
                if mode!='transient':
                    invocation=argv[argv.index('--invocation-id')+1]
                    receipt=Path(argv[argv.index('--failure-receipt')+1])
                    receipt.write_text(json.dumps(dict(schema='wikidict.blob-build.failure.v1',
                        error_name='OtherFailure' if mode=='unknown' else 'UncompiledPresentation',failure_class='deterministic-presentation',
                        invocation_id='old-invocation' if mode=='stale' else invocation,
                        invocation_args=tool_arguments(argv)+(['--different-context'] if mode=='argv-mismatch' else []),
                        page=dict(ordinal=2 if mode=='out-of-range' else 1,namespace=114,title='fixture',page_id=7,revision_id=9))))
                    if mode=='malformed': receipt.write_text('{')
                raise subprocess.CalledProcessError(1,argv)
            with patch.object(b,'timed_run',side_effect=run):
                if mode=='deterministic':
                    with self.assertRaises(b.DeterministicPresentationFailure) as failed:
                        b.build_shard_with_retries(tool,command,shard,root/'failures','enwiktionary','20261001',0,2,lambda:None,lambda:validated.append(True))
                    self.assertTrue(Path(failed.exception.failure_receipt).is_file())
                    self.assertEqual(len(calls),1);self.assertEqual(validated,[])
                    self.assertEqual((shard/'partial').read_text(),'retained failure bytes')
                else:
                    with self.assertRaises(subprocess.CalledProcessError) as failed:
                        b.build_shard_with_retries(tool,command,shard,root/'failures','enwiktionary','20261001',0,2,lambda:None,lambda:validated.append(True))
                    self.assertNotIsInstance(failed.exception,b.DeterministicPresentationFailure)
                    self.assertNotIsInstance(failed.exception,b.DeterministicBuildInputFailure)
                    self.assertEqual(len(calls),1);self.assertEqual(validated,[])
            evidence=list((root/'failures').iterdir())
            self.assertEqual(len(evidence),1)
            self.assertEqual(json.loads((evidence[0]/'exit.json').read_text())['returncode'],1)
            self.assertTrue((evidence[0]/'invocation.json').is_file())

    def exercise_missing_build_input(self, error_name):
        modes=('matching','stale','argv','page','class','name','worker-name','stage','detail','source-hash','source-size','missing-source')
        for mode in modes:
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);shard=root/'shard';calls=[];checked=[];validated=[];errors=[]
                tool=fixture_blob_tool(root);command=['dump',str(shard)]
                def run(argv,*args,**kwargs):
                    calls.append(argv);shard.mkdir();(shard/'partial').write_bytes(b'retained bytes')
                    if len(calls)>1:return
                    receipt=Path(argv[argv.index('--failure-receipt')+1])
                    row=dict(schema='wikidict.blob-build.failure.v1',error_name=error_name,
                        failure_class='deterministic-build-input',invocation_id=argv[argv.index('--invocation-id')+1],
                        invocation_args=tool_arguments(argv),page=dict(ordinal=1,namespace=0,title='fixture',page_id=7,revision_id=9),
                        source=dict(bytes=12,sha256=hashlib.sha256(b'{{int:Show}}').hexdigest()),
                        worker=dict(stage='expand',error_name=error_name,detail=error_name))
                    if mode=='stale':row['invocation_id']='old'
                    if mode=='argv':row['invocation_args']=row['invocation_args']+['changed']
                    if mode=='page':row['page']['ordinal']=2
                    if mode=='class':row['failure_class']='deterministic-presentation'
                    if mode=='name':row['error_name']='ExampleLuaError'
                    if mode=='worker-name':row['worker']['error_name']='ExampleLuaError'
                    if mode=='stage':row['worker']['stage']='assets'
                    if mode=='detail':row['worker']['detail']=None
                    if mode=='source-hash':row['source']['sha256']='not-a-hash'
                    if mode=='source-size':row['source']['bytes']=True
                    if mode=='missing-source':del row['source']
                    receipt.write_text(json.dumps(row))
                    error=subprocess.CalledProcessError(23,argv,output=b'original stdout',
                        stderr=b'interface message missing: language=it key=show\noriginal stderr')
                    errors.append(error);raise error
                with patch.object(b,'timed_run',side_effect=run):
                    if mode=='matching':
                        with self.assertRaises(b.DeterministicBuildInputFailure) as failed:
                            b.build_shard_with_retries(tool,command,shard,root/'failures','itwiktionary','20261001',0,2,
                                lambda:checked.append(True),lambda:validated.append(True))
                        self.assertIs(failed.exception.__cause__,errors[0])
                        self.assertEqual(failed.exception.returncode,23)
                        self.assertEqual(failed.exception.cmd,calls[0])
                        self.assertEqual(Path(calls[0][0]).name,'dict-blob-build')
                        self.assertNotIn('--',calls[0])
                        self.assertEqual(failed.exception.output,errors[0].output)
                        self.assertEqual(failed.exception.stderr,errors[0].stderr)
                        self.assertEqual(len(calls),1);self.assertEqual(checked,[True]);self.assertEqual(validated,[])
                        self.assertEqual((shard/'partial').read_bytes(),b'retained bytes')
                        receipt=Path(failed.exception.failure_receipt)
                        self.assertEqual(json.loads(receipt.read_text())['worker']['error_name'],error_name)
                        self.assertEqual(json.loads((receipt.parent/'classification.json').read_text()),
                            dict(deterministic_presentation=False,deterministic_build_input=True))
                    else:
                        with self.assertRaises(subprocess.CalledProcessError) as failed:
                            b.build_shard_with_retries(tool,command,shard,root/'failures','itwiktionary','20261001',0,2,
                                lambda:checked.append(True),lambda:validated.append(True))
                        self.assertIs(failed.exception,errors[0])
                        self.assertNotIsInstance(failed.exception,b.DeterministicBuildInputFailure)
                        self.assertEqual(len(calls),1);self.assertEqual(checked,[True]);self.assertEqual(validated,[])


    def test_missing_interface_input_stops_once_only_with_bound_typed_evidence(self):
        self.exercise_missing_build_input('InterfaceMessageSnapshotMissing')

    def test_missing_file_metadata_stops_once_only_with_bound_typed_evidence(self):
        self.exercise_missing_build_input('FileMetadataSnapshotMissing')

    def test_matching_presentation_failure_stops_and_preserves(self):
        self.exercise('deterministic')

    def test_unclassified_exit_stops_without_positive_transient_evidence(self):
        self.exercise('transient')

    def test_stale_presentation_receipt_stops_and_retains_evidence(self):
        self.exercise('stale')

    def test_unknown_or_malformed_receipt_stops_unclassified(self):
        for mode in ('unknown','malformed'):
            with self.subTest(mode=mode): self.exercise(mode)

    def test_full_argv_mismatch_or_out_of_range_page_stops_unclassified(self):
        for mode in ('argv-mismatch','out-of-range'):
            with self.subTest(mode=mode): self.exercise(mode)

    def test_evidence_and_logging_write_errors_keep_typed_failure_and_identity_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);shard=root/'00000000';calls=[];checked=[];original=[];failed_writes=[]
            tool=fixture_blob_tool(root);command=['dump',str(shard)]
            real_write_text=Path.write_text
            def write_text(path, text, *args, **kwargs):
                if path.name in ('exit.json','classification.json'):
                    failed_writes.append(path.name)
                    raise OSError('simulated evidence disk error')
                return real_write_text(path,text,*args,**kwargs)
            def run(argv, *args, **kwargs):
                calls.append(argv);shard.mkdir();(shard/'partial').write_text('retained bytes')
                receipt=Path(argv[argv.index('--failure-receipt')+1])
                receipt.write_text(json.dumps(dict(schema='wikidict.blob-build.failure.v1',
                    error_name='UncompiledPresentation',failure_class='deterministic-presentation',
                    invocation_id=argv[argv.index('--invocation-id')+1],invocation_args=tool_arguments(argv),
                    page=dict(ordinal=1,namespace=114,title='fixture',page_id=7,revision_id=9))))
                error=subprocess.CalledProcessError(23,argv,output=b'original stdout',stderr=b'original stderr')
                original.append(error)
                raise error
            with patch.object(b,'timed_run',side_effect=run), \
                 patch.object(Path,'write_text',new=write_text), \
                 patch.object(b,'phase_event',wraps=b.phase_event) as event, \
                 patch('builtins.print',side_effect=OSError('simulated stderr error')):
                with self.assertRaises(b.DeterministicPresentationFailure) as failed:
                    b.build_shard_with_retries(tool,command,shard,root/'failures','enwiktionary','20261001',0,2,
                        lambda:checked.append(True),lambda:self.fail('failed builder cannot validate'))
            self.assertEqual(checked,[True]);self.assertEqual(len(calls),1)
            event.assert_called_once()
            self.assertEqual(event.call_args.args[3],'retry_suppressed')
            self.assertEqual(failed_writes,['exit.json','classification.json'])
            self.assertIs(failed.exception.__cause__,original[0])
            self.assertEqual(failed.exception.returncode,23)
            self.assertEqual(failed.exception.cmd,original[0].cmd)
            self.assertEqual(failed.exception.output,b'original stdout')
            self.assertEqual(failed.exception.stderr,b'original stderr')
            self.assertTrue(Path(failed.exception.failure_receipt).is_file())
            self.assertEqual((shard/'partial').read_text(),'retained bytes')

    def test_coverage_evidence_write_error_keeps_original_coverage_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);shard=root/'00000000';checked=[];writes=[]
            tool=fixture_blob_tool(root);command=['dump',str(shard)]
            coverage_error=ValueError('original invalid coverage')
            real_write_text=Path.write_text
            def write_text(path, text, *args, **kwargs):
                if path.name=='coverage-error.json':
                    writes.append(path.name)
                    raise OSError('simulated evidence disk error')
                return real_write_text(path,text,*args,**kwargs)
            def run(*args, **kwargs): shard.mkdir()
            def validate(): raise coverage_error
            stderr=io.StringIO()
            with patch.object(b,'timed_run',side_effect=run),patch.object(Path,'write_text',new=write_text),contextlib.redirect_stderr(stderr):
                with self.assertRaises(ValueError) as failed:
                    b.build_shard_with_retries(tool,command,shard,root/'failures','enwiktionary','20261001',0,2,
                        lambda:checked.append(True),validate)
            self.assertIs(failed.exception,coverage_error)
            self.assertEqual(len(checked),b.SHARD_RETRIES)
            self.assertEqual(len(writes),b.SHARD_RETRIES)
            warnings=stderr.getvalue().splitlines()
            self.assertEqual(len(warnings),b.SHARD_RETRIES)
            for warning in warnings:
                self.assertTrue(warning.startswith(f'Unable to write shard failure evidence: {root}/failures/'))
                self.assertTrue(warning.endswith('/coverage-error.json'))

    def test_changed_input_after_failure_preserves_receipt_and_bypasses_classification(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);shard=root/'00000000';calls=[]
            tool=fixture_blob_tool(root);command=['dump',str(shard),'--start-page','0','--limit-pages','2']
            identity_error=ValueError('Page index identity changed')
            def run(argv, *args, **kwargs):
                calls.append(argv);shard.mkdir();(shard/'partial').write_text('failed bytes')
                receipt=Path(argv[argv.index('--failure-receipt')+1])
                receipt.write_text(json.dumps(dict(schema='wikidict.blob-build.failure.v1',
                    error_name='UncompiledPresentation',failure_class='deterministic-presentation',
                    invocation_id=argv[argv.index('--invocation-id')+1],
                    invocation_args=tool_arguments(argv),
                    page=dict(ordinal=1,namespace=114,title='fixture',page_id=7,revision_id=9))))
                raise subprocess.CalledProcessError(1,argv)
            with patch.object(b,'timed_run',side_effect=run), \
                 patch.object(b,'matching_build_failure') as classify:
                def changed_identity(): raise identity_error
                with self.assertRaises(ValueError) as failed:
                    b.build_shard_with_retries(tool,command,shard,root/'failures','enwiktionary','20261001',0,2,changed_identity,lambda:None)
                self.assertIs(failed.exception,identity_error)
                classify.assert_not_called()
            self.assertEqual(len(calls),1)
            evidence=list((root/'failures').iterdir());self.assertEqual(len(evidence),1)
            self.assertTrue((evidence[0]/'failure.json').is_file())
            self.assertTrue((evidence[0]/'invocation.json').is_file())
            self.assertEqual(json.loads((evidence[0]/'exit.json').read_text())['returncode'],1)
            self.assertFalse((evidence[0]/'classification.json').exists())
            self.assertEqual((shard/'partial').read_text(),'failed bytes')
    def template_capture(self, receipt, argv):
        capture=receipt.parent/'.presentation-first-failure';capture.mkdir()
        args=tool_arguments(argv);identity=argv[argv.index('--invocation-id')+1]
        digest=hashlib.sha256()
        for arg in args:
            data=arg.encode();digest.update(len(data).to_bytes(8,'little'));digest.update(data)
        title='Белград'
        row=dict(schema='wikidict.presentation-first-failure.v1',record_complete=True,diagnostic_only=True,
                 publication_created=False,semantic_acceptance=False,error_name='UncompiledTemplate',
                 invocation_id=identity,invocation_args_sha256=digest.hexdigest(),
                 invocation_args_hash_framing='each argv item: u64 little-endian byte length then exact bytes',
                 ordinal=1,namespace=0,page_id=662,revision_id=1135263,title=title,
                 title_bytes=len(title.encode()),title_sha256=hashlib.sha256(title.encode()).hexdigest(),title_truncated=False,
                 input=dict(dump_path='dump',expander_root='bundle',start_page=0,requested_limit=2),payload_limit_bytes=4*1024*1024)
        parts={'raw_source':('raw.wikitext',b'{{one}}'),'expanded':('expanded.wikitext',b'{{one|two}}'),
               'index_row':('index-row.tsv',b'exact original row'),'display_title':('display-title.wikitext',None),
               'poem_metadata':('poem.json',None),'missing_dependency_metadata':('missing-dependency.json',None),'alias_record':('alias.json',None)}
        for key,(suffix,data) in parts.items():
            path=capture/('failure-00000001-'+suffix)
            if data is not None:path.write_bytes(data)
            row[key]=dict(present=data is not None,bytes=len(data) if data is not None else 0,
                          sha256=hashlib.sha256(data).hexdigest() if data is not None else None,
                          path=str(path) if data is not None else None,retained_bytes=len(data) if data is not None else 0,
                          truncated=False,unretained=False)
        return capture/'capture.json',row

    def exercise_template_capture(self, change=None, identity_failure=False, no_capture=False, *, error_name='UncompiledTemplate'):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);shard=root/'00000000';calls=[];captures=[];validated=[];original=[]
            tool=fixture_blob_tool(root);command=['dump',str(shard),'--expander-root','bundle','--start-page','0','--limit-pages','2']
            def run(argv,*args,**kwargs):
                calls.append(argv);shard.mkdir();(shard/'partial').write_text('retained failure bytes')
                if len(calls)>1:return
                receipt=Path(argv[argv.index('--failure-receipt')+1])
                if not no_capture:
                    path,row=self.template_capture(receipt,argv)
                    row['error_name']=error_name
                    if change:change(row,path,receipt)
                    path.write_text(json.dumps(row));captures.append(path)
                failure=subprocess.CalledProcessError(1,argv,output=b'original stdout',stderr=error_name)
                original.append(failure);raise failure
            def check():
                if identity_failure:raise ValueError('input identity changed')
            with patch.object(b,'timed_run',side_effect=run),patch.object(b,'phase_event') as event:
                if identity_failure:
                    with patch.object(b,'matching_build_failure') as classify:
                        with self.assertRaisesRegex(ValueError,'input identity changed'):
                            b.build_shard_with_retries(tool,command,shard,root/'failures','bgwiktionary','20261001',0,2,check,lambda:None)
                        classify.assert_not_called()
                    self.assertEqual(len(calls),1)
                elif change is None and not no_capture:
                    with self.assertRaises(b.DeterministicPresentationFailure) as failed:
                        b.build_shard_with_retries(tool,command,shard,root/'failures','bgwiktionary','20261001',0,2,check,lambda:validated.append(True))
                    self.assertEqual(len(calls),1);self.assertEqual(validated,[])
                    self.assertEqual(failed.exception.failure_receipt,str(captures[0]))
                    self.assertEqual(failed.exception.returncode,1)
                    self.assertEqual(event.call_args.kwargs['error_name'],error_name)
                    self.assertIs(failed.exception.__cause__,original[0])
                    self.assertEqual(failed.exception.cmd,original[0].cmd)
                    self.assertEqual(failed.exception.output,original[0].output)
                    self.assertEqual(failed.exception.stderr,original[0].stderr)
                    self.assertEqual(json.loads((captures[0].parents[1]/'classification.json').read_text())['deterministic_presentation'],True)
                    self.assertEqual((shard/'partial').read_text(),'retained failure bytes')
                else:
                    with self.assertRaises(subprocess.CalledProcessError) as failed:
                        b.build_shard_with_retries(tool,command,shard,root/'failures','bgwiktionary','20261001',0,2,check,lambda:validated.append(True))
                    self.assertIs(failed.exception,original[0])
                    self.assertNotIsInstance(failed.exception,b.DeterministicPresentationFailure)
                    self.assertEqual(len(calls),1);self.assertEqual(validated,[])

    def test_complete_typed_template_capture_stops_first_identical_retry(self):
        self.exercise_template_capture()

    def test_template_capture_generic_exit_and_stderr_do_not_classify(self):
        self.exercise_template_capture(no_capture=True)

    def test_template_capture_requires_current_invocation_and_exact_framed_arguments(self):
        changes=[lambda r,p,f:r.update(invocation_id='stale'),lambda r,p,f:r.update(invocation_args_sha256='0'*64),
                 lambda r,p,f:r.update(invocation_args_hash_framing='joined strings')]
        for change in changes:
            with self.subTest(change=change):self.exercise_template_capture(change)

    def test_template_capture_rejects_other_errors_incomplete_and_foreign_page_context(self):
        for fields in [dict(error_name='InvalidPreContextExtra'),dict(record_complete=False),dict(publication_created=True),
                       dict(title_truncated=True),dict(title_sha256='0'*64),dict(ordinal=2),dict(namespace=True),dict(page_id=-1)]:
            with self.subTest(fields=fields):self.exercise_template_capture(lambda r,p,f:r.update(fields))
        self.exercise_template_capture(lambda r,p,f:r['input'].update(dump_path='other'))
        self.exercise_template_capture(lambda r,p,f:r['input'].update(expander_root='other'))

    def test_template_capture_requires_complete_unchanged_bounded_payloads(self):
        for fields in [dict(truncated=True),dict(unretained=True),dict(bytes=3*1024*1024),dict(sha256='0'*64),dict(retained_bytes=0)]:
            with self.subTest(fields=fields):self.exercise_template_capture(lambda r,p,f:r['expanded'].update(fields))
        self.exercise_template_capture(lambda r,p,f:r['display_title'].update(truncated=True))
        self.exercise_template_capture(lambda r,p,f:Path(r['raw_source']['path']).write_bytes(b'changed'))
        self.exercise_template_capture(lambda r,p,f:Path(r['index_row']['path']).unlink())

    def test_template_capture_rejects_foreign_or_symlinked_payloads(self):
        self.exercise_template_capture(lambda r,p,f:r['raw_source'].update(path=str(p.parent/'other')))
        def symlink(row,path,receipt):
            target=Path(row['raw_source']['path']);data=target.read_bytes();target.unlink();other=receipt.parent/'outside';other.write_bytes(data);target.symlink_to(other)
        self.exercise_template_capture(symlink)

    def test_template_capture_cannot_override_existing_unknown_receipt(self):
        self.exercise_template_capture(lambda r,p,f:f.write_text(json.dumps(dict(error_name='OtherFailure'))))

    def test_template_capture_refuses_nonregular_files_before_open(self):
        def payload_fifo(row,path,receipt):
            target=Path(row['raw_source']['path']);target.unlink();os.mkfifo(target)
        self.exercise_template_capture(payload_fifo)
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)/'invocation';root.mkdir();capture=root/'.presentation-first-failure';capture.mkdir()
            os.mkfifo(capture/'capture.json')
            with patch.object(Path,'open',side_effect=AssertionError('nonregular capture opened')):
                self.assertFalse(b.matching_presentation_capture(root/'failure.json','invocation',['dump','output'],0,2))

    def test_template_capture_changed_input_precedes_any_classification(self):
        self.exercise_template_capture(identity_failure=True)

    def test_complete_heading_projection_capture_stops_first_identical_retry(self):
        self.exercise_template_capture(error_name='InvalidHeadingProjection')

    def test_heading_projection_capture_requires_current_invocation_and_page_context(self):
        changes=[lambda r,p,f:r.update(invocation_id='stale'),
                 lambda r,p,f:r.update(invocation_args_sha256='0'*64),
                 lambda r,p,f:r.update(invocation_args_hash_framing='joined strings'),
                 lambda r,p,f:r.update(ordinal=2),
                 lambda r,p,f:r.update(title_sha256='0'*64),
                 lambda r,p,f:r['input'].update(dump_path='other'),
                 lambda r,p,f:r['input'].update(expander_root='other')]
        for change in changes:
            with self.subTest(change=change):
                self.exercise_template_capture(change,error_name='InvalidHeadingProjection')

    def test_heading_projection_capture_requires_complete_unchanged_payload(self):
        for fields in [dict(record_complete=False),dict(diagnostic_only=False),
                       dict(publication_created=True),dict(semantic_acceptance=True)]:
            with self.subTest(fields=fields):
                self.exercise_template_capture(lambda r,p,f:r.update(fields),error_name='InvalidHeadingProjection')
        for fields in [dict(truncated=True),dict(unretained=True),dict(bytes=3*1024*1024),
                       dict(sha256='0'*64),dict(retained_bytes=0)]:
            with self.subTest(payload=fields):
                self.exercise_template_capture(lambda r,p,f:r['expanded'].update(fields),error_name='InvalidHeadingProjection')
        self.exercise_template_capture(lambda r,p,f:Path(r['raw_source']['path']).write_bytes(b'changed'),
                                       error_name='InvalidHeadingProjection')
        self.exercise_template_capture(lambda r,p,f:Path(r['index_row']['path']).unlink(),
                                       error_name='InvalidHeadingProjection')

    def test_heading_projection_capture_never_classifies_exit_stderr_or_unknown_receipt(self):
        self.exercise_template_capture(no_capture=True,error_name='InvalidHeadingProjection')
        self.exercise_template_capture(lambda r,p,f:f.write_text(json.dumps(dict(error_name='OtherFailure'))),
                                       error_name='InvalidHeadingProjection')
        for error in ('OutOfMemory','Cancelled','InvalidPreContextExtra','OtherFailure'):
            with self.subTest(error=error):
                self.exercise_template_capture(lambda r,p,f:r.update(error_name=error),error_name='InvalidHeadingProjection')

    def test_heading_projection_capture_changed_input_precedes_classification(self):
        self.exercise_template_capture(identity_failure=True,error_name='InvalidHeadingProjection')

    def test_complete_render_limit_capture_stops_first_identical_retry(self):
        self.exercise_template_capture(error_name='RenderLimit')

    def test_render_limit_capture_requires_current_page_input_and_complete_payload(self):
        changes=[lambda r,p,f:r.update(invocation_id='stale'),
                 lambda r,p,f:r.update(invocation_args_sha256='0'*64),
                 lambda r,p,f:r.update(ordinal=2),
                 lambda r,p,f:r.update(title_sha256='0'*64),
                 lambda r,p,f:r['input'].update(dump_path='other'),
                 lambda r,p,f:r['input'].update(expander_root='other'),
                 lambda r,p,f:r.update(record_complete=False),
                 lambda r,p,f:r.update(semantic_acceptance=True),
                 lambda r,p,f:r['expanded'].update(truncated=True),
                 lambda r,p,f:r['expanded'].update(unretained=True),
                 lambda r,p,f:r['expanded'].update(bytes=3*1024*1024),
                 lambda r,p,f:r['expanded'].update(sha256='0'*64),
                 lambda r,p,f:Path(r['raw_source']['path']).write_bytes(b'changed'),
                 lambda r,p,f:Path(r['index_row']['path']).unlink()]
        for change in changes:
            with self.subTest(change=change):
                self.exercise_template_capture(change,error_name='RenderLimit')

    def test_render_limit_generic_exit_unknown_receipt_and_transient_labels_stop_unclassified(self):
        self.exercise_template_capture(no_capture=True,error_name='RenderLimit')
        for outer in ('{',json.dumps(dict(error_name='RenderLimit')),
                      json.dumps(dict(error_name='OtherFailure'))):
            with self.subTest(outer=outer):
                self.exercise_template_capture(lambda r,p,f:f.write_text(outer),error_name='RenderLimit')
        for error in ('OutOfMemory','Cancelled','InputOutput','FileNotFound','InvalidPreContextExtra','OtherFailure'):
            with self.subTest(error=error):
                self.exercise_template_capture(lambda r,p,f:r.update(error_name=error),error_name='RenderLimit')

    def test_render_limit_changed_input_precedes_capture_classification(self):
        self.exercise_template_capture(identity_failure=True,error_name='RenderLimit')

    def test_complete_precontext_capture_stops_first_identical_retry(self):
        self.exercise_template_capture(error_name='InvalidPreContext')

    def test_precontext_capture_requires_exact_current_complete_payload(self):
        changes=[lambda r,p,f:r.update(invocation_id='stale'),
                 lambda r,p,f:r.update(invocation_args_sha256='0'*64),
                 lambda r,p,f:r.update(ordinal=2),
                 lambda r,p,f:r['input'].update(dump_path='other'),
                 lambda r,p,f:r.update(record_complete=False),
                 lambda r,p,f:r['expanded'].update(truncated=True),
                 lambda r,p,f:Path(r['raw_source']['path']).write_bytes(b'changed'),
                 lambda r,p,f:Path(r['index_row']['path']).unlink(),
                 lambda r,p,f:f.write_text(json.dumps(dict(error_name='InvalidPreContext')))]
        for change in changes:
            with self.subTest(change=change):
                self.exercise_template_capture(change,error_name='InvalidPreContext')
        self.exercise_template_capture(identity_failure=True,error_name='InvalidPreContext')

    def test_precontext_prose_and_transient_failures_do_not_classify(self):
        self.exercise_template_capture(no_capture=True,error_name='InvalidPreContext')
        for error in ('OutOfMemory','Cancelled','InputOutput','FileNotFound','InvalidPreContextExtra'):
            def prose(row,path,receipt):
                row['error_name']=error
                title='InvalidPreContext: literal user title'
                row.update(title=title,title_bytes=len(title.encode()),title_sha256=hashlib.sha256(title.encode()).hexdigest())
                payload=Path(row['expanded']['path']);data=b'error: InvalidPreContext\nraw page prose'
                payload.write_bytes(data)
                row['expanded'].update(bytes=len(data),retained_bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
            with self.subTest(error=error):self.exercise_template_capture(prose,error_name='InvalidPreContext')

    def test_precontext_failure_and_capture_survive_payload_retirement(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);shard=root/'00000000';calls=[];original=[]
            tool=fixture_blob_tool(root);command=['dump',str(shard),'--expander-root','bundle']
            def run(argv,*args,**kwargs):
                calls.append(argv);shard.mkdir();(shard/'.spool').mkdir()
                (shard/'.spool/lang-00.tmp').write_bytes(b'disposable partial output')
                receipt=Path(argv[argv.index('--failure-receipt')+1])
                path,row=self.template_capture(receipt,argv);row['error_name']='InvalidPreContext';path.write_text(json.dumps(row))
                capture=shard/'.presentation-first-failure';capture.mkdir()
                (capture/'capture.json').write_bytes(path.read_bytes())
                error=subprocess.CalledProcessError(1,argv,output=b'exact stdout',stderr=b'exact stderr')
                original.append(error);raise error
            with patch.object(b,'timed_run',side_effect=run):
                with self.assertRaises(b.DeterministicPresentationFailure) as failed:
                    b.build_shard_with_retries(tool,command,shard,root/'failures','itwiktionary','20261001',0,2,lambda:None,lambda:self.fail('failed build validated'))
            self.assertEqual(len(calls),1);self.assertIs(failed.exception.__cause__,original[0])
            self.assertEqual(failed.exception.output,b'exact stdout');self.assertEqual(failed.exception.stderr,b'exact stderr')
            capture=Path(failed.exception.failure_receipt);before=capture.read_bytes()
            self.assertFalse((shard/'.spool/lang-00.tmp').exists())
            archived=capture.parents[1]/'shard-diagnostics/.presentation-first-failure/capture.json'
            self.assertEqual(archived.read_bytes(),before)
            b.remove_artifact_tree(shard)
            self.assertEqual(capture.read_bytes(),before);self.assertEqual(archived.read_bytes(),before)

class FailedShardPayloadCleanupTests(unittest.TestCase):
    def fixture(self, root):
        edition='testwiktionary'; date='20261001'
        cfg=dict(output=str(root/'output'),raw_shard_root=str(root/'raw'),date=date)
        workspace=Path(cfg['output'])/edition/(date+'.shards'); workspace.mkdir(parents=True)
        raw=Path(cfg['raw_shard_root'])/edition/(date+'.raw-shards')
        b.external_raw_shards(workspace,raw,create=True)
        (workspace/'state.json').write_text(json.dumps(dict(raw_shards_path=str(raw))))
        inputs=workspace/'input'; inputs.mkdir(); (inputs/'pages.xml.zst').write_bytes(b'original input')
        cache=inputs/'extraction-cache'; cache.mkdir(); (cache/'source').write_bytes(b'required extraction')
        shard=raw/'00000000'; shard.mkdir(); (shard/'.spool').mkdir(); (shard/'languages').mkdir()
        payload=[]
        names=[f'lang-{i:02d}.tmp' for i in range(32)]+[name+'.tmp' for name in
            ('thesaurus','citations','reconstruction','rhymes','sign-gloss','supplemental','aliases')]
        for name in names:
            path=shard/'.spool'/name; path.write_bytes(b'generated spool'); payload.append(path)
        for i in range(195):
            path=shard/'languages'/(hashlib.sha256(str(i).encode()).hexdigest()+'.wikblb')
            path.write_bytes(b'generated language output'); payload.append(path)
        (shard/'languages.tsv').write_bytes(b'')
        (shard/'fallback-pages.jsonl').write_bytes(b'exact fallback diagnostic\n')
        capture=shard/'.presentation-first-failure'; capture.mkdir()
        (capture/'capture.json').write_bytes(b'{"record_complete":false}\n')
        (capture/'raw.wikitext').write_bytes(b'exact first failure source')
        (shard/'unique-source-note').write_bytes(b'keep unknown evidence')
        verified=raw/'00100000'; verified.mkdir(); (verified/'.verified').write_text('verified\n')
        (verified/'retained.wikblb').write_bytes(b'complete verified work')
        folder=root/'attempt'; folder.mkdir(); (folder/'build.log').write_bytes(b'original failed attempt log')
        external=workspace.with_name(workspace.name+'.failures')/'invocation'; external.mkdir(parents=True)
        (external/'failure.json').write_bytes(b'exact original typed receipt')
        closed=dict(outcome='failed',accepted=None,controller_interrupted=False,exit_code=-9,
                    cleanup_proven=True,source_guard=True,control_proven=True)
        return cfg,edition,workspace,raw,shard,payload,folder,external,closed

    def test_eligible_closed_attempt_retires_234_generated_files_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);cfg,edition,workspace,raw,shard,payload,folder,external,closed=self.fixture(root)
            original=dict(closed); allocated=sum(path.stat().st_blocks*512 for path in payload)
            result=b.cleanup_failed_attempt_shards(cfg,edition,folder,closed)
            retired=next(row for row in result['shards'] if row['shard']==str(shard))
            self.assertEqual(closed,original); self.assertEqual(retired['status'],'generated-payload-retired')
            self.assertEqual(len(retired['removed']),234); self.assertEqual(retired['allocated_file_bytes_removed'],allocated)
            self.assertFalse(retired['exclusive_filesystem_gain_claimed'])
            self.assertTrue(all(not path.exists() for path in payload))
            self.assertEqual((shard/'fallback-pages.jsonl').read_bytes(),b'exact fallback diagnostic\n')
            self.assertEqual((shard/'.presentation-first-failure/raw.wikitext').read_bytes(),b'exact first failure source')
            self.assertEqual((shard/'unique-source-note').read_bytes(),b'keep unknown evidence')
            self.assertEqual((workspace/'input/pages.xml.zst').read_bytes(),b'original input')
            self.assertEqual((workspace/'input/extraction-cache/source').read_bytes(),b'required extraction')
            self.assertEqual((raw/'00100000/retained.wikblb').read_bytes(),b'complete verified work')
            self.assertEqual((external/'failure.json').read_bytes(),b'exact original typed receipt')
            self.assertEqual((folder/'build.log').read_bytes(),b'original failed attempt log')
            for row in retired['diagnostics']:
                source=Path(row['original']); archived=Path(row['retained'])
                self.assertEqual(source.read_bytes(),archived.read_bytes())
                self.assertNotEqual(source.stat().st_ino,archived.stat().st_ino)
                self.assertEqual(hashlib.sha256(archived.read_bytes()).hexdigest(),row['sha256'])

    def test_unproven_interrupted_and_accepted_attempts_do_not_touch_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg,edition,workspace,raw,shard,payload,folder,external,closed=self.fixture(Path(tmp))
            for key,value in [('cleanup_proven',False),('source_guard',False),('control_proven',False),
                              ('controller_interrupted',True),('accepted',{'root':'published'}),('exit_code',0)]:
                with self.subTest(key=key):
                    result=b.cleanup_failed_attempt_shards(cfg,edition,folder,dict(closed,**{key:value}))
                    self.assertEqual(result['status'],'retained-unproven-or-complete-attempt')
                    self.assertTrue(all(path.is_file() for path in payload))
                    self.assertFalse((folder/'generated-shard-diagnostics').exists())

    def test_completion_markers_and_nonempty_catalog_preserve_all_payload(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg,edition,workspace,raw,shard,payload,folder,external,closed=self.fixture(Path(tmp))
            for name in ('.verified','page-coverage.json','namespace-coverage.json','complete.json','languages.tsv'):
                with self.subTest(name=name):
                    marker=shard/name; marker.write_bytes(b'completed work')
                    result=b.cleanup_incomplete_shard_payload(shard,folder/'never-created')
                    self.assertEqual(result['status'],'retained-completed'); self.assertTrue(all(path.exists() for path in payload))
                    if name=='languages.tsv': marker.write_bytes(b'')
                    else: marker.unlink()
            self.assertFalse((folder/'never-created').exists())

    def test_shared_payload_inode_and_unknown_files_are_not_unlinked(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg,edition,workspace,raw,shard,payload,folder,external,closed=self.fixture(Path(tmp))
            shared=payload[-1]; alias=workspace/'input/retained-shared-blob'; os.link(shared,alias)
            before=shared.stat(); unknown=shard/'.spool/unrecognized.trace'; unknown.write_bytes(b'unique trace')
            result=b.cleanup_incomplete_shard_payload(shard,folder/'diagnostics')
            self.assertEqual(len(result['removed']),233); self.assertTrue(shared.is_file())
            self.assertEqual(shared.stat().st_ctime_ns,before.st_ctime_ns); self.assertEqual(alias.read_bytes(),b'generated language output')
            self.assertEqual(unknown.read_bytes(),b'unique trace')

    def test_diagnostic_copy_failure_prevents_any_payload_retirement(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg,edition,workspace,raw,shard,payload,folder,external,closed=self.fixture(Path(tmp))
            with patch.object(b.shutil,'copyfileobj',side_effect=OSError('archive unavailable')):
                with self.assertRaisesRegex(OSError,'archive unavailable'):
                    b.cleanup_incomplete_shard_payload(shard,folder/'diagnostics')
            self.assertTrue(all(path.is_file() for path in payload))
            self.assertEqual((shard/'fallback-pages.jsonl').read_bytes(),b'exact fallback diagnostic\n')

    def test_wrong_raw_owner_and_symlink_directory_are_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg,edition,workspace,raw,shard,payload,folder,external,closed=self.fixture(Path(tmp))
            state=workspace/'state.json'; state.write_text(json.dumps(dict(raw_shards_path=str(raw)+'-other')))
            with self.assertRaisesRegex(ValueError,'owner differs'):
                b.cleanup_failed_attempt_shards(cfg,edition,folder,closed)
            self.assertTrue(all(path.exists() for path in payload))
            old=shard/'.spool'; saved=shard/'retained-spool'; old.rename(saved); old.symlink_to(saved,target_is_directory=True)
            with self.assertRaisesRegex(ValueError,'Unsafe generated'):
                b.cleanup_incomplete_shard_payload(shard,folder/'diagnostics')
            self.assertTrue(all((saved/path.name).is_file() for path in payload[:39]))

    def test_invalid_coverage_keeps_existing_retry_policy_and_archives_diagnostics(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); shard=root/'00000000'; calls=[]
            error=ValueError('original invalid coverage')
            def run(argv,*args,**kwargs):
                calls.append(argv); shard.mkdir()
                (shard/'languages.tsv').write_bytes(b'nonempty rejected catalog')
                (shard/'page-coverage.json').write_bytes(b'invalid rejected coverage')
                (shard/'fallback-pages.jsonl').write_bytes(b'exact fallback')
            with patch.object(b,'timed_run',side_effect=run):
                with self.assertRaises(ValueError) as failed:
                    b.build_shard_with_retries(fixture_blob_tool(root),['dump',str(shard)],shard,
                        root/'failures','testwiktionary','20261001',0,2,lambda:None,
                        lambda:(_ for _ in ()).throw(error))
            self.assertIs(failed.exception,error)
            self.assertEqual(len(calls),b.SHARD_RETRIES)
            self.assertEqual((shard/'page-coverage.json').read_bytes(),b'invalid rejected coverage')
            evidence=list((root/'failures').iterdir())
            self.assertEqual(len(evidence),b.SHARD_RETRIES)
            for item in evidence:
                self.assertEqual((item/'shard-diagnostics/fallback-pages.jsonl').read_bytes(),b'exact fallback')
                self.assertEqual(json.loads((item/'payload-cleanup.json').read_text())['removed'],[])

    def test_nonpositive_final_failure_archives_only_and_preserves_error_and_retries(self):
        for returncode in (-15,0):
            with self.subTest(returncode=returncode),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp); shard=root/'00000000'; calls=[]; errors=[]
                def run(argv,*args,**kwargs):
                    calls.append(argv); (shard/'.spool').mkdir(parents=True); (shard/'languages').mkdir()
                    (shard/'.spool/lang-00.tmp').write_bytes(b'generated spool')
                    (shard/'languages'/('a'*64+'.wikblb')).write_bytes(b'generated language')
                    (shard/'fallback-pages.jsonl').write_bytes(b'exact fallback')
                    error=subprocess.CalledProcessError(returncode,argv,output=b'original stdout',stderr=b'original stderr')
                    errors.append(error); raise error
                with patch.object(b,'timed_run',side_effect=run):
                    with self.assertRaises(subprocess.CalledProcessError) as failed:
                        b.build_shard_with_retries(fixture_blob_tool(root),['dump',str(shard)],shard,
                            root/'failures','testwiktionary','20261001',0,2,lambda:None,
                            lambda:self.fail('no validation after command failure'))
                self.assertIs(failed.exception,errors[-1]); self.assertEqual(len(calls),b.SHARD_RETRIES)
                self.assertEqual(failed.exception.output,b'original stdout'); self.assertEqual(failed.exception.stderr,b'original stderr')
                self.assertEqual((shard/'.spool/lang-00.tmp').read_bytes(),b'generated spool')
                self.assertEqual((shard/'languages'/('a'*64+'.wikblb')).read_bytes(),b'generated language')
                evidence=list((root/'failures').iterdir()); self.assertEqual(len(evidence),b.SHARD_RETRIES)
                for item in evidence:
                    self.assertEqual((item/'shard-diagnostics/fallback-pages.jsonl').read_bytes(),b'exact fallback')
                    receipt=json.loads((item/'payload-cleanup.json').read_text())
                    self.assertEqual(receipt['removed'],[]); self.assertEqual(receipt['status'],'diagnostics-retained')

    def test_matching_failure_keeps_primary_error_and_archives_before_payload_removal(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);shard=root/'00000000';original=[];calls=[]
            tool=fixture_blob_tool(root);command=['dump',str(shard),'--start-page','0','--limit-pages','2']
            def run(argv,*args,**kwargs):
                calls.append(argv); (shard/'.spool').mkdir(parents=True); (shard/'languages').mkdir()
                (shard/'.spool/lang-00.tmp').write_bytes(b'disposable'); (shard/'languages'/('a'*64+'.wikblb')).write_bytes(b'disposable blob')
                (shard/'fallback-pages.jsonl').write_bytes(b'exact fallback')
                receipt=Path(argv[argv.index('--failure-receipt')+1]); receipt.write_text(json.dumps(dict(
                    schema='wikidict.blob-build.failure.v1',error_name='UncompiledPresentation',failure_class='deterministic-presentation',
                    invocation_id=argv[argv.index('--invocation-id')+1],invocation_args=tool_arguments(argv),
                    page=dict(ordinal=1,namespace=0,title='fixture',page_id=7,revision_id=9))))
                error=subprocess.CalledProcessError(1,argv,output=b'original stdout',stderr=b'original stderr'); original.append(error); raise error
            with patch.object(b,'timed_run',side_effect=run):
                with self.assertRaises(b.DeterministicPresentationFailure) as failed:
                    b.build_shard_with_retries(tool,command,shard,root/'failures','testwiktionary','20261001',0,2,lambda:None,lambda:self.fail('no validation on failed builder'))
            self.assertEqual(len(calls),1); self.assertIs(failed.exception.__cause__,original[0]); self.assertEqual(failed.exception.stderr,b'original stderr')
            evidence=Path(failed.exception.failure_receipt).parent
            self.assertFalse((shard/'.spool/lang-00.tmp').exists()); self.assertFalse((shard/'languages'/('a'*64+'.wikblb')).exists())
            self.assertEqual((evidence/'shard-diagnostics/fallback-pages.jsonl').read_bytes(),b'exact fallback')
            self.assertEqual(json.loads((evidence/'payload-cleanup.json').read_text())['status'],'generated-payload-retired')


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


def write_magic_fixture(folder, edition='arwiktionary', date='20261001', observation='first', alias='اسم_الصفحة', parser_functions=False, content_language='ar', complete_magic_projection=False):
    import prepare_magic_words as magic
    folder.mkdir(parents=True,exist_ok=True)
    namespace=magic.document({'query':{'general':{'wikiid':edition,'lang':content_language}}})
    (folder/'namespace-siteinfo.raw.json').write_bytes(namespace)
    (folder/'capture.complete.json').write_bytes(magic.document(dict(wiki=edition,date=date,
        artifacts={'namespace-siteinfo.raw.json':magic.digest(namespace)})))
    words=[{'name':name,'case-sensitive':True,'aliases':[name.upper()]+([alias] if name=='pagename' else [])}
           for name in sorted(magic.SUPPORTED)]
    if parser_functions:
        words += [{'name':name,'aliases':[name]+(['استدعاء'] if name=='invoke' else [])}
                  for name in sorted(magic.PARSER_FUNCTIONS)]
    if complete_magic_projection:
        # Capture these facts in the original v1 raw response. The successive
        # real projections require int and language and retain captured lst.
        words += [dict(name=name, **{'case-sensitive':False}, aliases=[alias])
                  for name,alias in (('int','INT:'),('language','#language'),('lst','#section'))]
    raw=magic.document({'query':{'general':{'wikiid':edition,'lang':content_language,'sitename':observation},'magicwords':words}})
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


def write_commons_capture_fixture(folder, namespace):
    import prepare_commons_data as commons
    from test_prepare_commons_data import TITLE, response
    raw=json.dumps(response(),ensure_ascii=False).encode()
    args=SimpleNamespace(wiki='arwiktionary',date='20261001',title=[TITLE],
        namespace_registry=namespace,output=folder,delay=0,wall_seconds=30)
    def transport(url,timeout):
        assert url==commons.query_url(TITLE)
        assert timeout>0
        return 200,{'content-type':'application/json'},raw
    commons.capture(args,transport=transport,sleep=lambda _:None)
    return folder/'commons-data.tsv'


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


class AffinityAdmissionTests(unittest.TestCase):
    @contextlib.contextmanager
    def envelope(self,cpus=(0,2,4,6),address_space=limits.MAX_BUILD_MEMORY,nice=15):
        with patch.dict(os.environ,{},clear=True), \
             patch.object(limits,'inside_watchdog',return_value=True), \
             patch.object(b.resource,'getrlimit',return_value=(address_space,address_space)), \
             patch.object(b.os,'sched_getaffinity',return_value=set(cpus)), \
             patch.object(b.os,'getpriority',return_value=nice):
            yield

    def test_affinity_budget_ignores_global_load_and_owned_worker_credit(self):
        with self.envelope(),patch.object(b.os,'cpu_count',return_value=8),patch.object(b,'load_average',return_value=1000) as load:
            self.assertEqual(0,b.safe_worker_budget())
            load.reset_mock()
            self.assertEqual(4,b.safe_worker_budget(cpu_admission='affinity'))
            self.assertEqual(4,b.safe_worker_budget(1000,cpu_admission='affinity'))
            load.assert_not_called()
        for cpus,memory,expected in [((0,2),limits.MAX_BUILD_MEMORY,2),((0,2,4,6),4*1024**3,2),((0,),128*1024**2,0)]:
            with self.subTest(cpus=cpus,memory=memory),self.envelope(cpus,memory):
                self.assertEqual(expected,b.safe_worker_budget(cpu_admission='affinity'))

    def test_affinity_rejects_unverified_child_and_forged_partial_environment(self):
        with patch.dict(os.environ,{},clear=True),patch.object(limits,'_verified_watchdog_pid',None):
            with self.assertRaisesRegex(limits.ContainmentUnavailable,'verified watchdog child'):
                b.safe_worker_budget(cpu_admission='affinity')
        with patch.dict(os.environ,{limits.WATCHDOG_TOKEN:'a'*32},clear=True),patch.object(limits,'_verified_watchdog_pid',None):
            with self.assertRaisesRegex(limits.ContainmentUnavailable,'Incomplete watchdog child proof'):
                b.safe_worker_budget(cpu_admission='affinity')

    def test_affinity_requires_finite_actual_address_space_and_narrow_allowed_affinity(self):
        for soft,hard in [(0,limits.MAX_BUILD_MEMORY),
                          (limits.MAX_BUILD_MEMORY,limits.MAX_BUILD_MEMORY+1),(limits.MAX_BUILD_MEMORY,1024**3)]:
            with self.subTest(limits=(soft,hard)),self.envelope(),patch.object(b.resource,'getrlimit',return_value=(soft,hard)):
                with self.assertRaisesRegex(limits.ContainmentUnavailable,'finite watchdog address-space'):
                    b.safe_worker_budget(cpu_admission='affinity')
        for cpus in [(),tuple(range(5))]:
            with self.subTest(cpus=cpus),self.envelope(cpus):
                with self.assertRaisesRegex(ValueError,'one through four allowed CPUs'):
                    b.safe_worker_budget(cpu_admission='affinity')
        for nice in [-1,20]:
            with self.subTest(nice=nice),self.envelope(nice=nice),self.assertRaisesRegex(limits.ContainmentUnavailable,'nice priority'):
                b.safe_worker_budget(cpu_admission='affinity')

    def test_unlimited_affinity_requires_authenticated_physical_budget_and_bounded_workers(self):
        with self.envelope(cpus=(0,2),address_space=b.resource.RLIM_INFINITY):
            with patch.object(limits,'watchdog_physical_memory_limit_bytes',side_effect=limits.ContainmentUnavailable('no physical proof')):
                with self.assertRaises(limits.ContainmentUnavailable):
                    b.affinity_worker_budget()
            with patch.object(limits,'watchdog_physical_memory_limit_bytes',return_value=4*1024**3),patch.object(b.os,'cpu_count',side_effect=AssertionError('must not use host CPU count')):
                self.assertEqual(b.validate_affinity_workers(2,1),2)
                with self.assertRaises(ValueError):
                    b.validate_affinity_workers(3,1)
                with self.assertRaises(ValueError):
                    b.validate_affinity_workers(2,2)
            with patch.object(limits,'watchdog_physical_memory_limit_bytes',return_value=limits.MAX_BUILD_MEMORY+1):
                with self.assertRaises(limits.ContainmentUnavailable):
                    b.affinity_worker_budget()

    def test_affinity_accepts_authenticated_normal_and_lower_priorities(self):
        for nice in [0,15,19]:
            with self.subTest(nice=nice),self.envelope(nice=nice),patch.object(b.os,'cpu_count',return_value=8),patch.object(b,'load_average',side_effect=AssertionError('affinity must not consult global load')):
                self.assertEqual(4,b.safe_worker_budget(cpu_admission='affinity'))


    def test_affinity_retains_lower_child_cgroup_cap_and_fails_closed(self):
        with self.envelope(),patch.dict(os.environ,{limits.CHILD_CGROUP:'/private/build'}):
            for cap,expected in [(4*1024**3,2),(128*1024**2,0),(None,0),(0,0),(True,0)]:
                with self.subTest(cap=cap),patch.object(limits,'child_memory_limit_bytes',return_value=cap):
                    self.assertEqual(expected,b.safe_worker_budget(cpu_admission='affinity'))
            with patch.object(limits,'child_memory_limit_bytes',side_effect=OSError('unreadable')):
                self.assertEqual(0,b.safe_worker_budget(cpu_admission='affinity'))

    def test_affinity_cli_rejects_wide_or_cgroup_requests_before_supervision(self):
        variants=[[],['--resource-mode=watchdog','--jobs=2'],['--resource-mode=watchdog','--threads=5'],
                  ['--resource-mode=watchdog','--expansion-workers=8']]
        for args in variants:
            with self.subTest(args=args),patch.object(sys,'argv',['build_wiktionaries.py','--cpu-admission=affinity',*args]), \
                 patch.object(limits,'supervise_watchdog') as watchdog,patch.object(limits,'supervise') as cgroup, \
                 patch.object(b,'main') as main:
                with self.assertRaises(SystemExit):b.cli()
                watchdog.assert_not_called();cgroup.assert_not_called();main.assert_not_called()

    def test_affinity_cli_keeps_existing_watchdog_lock_deadline_and_disk_envelope(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            def supervised(**kwargs):
                self.assertEqual({'wall_seconds':123,'disk_paths':(root/'.tmp',root/'data/dictionaries')},kwargs)
                with self.assertRaises(limits.ContainmentUnavailable):
                    b.acquire_build_resource_lock(root/'.tmp/build-resources.lock')
                return 0
            argv=['build_wiktionaries.py','--resource-mode=watchdog','--cpu-admission=affinity',
                  '--threads=4','--jobs=1','--expansion-workers=4','--build-timeout-seconds=123']
            with patch.object(b,'PROJECT',root),patch.object(sys,'argv',argv), \
                 patch.object(limits,'inside_watchdog',return_value=False), \
                 patch.object(limits,'supervise_watchdog',side_effect=supervised) as watchdog,patch.object(b,'main') as main:
                with self.assertRaises(SystemExit) as result:b.cli()
                self.assertEqual(0,result.exception.code)
                watchdog.assert_called_once();main.assert_not_called()

    def test_affinity_main_resolves_defaults_without_host_load_and_forwards_policy(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            write_test_manifest(root,{'files':[dict(wiki='testwiktionary',date='20261001',name='test.xml.bz2',
                url='https://dumps.wikimedia.org/testwiktionary/20261001/test.xml.bz2',size=1,sha1='a'*40)]})
            argv=['build_wiktionaries.py','--resource-mode=watchdog','--cpu-admission=affinity','--downloads',str(root),'--output',str(root/'out')]
            with self.envelope(),patch.object(sys,'argv',argv), \
                 patch.object(b,'load_average',side_effect=AssertionError('affinity admission must not consult global load')), \
                 patch.object(b,'build_groups',return_value=[]) as groups:
                b.main()
            self.assertEqual((4,1,None),groups.call_args.args[4:])
            self.assertEqual('affinity',groups.call_args.kwargs['cpu_admission'])
            self.assertIn('edition_options',groups.call_args.kwargs)
            self.assertEqual(limits.WATCHDOG_WALL_SECONDS,groups.call_args.kwargs['admission_wait_seconds'])

    def test_affinity_group_admission_builds_serially_without_global_load_wait(self):
        groups={(wiki,'20261001'):[dict(wiki=wiki)] for wiki in ('aawiktionary','abwiktionary')}
        started=[]
        def fake_build(group,*args,**kwargs):
            started.append(group[0]['wiki'])
            self.assertEqual(4,args[-1])
            self.assertEqual(4,kwargs['expansion_workers'])
        with self.envelope(),patch.object(b,'load_average',side_effect=AssertionError('unexpected global load')), \
             patch.object(b,'build',side_effect=fake_build),patch.object(b.time,'sleep',side_effect=AssertionError('unexpected admission wait')):
            self.assertEqual([],b.build_groups(groups,Path('.'),Path('.'),'zig',4,1,4,cpu_admission='affinity'))
        self.assertEqual(['aawiktionary','abwiktionary'],started)

    def test_affinity_group_rejects_job_and_effective_edition_worker_overrides(self):
        key=('aawiktionary','20261001');groups={key:[dict(wiki=key[0])]}
        for threads,jobs,expansion in [(4,2,4),(5,1,4),(4,1,5)]:
            with self.subTest(threads=threads,jobs=jobs,expansion=expansion),self.envelope(),patch.object(b,'build') as build:
                with self.assertRaises(ValueError):
                    b.build_groups(groups,Path('.'),Path('.'),'zig',threads,jobs,expansion,cpu_admission='affinity')
                build.assert_not_called()
        for cpus,override in [((0,2,4,6),5),((0,),2)]:
            with self.subTest(cpus=cpus,override=override),self.envelope(cpus),patch.object(b,'build') as build:
                with self.assertRaises(ValueError):
                    b.build_groups(groups,Path('.'),Path('.'),'zig',1,1,1,cpu_admission='affinity',
                        edition_options={key:{'expansion_workers':override}})
                build.assert_not_called()


class ProvenanceBindingTests(unittest.TestCase):
    def test_autonym_capture_pin_isolates_strict_inventory_and_preserves_checkpoint(self):
        import prepare_language_names_autonyms as autonyms
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);source=root/'capture';source.mkdir()
            for name in ('language-names.tsv','language-autonyms.namespace-registry.tsv',
                         'language-names.manifest.json','language-names.complete.json'):
                (source/name).write_text('fixture '+name+'\n')
            destination=root/'workspace';destination.mkdir()
            checkpoint=destination/'state.json';checkpoint.write_text('{"now_unix":222}\n')
            (destination/'input').mkdir();(destination/'input/pages.xml').write_text('<mediawiki/>')
            record={'schema':'wikidict.language-names-autonym-capture.v1'}
            def validated(name,path):
                self.assertEqual(name,'language-names')
                # Exercise the real strict whole-directory inventory; replay itself is not mocked as acceptance.
                inventory={key:row['sha256'] for key,row in autonyms.inventory(Path(path).parent).items()}
                for key in ('language-names.manifest.json','language-names.complete.json'):
                    inventory[key]=b.sha256_file(Path(path).parent/key)
                return record,inventory
            snapshots={'language-names':source/'language-names.tsv'}
            with patch.object(b,'validated_auxiliary_capture',side_effect=validated):
                capture=validated('language-names',snapshots['language-names'])
                pinned=b.pinned_auxiliary_snapshots(snapshots,{'language-names':b.sha256_file(snapshots['language-names'])},destination,
                    {'language-names':capture[1]['language-names.manifest.json']},
                    {'language-names':b.auxiliary_artifact_digest(capture[1])})
                self.assertEqual(destination/'language-names/language-names.tsv',pinned['language-names'])
                self.assertEqual(capture,validated('language-names',pinned['language-names']))
            self.assertEqual('{"now_unix":222}\n',checkpoint.read_text())
            self.assertEqual('<mediawiki/>',(destination/'input/pages.xml').read_text())
            (pinned['language-names'].parent/'unexpected.json').write_text('{}')
            with self.assertRaisesRegex(ValueError,'Unexpected capture artifact'):
                autonyms.inventory(pinned['language-names'].parent)

    def test_commons_pin_isolates_inventory_from_other_captures_and_staged_input(self):
        import prepare_commons_data as commons
        import prepare_language_messages as messages
        for staged_input in (False,True):
            with self.subTest(staged_input=staged_input),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp)
                snapshots=write_language_messages_fixture(root/'messages')
                snapshots['namespace-registry']=root/'messages'/'namespace-registry.tsv'
                snapshots['commons-data']=write_commons_capture_fixture(root/'commons',snapshots['namespace-registry'])
                manifest=commons.validate_snapshot(snapshots['commons-data'],'arwiktionary','20261001')
                inventory=commons.capture_artifacts(snapshots['commons-data'],manifest)
                message_inventory=messages.capture_artifacts(snapshots['interface-messages'])
                hashes=b.verified_auxiliary_hashes(snapshots,'arwiktionary','20261001')
                captures=b.auxiliary_capture_identities(snapshots,'arwiktionary','20261001')
                destination=root/'pinned';destination.mkdir()
                if staged_input:
                    (destination/'input').mkdir()
                    (destination/'input'/'pages.xml').write_bytes(b'<mediawiki/>')
                with patch.object(commons.evidence,'get_response',side_effect=AssertionError('unexpected network')):
                    pinned=b.pinned_auxiliary_snapshots(snapshots,hashes,destination,*captures)
                    self.assertEqual(pinned['commons-data'],destination/'commons-data'/'commons-data.tsv')
                    self.assertEqual(set(inventory),{p.name for p in pinned['commons-data'].parent.iterdir()})
                    self.assertEqual(inventory,commons.capture_artifacts(pinned['commons-data'],commons.validate_snapshot(pinned['commons-data'])))
                    for name,digest in inventory.items():
                        self.assertEqual(digest,b.sha256_file(pinned['commons-data'].parent/name))
                    self.assertEqual(hashes,b.verified_auxiliary_hashes(pinned,'arwiktionary','20261001'))
                    self.assertEqual(captures,b.auxiliary_capture_identities(pinned,'arwiktionary','20261001'))
                    for name in ('language-fallbacks','interface-messages','namespace-registry'):
                        self.assertEqual(destination/(name+'.tsv'),pinned[name])
                    for name,digest in message_inventory.items():
                        self.assertEqual(digest,b.sha256_file(destination/name))
                    if staged_input:self.assertEqual(b'<mediawiki/>',(destination/'input'/'pages.xml').read_bytes())
                    (pinned['commons-data'].parent/'unexpected.txt').write_text('unrecorded')
                    with self.assertRaisesRegex(ValueError,'Commons payload inventory mismatch'):
                        b.verified_auxiliary_hashes(pinned,'arwiktionary','20261001')

    def test_commons_pin_rejects_symlink_capture_directory_before_copying(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            namespace=write_namespace_fixture(root/'source','arwiktionary','20261001')['namespace-registry']
            namespace.write_text(namespace.read_text().replace('# content-language\ten\n','# content-language\tar\n'))
            snapshots={'commons-data':write_commons_capture_fixture(root/'commons',namespace)}
            hashes=b.verified_auxiliary_hashes(snapshots,'arwiktionary','20261001')
            captures=b.auxiliary_capture_identities(snapshots,'arwiktionary','20261001')
            destination=root/'pinned';destination.mkdir()
            outside=root/'outside';outside.mkdir()
            sentinel=outside/'sentinel';sentinel.write_bytes(b'preserve')
            (destination/'commons-data').symlink_to(outside,target_is_directory=True)
            with patch.object(b,'copy_verified_snapshot',wraps=b.copy_verified_snapshot) as copy:
                with self.assertRaises(ValueError):
                    b.pinned_auxiliary_snapshots(snapshots,hashes,destination,*captures)
            copy.assert_not_called()
            self.assertEqual({'sentinel'},{p.name for p in outside.iterdir()})
            self.assertEqual(b'preserve',sentinel.read_bytes())
            self.assertTrue((destination/'commons-data').is_symlink())

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
        # The validated collector inventory uses its schema-specific copied namespace key.
        for schema,key,other_key in (
                ('wikidict.language-names-autonym-capture.v1','language-autonyms.namespace-registry.tsv','language-names.namespace-registry.tsv'),
                ('wikidict.language-names-capture.v2','language-names.namespace-registry.tsv','language-autonyms.namespace-registry.tsv')):
            with self.subTest(language_names_schema=schema),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);namespace=root/'namespace-registry.tsv';namespace.write_bytes(b'exact selected namespace')
                digest=b.sha256_file(namespace);capture={'wiki':'arwiktionary','date':'20261001'}
                path=root/'language-names.tsv';path.write_bytes(b'validated collector payload')
                with patch.object(b,'validated_auxiliary_capture',return_value=({'schema':schema},{key:digest})):
                    b.validate_captured_snapshot('language-names',path,capture,[],root)
                for inventory in ({}, {other_key:digest}, {key:'0'*64}, {key:'0'*64,other_key:digest}):
                    with self.subTest(inventory=inventory),patch.object(b,'validated_auxiliary_capture',return_value=({'schema':schema},inventory)):
                        with self.assertRaisesRegex(ValueError,'namespace source differs'):
                            b.validate_captured_snapshot('language-names',path,capture,[],root)
                namespace.write_bytes(b'different selected namespace')
                with patch.object(b,'validated_auxiliary_capture',return_value=({'schema':schema},{key:digest})):
                    with self.assertRaisesRegex(ValueError,'namespace source differs'):
                        b.validate_captured_snapshot('language-names',path,capture,[],root)
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


class SmallestFirstSchedulerTests(unittest.TestCase):
    @staticmethod
    def item(wiki, date, size, suffix='pages-meta-current.xml.bz2'):
        name = wiki+'-'+date+'-'+suffix
        return dict(wiki=wiki, date=date, name=name, size=size, sha1='a'*40,
                    url='https://dumps.wikimedia.org/'+wiki+'/'+date+'/'+name)

    def test_scheduler_orders_xml_member_totals_then_edition_and_date(self):
        specs = [('aawiktionary', '20261001', [90]),
                 ('zzwiktionary', '20261001', [6, 4]),
                 ('bbwiktionary', '20261002', [10]),
                 ('bbwiktionary', '20261001', [10])]
        groups = {}
        for wiki, date, sizes in specs:
            group = [self.item(wiki, date, size, 'pages-meta-current'+str(n)+'.xml.bz2')
                     for n, size in enumerate(sizes)]
            group.append(self.item(wiki, date, 1000000 if wiki == 'zzwiktionary' else 1, 'page.sql.gz'))
            groups[(wiki, date)] = group
        started = []
        def build(group, *args, **kwargs):
            key = group[0]['wiki'], group[0]['date']
            started.append(key)
            if key == ('bbwiktionary', '20261001'):
                raise ValueError('preserve edition failure')
        with patch.object(b, 'safe_worker_budget', return_value=1), \
             patch.object(b, 'build', side_effect=build), \
             patch.object(b.time, 'sleep', side_effect=AssertionError('unexpected admission wait')):
            failures = b.build_groups(groups, Path('.'), Path('.'), 'zig', 1, 1)
        self.assertEqual([('bbwiktionary', '20261001'), ('bbwiktionary', '20261002'),
                          ('zzwiktionary', '20261001'), ('aawiktionary', '20261001')], started)
        self.assertEqual([('bbwiktionary', '20261001')], failures)

    def test_invalid_or_missing_manifest_size_retains_original_rejection(self):
        good = self.item('zzwiktionary', '20261001', 20)
        bad = self.item('aawiktionary', '20261001', 10)
        for size in (None, 0, -1, '10', 1.5):
            with self.subTest(size=size):
                item = dict(bad)
                if size is None:
                    del item['size']
                else:
                    item['size'] = size
                groups = {('aawiktionary', '20261001'): [item],
                          ('zzwiktionary', '20261001'): [good]}
                started = []
                def build(group, *args, **kwargs):
                    started.append(group[0]['wiki'])
                    for value in group:
                        b.validate_item(value)
                with patch.object(b, 'safe_worker_budget', return_value=1), \
                     patch.object(b, 'build', side_effect=build):
                    failures = b.build_groups(groups, Path('.'), Path('.'), 'zig', 1, 1)
                self.assertEqual(['zzwiktionary', 'aawiktionary'], started)
                self.assertEqual([('aawiktionary', '20261001')], failures)


class BuildTest(PreparedToolsFixture):
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

    def test_small_shard_batch_syncs_all_targets_before_any_raw_unlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); language=root/'languages';language.mkdir()
            raws=[root/'aliases.wikblb',language/'a.wikblb',language/'b.wikblb']
            for raw in raws:raw.write_bytes(b'WIKBLB08'+b'x'*20)
            events=[];real_unlink=b.unlink_artifact
            def encode(paths,block):
                self.assertEqual(block,1048576);self.assertEqual(set(paths),set(raws))
                for raw in paths:Path(str(raw)+'.xz').write_bytes(lzma.compress(raw.read_bytes()))
                events.append(('encode',None))
            def sync(parent):
                events.append(('sync',parent))
                self.assertTrue(all(Path(str(raw)+'.xz').exists() for raw in raws))
            def unlink(raw):
                self.assertEqual({x[1] for x in events if x[0]=='sync'},{root,language})
                events.append(('unlink',raw));real_unlink(raw)
            with patch.object(b,'compress_small_batch_keep',side_effect=encode), \
                 patch.object(b,'sync_shard_directory',side_effect=sync),patch.object(b,'unlink_artifact',side_effect=unlink):
                b.compress_verified_shard(root)
            self.assertEqual([x[0] for x in events],['encode','sync','sync','unlink','unlink','unlink','sync','sync'])
            self.assertTrue(all(not raw.exists() for raw in raws))

    def test_small_shard_batch_sync_and_later_unlink_failures_remain_recoverable(self):
        for failure in ('directory','unlink'):
            with self.subTest(failure=failure),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);raws=[root/f'{n}.wikblb' for n in range(3)]
                for raw in raws:
                    raw.write_bytes(b'WIKBLB08'+b'x'*20)
                    Path(str(raw)+'.xz').write_bytes(lzma.compress(raw.read_bytes()))
                real_unlink=b.unlink_artifact
                def sync(parent):
                    if failure=='directory':raise OSError('directory sync failed')
                def unlink(raw):
                    if raw==raws[1]:raise OSError('later unlink failed')
                    real_unlink(raw)
                with patch.object(b,'sync_shard_directory',side_effect=sync), \
                     patch.object(b,'unlink_artifact',side_effect=unlink):
                    with self.assertRaises(OSError):b.compress_verified_shard(root)
                for raw in raws:
                    self.assertEqual(lzma.decompress(Path(str(raw)+'.xz').read_bytes()),b'WIKBLB08'+b'x'*20)
                if failure=='directory':self.assertTrue(all(raw.exists() for raw in raws))
                b.compress_verified_shard(root)
                self.assertTrue(all(not raw.exists() for raw in raws))

    def test_small_shard_batch_is_bounded_and_large_files_keep_serial_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);raws=[root/f'{n:03}.wikblb' for n in range(130)]
            for raw in raws:raw.write_bytes(b'WIKBLB08x')
            large=root/'001a.wikblb';large.write_bytes(b'WIKBLB08'+b'x'*65529)
            calls=[]
            def encode(paths,block):
                calls.append(('batch',len(paths)))
                self.assertLessEqual(len(paths),128)
                for raw in paths:Path(str(raw)+'.xz').write_bytes(lzma.compress(raw.read_bytes()))
            def single(raw,block,workers):
                calls.append(('single',raw.name));self.assertEqual(workers,1)
                Path(str(raw)+'.xz').write_bytes(lzma.compress(raw.read_bytes()))
            with patch.object(b,'compress_small_batch_keep',side_effect=encode),patch.object(b,'compress',side_effect=single):
                b.compress_verified_shard(root)
            self.assertEqual(calls,[('single','001a.wikblb'),('batch',128),('batch',2)])
            self.assertTrue(all(not raw.exists() for raw in raws+[large]))

    def test_compressed_shard_recovery_preserves_only_verified_copy_on_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);raw=root/'aliases.wikblb';payload=b'WIKBLB08\x08ordinary alias'
            raw.write_bytes(payload);target=Path(str(raw)+'.xz')
            target.write_bytes(lzma.compress(payload));part=Path(str(target)+'.part');part.write_bytes(b'interrupted')
            with patch.object(b,'compress') as encode:
                b.compress_verified_shard(root)
            encode.assert_not_called();self.assertFalse(raw.exists());self.assertFalse(part.exists())
            self.assertEqual(lzma.decompress(target.read_bytes()),payload)
            # XZ-only recovery is kept, never recompressed or removed.
            b.compress_verified_shard(root);self.assertTrue(target.exists())
            raw.write_bytes(payload);target.write_bytes(lzma.compress(payload+b'changed'))
            with self.assertRaises(ValueError):b.compress_verified_shard(root)
            self.assertEqual(raw.read_bytes(),payload);self.assertTrue(target.exists())
            target.unlink()
            with patch.object(b,'compress',side_effect=RuntimeError('codec interrupted')):
                with self.assertRaisesRegex(RuntimeError,'codec interrupted'):b.compress_verified_shard(root)
            self.assertEqual(raw.read_bytes(),payload)
            raw.unlink();part.write_bytes(b'only possible recovery')
            with self.assertRaisesRegex(ValueError,'Unresolved shard compression partial'):
                b.cleanup_shard_compression_parts(root)
            self.assertTrue(part.exists())

    def test_compressed_shard_target_is_durable_before_raw_retirement(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);raw=root/'aliases.wikblb';payload=b'WIKBLB08\x08alias'
            raw.write_bytes(payload);target=Path(str(raw)+'.xz');target.write_bytes(lzma.compress(payload))
            events=[];real_unlink=b.unlink_artifact
            def sync(path):events.append(('sync',path));self.assertTrue(target.exists())
            def unlink(path):events.append(('unlink',path));self.assertEqual(events[-2],('sync',root));real_unlink(path)
            with patch.object(b,'sync_shard_directory',side_effect=sync),patch.object(b,'unlink_artifact',side_effect=unlink):
                b.compress_verified_shard(root)
            self.assertEqual([x[0] for x in events],['sync','unlink','sync'])
            self.assertEqual(lzma.decompress(target.read_bytes()),payload)

    def test_compressed_mode_retires_each_raw_shard_before_next_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);workspace=root/'work';exp=workspace/'expander/.bundle-expander';exp.mkdir(parents=True)
            (workspace/'expander/.incomplete').write_text('expander ready')
            (exp/'page-index.tsv').write_text('p0\np1\n')
            (exp/'dict-bundle-expander').write_text('worker');write_namespace_fixture(exp)
            cache=workspace/'input';cache.mkdir();(cache/'.complete.json').write_text(json.dumps({'source_pages':2}))
            events=[]
            def run(command):
                if blob_command(command,'build-blobs'):
                    self.assertNotIn('--shard-pages',command)
                    dest=Path(tool_arguments(command)[1]);start=int(command[command.index('--start-page')+1])
                    if start: self.assertFalse((dest.parent/'00000000/aliases.wikblb').exists());self.assertTrue((dest.parent/'00000000/aliases.wikblb.xz').exists())
                    dest.mkdir();write_coverage(dest,command);(dest/'aliases.wikblb').write_bytes(b'WIKBLB08\x08alias')
                    events.append(('build',start))
                elif blob_command(command,'verify-blobs'):events.append(('verify',Path(command[-1]).name))
            def encode(path,block_size,workers):
                self.assertEqual((block_size,workers),(1024*1024,1));self.assertEqual(events[-1][0],'verify')
                Path(str(path)+'.xz').write_bytes(lzma.compress(path.read_bytes()));events.append(('compress',path.parent.name))
            with patch.object(b,'SHARD_PAGES',1),patch.object(b,'run_checked',side_effect=run),patch.object(b,'compress',side_effect=encode),patch.object(b,'require_merge_disk_space',side_effect=ValueError('stop before merge')) as admit:
                with self.assertRaisesRegex(ValueError,'stop before merge'):
                    b.build_sharded(root/'dump',root/'staging',workspace,root/'registry','zig',1,[{'wiki':'test','date':'20260901'}],123,compress_shards=True)
            self.assertTrue(admit.call_args.kwargs['allow_compressed'])
            self.assertTrue(admit.call_args.kwargs['compressed_output'])
            self.assertEqual([x[0]for x in events],['build','verify','compress','build','verify','compress'])
            self.assertTrue((workspace/'shards/00000000/aliases.wikblb.xz').exists())
            self.assertTrue((workspace/'shards/00000001/aliases.wikblb.xz').exists())

    def test_direct_xz_merge_keeps_recovery_until_deep_verify_and_logical_seal(self):
        for verify_failure in (True,False):
            with self.subTest(verify_failure=verify_failure),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);workspace=root/'work';exp=workspace/'expander/.bundle-expander';exp.mkdir(parents=True)
                (workspace/'expander/.incomplete').write_text('expander ready')
                (exp/'page-index.tsv').write_text('p0\n');(exp/'dict-bundle-expander').write_text('worker');write_namespace_fixture(exp)
                cache=workspace/'input';cache.mkdir();(cache/'.complete.json').write_text(json.dumps({'source_pages':1}))
                staging=root/'staging';events=[];payload=b'WIKBLB08\x08alias'
                def run(command):
                    if blob_command(command,'build-blobs'):
                        dest=Path(tool_arguments(command)[1]);dest.mkdir();write_coverage(dest,command)
                        (dest/'aliases.wikblb').write_bytes(payload)
                    elif blob_command(command,'merge-blobs'):
                        args=tool_arguments(command);self.assertEqual(args[0],'--compress-output');self.assertEqual(Path(args[1]),staging)
                        staging.mkdir();write_namespace_coverage(staging,1);(staging/'aliases.wikblb.xz').write_bytes(lzma.compress(payload));events.append('merge')
                    elif blob_command(command,'verify-blobs') and Path(command[-1])==staging:
                        events.append('verify')
                        if verify_failure:raise ValueError('merged verification failed')
                def encode(path,block_size,workers):Path(str(path)+'.xz').write_bytes(lzma.compress(path.read_bytes()))
                def cleanup(path):
                    self.assertEqual(path,workspace);self.assertEqual(events,['merge','verify'])
                    saved=json.loads((staging/b.VERIFIED_INVENTORY_NAME).read_text())
                    self.assertEqual(saved['files']['aliases.wikblb'],dict(size=len(payload),sha256=hashlib.sha256(payload).hexdigest()))
                    self.assertTrue((staging/b.VERIFIED_MARKER).is_file());events.append('cleanup')
                with patch.object(b,'PROJECT',root),patch.object(b,'SHARD_PAGES',1),patch.object(b,'run_checked',side_effect=run),patch.object(b,'compress',side_effect=encode),patch.object(b,'require_merge_disk_space',return_value={}) as admission,patch.object(b,'cleanup_shard_workspace',side_effect=cleanup):
                    if verify_failure:
                        with self.assertRaisesRegex(ValueError,'merged verification failed'):
                            b.build_sharded(root/'dump',staging,workspace,root/'registry','zig',1,[{'wiki':'test','date':'20260901'}],123,compress_shards=True)
                    else:b.build_sharded(root/'dump',staging,workspace,root/'registry','zig',1,[{'wiki':'test','date':'20260901'}],123,compress_shards=True)
                self.assertTrue(admission.call_args.kwargs['compressed_output'])
                self.assertTrue((workspace/'shards/00000000/aliases.wikblb.xz').exists())
                self.assertEqual(events,['merge','verify']+([] if verify_failure else ['cleanup']))
                if verify_failure:self.assertFalse((staging/b.VERIFIED_INVENTORY_NAME).exists())

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
                if blob_command(command,'build-blobs'):
                    dest=Path(tool_arguments(command)[1]);dest.mkdir(exist_ok=True)
                    write_coverage(dest,command)
                elif blob_command(command,'merge-blobs'):
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
            self.assertFalse(any(blob_command(command,'merge-blobs') for command in calls))

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
                if blob_command(command,'build-blobs'):
                    dest=Path(tool_arguments(command)[1]);dest.mkdir(exist_ok=True);write_coverage(dest,command)
                if blob_command(command,'merge-blobs'):
                    dest=Path(tool_arguments(command)[0]);dest.mkdir();write_coverage(dest)
            with patch.object(b,'run_checked',side_effect=run):
                b.build_sharded(root/'dump',root/'staging',workspace,root/'registry','zig',4,
                                [{'wiki':'test','date':'20260901'}],123,8,expansion_timeout_ms=600000)
            compiler=next(c for c in calls if 'build-dictionary' in c)
            blob=next(c for c in calls if blob_command(c,'build-blobs'))
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
                if blob_command(command,'build-blobs'):
                    dest=Path(tool_arguments(command)[1]);dest.mkdir(exist_ok=True);write_coverage(dest,command)
                if blob_command(command,'merge-blobs'):
                    dest=Path(tool_arguments(command)[0]);dest.mkdir();write_coverage(dest)
            with patch.object(b,'run_checked',side_effect=run):
                b.build_sharded(root/'dump',root/'staging',workspace,root/'registry','zig',8,[{'wiki':'test','date':'20260901'}],123)
            builds=[c for c in calls if blob_command(c,'build-blobs')]
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
                if blob_command(command,'verify-blobs'):
                    raise subprocess.CalledProcessError(137,command)
                self.fail('No rebuild or merge should follow a verifier tool failure')
            with patch.object(b,'run_checked',side_effect=run):
                with self.assertRaises(subprocess.CalledProcessError):
                    b.build_sharded(root/'dump',root/'staging',workspace,root/'registry','zig',4,
                                    [{'wiki':'test','date':'20260901'}],123)
            self.assertEqual((shard/'sentinel').read_text(),'retain')
            self.assertTrue((shard/'page-coverage.json').is_file())
            self.assertFalse(any(blob_command(c,'build-blobs') or blob_command(c,'merge-blobs') for c in calls))
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
                if blob_command(command,'build-blobs'):
                    dest=Path(tool_arguments(command)[1]);dest.mkdir()
                    write_coverage(dest,command)
                elif blob_command(command,'verify-blobs') and str(shards/'00000002') in command:
                    raise subprocess.CalledProcessError(137,command)
                elif blob_command(command,'merge-blobs'):
                    self.fail('Merge must not run after a verifier failure')
            with patch.object(b,'SHARD_PAGES',1),patch.object(b,'run_checked',side_effect=run):
                with self.assertRaises(subprocess.CalledProcessError):
                    b.build_sharded(root/'dump',root/'staging',workspace,root/'registry','zig',4,
                                    [{'wiki':'test','date':'20260901'}],123)
            self.assertEqual((shards/'00000002/sentinel').read_text(),'retain')
            self.assertFalse(any(blob_command(c,'merge-blobs') for c in calls))

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

    def test_cached_auxiliary_staging_preserves_consumed_snapshot_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            from test_prepare_behavior_switches import hermetic_capture
            source = hermetic_capture(root)/'behavior-switches.tsv'
            digest = b.sha256_file(source)
            snapshots = {'behavior-switches': source}
            pinned = b.pinned_auxiliary_snapshots(snapshots, {'behavior-switches': digest}, root/'work')
            target = pinned['behavior-switches']
            before = target.stat()
            link = root/'expander/behavior-switches.tsv'
            link.parent.mkdir()
            link.symlink_to(target)
            with patch.object(b.shutil, 'copyfile', side_effect=AssertionError('unchanged retry must not copy')):
                self.assertEqual(b.pinned_auxiliary_snapshots(snapshots, {'behavior-switches': digest}, root/'work'), pinned)
            after = target.stat()
            self.assertEqual((before.st_ino, before.st_mtime_ns, before.st_ctime_ns),
                             (after.st_ino, after.st_mtime_ns, after.st_ctime_ns))
            self.assertEqual(link.stat().st_ino, before.st_ino)

    def test_identical_destination_does_not_hide_changed_source_or_pending_copy(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root/'source.tsv'; source.write_bytes(b'original')
            destination = root/'pinned.tsv'
            digest = b.sha256_file(source)
            b.copy_verified_snapshot(source, destination, digest)
            source.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'External snapshot changed'):
                b.copy_verified_snapshot(source, destination, digest)
            self.assertEqual(destination.read_bytes(), b'original')
            source.write_bytes(b'original')
            destination.with_suffix('.tsv.part').write_bytes(b'pending')
            with self.assertRaisesRegex(ValueError, 'Unsafe external snapshot'):
                b.copy_verified_snapshot(source, destination, digest)

    def test_snapshot_reuse_refuses_identity_drift_during_either_hash(self):
        for changed in ('source', 'destination'):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                source = root/'source.tsv'; source.write_bytes(b'original')
                destination = root/'pinned.tsv'; destination.write_bytes(b'original')
                digest = b.sha256_file(source)
                original_hash = b.sha256_file
                def hashing(path):
                    result = original_hash(path)
                    if path == (source if changed == 'source' else destination):
                        replacement = root/'replacement'
                        replacement.write_bytes(b'original')
                        os.replace(replacement, path)
                    return result
                with patch.object(b, 'sha256_file', side_effect=hashing):
                    with self.assertRaisesRegex(ValueError, 'changed while authenticating'):
                        b.copy_verified_snapshot(source, destination, digest)

    def test_snapshot_reuse_preserves_replacement_and_symlink_refusal(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root/'source.tsv'; source.write_bytes(b'new expected')
            destination = root/'pinned.tsv'; destination.write_bytes(b'old snapshot')
            digest = b.sha256_file(source)
            self.assertEqual(b.copy_verified_snapshot(source, destination, digest).read_bytes(), b'new expected')
            alias = root/'alias.tsv'; alias.symlink_to(destination)
            with self.assertRaisesRegex(ValueError, 'Unsafe external snapshot'):
                b.copy_verified_snapshot(source, alias, digest)

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
            initial=dict(version=b.SHARD_STATE_VERSION,source='a'*64,production_source='a'*64,registry_sha256='registry-a')
            with patch.object(b.time,'time',return_value=111):
                self.assertEqual(b.prepare_shard_workspace(workspace,initial),111)
            with patch.object(b,'stage_seekable_dump',wraps=b.stage_seekable_dump) as stage:
                dump=b.cached_shard_dump(items,root,workspace)
                self.assertEqual(stage.call_count,1)
                original_inode=dump.stat().st_ino
                (workspace/'expander').mkdir()
                (workspace/'shards').mkdir()
                (workspace/'shards/old').write_text('stale')
                changed=dict(initial,source='b'*64,production_source='b'*64,registry_sha256='registry-b')
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
            expected=dict(version=b.SHARD_STATE_VERSION,source='a'*64,production_source='a'*64,files=[name])
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
                changed=dict(expected,source='b'*64,production_source='b'*64)
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
            expected={'version':b.SHARD_STATE_VERSION,'source':'a'*64,'production_source':'a'*64}
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
                    dest=Path(tool_arguments(command)[1]);exp=dest/'.bundle-expander';exp.mkdir(parents=True)
                    (dest/'.incomplete').write_text('expander ready')
                    (exp/'page-index.tsv').write_text('0\n1\n')
                    (exp/'dict-bundle-expander').write_text('worker');write_namespace_fixture(exp)
                elif blob_command(command,'build-blobs'):
                    dest=Path(tool_arguments(command)[1]);dest.mkdir(parents=True,exist_ok=True)
                    write_coverage(dest,command)
                elif blob_command(command,'merge-blobs'):
                    merges.append(command)
                    if len(merges)==1:raise subprocess.CalledProcessError(1,command)
                    dest=Path(tool_arguments(command)[0]);dest.mkdir()
                    (dest/'fallback-pages.jsonl').write_text('')
                    if blob_command(command,'merge-blobs'):write_namespace_coverage(dest,sum(json.loads((Path(x)/'page-coverage.json').read_text())['pages_seen'] for x in tool_arguments(command)[1:]))
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
                step=next((x for x in ('build-dictionary','build-blobs','verify-blobs','merge-blobs') if (x in command if x=='build-dictionary' else blob_command(command,x))),None)
                if step=='build-dictionary':
                    dest=Path(tool_arguments(command)[1]);exp=dest/'.bundle-expander';exp.mkdir(parents=True)
                    (dest/'.incomplete').write_text('expander ready')
                    (exp/'page-index.tsv').write_text('0\n1\n')
                    (exp/'dict-bundle-expander').write_text('worker');write_namespace_fixture(exp)
                elif step=='build-blobs':
                    dest=Path(tool_arguments(command)[1]);dest.mkdir(parents=True,exist_ok=True)
                    write_coverage(dest,command)
                    (dest/'fallback-pages.jsonl').write_text('')
                    if blob_command(command,'merge-blobs'):write_namespace_coverage(dest,sum(json.loads((Path(x)/'page-coverage.json').read_text())['pages_seen'] for x in tool_arguments(command)[1:]))
                    (dest/'languages.tsv').write_text('heading\n')
                elif step=='merge-blobs':
                    dest=Path(tool_arguments(command)[0]);dest.mkdir(parents=True)
                    (dest/'fallback-pages.jsonl').write_text('')
                    if blob_command(command,'merge-blobs'):write_namespace_coverage(dest,sum(json.loads((Path(x)/'page-coverage.json').read_text())['pages_seen'] for x in tool_arguments(command)[1:]))
                    (dest/'languages.tsv').write_text('heading\n')
                    (dest/'merged.wikblb').write_bytes(b'WIKBLB08merged')
            with patch.object(b,'PROJECT',root),patch.object(b,'SHARD_PAGES',1),patch.object(b,'source_fingerprint',return_value='source'),patch.object(b.time,'time',return_value=123),patch.object(b,'run_checked',side_effect=run):
                b.build([item],root,root/'output','zig',2,interwiki_snapshot=interwiki,
                        auxiliary_snapshots={'category-stats':category})
            blob_calls=[c for c in calls if blob_command(c,'build-blobs')]
            expander_call=next(c for c in calls if 'build-dictionary' in c)
            self.assertTrue(calls)
            bound_prefix=root/'output/testwiktionary/20260901.shards/test-blob-tools'
            for command in calls:
                if command[0]=='zig':
                    self.assertEqual(command[1:4],['build','-j1','-Doptimize=fast'])
                    self.assertIn('build-dictionary',command)
                else:
                    self.assertIn(Path(command[0]).name,b.BLOB_TOOL_NAMES)
                    self.assertEqual(Path(command[0]).parent,bound_prefix)
                    self.assertNotIn('--',command)
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
            self.assertEqual(sum(blob_command(c,'merge-blobs') for c in calls),1)
            self.assertGreaterEqual(sum(blob_command(c,'verify-blobs') for c in calls),3)
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
    def test_automatic_scheduler_reduces_four_to_two_to_one_without_restarting_jobs(self):
        groups={(wiki,'20260901'):[dict(wiki=wiki)] for wiki in
                ('aawiktionary','abwiktionary','acwiktionary')}
        dispatched=[]
        def budget(_owned=0):return (4,3,1)[min(len(dispatched),2)]
        def fake_build(group,downloads,output,zig,threads,**options):
            dispatched.append((group[0]['wiki'],threads))
            self.assertNotIn('expansion_workers',options)
            if len(dispatched)==1:raise ValueError('preserved first edition failure')
        with patch.object(b,'safe_worker_budget',side_effect=budget), \
             patch.object(b,'build',side_effect=fake_build),patch.object(b.time,'sleep') as sleep:
            failures=b.build_groups(groups,Path('.'),Path('.'),'zig',4,1,adaptive_workers=True)
        self.assertEqual(dispatched,[('aawiktionary',4),('abwiktionary',2),('acwiktionary',1)])
        self.assertEqual(failures,[('aawiktionary','20260901')])
        sleep.assert_not_called()

    def test_automatic_scheduler_preserves_zero_capacity_deadline(self):
        groups={(wiki,'20260901'):[dict(wiki=wiki)] for wiki in
                ('aawiktionary','abwiktionary','acwiktionary')}
        dispatched=[];clock=[0]
        def budget(_owned=0):return 0 if dispatched and clock[0]<7 else 4
        with patch.object(b,'safe_worker_budget',side_effect=budget), \
             patch.object(b,'build',side_effect=lambda group,*args,**kwargs:dispatched.append(group[0]['wiki'])), \
             patch.object(b.time,'monotonic',side_effect=lambda:clock[0]), \
             patch.object(b.time,'sleep',side_effect=lambda seconds:clock.__setitem__(0,clock[0]+seconds)) as sleep:
            failures=b.build_groups(groups,Path('.'),Path('.'),'zig',4,1,admission_wait_seconds=7,adaptive_workers=True)
        self.assertEqual(dispatched,['aawiktionary'])
        self.assertEqual(failures,[('abwiktionary','20260901'),('acwiktionary','20260901')])
        self.assertEqual([call.args[0] for call in sleep.call_args_list],[5,2])

    def test_main_automatic_count_handles_startup_drop_but_explicit_counts_remain_exact(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            write_test_manifest(root,{'files':[dict(wiki='testwiktionary',date='20261001',name='test.xml.bz2',
                url='https://dumps.wikimedia.org/testwiktionary/20261001/test.xml.bz2',size=1,sha1='a'*40)]})
            argv=['build_wiktionaries.py','--downloads',str(root),'--output',str(root/'output')]
            with patch.object(sys,'argv',argv),patch.object(b,'safe_worker_budget',side_effect=[4,3]), \
                 patch.object(b,'build_groups',return_value=[]) as groups:
                b.main()
            self.assertEqual(groups.call_args.args[4:],(2,1,None))
            self.assertTrue(groups.call_args.kwargs['adaptive_workers'])
            for flags,budgets in [(['--threads','4'],[3]),(['--expansion-workers','4'],[4,3])]:
                with self.subTest(flags=flags),patch.object(sys,'argv',argv+flags), \
                     patch.object(b,'safe_worker_budget',side_effect=budgets), \
                     patch.object(b,'build_groups',return_value=[]) as groups,contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit):b.main()
                    groups.assert_not_called()
            with patch.object(sys,'argv',argv+['--threads','2']),patch.object(b,'safe_worker_budget',return_value=3), \
                 patch.object(b,'build_groups',return_value=[]) as groups:
                b.main()
            self.assertEqual(groups.call_args.args[4:],(2,1,None))
            self.assertNotIn('adaptive_workers',groups.call_args.kwargs)

    def test_automatic_reduction_cannot_override_expansion_or_affinity_contract(self):
        for options in [dict(adaptive_workers=True,expansion_workers=4),
                        dict(adaptive_workers=True,cpu_admission='affinity'),dict(adaptive_workers=1)]:
            with self.subTest(options=options),self.assertRaisesRegex(ValueError,'Automatic worker reduction'):
                b.build_groups({},Path('.'),Path('.'),'zig',4,1,**options)

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
            with patch.object(b,'PROJECT',root),patch.object(sys,'argv',['build_wiktionaries.py']),patch.object(limits,'inside_envelope',return_value=False),patch.object(limits,'inside_watchdog',return_value=False),patch.object(limits,'supervise',side_effect=supervised) as supervise,patch.object(b,'safe_worker_budget',return_value=0),patch.object(b,'main') as main:
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
                    dest=Path(tool_arguments(command)[1]);dest.mkdir();(dest/'en.wikblb').write_bytes(b'WIKBLB08payload')
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
            (staging/b.AUXILIARY_SHA_NAME).write_text(json.dumps({name:b.sha256_file(folder/(name+'.tsv')) for name in ('namespace-registry','language-registry')}))
            with patch.object(b,'PROJECT',root):write_coverage(staging)
            first=staging/'first.wikblb';second=staging/'second.wikblb'
            first.write_bytes(b'WIKBLB08first');second.write_bytes(b'WIKBLB08second')
            real_run=subprocess.run
            def run(command,**kwargs):
                if command[0]=='xz':return real_run(command,**kwargs)
                raise AssertionError(f'unexpected rebuild command: {command}')
            with patch.object(b,'PROJECT',root),patch.object(b.subprocess,'run',side_effect=run):
                b.persist_build_identity(staging,b.build_input_identity([item],'zig',b.verified_auxiliary_hashes(write_namespace_fixture(folder)),None,None))
                b.seal_verified_publication_inventory(staging)
                (staging/b.VERIFIED_MARKER).write_text(b.VERIFIED_CONTENT)
                compress(first,64*1024,1)
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
                    dest=Path(tool_arguments(command)[1]);dest.mkdir();(dest/'fallback-pages.jsonl').write_text('')
                    write_coverage(dest)
            with patch.object(b,'PROJECT',root),patch.object(b.subprocess,'run',side_effect=run):
                b.build([item],root,root/'output','zig',2)
            final=root/'output/testwiktionary/20260901'
            self.assertEqual(json.loads((final/'complete.json').read_text())['status'],'empty')
            self.assertFalse((final/'old').exists())


class FallbackNamespaceHistogramTests(unittest.TestCase):
    @staticmethod
    def row(namespace, name, kind, expanded=0, fallback=0, aliases=0):
        return dict(id=namespace, name=name, kind=kind,
                    input_rows=expanded + fallback, compile_only_rows=0,
                    source_unavailable_rows=0, dispatched_rows=expanded + fallback,
                    expanded_pages=expanded, fallback_pages=fallback,
                    duplicate_rows=0, alias_pages=aliases)

    def test_fallback_namespace_histogram_valid_aliases_and_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rows = [self.row(0, '', 'language', expanded=1),
                    self.row(114, 'Citations', 'citations', fallback=1, aliases=1)]
            (root/'namespace-coverage.json').write_text(json.dumps(dict(version=1, namespaces=rows)))
            path = root/'fallback-pages.jsonl'
            path.write_text(json.dumps(dict(namespace=114, title='Citations:alias', reasons=['literal_markup']))+'\n')
            # A fallback alias counts as a fallback page, without subtraction.
            self.assertEqual(1, b.validate_fallback_report(path))
            counts = {999: 37}
            self.assertEqual(1, b.validate_fallback_report(path, counts))
            self.assertEqual({114: 1}, counts)
            totals = b.validate_namespace_coverage(root, 2, fallback_counts=counts)
            self.assertEqual((1, 1), (totals['fallback_pages'], totals['alias_pages']))
            path.write_text('')
            rows[1].update(expanded_pages=1, fallback_pages=0)
            (root/'namespace-coverage.json').write_text(json.dumps(dict(version=1, namespaces=rows)))
            self.assertEqual(0, b.validate_fallback_report(path, counts))
            self.assertEqual({}, counts)
            self.assertEqual(0, b.validate_namespace_coverage(root, 2, fallback_counts=counts)['fallback_pages'])
            (root/'namespace-coverage.json').write_text(json.dumps(dict(version=1, namespaces=[])))
            self.assertEqual(0, b.validate_namespace_coverage(root, 0, fallback_counts={})['input_rows'])

    def test_fallback_namespace_histogram_output_committed_after_validation(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'fallback-pages.jsonl'
            page = json.dumps(dict(namespace=0, title='same', reasons=['literal_markup']))+'\n'
            path.write_text(page+page)
            counts = {999: 37}
            with self.assertRaisesRegex(ValueError, 'Duplicate fallback page'):
                b.validate_fallback_report(path, counts)
            self.assertEqual({999: 37}, counts)


    def test_fallback_reason_counts_overlap_in_one_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'fallback-pages.jsonl'
            rows = [dict(namespace=0, title='one', reasons=['literal_markup', 'missing_language_heading']),
                    dict(namespace=114, title='two', reasons=['literal_markup'])]
            path.write_text(''.join(json.dumps(row)+'\n' for row in rows))
            namespaces, reasons, opens = {999: 37}, {'old': 37}, []
            original_open = Path.open
            def opened(selected, *args, **kwargs):
                if selected == path:
                    opens.append(selected)
                return original_open(selected, *args, **kwargs)
            with patch.object(Path, 'open', opened):
                self.assertEqual(2, b.validate_fallback_report(path, namespaces, reasons))
            self.assertEqual([path], opens)
            self.assertEqual({0: 1, 114: 1}, namespaces)
            self.assertEqual({'literal_markup': 2, 'missing_language_heading': 1}, reasons)
            self.assertEqual(3, sum(reasons.values()))

    def test_fallback_reason_counts_empty_report_clears_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'fallback-pages.jsonl'
            path.write_text('')
            namespaces, reasons = {999: 37}, {'old': 37}
            self.assertEqual(0, b.validate_fallback_report(path, namespaces, reasons))
            self.assertEqual({}, namespaces)
            self.assertEqual({}, reasons)

    def test_fallback_reason_counts_rejections_do_not_commit_partial_counts(self):
        good = dict(namespace=0, title='first', reasons=['literal_markup'])
        prefix = json.dumps(good)+'\n'
        bad_records = [good, None, dict(namespace=True, title='bad', reasons=['literal_markup']),
                       dict(namespace=0, title='bad', reasons=[]),
                       dict(namespace=0, title='bad', reasons=['']),
                       dict(namespace=0, title='bad', reasons=[7]),
                       dict(namespace=0, title='bad', reasons=['literal_markup', 'literal_markup'])]
        for reason in ('expansion_error:Timeout', 'expansion_error:expand:OutOfMemory',
                       'expansion_error:worker:Crash'):
            bad_records.append(dict(namespace=0, title='bad', reasons=[reason]))
        suffixes = ['{broken\n', '\n'] + [json.dumps(row)+'\n' for row in bad_records]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'fallback-pages.jsonl'
            for suffix in suffixes:
                with self.subTest(suffix=suffix):
                    path.write_text(prefix+suffix)
                    namespaces, reasons = {999: 37}, {'old': 37}
                    with self.assertRaises(ValueError):
                        b.validate_fallback_report(path, namespaces, reasons)
                    self.assertEqual({999: 37}, namespaces)
                    self.assertEqual({'old': 37}, reasons)


class PublicationResumeTests(unittest.TestCase):
    def fallback_namespace_fixture(self, root):
        item, target, workspace = self.prepare(root, publish=False)
        staging = target.with_name(item['date']+'.building')
        folder = root/item['wiki']/item['date']
        namespace = folder/'namespace-registry.tsv'
        with namespace.open('a') as out:
            out.write('114\tCitations\tCitations\tcase-sensitive\t0\t0\t0\t\tcitations\tentries\n')
        snapshots = {'namespace-registry': namespace, 'language-registry': folder/'language-registry.tsv'}
        hashes = b.verified_auxiliary_hashes(snapshots)
        identity = b.build_input_identity([item], 'zig', hashes, None, None)
        (staging/b.AUXILIARY_SHA_NAME).write_text(json.dumps(hashes))
        b.persist_build_identity(staging, identity)
        coverage = json.loads((staging/'page-coverage.json').read_text())
        coverage.update(pages_seen=3, expected_input_pages=3)
        (staging/'page-coverage.json').write_text(json.dumps(coverage))
        rows = [FallbackNamespaceHistogramTests.row(0, '', 'language', expanded=1),
                FallbackNamespaceHistogramTests.row(114, 'Citations', 'citations', fallback=1)]
        compile_only = FallbackNamespaceHistogramTests.row(10, 'Template', None)
        compile_only.update(input_rows=1, compile_only_rows=1)
        rows.append(compile_only)
        (staging/'namespace-coverage.json').write_text(json.dumps(dict(
            version=1, registry_sha256=b.sha256_file(namespace), namespaces=rows)))
        (staging/'fallback-pages.jsonl').write_text(json.dumps(dict(
            namespace=114, title='Citations:fixture', reasons=['literal_markup']))+'\n')
        # Construct this controlled raw fixture's seal after its final metadata.
        (staging/b.VERIFIED_INVENTORY_NAME).unlink()
        b.seal_verified_publication_inventory(staging)
        return item, target, workspace, staging, namespace, hashes, identity

    def test_fallback_namespace_histogram_refuses_publication_same_total(self):
        for wrong_namespace in (0, 10, 999):
            with self.subTest(namespace=wrong_namespace), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                with patch.object(b, 'PROJECT', root):
                    item, target, workspace, staging, namespace, hashes, identity = self.fallback_namespace_fixture(root)
                    # Both old grand totals are still one. Only ownership is wrong:
                    # selected-main zero, compile-only Template, or unknown ns.
                    report = staging/'fallback-pages.jsonl'
                    record = json.loads(report.read_text())
                    record['namespace'] = wrong_namespace
                    report.write_text(json.dumps(record)+'\n')
                    self.assertEqual(1, b.validate_fallback_report(report))
                    with patch.object(b, 'compress_many') as compress:
                        with self.assertRaisesRegex(ValueError, '(Namespace fallback counts differ|Fallback report names namespace)'):
                            b._publish_verified_staging(staging, target, item['wiki'], item['date'], 1,
                                auxiliary_hashes=hashes, build_identity=identity, namespace_snapshot=namespace)
                        compress.assert_not_called()
                    self.assertFalse((target/'complete.json').exists())
                    self.assertTrue((workspace/'sentinel').exists())
                    self.assertTrue((staging/b.VERIFIED_MARKER).exists())

    def test_fallback_namespace_histogram_refuses_existing_output_same_total(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with patch.object(b, 'PROJECT', root):
                item, target, workspace, staging, namespace, hashes, identity = self.fallback_namespace_fixture(root)
                b._publish_verified_staging(staging, target, item['wiki'], item['date'], 1,
                    auxiliary_hashes=hashes, build_identity=identity, namespace_snapshot=namespace)
                # Valid multi-namespace publication is a positive control first.
                complete = target/'complete.json'
                metadata = json.loads(complete.read_text())
                self.assertEqual(1, metadata['fallback_pages'])
                # Successful publication retires the old workspace first.
                self.assertFalse(workspace.exists())
                workspace.mkdir()
                sentinel=workspace/'sentinel';sentinel.write_bytes(b'owned recovery state after publication')
                report = target/'fallback-pages.jsonl'
                record = json.loads(report.read_text()); record['namespace'] = 0
                report.write_text(json.dumps(record)+'\n')
                # Make the inventory agree, so histogram ownership must refuse it.
                metadata['publication_files'] = b.publication_inventory(target)
                complete.write_text(json.dumps(metadata))
                before = complete.read_bytes()
                with patch.object(b, 'run_checked') as native:
                    with self.assertRaisesRegex(ValueError, 'Namespace fallback counts differ'):
                        b.build([item], root, root/'output', 'zig', 1)
                    native.assert_not_called()
                self.assertEqual(before, complete.read_bytes())
                self.assertEqual(sentinel.read_bytes(),b'owned recovery state after publication')

    @staticmethod
    def compress_reason_count_fixture(paths, block_size, workers):
        # Count/publication metadata control: no external compressor process.
        for path in paths:
            raw = path.read_bytes()
            assert raw == b'WIKBLB08fixture'
            target = Path(str(path)+'.xz')
            with target.open('xb') as out:
                out.write(lzma.compress(raw, preset=0))
            b.verify_round_trip(path, target)
            path.unlink()

    def test_fallback_reason_counts_publication_and_legacy_reuse(self):
        for has_fallback in (False, True):
            with self.subTest(has_fallback=has_fallback), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                with patch.object(b, 'PROJECT', root), \
                     patch.object(b, 'compress_many', side_effect=self.compress_reason_count_fixture):
                    if has_fallback:
                        item, target, workspace, staging, namespace, hashes, identity = self.fallback_namespace_fixture(root)
                        b._publish_verified_staging(staging, target, item['wiki'], item['date'], 1,
                            auxiliary_hashes=hashes, build_identity=identity, namespace_snapshot=namespace)
                    else:
                        item, target, workspace = self.prepare(root)
                    complete = target/'complete.json'
                    metadata = json.loads(complete.read_text())
                    self.assertEqual({'literal_markup': 1} if has_fallback else {}, metadata['fallback_reason_counts'])
                    before = complete.read_bytes()
                    with patch.object(b, 'run_checked') as native:
                        self.assertEqual('existing_output', b.build([item], root, root/'output', 'zig', 1))
                        native.assert_not_called()
                    self.assertEqual(before, complete.read_bytes())
                    del metadata['fallback_reason_counts']
                    complete.write_text(json.dumps(metadata)+'\n')
                    legacy = complete.read_bytes()
                    with patch.object(b, 'run_checked') as native:
                        self.assertEqual('existing_output', b.build([item], root, root/'output', 'zig', 1))
                        native.assert_not_called()
                    self.assertEqual(legacy, complete.read_bytes())

    def test_fallback_reason_counts_mismatch_preserves_existing_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with patch.object(b, 'PROJECT', root), \
                 patch.object(b, 'compress_many', side_effect=self.compress_reason_count_fixture):
                item, target, workspace, staging, namespace, hashes, identity = self.fallback_namespace_fixture(root)
                b._publish_verified_staging(staging, target, item['wiki'], item['date'], 1,
                    auxiliary_hashes=hashes, build_identity=identity, namespace_snapshot=namespace)
                workspace.mkdir()
                sentinel = workspace/'sentinel'; sentinel.write_bytes(b'preserve recovery state')
                complete = target/'complete.json'; metadata = json.loads(complete.read_text())
                for wrong in (None, [], {}, {'literal_markup': 2}, {'other': 1},
                              {'literal_markup': True}, {'literal_markup': 1.0},
                              {'literal_markup': 0}, {'literal_markup': -1}):
                    with self.subTest(wrong=wrong):
                        metadata['fallback_reason_counts'] = wrong
                        complete.write_text(json.dumps(metadata)+'\n')
                        before = complete.read_bytes()
                        with patch.object(b, 'run_checked') as native:
                            with self.assertRaisesRegex(ValueError, 'fallback reason counts differ'):
                                b.build([item], root, root/'output', 'zig', 1)
                            native.assert_not_called()
                        self.assertEqual(before, complete.read_bytes())
                        self.assertEqual(b'preserve recovery state', sentinel.read_bytes())

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
        hashes=b.verified_auxiliary_hashes(snapshots)
        (staging/b.AUXILIARY_SHA_NAME).write_text(json.dumps(hashes))
        identity=b.build_input_identity([item],'zig',hashes,None,None)
        b.persist_build_identity(staging,identity)
        b.seal_verified_publication_inventory(staging)
        (staging/b.VERIFIED_MARKER).write_text(b.VERIFIED_CONTENT)
        if publish:
            b._publish_verified_staging(staging,target,'testwiktionary','20260901',1,
                auxiliary_hashes=hashes,build_identity=identity,namespace_snapshot=snapshots['namespace-registry'])
        workspace=target.with_name('20260901.shards');workspace.mkdir()
        (workspace/'sentinel').write_text('keep until publication is verified')
        return item,target,workspace

    def assert_failed_build_timing(self, root, item, error, verification):
        import corpus_controller as controller
        output=io.StringIO()
        with patch.object(b,'run_checked') as native,patch('sys.stdout',output):
            with self.assertRaisesRegex(ValueError,error):
                b.build([item],root,root/'output','zig',1)
        native.assert_not_called()
        log=root/'failed-build.log';log.write_text(output.getvalue())
        phase=controller.phase_end(log,item['wiki'],item['date'])
        self.assertEqual(phase['status'],'failure')
        self.assertEqual(phase.get('execution_mode'),'existing_output' if verification else None)
        row=dict(attempt_id='failed',sequence=2,edition=item['wiki'],elapsed_seconds=3,
                 execution_mode=phase.get('execution_mode'),accepted=None,outcome='failed')
        prior=dict(attempt_id='built',sequence=1,edition=item['wiki'],elapsed_seconds=7,
                   execution_mode='pipeline_run_may_reuse_verified_inputs_or_shards',
                   accepted={'input_pages':11},outcome='passed')
        summary=controller.summarize([prior,row,dict(row)],[item['wiki']])
        observed=summary['editions'][0]
        self.assertEqual(observed['attempt_count'],2)
        self.assertEqual(observed['observed_build_seconds'],7 if verification else 10)
        self.assertEqual(observed['verification_seconds'],3 if verification else 0)
        self.assertIsNone(observed['accepted'])
        self.assertEqual(summary['accepted_cohort_input_pages'],0)
        self.assertIsNone(summary['final_observed_pages_per_second'])

    def test_failed_published_inventory_revalidation_excludes_production_time(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            with patch.object(b,'PROJECT',root),patch.object(b,'run_checked'):
                item,target,workspace=self.prepare(root)
                before=(target/'complete.json').read_bytes()
                with (target/'supplemental.wikblb.xz').open('ab') as stream:stream.write(b'changed')
                self.assert_failed_build_timing(root,item,'publication inventory is missing or changed',True)
                self.assertEqual((target/'complete.json').read_bytes(),before)
                self.assertTrue((workspace/'sentinel').is_file())

    def test_failed_existing_input_admission_excludes_production_time(self):
        for failure in ('registry','download'):
            with self.subTest(failure=failure),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp)
                with patch.object(b,'PROJECT',root),patch.object(b,'run_checked'):
                    item,target,workspace=self.prepare(root)
                    before=(target/'complete.json').read_bytes()
                    folder=root/item['wiki']/item['date']
                    if failure=='registry':
                        (folder/'language-registry.tsv').unlink()
                        error='Missing pinned language registry'
                    else:
                        (folder/item['name']).write_bytes(b'changed')
                        error='Missing or unverified download'
                    self.assert_failed_build_timing(root,item,error,True)
                    self.assertEqual((target/'complete.json').read_bytes(),before)
                    self.assertTrue((workspace/'sentinel').is_file())

    def test_failed_fresh_and_resumed_publication_remain_production_time(self):
        for resumed in (False,True):
            with self.subTest(resumed=resumed),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp)
                with patch.object(b,'PROJECT',root),patch.object(b,'run_checked'):
                    item,target,workspace=self.prepare(root,publish=False)
                    if resumed:
                        patcher=patch.object(b,'publish_verified_staging',side_effect=ValueError('resumed publication failure'))
                        error='resumed publication failure'
                    else:
                        (target.with_name(item['date']+'.building')/b.VERIFIED_MARKER).unlink()
                        patcher=patch.object(b,'cached_shard_dump',side_effect=ValueError('fresh input preparation failure'))
                        error='fresh input preparation failure'
                    with patcher:self.assert_failed_build_timing(root,item,error,False)
                    self.assertFalse((target/'complete.json').exists())

    def test_successful_return_overrides_provisional_existing_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            with patch.object(b,'PROJECT',root),patch.object(b,'run_checked'):
                item,target,_=self.prepare(root)
                output=io.StringIO()
                with patch.object(b,'build_locked',return_value='resumed_publication'),patch('sys.stdout',output):
                    self.assertEqual(b.build([item],root,root/'output','zig',1),'resumed_publication')
                events=[json.loads(line[len('BUILD_PHASE '):]) for line in output.getvalue().splitlines() if line.startswith('BUILD_PHASE ')]
                terminal=[row for row in events if row['phase']=='edition_build' and row['event']=='end']
                self.assertEqual(len(terminal),1)
                self.assertEqual(terminal[0]['status'],'success')
                self.assertEqual(terminal[0]['execution_mode'],'resumed_publication')

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


class VerifiedPublicationInventoryTests(unittest.TestCase):
    prepare = PublicationResumeTests.prepare
    """Synthetic interrupted staging; never compile or bless native fixtures."""
    def interrupted(self, root):
        item,target,workspace=self.prepare(root,publish=False)
        with patch.object(b.os,'rename',side_effect=OSError('publication interrupted')):
            with self.assertRaisesRegex(OSError,'publication interrupted'):
                b.build_locked([item],root,root/'output','zig',1)
        staging=target.with_name('20260901.building')
        self.assertFalse((staging/'supplemental.wikblb').exists())
        self.assertTrue((staging/'supplemental.wikblb.xz').is_file())
        return item,target,workspace,staging

    def assert_refused_preserved(self,item,target,workspace,staging,pattern=''):
        inventory=(staging/b.VERIFIED_INVENTORY_NAME).read_bytes() if (staging/b.VERIFIED_INVENTORY_NAME).exists() else None
        complete=(staging/'complete.json').read_bytes() if (staging/'complete.json').exists() else None
        workspace_before={p.relative_to(workspace).as_posix():p.read_bytes() for p in workspace.rglob('*') if p.is_file()} if workspace.exists() else None
        with patch.object(b,'run_checked') as native:
            with self.assertRaisesRegex(ValueError,pattern):b.build_locked([item],staging.parents[2],staging.parents[1],'zig',1)
            native.assert_not_called()
        self.assertFalse(target.exists());self.assertTrue((staging/b.VERIFIED_MARKER).is_file())
        if workspace_before is None:self.assertFalse(workspace.exists())
        else:
            self.assertTrue(workspace.is_dir())
            self.assertEqual({p.relative_to(workspace).as_posix():p.read_bytes() for p in workspace.rglob('*') if p.is_file()},workspace_before)
        self.assertEqual(inventory,(staging/b.VERIFIED_INVENTORY_NAME).read_bytes() if inventory is not None else None)
        self.assertEqual(complete,(staging/'complete.json').read_bytes() if complete is not None else None)

    def test_missing_namespace_report_refuses_before_cleanup_then_exact_restore_recovers(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            with patch.object(b,'PROJECT',root):
                item,target,workspace,staging=self.interrupted(root)
                report=staging/'namespace-coverage.json';raw=report.read_bytes();report.unlink()
                with patch.object(b,'cleanup_shard_workspace',side_effect=AssertionError('Cleanup before coverage refusal')) as cleanup:
                    self.assert_refused_preserved(item,target,workspace,staging,'Missing or invalid namespace coverage')
                    cleanup.assert_not_called()
                self.assertFalse(report.exists())
                report.write_bytes(raw)
                with patch.object(b,'run_checked') as native:
                    self.assertEqual(b.build_locked([item],root,root/'output','zig',1),'resumed_publication')
                    native.assert_not_called()
                self.assertEqual((target/'namespace-coverage.json').read_bytes(),raw)
                self.assertFalse(staging.exists())
                self.assertFalse((target/b.VERIFIED_MARKER).exists())
                self.assertEqual(b.publication_inventory(target),json.loads((target/'complete.json').read_text())['publication_files'])

    def test_sealed_compressed_only_interrupted_resume_keeps_exact_logical_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            with patch.object(b,'PROJECT',root):
                item,target,workspace,staging=self.interrupted(root)
                saved=(staging/b.VERIFIED_INVENTORY_NAME).read_bytes()
                expected=json.loads(saved)['files'];self.assertIn('supplemental.wikblb',expected)
                self.assertNotIn('supplemental.wikblb.xz',expected)
                with patch.object(b,'run_checked') as native:
                    self.assertEqual(b.build_locked([item],root,root/'output','zig',1),'resumed_publication');native.assert_not_called()
                self.assertEqual(lzma.open(target/'supplemental.wikblb.xz').read(),b'WIKBLB08fixture')
                self.assertFalse((target/b.VERIFIED_INVENTORY_NAME).exists())
                self.assertEqual(b.publication_inventory(target),json.loads((target/'complete.json').read_text())['publication_files'])

    def test_interrupted_missing_compressed_payload_cannot_be_relabelled_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            with patch.object(b,'PROJECT',root):
                item,target,workspace,staging=self.interrupted(root);(staging/'supplemental.wikblb.xz').unlink()
                self.assert_refused_preserved(item,target,workspace,staging,'Missing verified payload')

    def test_interrupted_truncated_compressed_payload_preserves_inventory_and_completion(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            with patch.object(b,'PROJECT',root):
                item,target,workspace,staging=self.interrupted(root);path=staging/'supplemental.wikblb.xz';path.write_bytes(path.read_bytes()[:-16])
                self.assert_refused_preserved(item,target,workspace,staging,'Invalid verified compressed payload')

    def test_interrupted_valid_compression_with_changed_same_size_logical_payload_refuses(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            with patch.object(b,'PROJECT',root):
                item,target,workspace,staging=self.interrupted(root);(staging/'supplemental.wikblb.xz').write_bytes(lzma.compress(b'WIKBLB08changed',preset=1))
                self.assert_refused_preserved(item,target,workspace,staging,'Verified decoded payload changed')

    def test_interrupted_equivalent_recompression_retains_logical_identity_and_pins_new_encoding(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            with patch.object(b,'PROJECT',root):
                item,target,workspace,staging=self.interrupted(root);path=staging/'supplemental.wikblb.xz';original=path.read_bytes();replacement=lzma.compress(b'WIKBLB08fixture',preset=1)
                self.assertNotEqual(original,replacement);path.write_bytes(replacement)
                self.assertEqual(b.build_locked([item],root,root/'output','zig',1),'resumed_publication')
                record=json.loads((target/'complete.json').read_text())['publication_files']['supplemental.wikblb.xz']
                self.assertEqual(record['sha256'],hashlib.sha256(replacement).hexdigest())
                self.assertEqual(lzma.open(target/'supplemental.wikblb.xz').read(),b'WIKBLB08fixture')

    def test_marker_only_legacy_staging_is_preserved_without_adopting_remaining_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            with patch.object(b,'PROJECT',root):
                item,target,workspace=self.prepare(root,publish=False);staging=target.with_name('20260901.building');(staging/b.VERIFIED_INVENTORY_NAME).unlink()
                self.assert_refused_preserved(item,target,workspace,staging,'lacks its sealed inventory')
                self.assertEqual((staging/'supplemental.wikblb').read_bytes(),b'WIKBLB08fixture')
                self.assertFalse((staging/b.VERIFIED_INVENTORY_NAME).exists())

    def test_interrupted_metadata_and_unexpected_payload_refuse(self):
        for change in ('metadata','extra'):
            with self.subTest(change=change),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp)
                with patch.object(b,'PROJECT',root):
                    item,target,workspace,staging=self.interrupted(root)
                    if change=='metadata':(staging/'languages.tsv').write_text('changed')
                    else:(staging/'extra.wikblb.xz').write_bytes((staging/'supplemental.wikblb.xz').read_bytes())
                    self.assert_refused_preserved(item,target,workspace,staging,'metadata changed|Unexpected member')

    def test_changed_raw_payload_refuses_before_compression(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            with patch.object(b,'PROJECT',root):
                item,target,workspace=self.prepare(root,publish=False);staging=target.with_name('20260901.building');(staging/'supplemental.wikblb').write_bytes(b'WIKBLB08changed')
                with patch.object(b,'compress_many') as compress:
                    self.assert_refused_preserved(item,target,workspace,staging,'Verified raw payload changed');compress.assert_not_called()

    def test_decoded_size_cannot_exceed_sealed_size(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            with patch.object(b,'PROJECT',root):
                item,target,workspace,staging=self.interrupted(root);(staging/'supplemental.wikblb.xz').write_bytes(lzma.compress(b'WIKBLB08fixture-extra',preset=1))
                self.assert_refused_preserved(item,target,workspace,staging,'exceeds sealed size')

    def test_interrupted_trailing_garbage_is_not_blessed_as_equivalent_compression(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            with patch.object(b,'PROJECT',root):
                item,target,workspace,staging=self.interrupted(root);path=staging/'supplemental.wikblb.xz';path.write_bytes(path.read_bytes()+b'not an XZ stream')
                self.assert_refused_preserved(item,target,workspace,staging,'Invalid verified compressed payload')

    def test_interrupted_lzma_alone_disguised_as_xz_refuses(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            with patch.object(b,'PROJECT',root):
                item,target,workspace,staging=self.interrupted(root);(staging/'supplemental.wikblb.xz').write_bytes(lzma.compress(b'WIKBLB08fixture',format=lzma.FORMAT_ALONE,preset=1))
                self.assert_refused_preserved(item,target,workspace,staging,'Invalid verified compressed payload')

    def test_interrupted_concatenated_valid_xz_streams_preserve_exact_logical_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            with patch.object(b,'PROJECT',root):
                item,target,workspace,staging=self.interrupted(root);path=staging/'supplemental.wikblb.xz';path.write_bytes(lzma.compress(b'WIKBLB08',preset=1)+lzma.compress(b'fixture',preset=1))
                self.assertEqual(b.build_locked([item],root,root/'output','zig',1),'resumed_publication')
                self.assertEqual(lzma.open(target/'supplemental.wikblb.xz').read(),b'WIKBLB08fixture')

    def test_decoder_diagnostics_are_bounded_and_owned_child_is_reaped(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'fixture.wikblb.xz';path.write_bytes(lzma.compress(b'WIKBLB08fixture',preset=1))
            real_popen=subprocess.Popen;children=[]
            def noisy_decoder(argv,**kwargs):
                self.assertIn('--format=xz',argv);self.assertNotIn('--single-stream',argv)
                self.assertIn('--threads=1',argv);self.assertIn('--memlimit-decompress=64MiB',argv)
                child=real_popen([sys.executable,'-B','-c',"import sys;sys.stderr.buffer.write(b'x'*65537);sys.stderr.flush();sys.stdout.buffer.write(b'WIKBLB08fixture');sys.stdout.flush()"],**kwargs)
                children.append(child);return child
            with patch.object(b.subprocess,'Popen',side_effect=noisy_decoder):
                with self.assertRaisesRegex(ValueError,'stderr exceeds bound'):b.verified_xz_record(path,15)
            self.assertEqual(len(children),1);self.assertIsNotNone(children[0].returncode)
            self.assertTrue(children[0].stdout.closed and children[0].stderr.closed)

    def test_fresh_compressed_seal_keeps_logical_v1_and_publication_resume(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);staging=root/'staging';staging.mkdir()
            with patch.object(b,'PROJECT',root):
                write_coverage(staging);(staging/b.NOW_UNIX_NAME).write_text('123\n')
                payload=b'WIKBLB08\x07ordinary compiled bytes'
                blob=staging/'supplemental.wikblb.xz';blob.write_bytes(lzma.compress(payload))
                with self.assertRaisesRegex(ValueError,'compressed leftovers'):
                    b.seal_verified_publication_inventory(staging)
                b.seal_verified_publication_inventory(staging,fresh_compressed=True)
                seal=json.loads((staging/b.VERIFIED_INVENTORY_NAME).read_text())
                self.assertEqual(seal['version'],1)
                self.assertEqual(seal['files']['supplemental.wikblb'],dict(size=len(payload),sha256=hashlib.sha256(payload).hexdigest()))
                self.assertNotIn('supplemental.wikblb.xz',seal['files'])
                expected,checked=b.validate_verified_publication_inventory(staging)
                self.assertEqual(expected,seal['files']);self.assertIn('supplemental.wikblb.xz',checked)
                (staging/b.VERIFIED_MARKER).write_text(b.VERIFIED_CONTENT)
                with patch.object(b,'compress_many') as encode,patch.object(b.os,'rename',side_effect=OSError('interrupt publication')):
                    with self.assertRaisesRegex(OSError,'interrupt publication'):
                        b._publish_verified_staging(staging,root/'final','test','20260901')
                    encode.assert_not_called()
                # The interrupted XZ-only tree uses the unchanged strict v1 resume path.
                with patch.object(b,'compress_many') as encode:
                    b._publish_verified_staging(staging,root/'final','test','20260901')
                    encode.assert_not_called()
                final=root/'final';self.assertEqual(lzma.decompress((final/blob.name).read_bytes()),payload)
                self.assertEqual(json.loads((final/'complete.json').read_text())['publication_files'][blob.name]['sha256'],b.sha256_file(final/blob.name))

    def test_fresh_compressed_seal_rejects_survivors_twins_unknown_and_changed_bytes(self):
        for fault in ('marker','raw-twin','extra','wrong-kind','changed'):
            with self.subTest(fault=fault),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);staging=root/'staging';staging.mkdir()
                with patch.object(b,'PROJECT',root):
                    write_coverage(staging);payload=b'WIKBLB08\x07ordinary'
                    blob=staging/'supplemental.wikblb.xz';blob.write_bytes(lzma.compress(payload))
                    if fault=='marker':(staging/b.VERIFIED_MARKER).write_text(b.VERIFIED_CONTENT)
                    elif fault=='raw-twin':(staging/'supplemental.wikblb').write_bytes(payload)
                    elif fault=='extra':(staging/'extra.wikblb.xz').write_bytes(blob.read_bytes())
                    elif fault=='wrong-kind':blob.write_bytes(lzma.compress(b'WIKBLB08\x08wrong'))
                    original=b.verified_xz_record
                    def changed(path,size):
                        result=original(path,size);path.write_bytes(lzma.compress(payload+b'changed'));return result
                    with patch.object(b,'verified_xz_record',side_effect=changed if fault=='changed' else original):
                        with self.assertRaises(ValueError):b.seal_verified_publication_inventory(staging,fresh_compressed=True)
                    self.assertFalse((staging/b.VERIFIED_INVENTORY_NAME).exists());self.assertTrue(blob.exists())

    def test_inventory_cannot_be_resealed_from_compressed_survivors(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            with patch.object(b,'PROJECT',root):
                item,target,workspace,staging=self.interrupted(root);before=(staging/b.VERIFIED_INVENTORY_NAME).read_bytes()
                with self.assertRaisesRegex(ValueError,'compressed leftovers'):b.seal_verified_publication_inventory(staging)
                self.assertEqual(before,(staging/b.VERIFIED_INVENTORY_NAME).read_bytes())


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



class VerifiedResumeCleanupOrderTests(unittest.TestCase):
    """Owned synthetic staging only; no native compilation or actual corpus input."""
    prepare = PublicationResumeTests.prepare

    def owned_inputs(self, root):
        item,target,workspace=self.prepare(root,publish=False)
        staging=target.with_name(item['date']+'.building')
        raw=root/'raw-shards'/item['wiki']/(item['date']+'.raw-shards')
        b.external_raw_shards(workspace,raw,create=True)
        (workspace/'state.json').write_text(json.dumps({'raw_shards_path':str(raw)}))
        shard=raw/'00000000';shard.mkdir()
        (shard/'.verified').write_text('verified\n')
        (shard/'supplemental.wikblb').write_bytes(b'WIKBLB08fixture')
        return item,target,workspace,staging,raw

    def files(self, root):
        return {p.relative_to(root).as_posix():p.read_bytes() for p in root.rglob('*') if p.is_file()}

    def test_verified_resume_cleanup_failure_retries_before_first_xz_without_page_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            with patch.object(b,'PROJECT',root):
                item,target,workspace,staging,raw=self.owned_inputs(root)
                before=self.files(root)
                with patch.object(b,'cleanup_shard_workspace',side_effect=PermissionError('owned cleanup interrupted')), \
                     patch.object(b,'compress_many',wraps=b.compress_many) as compression, \
                     patch.object(b,'run_checked') as native:
                    with self.assertRaisesRegex(PermissionError,'owned cleanup interrupted'):
                        b.build_locked([item],root,root/'output','zig',1)
                    compression.assert_not_called();native.assert_not_called()
                self.assertEqual(self.files(root),before)
                self.assertFalse(target.exists())
                original=b.compress_many
                def compress_after_cleanup(paths,*args,**kwargs):
                    self.assertFalse(workspace.exists());self.assertFalse(raw.exists())
                    self.assertTrue((staging/b.VERIFIED_MARKER).is_file())
                    return original(paths,*args,**kwargs)
                with patch.object(b,'compress_many',side_effect=compress_after_cleanup) as compression, \
                     patch.object(b,'run_checked') as native:
                    self.assertEqual(b.build_locked([item],root,root/'output','zig',1),'resumed_publication')
                    compression.assert_called_once();native.assert_not_called()
                self.assertEqual(lzma.open(target/'supplemental.wikblb.xz').read(),b'WIKBLB08fixture')
                self.assertFalse(staging.exists());self.assertFalse(workspace.exists());self.assertFalse(raw.exists())
                self.assertEqual(b.publication_inventory(target),json.loads((target/'complete.json').read_text())['publication_files'])

    def test_verified_resume_authenticates_identity_inventory_and_payloads_before_cleanup(self):
        for changed in ('identity','missing_inventory','raw','compressed_twin'):
            with self.subTest(changed=changed),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp)
                with patch.object(b,'PROJECT',root):
                    item,target,workspace,staging,raw=self.owned_inputs(root)
                    if changed=='identity':
                        path=staging/b.BUILD_IDENTITY_NAME;value=json.loads(path.read_text());value['source']='different-source';path.write_text(json.dumps(value))
                    elif changed=='missing_inventory':(staging/b.VERIFIED_INVENTORY_NAME).unlink()
                    elif changed=='raw':(staging/'supplemental.wikblb').write_bytes(b'WIKBLB08changed')
                    else:(staging/'supplemental.wikblb.xz').write_bytes(lzma.compress(b'WIKBLB08changed'))
                    before=self.files(root)
                    with patch.object(b,'cleanup_shard_workspace',wraps=b.cleanup_shard_workspace) as cleanup, \
                         patch.object(b,'compress_many') as compression,patch.object(b,'run_checked') as native:
                        with self.assertRaises(ValueError):b.build_locked([item],root,root/'output','zig',1)
                        cleanup.assert_not_called();compression.assert_not_called();native.assert_not_called()
                    self.assertEqual(self.files(root),before)
                    self.assertTrue(workspace.exists());self.assertTrue(raw.exists());self.assertFalse(target.exists())

    def test_verified_resume_raw_xz_twins_keep_owner_guard_and_retire_shards_before_roundtrip(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            with patch.object(b,'PROJECT',root):
                item,target,workspace,staging,raw=self.owned_inputs(root)
                payload=(staging/'supplemental.wikblb').read_bytes()
                (staging/'supplemental.wikblb.xz').write_bytes(lzma.compress(payload))
                owner=raw/b.RAW_SHARD_OWNER;saved_owner=owner.read_bytes();value=json.loads(saved_owner)
                value['workspace']=str(root/'different.shards');owner.write_text(json.dumps(value))
                before=self.files(root)
                with patch.object(b,'compress_many') as compression,patch.object(b,'run_checked') as native:
                    with self.assertRaisesRegex(ValueError,'raw shard owner differs'):
                        b.build_locked([item],root,root/'output','zig',1)
                    compression.assert_not_called();native.assert_not_called()
                self.assertEqual(self.files(root),before);self.assertFalse(target.exists())
                owner.write_bytes(saved_owner)
                original=b.verify_round_trip
                def roundtrip_after_cleanup(path,compressed):
                    self.assertFalse(workspace.exists());self.assertFalse(raw.exists())
                    return original(path,compressed)
                with patch.object(b,'verify_round_trip',side_effect=roundtrip_after_cleanup) as verified, \
                     patch.object(b,'compress_many') as compression,patch.object(b,'run_checked') as native:
                    self.assertEqual(b.build_locked([item],root,root/'output','zig',1),'resumed_publication')
                    verified.assert_called_once();compression.assert_not_called();native.assert_not_called()
                self.assertFalse((target/'supplemental.wikblb').exists())
                self.assertEqual(lzma.open(target/'supplemental.wikblb.xz').read(),payload)
                self.assertFalse(workspace.exists());self.assertFalse(raw.exists())


class ExternalRawShardTests(PreparedToolsFixture):
    def test_owned_resume_source_reset_and_path_mismatch_preserve_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);work=root/'output/enwiktionary/20261001.shards';raw=root/'other/enwiktionary/20261001.raw-shards'
            expected={'source':'first'}
            b.prepare_shard_workspace(work,expected,123,raw)
            cache=work/'input';cache.mkdir();(cache/'keep').write_text('authenticated input')
            native=work/'expander';native.mkdir();(native/'worker').write_text('old native')
            shard=raw/'00000000';shard.mkdir();(shard/'blob').write_text('raw')
            inode=(cache/'keep').stat().st_ino
            self.assertEqual(b.prepare_shard_workspace(work,expected,None,raw),123)
            self.assertTrue((shard/'blob').exists())
            for different in (None,root/'third/enwiktionary/20261001.raw-shards'):
                with self.assertRaisesRegex(ValueError,'location differs'):
                    b.prepare_shard_workspace(work,expected,123,different)
                self.assertTrue((shard/'blob').exists())
            self.assertEqual(b.prepare_shard_workspace(work,{'source':'second'},456,raw),456)
            self.assertEqual((cache/'keep').stat().st_ino,inode)
            self.assertFalse(shard.exists());self.assertFalse(native.exists())
            self.assertEqual(json.loads((work/'state.json').read_text())['raw_shards_path'],str(raw))
            self.assertTrue((raw/b.RAW_SHARD_OWNER).is_file())

    def test_foreign_symlink_overlapping_and_nested_paths_are_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);work=root/'output/enwiktionary/20261001.shards'
            foreign=root/'foreign';foreign.mkdir();sentinel=foreign/'keep';sentinel.write_text('untouched')
            with self.assertRaisesRegex(ValueError,'Unowned'):
                b.prepare_shard_workspace(work,{'source':'x'},123,foreign)
            self.assertEqual(sentinel.read_text(),'untouched');self.assertFalse((work/'state.json').exists())
            owned=root/'owned';b.external_raw_shards(work,owned,create=True)
            with self.assertRaisesRegex(ValueError,'owner differs'):
                b.external_raw_shards(root/'different.shards',owned,create=True)
            alias=root/'alias';alias.symlink_to(owned,target_is_directory=True)
            with self.assertRaisesRegex(ValueError,'Unsafe'):
                b.external_raw_shards(work,alias,create=True)
            for overlap in (work/'input',work.parent,work.with_name('20261001')/'raw',work.with_name('20261001.building')/'raw'):
                with self.assertRaisesRegex(ValueError,'overlap'):
                    b.external_raw_shards(work,overlap,create=True)
            with self.assertRaisesRegex(ValueError,'nested'):
                b.external_raw_shards(root/'another.shards',owned/'nested',create=True)
            marker=owned/b.RAW_SHARD_OWNER;marker.unlink();marker.symlink_to(sentinel)
            with self.assertRaisesRegex(ValueError,'marker'):
                b.external_raw_shards(work,owned,create=True)
            self.assertEqual(sentinel.read_text(),'untouched')

    def test_live_partial_and_changed_marker_block_reset_and_cleanup(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);work=root/'work';raw=root/'raw'
            b.prepare_shard_workspace(work,{'source':'first'},123,raw)
            cache=work/'input';cache.mkdir();(cache/'keep').write_text('input')
            partial=raw/f'.00000000.part-{os.getpid()}';partial.mkdir();(partial/'keep').write_text('active')
            for action in (lambda:b.prepare_shard_workspace(work,{'source':'second'},456,raw),
                           lambda:b.cleanup_shard_workspace(work)):
                with self.assertRaisesRegex(ValueError,'PID still exists'):action()
                self.assertEqual((partial/'keep').read_text(),'active')
                self.assertTrue((cache/'keep').exists())
            (partial/'keep').unlink();partial.rmdir()
            marker=raw/b.RAW_SHARD_OWNER;record=marker.read_text()
            marker.write_text(json.dumps({'workspace':'foreign'}))
            with self.assertRaisesRegex(ValueError,'owner differs'):b.cleanup_shard_workspace(work)
            self.assertTrue((cache/'keep').exists())
            marker.write_text(record);b.cleanup_shard_workspace(work)
            self.assertFalse(work.exists());self.assertFalse(raw.exists())

    def test_external_merge_and_verification_failures_resume_without_repack(self):
        for failure in ('merge','verify'):
            with self.subTest(failure=failure),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);folder=root/'testwiktionary/20260901';write_namespace_fixture(folder)
                name='testwiktionary-20260901-pages-meta-current.xml.bz2'
                data=bz2.compress(b'<mediawiki><page>word</page><page>second</page></mediawiki>')
                (folder/name).write_bytes(data)
                item=dict(wiki='testwiktionary',date='20260901',name=name,
                          url='https://dumps.wikimedia.org/testwiktionary/20260901/'+name,
                          size=len(data),sha1=hashlib.sha1(data).hexdigest())
                work=root/'output/testwiktionary/20260901.shards';raw=root/'other/testwiktionary/20260901.raw-shards'
                staging=root/'output/testwiktionary/20260901.building';merges=[];failed=False;builds=[]
                def run(command):
                    nonlocal failed
                    if 'build-dictionary' in command:
                        dest=Path(tool_arguments(command)[1]);self.assertEqual(dest,work/'expander')
                        exp=dest/'.bundle-expander';exp.mkdir(parents=True);(dest/'.incomplete').write_text('expander ready')
                        (exp/'page-index.tsv').write_text('0\n1\n');(exp/'dict-bundle-expander').write_text('worker');write_namespace_fixture(exp)
                    elif blob_command(command,'build-blobs'):
                        dest=Path(tool_arguments(command)[1]);self.assertEqual(dest,raw)
                        dest.mkdir(parents=True,exist_ok=True);write_coverage(dest,command);builds.append(command)
                    elif blob_command(command,'merge-blobs'):
                        merges.append(command);self.assertEqual(Path(tool_arguments(command)[0]),staging)
                        shards=[Path(x) for x in tool_arguments(command)[1:]]
                        self.assertTrue(all(x.parent==raw for x in shards))
                        self.assertTrue((work/'input/.complete.json').exists());self.assertTrue(raw.exists())
                        if failure=='merge' and not failed:failed=True;raise subprocess.CalledProcessError(1,command)
                        staging.mkdir();(staging/'fallback-pages.jsonl').write_text('')
                        write_namespace_coverage(staging,sum(json.loads((x/'page-coverage.json').read_text())['pages_seen'] for x in shards))
                    elif blob_command(command,'verify-blobs') and Path(command[-1])==staging:
                        self.assertTrue(raw.exists())
                        if failure=='verify' and not failed:failed=True;raise subprocess.CalledProcessError(1,command)
                with patch.object(b,'PROJECT',root),patch.object(b,'SHARD_PAGES',1), \
                     patch.object(b,'source_fingerprint',return_value='source'),patch.object(b.time,'time',return_value=123), \
                     patch.object(b,'run_checked',side_effect=run),patch.object(b,'stage_seekable_dump',wraps=b.stage_seekable_dump) as repack:
                    with self.assertRaises(subprocess.CalledProcessError):
                        b.build([item],root,root/'output','zig',1,raw_shard_root=root/'other')
                    self.assertTrue((raw/'00000000/.verified').exists());self.assertTrue((work/'input/.complete.json').exists())
                    b.build([item],root,root/'output','zig',1,raw_shard_root=root/'other')
                    self.assertEqual(repack.call_count,1);self.assertEqual(len(builds),1);self.assertEqual(len(merges),2)
                    self.assertFalse(raw.exists());self.assertFalse(work.exists())
                    self.assertTrue((root/'output/testwiktionary/20260901/complete.json').is_file())

    def test_cli_routes_optional_root_to_build_and_disk_watchdog(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);raw=root/'other';output=root/'output'
            argv=['build_wiktionaries.py','--resource-mode=watchdog','--output',str(output),'--raw-shard-root',str(raw),'--compress-shards']
            with patch.object(b,'PROJECT',root),patch.object(sys,'argv',argv), \
                 patch.object(limits,'inside_watchdog',return_value=False),patch.object(limits,'supervise_watchdog',return_value=0) as watchdog:
                with self.assertRaises(SystemExit) as done:b.cli()
                self.assertEqual(done.exception.code,0)
            watchdog.assert_called_once_with(wall_seconds=7200,disk_paths=(root/'.tmp',output,raw))
            write_test_manifest(root,{'files':[dict(wiki='testwiktionary',date='20261001',name='test.xml.bz2',
                url='https://dumps.wikimedia.org/testwiktionary/20261001/test.xml.bz2',size=1,sha1='a'*40)]})
            with patch.object(sys,'argv',argv+['--downloads',str(root),'--threads','1','--jobs','1']), \
                 patch.object(b,'safe_worker_budget',return_value=1),patch.object(b,'build_groups',return_value=[]) as groups:
                b.main()
            self.assertEqual(groups.call_args.kwargs['raw_shard_root'],raw)
            self.assertTrue(groups.call_args.kwargs['compress_shards'])
            with patch.object(b,'safe_worker_budget',return_value=1),patch.object(b,'build',return_value='built') as build:
                b.build_groups({('testwiktionary','20261001'):['item']},root,output,'zig',1,1,raw_shard_root=raw,compress_shards=True)
            self.assertEqual(build.call_args.kwargs['raw_shard_root'],raw)
            self.assertTrue(build.call_args.kwargs['compress_shards'])



class WatchdogMemoryLimitCliTests(unittest.TestCase):
    def test_memory_flag_bounds_and_watchdog_mode_are_strict(self):
        self.assertIsNone(b.watchdog_memory_limit_bytes(None, 'watchdog'))
        self.assertIsNone(b.watchdog_memory_limit_bytes(None, 'cgroup'))
        for mib in [1, 4096, 8192]:
            self.assertEqual(mib*1024**2, b.watchdog_memory_limit_bytes(mib, 'watchdog'))
        for mib in [True, False, 0, -1, 8193, 4096.0, '4096']:
            with self.subTest(mib=mib), self.assertRaises(ValueError):
                b.watchdog_memory_limit_bytes(mib, 'watchdog')
        with self.assertRaises(ValueError):
            b.watchdog_memory_limit_bytes(4096, 'cgroup')

    def test_outer_watchdog_forwards_exact_selected_bytes_and_keeps_unlimited_lock(self):
        for mib in [4096, 8192]:
            with self.subTest(mib=mib), tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp); output=root/'output'
                def supervised(**kwargs):
                    self.assertEqual(dict(wall_seconds=7200,
                        disk_paths=(root/'.tmp',output),
                        address_space_limit_bytes='unlimited',
                        memory_limit_bytes=mib*1024**2), kwargs)
                    with self.assertRaises(limits.ContainmentUnavailable):
                        b.acquire_build_resource_lock(root/'.tmp/build-resources.lock')
                    return 0
                argv=['build_wiktionaries.py','--resource-mode=watchdog',
                      '--watchdog-address-space=unlimited',
                      '--watchdog-memory-limit-mib='+str(mib),
                      '--output',str(output)]
                with patch.object(b,'PROJECT',root),patch.object(sys,'argv',argv), \
                     patch.object(limits,'inside_watchdog',return_value=False), \
                     patch.object(limits,'supervise_watchdog',side_effect=supervised) as watchdog, \
                     patch.object(limits,'supervise') as cgroup,patch.object(b,'main') as main:
                    with self.assertRaises(SystemExit) as result:b.cli()
                    self.assertEqual(0,result.exception.code)
                watchdog.assert_called_once(); cgroup.assert_not_called(); main.assert_not_called()

    def test_unlimited_child_requires_authenticated_selected_memory_before_main(self):
        argv=['build_wiktionaries.py','--resource-mode=watchdog',
              '--watchdog-address-space=unlimited','--watchdog-memory-limit-mib=4096']
        for actual in [4*1024**3,8*1024**3]:
            with self.subTest(actual=actual),patch.object(sys,'argv',argv), \
                 patch.object(limits,'inside_watchdog',return_value=True), \
                 patch.object(limits,'watchdog_physical_memory_limit_bytes',return_value=actual), \
                 patch.object(b,'main') as main,patch.object(limits,'supervise_watchdog') as watchdog:
                if actual==4*1024**3:
                    b.cli();main.assert_called_once()
                else:
                    with self.assertRaisesRegex(SystemExit, '^Authenticated watchdog memory budget differs from requested limit$'):b.cli()
                    main.assert_not_called()
                watchdog.assert_not_called()

    def test_both_parsers_refuse_invalid_memory_or_nonwatchdog_before_work(self):
        for options in [['--resource-mode=watchdog','--watchdog-memory-limit-mib=0'],
                        ['--resource-mode=watchdog','--watchdog-memory-limit-mib=8193'],
                        ['--resource-mode=cgroup','--watchdog-memory-limit-mib=4096']]:
            for entry in [b.cli,b.main]:
                with self.subTest(options=options,entry=entry.__name__), \
                     patch.object(sys,'argv',['build_wiktionaries.py',*options]), \
                     patch.object(limits,'supervise_watchdog') as watchdog, \
                     patch.object(limits,'supervise') as cgroup, \
                     patch.object(b,'safe_worker_budget') as budget, \
                     contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises((ValueError,SystemExit,limits.ContainmentUnavailable)):entry()
                    watchdog.assert_not_called();cgroup.assert_not_called();budget.assert_not_called()

    def test_main_parser_accepts_selected_memory_without_leaking_resource_kwargs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'manifest.json').write_text('{"files": []}')
            argv=['build_wiktionaries.py','--resource-mode=watchdog',
                  '--watchdog-address-space=unlimited','--watchdog-memory-limit-mib=4096',
                  '--downloads',str(root),'--threads=1','--jobs=1']
            with patch.object(sys,'argv',argv),patch.object(b,'safe_worker_budget',return_value=1), \
                 patch.object(b,'select_manifest_files',return_value=[]), \
                 patch.object(b,'resolve_edition_snapshot_options',return_value={}), \
                 patch.object(b,'build_groups',return_value=[]) as groups:
                b.main()
            groups.assert_called_once()
            self.assertNotIn('memory_limit_bytes',groups.call_args.kwargs)
            self.assertNotIn('watchdog_memory_limit_mib',groups.call_args.kwargs)


class WatchdogAddressSpaceCliTests(unittest.TestCase):
    def test_unlimited_parent_route_preserves_lock_and_resident_envelope(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);output=root/'output';raw=root/'raw'
            def supervised(**kwargs):
                self.assertEqual(kwargs,dict(wall_seconds=123,disk_paths=(root/'.tmp',output,raw),address_space_limit_bytes='unlimited'))
                with self.assertRaises(limits.ContainmentUnavailable):
                    b.acquire_build_resource_lock(root/'.tmp/build-resources.lock')
                return 0
            argv=['build_wiktionaries.py','--resource-mode=watchdog','--watchdog-address-space=unlimited',
                  '--cpu-admission=affinity','--threads=4','--jobs=1','--expansion-workers=4',
                  '--build-timeout-seconds=123','--output',str(output),'--raw-shard-root',str(raw)]
            with patch.object(b,'PROJECT',root),patch.object(sys,'argv',argv), \
                 patch.object(limits,'inside_watchdog',return_value=False), \
                 patch.object(limits,'supervise_watchdog',side_effect=supervised) as watchdog, \
                 patch.object(limits,'supervise') as cgroup,patch.object(b,'main') as main:
                with self.assertRaises(SystemExit) as result:b.cli()
                self.assertEqual(result.exception.code,0)
            watchdog.assert_called_once();cgroup.assert_not_called();main.assert_not_called()

    def test_omitted_and_explicit_default_preserve_existing_watchdog_call(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            for option in ([],['--watchdog-address-space=default']):
                with self.subTest(option=option),patch.object(b,'PROJECT',root), \
                     patch.object(sys,'argv',['build_wiktionaries.py','--resource-mode=watchdog',*option]), \
                     patch.object(limits,'inside_watchdog',return_value=False), \
                     patch.object(limits,'supervise_watchdog',return_value=0) as watchdog:
                    with self.assertRaises(SystemExit) as result:b.cli()
                    self.assertEqual(result.exception.code,0)
                watchdog.assert_called_once_with(wall_seconds=7200,disk_paths=(root/'.tmp',root/'data/dictionaries'))

    def test_verified_child_accepts_flag_without_resupervision(self):
        with patch.object(sys,'argv',['build_wiktionaries.py','--resource-mode=watchdog','--watchdog-address-space=unlimited']), \
             patch.object(limits,'inside_watchdog',return_value=True),patch.object(b,'main') as main, \
             patch.object(limits,'supervise_watchdog') as watchdog,patch.object(limits,'supervise') as cgroup:
            b.cli()
        main.assert_called_once();watchdog.assert_not_called();cgroup.assert_not_called()

    def test_main_parser_accepts_unlimited_and_keeps_build_options_unchanged(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'manifest.json').write_text('{"files": []}')
            argv=['build_wiktionaries.py','--resource-mode=watchdog','--watchdog-address-space=unlimited',
                  '--downloads',str(root),'--threads=1','--jobs=1']
            with patch.object(sys,'argv',argv),patch.object(b,'safe_worker_budget',return_value=1), \
                 patch.object(b,'select_manifest_files',return_value=[]), \
                 patch.object(b,'resolve_edition_snapshot_options',return_value={}), \
                 patch.object(b,'build_groups',return_value=[]) as groups:
                b.main()
            groups.assert_called_once()
            self.assertNotIn('address_space_limit_bytes',groups.call_args.kwargs)
            self.assertNotIn('watchdog_address_space',groups.call_args.kwargs)

    def test_unlimited_requires_watchdog_in_both_parsers_before_work(self):
        for mode in ([],['--resource-mode=cgroup']):
            for entrypoint in (b.cli,b.main):
                with self.subTest(mode=mode,entrypoint=entrypoint.__name__), \
                     patch.object(sys,'argv',['build_wiktionaries.py','--watchdog-address-space=unlimited',*mode]), \
                     patch.object(limits,'supervise_watchdog') as watchdog,patch.object(limits,'supervise') as cgroup, \
                     patch.object(b,'safe_worker_budget') as budget,contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaisesRegex(SystemExit,'watchdog mode|2'):entrypoint()
                    watchdog.assert_not_called();cgroup.assert_not_called();budget.assert_not_called()

    def test_unsupported_address_space_value_is_rejected_in_both_parsers(self):
        for entrypoint in (b.cli,b.main):
            with self.subTest(entrypoint=entrypoint.__name__), \
                 patch.object(sys,'argv',['build_wiktionaries.py','--resource-mode=watchdog','--watchdog-address-space=8589934592']), \
                 patch.object(limits,'supervise_watchdog') as watchdog,patch.object(b,'safe_worker_budget') as budget, \
                 contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as result:entrypoint()
                self.assertEqual(result.exception.code,2)
                watchdog.assert_not_called();budget.assert_not_called()


class SiteMainPageCoverageTests(unittest.TestCase):
    def fixture(self, root):
        site={'schema':'wikidict.site-info.v2','wiki':'aawiktionary','date':'20261001',
              'namespace_registry_sha256':'a'*64,
              'query':{'general':{'wikiid':'aawiktionary','mainpage':'Main Page'}}}
        path=root/'site.json';path.write_text(json.dumps(site))
        row=dict(id=0,name='',kind='language',input_rows=2,compile_only_rows=0,
                 source_unavailable_rows=0,site_metadata_rows=2,dispatched_rows=0,
                 expanded_pages=0,fallback_pages=0,duplicate_rows=0,alias_pages=0)
        report=dict(version=1,registry_sha256='a'*64,site_info_sha256=b.sha256_file(path),namespaces=[row])
        return path,report
    def save(self,root,report):
        (root/'namespace-coverage.json').write_text(json.dumps(report))
    def test_mainpage_and_redirect_rows_conserved_without_payloads(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);site,report=self.fixture(root);self.save(root,report)
            totals=b.validate_namespace_coverage(root,2,fallback_counts={},site_info_snapshot=site)
            self.assertEqual((2,2,0,0),(totals['input_rows'],totals['site_metadata_rows'],totals['dispatched_rows'],totals['fallback_pages']))
    def test_site_metadata_requires_pinned_unchanged_authority(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);site,report=self.fixture(root);self.save(root,report)
            with self.assertRaisesRegex(ValueError,'pinned site info'):b.validate_namespace_coverage(root,2)
            site.write_text(site.read_text().replace('Main Page','Other'))
            with self.assertRaisesRegex(ValueError,'authority differs'):b.validate_namespace_coverage(root,2,site_info_snapshot=site)
    def test_site_metadata_cannot_hide_missing_input_or_other_namespace(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);site,report=self.fixture(root)
            report['namespaces'][0]['input_rows']=3;self.save(root,report)
            with self.assertRaisesRegex(ValueError,'Incomplete'):b.validate_namespace_coverage(root,3,site_info_snapshot=site)
            report['namespaces'][0].update(id=114,name='Citations',kind='citations',input_rows=2);self.save(root,report)
            with self.assertRaisesRegex(ValueError,'site metadata coverage disposition'):b.validate_namespace_coverage(root,2,site_info_snapshot=site)
    def test_ordinary_heading_failure_stays_in_fallback_partition(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);site,report=self.fixture(root)
            row=report['namespaces'][0];row.update(input_rows=3,dispatched_rows=1,fallback_pages=1)
            self.save(root,report)
            totals=b.validate_namespace_coverage(root,3,fallback_counts={0:1},site_info_snapshot=site)
            self.assertEqual(1,totals['fallback_pages'])
            with self.assertRaisesRegex(ValueError,'fallback counts differ'):b.validate_namespace_coverage(root,3,fallback_counts={},site_info_snapshot=site)

class IndependentExecutionBuilderTests(unittest.TestCase):
    @staticmethod
    def identity(path):
        st=path.stat()
        return dict(path=str(path),device=st.st_dev,inode=st.st_ino,uid=st.st_uid,mode=st.st_mode & 0o7777)

    @contextlib.contextmanager
    def fixture(self, *, canonical=False):
        with tempfile.TemporaryDirectory() as temporary:
            workspace=Path(temporary)/'workspace';source=workspace if canonical else workspace/'.tmp/producer'
            (source/'tools').mkdir(parents=True)
            downloads=workspace/'data/downloads';downloads.mkdir(parents=True)
            (downloads/'manifest.json').write_bytes(b'original shared manifest is not selected')
            root=workspace/'data/corpus-executions/owned';root.mkdir(parents=True,mode=0o700)
            for role in ('state','output','raw','cache'):(root/role).mkdir(mode=0o700)
            attempt=root/'state/attempt';attempt.mkdir()
            item=dict(wiki='enwiktionary',date='20261001',name='enwiktionary-20261001-pages-meta-current.xml.bz2',
                size=1,sha1='a'*40,url='https://dumps.wikimedia.org/enwiktionary/20261001/enwiktionary-20261001-pages-meta-current.xml.bz2')
            manifest=root/'manifest.json';manifest.write_text(json.dumps(dict(requested_editions=['enwiktionary'],files=[item])))
            manifest.chmod(0o400)
            spec={name:self.identity(root if name=='root' else root/name) for name in ('root','state','output','raw','cache')}
            argv=['build_wiktionaries.py','--resource-mode','watchdog','--cpu-admission','affinity','--threads','1','--jobs','1',
                *([] if canonical else ['--workspace-root-spec',json.dumps(self.identity(workspace))]), '--execution-root-spec',json.dumps(spec),
                '--artifact-root-spec',json.dumps(spec['root']), '--downloads',str(downloads),'--output',str(root/'output'),
                '--raw-shard-root',str(root/'raw'),'--extraction-cache-root',str(root/'cache'),
                '--input-manifest',str(manifest),'--input-manifest-sha256',hashlib.sha256(manifest.read_bytes()).hexdigest(),
                '--wikis','enwiktionary']
            import build_artifact_root as artifacts
            with patch.object(b,'PROJECT',source),patch.object(b,'__file__',str(source/'tools/build_wiktionaries.py')), \
                 patch.object(sys,'argv',argv),contextlib.chdir(attempt), \
                 patch.object(artifacts,'_ACTIVE',None),patch.object(artifacts,'_ACTIVE_PATHS',()):
                yield workspace,source,root,argv,item

    def test_canonical_cli_keeps_owned_lock_manifest_and_declared_fingerprint_inputs(self):
        with self.fixture(canonical=True) as (workspace, source, root, argv, item):
            (source/'build.zig').write_text('declared build input')
            (source/'src').mkdir();(source/'src/core.zig').write_text('declared core input')
            (source/'tools/helper.py').write_text('declared helper input')
            before=b.source_fingerprint()
            original=(workspace/'data/downloads/manifest.json').read_bytes()
            private=root/'build-resources.lock'
            def supervised(**options):
                self.assertTrue(private.is_file())
                with self.assertRaises(limits.ContainmentUnavailable):b.acquire_build_resource_lock(private)
                self.assertEqual(options['disk_paths'],(workspace/'.tmp',root/'output',root/'raw',root/'cache'))
                return 0
            with patch.object(limits,'inside_watchdog',return_value=False), \
                 patch.object(limits,'supervise_watchdog',side_effect=supervised) as supervisor:
                with self.assertRaises(SystemExit) as done:b.cli()
                self.assertEqual(done.exception.code,0);supervisor.assert_called_once()
            self.assertFalse((workspace/'.tmp/build-resources.lock').exists())
            with patch.object(b,'safe_worker_budget',return_value=1), \
                 patch.object(b,'validate_affinity_workers'), \
                 patch.object(b,'resolve_edition_snapshot_options',return_value={}), \
                 patch.object(b,'build_groups',return_value=[]) as groups:
                b.main()
            self.assertEqual(groups.call_args.args[0],{('enwiktionary','20261001'):[item]})
            self.assertEqual(groups.call_args.kwargs['extraction_cache_root'],root/'cache')
            self.assertEqual((workspace/'data/downloads/manifest.json').read_bytes(),original)
            (root/'output/generated.py').write_text('generated output, not a producer input')
            self.assertEqual(before,b.source_fingerprint())
            (source/'src/core.zig').write_text('changed core input')
            self.assertNotEqual(before,b.source_fingerprint())
            with patch.object(b,'__file__',str(workspace/'.tmp/foreign/tools/build_wiktionaries.py')), \
                 patch.object(limits,'supervise_watchdog') as supervisor:
                with self.assertRaisesRegex(SystemExit,'bound producer'):b.cli()
                supervisor.assert_not_called()

    def test_existing_watchdog_owns_private_lock_while_global_build_remains_held(self):
        for fail in (False,True):
            with self.subTest(fail=fail),self.fixture() as (workspace,source,root,argv,item):
                global_lock=workspace/'.tmp/build-resources.lock';private=root/'build-resources.lock'
                manifest=workspace/'data/downloads/manifest.json';before=manifest.read_bytes()
                failure=RuntimeError('original watchdog error');calls=[]
                def supervise(**options):
                    calls.append(options)
                    with self.assertRaises(limits.ContainmentUnavailable):b.acquire_build_resource_lock(private)
                    with self.assertRaises(limits.ContainmentUnavailable):b.acquire_build_resource_lock(global_lock)
                    self.assertEqual(options['disk_paths'],(workspace/'.tmp',root/'output',root/'raw',root/'cache'))
                    if fail:raise failure
                    return 0
                with b.acquire_build_resource_lock(global_lock), \
                     patch.object(limits,'inside_watchdog',return_value=False), \
                     patch.object(limits,'supervise_watchdog',side_effect=supervise),patch.object(b,'main') as main:
                    if fail:
                        with self.assertRaises(RuntimeError) as caught:b.cli()
                        self.assertIs(caught.exception,failure)
                    else:
                        with self.assertRaises(SystemExit) as done:b.cli()
                        self.assertEqual(done.exception.code,0)
                    main.assert_not_called()
                    with b.acquire_build_resource_lock(private):pass
                self.assertEqual(len(calls),1)
                self.assertEqual(before,manifest.read_bytes())
                self.assertEqual(list((root/'output').iterdir()),[])
                self.assertFalse((source/'.tmp/build-resources.lock').exists())

    def test_invalid_execution_and_default_reserved_destination_refuse_before_supervisor(self):
        for mutation in ('cache-outside','jobs','wiki','manifest-hash','no-artifact-root','no-scope','cwd-outside'):
            with self.subTest(mutation=mutation),self.fixture() as (workspace,source,root,argv,item):
                if mutation=='cache-outside':argv[argv.index('--extraction-cache-root')+1]=str(workspace/'data/downloads')
                elif mutation=='jobs':argv[argv.index('--jobs')+1]='2'
                elif mutation=='wiki':argv[-1]='frwiktionary'
                elif mutation=='manifest-hash':argv[argv.index('--input-manifest-sha256')+1]='0'*64
                elif mutation=='no-artifact-root':
                    index=argv.index('--artifact-root-spec');del argv[index:index+2]
                elif mutation=='no-scope':
                    index=argv.index('--execution-root-spec');del argv[index:index+2]
                elif mutation=='cwd-outside':os.chdir(workspace)
                with patch.object(limits,'supervise_watchdog') as supervisor,patch.object(b,'main') as main:
                    with self.assertRaises(SystemExit):b.cli()
                    supervisor.assert_not_called();main.assert_not_called()
                self.assertFalse((root/'build-resources.lock').exists())
                self.assertFalse((workspace/'.tmp/build-resources.lock').exists())

    def test_scope_rechecks_manifest_and_lock_identity_after_original_supervisor(self):
        for mutation in ('manifest','lock','state'):
            with self.subTest(mutation=mutation),self.fixture() as (workspace,source,root,argv,item):
                def supervise(**options):
                    if mutation=='manifest':
                        path=root/'manifest.json';path.chmod(0o600);path.write_text('{}');path.chmod(0o400)
                    elif mutation=='lock':
                        path=root/'build-resources.lock';path.rename(root/'original.lock');path.touch()
                    else:
                        (root/'state').rename(root/'old-state');(root/'state').mkdir(mode=0o700)
                    return 0
                with patch.object(limits,'inside_watchdog',return_value=False), \
                     patch.object(limits,'supervise_watchdog',side_effect=supervise):
                    with self.assertRaises(ValueError):b.cli()

    def test_authenticated_watchdog_child_still_requires_its_parent_to_own_the_scope_lock(self):
        with self.fixture() as (workspace,source,root,argv,item):
            with patch.object(limits,'inside_watchdog',return_value=True),patch.object(b,'main') as main:
                with self.assertRaises(FileNotFoundError):b.cli()
                main.assert_not_called()
                with b.acquire_build_resource_lock(root/'build-resources.lock'):
                    with patch.object(os,'getppid',return_value=os.getpid()+10000000), \
                         self.assertRaisesRegex(ValueError,'does not own the execution lock'):
                        b.cli()
                    main.assert_not_called()
                    # Real flock ownership, with only the authenticated parent identity modeled.
                    with patch.object(os,'getppid',return_value=os.getpid()):b.cli()
                    main.assert_called_once_with()

    def test_normal_main_uses_exact_immutable_manifest_and_original_downloads(self):
        with self.fixture() as (workspace,source,root,argv,item):
            original=workspace/'data/downloads/manifest.json';before=(original.stat().st_ino,original.read_bytes())
            seen=[]
            def build_groups(groups,downloads,output,*args,**kwargs):
                seen.append((groups,downloads,output,kwargs))
                return []
            with patch.object(b,'safe_worker_budget',return_value=4), \
                 patch.object(b,'validate_affinity_workers'), \
                 patch.object(b,'resolve_edition_snapshot_options',return_value={}), \
                 patch.object(b,'build_groups',side_effect=build_groups), \
                 patch.object(b,'load_input_manifest',wraps=b.load_input_manifest) as loaded:
                b.main()
                loaded.assert_called_once_with(root/'manifest.json',argv[argv.index('--input-manifest-sha256')+1],workspace/'data/downloads')
            self.assertEqual(len(seen),1)
            self.assertEqual(seen[0][0],{('enwiktionary','20261001'):[item]})
            self.assertEqual(seen[0][1:3],(workspace/'data/downloads',root/'output'))
            self.assertEqual(seen[0][3]['extraction_cache_root'],root/'cache')
            self.assertEqual(before,(original.stat().st_ino,original.read_bytes()))
            self.assertEqual(list((root/'output').iterdir()),[])




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

    def _check_route(self, pages, attempts=1, llvm_workers=None, expansion_workers=None):
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
                self.assertEqual(command[command.index('--llvm-workers')+1],str(llvm_workers or 1))
                self.assertEqual(command[command.index('--parse-workers')+1],'1')
                self.assertEqual(command[command.index('--page-workers')+1],str(expansion_workers or 1))
                actual=Path(tool_arguments(command)[0])
                calls.append(('one-shot',actual))
                self.assertEqual(actual,dump)
                self.assertTrue(actual.is_file())
                raise self.RouteReached()
            def stop_sharded(actual, staging, actual_workspace, *args, **kwargs):
                calls.append(('sharded',Path(actual)))
                self.assertEqual(Path(actual),dump)
                self.assertEqual(actual_workspace,workspace)
                self.assertEqual(kwargs.get('llvm_workers'),llvm_workers)
                self.assertEqual(args[5],expansion_workers)
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
                        b.build([item],root,root/'output',str(tool),1, **({'llvm_workers':llvm_workers} if llvm_workers is not None else {}), **({'expansion_workers':expansion_workers} if expansion_workers is not None else {}))
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

    def test_explicit_page_workers_forward_small_and_sharded_without_widening_compiler(self):
        self._check_route(1)
        for pages in (1,100_001):
            with self.subTest(pages=pages):self._check_route(pages,llvm_workers=2,expansion_workers=4)

    def test_explicit_llvm_workers_preserve_small_and_sharded_routes(self):
        for pages in (1,100_001):
            with self.subTest(pages=pages):self._check_route(pages,llvm_workers=2)

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


class FileMetadataV2ReplayReuseTest(unittest.TestCase):
    def setUp(self):
        import test_prepare_file_metadata_v2 as fixture_module
        self.fixture=fixture_module.CaptureReplayTest()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.manifest=self.fixture.capture()
        self.path=self.fixture.args.output/'file-metadata.tsv'
        self.helper=fixture_module.v2
        b._FILE_METADATA_V2_REPLAYS.clear()
        self.addCleanup(b._FILE_METADATA_V2_REPLAYS.clear)

    def validate(self,path=None,edition='arwiktionary',date='20261001'):
        return b.validated_auxiliary_capture('file-metadata',path or self.path,edition,date)

    def test_exact_repeat_and_copied_capture_reuse_do_not_share_mutable_results(self):
        import shutil
        with patch.object(self.helper,'validate_snapshot',wraps=self.helper.validate_snapshot) as replay:
            record,artifacts=self.validate()
            expected=json.loads(json.dumps(record))
            record['dependency_sha256'].clear();artifacts.clear()
            self.assertEqual(self.validate()[0],expected)
            copied=self.fixture.root/'copied';shutil.copytree(self.path.parent,copied)
            self.assertEqual(self.validate(copied/self.path.name)[0],expected)
            self.assertEqual(replay.call_count,1)

    def test_cache_hit_preserves_edition_and_date_rejection(self):
        self.validate()
        for edition,date in [('enwiktionary','20261001'),('arwiktionary','20261002')]:
            with self.subTest(edition=edition,date=date),self.assertRaisesRegex(ValueError,'edition/date'):
                self.validate(edition=edition,date=date)

    def test_same_size_same_mtime_mutations_of_all_evidence_classes_are_rejected(self):
        self.validate()
        names=['file-metadata.tsv',self.helper.NAMESPACE,self.helper.EVIDENCE,self.helper.COMPLETE,
               next(self.path.parent.glob('*.raw.json')).name,
               next(self.path.parent.glob('*.titles')).name]
        for name in names:
            with self.subTest(name=name):
                path=self.path.with_name(name);original=path.read_bytes();stat=path.stat()
                replacement=bytes([original[0]^1])+original[1:]
                try:
                    path.write_bytes(replacement);os.utime(path,ns=(stat.st_atime_ns,stat.st_mtime_ns))
                    with self.assertRaises(ValueError):self.validate()
                finally:path.write_bytes(original);os.utime(path,ns=(stat.st_atime_ns,stat.st_mtime_ns))
                self.validate()

    def test_rehashed_semantic_tamper_requires_replay_and_never_enters_cache(self):
        self.validate()
        raw=self.path.read_bytes().replace(b'\tAUDIO\t',b'\tVIDEO\t')
        self.path.write_bytes(raw)
        index=self.helper.decode(self.path.with_name(self.helper.EVIDENCE).read_bytes())
        self.manifest.update(output_bytes=len(raw),output_sha256=self.helper.digest(raw))
        self.fixture.rewrite_index_and_manifest(self.manifest,index)
        with patch.object(self.helper,'validate_snapshot',wraps=self.helper.validate_snapshot) as replay:
            for _ in range(2):
                with self.assertRaisesRegex(ValueError,'TSV differs'):self.validate()
            self.assertEqual(replay.call_count,2)

    def test_missing_extra_and_symlink_artifacts_do_not_use_prior_success(self):
        self.validate()
        raw=next(self.path.parent.glob('*.raw.json'));saved=raw.read_bytes()
        raw.unlink()
        with self.assertRaises(ValueError):self.validate()
        raw.write_bytes(saved)
        extra=self.path.with_name('file-metadata.unrecorded.json');extra.write_text('{}')
        with self.assertRaises(ValueError):self.validate()
        extra.unlink()
        target=self.fixture.root/'outside-raw.json';target.write_bytes(saved);raw.unlink();raw.symlink_to(target.resolve())
        with self.assertRaises(ValueError):self.validate()

    def test_producer_change_does_not_reuse_proof(self):
        expected=self.validate()
        changed=self.helper.producer();changed['generator_sha256']='0'*64
        with patch.object(self.helper,'producer',return_value=changed):
            with patch.object(self.helper,'validate_snapshot',side_effect=ValueError('fresh replay rejected')) as replay:
                with self.assertRaisesRegex(ValueError,'fresh replay rejected'):self.validate()
                self.assertEqual(replay.call_count,1)
            with patch.object(self.helper,'validate_snapshot',wraps=self.helper.validate_snapshot) as replay:
                self.assertEqual(self.validate(),expected)
                self.assertEqual(replay.call_count,1)
                self.assertEqual(self.validate(),expected)
                self.assertEqual(replay.call_count,1)



    def resolver_fixture(self):
        # Real file-metadata collector/replay and namespace projector; all source
        # bytes are small synthetic fixtures, with no payload validation mocked.
        import namespace_registry_snapshot as namespace_projection
        project=self.fixture.root.resolve();wiki,date=self.manifest['wiki'],self.manifest['date']
        item=dict(wiki=wiki,date=date,name=wiki+'-'+date+'-pages-meta-current.xml.bz2',
                  url='https://dumps.wikimedia.org/synthetic-local-fixture',size=1,sha1='0'*40)
        namespaces={str(i):dict(id=i,name=name,canonical=canonical,case='case-sensitive',
                    content=i==0,subpages=i==10,defaultcontentmodel='wikitext')
                    for i,name,canonical in ((-2,'ميديا','Media'),(0,'',''),(6,'ملف','File'),
                                             (10,'قالب','Template'),(14,'تصنيف','Category'))}
        inventory=[dict(id=row['id'],name=row['name'],case=row['case']) for row in namespaces.values()]
        query=dict(general=dict(wikiid=wiki,lang='ar',server='//ar.wiktionary.org'),
                   namespaces=namespaces,namespacealiases=[])
        namespace_raw,_=namespace_projection.render(wiki,date,query,inventory)
        self.fixture.namespace.write_bytes(namespace_raw)
        self.fixture.args.output=self.fixture.root/'resolver-capture'
        self.manifest=self.fixture.capture();self.path=self.fixture.args.output/'file-metadata.tsv'
        root=self.path.parent.resolve();namespace=root/'namespace-registry.tsv'
        raw_siteinfo=json.dumps(dict(query=query)).encode()
        xml=('<mediawiki><siteinfo><dbname>'+wiki+'</dbname><namespaces>'+''.join(
             '<namespace key="'+str(row['id'])+'" case="'+row['case']+'">'+row['name']+'</namespace>'
             for row in inventory)+'</namespaces></siteinfo></mediawiki>').encode()
        for name,raw in [('dump-siteinfo.xml',xml),('namespace-siteinfo.raw.json',raw_siteinfo),
                         ('pagetable-dumpstatus.raw.json',b'{}')]:
            (root/name).write_bytes(raw)
        artifacts={name:b.sha256_file(root/name) for name in
                   ('dump-siteinfo.xml','namespace-siteinfo.raw.json','pagetable-dumpstatus.raw.json')}
        capture=dict(wiki=wiki,date=date,source_xml=item,namespace_mismatches=[],artifacts=artifacts,
                     dump_namespace_inventory=inventory,retrieved_utc='2026-10-18T00:00:00Z',
                     siteinfo_source_url='https://ar.wiktionary.org/w/api.php',
                     siteinfo_temporal_scope='synthetic-local-fixture')
        (root/'capture.complete.json').write_text(json.dumps(capture))
        namespace_projection.build(root)
        self.assertEqual(namespace.read_bytes(),namespace_raw)
        # Match the normal resolver's mandatory LST projection using the same
        # real derivation chain as LoopMessageSelectionTests, not an override.
        import prepare_magic_words_int as int_magic
        import prepare_magic_words_language as language_magic
        import prepare_magic_words_lst as lst_magic
        original=write_magic_fixture(project/'resolver-magic-capture',wiki,date,
            parser_functions=True,content_language='ar',complete_magic_projection=True)
        int_root=original.parent.parent/int_magic.DERIVED_DIRECTORY
        int_magic.derive_snapshot(original,int_root)
        language_root=original.parent.parent/language_magic.DERIVED_DIRECTORY
        language_magic.derive_snapshot(int_root,language_root)
        lst_magic.derive_snapshot(language_root,root/lst_magic.DERIVED_DIRECTORY)
        magic=root/lst_magic.DERIVED_DIRECTORY/'magic-words.tsv'
        for row in (b'int\t0\tINT:\n',b'language\t0\t#language\n',b'lst\t0\t#section\n'):
            self.assertIn(row,magic.read_bytes())
        downloads=project/'dumps';language=downloads/wiki/date/'language-registry.tsv'
        language.parent.mkdir(parents=True);language.write_bytes(b'# content-language\tar\nar\tArabic\n')
        manifest={'auxiliary_capture_roots':{wiki:str(root.relative_to(project))},
                  'language_registries':[dict(wiki=wiki,date=date,name=language.name,
                      size=language.stat().st_size,sha256=b.sha256_file(language))]}
        return SimpleNamespace(root=root,project=project,wiki=wiki,date=date,item=item,capture=capture,
            namespace=namespace,downloads=downloads,language=language,magic=magic,manifest=manifest,groups={(wiki,date):[item]})

    def resolve_fixture(self, fixture):
        with patch.object(b,'PROJECT',fixture.project):
            return b.resolve_edition_snapshot_options(fixture.manifest,fixture.groups,fixture.downloads)[
                (fixture.wiki,fixture.date)]['auxiliary_snapshots']

    def first_response(self):
        index=self.helper.decode(self.path.with_name(self.helper.EVIDENCE).read_bytes())
        receipt=self.helper.decode(self.path.with_name(index['batches'][0]['accepted_receipt']).read_bytes())
        return self.path.with_name(receipt['response'])

    def mutate_same_size_and_mtime(self, path):
        raw=path.read_bytes();before=path.stat()
        path.write_bytes(bytes([raw[0]^1])+raw[1:])
        os.utime(path,ns=(before.st_atime_ns,before.st_mtime_ns))
        return raw,before

    def test_resolver_combines_adjacent_validation_with_exact_selection_and_hash_parity(self):
        fixture=self.resolver_fixture()
        snapshots={'file-metadata':self.path.resolve(),'namespace-registry':fixture.namespace,
                   'language-registry':fixture.language,'site-info':fixture.root/'namespace-siteinfo.raw.json',
                   'magic-words':fixture.magic}
        with patch.object(self.helper,'payload',wraps=self.helper.payload) as traversals:
            b.validate_captured_snapshot('file-metadata',self.path,fixture.capture,[fixture.item],fixture.root)
            expected=b.verified_auxiliary_hashes(snapshots,fixture.wiki,fixture.date)
            self.assertEqual(traversals.call_count,3)  # Cold pre/post plus adjacent warm recheck.
        b._FILE_METADATA_V2_REPLAYS.clear()
        before=self.path.read_bytes()
        with patch.object(self.helper,'payload',wraps=self.helper.payload) as traversals:
            selected=self.resolve_fixture(fixture)
            self.assertEqual(traversals.call_count,2)  # Cold pre/post remain; no adjacent duplicate.
        self.assertEqual(selected,snapshots)
        self.assertEqual(b.verified_auxiliary_hashes(selected,fixture.wiki,fixture.date),expected)
        self.assertEqual(self.path.read_bytes(),before)

    def test_resolver_preserves_post_replay_inventory_check(self):
        fixture=self.resolver_fixture();response=self.first_response();changed=[]
        original=self.helper.classify_response
        def classify(*args,**kwargs):
            result=original(*args,**kwargs)
            if not changed:changed.append(self.mutate_same_size_and_mtime(response))
            return result
        with patch.object(self.helper,'classify_response',side_effect=classify), \
             patch.object(self.helper,'payload',wraps=self.helper.payload) as traversals:
            with self.assertRaisesRegex(ValueError,'artifact inventory changed'):
                self.resolve_fixture(fixture)
            self.assertEqual(traversals.call_count,2)
        self.assertEqual(len(changed),1)
        self.assertEqual(b._FILE_METADATA_V2_REPLAYS,{})

    def test_resolver_does_not_reuse_changed_evidence_across_calls_or_later_guards(self):
        fixture=self.resolver_fixture();selected=self.resolve_fixture(fixture)
        manifests,artifacts=b.auxiliary_capture_identities(selected,fixture.wiki,fixture.date)
        identity={'auxiliary_capture_sha256':manifests,'auxiliary_capture_artifact_sha256':artifacts}
        self.mutate_same_size_and_mtime(self.first_response())
        for operation in (lambda:self.resolve_fixture(fixture),
                          lambda:b.verified_auxiliary_hashes(selected,fixture.wiki,fixture.date),
                          lambda:b.require_auxiliary_capture_identity(selected,identity)):
            with self.subTest(operation=operation),self.assertRaisesRegex(ValueError,'artifact inventory changed'):
                operation()

    def test_resolver_retains_outer_namespace_binding_on_fresh_shared_result(self):
        fixture=self.resolver_fixture()
        self.mutate_same_size_and_mtime(fixture.namespace)
        with self.assertRaisesRegex(ValueError,'namespace source differs'):
            self.resolve_fixture(fixture)

    def test_resolver_rehashed_wrong_semantics_still_replays_and_rejects(self):
        fixture=self.resolver_fixture();self.resolve_fixture(fixture)
        raw=self.path.read_bytes().replace(b'\tAUDIO\t',b'\tVIDEO\t')
        self.assertNotEqual(raw,self.path.read_bytes());self.path.write_bytes(raw)
        index=self.helper.decode(self.path.with_name(self.helper.EVIDENCE).read_bytes())
        self.manifest.update(output_bytes=len(raw),output_sha256=self.helper.digest(raw))
        self.fixture.rewrite_index_and_manifest(self.manifest,index)
        with self.assertRaisesRegex(ValueError,'TSV differs'):
            self.resolve_fixture(fixture)

    def test_resolver_retains_selected_dump_and_capture_edition_binding(self):
        fixture=self.resolver_fixture()
        fixture.groups[(fixture.wiki,fixture.date)]=[{**fixture.item,'size':2}]
        with self.assertRaisesRegex(ValueError,'Captured source differs'):
            self.resolve_fixture(fixture)
        fixture.groups[(fixture.wiki,fixture.date)]=[fixture.item]
        (fixture.root/'capture.complete.json').write_text(json.dumps({**fixture.capture,'wiki':'bnwiktionary'}))
        with self.assertRaisesRegex(ValueError,'Auxiliary capture edition/date mismatch'):
            self.resolve_fixture(fixture)


    def test_stage_input_identity_projects_fresh_capture_once_with_exact_identity_parity(self):
        fixture=self.resolver_fixture();snapshots=self.resolve_fixture(fixture)
        tool=fixture.project/'zig-fixture';tool.write_bytes(b'unchanged toolchain fixture')
        reviewed={'sha256':'f'*64}
        with patch.object(b.shutil,'which',return_value=str(tool)), \
             patch.object(b,'source_fingerprint',return_value='audit-source'):
            with patch.object(self.helper,'payload',wraps=self.helper.payload) as traversals:
                hashes=b.verified_auxiliary_hashes(snapshots,fixture.wiki,fixture.date)
                expected=b.build_input_identity([fixture.item],'zig',hashes,'interwiki',60000,
                    snapshots,fixture.downloads,reviewed)
                self.assertEqual(traversals.call_count,2)
            with patch.object(self.helper,'payload',wraps=self.helper.payload) as traversals:
                actual=b.build_input_identity([fixture.item],'zig',None,'interwiki',60000,
                    snapshots,fixture.downloads,reviewed,validate_auxiliary=True)
                self.assertEqual(traversals.call_count,1)
            self.assertEqual(actual,expected)
            self.assertEqual(actual['source'],'audit-source')
            self.assertEqual(actual['zig_sha256'],b.sha256_file(tool))
            self.assertEqual(actual['reviewed_nonlexical_source_review_sha256'],reviewed['sha256'])
            with self.assertRaisesRegex(ValueError,'does not accept supplied hashes'):
                b.build_input_identity([fixture.item],'zig',hashes,None,None,snapshots,
                    fixture.downloads,validate_auxiliary=True)

    def test_stage_input_identity_detects_changes_during_source_and_toolchain_hashing(self):
        fixture=self.resolver_fixture();snapshots=self.resolve_fixture(fixture)
        tool=fixture.project/'zig-fixture';tool.write_bytes(b'unchanged toolchain fixture')
        response=self.first_response();original=response.read_bytes();before=response.stat()
        original_hash=b.sha256_file
        for phase in ('source','toolchain'):
            mutated=[]
            def mutate():
                if not mutated:mutated.append(self.mutate_same_size_and_mtime(response))
            def source_hash():
                if phase=='source':mutate()
                return 'audit-source'
            def file_hash(path):
                result=original_hash(path)
                if phase=='toolchain' and Path(path)==tool:mutate()
                return result
            try:
                with self.subTest(phase=phase),patch.object(b.shutil,'which',return_value=str(tool)), \
                     patch.object(b,'source_fingerprint',side_effect=source_hash), \
                     patch.object(b,'sha256_file',side_effect=file_hash):
                    with self.assertRaisesRegex(ValueError,'artifact inventory changed'):
                        b.build_input_identity([fixture.item],'zig',None,None,None,snapshots,
                            fixture.downloads,validate_auxiliary=True)
                    self.assertEqual(len(mutated),1)
            finally:
                response.write_bytes(original);os.utime(response,ns=(before.st_atime_ns,before.st_mtime_ns))

    def test_stage_workspace_projects_once_and_keeps_later_boundary_revalidation(self):
        fixture=self.resolver_fixture();snapshots=self.resolve_fixture(fixture)
        with patch.object(self.helper,'payload',wraps=self.helper.payload) as traversals:
            expected_hashes=b.verified_auxiliary_hashes(snapshots,fixture.wiki,fixture.date)
            expected_manifests,expected_artifacts=b.auxiliary_capture_identities(snapshots,fixture.wiki,fixture.date)
            self.assertEqual(traversals.call_count,2)
        with patch.object(b,'_source_fingerprints',return_value=('audit-source','producer-source')):
            with patch.object(self.helper,'payload',wraps=self.helper.payload) as traversals:
                state=b.shard_state([fixture.item],fixture.language,123,auxiliary_snapshots=snapshots)
                self.assertEqual(traversals.call_count,1)
            self.assertEqual(state['auxiliary_snapshot_sha256'],expected_hashes)
            self.assertEqual(state['auxiliary_capture_sha256'],expected_manifests)
            self.assertEqual(state['auxiliary_capture_artifact_sha256'],expected_artifacts)
            self.assertEqual((state['source'],state['production_source'],state['now_unix']),
                             ('audit-source','producer-source',123))
            self.mutate_same_size_and_mtime(self.first_response())
            with self.assertRaisesRegex(ValueError,'artifact inventory changed'):
                b.shard_state([fixture.item],fixture.language,123,auxiliary_snapshots=snapshots)
            with self.assertRaisesRegex(ValueError,'artifact inventory changed'):
                b.require_auxiliary_capture_identity(snapshots,state)

    def test_stage_identity_projection_keeps_cross_capture_namespace_consistency(self):
        fixture=self.resolver_fixture();tool=fixture.project/'zig-fixture';tool.write_bytes(b'toolchain fixture')
        import namespace_registry_snapshot as namespace_projection
        import site_info_snapshot as site_info
        alternate=fixture.project/'alternate-namespace';alternate.mkdir()
        for name in fixture.capture['artifacts']:
            (alternate/name).write_bytes((fixture.root/name).read_bytes())
        raw_siteinfo=json.loads((alternate/'namespace-siteinfo.raw.json').read_text())
        raw_siteinfo['query']['namespacealiases'].append({'id':6,'alias':'Image'})
        (alternate/'namespace-siteinfo.raw.json').write_text(json.dumps(raw_siteinfo))
        alternate_capture={**fixture.capture,'artifacts':{name:b.sha256_file(alternate/name)
            for name in fixture.capture['artifacts']}}
        (alternate/'capture.complete.json').write_text(json.dumps(alternate_capture))
        namespace_projection.build(alternate)
        # This is independently valid projected evidence, not a stale output hash.
        site_info.validate_snapshot(alternate/'namespace-siteinfo.raw.json',fixture.wiki,fixture.date)
        selected_namespace=alternate/'namespace-registry.tsv'
        standalone=b.verified_auxiliary_hashes({'namespace-registry':selected_namespace},fixture.wiki,fixture.date)
        self.assertEqual(standalone,{'namespace-registry':b.sha256_file(selected_namespace)})
        self.assertNotEqual(b.sha256_file(selected_namespace),b.sha256_file(fixture.namespace))
        snapshots={'file-metadata':self.path,'namespace-registry':selected_namespace,
                   'language-registry':fixture.language}
        with patch.object(b.shutil,'which',return_value=str(tool)), \
             patch.object(b,'source_fingerprint',return_value='audit-source'):
            with self.assertRaisesRegex(ValueError,'different namespace registry'):
                b.build_input_identity([fixture.item],'zig',None,None,None,snapshots,
                    fixture.downloads,validate_auxiliary=True)


    def final_auxiliary_boundary(self, function, snapshots, hashes, identity, staging):
        # Execute the actual maintained finalization block; no native/subprocess boundary.
        import ast,inspect,textwrap
        if function is b.build_locked:function=b._build_locked
        tree=ast.parse(textwrap.dedent(inspect.getsource(function)))
        blocks=[node for node in ast.walk(tree) if isinstance(node,ast.If) and
                ast.unparse(node.test)=='auxiliary_hashes or build_identity is not None']
        self.assertEqual(len(blocks),1)
        namespace=dict(auxiliary_hashes=hashes,build_identity=identity,
            auxiliary_snapshots=snapshots,aux_pinned=snapshots,staging=staging,
            AUXILIARY_SHA_NAME=b.AUXILIARY_SHA_NAME,json=json,
            _validated_auxiliary_state=b._validated_auxiliary_state,
            _project_auxiliary_capture_identities=b._project_auxiliary_capture_identities)
        exec(compile(ast.Module(body=blocks,type_ignores=[]),'<actual-final-auxiliary-boundary>','exec'),namespace)

    def test_final_boundaries_share_one_fresh_validation_for_hashes_and_capture_identity(self):
        fixture=self.resolver_fixture();snapshots=self.resolve_fixture(fixture)
        hashes=b.verified_auxiliary_hashes(snapshots)
        manifests,artifacts=b.auxiliary_capture_identities(snapshots)
        identity=dict(auxiliary_capture_sha256=manifests,auxiliary_capture_artifact_sha256=artifacts)
        for function in (b.build_sharded,b.build_locked):
            with self.subTest(function=function.__name__),tempfile.TemporaryDirectory() as tmp:
                staging=Path(tmp)
                with patch.object(self.helper,'payload',wraps=self.helper.payload) as traversals, \
                     patch.object(b,'_validated_auxiliary_state',wraps=b._validated_auxiliary_state) as validations:
                    self.final_auxiliary_boundary(function,snapshots,hashes,identity,staging)
                    self.assertEqual(validations.call_count,1)
                    self.assertEqual(traversals.call_count,1)
                self.assertEqual(json.loads((staging/b.AUXILIARY_SHA_NAME).read_text()),hashes)
        # No identities means the existing no-op path stays a no-op.
        with tempfile.TemporaryDirectory() as tmp,patch.object(b,'_validated_auxiliary_state') as validations:
            for function in (b.build_sharded,b.build_locked):
                self.final_auxiliary_boundary(function,None,None,None,Path(tmp))
            validations.assert_not_called()

    def test_final_boundaries_reject_snapshot_manifest_and_artifact_mismatches(self):
        fixture=self.resolver_fixture();snapshots=self.resolve_fixture(fixture)
        hashes=b.verified_auxiliary_hashes(snapshots)
        manifests,artifacts=b.auxiliary_capture_identities(snapshots)
        identity=dict(auxiliary_capture_sha256=manifests,auxiliary_capture_artifact_sha256=artifacts)
        for function in (b.build_sharded,b.build_locked):
            for mismatch in ('snapshot','manifest','artifact'):
                expected_hashes=dict(hashes);expected=json.loads(json.dumps(identity))
                if mismatch=='snapshot':expected_hashes['file-metadata']='0'*64
                else:expected['auxiliary_capture_sha256' if mismatch=='manifest' else
                              'auxiliary_capture_artifact_sha256']['file-metadata']='0'*64
                with self.subTest(function=function.__name__,mismatch=mismatch),tempfile.TemporaryDirectory() as tmp, \
                     patch.object(b,'_validated_auxiliary_state',wraps=b._validated_auxiliary_state) as validations:
                    with self.assertRaisesRegex(ValueError,'Auxiliary (snapshot|capture) changed during build'):
                        self.final_auxiliary_boundary(function,snapshots,expected_hashes,expected,Path(tmp))
                    self.assertEqual(validations.call_count,1)

    def test_final_boundaries_revalidate_changed_bytes_on_every_later_call(self):
        fixture=self.resolver_fixture();snapshots=self.resolve_fixture(fixture)
        hashes=b.verified_auxiliary_hashes(snapshots)
        manifests,artifacts=b.auxiliary_capture_identities(snapshots)
        identity=dict(auxiliary_capture_sha256=manifests,auxiliary_capture_artifact_sha256=artifacts)
        with tempfile.TemporaryDirectory() as tmp:
            for function in (b.build_sharded,b.build_locked):
                self.final_auxiliary_boundary(function,snapshots,hashes,identity,Path(tmp))
            self.mutate_same_size_and_mtime(self.first_response())
            for function in (b.build_sharded,b.build_locked):
                with self.subTest(function=function.__name__),self.assertRaisesRegex(ValueError,'artifact inventory changed'):
                    self.final_auxiliary_boundary(function,snapshots,hashes,identity,Path(tmp))


class LoopMessageSelectionTests(unittest.TestCase):
    """Real capture/replay and resolver; all outer source bytes are synthetic."""
    def setUp(self):
        import prepare_language_messages_v2 as messages
        from test_prepare_language_messages_v2 import Transport
        self.messages,self.Transport=messages,Transport
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.project=Path(self.temp.name)
        self.root=self.project/'auxiliary'/'bnwiktionary'/'20261001'
        self.root.mkdir(parents=True)
        self.downloads=self.project/'dumps'
        self.wiki,self.date='bnwiktionary','20261001'
        self.namespace=self.root/'namespace-registry.tsv'
        self.item=dict(wiki=self.wiki,date=self.date,name='bnwiktionary-20261001-pages-meta-current.xml.bz2',
                       url='https://dumps.wikimedia.org/synthetic-local-fixture',size=1,sha1='0'*40)
        # Build one coherent synthetic dated XML/current siteinfo namespace
        # capture using the real projector; the resolver validates this whole
        # authority, including its discovered legacy site-info role.
        import namespace_registry_snapshot as namespace_projection
        import site_info_snapshot as site_info
        namespaces={str(i):dict(id=i,name=name,canonical=name,case='case-sensitive',
                                content=i==0,defaultcontentmodel='wikitext')
                    for i,name in ((0,''),(10,'Template'),(14,'Category'))}
        inventory=[dict(id=row['id'],name=row['name'],case=row['case'])
                   for row in namespaces.values()]
        query=dict(general=dict(wikiid=self.wiki,lang='bn',server='//bn.wiktionary.org'),
                   namespaces=namespaces,namespacealiases=[])
        raw_siteinfo=json.dumps(dict(query=query)).encode()
        xml=('<mediawiki><siteinfo><dbname>'+self.wiki+'</dbname><namespaces>'+
             ''.join('<namespace key="'+str(row['id'])+'" case="'+row['case']+'">'+
                     row['name']+'</namespace>' for row in inventory)+
             '</namespaces></siteinfo></mediawiki>').encode()
        for name,raw in [('dump-siteinfo.xml',xml),
                         ('namespace-siteinfo.raw.json',raw_siteinfo),('pagetable-dumpstatus.raw.json',b'{}')]:
            (self.root/name).write_bytes(raw)
        artifacts={name:b.sha256_file(self.root/name) for name in
                   ('dump-siteinfo.xml','namespace-siteinfo.raw.json','pagetable-dumpstatus.raw.json')}
        capture=dict(wiki=self.wiki,date=self.date,source_xml=self.item,namespace_mismatches=[],
                     dump_namespace_inventory=inventory,artifacts=artifacts,
                     retrieved_utc='2026-10-18T00:00:00Z',
                     siteinfo_source_url='https://bn.wiktionary.org/w/api.php',
                     siteinfo_temporal_scope='synthetic-local-fixture')
        (self.root/'capture.complete.json').write_text(json.dumps(capture))
        namespace_projection.build(self.root)
        site_info.validate_snapshot(self.root/'namespace-siteinfo.raw.json',self.wiki,self.date)
        language=self.downloads/self.wiki/self.date/'language-registry.tsv'
        language.parent.mkdir(parents=True)
        language.write_text('# content-language\tbn\nbn\tবাংলা\nen\tEnglish\n')
        self.manifest={'auxiliary_capture_roots':{self.wiki:str(self.root.relative_to(self.project))},
                       'language_registries':[dict(wiki=self.wiki,date=self.date,name=language.name,
                           size=language.stat().st_size,sha256=b.sha256_file(language))]}
        self.groups={(self.wiki,self.date):[self.item]}
        # Exercise the real resolver's mandatory full LST projection as well as
        # message selection; each predecessor embeds authenticated raw evidence.
        import prepare_magic_words as magic
        import prepare_magic_words_int as int_magic
        import prepare_magic_words_language as language_magic
        import prepare_magic_words_lst as lst_magic
        original=write_magic_fixture(self.project/'magic-capture', self.wiki, self.date,
                                     parser_functions=True, content_language='bn', complete_magic_projection=True)
        int_root=original.parent.parent/int_magic.DERIVED_DIRECTORY
        int_magic.derive_snapshot(original,int_root)
        language_root=original.parent.parent/language_magic.DERIVED_DIRECTORY
        language_magic.derive_snapshot(int_root,language_root)
        lst_magic.derive_snapshot(language_root,self.root/lst_magic.DERIVED_DIRECTORY)
        projection=(self.root/lst_magic.DERIVED_DIRECTORY/'magic-words.tsv').read_bytes()
        for row in (b'int\t0\tINT:\n',b'language\t0\t#language\n',b'lst\t0\t#section\n'):
            self.assertIn(row,projection)

    def rebind(self, root, generator=None):
        messages=self.messages
        inventory=messages.owned_payload(root)
        hashes={}
        for kind in messages.KINDS:
            path=root/(kind+'.manifest.json')
            record=json.loads(path.read_text())
            record['artifacts']=inventory
            raw=(root/(kind+'.tsv')).read_bytes()
            record.update(output_bytes=len(raw),output_sha256=messages.evidence.digest(raw))
            if generator is not None:record['generator_sha256']=generator
            path.write_bytes(messages.evidence.encoded(record))
            hashes[path.name]=messages.evidence.digest(path.read_bytes())
        (root/messages.COMPLETE).write_bytes(messages.evidence.encoded(
            {'schema':messages.SCHEMA,'manifests':hashes}))

    def collect(self, directory, prior=False):
        messages=self.messages
        args=SimpleNamespace(wiki=self.wiki,date=self.date,namespace_registry=self.namespace,
             output=self.root/directory,languages=['bn','en'],
             messages=[f'Key-{i:03d}' for i in range(66)],delay=0,wall_seconds=60)
        if prior:
            required=messages.REQUIRED_MESSAGE_KEYS
            try:
                messages.REQUIRED_MESSAGE_KEYS=frozenset()
                messages.capture(args,transport=self.Transport(),sleep=lambda _:None)
            finally:
                messages.REQUIRED_MESSAGE_KEYS=required
            self.rebind(args.output,messages.PRE_LOOP_WARNING_GENERATOR_SHA256)
        else:
            messages.capture(args,transport=self.Transport(),sleep=lambda _:None)
        return args.output

    def resolve(self):
        with patch.object(b,'PROJECT',self.project):
            return b.resolve_edition_snapshot_options(self.manifest,self.groups,self.downloads)[(self.wiki,self.date)]['auxiliary_snapshots']

    def test_retained_source_resolves_unchanged_workspace_captures_with_full_validation(self):
        expected=self.resolve()
        source=self.project/'.tmp/retained';source.mkdir(parents=True)
        with patch.object(b,'PROJECT',source):
            with self.assertRaises(FileNotFoundError):
                b.resolve_edition_snapshot_options(self.manifest,self.groups,self.downloads)
            actual=b.resolve_edition_snapshot_options(self.manifest,self.groups,self.downloads,
                                                       workspace=self.project)
            self.assertEqual(actual[(self.wiki,self.date)]['auxiliary_snapshots'],expected)
            # Same-path selection still replays authenticated capture bytes.
            (self.root/'namespace-siteinfo.raw.json').write_bytes(b'corrupt selected authority')
            with self.assertRaises(ValueError):
                b.resolve_edition_snapshot_options(self.manifest,self.groups,self.downloads,
                                                   workspace=self.project)

    def test_retained_source_does_not_allow_capture_root_escape(self):
        import copy
        source=self.project/'.tmp/retained';source.mkdir(parents=True)
        with tempfile.TemporaryDirectory() as external:
            target=Path(external)
            # A valid-looking identity must not let a symlink escape the workspace.
            (target/'capture.complete.json').write_bytes((self.root/'capture.complete.json').read_bytes())
            (self.project/'escaped').symlink_to(target,target_is_directory=True)
            for selected in ('../outside',str(self.root),'escaped'):
                manifest=copy.deepcopy(self.manifest)
                manifest['auxiliary_capture_roots'][self.wiki]=selected
                with self.subTest(selected=selected),patch.object(b,'PROJECT',source),self.assertRaises(ValueError):
                    b.resolve_edition_snapshot_options(manifest,self.groups,self.downloads,workspace=self.project)

    def test_explicit_valid_pair_ignores_invalid_unused_default(self):
        old=self.collect('language-messages-loop-v1')
        (old/'interface-messages.tsv').write_bytes(b'invalid unused default')
        new=self.collect('explicit-messages')
        overrides={kind:new/(kind+'.tsv') for kind in self.messages.KINDS}
        with patch.object(b,'PROJECT',self.project):
            selected=b.resolve_edition_snapshot_options(self.manifest,self.groups,self.downloads,overrides)[(self.wiki,self.date)]['auxiliary_snapshots']
        for kind in self.messages.KINDS:
            self.assertEqual(selected[kind],overrides[kind])
            self.messages.validate_snapshot(selected[kind],self.wiki,self.date)

    def test_invalid_explicit_pair_still_fails_selected_validation(self):
        self.collect('language-messages-loop-v1')
        new=self.collect('explicit-messages')
        (new/'interface-messages.tsv').write_bytes(b'invalid selected override')
        overrides={kind:new/(kind+'.tsv') for kind in self.messages.KINDS}
        with patch.object(b,'PROJECT',self.project),self.assertRaises(ValueError):
            b.resolve_edition_snapshot_options(self.manifest,self.groups,self.downloads,overrides)

    def test_explicit_magic_ignores_corrupt_unused_default(self):
        import shutil
        import prepare_magic_words_lst as lst_magic
        default=self.root/lst_magic.DERIVED_DIRECTORY
        selected=self.project/'explicit-magic'
        shutil.copytree(default,selected)
        (default/'magic-words.tsv').write_bytes(b'corrupt unused magic')
        overrides={'magic-words':selected/'magic-words.tsv'}
        with patch.object(b,'PROJECT',self.project):
            options=b.resolve_edition_snapshot_options(self.manifest,self.groups,self.downloads,overrides)
        self.assertEqual(options[(self.wiki,self.date)]['auxiliary_snapshots']['magic-words'],overrides['magic-words'])

    def test_corrupt_selected_magic_still_rejected(self):
        import shutil
        import prepare_magic_words_lst as lst_magic
        selected=self.project/'explicit-magic'
        shutil.copytree(self.root/lst_magic.DERIVED_DIRECTORY,selected)
        (selected/'magic-words.tsv').write_bytes(b'corrupt selected magic')
        with patch.object(b,'PROJECT',self.project),self.assertRaises(ValueError):
            b.resolve_edition_snapshot_options(self.manifest,self.groups,self.downloads,{'magic-words':selected/'magic-words.tsv'})

    def test_partial_message_override_still_validates_required_default_pair(self):
        default=self.collect('language-messages-loop-v1')
        selected=self.collect('explicit-messages')
        (default/'language-fallbacks.tsv').write_bytes(b'corrupt required fallback')
        with patch.object(b,'PROJECT',self.project),self.assertRaises(ValueError):
            b.resolve_edition_snapshot_options(self.manifest,self.groups,self.downloads,{'interface-messages':selected/'interface-messages.tsv'})

    def test_loop_pair_preferred_and_prior_pair_bytes_unchanged(self):
        old=self.collect('language-messages',prior=True)
        before={p.name:p.read_bytes() for p in old.iterdir()}
        new=self.collect('language-messages-loop-v1')
        selected=self.resolve()
        for kind in self.messages.KINDS:
            self.assertEqual(selected[kind],new/(kind+'.tsv'))
            verified=self.messages.validate_snapshot(selected[kind],self.wiki,self.date)
            self.assertEqual(len(verified['keys']),67)
            self.assertIn('parser-template-loop-warning',verified['keys'])
        self.assertEqual(before,{p.name:p.read_bytes() for p in old.iterdir()})
        self.assertEqual(selected['namespace-registry'],self.namespace)

    def test_absent_loop_directory_preserves_real_prior_sixty_six(self):
        old=self.collect('language-messages',prior=True)
        selected=self.resolve()
        self.assertEqual(selected['interface-messages'],old/'interface-messages.tsv')
        record=self.messages.validate_snapshot(selected['interface-messages'],self.wiki,self.date)
        self.assertEqual(len(record['keys']),66)
        self.assertNotIn('parser-template-loop-warning',record['keys'])

    def test_partial_loop_pair_refuses_instead_of_legacy_fallback(self):
        self.collect('language-messages',prior=True)
        new=self.collect('language-messages-loop-v1')
        (new/'language-fallbacks.tsv').unlink()
        with self.assertRaises((ValueError,FileNotFoundError)):
            self.resolve()

    def test_preferred_loop_profile_requires_warning_and_full_current_replay(self):
        for mode in ('prior-sixty-six','unknown'):
            with self.subTest(mode=mode):
                if (self.root/'language-messages-loop-v1').exists():
                    (self.root/'language-messages-loop-v1').rename(self.root/'previous-loop-case')
                new=self.collect('language-messages-loop-v1',prior=mode=='prior-sixty-six')
                if mode=='prior-sixty-six':
                    with self.assertRaisesRegex(ValueError,'loop-warning key'):self.resolve()
                    continue
                self.rebind(new,'0'*64)
                before={path.name:path.read_bytes() for path in new.iterdir()}
                record=json.loads((new/'interface-messages.manifest.json').read_text())
                expected_batches=sum(json.loads((new/batch['request']).read_text())['kind']=='messages'
                                     for batch in record['requests'])
                self.assertGreater(expected_batches,0)
                self.messages._VALIDATED_REPLAY_KEYS.clear()
                with patch.object(self.messages,'parse_messages',wraps=self.messages.parse_messages) as replay:
                    selected=self.resolve()
                    self.assertEqual(replay.call_count,expected_batches)
                for kind in self.messages.KINDS:self.assertEqual(selected[kind],new/(kind+'.tsv'))
                self.assertEqual(before,{path.name:path.read_bytes() for path in new.iterdir()})
                self.assertEqual(self.messages.validate_snapshot(selected['interface-messages'])['generator_sha256'],'0'*64)
                target=new/'interface-messages.tsv';raw=target.read_bytes()
                tampered=raw.replace('বাংলা parser-template-loop-warning'.encode(),b'forged warning')
                self.assertNotEqual(raw,tampered);target.write_bytes(tampered);self.rebind(new,'0'*64)
                with self.assertRaisesRegex(ValueError,'Rendered TSV differs from complete API evidence'):
                    self.resolve()

    def test_missing_warning_under_new_producer_is_not_a_loop_profile(self):
        new=self.collect('language-messages-loop-v1',prior=True)
        self.rebind(new,self.messages.producer()['generator_sha256'])
        with self.assertRaisesRegex(ValueError,'Required parser message'):
            self.resolve()

    def test_resealed_message_or_accepted_receipt_tampering_refuses(self):
        for mode in ('localized-row','accepted-receipt'):
            with self.subTest(mode=mode):
                if (self.root/'language-messages-loop-v1').exists():
                    (self.root/'language-messages-loop-v1').rename(self.root/'previous-loop-case')
                new=self.collect('language-messages-loop-v1')
                if mode=='localized-row':
                    p=new/'interface-messages.tsv'
                    p.write_text(p.read_text().replace('বাংলা parser-template-loop-warning','forged warning',1))
                else:
                    record=json.loads((new/'interface-messages.manifest.json').read_text())
                    p=new/record['requests'][-1]['accepted_receipt']
                    receipt=json.loads(p.read_text());receipt['accepted']=False
                    p.write_bytes(self.messages.evidence.encoded(receipt))
                self.rebind(new)
                with self.assertRaisesRegex(ValueError,'Rendered TSV|accepted API receipt'):
                    self.resolve()


class ExplicitExtractionCacheTests(PreparedToolsFixture):
    def test_unsharded_command_uses_workspace_cache_by_default_and_preserves_override(self):
        for explicit in (False,True):
            with self.subTest(explicit=explicit),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);folder=root/'testwiktionary/20260901'
                write_namespace_fixture(folder)
                name='testwiktionary-20260901-pages-meta-current.xml.bz2'
                data=bz2.compress(b'<mediawiki><page></page></mediawiki>')
                (folder/name).write_bytes(data)
                item=dict(wiki='testwiktionary',date='20260901',name=name,
                    url='https://dumps.wikimedia.org/testwiktionary/20260901/'+name,
                    size=len(data),sha1=hashlib.sha1(data).hexdigest())
                workspace=root/'output/testwiktionary/20260901.shards'
                cache=root/'external-cache';cache.mkdir()
                options={'extraction_cache_root':cache} if explicit else {}
                with patch.object(b,'PROJECT',root), \
                     patch.object(b,'timed_run',side_effect=RuntimeError('stop before native execution')) as run:
                    with self.assertRaisesRegex(RuntimeError,'stop before native execution'):
                        b.build_locked([item],root,root/'output',sys.executable,1,**options)
                run.assert_called_once()
                command=run.call_args.args[0]
                self.assertEqual(run.call_args.args[3],'dictionary_build')
                self.assertEqual(tool_arguments(command)[:2],[str(workspace/'input/pages.xml.zst'),
                    str(root/'output/testwiktionary/20260901.building')])
                self.assertNotIn('--expander-only',command)
                expected=cache if explicit else workspace/'input/extraction-cache'
                self.assertEqual(command[command.index('--extraction-cache-root')+1],str(expected))
                staged=json.loads((workspace/'input/.complete.json').read_text())
                self.assertEqual(staged['source_pages'],1)
                for flag,key in (('--verified-dump-sha256','dump_sha256'),
                                 ('--verified-index-sha256','index_sha256')):
                    self.assertEqual(command[command.index(flag)+1],staged[key])
                self.assertEqual(staged['dump_sha256'],b.sha256_file(workspace/'input/pages.xml.zst'))
                self.assertEqual(staged['index_sha256'],b.sha256_file(workspace/'input/pages-index.txt.bz2'))

    def test_fresh_expander_command_uses_external_cache_and_new_input_marker(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);workspace=root/'fresh-work';(workspace/'input').mkdir(parents=True)
            cache=root/'old-cache';cache.mkdir()
            (workspace/'input/.complete.json').write_text(json.dumps({'dump_sha256':'c'*64,'index_sha256':'d'*64}))
            for selected,expected in [(cache,cache),(None,workspace/'input/extraction-cache')]:
                with patch.object(b,'expander_ready',return_value=False), \
                     patch.object(b,'pipeline_snapshot_args',return_value=[]), \
                     patch.object(b,'timed_run',side_effect=RuntimeError('stop before native execution')) as run:
                    with self.assertRaisesRegex(RuntimeError,'stop before native execution'):
                        b.build_sharded(root/'new-dump',root/'fresh-staging',workspace,root/'registry','zig',1,
                            [{'wiki':'testwiktionary','date':'20261001'}],123,extraction_cache_root=selected)
                command=run.call_args.args[0]
                self.assertEqual(tool_arguments(command)[:2],
                                 [str(root/'new-dump'),str(workspace/'expander')])
                self.assertEqual(command[command.index('--extraction-cache-root')+1],str(expected))
                self.assertEqual(command[command.index('--verified-dump-sha256')+1],'c'*64)
                self.assertEqual(command[command.index('--verified-index-sha256')+1],'d'*64)
                self.assertIn('--expander-only',command)

    def test_cache_command_uses_current_staged_digests_and_rejects_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);cache=root/'cache';cache.mkdir()
            staged={'dump_sha256':'a'*64,'index_sha256':'b'*64}
            self.assertEqual(b.extraction_cache_args(None,{}),[])
            self.assertEqual(b.extraction_cache_args(cache,staged),[
                '--extraction-cache-root',str(cache),
                '--verified-dump-sha256','a'*64,'--verified-index-sha256','b'*64])
            link=root/'link';link.symlink_to(cache,target_is_directory=True)
            with self.assertRaisesRegex(ValueError,'regular directory'):
                b.extraction_cache_args(link,staged)

    def test_cli_and_scheduler_forward_cache_without_adopting_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);cache=root/'old-cache';cache.mkdir();output=root/'fresh-output'
            argv=['build_wiktionaries.py','--resource-mode=watchdog','--output',str(output),
                  '--extraction-cache-root',str(cache),'--downloads',str(root),'--threads','1','--jobs','1']
            write_test_manifest(root,{'files':[dict(wiki='testwiktionary',date='20261001',name='test.xml.bz2',
                url='https://dumps.wikimedia.org/testwiktionary/20261001/test.xml.bz2',size=1,sha1='a'*40)]})
            with patch.object(b,'PROJECT',root),patch.object(sys,'argv',argv), \
                 patch.object(b,'safe_worker_budget',return_value=1),patch.object(b,'build_groups',return_value=[]) as groups:
                b.main()
            self.assertEqual(groups.call_args.kwargs['extraction_cache_root'],cache)
            self.assertEqual(groups.call_args.args[2],output)
            with patch.object(b,'safe_worker_budget',return_value=1),patch.object(b,'build',return_value='built') as build:
                b.build_groups({('testwiktionary','20261001'):['item']},root,output,'zig',1,1,extraction_cache_root=cache)
            self.assertEqual(build.call_args.kwargs['extraction_cache_root'],cache)
            self.assertEqual(build.call_args.args[2],output)
            with patch.object(b,'PROJECT',root),patch.object(sys,'argv',argv), \
                 patch.object(limits,'inside_watchdog',return_value=False),patch.object(limits,'supervise_watchdog',return_value=0) as watchdog:
                with self.assertRaises(SystemExit) as done:b.cli()
                self.assertEqual(done.exception.code,0)
            watchdog.assert_called_once_with(wall_seconds=7200,disk_paths=(root/'.tmp',output,cache))

class ExplicitLlvmWorkerTests(PreparedToolsFixture):
    def test_invalid_llvm_workers_refuse_before_artifact_side_effects(self):
        root=Path('/unused-invalid-llvm-control')
        for value in (0,-1,5,True,1.5):
            for entry,args in ((b.build,([],root,root/'out','zig')),
                               (b.build_locked,([],root,root/'out','zig')),
                               (b.build_sharded,(root/'dump',root/'staging',root/'work',root/'registry','zig',1,[],123))):
                with self.subTest(value=value,entry=entry.__name__), \
                     patch.object(b,'artifact_path') as artifact, \
                     patch.object(b,'remove_artifact_tree') as cleanup, \
                     patch.object(b,'cleanup_dead_private_shards') as reconcile, \
                     patch.object(b,'external_raw_shards') as external, \
                     patch.object(b,'timed_run') as native:
                    with self.assertRaisesRegex(ValueError,'LLVM workers'):
                        options={'raw_shards_path':root/'raw'} if entry is b.build_sharded else {}
                        entry(*args,llvm_workers=value,**options)
                    artifact.assert_not_called()
                    cleanup.assert_not_called()
                    reconcile.assert_not_called()
                    external.assert_not_called()
                    native.assert_not_called()

    def test_sharded_llvm_override_preserves_other_workers(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);work=root/'work';(work/'input').mkdir(parents=True)
            (work/'input/.complete.json').write_text(json.dumps({'dump_sha256':'a'*64,'index_sha256':'b'*64}))
            for chosen,expected in ((None,'1'),(2,'2')):
                with patch.object(b,'expander_ready',return_value=False),patch.object(b,'pipeline_snapshot_args',return_value=[]),patch.object(b,'timed_run',side_effect=RuntimeError('stop')) as run:
                    with self.assertRaisesRegex(RuntimeError,'stop'):
                        b.build_sharded(root/'dump',root/'staging',work,root/'registry','zig',1,[{'wiki':'testwiktionary','date':'20261001'}],123,llvm_workers=chosen)
                argv=run.call_args.args[0]
                self.assertEqual(argv[argv.index('--llvm-workers')+1],expected)
                for flag in ('--parse-workers','--page-workers'):self.assertEqual(argv[argv.index(flag)+1],'1')

    def test_llvm_override_affinity_and_type_validation(self):
        with patch.object(b,'safe_worker_budget',return_value=2),patch.object(b,'affinity_worker_budget',return_value=2):
            b.validate_affinity_workers(1,1,1,2)
            for value in (0,-1,5,True,1.5):
                with self.subTest(value=value),self.assertRaises(ValueError):b.validate_affinity_workers(1,1,1,value)
        with patch.object(b,'safe_worker_budget',return_value=1),patch.object(b,'affinity_worker_budget',return_value=1):
            with self.assertRaises(ValueError):b.validate_affinity_workers(1,1,1,2)

    def test_llvm_override_cli_and_scheduler_forwarding(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);argv=['build_wiktionaries.py','--resource-mode=watchdog','--cpu-admission=affinity','--downloads',str(root),'--output',str(root/'out'),'--threads','1','--jobs','1','--llvm-workers','2']
            write_test_manifest(root,{'files':[dict(wiki='testwiktionary',date='20261001',name='test.xml.bz2',url='https://dumps.wikimedia.org/testwiktionary/20261001/test.xml.bz2',size=1,sha1='a'*40)]})
            with patch.object(b,'PROJECT',root),patch.object(sys,'argv',argv),patch.object(b,'safe_worker_budget',return_value=2),patch.object(b,'affinity_worker_budget',return_value=2),patch.object(b,'build_groups',return_value=[]) as groups:b.main()
            self.assertEqual(groups.call_args.kwargs['llvm_workers'],2)
            self.assertEqual(groups.call_args.args[4],1)
            with patch.object(b,'safe_worker_budget',return_value=2),patch.object(b,'affinity_worker_budget',return_value=2),patch.object(b,'build',return_value='built') as build:
                b.build_groups({('testwiktionary','20261001'):['item']},root,root/'out','zig',1,1,cpu_admission='affinity',llvm_workers=2)
            self.assertEqual(build.call_args.kwargs['llvm_workers'],2)
            with patch.object(b,'PROJECT',root),patch.object(sys,'argv',argv),patch.object(b,'safe_worker_budget',return_value=1),patch.object(b,'affinity_worker_budget',return_value=1):
                with self.assertRaises(SystemExit):b.main()


class PreparedBlobToolsTests(unittest.TestCase):
    def fixture(self, root):
        workspace=root/'work';workspace.mkdir()
        compiler=root/'zig';compiler.write_bytes(b'fixture compiler');compiler.chmod(0o755)
        identity=dict(source='qualified-source',zig_sha256=b.sha256_file(compiler))
        return workspace,compiler,identity

    def install(self, command, expander_args=None):
        self.assertEqual(command[1:4],['build','-j1','-Doptimize=fast'])
        if expander_args is None:
            self.assertEqual(command[-1],'prepare-blob-tools')
            self.assertNotIn('--',command)
        else:
            self.assertEqual(command[6:11],['prepare-blob-tools','--summary','all','build-dictionary','--'])
            self.assertEqual(command[11:],expander_args)
        prefix=Path(command[command.index('--prefix')+1]);(prefix/'bin').mkdir(parents=True,exist_ok=True)
        for name in b.BLOB_TOOL_NAMES:
            path=prefix/'bin'/name
            path.write_bytes(('installed '+name).encode());path.chmod(0o755)

    def test_combined_graph_preserves_forwarded_arguments_and_binds_all_tools_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);workspace,compiler,identity=self.fixture(root);calls=[];phases=[]
            args=['dump with spaces',str(workspace/'expander'),'--namespace-registry','nonascii-\u00e9',
                  '--llvm-workers','2','--parse-workers','4','--page-workers','4','--expander-only',
                  '--extraction-cache-root','cache with spaces','--verified-dump-sha256','a'*64,
                  '--verified-index-sha256','b'*64]
            def install(argv):calls.append(argv);self.install(argv,args)
            with patch.object(b,'source_fingerprint',return_value=identity['source']), \
                 patch.object(b,'run_checked',side_effect=install), \
                 patch.object(b,'phase_event',side_effect=lambda edition,date,phase,event,**fields:phases.append((phase,event,fields))):
                tools=b.prepare_blob_tools(workspace,str(compiler),'testwiktionary','20261001',identity,expander_args=args)
            self.assertEqual(len(calls),1)
            self.assertEqual([(phase,event) for phase,event,_ in phases],
                [('expander_and_blob_tools_prepare','start'),('expander_and_blob_tools_prepare','end')])
            record=phases[-1][2];self.assertEqual(record['status'],'success')
            self.assertEqual(record['source'],identity['source']);self.assertEqual(record['zig_sha256'],identity['zig_sha256'])
            self.assertEqual(set(record['tools']),set(b.BLOB_TOOL_NAMES))
            for name,tool in tools.items():
                self.assertEqual(record['tools'][name]['sha256'],b.sha256_file(tool.path))
                self.assertEqual(tool.path.stat().st_mode&0o222,0)
                self.assertEqual(tool.command(['input','output']),[str(tool.path),'input','output'])

    def test_combined_graph_failure_preserves_native_error_without_downstream_work(self):
        for installed in (False,True):
            with self.subTest(installed=installed),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);workspace,compiler,identity=self.fixture(root);phases=[];calls=[]
                (workspace/'input').mkdir()
                (workspace/'input/.complete.json').write_text(json.dumps({'dump_sha256':'a'*64,'index_sha256':'b'*64}))
                error=subprocess.CalledProcessError(7,['original native failure'],output=b'out',stderr=b'err')
                def run(argv):
                    calls.append(argv)
                    if installed:self.install(argv,tool_arguments(argv))
                    raise error
                with patch.object(b,'source_fingerprint',return_value=identity['source']), \
                     patch.object(b,'expander_ready',return_value=False),patch.object(b,'pipeline_snapshot_args',return_value=[]), \
                     patch.object(b,'run_checked',side_effect=run),patch.object(b,'inspect_page_index') as inspect, \
                     patch.object(b,'phase_event',side_effect=lambda edition,date,phase,event,**fields:phases.append((phase,event,fields))):
                    with self.assertRaises(subprocess.CalledProcessError) as failed:
                        b.build_sharded(root/'dump',root/'staging',workspace,root/'registry',str(compiler),1,
                            [{'wiki':'testwiktionary','date':'20261001'}],123,build_identity=identity)
                self.assertIs(failed.exception,error);self.assertEqual(failed.exception.stderr,b'err')
                self.assertEqual(len(calls),1);inspect.assert_not_called()
                self.assertFalse((workspace/'shards').exists());self.assertFalse((root/'staging').exists())
                self.assertEqual(phases[-1][:2],('expander_and_blob_tools_prepare','end'))
                self.assertEqual(phases[-1][2]['status'],'failure');self.assertNotIn('tools',phases[-1][2])
                self.assertEqual((workspace/'native-blob-tools/bin').exists(),installed)

    def test_combined_phase_preserves_campaign_production_time_and_failure(self):
        import corpus_controller as controller
        for fail in (False,True):
            with self.subTest(fail=fail),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);workspace,compiler,identity=self.fixture(root);output=io.StringIO()
                args=['dump',str(workspace/'expander'),'--expander-only']
                error=subprocess.CalledProcessError(7,['original'],stderr=b'compiler diagnostic')
                def run(argv):
                    self.install(argv,args)
                    if fail:raise error
                ticks=[0,1,1.25,2.25,*([] if fail else [3.25]),3.75,4,10]
                with patch.object(b,'source_fingerprint',return_value=identity['source']), \
                     patch.object(b,'run_checked',side_effect=run),patch.object(b.time,'monotonic',side_effect=ticks), \
                     contextlib.redirect_stdout(output):
                    try:
                        with b.build_phase('testwiktionary','20261001','edition_build'):
                            b.prepare_blob_tools(workspace,str(compiler),'testwiktionary','20261001',identity,expander_args=args)
                    except subprocess.CalledProcessError as caught:
                        self.assertTrue(fail);self.assertIs(caught,error)
                events=[json.loads(line.removeprefix('BUILD_PHASE ')) for line in output.getvalue().splitlines()]
                ends=[event for event in events if event['event']=='end']
                self.assertEqual([(event['phase'],event['seconds']) for event in ends],
                    [('expander_and_blob_tools_prepare',3),('edition_build',10)])
                self.assertEqual([event['status'] for event in ends],['failure' if fail else 'success']*2)
                self.assertEqual(ends[0]['pre_verification_seconds'],1)
                self.assertEqual(ends[0]['command_seconds'],1.5 if fail else 1)
                if fail:self.assertNotIn('post_verification_seconds',ends[0])
                else:self.assertEqual(ends[0]['post_verification_seconds'],.5)
                log=root/'build.log';log.write_text(output.getvalue())
                evidence=controller.phase_evidence(log,'testwiktionary','20261001',strict=True)
                self.assertTrue(evidence['production_started']);self.assertEqual(evidence['end'],ends[-1])
                self.assertEqual(controller.attempt_phase_seconds(dict(edition='testwiktionary',edition_build=evidence['end'])),10)

    def test_combined_graph_rejects_source_toolchain_and_install_target_changes(self):
        for change in ('source','compiler','wrong-initial-source','wrong-initial-compiler','symlink','hardlink','directory','nonexecutable'):
            with self.subTest(change=change),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);workspace,compiler,identity=self.fixture(root);calls=[];phases=[]
                args=['dump',str(workspace/'expander'),'--expander-only']
                external=root/'external';external.write_bytes(b'external bytes');external.chmod(0o755)
                unsafe=change in ('symlink','hardlink','directory','nonexecutable')
                if unsafe:
                    target=workspace/'native-blob-tools/bin'/b.BLOB_TOOL_NAMES[0];target.parent.mkdir(parents=True)
                    if change=='symlink':target.symlink_to(external)
                    elif change=='hardlink':os.link(external,target)
                    elif change=='directory':target.mkdir()
                    else:target.write_bytes(b'not executable')
                if change=='wrong-initial-source':identity['source']='other'
                if change=='wrong-initial-compiler':identity['zig_sha256']='0'*64
                def run(argv):
                    calls.append(argv);self.install(argv,args)
                    if change=='compiler':compiler.write_bytes(b'changed compiler')
                sources=['qualified-source','changed-source'] if change=='source' else ['qualified-source','qualified-source']
                with patch.object(b,'source_fingerprint',side_effect=sources),patch.object(b,'run_checked',side_effect=run), \
                     patch.object(b,'phase_event',side_effect=lambda edition,date,phase,event,**fields:phases.append(fields)):
                    with self.assertRaises(ValueError):
                        b.prepare_blob_tools(workspace,str(compiler),'testwiktionary','20261001',identity,expander_args=args)
                self.assertEqual(len(calls),0 if unsafe or change.startswith('wrong-initial') else 1)
                self.assertEqual(phases[-1]['status'],'failure');self.assertNotIn('tools',phases[-1])
                self.assertEqual(external.read_bytes(),b'external bytes');self.assertEqual(external.stat().st_mode&0o777,0o755)

    def test_prepare_binds_all_private_tools_and_direct_arguments(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);workspace,compiler,identity=self.fixture(root);calls=[];phases=[]
            with patch.object(b,'source_fingerprint',return_value=identity['source']),patch.object(b,'run_checked',side_effect=self.install),patch.object(b,'phase_event',side_effect=lambda edition,date,phase,event,**fields:phases.append((phase,event,fields))):
                tools=b.prepare_blob_tools(workspace,str(compiler),'testwiktionary','20261001',identity)
            completed=[fields for phase,event,fields in phases if phase=='blob_tools_prepare' and event=='end' and fields['status']=='success']
            self.assertEqual(len(completed),1);record=completed[0]
            self.assertEqual(record['source'],identity['source']);self.assertEqual(record['zig_sha256'],identity['zig_sha256'])
            self.assertEqual(set(record['tools']),set(b.BLOB_TOOL_NAMES))
            args=['dump with spaces','out','--','-literal','nonascii-\u00e9']
            with patch.object(b,'run_checked',side_effect=lambda argv:calls.append(argv)):
                for name,tool in tools.items():
                    tool.run(args,'testwiktionary','20261001','fixture')
                    self.assertEqual(calls[-1],[str(tool.path),*args])
                    self.assertEqual(record['tools'][name]['sha256'],b.sha256_file(tool.path))
                    self.assertEqual(record['tools'][name]['bytes'],tool.path.stat().st_size)
                    self.assertEqual(tool.path.stat().st_mode&0o222,0)

    def test_changed_source_or_toolchain_never_creates_success_binding(self):
        for change in ('source','compiler','wrong-initial-source','wrong-initial-compiler'):
            with self.subTest(change=change),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);workspace,compiler,identity=self.fixture(root);calls=[];phases=[]
                if change=='wrong-initial-source':identity['source']='other'
                if change=='wrong-initial-compiler':identity['zig_sha256']='0'*64
                def install(argv):
                    calls.append(argv);self.install(argv)
                    if change=='compiler':compiler.write_bytes(b'changed compiler')
                values=['qualified-source','changed-source'] if change=='source' else ['qualified-source','qualified-source']
                with patch.object(b,'source_fingerprint',side_effect=values),patch.object(b,'run_checked',side_effect=install),patch.object(b,'phase_event',side_effect=lambda edition,date,phase,event,**fields:phases.append((event,fields))):
                    with self.assertRaisesRegex(ValueError,'source or compiler differs|Source or compiler changed'):
                        b.prepare_blob_tools(workspace,str(compiler),'testwiktionary','20261001',identity)
                self.assertEqual(phases[-1][1]['status'],'failure');self.assertNotIn('tools',phases[-1][1])
                self.assertEqual(len(calls),0 if change.startswith('wrong-initial') else 1)

    def test_invalid_or_redirected_install_never_chmods_external_or_binds_tools(self):
        for kind in ('missing','symlink','hardlink','nonexecutable','directory','parent-symlink'):
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);workspace,compiler,identity=self.fixture(root);phases=[]
                external=root/'external';external.write_bytes(b'external bytes');external.chmod(0o755)
                def install(argv):
                    self.install(argv);folder=workspace/'native-blob-tools/bin';path=folder/b.BLOB_TOOL_NAMES[0]
                    path.unlink()
                    if kind=='symlink':path.symlink_to(external)
                    elif kind=='hardlink':os.link(external,path)
                    elif kind=='nonexecutable':path.write_bytes(b'not executable')
                    elif kind=='directory':path.mkdir()
                    elif kind=='parent-symlink':
                        saved=root/'redirected-bin';folder.rename(saved);folder.symlink_to(saved,target_is_directory=True)
                with patch.object(b,'source_fingerprint',return_value=identity['source']),patch.object(b,'run_checked',side_effect=install),patch.object(b,'phase_event',side_effect=lambda edition,date,phase,event,**fields:phases.append((event,fields))):
                    with self.assertRaises((ValueError,OSError)):
                        b.prepare_blob_tools(workspace,str(compiler),'testwiktionary','20261001',identity)
                self.assertEqual(phases[-1][1]['status'],'failure');self.assertNotIn('tools',phases[-1][1])
                self.assertEqual(external.read_bytes(),b'external bytes');self.assertEqual(external.stat().st_mode&0o777,0o755)

    def test_bound_tool_replacement_and_write_are_rejected_before_execution(self):
        for change in ('write','replace','chmod','symlink'):
            with self.subTest(change=change),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);tool=fixture_blob_tool(root);path=tool.path
                if change=='write':
                    path.chmod(0o755);path.write_bytes(b'changed content');path.chmod(0o555)
                elif change=='replace':
                    other=root/'replacement';other.write_bytes(path.read_bytes());other.chmod(0o555);os.replace(other,path)
                elif change=='chmod':path.chmod(0o755)
                else:
                    other=root/'other';other.write_bytes(path.read_bytes());other.chmod(0o555);path.unlink();path.symlink_to(other)
                with patch.object(b,'run_checked') as run:
                    with self.assertRaises(ValueError):tool.run(['input'],'testwiktionary','20261001','fixture')
                run.assert_not_called()

    def test_existing_redirected_install_target_is_rejected_before_zig(self):
        for kind in ('symlink','hardlink','directory','nonexecutable'):
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);workspace,compiler,identity=self.fixture(root)
                external=root/'external';external.write_bytes(b'external bytes');external.chmod(0o755)
                target=workspace/'native-blob-tools/bin'/b.BLOB_TOOL_NAMES[0];target.parent.mkdir(parents=True)
                if kind=='symlink':target.symlink_to(external)
                elif kind=='hardlink':os.link(external,target)
                elif kind=='directory':target.mkdir()
                else:target.write_bytes(b'not executable')
                with patch.object(b,'source_fingerprint',return_value=identity['source']),patch.object(b,'run_checked') as run:
                    with self.assertRaises(ValueError):b.prepare_blob_tools(workspace,str(compiler),'testwiktionary','20261001',identity)
                run.assert_not_called();self.assertEqual(external.read_bytes(),b'external bytes')
                self.assertEqual(external.stat().st_mode&0o777,0o755)

    def test_bound_tool_preserves_native_error_and_rejects_midrun_mutation(self):
        for change in (False,True):
            with self.subTest(change=change),tempfile.TemporaryDirectory() as tmp:
                tool=fixture_blob_tool(Path(tmp));error=subprocess.CalledProcessError(7,[str(tool.path)],output=b'out',stderr=b'err')
                def run(argv):
                    if change:tool.path.chmod(0o755)
                    raise error
                with patch.object(b,'run_checked',side_effect=run):
                    if change:
                        with self.assertRaises(ValueError) as failed:tool.run(['exact native argument'],'testwiktionary','20261001','fixture')
                        self.assertIs(failed.exception.__context__,error)
                    else:
                        with self.assertRaises(subprocess.CalledProcessError) as failed:tool.run(['exact native argument'],'testwiktionary','20261001','fixture')
                        self.assertIs(failed.exception,error)
                        self.assertEqual(failed.exception.output,b'out');self.assertEqual(failed.exception.stderr,b'err')

    def test_ordinary_compressed_shards_use_one_bound_set_and_verify_before_retirement(self):
        self.ordinary_compressed_shards(fresh=False)

    def test_fresh_compressed_shards_share_graph_and_preserve_verification_order(self):
        self.ordinary_compressed_shards(fresh=True)

    def ordinary_compressed_shards(self, *, fresh):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);workspace,compiler,identity=self.fixture(root)
            exp=workspace/'expander/.bundle-expander'
            def make_expander():
                exp.mkdir(parents=True)
                (workspace/'expander/.incomplete').write_text('expander ready')
                (exp/'page-index.tsv').write_text('p0\np1\n');(exp/'dict-bundle-expander').write_text('worker');write_namespace_fixture(exp)
            if not fresh:make_expander()
            cached=workspace/'input';cached.mkdir();(cached/'.complete.json').write_text(json.dumps({
                'source_pages':2,'dump_sha256':'a'*64,'index_sha256':'b'*64}))
            staging=root/'staging';calls=[];verified=set();payloads={}
            def run(argv):
                calls.append(argv)
                if 'prepare-blob-tools' in argv:
                    self.assertEqual('build-dictionary' in argv,fresh)
                    args=tool_arguments(argv) if fresh else None
                    self.install(argv,args)
                    if fresh:
                        self.assertEqual(args[:2],[str(root/'dump'),str(workspace/'expander')])
                        self.assertIn('--expander-only',args)
                        self.assertEqual(args[args.index('--verified-dump-sha256')+1],'a'*64)
                        self.assertEqual(args[args.index('--verified-index-sha256')+1],'b'*64)
                        make_expander()
                    return
                self.assertNotIn('build',argv)
                args=argv[1:];name=Path(argv[0]).name
                self.assertEqual(Path(argv[0]).parent,workspace/'native-blob-tools/bin')
                if name=='dict-blob-build':
                    dest=Path(args[1]);dest.mkdir();write_coverage(dest,argv)
                    payload=b'WIKBLB08\x08'+dest.name.encode();payloads[dest]=payload;(dest/'aliases.wikblb').write_bytes(payload)
                elif name=='dict-blob-verify':
                    dest=Path(args[0])
                    if dest==staging:
                        self.assertEqual(lzma.decompress((dest/'aliases.wikblb.xz').read_bytes()),b''.join(payloads.values()))
                    else:self.assertEqual((dest/'aliases.wikblb').read_bytes(),payloads[dest])
                    verified.add(dest)
                elif name=='dict-blob-merge':
                    self.assertEqual(args[0],'--compress-output');self.assertEqual(Path(args[1]),staging)
                    self.assertEqual([Path(x) for x in args[2:]],list(payloads))
                    for shard,payload in payloads.items():
                        self.assertIn(shard,verified);self.assertTrue((shard/'.verified').is_file())
                        self.assertFalse((shard/'aliases.wikblb').exists())
                        self.assertEqual(lzma.decompress((shard/'aliases.wikblb.xz').read_bytes()),payload)
                    staging.mkdir();write_namespace_coverage(staging,2)
                    (staging/'aliases.wikblb.xz').write_bytes(lzma.compress(b''.join(payloads.values())))
                else:self.fail('Unexpected tool '+name)
            def compress(path,block_size,workers):
                self.assertIn(path.parent,verified);self.assertEqual(workers,1)
                Path(str(path)+'.xz').write_bytes(lzma.compress(path.read_bytes()))
            def cleanup(path):
                self.assertEqual(path,workspace);self.assertIn(staging,verified)
                self.assertEqual((staging/b.VERIFIED_MARKER).read_text(),b.VERIFIED_CONTENT)
                self.assertEqual(json.loads((staging/'page-coverage.json').read_text())['pages_seen'],2)
            with patch.object(b,'source_fingerprint',return_value=identity['source']),patch.object(b,'run_checked',side_effect=run), \
                 patch.object(b,'SHARD_PAGES',1),patch.object(b,'compress',side_effect=compress), \
                 patch.object(b,'require_merge_disk_space',return_value={}),patch.object(b,'cleanup_shard_workspace',side_effect=cleanup):
                b.build_sharded(root/'dump',staging,workspace,root/'registry',str(compiler),1,
                    [{'wiki':'testwiktionary','date':'20261001'}],123,compress_shards=True)
            self.assertEqual(sum('prepare-blob-tools' in argv for argv in calls),1)
            self.assertEqual(sum('build-dictionary' in argv for argv in calls),int(fresh))
            self.assertEqual([Path(argv[0]).name for argv in calls[1:]],
                ['dict-blob-build','dict-blob-verify','dict-blob-build','dict-blob-verify','dict-blob-merge','dict-blob-verify'])


class RetainedWorkspaceTests(unittest.TestCase):
    @staticmethod
    def identity(path):
        st=path.stat()
        return dict(path=str(path),device=st.st_dev,inode=st.st_ino,uid=st.st_uid,mode=st.st_mode & 0o7777)

    @contextlib.contextmanager
    def fixture(self):
        with tempfile.TemporaryDirectory() as temporary:
            workspace=Path(temporary)/'workspace';source=workspace/'.tmp/retained'
            (source/'tools').mkdir(parents=True)
            (workspace/'data/dumps').mkdir(parents=True)
            for name,data in (('build.zig','bound graph'),('build.zig.zon','bound package'),
                              ('tools/build_wiktionaries.py','bound builder')):
                (source/name).write_text(data)
            with patch.object(b,'PROJECT',source),patch.object(b,'__file__',str(source/'tools/build_wiktionaries.py')):
                yield workspace,source,self.identity(workspace)

    def test_workspace_binding_rejects_replacement_alias_and_wrong_source(self):
        for change in ('inode','mode','owner','type','extra','relative','symlink','foreign-root','wrong-script'):
            with self.subTest(change=change),self.fixture() as (workspace,source,spec):
                if change=='inode':spec['inode']+=1
                elif change=='mode':spec['mode']^=0o100
                elif change=='owner':spec['uid']+=1
                elif change=='type':spec['inode']=True
                elif change=='extra':spec['unexpected']=1
                elif change=='relative':spec['path']='workspace'
                elif change=='symlink':
                    alias=workspace.parent/'alias';alias.symlink_to(workspace,target_is_directory=True)
                    spec['path']=str(alias)
                elif change=='foreign-root':
                    other=workspace.parent/'other';other.mkdir();spec=self.identity(other)
                if change=='wrong-script':
                    with patch.object(b,'__file__',str(workspace/'tools/build_wiktionaries.py')), self.assertRaises(ValueError):
                        b.workspace_root(spec)
                else:
                    with self.assertRaises(ValueError):b.workspace_root(spec)
        with self.fixture() as (workspace,source,spec):
            self.assertEqual(b.workspace_root(spec),workspace)
            self.assertEqual(b.workspace_root(),source)

    def test_parent_holds_workspace_global_lock_through_original_supervisor(self):
        for mode in ('watchdog','cgroup'):
            for fail in (False,True):
                with self.subTest(mode=mode,fail=fail),self.fixture() as (workspace,source,spec):
                    shared=workspace/'.tmp/build-resources.lock';seen=[]
                    failure=RuntimeError('original supervisor failure')
                    def supervised(**options):
                        seen.append(shared.stat().st_ino)
                        with self.assertRaises(limits.ContainmentUnavailable):b.acquire_build_resource_lock(shared)
                        if mode=='watchdog':
                            self.assertEqual(options,dict(wall_seconds=7200,
                                disk_paths=(workspace/'.tmp',workspace/'data/dictionaries')))
                        else:self.assertEqual(options,{})
                        if fail:raise failure
                        return 0
                    argv=['build_wiktionaries.py','--resource-mode',mode,
                          '--workspace-root-spec',json.dumps(spec)]
                    selected='supervise_watchdog' if mode=='watchdog' else 'supervise'
                    with patch.object(sys,'argv',argv),patch.object(limits,'inside_watchdog',return_value=False), \
                         patch.object(limits,'inside_envelope',return_value=False), \
                         patch.object(limits,selected,side_effect=supervised),patch.object(b,'main') as main:
                        if fail:
                            with self.assertRaises(RuntimeError) as caught:b.cli()
                            self.assertIs(caught.exception,failure)
                        else:
                            with self.assertRaises(SystemExit) as done:b.cli()
                            self.assertEqual(done.exception.code,0)
                        main.assert_not_called()
                    self.assertEqual(seen,[shared.stat().st_ino])
                    self.assertFalse((source/'.tmp/build-resources.lock').exists())
                    with b.acquire_build_resource_lock(shared):pass

    def test_child_rechecks_workspace_identity_before_entering_main(self):
        with self.fixture() as (workspace,source,spec):
            spec['inode']+=1
            argv=['build_wiktionaries.py','--resource-mode=watchdog','--workspace-root-spec',json.dumps(spec)]
            with patch.object(sys,'argv',argv),patch.object(limits,'inside_watchdog',return_value=True), \
                 patch.object(limits,'supervise_watchdog') as supervisor,patch.object(b,'main') as main:
                with self.assertRaisesRegex(SystemExit,'Workspace directory identity changed'):b.cli()
                main.assert_not_called();supervisor.assert_not_called()
            self.assertFalse((workspace/'.tmp/build-resources.lock').exists())

    def test_workspace_defaults_reach_normal_builder_without_changing_source_cwd(self):
        with self.fixture() as (workspace,source,spec):
            downloads=workspace/'data/dumps'
            write_test_manifest(downloads,{'files':[dict(wiki='testwiktionary',date='20261001',name='test.xml.bz2',
                url='https://dumps.wikimedia.org/testwiktionary/20261001/test.xml.bz2',size=1,sha1='a'*40)]})
            argv=['build_wiktionaries.py','--resource-mode=watchdog','--workspace-root-spec',json.dumps(spec),
                  '--threads','1','--jobs','1']
            with patch.object(sys,'argv',argv),patch.object(b,'safe_worker_budget',return_value=1), \
                 patch.object(b,'build_groups',return_value=[]) as groups:
                b.main()
            self.assertEqual(groups.call_args.args[1:3],(downloads,workspace/'data/dictionaries'))
            self.assertEqual(groups.call_args.args[4:],(1,1,None))
            self.assertTrue(groups.call_args.kwargs['edition_options'])
            before=b.source_fingerprint()
            (workspace/'tools').mkdir();(workspace/'tools/later-edit.py').write_text('canonical-only edit')
            self.assertEqual(b.source_fingerprint(),before)
            with patch.object(b.subprocess,'run') as native:
                b.run_checked(['zig','build','build-dictionary'])
            native.assert_called_once_with(['zig','build','build-dictionary'],cwd=source,check=True)
            (source/'build.zig').write_text('actual producer mutation')
            self.assertNotEqual(b.source_fingerprint(),before)

class BorrowedStagedInputTests(PreparedToolsFixture):
    class RouteReached(RuntimeError):pass

    def fixture(self, root):
        folder=root/'testwiktionary/20260901';write_namespace_fixture(folder)
        name='testwiktionary-20260901-pages-meta-current.xml.bz2'
        data=bz2.compress(b'<mediawiki><page>word</page></mediawiki>')
        (folder/name).write_bytes(data)
        item=dict(wiki='testwiktionary',date='20260901',name=name,
                  url='https://dumps.wikimedia.org/testwiktionary/20260901/'+name,
                  size=len(data),sha1=hashlib.sha1(data).hexdigest())
        workspace=root/'original';workspace.mkdir()
        dump=b.cached_shard_dump([item],root,workspace)
        return item,dump.parent

    def identities(self, root):
        return {p.name:(p.read_bytes(),p.stat().st_dev,p.stat().st_ino,p.stat().st_size,
                        p.stat().st_mtime_ns,p.stat().st_ctime_ns)
                for p in (root/name for name in ('pages.xml.zst','pages-index.txt.bz2','.complete.json'))}

    def test_reuses_one_real_repack_without_link_copy_or_physical_change(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            with patch.object(b,'stage_seekable_dump',wraps=b.stage_seekable_dump) as stage:
                item,borrowed=self.fixture(root);before=self.identities(borrowed)
                for outcome in ('success','failure'):
                    with self.subTest(outcome=outcome):
                        try:
                            with b.borrowed_staged_input([item],borrowed,root/'new-output') as (selected,check):
                                self.assertEqual(selected,borrowed)
                                b.validated_staged_dump([item],selected)
                                if outcome=='failure':raise self.RouteReached()
                        except self.RouteReached:pass
                        self.assertEqual(self.identities(borrowed),before)
                self.assertEqual(stage.call_count,1)

    def test_rejects_invalid_marker_dump_and_index_without_repair(self):
        for mode in ('marker','input','dump','index','symlink'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);item,borrowed=self.fixture(root)
                if mode=='marker':(borrowed/'.complete.json').write_text('{')
                if mode=='input':
                    path=borrowed/'.complete.json';row=json.loads(path.read_text());row['input_sha256']='0'*64;path.write_text(json.dumps(row))
                if mode in ('dump','index'):
                    path=borrowed/('pages.xml.zst' if mode=='dump' else 'pages-index.txt.bz2')
                    data=bytearray(path.read_bytes());data[-1]^=1;path.write_bytes(data)
                if mode=='symlink':
                    path=borrowed/'pages.xml.zst';data=path.read_bytes();path.unlink();other=root/'other';other.write_bytes(data);path.symlink_to(other)
                def stamps():
                    return {p.name:tuple(getattr(p.lstat(),k) for k in ('st_dev','st_ino','st_mode','st_size','st_mtime_ns','st_ctime_ns')) for p in borrowed.iterdir()}
                before=stamps()
                with patch.object(b,'stage_seekable_dump',side_effect=AssertionError('borrowed input repaired')):
                    with self.assertRaises((ValueError,OSError)):
                        with b.borrowed_staged_input([item],borrowed,root/'new-output'):self.fail('invalid input borrowed')
                self.assertEqual(stamps(),before)

    def test_borrowed_root_survives_owned_cleanup_success_and_failure(self):
        for failure in (False,True):
            with self.subTest(failure=failure),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);item,borrowed=self.fixture(root);before=self.identities(borrowed)
                output=root/'output';workspace=output/item['wiki']/(item['date']+'.shards')
                def finish(*args):
                    workspace.mkdir(parents=True);(workspace/'input').mkdir();(workspace/'input/owned').write_bytes(b'owned')
                    b.cleanup_shard_workspace(workspace)
                    if failure:raise self.RouteReached()
                    return 'fresh_production'
                with patch.object(b,'_build_locked',side_effect=finish):
                    if failure:
                        with self.assertRaises(self.RouteReached):b.build_locked([item],root,output,'never-executed',staged_input_root=borrowed)
                    else:self.assertEqual(b.build_locked([item],root,output,'never-executed',staged_input_root=borrowed),'fresh_production')
                self.assertFalse(workspace.exists());self.assertEqual(self.identities(borrowed),before)

    def test_owned_path_overlap_and_in_use_mutation_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);item,borrowed=self.fixture(root)
            with self.assertRaisesRegex(ValueError,'overlaps'):
                with b.borrowed_staged_input([item],borrowed,root,raw_shard_root=borrowed.parent):pass
            with self.assertRaisesRegex(ValueError,'changed during build'):
                with b.borrowed_staged_input([item],borrowed,root/'new-output'):
                    path=borrowed/'pages.xml.zst';old=path.stat();data=path.read_bytes();path.write_bytes(data)
                    os.utime(path,ns=(old.st_atime_ns,old.st_mtime_ns))

    def test_original_dump_and_hashes_reach_both_native_preparation_routes(self):
        for sharded in (False,True):
            with self.subTest(sharded=sharded),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);item,borrowed=self.fixture(root);before=self.identities(borrowed)
                tool=root/'zig';tool.write_bytes(b'fixture compiler identity');tool.chmod(0o700)
                record=json.loads((borrowed/'.complete.json').read_text());calls=[]
                def check(argv):
                    self.assertEqual(argv[0],str(borrowed/'pages.xml.zst'))
                    self.assertEqual(argv[argv.index('--verified-dump-sha256')+1],record['dump_sha256'])
                    self.assertEqual(argv[argv.index('--verified-index-sha256')+1],record['index_sha256'])
                    calls.append(argv);raise self.RouteReached()
                def one_shot(argv,*args,**kwargs):check(tool_arguments(argv))
                def preparation(*args,**kwargs):check(kwargs['expander_args'])
                with patch.object(b,'PROJECT',root),patch.object(b,'source_fingerprint',return_value='source'), \
                     patch.object(b,'SHARD_PAGES',0 if sharded else 100000), \
                     patch.object(b,'stage_seekable_dump',side_effect=AssertionError('duplicate repack')), \
                     patch.object(b,'timed_run',side_effect=one_shot),patch.object(b,'prepare_blob_tools',side_effect=preparation):
                    with self.assertRaises(self.RouteReached):
                        b.build([item],root,root/'output',str(tool),1,staged_input_root=borrowed)
                self.assertEqual(len(calls),1);self.assertEqual(self.identities(borrowed),before)
                self.assertFalse((root/'output'/item['wiki']/(item['date']+'.shards')/'input/pages.xml.zst').exists())

    def test_explicit_cli_and_scheduler_forward_one_selected_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);item,borrowed=self.fixture(root);write_test_manifest(root,dict(files=[item]))
            argv=['build_wiktionaries.py','--downloads',str(root),'--output',str(root/'output'),
                  '--wikis','testwiktionary','--threads','1','--jobs','1','--staged-input-root',str(borrowed)]
            with patch.object(sys,'argv',argv),patch.object(b,'safe_worker_budget',return_value=4),patch.object(b,'build_groups',return_value=[]) as groups:
                b.main()
            self.assertEqual(groups.call_args.kwargs['staged_input_root'],borrowed)
            with patch.object(b,'build',return_value=None) as build,patch.object(b,'safe_worker_budget',return_value=4):
                self.assertEqual(b.build_groups({('testwiktionary','20260901'):[item]},root,root/'output','zig',1,1,staged_input_root=borrowed),[])
            self.assertEqual(build.call_args.kwargs['staged_input_root'],borrowed)
            with self.assertRaisesRegex(ValueError,'exactly one edition'):
                b.build_groups({('testwiktionary','20260901'):[item],('other','20260901'):[item]},root,root/'output','zig',1,1,staged_input_root=borrowed)

    def test_borrowed_repack_survives_real_sharded_publication_and_merge_retry(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True);write_namespace_fixture(folder)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            data=bz2.compress(b'<mediawiki><page>word</page><page>second</page></mediawiki>')
            (folder/name).write_bytes(data)
            item=dict(wiki='testwiktionary',date='20260901',name=name,
                      url='https://dumps.wikimedia.org/testwiktionary/20260901/'+name,
                      size=len(data),sha1=hashlib.sha1(data).hexdigest())
            (folder/'language-registry.tsv').write_text('# content-language\ten\nen\tEnglish\n')
            original=root/'original';original.mkdir()
            borrowed=b.cached_shard_dump([item],root,original).parent
            before=self.identities(borrowed)
            merges=[]
            def run(command):
                if 'build-dictionary' in command:
                    dest=Path(tool_arguments(command)[1]);exp=dest/'.bundle-expander';exp.mkdir(parents=True)
                    (dest/'.incomplete').write_text('expander ready')
                    (exp/'page-index.tsv').write_text('0\n1\n')
                    (exp/'dict-bundle-expander').write_text('worker');write_namespace_fixture(exp)
                elif blob_command(command,'build-blobs'):
                    dest=Path(tool_arguments(command)[1]);dest.mkdir(parents=True,exist_ok=True)
                    write_coverage(dest,command)
                elif blob_command(command,'merge-blobs'):
                    merges.append(command)
                    if len(merges)==1:raise subprocess.CalledProcessError(1,command)
                    dest=Path(tool_arguments(command)[0]);dest.mkdir()
                    (dest/'fallback-pages.jsonl').write_text('')
                    if blob_command(command,'merge-blobs'):write_namespace_coverage(dest,sum(json.loads((Path(x)/'page-coverage.json').read_text())['pages_seen'] for x in tool_arguments(command)[1:]))
            real_stage=b.stage_seekable_dump
            with patch.object(b,'PROJECT',root), \
                 patch.object(b,'SHARD_PAGES',1),patch.object(b,'source_fingerprint',return_value='source'), \
                 patch.object(b.time,'time',return_value=123),patch.object(b,'run_checked',side_effect=run), \
                 patch.object(b,'stage_seekable_dump',wraps=real_stage) as stage:
                with self.assertRaises(subprocess.CalledProcessError):
                    b.build([item],root,root/'output','zig',1,staged_input_root=borrowed)
                workspace=root/'output/testwiktionary/20260901.shards'
                self.assertTrue((borrowed/'.complete.json').is_file())
                self.assertFalse((workspace/'input/pages.xml.zst').exists())
                self.assertEqual(stage.call_count,0)
                b.build([item],root,root/'output','zig',1,staged_input_root=borrowed)
                self.assertEqual(stage.call_count,0)
                self.assertEqual(len(merges),2)
                self.assertFalse(workspace.exists())
                self.assertTrue((root/'output/testwiktionary/20260901/complete.json').is_file())

                self.assertEqual(self.identities(borrowed),before)

    def test_preseal_input_mutation_cannot_publish_or_mark_verified(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True);write_namespace_fixture(folder)
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            data=bz2.compress(b'<mediawiki><page>word</page><page>second</page></mediawiki>')
            (folder/name).write_bytes(data)
            item=dict(wiki='testwiktionary',date='20260901',name=name,
                      url='https://dumps.wikimedia.org/testwiktionary/20260901/'+name,
                      size=len(data),sha1=hashlib.sha1(data).hexdigest())
            (folder/'language-registry.tsv').write_text('# content-language\ten\nen\tEnglish\n')
            original=root/'original';original.mkdir()
            borrowed=b.cached_shard_dump([item],root,original).parent
            before=self.identities(borrowed)
            merges=[]
            def run(command):
                if 'build-dictionary' in command:
                    dest=Path(tool_arguments(command)[1]);exp=dest/'.bundle-expander';exp.mkdir(parents=True)
                    (dest/'.incomplete').write_text('expander ready')
                    (exp/'page-index.tsv').write_text('0\n1\n')
                    (exp/'dict-bundle-expander').write_text('worker');write_namespace_fixture(exp)
                elif blob_command(command,'build-blobs'):
                    dest=Path(tool_arguments(command)[1]);dest.mkdir(parents=True,exist_ok=True)
                    write_coverage(dest,command)
                elif blob_command(command,'verify-blobs') and Path(tool_arguments(command)[0]).name=='20260901.building':
                    path=borrowed/'pages.xml.zst';data=bytearray(path.read_bytes());data[-1]^=1;path.write_bytes(data)
                elif blob_command(command,'merge-blobs'):
                    merges.append(command)
                    if len(merges)==1:raise subprocess.CalledProcessError(1,command)
                    dest=Path(tool_arguments(command)[0]);dest.mkdir()
                    (dest/'fallback-pages.jsonl').write_text('')
                    if blob_command(command,'merge-blobs'):write_namespace_coverage(dest,sum(json.loads((Path(x)/'page-coverage.json').read_text())['pages_seen'] for x in tool_arguments(command)[1:]))
            real_stage=b.stage_seekable_dump
            with patch.object(b,'PROJECT',root), \
                 patch.object(b,'SHARD_PAGES',1),patch.object(b,'source_fingerprint',return_value='source'), \
                 patch.object(b.time,'time',return_value=123),patch.object(b,'run_checked',side_effect=run), \
                 patch.object(b,'stage_seekable_dump',wraps=real_stage) as stage:
                with self.assertRaises(subprocess.CalledProcessError):
                    b.build([item],root,root/'output','zig',1,staged_input_root=borrowed)
                workspace=root/'output/testwiktionary/20260901.shards'
                self.assertTrue((borrowed/'.complete.json').is_file())
                self.assertFalse((workspace/'input/pages.xml.zst').exists())
                self.assertEqual(stage.call_count,0)
                with self.assertRaisesRegex(ValueError,'changed during build'):
                    b.build([item],root,root/'output','zig',1,staged_input_root=borrowed)
                self.assertEqual(stage.call_count,0)
                self.assertEqual(len(merges),2)
                staging=root/'output/testwiktionary/20260901.building'
                self.assertFalse((staging/b.VERIFIED_MARKER).exists())
                self.assertFalse((staging/'complete.json').exists())
                self.assertFalse((root/'output/testwiktionary/20260901').exists())

    def test_resolved_write_cache_and_recorded_raw_overlap_refuse_before_writes(self):
        for mode in ('cache','resolved-output','recorded-raw'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);item,borrowed=self.fixture(root);before=self.identities(borrowed)
                output=root/'new-output';options={}
                if mode=='cache':options['extraction_cache_root']=borrowed/'new-cache'
                if mode=='resolved-output':
                    alias=root/'alias';alias.symlink_to(borrowed,target_is_directory=True);output=alias/'output'
                if mode=='recorded-raw':
                    workspace=output/item['wiki']/(item['date']+'.shards');workspace.mkdir(parents=True)
                    (workspace/'state.json').write_text(json.dumps(dict(raw_shards_path=str(borrowed.parent))))
                with patch.object(b,'_build_locked',side_effect=AssertionError('owned writes entered')):
                    with self.assertRaisesRegex(ValueError,'overlaps'):
                        b.build([item],root,output,'never-executed',staged_input_root=borrowed,**options)
                self.assertEqual(self.identities(borrowed),before)
                self.assertFalse((borrowed/'new-cache').exists());self.assertFalse((borrowed/'output').exists())

    def test_postcheck_keeps_original_build_exception_as_context(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);item,borrowed=self.fixture(root);original=self.RouteReached('original build failure')
            def fail(*args):
                (borrowed/'pages.xml.zst').write_bytes(b'changed source')
                raise original
            with patch.object(b,'_build_locked',side_effect=fail):
                with self.assertRaisesRegex(ValueError,'changed during build') as failed:
                    b.build_locked([item],root,root/'output','never-executed',staged_input_root=borrowed)
            self.assertIs(failed.exception.__context__,original)


class PresentationContinuationTests(PreparedToolsFixture):
    def exercise(self, mode, budget):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'testwiktionary/20260901';folder.mkdir(parents=True)
            write_namespace_fixture(folder)
            (folder/'language-registry.tsv').write_text('# content-language\ten\nen\tEnglish\n')
            name='testwiktionary-20260901-pages-meta-current.xml.bz2'
            data=bz2.compress(b'<mediawiki>'+b'<page>fixture</page>'*6+b'</mediawiki>')
            (folder/name).write_bytes(data)
            item=dict(wiki='testwiktionary',date='20260901',name=name,
                url='https://dumps.wikimedia.org/testwiktionary/20260901/'+name,
                size=len(data),sha1=hashlib.sha1(data).hexdigest())
            zig=root/'fixture-zig'
            zig.write_bytes(b'fixture compiler identity; native execution is mocked\n');zig.chmod(0o555)
            output=root/'output';workspace=output/'testwiktionary/20260901.shards'
            calls=[];events=[];audit_roots=[];native_failure=[]
            def run(command):
                calls.append(command)
                args=tool_arguments(command)
                if 'build-dictionary' in command:
                    dest=Path(args[1]);exp=dest/'.bundle-expander';exp.mkdir(parents=True)
                    (dest/'.incomplete').write_text('expander ready')
                    (exp/'page-index.tsv').write_text('0\n1\n2\n3\n4\n5\n')
                    (exp/'dict-bundle-expander').write_text('worker');write_namespace_fixture(exp)
                elif blob_command(command,'build-blobs'):
                    dest=Path(args[1])
                    if '--audit-presentation-errors' in args:
                        audit_roots.append(dest)
                        # Real edition lock must remain owned after production
                        # phase failure and throughout diagnostic continuation.
                        with (output/'testwiktionary/20260901.lock').open('a') as competing:
                            with self.assertRaises(BlockingIOError):
                                b.fcntl.flock(competing,b.fcntl.LOCK_EX|b.fcntl.LOCK_NB)
                        self.assertEqual([e[3].get('status') for e in events if e[:3]==('testwiktionary','20260901','edition_build') and e[3]['event']=='end'],['failure'])
                        self.assertEqual(args[args.index('--start-page')+1],'2')
                        count=min(budget,4)
                        self.assertEqual(args[args.index('--limit-pages')+1],str(count))
                        self.assertEqual(args[args.index('--now-unix')+1],'123')
                        self.assertEqual(args[args.index('--expansion-timeout-ms')+1],'60000')
                        self.assertEqual(args[args.index('--workers')+1],'2')
                        for flag in ('--shard-pages','--index-byte-offset','--failure-receipt','--invocation-id'):
                            self.assertNotIn(flag,args)
                        self.assertEqual(args[0],native_failure[0][0])
                        self.assertEqual(args[args.index('--expander-root')+1],native_failure[0][native_failure[0].index('--expander-root')+1])
                        self.assertNotEqual(dest,Path(native_failure[0][1]))
                        dest.mkdir()
                        if mode=='signal': raise subprocess.CalledProcessError(-9,command)
                        failed=0 if mode=='zero' else 1
                        row=dict(schema='wikidict.presentation-audit.summary.v1',diagnostic_only=True,
                            inventory_complete=False,range_complete=mode!='incomplete',failure_index_complete=True,audit_scope='page-range',
                            start_page=2,requested_limit=count,selected_end_exclusive=2+count,
                            reached_eof=count==4,index_rows_seen=6 if count==4 else 3+count,
                            semantic_acceptance=False,publication_created=False,error_name=None,
                            selected=count,dispatched=count,consumed=count,skipped=0,direct_aliases=0,
                            expansion_fallbacks=0,compile_attempts=count,succeeded=count-failed,
                            failed=failed,failure_records=failed,payload_bytes=0,report_bytes=0)
                        if mode=='missing-field': del row['error_name']
                        if mode=='missing-index': del row['failure_index_complete']
                        if mode=='index-incomplete': row['failure_index_complete']=False
                        if mode=='counts': row['consumed']-=1
                        if mode=='publish': row['publication_created']=True
                        (dest/'audit-summary.json').write_text(json.dumps(row))
                        (dest/'failures.jsonl').write_text('')
                        if mode=='source-change':
                            (Path(args[args.index('--expander-root')+1])/'page-index.tsv').write_text('changed')
                        if mode=='tool-change':
                            tool=Path(command[0]);tool.chmod(0o755);tool.write_bytes(b'changed native tool')
                        if failed: raise subprocess.CalledProcessError(1,command)
                        return
                    dest.mkdir(parents=True,exist_ok=True)
                    start=int(args[args.index('--start-page')+1])
                    if start==0:
                        write_coverage(dest,command);return
                    self.assertEqual(start,2)
                    native_failure.append(args)
                    invocation=args[args.index('--invocation-id')+1]
                    receipt=Path(args[args.index('--failure-receipt')+1])
                    receipt.write_text(json.dumps(dict(schema='wikidict.blob-build.failure.v1',
                        error_name='UncompiledPresentation',failure_class='deterministic-presentation',
                        invocation_id=invocation,invocation_args=args,
                        page=dict(ordinal=3,namespace=0,title='failure',page_id=7,revision_id=9))))
                    raise subprocess.CalledProcessError(-9 if mode=='production-signal' else 1,command)
                elif blob_command(command,'merge-blobs'):
                    self.fail('failed edition must never reach merge')
            original_cleanup=b.cleanup_incomplete_shard_payload
            def cleanup(*args,**kwargs):
                if mode=='retention-io':raise OSError('diagnostic retention I/O failure')
                if mode=='retention-ownership':raise ValueError('diagnostic retention ownership changed')
                return original_cleanup(*args,**kwargs)
            def event(edition,date,phase,event,**fields):
                events.append((edition,date,phase,dict(event=event,**fields)))
            with patch.object(b,'PROJECT',root),patch.object(b,'SHARD_PAGES',2), \
                 patch.object(b,'source_fingerprint',return_value='source'),patch.object(b.time,'time',return_value=123), \
                 patch.object(b,'run_checked',side_effect=run),patch.object(b,'phase_event',side_effect=event), \
                 patch.object(b,'cleanup_incomplete_shard_payload',side_effect=cleanup), \
                 patch.object(b,'publish_verified_staging') as publish:
                with self.assertRaises(b.DeterministicPresentationFailure) as failed:
                    b.build([item],root,output,str(zig),1,expansion_workers=2,expansion_timeout_ms=60000,
                            presentation_audit_pages=budget)
                publish.assert_not_called()
            blocked=mode in ('production-signal','retention-io','retention-ownership')
            self.assertEqual(len(native_failure),1);self.assertEqual(len(audit_roots),0 if blocked else 1)
            self.assertIs(failed.exception.presentation_continuation_safe,not blocked)
            self.assertEqual(failed.exception.returncode,-9 if mode=='production-signal' else 1)
            self.assertTrue(Path(failed.exception.failure_receipt).is_file())
            self.assertFalse((output/'testwiktionary/20260901/complete.json').exists())
            self.assertTrue((workspace/'shards/00000000/.verified').exists())
            self.assertFalse((workspace/'shards/00000002/.verified').exists())
            self.assertEqual(sum('build-dictionary' in c for c in calls),1)
            self.assertTrue((workspace/'input/.complete.json').exists())
            audit_ends=[e[3] for e in events if e[2]=='presentation_diagnostic_continuation' and e[3]['event']=='end']
            if blocked:
                self.assertEqual(audit_ends,[])
                self.assertIsNone(failed.exception.presentation_audit)
                self.assertIsInstance(failed.exception.__cause__,subprocess.CalledProcessError)
                if mode.startswith('retention-'):
                    cleanup_path=Path(failed.exception.failure_receipt).parent/'payload-cleanup.json'
                    row=json.loads(cleanup_path.read_text())
                    self.assertEqual(row['status'],'cleanup-error')
                    self.assertIn('diagnostic retention',row['error'])
                with (output/'testwiktionary/20260901.lock').open('a') as released:
                    b.fcntl.flock(released,b.fcntl.LOCK_EX|b.fcntl.LOCK_NB)
                return
            self.assertEqual(len(audit_ends),1)
            self.assertEqual(audit_ends[0]['unrun_suffix_pages'],max(0,4-budget))
            if mode in ('complete','zero'):
                self.assertEqual(audit_ends[0]['status'],'success')
                self.assertEqual(audit_ends[0]['failed'],0 if mode=='zero' else 1)
            else:
                self.assertEqual(audit_ends[0]['status'],'failure')
                self.assertIsNotNone(failed.exception.__cause__)
                self.assertTrue(any('continuation incomplete' in note for note in failed.exception.__notes__))
            with (output/'testwiktionary/20260901.lock').open('a') as released:
                b.fcntl.flock(released,b.fcntl.LOCK_EX|b.fcntl.LOCK_NB)

    def test_failed_shard_continuation_reuses_tools_and_range_without_publication(self):
        for mode,budget in (('complete',99),('complete',1),('zero',99)):
            with self.subTest(mode=mode,budget=budget): self.exercise(mode,budget)

    def test_incomplete_signal_changed_source_or_tool_preserves_original_failure(self):
        for mode in ('incomplete','missing-field','missing-index','index-incomplete','counts','publish','signal','source-change','tool-change'):
            with self.subTest(mode=mode): self.exercise(mode,99)

    def test_explicit_audit_budget_cli_scheduler_and_prewrite_validation(self):
        root=Path('/unused-audit-budget-control')
        for value in (0,-1,True,1.5,1<<63):
            for entry,args in ((b.build,([],root,root/'out','zig')),
                               (b.build_locked,([],root,root/'out','zig')),
                               (b.build_groups,({},root,root/'out','zig',1,1))):
                with self.subTest(value=value,entry=entry.__name__):
                    with self.assertRaisesRegex(ValueError,'Presentation audit pages'):
                        entry(*args,presentation_audit_pages=value)
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            write_test_manifest(root,{'files':[dict(wiki='testwiktionary',date='20261001',name='test.xml.bz2',
                url='https://dumps.wikimedia.org/testwiktionary/20261001/test.xml.bz2',size=1,sha1='a'*40)]})
            argv=['build_wiktionaries.py','--downloads',str(root),'--output',str(root/'out'),
                  '--threads','1','--jobs','1','--presentation-audit-pages','25']
            with contextlib.chdir(root),patch.object(b,'PROJECT',root),patch.object(sys,'argv',argv), \
                 patch.object(b,'safe_worker_budget',return_value=1),patch.object(b,'build_groups',return_value=[]) as groups:
                b.main()
            self.assertEqual(groups.call_args.kwargs['presentation_audit_pages'],25)
            with patch.object(b,'safe_worker_budget',return_value=1),patch.object(b,'build',return_value='built') as build:
                b.build_groups({('testwiktionary','20261001'):['item']},root,root/'out','zig',1,1,presentation_audit_pages=25)
            self.assertEqual(build.call_args.kwargs['presentation_audit_pages'],25)



    def test_signaled_or_failed_diagnostic_retention_stops_before_continuation(self):
        # The pristine positive baseline uses this exact fixture and matched
        # receipt, so each refusal reaches the intended post-command boundary.
        self.exercise('complete',99)
        for mode in ('production-signal','retention-io','retention-ownership'):
            with self.subTest(mode=mode):self.exercise(mode,99)


class PreparedSourceCallerTests(unittest.TestCase):
    @contextlib.contextmanager
    def generation_fixture(self):
        import copy
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); project=root/'project'; (project/'tools').mkdir(parents=True)
            helper=project/'tools'/'custody_fixture_helper.py'; helper.write_text('VALUE = 1\n'); helper.chmod(0o644)
            workspace=root/'edition.shards'; expander=workspace/'expander'/'.bundle-expander'
            expander.mkdir(parents=True); dump=root/'pages.xml.zst'; dump.write_bytes(b'fixture dump')
            state=dict(version=3,source='1'*64,production_source='2'*64,now_unix=1234)
            (workspace/'state.json').write_text(json.dumps(state))
            archive=root/'retained-seal.json'; archive.write_text('{}\n')
            seal_ref=b.prepared_metadata_ref(archive)
            identity=dict(source='1'*64,files=[],zig_sha256='3'*64)
            source=dict(head='old-qualified-head',fingerprint=identity['source'],inventory={})
            tools={}
            for name in b.BLOB_TOOL_NAMES:
                path=workspace/'native-blob-tools'/'bin'/name; path.parent.mkdir(parents=True,exist_ok=True)
                path.write_bytes(('fixture '+name).encode()); path.chmod(0o555)
                tool=b.PreparedBlobTool(path)
                tools[name]=dict(path=str(path),stamp=list(tool.stamp),sha256=tool.sha256,libraries=[])
            seal=dict(identity=dict(runtime_libraries=dict(libraries=[]),producer=dict(unicode={'libraries':[]})))
            observed=[]
            def frozen(actual_root,actual_dump,actual_sha):
                self.assertEqual((expander,dump,seal_ref['sha256']),(actual_root,actual_dump,actual_sha))
                observed.append((actual_root,actual_dump,actual_sha))
                return copy.deepcopy(seal)
            cache=SimpleNamespace(frozen_runtime_context=frozen,unicode_case_identity=lambda:{'libraries':[]},
                tool_identity=lambda *args:copy.deepcopy(seal['identity']['runtime_libraries']))
            record=dict(schema='wikidict.prepared-source-generation.v1',source=source,
                build_identity=identity,now_unix=1234,context='4'*64,workspace=str(workspace),
                dump=str(dump),expander=str(expander),workspace_state=state,
                python={'tools/custody_fixture_helper.py':dict(sha256=b.sha256_file(helper),mode=0o644)},
                tools=tools,seal_sha256=seal_ref['sha256'],seal_archive=seal_ref)
            cfg=dict(source=source,now_unix=1234,prepared_source_custody=True,build_timeout_seconds=5)
            start=dict(context='4'*64)
            generation_path=root/'prepared-generation.json'; b.write_prepared_metadata(generation_path,record)
            generation_ref=b.prepared_metadata_ref(generation_path)
            launch=root/'launch.json'
            authorization=dict(schema='wikidict.prepared-source-authorization.v1',configuration=cfg,
                context=start['context'],attempt_start=start,generation=generation_ref,
                decision='parent-verified-original-source',original_source_observation=dict(
                    qualified_head=source['head'],producer_inventory=source['inventory'],apps_acceptance=False))
            b.write_prepared_metadata(launch,dict(identity={'fixture':True},prepared_source_authorization=authorization))
            with patch.object(b,'PROJECT',project),patch.dict(sys.modules,{'extraction_cache':cache}):
                generation=b.prepared_authorized_generation(cfg,start,b.prepared_metadata_ref(launch))
                yield SimpleNamespace(root=root,project=project,helper=helper,workspace=workspace,
                    cfg=cfg,start=start,record=record,identity=identity,generation=generation,
                    generation_ref=generation_ref,launch=launch,observed=observed,cache=cache)

    def test_parent_authorization_binds_original_attempt_configuration_and_generation(self):
        import copy
        with self.generation_fixture() as f:
            self.assertEqual(f.identity,f.generation.identity)
            self.assertTrue(f.observed)
            for mutation in ('configuration','attempt','context','decision','generation'):
                with self.subTest(mutation=mutation):
                    launch=b.prepared_metadata(b.prepared_metadata_ref(f.launch))
                    auth=launch['prepared_source_authorization']
                    if mutation=='configuration':auth['configuration']['now_unix']+=1
                    elif mutation=='attempt':auth['attempt_start']={'context':'wrong'}
                    elif mutation=='context':auth['context']='wrong'
                    elif mutation=='decision':auth['decision']='child-ready-only'
                    else:auth['generation']=dict(f.generation_ref,sha256='0'*64)
                    path=f.root/('wrong-'+mutation+'.json'); b.write_prepared_metadata(path,launch)
                    with self.assertRaises(ValueError):
                        b.prepared_authorized_generation(copy.deepcopy(f.cfg),copy.deepcopy(f.start),b.prepared_metadata_ref(path))

    def test_same_generation_scope_avoids_current_source_walk_and_forbids_reprepare(self):
        with self.generation_fixture() as f:
            with patch.object(b._PREPARED_SOURCE,'value',f.generation,create=True):
                (f.project/'unrelated.zig').write_text('new unrelated compiler work\n')
                self.assertEqual((f.identity['source'],'2'*64),b._source_fingerprints(include_production=True))
                with patch.object(b,'run_checked',side_effect=AssertionError('must not compile')):
                    with self.assertRaisesRegex(ValueError,'cannot silently prepare'):
                        b.prepare_blob_tools(f.workspace,'zig','toy','date',f.identity)
                with self.assertRaisesRegex(ValueError,'mix original'):
                    f.generation.require_identity(dict(f.identity,source='5'*64))
            self.assertIsNone(getattr(b._PREPARED_SOURCE,'value',None))

    def test_scope_refuses_python_tool_and_workspace_drift_before_native_dispatch(self):
        from importlib.machinery import EXTENSION_SUFFIXES
        for name in ('unbound.pyc','unbound'+EXTENSION_SUFFIXES[0]):
            with self.subTest(name=name),self.generation_fixture() as f:
                (f.project/'tools'/name).write_bytes(b'never imported')
                with self.assertRaisesRegex(ValueError,'Unbound Python import artifact'):
                    f.generation.require_unchanged(full_context=False)
        with self.generation_fixture() as f:
            with patch.object(b._PREPARED_SOURCE,'value',f.generation,create=True):
                f.helper.write_text('VALUE = 2\n')
                with patch.object(b,'timed_run',side_effect=AssertionError('must not dispatch')):
                    with self.assertRaisesRegex(ValueError,'Python helper changed'):
                        next(iter(f.generation.tools.values())).run([], 'toy','date','fixture')
        with self.generation_fixture() as f:
            tool=next(iter(f.generation.tools.values())); tool.path.chmod(0o755)
            with self.assertRaisesRegex(ValueError,'Prepared native tool'):
                f.generation.require_unchanged()
        with self.generation_fixture() as f:
            state=dict(f.record['workspace_state'],now_unix=1235)
            (f.workspace/'state.json').write_text(json.dumps(state))
            with self.assertRaisesRegex(ValueError,'shard state changed'):
                f.generation.require_unchanged()

    def test_scope_guards_before_and_after_actual_prepared_tool_boundary(self):
        with self.generation_fixture() as f:
            tool=next(iter(f.generation.tools.values()))
            with patch.object(b._PREPARED_SOURCE,'value',f.generation,create=True):
                def mutate(*args,**kwargs):f.helper.write_text('VALUE = 2\n')
                with patch.object(b,'timed_run',side_effect=mutate) as command:
                    with self.assertRaisesRegex(ValueError,'Python helper changed'):
                        tool.run([], 'toy','date','fixture')
                self.assertEqual(1,command.call_count)

    def test_finalization_keeps_original_identity_and_prohibits_further_native_work(self):
        with self.generation_fixture() as f:
            staging=f.root/'verified-staging'; staging.mkdir()
            (staging/b.VERIFIED_MARKER).write_text(b.VERIFIED_CONTENT)
            (staging/b.BUILD_IDENTITY_NAME).write_text(json.dumps(f.identity))
            with patch.object(b._PREPARED_SOURCE,'value',f.generation,create=True):
                f.generation.finalize(staging)
                b.require_build_source(f.identity)
                with patch.object(b,'timed_run',side_effect=AssertionError('must not dispatch')):
                    with self.assertRaisesRegex(ValueError,'already been finalized'):
                        next(iter(f.generation.tools.values())).run([], 'toy','date','fixture')
                f.helper.write_text('VALUE = 2\n')
                with self.assertRaisesRegex(ValueError,'Python helper changed'):
                    b.require_build_source(f.identity)
        with self.generation_fixture() as f:
            with self.assertRaisesRegex(ValueError,'verified original staging'):
                f.generation.finalize(f.root)

    def test_missing_seal_and_runtime_drift_are_not_authorization_or_cache_reset(self):
        with self.generation_fixture() as f:
            f.cache.frozen_runtime_context=lambda *args:None
            with self.assertRaisesRegex(ValueError,'no complete generation seal'):
                f.generation.require_unchanged()
            self.assertTrue(f.workspace.is_dir())
        with self.generation_fixture() as f:
            f.cache.unicode_case_identity=lambda:{'libraries':['changed']}
            with self.assertRaisesRegex(ValueError,'Unicode runtime changed'):
                f.generation.require_unchanged()
    def test_stable_command_guards_read_zero_python_payloads_then_force_final_bytes(self):
        with self.generation_fixture() as f:
            reads=[]; real=b.sha256_file
            def digest(path):
                if Path(path)==f.helper:reads.append(f.helper.stat().st_size)
                return real(path)
            with patch.object(b,'sha256_file',side_effect=digest):
                with patch.object(b._PREPARED_SOURCE,'value',f.generation,create=True):
                    with patch.object(b,'timed_run') as run:
                        tool=next(iter(f.generation.tools.values()))
                        for _ in range(3):tool.run([], 'toy','date','fixture')
                    self.assertEqual(3,run.call_count)
                    self.assertEqual([],reads)
                    staging=f.root/'staging'; staging.mkdir()
                    (staging/b.VERIFIED_MARKER).write_text(b.VERIFIED_CONTENT)
                    (staging/b.BUILD_IDENTITY_NAME).write_text(json.dumps(f.identity))
                    f.generation.finalize(staging)
                    self.assertEqual([f.helper.stat().st_size],reads)

    def test_same_byte_python_replacement_is_drift_within_the_original_source_lease(self):
        with self.generation_fixture() as f:
            original=f.helper.stat(); data=f.helper.read_bytes()
            replacement=f.helper.with_suffix('.replacement')
            replacement.write_bytes(data); replacement.chmod(0o644)
            os.utime(replacement,ns=(original.st_atime_ns,original.st_mtime_ns))
            os.replace(replacement,f.helper)
            with self.assertRaisesRegex(ValueError,'Python helper changed'):
                f.generation.require_unchanged(full_context=False)


    def test_outer_retry_reopens_original_generation_before_workspace_or_preparation(self):
        with self.generation_fixture() as f:
            old_start=f.root/'start.json'; b.write_prepared_metadata(old_start,f.start)
            resume=dict(start=b.prepared_metadata_ref(old_start),authorization=b.prepared_metadata_ref(f.launch))
            second=f.root/'second-attempt';second.mkdir()
            prefix=str(second/'unwritten-python-cache')
            start=dict(context=f.start['context'],prepared_source_control=dict(version=1,
                configuration=f.cfg,resume=resume,bytecode_prefix=prefix))
            start_path=second/'start.json';b.write_prepared_metadata(start_path,start)
            authorization=dict(schema='wikidict.prepared-source-authorization.v1',configuration=f.cfg,
                context=start['context'],attempt_start=start,generation=f.generation_ref,
                decision='parent-verified-original-source',original_source_observation=dict(
                    qualified_head=f.cfg['source']['head'],producer_inventory=f.cfg['source']['inventory'],apps_acceptance=False))
            b.write_prepared_metadata(second/'launch.json',dict(prepared_source_authorization=authorization))
            selected=b.prepared_metadata_ref(start_path)
            roots=[sys._stdlib_dir,sys._stdlib_dir+'/lib-dynload',str(f.project/'tools')]
            with patch.object(sys,'pycache_prefix',prefix),patch.object(sys,'_xoptions',{'wikidict_prepared_source':'1'}),patch.object(sys,'path',roots):
                with b.prepared_source_request(selected) as request:
                    self.assertEqual(f.generation_ref,request.generation.generation_reference)
                    self.assertEqual(f.identity,request.generation.identity)
                    expected={k:v for k,v in f.record['workspace_state'].items() if k!='now_unix'}
                    with patch.object(b,'artifact_path'),patch.object(b,'remove_artifact_tree',side_effect=AssertionError('must not retire')):
                        self.assertEqual(1234,b.prepare_shard_workspace(f.workspace,expected,1234))
                        with self.assertRaisesRegex(ValueError,'exact original prepared workspace'):
                            b.prepare_shard_workspace(f.workspace,dict(expected,production_source='6'*64),1234)
                    with patch.object(b,'run_checked',side_effect=AssertionError('must not compile')):
                        with self.assertRaisesRegex(ValueError,'cannot silently prepare'):
                            b.prepare_blob_tools(f.workspace,'zig','toy','date',f.identity)
            self.assertIsNone(getattr(b._PREPARED_SOURCE,'value',None))
            with patch.object(sys,'pycache_prefix',str(second/'different-prefix')),patch.object(sys,'_xoptions',{'wikidict_prepared_source':'1'}):
                with self.assertRaisesRegex(ValueError,'bound absent bytecode prefix'):
                    b.PreparedSourceRequest(selected)
            with patch.object(sys,'pycache_prefix',prefix),patch.object(sys,'_xoptions',{}):
                with self.assertRaisesRegex(ValueError,'bound interpreter bootstrap'):
                    b.PreparedSourceRequest(selected)


    def test_without_authorization_default_source_guard_still_rejects_zig_drift(self):
        with self.generation_fixture() as f:
            zig=f.project/'build.zig';zig.write_text('original compiler source\n')
            identity=dict(source=b.source_fingerprint())
            b.require_build_source(identity)
            zig.write_text('changed compiler source\n')
            with self.assertRaisesRegex(ValueError,'Compiler source changed'):
                b.require_build_source(identity)


    def test_actual_child_bootstrap_survives_watchdog_argv_and_excludes_lazy_shadow_roots(self):
        import ast
        import corpus_controller as controller
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); tools=root/'source'/'tools';tools.mkdir(parents=True)
            cwd=root/'cwd';cwd.mkdir();shadow=root/'pythonpath';shadow.mkdir();site=root/'site-packages';site.mkdir()
            marker=root/'shadow-executed'
            bad='raise RuntimeError("unbound shadow executed")\n'
            for folder in (cwd,shadow,site):
                names=('argparse.py','json.py','fractions.py','unbound_thirdparty.py') if folder==cwd else ('fractions.py','unbound_thirdparty.py')
                for name in names:
                    (folder/name).write_text('from pathlib import Path\nPath('+repr(str(marker))+').write_text("bad")\n'+bad)
            allowed=tools/'custody_allowed.py';allowed.write_text('VALUE = 7\n');allowed.chmod(0o644)
            prefix_source=Path(b.__file__).read_text().split('from compress_blobs import ',1)[0]
            # Simulate an interpreter-established site path before the actual
            # selected builder bootstrap. No site startup code is introduced.
            probe_source='import sys\nsys.path[0:0]='+repr([str(cwd),str(site)])+'\n'+prefix_source+'''
import argparse,json,fractions,custody_allowed
_PREPARED_BOOTSTRAP_PYTHON_GUARD.require_python()
assert sys.flags.isolated==1 and sys.flags.no_site==1
assert custody_allowed.VALUE==7
assert fractions.__file__.startswith(sys._stdlib_dir)
try:
 import unbound_thirdparty
except ModuleNotFoundError:
 pass
else:
 raise AssertionError('unbound lazy site/PYTHONPATH module imported')
print(json.dumps(dict(paths=sys.path,stdlib=sys._stdlib_dir,allowed=custody_allowed.__file__)))
'''
            script=tools/'build_wiktionaries.py';script.write_text(probe_source);script.chmod(0o644)
            files={path.relative_to(root/'source').as_posix():controller.descriptor(path) for path in (script,allowed)}
            inventory=root/'inventory.json';b.write_prepared_metadata(inventory,dict(head='fixture-qualified',files=files,modes={name:0o644 for name in files}))
            attempt=root/'attempt';attempt.mkdir();bytecode_prefix=str(attempt/'unwritten-python-cache')
            cfg=dict(source=dict(head='fixture-qualified',root=str(root/'source'),inventory=b.prepared_metadata_ref(inventory)),prepared_source_custody=True)
            start=attempt/'start.json';b.write_prepared_metadata(start,dict(prepared_source_control=dict(version=1,configuration=cfg,bytecode_prefix=bytecode_prefix)))
            original=dict(wall_seconds=1800,disk_paths=('unchanged-fixture',))
            with patch.object(sys,'_xoptions',{'wikidict_prepared_source':'1'}),patch.object(sys,'argv',[str(script)]),patch.object(sys,'pycache_prefix',bytecode_prefix):
                options=b.prepared_watchdog_options(original)
            self.assertEqual(original,{key:value for key,value in options.items() if key!='argv'})
            self.assertEqual(['-I','-S','-B','-X','wikidict_prepared_source=1','-X','pycache_prefix='+bytecode_prefix,str(script)],options['argv'])
            # Execute the real existing watchdog command-construction statement,
            # without another guardian/admission/resource runner in this test.
            watchdog=next(node for node in ast.parse(Path(limits.__file__).read_text()).body if isinstance(node,ast.FunctionDef) and node.name=='supervise_watchdog')
            commands=[node for node in ast.walk(watchdog) if isinstance(node,ast.Assign) and any(isinstance(target,ast.Name) and target.id=='command' for target in node.targets)]
            self.assertEqual(1,len(commands))
            namespace=dict(sys=sys,argv=options['argv'])
            exec(compile(ast.Module(body=commands,type_ignores=[]),str(limits.__file__),'exec'),namespace)
            environment=dict(os.environ,PYTHONPATH=str(shadow),PYTHONPYCACHEPREFIX=bytecode_prefix,
                WIKIDICT_PREPARED_SOURCE_ATTEMPT=json.dumps(b.prepared_metadata_ref(start)))
            # Prove the startup trap is real before testing the isolated relaunch.
            (shadow/'sitecustomize.py').write_text('from pathlib import Path\nPath('+repr(str(marker))+').write_text("startup")\n')
            baseline=subprocess.run([sys.executable,'-B','-c','pass'],cwd=cwd,env=environment,capture_output=True,text=True)
            self.assertEqual(baseline.returncode,0,baseline.stderr)
            self.assertEqual(marker.read_text(),'startup')
            marker.unlink()
            result=subprocess.run(namespace['command'],cwd=cwd,env=environment,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            observed=json.loads(result.stdout)
            self.assertEqual([observed['stdlib'],observed['stdlib']+'/lib-dynload',str(tools)],observed['paths'])
            self.assertEqual(str(allowed),observed['allowed']);self.assertFalse(marker.exists())
            self.assertFalse(Path(bytecode_prefix).exists())
            with patch.object(sys,'_xoptions',{}):
                self.assertIs(original,b.prepared_watchdog_options(original))

class PreparedGuardianStartupTests(unittest.TestCase):
    def test_actual_guardian_command_isolates_selected_startup_and_keeps_default(self):
        import ast
        import math
        from types import SimpleNamespace
        tree = ast.parse(Path(limits.__file__).read_text())
        function = next(node for node in tree.body if isinstance(node,ast.FunctionDef)
                        and node.name=='supervise_watchdog')
        blocks = [node.body for node in ast.walk(function) if isinstance(getattr(node,'body',None),list)]
        def assigned(node,name):
            return isinstance(node,ast.Assign) and any(isinstance(target,ast.Name) and target.id==name for target in node.targets)
        block = next(body for body in blocks if any(assigned(node,'guardian_python') for node in body))
        first = next(index for index,node in enumerate(block) if assigned(node,'guardian_python'))
        statements = block[first:first+3]
        self.assertTrue(assigned(statements[-1],'guardian_command'))
        code = compile(ast.Module(body=statements,type_ignores=[]),str(limits.__file__),'exec')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root/'guardian.py'
            (root/'bound_helper.py').write_text('VALUE=7\n')
            script.write_text('import sys,json,bound_helper\nprint(json.dumps(dict(value=bound_helper.VALUE,isolated_environment=sys.flags.ignore_environment,no_site=sys.flags.no_site,prefix=sys.pycache_prefix)))\n')
            shadow = root/'unbound';shadow.mkdir()
            marker = root/'startup-side-effect'
            (shadow/'sitecustomize.py').write_text('from pathlib import Path\nPath('+repr(str(marker))+').write_text("unexpected")\n')
            prefix = str(root/'unwritten-python-cache')
            def construct(selected,*,no_site=1):
                namespace = dict(sys=sys,os=os,math=math,ContainmentUnavailable=limits.ContainmentUnavailable,
                    guardian_script=script,supervisor_start=1,guardian_liveness_read=3,
                    guardian_identity_read=4,guardian_ack_write=5,wall_seconds=60,
                    guardian_cpu=0,guardian_report=root/'report.json')
                with patch.object(sys,'_xoptions',{'wikidict_prepared_source':'1'} if selected else {}), \
                        patch.object(sys,'flags',SimpleNamespace(isolated=1,no_site=no_site)), \
                        patch.object(sys,'pycache_prefix',prefix):
                    exec(code,namespace)
                return namespace['guardian_command']
            self.assertEqual(construct(False)[:3],[sys.executable,'-B',str(script)])
            command = construct(True)
            self.assertEqual(command[1:7],['-E','-s','-S','-B','-X','pycache_prefix='+prefix])
            with self.assertRaises(limits.ContainmentUnavailable):
                construct(True,no_site=0)
            result = subprocess.run(command,cwd=root,env=dict(os.environ,PYTHONPATH=str(shadow)),
                                    capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(json.loads(result.stdout),dict(value=7,isolated_environment=1,no_site=1,prefix=prefix))
            self.assertFalse(marker.exists())
            self.assertFalse(Path(prefix).exists())




class FigurePreparationPolicyTests(unittest.TestCase):
    def fixture(self, directory):
        root = Path(directory)
        selected = [dict(wiki='viwiktionary', date='20261001', name='viwiktionary-20261001-image.sql.gz', url='https://dumps.wikimedia.org/viwiktionary/20261001/viwiktionary-20261001-image.sql.gz', size=1, sha1='a'*40)]
        namespace = root/'namespace-registry.tsv'
        namespace.write_text('selected namespace fixture')
        expected = {name:root/'figure-inputs'/filename for name,filename in dict(b.FIGURE_SNAPSHOT_FILES, **{'file-metadata':'file-metadata.tsv'}).items()}
        return root, selected, namespace, expected

    def test_offline_missing_capture_does_not_invoke_acquisition(self):
        import prepare_figure_metadata as figures
        with tempfile.TemporaryDirectory() as directory:
            root, selected, namespace, _ = self.fixture(directory)
            with patch.object(figures,'prepare_for_build',create=True) as prepare:
                self.assertEqual(b.resolve_figure_snapshot_options(root,{},selected,root,namespace,{}),{})
                prepare.assert_not_called()
            with self.assertRaisesRegex(ValueError,'Figure'):
                b.require_figure_inputs({},required=True)

    def test_published_capture_is_reused_even_with_network_allowed(self):
        import prepare_figure_metadata as figures
        with tempfile.TemporaryDirectory() as directory:
            root, selected, namespace, expected = self.fixture(directory)
            generation=root/'figure-inputs'; generation.mkdir()
            (generation/figures.COMPLETE).write_text('selected complete marker fixture')
            with patch.object(b,'discover_auxiliary_generation',return_value=expected) as discover, patch.object(figures,'prepare_for_build',create=True) as prepare:
                self.assertEqual(b.resolve_figure_snapshot_options(root,{},selected,root,namespace,{},metadata_network='allow'),expected)
                discover.assert_called_once()
                prepare.assert_not_called()

    def test_partial_explicit_tuple_and_invalid_policy_refuse_before_preparation(self):
        import prepare_figure_metadata as figures
        with tempfile.TemporaryDirectory() as directory:
            root, selected, namespace, expected = self.fixture(directory)
            for overrides,policy in (({'figure-sizing':expected['figure-sizing']},'allow'),({},True),({},'guess')):
                with self.subTest(overrides=overrides,policy=policy), patch.object(figures,'prepare_for_build',create=True) as prepare, self.assertRaises(ValueError):
                    b.resolve_figure_snapshot_options(root,{},selected,root,namespace,overrides,metadata_network=policy)
                prepare.assert_not_called()
            with patch.object(figures,'prepare_for_build',create=True) as prepare:
                complete={name:expected[name] for name in b.FIGURE_SNAPSHOT_FILES}
                self.assertEqual(b.resolve_figure_snapshot_options(root,{},selected,root,namespace,complete,metadata_network='allow'),{})
                prepare.assert_not_called()

    def test_invalid_published_capture_never_falls_back_to_network(self):
        import prepare_figure_metadata as figures
        with tempfile.TemporaryDirectory() as directory:
            root, selected, namespace, _ = self.fixture(directory)
            generation=root/'figure-inputs'; generation.mkdir()
            (generation/figures.COMPLETE).write_text('invalid')
            with patch.object(b,'discover_auxiliary_generation',side_effect=ValueError('bad capture')), patch.object(figures,'prepare_for_build',create=True) as prepare, self.assertRaisesRegex(ValueError,'bad capture'):
                b.resolve_figure_snapshot_options(root,{},selected,root,namespace,{},metadata_network='allow')
            prepare.assert_not_called()

    def test_acquisition_receives_exact_official_inputs_while_lock_is_held(self):
        import fcntl
        import prepare_figure_metadata as figures
        with tempfile.TemporaryDirectory() as directory:
            root, selected, namespace, expected = self.fixture(directory)
            manifest={'files':selected}
            def acquire(*args,**kwargs):
                self.assertEqual(args,(root,manifest,selected,root,namespace))
                self.assertEqual(kwargs,{'network':True})
                with (root/'.figure-inputs.lock').open('r+') as stream:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(stream,fcntl.LOCK_EX|fcntl.LOCK_NB)
                return expected
            with patch.object(figures,'prepare_for_build',side_effect=acquire,create=True):
                self.assertEqual(b.resolve_figure_snapshot_options(root,manifest,selected,root,namespace,{},metadata_network='allow'),expected)
            with b.acquire_build_resource_lock(root/'.figure-inputs.lock'):
                pass

    def test_busy_capture_lock_refuses_without_acquisition(self):
        import prepare_figure_metadata as figures
        with tempfile.TemporaryDirectory() as directory:
            root, selected, namespace, _ = self.fixture(directory)
            with b.acquire_build_resource_lock(root/'.figure-inputs.lock'), patch.object(figures,'prepare_for_build',create=True) as prepare:
                with self.assertRaises(limits.ContainmentUnavailable):
                    b.resolve_figure_snapshot_options(root,{},selected,root,namespace,{},metadata_network='allow')
                prepare.assert_not_called()

    def test_failed_prefix_or_wrong_returned_roles_never_trigger_another_capture(self):
        import prepare_figure_metadata as figures
        with tempfile.TemporaryDirectory() as directory:
            root, selected, namespace, expected = self.fixture(directory)
            for response in (ValueError('unproved prefix'),dict(expected,**{'file-metadata':root/'wrong.tsv'})):
                kwargs={'side_effect':response} if isinstance(response,Exception) else {'return_value':response}
                with self.subTest(response=response), patch.object(figures,'prepare_for_build',create=True,**kwargs) as prepare, self.assertRaises(ValueError):
                    b.resolve_figure_snapshot_options(root,{},selected,root,namespace,{},metadata_network='allow')
                prepare.assert_called_once()

    def test_non_directory_or_linked_generation_is_not_acquired(self):
        import prepare_figure_metadata as figures
        with tempfile.TemporaryDirectory() as directory:
            root, selected, namespace, _ = self.fixture(directory)
            generation=root/'figure-inputs'
            generation.write_text('not a capture')
            with patch.object(figures,'prepare_for_build',create=True) as prepare, self.assertRaises(ValueError):
                b.resolve_figure_snapshot_options(root,{},selected,root,namespace,{},metadata_network='allow')
            prepare.assert_not_called()
            generation.unlink()
            generation.symlink_to(root,target_is_directory=True)
            with patch.object(figures,'prepare_for_build',create=True) as prepare, self.assertRaises(ValueError):
                b.resolve_figure_snapshot_options(root,{},selected,root,namespace,{},metadata_network='allow')
            prepare.assert_not_called()


class FigureReuseBatchForwardingTests(FigurePreparationPolicyTests):
    def test_records_force_locked_helper_for_offline_and_complete_capture(self):
        import prepare_figure_metadata as figures
        for policy in ('offline','allow'):
            with self.subTest(policy=policy), tempfile.TemporaryDirectory() as directory:
                root,selected,namespace,expected=self.fixture(directory)
                generation=root/'figure-inputs';generation.mkdir();(generation/figures.COMPLETE).write_text('complete')
                refs=(root/'one.json',root/'two.json')
                with patch.object(figures,'prepare_for_build',return_value=expected,create=True) as prepare, patch.object(b,'discover_auxiliary_generation',side_effect=AssertionError('must validate supplied records')):
                    self.assertEqual(b.resolve_figure_snapshot_options(root,{},selected,root,namespace,{},metadata_network=policy,figure_reuse_batches=refs),expected)
                    self.assertEqual(prepare.call_args.kwargs,dict(network=policy=='allow',reuse_batches=refs))
    def test_explicit_override_duplicate_and_invalid_records_refuse_without_helper(self):
        import prepare_figure_metadata as figures
        with tempfile.TemporaryDirectory() as directory:
            root,selected,namespace,expected=self.fixture(directory)
            for refs,overrides in (((root/'one',root/'one'),{}), (('not-a-path',),{}), ((root/'one',),{name:root/filename for name,filename in b.FIGURE_SNAPSHOT_FILES.items()})):
                with self.subTest(refs=refs,overrides=overrides), patch.object(figures,'prepare_for_build',create=True) as prepare, self.assertRaises(ValueError):
                    b.resolve_figure_snapshot_options(root,{},selected,root,namespace,overrides,figure_reuse_batches=refs)
                prepare.assert_not_called()
    def test_record_validation_error_never_falls_back_or_allows_network(self):
        import prepare_figure_metadata as figures
        with tempfile.TemporaryDirectory() as directory:
            root,selected,namespace,_=self.fixture(directory)
            with patch.object(figures,'prepare_for_build',side_effect=ValueError('wrong record wiki/date'),create=True) as prepare, patch.object(b,'discover_auxiliary_generation',side_effect=AssertionError('no fallback')), self.assertRaisesRegex(ValueError,'wrong record'):
                b.resolve_figure_snapshot_options(root,{},selected,root,namespace,{},figure_reuse_batches=(root/'one',))
            self.assertIs(prepare.call_args.kwargs['network'],False)

class MaintainedFigureCompatibilityTests(unittest.TestCase):
    def inputs(self, root):
        names=('namespace-registry',*b.FIGURE_SNAPSHOT_FILES)
        result={}
        for n,name in enumerate(names):
            path=root/('selected-'+str(n));path.write_bytes(('original '+name).encode())
            result[name]=path
        return result


    def test_compatibility_paths_preserve_selected_order_and_partial_inputs_refuse(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);snapshots=self.inputs(root)
            expected=tuple(root/('selected-'+str(n)) for n in range(5))
            self.assertEqual(b.figure_compatibility_paths(snapshots),expected)
            self.assertIsNone(b.figure_compatibility_paths({}))
            for key in snapshots:
                missing=dict(snapshots);missing.pop(key)
                with self.subTest(key=key),self.assertRaises(ValueError):b.figure_compatibility_paths(missing)
            snapshots['figure-sizing']=Path('relative.json')
            with self.assertRaises(ValueError):b.figure_compatibility_paths(snapshots)


    def test_compatibility_checks_selected_input_and_tool_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);tool=fixture_blob_tool(root)
            paths=b.figure_compatibility_paths(self.inputs(root))
            original=paths[2].read_bytes()
            def changed(*a,**kw):paths[2].write_bytes(original+b' changed')
            with patch.object(b,'timed_run',side_effect=changed):
                with self.assertRaisesRegex(ValueError,'inputs changed'):
                    b.check_figure_compatibility(tool,paths,'testwiktionary','20261001')
            paths[2].write_bytes(original)
            tool.path.chmod(0o755);tool.path.write_bytes(b'changed native')
            with patch.object(b,'timed_run') as run:
                with self.assertRaises(ValueError):b.check_figure_compatibility(tool,paths,'testwiktionary','20261001')
            run.assert_not_called()


    def test_new_cached_and_prepared_paths_reject_before_expander_or_first_shard(self):
        for mode in ('new','cached','prepared'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);workspace=root/'work';(workspace/'input').mkdir(parents=True)
                compiler=root/'zig';compiler.write_bytes(b'compiler');compiler.chmod(0o755)
                (workspace/'input/.complete.json').write_text(json.dumps(dict(source_pages=0,dump_sha256='a'*64,index_sha256='b'*64)))
                snapshots=self.inputs(root);identity=dict(source='current',zig_sha256=b.sha256_file(compiler))
                generation=None
                if mode=='prepared':
                    generation=SimpleNamespace(workspace=workspace,dump=root/'dump',root=workspace/'expander/.bundle-expander',
                        tools={name:fixture_blob_tool(root,name) for name in b.BLOB_TOOL_NAMES},
                        require_identity=lambda value:None,require_unchanged=lambda **kw:None)
                commands=[];checks=[]
                def install(command):
                    commands.append(command)
                    self.assertIn('prepare-blob-tools',command);self.assertNotIn('build-dictionary',command)
                    prefix=Path(command[command.index('--prefix')+1]);(prefix/'bin').mkdir(parents=True,exist_ok=True)
                    for name in b.BLOB_TOOL_NAMES:
                        path=prefix/'bin'/name;path.write_bytes(name.encode());path.chmod(0o555)
                refusal=subprocess.CalledProcessError(9,['selected Writer compatibility refusal'])
                def dispatch(command,*args,**fields):
                    checks.append(command)
                    self.assertEqual(command[1:],["--check-figure-compatibility",*map(str,b.figure_compatibility_paths(snapshots))])
                    self.assertTrue(fields['compatibility_only']);self.assertFalse(fields['full_input_validation'])
                    raise refusal
                with patch.object(b._PREPARED_SOURCE,'value',generation,create=True), \
                     patch.object(b,'source_fingerprint',return_value='current'), \
                     patch.object(b,'expander_ready',return_value=mode=='cached'), \
                     patch.object(b,'pipeline_snapshot_args',return_value=[]), \
                     patch.object(b,'run_checked',side_effect=install), \
                     patch.object(b,'timed_run',side_effect=dispatch), \
                     patch.object(b,'inspect_page_index',return_value={'rows':0,'sha256':'a'*64}), \
                     patch.object(b,'build_shard_with_retries') as shard:
                    with self.assertRaises(subprocess.CalledProcessError) as caught:
                        b.build_sharded(root/'dump',root/'staging',workspace,root/'namespace',str(compiler),1,
                            [dict(wiki='testwiktionary',date='20261001')],123,build_identity=identity,
                            compress_shards=True,auxiliary_snapshots=snapshots)
                self.assertIs(caught.exception,refusal);self.assertEqual(len(checks),1)
                self.assertEqual(len(commands),0 if mode=='prepared' else 1);shard.assert_not_called()

    def test_fresh_tools_are_bound_and_checked_before_expander_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);compiler=root/'zig';compiler.write_bytes(b'compiler');compiler.chmod(0o755)
            workspace=root/'work';workspace.mkdir();paths=b.figure_compatibility_paths(self.inputs(root))
            calls=[];events=[]
            def compile_tools(command):
                calls.append(command)
                destination=workspace/'native-blob-tools/bin'
                if 'prepare-blob-tools' in command:
                    events.append('prepare')
                    destination.mkdir(parents=True,exist_ok=True)
                    for name in b.BLOB_TOOL_NAMES:
                        tool=destination/name;tool.write_bytes(name.encode());tool.chmod(0o555)
                else:
                    self.assertIn('build-dictionary',command)
                    events.append('expander')
                    # addPublicRunStep runs the bundle driver; it does not
                    # reinstall private tools prepared by the preceding step.
                    for name in b.BLOB_TOOL_NAMES:
                        self.assertEqual((destination/name).read_bytes(),name.encode())
            error=subprocess.CalledProcessError(2,['bound Writer rejects profile'])
            with patch.object(b,'source_fingerprint',return_value='same-source'), \
                 patch.object(b,'run_checked',side_effect=compile_tools), \
                 patch.object(b,'timed_run',side_effect=error):
                with self.assertRaises(subprocess.CalledProcessError) as caught:
                    b.prepare_blob_tools(workspace,str(compiler),'testwiktionary','20261001',
                        expander_args=['dump','output','--expander-only'],figure_inputs=paths)
            self.assertIs(caught.exception,error);self.assertEqual(len(calls),1)
            self.assertIn('prepare-blob-tools',calls[0]);self.assertNotIn('build-dictionary',calls[0])
            workspace=root/'success';workspace.mkdir();calls.clear();events.clear()
            def checked(command,*a,**kw):
                self.assertEqual(command[1], '--check-figure-compatibility')
                self.assertTrue(kw['compatibility_only']);self.assertFalse(kw['full_input_validation'])
                events.append('compatibility')
            with patch.object(b,'source_fingerprint',return_value='same-source'), \
                 patch.object(b,'run_checked',side_effect=compile_tools), \
                 patch.object(b,'timed_run',side_effect=checked):
                tools=b.prepare_blob_tools(workspace,str(compiler),'testwiktionary','20261001',
                    expander_args=['dump','output','--expander-only'],figure_inputs=paths)
            self.assertEqual(events,['prepare','compatibility','expander'])
            self.assertEqual(len(calls),2)
            for name,tool in tools.items():
                self.assertEqual(tool.path.read_bytes(),name.encode());tool.require_unchanged()


class FigureTupleReplayReuseTests(unittest.TestCase):
    def setUp(self):
        import prepare_figure_metadata as figures
        from test_prepare_figure_files import FigureFileTests
        self.figures = figures
        self.fixture = FigureFileTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.args = self.fixture.args()
        figures.capture_files(self.args, transport=lambda *_: (200, {}, figures.encoded(self.fixture.response())), sleep=lambda _: None)
        self.paths = {role: self.args.output / filename for role, filename in
                      dict(figures.ROLES, **{'file-metadata': figures.PROVIDER}).items()}
        b._FIGURE_TUPLE_REPLAYS.clear()
        self.addCleanup(b._FIGURE_TUPLE_REPLAYS.clear)

    def validate(self):
        return b.validated_figure_tuple(self.paths, self.fixture.wiki, self.fixture.date)

    def test_figure_replay_reuse_runs_initial_sql_replay_once_and_returns_owned_values(self):
        with patch.object(self.figures, 'verify_tuple', wraps=self.figures.verify_tuple) as replay:
            first = self.validate()
            first['figure-sizing'][0]['wiki'] = 'changed'
            second = self.validate()
            self.assertEqual(replay.call_count, 1)
            self.assertEqual(second['figure-sizing'][0]['wiki'], self.fixture.wiki)
            self.assertIsInstance(second['figure-sizing'], tuple)
            with self.assertRaisesRegex(ValueError, 'edition/date'):
                b.validated_figure_tuple(self.paths, 'enwiktionary', self.fixture.date)

    def test_figure_replay_reuse_refuses_artifact_mutation_truncation_and_membership(self):
        for mode in ('changed', 'truncated', 'extra'):
            with self.subTest(mode=mode):
                b._FIGURE_TUPLE_REPLAYS.clear()
                path = self.paths['file-metadata']
                original = path.read_bytes()
                self.validate()
                try:
                    if mode == 'changed': path.write_bytes(original + b'x')
                    elif mode == 'truncated': path.write_bytes(original[:-1])
                    else: (path.parent/'unrecorded.raw').write_bytes(b'x')
                    with self.assertRaisesRegex(ValueError, 'changed'):
                        self.validate()
                finally:
                    path.write_bytes(original)
                    (path.parent/'unrecorded.raw').unlink(missing_ok=True)

    def test_figure_replay_reuse_refuses_identical_byte_replacement(self):
        self.validate()
        path = self.paths['file-metadata']
        replacement = path.with_name('replacement.part')
        replacement.write_bytes(path.read_bytes())
        os.replace(replacement, path)
        with self.assertRaisesRegex(ValueError, 'changed'):
            self.validate()

    def test_figure_replay_reuse_refuses_changed_official_sql_before_replay(self):
        self.validate()
        path = self.args.sql[0]
        path.write_bytes(path.read_bytes() + b'x')
        with patch.object(self.figures, 'verify_tuple', side_effect=AssertionError('unexpected full replay')):
            with self.assertRaisesRegex(ValueError, 'changed'):
                self.validate()

    def test_figure_replay_reuse_refuses_changed_helper_identity(self):
        self.validate()
        original = self.figures.producer()
        with patch.object(self.figures, 'producer', return_value=dict(original, generator_sha256='0'*64)):
            with self.assertRaisesRegex(ValueError, 'changed'):
                self.validate()

    def test_figure_replay_reuse_does_not_survive_new_interpreter_local_state(self):
        self.validate()
        # A fresh invocation has no retained result and must replay; no on-disk
        # cache, manifest field, or trust option can repopulate this dictionary.
        with patch.object(b, '_FIGURE_TUPLE_REPLAYS', {}):
            with patch.object(self.figures, 'verify_tuple', wraps=self.figures.verify_tuple) as replay:
                self.validate()
                self.assertEqual(replay.call_count, 1)

    def test_figure_replay_guard_accepts_multiline_legacy_request_inventory(self):
        path = self.args.output / self.figures.FILE_REQUESTS
        # This tests the guard's transport acceptance, not semantic validity of
        # a rewritten capture. Full semantic replay remains mandatory separately.
        path.write_text(json.dumps([], indent=2).replace('[]', '[\n]') + '\n')
        self.assertIsNotNone(b.figure_tuple_guard(self.figures, self.args.output))


class CompleteParentTupleReplayTests(unittest.TestCase):
    def setUp(self):
        import prepare_figure_metadata as figures
        from test_prepare_figure_files import FigureFileTests
        self.figures = figures
        self.fixture = FigureFileTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.args, self.observation, _ = self.fixture.complete_stream_fixture()
        self.parent = self.args.output
        self.args.output = self.fixture.root/'complete-child'
        self.args.reuse = [self.parent]
        self.args.reuse_batch = [self.observation]
        figures.capture_files(self.args, transport=lambda *_: self.fail('Retained parent made HTTP'))
        self.child = self.args.output
        self.args.output = self.fixture.root/'complete-grandchild'
        self.args.reuse = [self.child]
        self.args.reuse_batch = []
        figures.capture_files(self.args, transport=lambda *_: self.fail('Retained ancestor made HTTP'))
        self.paths = {role: self.args.output / filename for role, filename in
                      dict(figures.ROLES, **{'file-metadata': figures.PROVIDER}).items()}
        b._FIGURE_TUPLE_REPLAYS.clear()
        self.addCleanup(b._FIGURE_TUPLE_REPLAYS.clear)

    def validate(self):
        return b.validated_figure_tuple(self.paths, self.fixture.wiki, self.fixture.date)

    def test_auxiliary_then_input_identity_share_completed_parent_replay_with_fresh_guards(self):
        compiler = self.fixture.root/'controlled-compiler'
        compiler.write_bytes(b'controlled compiler identity')
        compiler.chmod(0o555)
        with patch.object(self.figures, 'verify_tuple', wraps=self.figures.verify_tuple) as replay:
            initial = b.verified_auxiliary_hashes(self.paths, self.fixture.wiki, self.fixture.date)
            with patch.object(b, 'source_fingerprint', return_value='a'*64):
                identity = b.build_input_identity([], str(compiler), None, None, None,
                    auxiliary_snapshots=self.paths, validate_auxiliary=True)
            self.assertEqual(identity['auxiliary_snapshot_sha256'], initial)
            self.assertEqual(replay.call_count, 1)
            self.assertEqual(set(identity['auxiliary_capture_sha256']), set(self.paths))
        with patch.object(b, '_FIGURE_TUPLE_REPLAYS', {}):
            with patch.object(self.figures, 'verify_tuple', wraps=self.figures.verify_tuple) as replay:
                self.validate()
                self.assertEqual(replay.call_count, 1)

    def test_guard_hashes_transitive_inputs_and_visits_each_repeated_parent_once(self):
        roots = {self.args.output, self.child, self.parent}
        visits = {root: 0 for root in roots}
        original = Path.iterdir
        def counted(directory):
            if directory in visits:
                visits[directory] += 1
            return original(directory)
        with patch.object(Path, 'iterdir', counted):
            with patch.object(self.figures.evidence, 'fingerprint', wraps=self.figures.evidence.fingerprint) as fingerprint:
                guard = b.figure_tuple_guard(self.figures, self.args.output)
        self.assertIsNotNone(guard)
        self.assertEqual(visits, {root: 2 for root in roots})
        self.assertEqual(set(guard[2]), {str(root) for root in roots})
        self.assertIn(str(self.parent/self.figures.ROLES['figure-sizing-raw']), guard[1])
        self.assertIn(str(self.observation), guard[1])
        self.assertEqual(sum(Path(call.args[0]) == self.args.sql[0] for call in fingerprint.call_args_list), 1)

    def test_cached_parent_members_bytes_inode_sql_and_external_observation_must_stay_exact(self):
        retained = json.loads(self.observation.read_text())
        artifact = self.observation.parent/next(iter(retained['artifacts']))
        raw = self.parent/self.figures.ROLES['figure-sizing-raw']
        for mode, path in (('truncated', raw), ('same-byte-inode', raw),
                           ('extra', self.parent/'unrecorded.raw'),
                           ('sql', self.args.sql[0]), ('external-observation', artifact)):
            with self.subTest(mode=mode):
                b._FIGURE_TUPLE_REPLAYS.clear()
                self.validate()
                original = None if mode == 'extra' else path.read_bytes()
                try:
                    if mode == 'same-byte-inode':
                        replacement = path.with_name(path.name+'.replacement')
                        replacement.write_bytes(original)
                        os.replace(replacement, path)
                    else:
                        path.write_bytes(b'extra' if mode == 'extra' else original[:-1] if mode == 'truncated' else original+b'x')
                    with patch.object(self.figures, 'verify_tuple', side_effect=AssertionError('Changed authority reached semantic replay')):
                        with self.assertRaisesRegex(ValueError, 'changed'):
                            self.validate()
                finally:
                    if mode == 'extra':
                        path.unlink()
                    else:
                        path.write_bytes(original)

    def test_parent_cycles_unsafe_locators_and_unrecognized_authorities_do_not_enter_cache(self):
        path = self.parent/self.figures.FILE_REQUESTS
        original = path.read_bytes()
        rows = [self.figures.decode(line) for line in original.splitlines()]
        try:
            cases = (
                ({'kind': 'complete-stream', 'path': str(self.args.output/self.figures.MANIFEST), 'sha256': '0'*64, 'batch': 0}, 'recursive'),
                ({'kind': 'complete-stream', 'path': 'relative/figure-inputs.manifest.json', 'sha256': '0'*64, 'batch': 0}, 'Unsafe'),
            )
            for source, message in cases:
                with self.subTest(source=source):
                    path.write_bytes(self.figures.stream_encoded(rows[0])+self.figures.stream_encoded(source)+b''.join(self.figures.stream_encoded(row) for row in rows[2:]))
                    with self.assertRaisesRegex(ValueError, message):
                        b.figure_tuple_guard(self.figures, self.args.output)
            rows[1] = {'kind': 'unknown-future-prefix', 'path': '/unread-authority.json', 'sha256': '0'*64, 'batch': 0}
            path.write_bytes(b''.join(self.figures.stream_encoded(row) for row in rows))
            self.assertIsNone(b.figure_tuple_guard(self.figures, self.args.output))
            with patch.object(self.figures, 'verify_tuple', side_effect=ValueError('Existing full replay required')) as replay:
                with self.assertRaisesRegex(ValueError, 'Existing full replay required'):
                    self.validate()
                self.assertEqual(replay.call_count, 1)
            self.assertEqual(b._FIGURE_TUPLE_REPLAYS, {})
        finally:
            path.write_bytes(original)

    def test_invalid_parent_still_requires_first_semantic_replay_and_failure_cannot_seed_cache(self):
        path = self.parent/self.figures.ROLES['figure-sizing-raw']
        original = path.read_bytes()
        try:
            path.write_bytes(b'{}\n')
            with patch.object(self.figures, 'verify_tuple', wraps=self.figures.verify_tuple) as replay:
                with self.assertRaises(ValueError):
                    self.validate()
                self.assertEqual(replay.call_count, 1)
            self.assertEqual(b._FIGURE_TUPLE_REPLAYS, {})
        finally:
            path.write_bytes(original)
        with patch.object(self.figures, 'verify_tuple', wraps=self.figures.verify_tuple) as replay:
            self.validate()
            self.assertEqual(replay.call_count, 1)


class ExactSnapshotSelectionTests(unittest.TestCase):
    def invoke(self, mutation=None, *, exact=True, explicit_interwiki=False, failure=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); key = ('enwiktionary', '20260901')
            name = 'enwiktionary-20260901-pages-meta-current.xml.bz2'
            write_test_manifest(root, {'files': [dict(wiki=key[0], date=key[1], name=name,
                url='https://dumps.wikimedia.org/enwiktionary/20260901/'+name, size=1, sha1='a'*40)]})
            category = root/'category.tsv'; category.write_text('x\t1\t0\t0\n')
            interwiki = root/'interwiki.tsv'; interwiki.write_text('selected\n')
            other = root/'other.tsv'; other.write_text('different\n')
            selected = {key: {'auxiliary_snapshots': {'category-stats': category}}}
            if mutation == 'extra': selected[key]['auxiliary_snapshots']['file-metadata'] = other
            elif mutation == 'missing': selected[key]['auxiliary_snapshots'].clear()
            elif mutation == 'path': selected[key]['auxiliary_snapshots']['category-stats'] = other
            elif mutation == 'date': selected[(key[0], '20261001')] = selected.pop(key)
            elif mutation == 'edition': selected[('viwiktionary', key[1])] = selected.pop(key)
            elif mutation == 'interwiki': selected[key]['interwiki_snapshot'] = other
            argv = ['build_wiktionaries.py', '--downloads', str(root), '--output', str(root/'out'),
                    '--wikis', key[0], '--threads', '1', '--jobs', '1',
                    '--category-stats-snapshot', str(category)]
            if exact: argv.append('--exact-snapshot-selection')
            if explicit_interwiki: argv.extend(['--interwiki-map-snapshot', str(interwiki)])
            events = []
            def resolve(*args, **kwargs):
                events.append('resolve')
                if failure: raise ValueError('source verification failed')
                return selected
            def build(*args, **kwargs):
                events.append('build')
                self.assertNotIn('exact_snapshot_selection', kwargs)
                return []
            with patch.object(sys, 'argv', argv), patch.object(b, 'safe_worker_budget', return_value=4), \
                 patch.object(b, 'resolve_edition_snapshot_options', side_effect=resolve) as resolver, \
                 patch.object(b, 'build_groups', side_effect=build) as groups, \
                 contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                refused = exact and mutation is not None and not (mutation == 'interwiki' and explicit_interwiki)
                if refused or failure:
                    with self.assertRaises(SystemExit): b.main()
                    groups.assert_not_called()
                    self.assertEqual(events, ['resolve'])
                else:
                    b.main(); groups.assert_called_once()
                    self.assertEqual(events, ['resolve', 'build'])
                    if explicit_interwiki:
                        self.assertEqual(groups.call_args.kwargs['edition_options'][key]['interwiki_snapshot'], interwiki)
                resolver.assert_called_once()

    def test_selected_producer_resolves_once_and_builds_only_exact_paths(self):
        self.invoke()

    def test_changed_role_path_edition_date_and_implicit_interwiki_refuse_before_build(self):
        for mutation in ('extra', 'missing', 'path', 'date', 'edition', 'interwiki'):
            with self.subTest(mutation=mutation): self.invoke(mutation)

    def test_normal_source_refusal_is_not_replaced_by_selection_check(self):
        self.invoke(failure=True)

    def test_ordinary_discovery_keeps_default_and_final_explicit_interwiki_is_compared(self):
        self.invoke('extra', exact=False)
        self.invoke('interwiki', explicit_interwiki=True)


class ClosedPrefixTupleReplayTests(unittest.TestCase):
    def setUp(self):
        import prepare_figure_metadata as figures
        from test_prepare_figure_files import FigureFileTests
        self.figures = figures
        self.fixture = FigureFileTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.args, self.proof_path, _ = self.fixture.make_svg_oversize_lookahead()
        self.proof = json.loads(self.proof_path.read_text())
        self.closed_root = Path(self.proof['source_root'])
        self.closure_path = Path(self.proof['closure']['path'])
        self.args.max_inflight = 1
        clock = [0.0]
        with patch.object(figures.time, 'monotonic', side_effect=lambda:clock[0]):
            figures.capture_files(self.args, transport=self.fixture.svg_light_transport([]),
                sleep=lambda seconds:clock.__setitem__(0,clock[0]+seconds))
        self.parent = self.args.output
        self.args.output = self.fixture.root/'complete-over-closed-prefix'
        self.args.reuse = [self.parent]
        self.args.reuse_batch = []
        figures.capture_files(self.args, transport=lambda *_:self.fail('Retained parent refetched'))
        self.paths = {role:self.args.output/name for role,name in dict(figures.ROLES, **{'file-metadata':figures.PROVIDER}).items()}
        b._FIGURE_TUPLE_REPLAYS.clear()
        self.addCleanup(b._FIGURE_TUPLE_REPLAYS.clear)

    def validate(self):
        return b.validated_figure_tuple(self.paths, self.fixture.wiki, self.fixture.date)

    def test_closed_prefix_auxiliary_identity_and_workspace_share_one_semantic_replay(self):
        compiler = self.fixture.root/'controlled-compiler'
        compiler.write_bytes(b'controlled compiler identity'); compiler.chmod(0o555)
        items = [dict(wiki=self.fixture.wiki,date=self.fixture.date,name='selected.sql.gz',size=1,sha1='a'*40)]
        with patch.object(self.figures, 'verify_tuple', wraps=self.figures.verify_tuple) as replay:
            initial = b.verified_auxiliary_hashes(self.paths, self.fixture.wiki, self.fixture.date)
            with patch.object(b, 'source_fingerprint', return_value='a'*64):
                identity = b.build_input_identity([],str(compiler),None,None,None,
                    auxiliary_snapshots=self.paths,validate_auxiliary=True)
            with patch.object(b, '_source_fingerprints', return_value=('a'*64,'b'*64)):
                state = b.shard_state(items,self.fixture.namespace,auxiliary_snapshots=self.paths)
            self.assertEqual(identity['auxiliary_snapshot_sha256'],initial)
            self.assertEqual(state['auxiliary_snapshot_sha256'],initial)
            self.assertEqual(replay.call_count,1)
        with patch.object(b, '_FIGURE_TUPLE_REPLAYS', {}), patch.object(self.figures,'verify_tuple',wraps=self.figures.verify_tuple) as replay:
            self.validate(); self.assertEqual(replay.call_count,1)

    def test_closed_prefix_guard_covers_every_failed_member_closure_and_external_sql_once(self):
        roots = {self.args.output,self.parent,self.closed_root}
        visits = {root:0 for root in roots}
        original = Path.iterdir
        def counted(path):
            if path in visits: visits[path] += 1
            return original(path)
        with patch.object(Path,'iterdir',counted), patch.object(self.figures.evidence,'fingerprint',wraps=self.figures.evidence.fingerprint) as hashed:
            guard = b.figure_tuple_guard(self.figures,self.args.output)
        self.assertIsNotNone(guard)
        self.assertEqual(visits,{root:2 for root in roots})
        self.assertEqual(set(guard[2]),{str(root) for root in roots})
        required = {self.proof_path,self.closure_path,*self.closed_root.iterdir(),*self.args.sql}
        self.assertTrue({str(path) for path in required} <= set(guard[1]))
        counts = [Path(call.args[0]) for call in hashed.call_args_list]
        for path in required: self.assertEqual(counts.count(path),1,str(path))
        self.assertIn(str(self.closed_root/'file-metadata.response-000003-01.raw.json'),guard[1])
        self.assertIn(str(self.closed_root/'file-metadata.response-000002-01.raw.json'),guard[1])

    def test_closed_prefix_proof_closure_and_same_byte_inode_mutation_refuse_cached_result(self):
        for path,mode in ((self.proof_path,'bytes'),(self.closure_path,'bytes'),(self.closure_path,'inode')):
            with self.subTest(path=path,mode=mode):
                b._FIGURE_TUPLE_REPLAYS.clear();self.validate();original=path.read_bytes()
                try:
                    if mode=='inode':
                        replacement=path.with_suffix('.replacement');replacement.write_bytes(original);replacement.replace(path)
                    else: path.write_bytes(original+b' ')
                    with patch.object(self.figures,'verify_tuple',side_effect=AssertionError('Changed proof reached replay')):
                        with self.assertRaisesRegex(ValueError,'changed'):self.validate()
                finally:path.write_bytes(original)

    def test_closed_prefix_rejected_accepted_plan_failure_sql_and_membership_mutations_refuse(self):
        names = ('file-metadata.response-000002-01.raw.json','file-metadata.response-000003-01.raw.json',
                 self.figures.PLAN,'figure-failure-0001.json',self.figures.ROLES['figure-sizing-raw'])
        cases = [(self.closed_root/name,False) for name in names]
        cases += [(self.args.sql[0],False),(self.closed_root/'unexpected.bin',True),(self.closed_root/self.figures.COMPLETE,True)]
        for path,new in cases:
            with self.subTest(path=path):
                b._FIGURE_TUPLE_REPLAYS.clear();self.validate();original=None if new else path.read_bytes()
                try:
                    path.write_bytes(b'extra' if new else original+b' ')
                    with patch.object(self.figures,'verify_tuple',side_effect=AssertionError('Changed failed input reached replay')):
                        with self.assertRaisesRegex(ValueError,'changed'):self.validate()
                finally:
                    if new:path.unlink()
                    else:path.write_bytes(original)

    def test_closed_prefix_invalid_initial_proof_requires_semantic_replay_and_cannot_seed_cache(self):
        value=json.loads(self.closure_path.read_text());value['terminal']=0
        self.closure_path.write_bytes(self.figures.encoded(value))
        proof=dict(self.proof,closure=dict(path=str(self.closure_path),bytes=self.closure_path.stat().st_size,
            sha256=self.figures.digest(self.closure_path.read_bytes())))
        self.proof_path.write_bytes(self.figures.encoded(proof))
        self.assertIsNotNone(b.figure_tuple_guard(self.figures,self.args.output))
        with patch.object(self.figures,'verify_tuple',wraps=self.figures.verify_tuple) as replay:
            with self.assertRaises(ValueError):self.validate()
            self.assertEqual(replay.call_count,1)
        self.assertEqual(b._FIGURE_TUPLE_REPLAYS,{})

    def test_closed_prefix_cycle_unknown_schema_and_kind_retain_refusal_or_full_fallback(self):
        path=self.closed_root/self.figures.FILE_REQUESTS;original=path.read_bytes()
        rows=[self.figures.decode(line) for line in original.splitlines()]
        rows[1]=dict(kind='complete-stream',path=str(self.args.output/self.figures.MANIFEST),sha256='0'*64,batch=0)
        path.write_bytes(b''.join(self.figures.stream_encoded(row) for row in rows))
        with self.assertRaisesRegex(ValueError,'recursive'):b.figure_tuple_guard(self.figures,self.args.output)
        path.write_bytes(original)
        for mode in ('schema','kind'):
            with self.subTest(mode=mode):
                saved=self.proof_path.read_bytes()
                try:
                    if mode=='schema':
                        proof=dict(self.proof,schema='unknown-future-prefix');self.proof_path.write_bytes(self.figures.encoded(proof))
                    else:
                        rows=[self.figures.decode(line) for line in original.splitlines()]
                        rows[1]=dict(kind='unknown-future-prefix')
                        path.write_bytes(b''.join(self.figures.stream_encoded(row) for row in rows))
                    self.assertIsNone(b.figure_tuple_guard(self.figures,self.args.output))
                    with patch.object(self.figures,'verify_tuple',side_effect=ValueError('Full replay required')) as replay:
                        with self.assertRaisesRegex(ValueError,'Full replay required'):self.validate()
                        self.assertEqual(replay.call_count,1)
                    self.assertEqual(b._FIGURE_TUPLE_REPLAYS,{})
                finally:self.proof_path.write_bytes(saved);path.write_bytes(original)
        proof=dict(self.proof,closure=dict(self.proof['closure'],path='relative/closure.json'))
        self.proof_path.write_bytes(self.figures.encoded(proof))
        with self.assertRaisesRegex(ValueError,'Unsafe'):b.figure_tuple_guard(self.figures,self.args.output)

    def test_closed_prefix_change_during_first_semantic_replay_cannot_seed_cache(self):
        original=self.figures.verify_tuple
        rejected=self.closed_root/'file-metadata.response-000002-01.raw.json'
        def changed(*args,**kwargs):
            result=original(*args,**kwargs)
            rejected.write_bytes(rejected.read_bytes()+b' ')
            return result
        with patch.object(self.figures,'verify_tuple',side_effect=changed) as replay:
            with self.assertRaisesRegex(ValueError,'changed during validation'):self.validate()
            self.assertEqual(replay.call_count,1)
        self.assertEqual(b._FIGURE_TUPLE_REPLAYS,{})


class PinnedParentReplayTests(unittest.TestCase):
    setUp = CompleteParentTupleReplayTests.setUp
    validate = CompleteParentTupleReplayTests.validate

    def pin(self, destination=None):
        return b.pinned_auxiliary_snapshots(self.paths,
            {role: b.sha256_file(path) for role, path in self.paths.items()},
            destination or self.fixture.root/'pinned')

    def proof_contexts(self):
        return [entry[2] for entry in b._FIGURE_TUPLE_REPLAYS.values() if len(entry) == 3]

    def test_pinning_reuses_external_parents_but_replays_destination_and_preserves_owned_results(self):
        with patch.object(self.figures, 'verify', wraps=self.figures.verify) as verify, \
                patch.object(self.figures, 'source_inventory', wraps=self.figures.source_inventory) as sql:
            source = self.validate()
            proofs = self.proof_contexts()[0]
            self.assertTrue(proofs['retained'])
            self.assertTrue(proofs['inventory'])
            pinned = self.pin()
            counts = {root: sum(Path(call.args[0]) == root for call in verify.call_args_list)
                      for root in (self.parent, self.child, self.args.output, next(iter(pinned.values())).parent)}
            self.assertEqual(set(counts.values()), {1})
            self.assertEqual(sql.call_count, 1)
            destination = b.validated_figure_tuple(pinned)
            self.assertEqual(source, destination)
            destination['figure-sizing'][0]['coverage']['files'] = -1
            self.assertNotEqual(b.validated_figure_tuple(pinned)['figure-sizing'][0]['coverage']['files'], -1)
        self.assertEqual(self.proof_contexts(), [])
        self.assertEqual(proofs['retained'], {})
        self.assertEqual(proofs['inventory'], {})
        for role in self.paths:
            self.assertEqual(self.paths[role].read_bytes(), pinned[role].read_bytes())

    def test_stale_external_parent_sql_member_inode_and_helper_refuse_before_pin(self):
        artifact = self.observation.parent/next(iter(json.loads(self.observation.read_text())['artifacts']))
        cases = (('bytes', self.parent/self.figures.PROVIDER), ('sql', self.args.sql[0]),
                 ('retained', artifact), ('inode', self.parent/self.figures.ROLES['figure-sizing-raw']),
                 ('member', self.parent/'unrecorded.raw'))
        for mode, path in cases:
            with self.subTest(mode=mode):
                b._FIGURE_TUPLE_REPLAYS.clear()
                self.validate()
                proofs = self.proof_contexts()[0]
                original = None if mode == 'member' else path.read_bytes()
                try:
                    if mode == 'inode':
                        replacement = path.with_name(path.name+'.replacement')
                        replacement.write_bytes(original)
                        os.replace(replacement, path)
                    else:
                        path.write_bytes(b'extra' if original is None else original+b'x')
                    with patch.object(b, 'copy_verified_snapshot', side_effect=AssertionError('Changed source reached copying')):
                        with self.assertRaises(ValueError):
                            self.pin()
                finally:
                    if original is None: path.unlink()
                    else: path.write_bytes(original)
                self.assertEqual(proofs['retained'], {})
                self.assertEqual(proofs['inventory'], {})
        b._FIGURE_TUPLE_REPLAYS.clear()
        self.validate()
        with patch.object(self.figures, 'producer', return_value=dict(self.figures.producer(), generator_sha256='0'*64)):
            with self.assertRaisesRegex(ValueError, 'changed'):
                self.pin()
        self.assertEqual(self.proof_contexts(), [])

    def test_destination_corruption_still_reaches_full_semantic_refusal_and_releases_proofs(self):
        self.validate()
        proofs = self.proof_contexts()[0]
        original = b.copy_verified_snapshot
        def corrupt(source, destination, digest):
            result = original(source, destination, digest)
            if destination.name == self.figures.PROVIDER:
                destination.write_bytes(destination.read_bytes()+b'corrupt\n')
            return result
        with patch.object(b, 'copy_verified_snapshot', side_effect=corrupt), \
                patch.object(self.figures, 'verify', wraps=self.figures.verify) as verify:
            with self.assertRaises(ValueError):
                self.pin()
            self.assertTrue(any(Path(call.args[0]) == self.fixture.root/'pinned'/'figure-inputs'
                                for call in verify.call_args_list))
        self.assertEqual(proofs['retained'], {})
        self.assertEqual(proofs['inventory'], {})
        self.assertEqual(self.proof_contexts(), [])

    def test_parent_change_after_destination_replay_is_rejected_by_final_guard(self):
        self.validate()
        path = self.parent/self.figures.PROVIDER
        original_bytes = path.read_bytes()
        original = self.figures.verify
        destination = self.fixture.root/'pinned'/'figure-inputs'
        def changed(root, *args, **kwargs):
            result = original(root, *args, **kwargs)
            if Path(root) == destination:
                path.write_bytes(original_bytes+b'changed after semantic replay')
            return result
        try:
            with patch.object(self.figures, 'verify', side_effect=changed):
                with self.assertRaisesRegex(ValueError, 'changed during validation'):
                    self.pin()
        finally:
            path.write_bytes(original_bytes)
        self.assertEqual(self.proof_contexts(), [])

    def test_legacy_helper_signature_keeps_full_parent_replay(self):
        original = self.figures.verify_tuple
        def legacy(paths, wiki=None, date=None):
            return original(paths, wiki, date)
        with patch.object(self.figures, 'verify_tuple', legacy), \
                patch.object(self.figures, 'verify', wraps=self.figures.verify) as verify:
            self.validate()
            self.pin()
            self.assertEqual(sum(Path(call.args[0]) == self.parent for call in verify.call_args_list), 2)
        self.assertEqual(self.proof_contexts(), [])

    def test_validation_typeerror_is_not_retried_or_cached(self):
        calls = []
        def broken(paths, wiki=None, date=None, *, retained_cache=None, inventory_cache=None):
            calls.append((retained_cache, inventory_cache))
            retained_cache['partial'] = {'partial': True}
            raise TypeError('Actual validation failure')
        with patch.object(self.figures, 'verify_tuple', broken):
            with self.assertRaisesRegex(TypeError, 'Actual validation failure'):
                self.validate()
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0], ({}, {}))
        self.assertEqual(b._FIGURE_TUPLE_REPLAYS, {})

    def test_main_resolver_proof_is_exclusively_transferred_to_normal_pool_worker(self):
        with patch.object(self.figures, 'verify', wraps=self.figures.verify) as verify:
            # The ordinary resolver calls this on main; build_groups submits
            # the later pinning operation to its ThreadPoolExecutor worker.
            hashes = b.verified_auxiliary_hashes(self.paths, self.fixture.wiki, self.fixture.date)
            proofs = self.proof_contexts()[0]
            self.assertIs(proofs['owner'], threading.current_thread())
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                pinned = pool.submit(b.pinned_auxiliary_snapshots, self.paths, hashes,
                                     self.fixture.root/'pinned').result()
            self.assertIsNot(proofs['owner'], threading.current_thread())
            self.assertEqual(sum(Path(call.args[0]) == self.parent for call in verify.call_args_list), 1)
            self.assertEqual(sum(Path(call.args[0]) == next(iter(pinned.values())).parent
                                 for call in verify.call_args_list), 1)
        self.assertEqual(proofs['retained'], {})
        self.assertEqual(proofs['inventory'], {})
        self.assertEqual(self.proof_contexts(), [])

    def test_competing_workers_cannot_share_or_clear_an_active_transferred_context(self):
        self.validate()
        transferred = self.proof_contexts()[0]
        barrier = threading.Barrier(2)
        entered = []
        original = self.figures.verify
        destinations = {self.fixture.root/name/'figure-inputs' for name in ('worker-one','worker-two')}
        def overlapping(root, *args, **kwargs):
            if Path(root) in destinations:
                with b._FIGURE_TUPLE_REPLAY_LOCK:
                    entered.append(kwargs['retained_cache'])
                barrier.wait(timeout=30)
                # Idle-cache release may not touch the detached active proof.
                b.release_figure_parent_replays()
                self.assertTrue(transferred['retained'])
                barrier.wait(timeout=30)
            return original(root, *args, **kwargs)
        with patch.object(self.figures, 'verify', side_effect=overlapping):
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                futures = [pool.submit(self.pin, destination.parent) for destination in sorted(destinations)]
                pinned = [future.result() for future in futures]
        self.assertEqual(len(entered), 2)
        self.assertIsNot(entered[0], entered[1])
        self.assertEqual(sum(value is transferred['retained'] for value in entered), 1)
        self.assertEqual(entered, [{}, {}])
        self.assertEqual(self.proof_contexts(), [])
        self.assertEqual(set(path.parent for paths in pinned for path in paths.values()), destinations)

    def test_pool_worker_refuses_stale_source_and_destination_typeerror_without_replay_retry(self):
        self.validate()
        proofs = self.proof_contexts()[0]
        path = self.parent/self.figures.PROVIDER
        original_bytes = path.read_bytes()
        try:
            path.write_bytes(original_bytes+b'changed')
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                with self.assertRaisesRegex(ValueError, 'changed'):
                    pool.submit(self.pin).result()
        finally:
            path.write_bytes(original_bytes)
        self.assertEqual(proofs['retained'], {})
        self.assertEqual(proofs['inventory'], {})
        b._FIGURE_TUPLE_REPLAYS.clear()
        self.validate()
        proofs = self.proof_contexts()[0]
        calls = []
        def broken(paths, wiki=None, date=None, *, retained_cache=None, inventory_cache=None):
            calls.append(paths)
            self.assertIs(retained_cache, proofs['retained'])
            raise TypeError('Actual destination validation failure')
        with patch.object(self.figures, 'verify_tuple', broken):
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                with self.assertRaisesRegex(TypeError, 'Actual destination validation failure'):
                    pool.submit(self.pin).result()
        self.assertEqual(len(calls), 1)
        self.assertEqual(proofs['retained'], {})
        self.assertEqual(proofs['inventory'], {})
        self.assertEqual(self.proof_contexts(), [])

        b._FIGURE_TUPLE_REPLAYS.clear()
        self.validate()
        proofs = self.proof_contexts()[0]
        copy = b.copy_verified_snapshot
        def corrupt(source, destination, digest):
            result = copy(source, destination, digest)
            if destination.name == self.figures.PROVIDER:
                destination.write_bytes(destination.read_bytes()+b'corrupt\n')
            return result
        with patch.object(b, 'copy_verified_snapshot', side_effect=corrupt):
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                with self.assertRaises(ValueError):
                    pool.submit(self.pin).result()
        self.assertEqual(proofs['retained'], {})
        self.assertEqual(proofs['inventory'], {})
        self.assertEqual(self.proof_contexts(), [])

    def test_one_proof_context_per_thread_and_nested_validation_cannot_clear_borrowed_context(self):
        self.validate()
        first = self.proof_contexts()[0]
        other_paths = {role: self.child/path.name for role, path in self.paths.items()}
        b.validated_figure_tuple(other_paths)
        self.assertEqual(first['retained'], {})
        self.assertEqual(first['inventory'], {})
        self.assertEqual(len(self.proof_contexts()), 1)
        b._FIGURE_TUPLE_REPLAYS.clear()
        self.validate()
        active = self.proof_contexts()[0]
        original = self.figures.verify
        destination = self.fixture.root/'pinned'/'figure-inputs'
        def nested(root, *args, **kwargs):
            if Path(root) == destination:
                self.assertIs(kwargs['retained_cache'], active['retained'])
                b.validated_figure_tuple(other_paths)
                self.assertTrue(active['retained'])
            return original(root, *args, **kwargs)
        with patch.object(self.figures, 'verify', side_effect=nested):
            self.pin()
        self.assertEqual(active['retained'], {})
        self.assertEqual(active['inventory'], {})
        self.assertEqual(self.proof_contexts(), [])


class WikibaseProviderGenerationTests(unittest.TestCase):
    def identity(self):
        return dict(version=b.SHARD_STATE_VERSION,edition='testwiktionary',date='20261001',
            source='a'*64,production_source='b'*64,files=[['dump',1,'c'*40]],registry_sha256='d'*64,
            auxiliary_snapshot_sha256={'wikibase-entities':'1'*64,'wikibase-entity-terms':'2'*64,'other':'3'*64},
            auxiliary_capture_sha256={'wikibase-entities':'4'*64,'wikibase-entity-terms':'5'*64,'other':'6'*64},
            auxiliary_capture_artifact_sha256={'wikibase-entities':'7'*64,'wikibase-entity-terms':'8'*64,'other':'9'*64})

    def changed(self,before):
        value=json.loads(json.dumps(before))
        for field in ('auxiliary_snapshot_sha256','auxiliary_capture_sha256','auxiliary_capture_artifact_sha256'):
            for name in b.WIKIBASE_PROVIDER_ROLES:value[field][name]='e'*64
        return value

    def workspace(self,root,bound=True):
        work=root/'work';old=self.identity();dump=work/'input/pages.xml.zst'
        for name,raw in {'input/pages.xml.zst':b'dump','expander/.incomplete':b'expander ready',
                         'expander/.bundle-expander/dict-bundle-expander':b'original native worker',
                         'expander/.bundle-expander/lua-program.meta':b'original native program',
                         'shards/00000000/blob':b'old Provider result','old-provider.tsv':b'old metadata'}.items():
            path=work/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(raw)
        state=dict(old,now_unix=123)
        if bound:state['native_generation']=dict(seal_sha256='f'*64,dump=str(dump),build_inputs=old)
        (work/'state.json').write_text(json.dumps(state))
        return work,dump,old

    def test_only_complete_entity_pair_authority_may_differ(self):
        before=self.identity();after=self.changed(before)
        self.assertTrue(b.wikibase_provider_only_change(before,after))
        self.assertFalse(b.wikibase_provider_only_change(before,before))
        for case in ('source','production_source','files','registry_sha256','tool','other-hash','missing-pair','wrong-hash','extra-role'):
            changed=json.loads(json.dumps(after))
            if case=='tool':changed['native_tool_roles']={'new':'role'}
            elif case=='other-hash':changed['auxiliary_snapshot_sha256']['other']='0'*64
            elif case=='missing-pair':del changed['auxiliary_capture_sha256']['wikibase-entity-terms']
            elif case=='wrong-hash':changed['auxiliary_capture_artifact_sha256']['wikibase-entities']=True
            elif case=='extra-role':changed['auxiliary_snapshot_sha256']['new']='0'*64
            else:changed[case]='changed'
            with self.subTest(case=case):self.assertFalse(b.wikibase_provider_only_change(before,changed))

    def test_bound_provider_reset_keeps_native_inode_and_invalidates_all_page_results(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);work,dump,old=self.workspace(root);expected=self.changed(old)
            native=work/'expander/.bundle-expander/dict-bundle-expander';stamp=native.stat().st_ino
            calls=[];proof={}
            def prepare(selected,selected_dump,digest):
                self.assertEqual(selected,work/'expander/.bundle-expander')
                self.assertEqual(selected_dump,dump);self.assertEqual(digest,'f'*64)
                self.assertTrue((work/'shards/00000000/blob').exists())
                calls.append('verified-before-reset')
                return dict(root=str(selected),dump=str(dump),record={'unchanged-native-origin':True})
            cache=SimpleNamespace(prepare_wikibase_provider_update=prepare,PROVIDER_UPDATE_MARKER=b'updating Wikibase providers\n')
            with patch.object(b,'PROJECT',root),patch.dict(sys.modules,extraction_cache=cache):
                self.assertEqual(456,b.prepare_shard_workspace(work,expected,456,provider_update=proof,build_identity=expected,dump=dump))
            self.assertEqual(['verified-before-reset'],calls)
            self.assertEqual(stamp,native.stat().st_ino);self.assertEqual(b'original native worker',native.read_bytes())
            self.assertEqual(b'original native program',(native.parent/'lua-program.meta').read_bytes())
            self.assertEqual(cache.PROVIDER_UPDATE_MARKER,(native.parent/'.incomplete').read_bytes())
            self.assertFalse((work/'shards').exists());self.assertFalse((work/'old-provider.tsv').exists())
            self.assertEqual(b'dump',dump.read_bytes())
            self.assertNotIn('native_generation',json.loads((work/'state.json').read_text()))
            self.assertEqual(str(native.parent),proof['root'])

    def test_unsealed_or_nonentity_change_keeps_existing_rebuild_path(self):
        for case in ('unsealed','source','other-provider','old-seal'):
            with self.subTest(case=case),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);work,dump,old=self.workspace(root,bound=case!='unsealed');expected=self.changed(old)
                if case=='source':expected['production_source']='0'*64
                elif case=='other-provider':expected['auxiliary_snapshot_sha256']['other']='0'*64
                calls=[]
                def prepare(*args):calls.append(args);return None
                cache=SimpleNamespace(prepare_wikibase_provider_update=prepare,PROVIDER_UPDATE_MARKER=b'updating Wikibase providers\n')
                with patch.object(b,'PROJECT',root),patch.dict(sys.modules,extraction_cache=cache):
                    proof={};b.prepare_shard_workspace(work,expected,456,provider_update=proof,build_identity=expected,dump=dump)
                self.assertFalse(proof);self.assertFalse((work/'expander').exists());self.assertTrue(dump.exists())
                self.assertEqual(1 if case=='old-seal' else 0,len(calls))

    def test_state_publication_failure_never_publishes_provider_ready(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);work,dump,old=self.workspace(root);expander=work/'expander/.bundle-expander'
            (expander/'.completed-expander.json').write_bytes(b'fresh successor proof')
            (expander/'.incomplete').write_bytes(b'updating Wikibase providers\n')
            original=(work/'state.json').read_bytes();calls=[]
            def verify(*args,**kwargs):calls.append((args,kwargs));return {'verified':True}
            cache=SimpleNamespace(COMPLETED_EXPANDER='.completed-expander.json',PROVIDER_UPDATE_MARKER=b'updating Wikibase providers\n',
                                  frozen_runtime_context=verify)
            failure=OSError('controlled state publication failure')
            with patch.dict(sys.modules,extraction_cache=cache),patch.object(b.os,'replace',side_effect=failure):
                with self.assertRaises(OSError) as caught:b.bind_native_generation(work,dump,self.changed(old),updating=True)
            self.assertIs(failure,caught.exception);self.assertEqual(1,len(calls))
            self.assertEqual({'provider_update':True},calls[0][1])
            self.assertEqual(original,(work/'state.json').read_bytes())
            self.assertTrue((expander/'.incomplete').exists());self.assertFalse((work/'state.part').exists())

    def test_final_provider_validation_failure_leaves_unready_generation(self):
        for outcome in (None,ValueError('controlled final source drift')):
            with self.subTest(outcome=outcome),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);work,dump,old=self.workspace(root);expander=work/'expander/.bundle-expander'
                (expander/'.completed-expander.json').write_bytes(b'fresh successor proof')
                (expander/'.incomplete').write_bytes(b'updating Wikibase providers\n')
                calls=[]
                def verify(*args,**kwargs):
                    calls.append(kwargs)
                    self.assertTrue((expander/'.incomplete').exists())
                    if len(calls)==1:return {'verified':True}
                    if isinstance(outcome,Exception):raise outcome
                    return outcome
                cache=SimpleNamespace(COMPLETED_EXPANDER='.completed-expander.json',PROVIDER_UPDATE_MARKER=b'updating Wikibase providers\n',
                                      frozen_runtime_context=verify)
                with patch.dict(sys.modules,extraction_cache=cache),self.assertRaises(ValueError):
                    b.bind_native_generation(work,dump,self.changed(old),updating=True)
                self.assertEqual([{'provider_update':True}]*2,calls)
                self.assertTrue((expander/'.incomplete').exists())

    def test_normal_new_build_requests_seal_and_provider_update_skips_native_preparation(self):
        class Boundary(Exception):pass
        for mode in ('fresh','provider','unready'):
            updating=mode=='provider'
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);work=root/'work';(work/'input').mkdir(parents=True)
                (work/'state.json').write_text('{}')
                (work/'input/.complete.json').write_text(json.dumps({'dump_sha256':'a'*64,'index_sha256':'b'*64,'source_pages':1}))
                dump=work/'input/pages.xml.zst';dump.write_bytes(b'dump');calls=[]
                if mode=='unready':
                    (work/'state.json').write_text(json.dumps({'native_generation':dict(seal_sha256='f'*64,dump=str(dump),build_inputs={})}))
                proof=dict(root=str(work/'expander/.bundle-expander'),dump=str(dump)) if updating else None
                def prepare(*args,**kwargs):calls.append(('prepare',kwargs['expander_args']));return {}
                def bind(*args,**kwargs):calls.append(('bind',kwargs.get('updating',False)));return 'f'*64
                cache=SimpleNamespace(finish_wikibase_provider_update=lambda *args:calls.append(('update',args)),
                                      frozen_runtime_context=lambda *args:None)
                with patch.object(b,'PROJECT',root),patch.object(b,'_PREPARED_SOURCE',threading.local()), \
                     patch.dict(sys.modules,extraction_cache=cache),patch.object(b,'expander_ready',return_value=updating), \
                     patch.object(b,'prepare_blob_tools',side_effect=prepare),patch.object(b,'bind_native_generation',side_effect=bind), \
                     patch.object(b,'inspect_page_index',side_effect=Boundary):
                    with self.assertRaises(Boundary):
                        b.build_sharded(dump,root/'staging',work,root/'registry','zig',1,
                            [{'wiki':'testwiktionary','date':'20261001'}],123,
                            auxiliary_snapshots={name:root/(name+'.tsv') for name in b.WIKIBASE_PROVIDER_ROLES},
                            auxiliary_hashes={name:'e'*64 for name in b.WIKIBASE_PROVIDER_ROLES},
                            build_identity=self.changed(self.identity()),provider_update=proof)
                if updating:
                    self.assertEqual(['update','bind'],[entry[0] for entry in calls]);self.assertTrue(calls[-1][1])
                else:
                    self.assertEqual(['prepare','bind'],[entry[0] for entry in calls]);self.assertFalse(calls[-1][1])
                    self.assertEqual(1,calls[0][1].count('--seal-prepared-source'))


import copy

class RetainedNativeRoleTests(unittest.TestCase):
    def fixture(self, root):
        source=root/'source';source.mkdir()
        entries={}
        names=tuple(dict.fromkeys((*b.RETAINED_NATIVE_ABI_PATHS, *b.RETAINED_BUNDLE_RUNTIME_SOURCES,
               'tools/blob_build.zig', 'tools/blob_merge.zig', 'tools/blob_verify.zig', 'tools/bundle_build.zig',
               'src/encoder/presentation_compile.zig', 'src/encoder/presentation_document.zig', 'tools/figure_sizing.zig')))
        for name in names:
            path=source/name;path.parent.mkdir(parents=True,exist_ok=True)
            path.write_bytes(('source '+name).encode())
            entries[name]=dict(bytes=path.stat().st_size,sha256=b.sha256_file(path),mode=0o644)
        inventory=root/'source.json';inventory.write_text(json.dumps(entries,sort_keys=True))
        ref=dict(path=str(inventory),bytes=inventory.stat().st_size,sha256=b.sha256_file(inventory))
        compiler=root/'zig';compiler.write_bytes(b'compiler');compiler.chmod(0o755)
        def descriptor(path):
            return dict(path=str(path),bytes=path.stat().st_size,sha256=b.sha256_file(path),mode=path.stat().st_mode&0o777)
        dependencies={}
        for name in b.RETAINED_BUNDLE_DEPENDENCIES:
            path=compiler if name=='zig' else root/('dependency-'+name)
            if name!='zig':path.write_bytes(name.encode())
            dependencies[name]=descriptor(path)
        dependencies.update({'runtime_source:'+name:descriptor(source/name) for name in b.RETAINED_BUNDLE_RUNTIME_SOURCES})
        roles={}
        for role in b.RETAINED_NATIVE_ROLE_NAMES:
            path=root/role;path.write_bytes(('native '+role).encode());path.chmod(0o555)
            roles[role]=dict(artifact=descriptor(path),producer_source=ref['sha256'],source=ref,
                source_root=str(source),source_paths=list(names),zig_sha256=b.sha256_file(compiler),
                dependencies=copy.deepcopy(dependencies if role=='dict-bundle-build' else {name:dependencies[name] for name in ('zig','worker_object','value_leaf_bc','worker_main_c')}))
        return roles,compiler

    def test_retained_roles_select_existing_tools_and_expander_without_compile(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);roles,compiler=self.fixture(root)
            selection=b.RetainedNativeToolRoles(roles,zig_sha256=b.sha256_file(compiler))
            calls=[];events=[]
            identity=dict(source='current-orchestration',zig_sha256=b.sha256_file(compiler),native_tool_roles=selection.provenance())
            args=['dump',str(root/'output'),'--expander-only']
            with patch.object(b,'source_fingerprint',return_value=identity['source']), \
                 patch.object(b,'run_checked',side_effect=AssertionError('unexpected compiler execution')), \
                 patch.object(b,'timed_run',side_effect=lambda command,*a,**kw:calls.append(command)), \
                 patch.object(b,'phase_event',side_effect=lambda *a,**kw:events.append(kw)):
                tools=b.prepare_blob_tools(root/'workspace',str(compiler),'testwiktionary','20261001',
                    identity,expander_args=args,retained_roles=selection)
            self.assertEqual(set(tools),set(b.BLOB_TOOL_NAMES))
            self.assertEqual(calls,[[roles['dict-bundle-build']['artifact']['path'],*args]])
            self.assertFalse((root/'workspace'/'native-blob-tools').exists())
            record=events[-1]
            self.assertEqual(record['preparation'],'retained-role-selection')
            self.assertEqual(record['orchestration_source'],'current-orchestration')
            self.assertEqual(record['native_role_provenance'],roles)
            self.assertNotIn('source',record)

    def test_retained_roles_refuse_wrong_role_bytes_source_abi_and_dependencies(self):
        for failure in ('role','bytes','source','abi','dependency','missing-dependency','compiler'):
            with self.subTest(failure=failure),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);roles,compiler=self.fixture(root)
                writer=roles['dict-blob-build']
                if failure=='role':writer['artifact']=roles['dict-blob-verify']['artifact']
                elif failure=='bytes':writer['artifact']['sha256']='0'*64
                elif failure=='source':writer['producer_source']='0'*64
                elif failure=='abi':(Path(writer['source_root'])/b.RETAINED_NATIVE_ABI_PATHS[0]).write_bytes(b'changed ABI')
                elif failure=='dependency':roles['dict-bundle-build']['dependencies']['llvm']['sha256']='0'*64
                elif failure=='missing-dependency':del roles['dict-bundle-build']['dependencies']['pipeline_paths']
                else:writer['zig_sha256']='0'*64
                with self.assertRaises(ValueError):
                    b.RetainedNativeToolRoles(roles,zig_sha256=b.sha256_file(compiler))

    def test_retained_roles_refuse_dependency_and_tool_replacement_before_dispatch(self):
        for kind in ('dependency','tool'):
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);roles,compiler=self.fixture(root)
                selection=b.RetainedNativeToolRoles(roles,zig_sha256=b.sha256_file(compiler))
                path=Path(roles['dict-bundle-build']['dependencies']['llvm']['path'] if kind=='dependency'
                          else roles['dict-blob-build']['artifact']['path'])
                replacement=root/'replacement';replacement.write_bytes(path.read_bytes());replacement.chmod(path.stat().st_mode&0o777)
                os.replace(replacement,path)
                with patch.object(b,'timed_run',side_effect=AssertionError('unexpected native dispatch')):
                    with self.assertRaises(ValueError):selection.prepare(['dump','out','--expander-only'],'testwiktionary','20261001')

    def test_retained_bundle_cannot_execute_its_embedded_writer(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);roles,compiler=self.fixture(root)
            selection=b.RetainedNativeToolRoles(roles,zig_sha256=b.sha256_file(compiler))
            with patch.object(b,'timed_run',side_effect=AssertionError('unexpected native dispatch')):
                for args in (['dump','out'], ['--expander-only','out'],
                             ['dump','--expander-only'],
                             ['dump','out','--namespace-registry-snapshot','--expander-only'],
                             ['dump','out','--expander-only','--expander-only']):
                    with self.assertRaisesRegex(ValueError,'expander-only'):
                        selection.prepare(args,'testwiktionary','20261001')

    def test_retained_roles_refuse_prepared_generation_authorization(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);roles,compiler=self.fixture(root)
            selection=b.RetainedNativeToolRoles(roles,zig_sha256=b.sha256_file(compiler))
            with patch.object(b,'source_fingerprint',return_value='current'), \
                 patch.object(b._PREPARED_SOURCE,'request',object(),create=True), \
                 patch.object(b,'run_checked',side_effect=AssertionError('unexpected build')):
                with self.assertRaisesRegex(ValueError,'ordinary preparation'):
                    b.prepare_blob_tools(root/'work',str(compiler),'testwiktionary','20261001',
                        dict(source='current',zig_sha256=b.sha256_file(compiler)),retained_roles=selection)

    def separate_source(self, root, row, changed):
        source=root/'independent-source';source.mkdir()
        entries={}
        for name in row['source_paths']:
            path=source/name;path.parent.mkdir(parents=True,exist_ok=True)
            path.write_bytes(changed.get(name,(Path(row['source_root'])/name).read_bytes()))
            entries[name]=dict(bytes=path.stat().st_size,sha256=b.sha256_file(path),mode=0o644)
        inventory=root/'independent-source.json';inventory.write_text(json.dumps(entries,sort_keys=True))
        row['source']=dict(path=str(inventory),bytes=inventory.stat().st_size,sha256=b.sha256_file(inventory))
        row['producer_source']=row['source']['sha256'];row['source_root']=str(source)

    def test_independently_authentic_different_abi_and_runtime_dependencies_refuse(self):
        for changed in ('abi','runtime'):
            with self.subTest(changed=changed),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);roles,compiler=self.fixture(root)
                row=roles['dict-blob-verify']
                if changed=='abi':
                    self.separate_source(root,row,{'src/encoder/presentation_types.zig':b'other authentic layout'})
                else:
                    path=root/'other-leaf.bc';path.write_bytes(b'independently authentic other leaf')
                    row['dependencies']['value_leaf_bc']=dict(path=str(path),bytes=path.stat().st_size,
                        sha256=b.sha256_file(path),mode=0o644)
                with self.assertRaisesRegex(ValueError,'incompatible'):
                    b.RetainedNativeToolRoles(roles,zig_sha256=b.sha256_file(compiler))

    def test_different_authentic_renderer_implementation_does_not_require_whole_source_equality(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);roles,compiler=self.fixture(root)
            self.separate_source(root,roles['dict-blob-build'],{'tools/blob_build.zig':b'another qualified renderer implementation'})
            selection=b.RetainedNativeToolRoles(roles,zig_sha256=b.sha256_file(compiler))
            self.assertNotEqual(selection.records['dict-blob-build']['producer_source'],
                                selection.records['dict-blob-verify']['producer_source'])

    def test_returned_role_guards_dependencies_before_and_after_each_dispatch(self):
        for when in ('before','during'):
            with self.subTest(when=when),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);roles,compiler=self.fixture(root)
                selection=b.RetainedNativeToolRoles(roles,zig_sha256=b.sha256_file(compiler))
                tool=selection.prepare(None,'testwiktionary','20261001')['dict-blob-build']
                dependency=Path(roles['dict-bundle-build']['dependencies']['llvm']['path'])
                calls=[]
                def dispatch(*a,**kw):
                    calls.append(a);dependency.write_bytes(b'changed during native execution')
                if when=='before':dependency.write_bytes(b'changed after prepare returned')
                with patch.object(b,'timed_run',side_effect=dispatch):
                    with self.assertRaisesRegex(ValueError,'dependency changed'):
                        tool.run(['args'],'testwiktionary','20261001','writer')
                self.assertEqual(len(calls),0 if when=='before' else 1)

    def test_original_role_provenance_is_bound_before_generation_and_persisted(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);roles,compiler=self.fixture(root)
            selection=b.RetainedNativeToolRoles(roles,zig_sha256=b.sha256_file(compiler))
            with patch.object(b,'source_fingerprint',return_value='current-orchestration'):
                identity=b.build_input_identity([],str(compiler),{},None,None,native_roles=selection)
                staging=root/'staging';staging.mkdir()
                b.persist_build_identity(staging,identity)
            saved=json.loads((staging/b.BUILD_IDENTITY_NAME).read_text())
            self.assertEqual(saved['native_tool_roles'],roles)
            self.assertEqual(saved['source'],'current-orchestration')
            # publish_verified_staging writes this same exact build_identity
            # into complete.json['build_inputs']; no per-role source restamp.
            with patch.object(b,'source_fingerprint',return_value='current-orchestration'), \
                 patch.object(b,'run_checked',side_effect=AssertionError('unexpected compiler')):
                wrong=dict(identity);wrong.pop('native_tool_roles')
                with self.assertRaisesRegex(ValueError,'ordinary preparation'):
                    b.prepare_blob_tools(root/'work',str(compiler),'testwiktionary','20261001',wrong,retained_roles=selection)

    def test_retained_bundle_uses_bound_source_working_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);roles,compiler=self.fixture(root)
            selection=b.RetainedNativeToolRoles(roles,zig_sha256=b.sha256_file(compiler))
            calls=[]
            with patch.object(b.subprocess,'run',side_effect=lambda *a,**kw:calls.append((a,kw))):
                selection.prepare(['dump','out','--expander-only'],'testwiktionary','20261001')
            self.assertEqual(len(calls),1)
            self.assertEqual(calls[0][1]['cwd'],Path(roles['dict-bundle-build']['source_root']))
            with patch.object(b.subprocess,'run',side_effect=AssertionError('unexpected native dispatch')):
                with self.assertRaisesRegex(ValueError,'cannot be overridden'):
                    selection.tools['dict-bundle-build'].run(['dump','out','--expander-only'],
                        'testwiktionary','20261001','probe',native_working_directory=root)

    def test_writable_cached_bundle_is_privately_installed_without_origin_mutation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);roles,compiler=self.fixture(root)
            origin=Path(roles['dict-bundle-build']['artifact']['path'])
            origin.chmod(0o755);roles['dict-bundle-build']['artifact']['mode']=0o755
            st=origin.stat();original=(st.st_dev,st.st_ino,st.st_mode,st.st_size,st.st_mtime_ns,st.st_ctime_ns)
            selection=b.RetainedNativeToolRoles(roles,zig_sha256=b.sha256_file(compiler))
            self.assertIsNone(selection.tools['dict-bundle-build'])
            workspace=root/'workspace';calls=[]
            with patch.object(b.subprocess,'run',side_effect=lambda *a,**kw:calls.append((a,kw))):
                selection.prepare(['dump','out','--expander-only'],'testwiktionary','20261001',workspace=workspace)
            target=workspace/'native-blob-tools/bin/dict-bundle-build'
            self.assertEqual(calls[0][0][0][0],str(target))
            self.assertEqual(target.read_bytes(),origin.read_bytes())
            self.assertEqual(target.stat().st_mode&0o777,0o555)
            self.assertEqual(target.stat().st_nlink,1)
            st=origin.stat();self.assertEqual(original,(st.st_dev,st.st_ino,st.st_mode,st.st_size,st.st_mtime_ns,st.st_ctime_ns))
            self.assertEqual(selection.provenance()['dict-bundle-build']['artifact']['path'],str(origin))
            self.assertEqual({p.name for p in target.parent.iterdir()},{'dict-bundle-build'})

    def test_unretained_tool_cannot_inject_selected_working_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);roles,_=self.fixture(root)
            tool=b.PreparedBlobTool(Path(roles['dict-blob-build']['artifact']['path']))
            with patch.object(b.subprocess,'run',side_effect=AssertionError('unexpected execution')):
                with self.assertRaisesRegex(ValueError,'cannot be overridden'):
                    tool.run(['args'],'testwiktionary','20261001','writer',native_working_directory=root)

    def test_normal_role_json_parser_and_ordinary_route_refusals(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);roles,compiler=self.fixture(root);raw=json.dumps(roles)
            selected=b.parse_retained_native_roles(raw,str(compiler),sharded=True,edition_count=1,jobs=1)
            self.assertEqual(selected.provenance(),roles)
            self.assertIsNone(b.parse_retained_native_roles(None,str(compiler),sharded=False,edition_count=2,jobs=2))
            for sharded,count,jobs in ((False,1,1),(True,2,1),(True,1,2)):
                with self.assertRaisesRegex(ValueError,'ordinary compressed edition'):
                    b.parse_retained_native_roles(raw,str(compiler),sharded=sharded,edition_count=count,jobs=jobs)
            with patch.dict(os.environ,{'WIKIDICT_PREPARED_SOURCE_ATTEMPT':'{}'}):
                with self.assertRaisesRegex(ValueError,'ordinary compressed edition'):
                    b.parse_retained_native_roles(raw,str(compiler),sharded=True,edition_count=1,jobs=1)

    def test_selected_sharded_route_forwards_real_roles_and_flag_before_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);roles,compiler=self.fixture(root)
            selected=b.RetainedNativeToolRoles(roles,zig_sha256=b.sha256_file(compiler))
            workspace=root/'work';(workspace/'input').mkdir(parents=True)
            (workspace/'input/.complete.json').write_text(json.dumps(dict(dump_sha256='a'*64,index_sha256='b'*64)))
            identity=dict(source='current',zig_sha256=b.sha256_file(compiler),native_tool_roles=selected.provenance())
            original=subprocess.CalledProcessError(7,['original selected bundle error']);calls=[]
            def dispatch(command,*a,**kw):calls.append((command,kw));raise original
            with patch.object(b,'source_fingerprint',return_value='current'), \
                 patch.object(b,'expander_ready',return_value=False), \
                 patch.object(b,'pipeline_snapshot_args',return_value=[]), \
                 patch.object(b,'run_checked',side_effect=AssertionError('unexpected compile')), \
                 patch.object(b,'timed_run',side_effect=dispatch),patch.object(b,'inspect_page_index') as inspect:
                with self.assertRaises(subprocess.CalledProcessError) as failed:
                    b.build_sharded(root/'dump',root/'staging',workspace,root/'namespace',str(compiler),1,
                        [dict(wiki='testwiktionary',date='20261001')],123,build_identity=identity,
                        retained_roles=selected,compress_shards=True)
            self.assertIs(failed.exception,original)
            self.assertEqual(len(calls),1)
            self.assertEqual(calls[0][0][1:4],[str(root/'dump'),str(workspace/'expander'),'--expander-only'])
            self.assertEqual(calls[0][1]['native_working_directory'],Path(roles['dict-bundle-build']['source_root']))
            inspect.assert_not_called()
            self.assertFalse((workspace/'shards').exists())

    def test_programmatic_nonsharded_route_cannot_claim_retained_tool_provenance(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);roles,compiler=self.fixture(root)
            selected=b.RetainedNativeToolRoles(roles,zig_sha256=b.sha256_file(compiler))
            with self.assertRaisesRegex(ValueError,'ordinary compressed sharded'):
                b._build_locked([],root,root,str(compiler),retained_roles=selected)

    def test_small_edition_routes_selected_roles_and_identity_to_sharded_writer(self):
        import ast,inspect,textwrap
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);roles,compiler=self.fixture(root)
            selected=b.RetainedNativeToolRoles(roles,zig_sha256=b.sha256_file(compiler))
            identity=dict(source='current',native_tool_roles=selected.provenance())
            # Execute the maintained dispatch statement itself with one source
            # page, stopping at its existing native-build boundary. This is not
            # a synthetic copy of the routing predicate or a whole-build claim.
            function=ast.parse(textwrap.dedent(inspect.getsource(b._build_locked))).body[0]
            dispatch=next(node for node in function.body if isinstance(node,ast.If)
                and any(isinstance(child,ast.Name) and child.id=='source_pages' for child in ast.walk(node.test)))
            scope=dict(b.__dict__)
            scope.update(source_pages=1,reviewed=None,presentation_audit_pages=None,retained_roles=selected,
                continue_failed_shards=False,provider_update={},
                edition='testwiktionary',date='20261001',dump=root/'dump',staging=root/'staging',
                workspace=root/'work',registry=root/'registry',zig=str(compiler),workers=1,items=[],now_unix=1,
                expansion_workers=1,pinned=None,interwiki_sha=None,aux_pinned={},auxiliary_hashes={},
                build_identity=identity,page_links_snapshot=None,page_redirects_snapshot=None,
                expansion_timeout_ms=None,raw_shards_path=None,compress_shards=True,
                extraction_cache_root=None,llvm_explicit=False,llvm_workers=1,
                staged_input_root=None,_staged_input_guard=None)
            calls=[]
            scope['build_sharded']=lambda *a,**kw:calls.append((a,kw))
            scope['timed_run']=lambda *a,**kw:self.fail('selected roles reached current nonsharded compiler')
            exec(compile(ast.Module(body=[dispatch],type_ignores=[]),'<maintained-small-edition-dispatch>','exec'),scope)
            self.assertEqual(len(calls),1)
            self.assertIs(calls[0][1]['retained_roles'],selected)
            self.assertIs(calls[0][1]['build_identity'],identity)
            self.assertTrue(calls[0][1]['compress_shards'])

    def test_normal_main_forwards_parsed_roles_to_existing_single_edition_options(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);roles,compiler=self.fixture(root)
            name='enwiktionary-20261001-pages-meta-current.xml.bz2'
            item=dict(wiki='enwiktionary',date='20261001',name=name,
                url='https://dumps.wikimedia.org/enwiktionary/20261001/'+name,size=1,sha1='a'*40)
            write_test_manifest(root,{'files':[item]})
            argv=['build_wiktionaries.py','--downloads',str(root),'--output',str(root/'out'),
                '--wikis','enwiktionary','--threads','1','--jobs','1','--compress-shards',
                '--zig',str(compiler),'--retained-native-roles-json',json.dumps(roles)]
            with contextlib.chdir(root),patch.object(sys,'argv',argv),patch.object(b,'PROJECT',root),patch.object(b,'safe_worker_budget',return_value=4), \
                 patch.object(b,'resolve_edition_snapshot_options',return_value={('enwiktionary','20261001'):{}}), \
                 patch.object(b,'build_groups',return_value=[]) as groups:
                b.main()
            selected=groups.call_args.kwargs['edition_options'][('enwiktionary','20261001')]['retained_roles']
            self.assertEqual(selected.provenance(),roles)
            self.assertTrue(groups.call_args.kwargs['compress_shards'])

    def test_immutable_git_payloads_preserve_old_source_after_renderer_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);roles,compiler=self.fixture(root);source=Path(roles['dict-blob-build']['source_root'])
            subprocess.run(['git','init','-q',str(source)],check=True)
            subprocess.run(['git','-c','core.autocrlf=false','add','--all'],cwd=source,check=True)
            subprocess.run(['git','-c','user.name=Fixture','-c','user.email=fixture@example.invalid',
                '-c','commit.gpgsign=false','commit','-qm','original payloads'],cwd=source,check=True)
            commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=source,text=True).strip()
            original_source=roles['dict-blob-build']['producer_source']
            for row in roles.values():row['source_payload_git']=dict(repository=str(source),commit=commit)
            for relative in ('tools/blob_build.zig','tools/figure_sizing.zig',
                             'src/encoder/presentation_compile.zig','src/encoder/presentation_document.zig'):
                (source/relative).write_bytes(b'new renderer source, not consumed by retained ELF')
            selection=b.RetainedNativeToolRoles(roles,zig_sha256=b.sha256_file(compiler))
            self.assertEqual(selection.provenance()['dict-blob-build']['producer_source'],original_source)
            # Later source removal cannot invalidate code already authenticated
            # from immutable Git payloads. Actual runtime helper drift still can.
            (source/'tools/blob_build.zig').unlink()
            tools=selection.prepare(None,'testwiktionary','20261001')
            with patch.object(b,'timed_run') as run:
                tools['dict-blob-build'].run(['args'],'testwiktionary','20261001','writer')
                run.assert_called_once()
            selection_again=b.RetainedNativeToolRoles(roles,zig_sha256=b.sha256_file(compiler))
            self.assertEqual(selection_again.provenance()['dict-blob-build']['producer_source'],original_source)
            (source/'tools/extraction_cache.py').write_bytes(b'changed actual runtime helper')
            with patch.object(b,'timed_run',side_effect=AssertionError('unexpected native dispatch')):
                with self.assertRaisesRegex(ValueError,'dependency changed'):
                    tools['dict-blob-build'].run(['args'],'testwiktionary','20261001','writer')

    def test_wrong_immutable_payload_commit_refuses_without_source_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);roles,compiler=self.fixture(root)
            row=roles['dict-blob-build'];row['source_payload_git']=dict(repository=str(root),commit='0'*40)
            with self.assertRaises((ValueError,subprocess.CalledProcessError)):
                b.RetainedNativeToolRoles(roles,zig_sha256=b.sha256_file(compiler))


    def retained_payload_files(self, root, roles):
        source=Path(roles['dict-blob-build']['source_root'])
        archive=root/'original-payloads';archive.mkdir()
        mapped={}
        for number,relative in enumerate(('tools/blob_build.zig','tools/figure_sizing.zig',
                'src/encoder/presentation_compile.zig','src/encoder/presentation_document.zig')):
            path=archive/str(number);path.write_bytes((source/relative).read_bytes())
            mapped[relative]=dict(path=str(path),bytes=path.stat().st_size,
                sha256=b.sha256_file(path),mode=path.stat().st_mode&0o777)
        for row in roles.values():row['source_payload_files']=copy.deepcopy(mapped)
        return source,mapped

    def test_per_file_payload_custody_preserves_original_source_after_live_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);roles,compiler=self.fixture(root);source,mapped=self.retained_payload_files(root,roles)
            original=roles['dict-blob-build']['producer_source']
            for relative in mapped:(source/relative).write_bytes(b'new source not consumed by old binary')
            selection=b.RetainedNativeToolRoles(roles,zig_sha256=b.sha256_file(compiler))
            self.assertEqual(selection.provenance()['dict-blob-build']['producer_source'],original)
            for relative in mapped:(source/relative).unlink()
            selected=b.RetainedNativeToolRoles(roles,zig_sha256=b.sha256_file(compiler))
            tools=selected.prepare(None,'testwiktionary','20261001')
            with patch.object(b,'timed_run') as run:
                tools['dict-blob-build'].run(['args'],'testwiktionary','20261001','writer')
                run.assert_called_once()

    def test_per_file_payload_invalid_authority_refuses_without_live_fallback(self):
        for mode in ('bytes','missing','foreign','mode','duplicate','unbound','forged'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);roles,compiler=self.fixture(root);source,mapped=self.retained_payload_files(root,roles)
                row=roles['dict-blob-build'];relative='tools/blob_build.zig'
                if mode=='bytes':Path(mapped[relative]['path']).write_bytes(b'changed immutable bytes')
                elif mode=='missing':Path(mapped[relative]['path']).unlink()
                elif mode=='foreign':row['source_payload_files']['not/in/projection']=mapped[relative]
                elif mode=='duplicate':row['source_payload_files']['tools/figure_sizing.zig']=copy.deepcopy(mapped[relative])
                elif mode=='unbound':row['source_payload_files'][relative]={}
                elif mode=='forged':
                    path=Path(mapped[relative]['path']);path.write_bytes(b'forged payload with honest new descriptor')
                    row['source_payload_files'][relative].update(bytes=path.stat().st_size,sha256=b.sha256_file(path))
                else:row['source_payload_files'][relative]['mode']=True
                with self.assertRaises((ValueError,FileNotFoundError)):
                    b.RetainedNativeToolRoles(roles,zig_sha256=b.sha256_file(compiler))

    def test_per_file_payload_custody_does_not_waive_actual_runtime_dependencies(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);roles,compiler=self.fixture(root);source,mapped=self.retained_payload_files(root,roles)
            selection=b.RetainedNativeToolRoles(roles,zig_sha256=b.sha256_file(compiler))
            tools=selection.prepare(None,'testwiktionary','20261001')
            (source/'tools/extraction_cache.py').write_bytes(b'changed runtime helper')
            with patch.object(b,'timed_run',side_effect=AssertionError('must not dispatch')):
                with self.assertRaisesRegex(ValueError,'dependency changed'):
                    tools['dict-blob-build'].run(['args'],'testwiktionary','20261001','writer')


class RetainedNativeFigureCompatibilityTests(unittest.TestCase):
    fixture=RetainedNativeRoleTests.fixture

    def test_retained_writer_compatibility_precedes_expander_and_refusal_stops(self):
        for refuse in (False,True):
            with self.subTest(refuse=refuse),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);roles,compiler=self.fixture(root)
                selection=b.RetainedNativeToolRoles(roles,zig_sha256=b.sha256_file(compiler))
                paths=[]
                for i in range(5):
                    path=root/('figure-'+str(i));path.write_bytes(b'bound figure input');paths.append(path)
                identity=dict(source='orchestration',zig_sha256=b.sha256_file(compiler),native_tool_roles=selection.provenance())
                calls=[]
                def run(command,*args,**kwargs):
                    calls.append(command)
                    if refuse and '--check-figure-compatibility' in command:
                        raise subprocess.CalledProcessError(2,command)
                with patch.object(b,'source_fingerprint',return_value=identity['source']),patch.object(b,'timed_run',side_effect=run),patch.object(b,'run_checked',side_effect=AssertionError('native compile')):
                    if refuse:
                        with self.assertRaises(subprocess.CalledProcessError):
                            b.prepare_blob_tools(root/'workspace',str(compiler),'testwiktionary','20261001',identity,expander_args=['dump','output','--expander-only'],figure_inputs=tuple(paths),retained_roles=selection)
                    else:
                        b.prepare_blob_tools(root/'workspace',str(compiler),'testwiktionary','20261001',identity,expander_args=['dump','output','--expander-only'],figure_inputs=tuple(paths),retained_roles=selection)
                self.assertEqual(len(calls),1 if refuse else 2)
                self.assertEqual(calls[0],[roles['dict-blob-build']['artifact']['path'],'--check-figure-compatibility',*(str(p) for p in paths)])
                if not refuse:self.assertEqual(calls[1],[roles['dict-bundle-build']['artifact']['path'],'dump','output','--expander-only'])
                self.assertFalse((root/'workspace').exists())

    def test_retained_figure_input_mutation_stops_before_expander(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);roles,compiler=self.fixture(root)
            selection=b.RetainedNativeToolRoles(roles,zig_sha256=b.sha256_file(compiler))
            paths=[]
            for i in range(5):
                path=root/('figure-'+str(i));path.write_bytes(b'bound figure input');paths.append(path)
            calls=[]
            def run(command,*args,**kwargs):
                calls.append(command);paths[-1].write_bytes(b'changed during capability check')
            with patch.object(b,'timed_run',side_effect=run),self.assertRaisesRegex(ValueError,'Figure compatibility inputs changed'):
                selection.prepare(['dump','output','--expander-only'],'testwiktionary','20261001',figure_inputs=tuple(paths))
            self.assertEqual(len(calls),1)
            self.assertIn('--check-figure-compatibility',calls[0])


class PresentationInputContinuationTests(unittest.TestCase):
    def exercise_input_summary(self, change=None, legacy=False, native_exit=1):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            identities = []
            events = []
            native_calls = []
            def run(args, *unused, **kwargs):
                native_calls.append(args)
                dest = Path(args[1]); dest.mkdir()
                row = dict(schema='wikidict.presentation-audit.summary.v1', diagnostic_only=True,
                    inventory_complete=False, range_complete=True, failure_index_complete=True,
                    audit_scope='page-range', start_page=2, requested_limit=5, selected_end_exclusive=7,
                    reached_eof=False, index_rows_seen=8, semantic_acceptance=False,
                    publication_created=False, error_name=None, selected=5, dispatched=5, consumed=5,
                    skipped=0, direct_aliases=0, expansion_fallbacks=0, compile_attempts=3,
                    succeeded=2, failed=3, failure_records=3, payload_bytes=127, report_bytes=31,
                    expansion_input_failures=2, presentation_failures=1, expansion_complete=False)
                if legacy:
                    for key in ('expansion_input_failures', 'presentation_failures', 'expansion_complete'):
                        del row[key]
                    row.update(compile_attempts=5, succeeded=2)
                if change: change(row)
                (dest/'audit-summary.json').write_text(json.dumps(row))
                (dest/'failures.jsonl').write_text('')
                if native_exit: raise subprocess.CalledProcessError(native_exit, ['bound-native-tool', *args])
            class Tool:
                pass
            tool = Tool(); tool.run = run
            with patch.object(b, 'phase_event', side_effect=lambda *args, **kwargs: events.append((args, kwargs))):
                b.audit_failed_shard(tool, root/'dump', root/'expander', root, 'fixture', '20261001',
                    2, 10, 5, 2, 123, [], [], lambda: identities.append('checked'), 'original-production-failure')
            self.assertEqual(identities, ['checked', 'checked'])
            self.assertEqual(len(native_calls), 1)
            self.assertIn('--audit-presentation-errors', native_calls[0])
            ending = [fields for args, fields in events if args[-1] == 'end'][-1]
            self.assertEqual(ending['status'], 'success')
            self.assertFalse(ending['semantic_acceptance'])
            self.assertFalse(ending['publication_created'])
            self.assertTrue(ending['range_complete'])
            self.assertEqual(ending['expansion_input_failures'], 0 if legacy else 2)
            self.assertEqual(ending['presentation_failures'], 3 if legacy else 1)
            self.assertIs(ending['expansion_complete'], None if legacy else False)

    def test_mixed_input_and_writer_failures_complete_only_the_selected_audit_range(self):
        self.exercise_input_summary()

    def test_legacy_complete_summary_stays_readable_without_invented_expansion_proof(self):
        self.exercise_input_summary(legacy=True)

    def test_inconsistent_input_counts_completeness_and_partial_extensions_refuse(self):
        changes = [
            lambda row: row.update(expansion_input_failures=True),
            lambda row: row.update(expansion_input_failures=-1),
            lambda row: row.update(expansion_input_failures=4),
            lambda row: row.update(presentation_failures=2),
            lambda row: row.update(compile_attempts=5),
            lambda row: row.update(expansion_complete=True),
            lambda row: row.update(expansion_complete=0),
            lambda row: row.pop('presentation_failures'),
            lambda row: row.pop('expansion_input_failures'),
            lambda row: row.update(range_complete=False),
            lambda row: row.update(failure_records=2),
        ]
        for change in changes:
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.exercise_input_summary(change)
        with self.assertRaises(ValueError): self.exercise_input_summary(native_exit=0)
        with self.assertRaises(subprocess.CalledProcessError): self.exercise_input_summary(native_exit=-9)


if __name__=='__main__':unittest.main()
