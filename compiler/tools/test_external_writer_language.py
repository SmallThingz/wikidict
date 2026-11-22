"""External Writer snapshots cannot manufacture or replace worker Providers."""
import copy
import tempfile
import unittest
from pathlib import Path
from unittest import mock
import build_wiktionaries as b
import page_language_snapshot as p
from test_direct_page_language import fixture
from test_matched_triple_successor import StrictInputs


def package(root):
    source,ns,_=fixture(root)
    selected=p.pack_snapshot(source,ns,root/'packed',wiki='testwiktionary',date='20261001')
    snapshots={'page-language':selected,'namespace-registry':ns}
    hashes=b.verified_auxiliary_hashes(snapshots,'testwiktionary','20261001')
    manifests,artifacts=b.auxiliary_capture_identities(snapshots)
    identity=dict(edition='testwiktionary',date='20261001',auxiliary_snapshot_sha256=hashes,
                  auxiliary_capture_sha256=manifests,auxiliary_capture_artifact_sha256=artifacts)
    providers={name:None for name in ('page-language.json','page-language.raw.json','page-language.html')}
    return selected,snapshots,identity,providers


class ExternalWriterLanguageTests(unittest.TestCase):
    def test_explicit_package_keeps_all_sealed_absences(self):
        with tempfile.TemporaryDirectory()as tmp:
            selected,snapshots,identity,providers=package(Path(tmp));old=copy.deepcopy(providers)
            roles=StrictInputs();hashes=b.initial_sealed_writer_inputs(identity,identity,snapshots,providers,roles)
            self.assertNotIn('page-language',hashes)
            self.assertEqual(identity['auxiliary_snapshot_sha256']['namespace-registry'],hashes['namespace-registry'])
            self.assertEqual(old,providers)
            self.assertEqual({selected,selected.with_name(p.RAW),selected.with_name(p.MANIFEST)},set(roles.inputs))
            roles.require_unchanged()

    def test_original_provider_route_is_not_reinterpreted(self):
        with tempfile.TemporaryDirectory()as tmp:
            _,snapshots,identity,providers=package(Path(tmp))
            digest=identity['auxiliary_snapshot_sha256']['page-language'];providers[p.SNAPSHOT]=[100,digest]
            with mock.patch.object(b,'validated_auxiliary_capture',side_effect=AssertionError('old route must retain its own checks')):
                self.assertEqual(identity['auxiliary_snapshot_sha256'],b.initial_sealed_writer_inputs(identity,identity,snapshots,providers,StrictInputs()))
            empty=dict(identity,auxiliary_snapshot_sha256={'namespace-registry':'a'*64})
            self.assertEqual(empty['auxiliary_snapshot_sha256'],b.initial_sealed_writer_inputs(empty,empty,None,{},StrictInputs()))

    def test_any_unaccounted_or_nonempty_sealed_companion_refuses(self):
        for name in (p.SNAPSHOT,p.RAW,p.HTML):
            for present in (False,True):
                with self.subTest(name=name,present=present),tempfile.TemporaryDirectory()as tmp:
                    _,snapshots,identity,providers=package(Path(tmp))
                    if present:providers[name]=[1,'a'*64]
                    else:del providers[name]
                    with self.assertRaises(ValueError):b.initial_sealed_writer_inputs(identity,identity,snapshots,providers,StrictInputs())

    def test_capture_identity_and_bytes_cannot_be_rebound(self):
        for field in ('auxiliary_snapshot_sha256','auxiliary_capture_sha256','auxiliary_capture_artifact_sha256'):
            for side in (0,1):
                with self.subTest(field=field,side=side),tempfile.TemporaryDirectory()as tmp:
                    _,snapshots,identity,providers=package(Path(tmp));pair=[copy.deepcopy(identity),copy.deepcopy(identity)]
                    pair[side][field]['page-language']='0'*64
                    with self.assertRaises(ValueError):b.initial_sealed_writer_inputs(*pair,snapshots,providers,StrictInputs())
        with tempfile.TemporaryDirectory()as tmp:
            selected,snapshots,identity,providers=package(Path(tmp));selected.with_name(p.RAW).write_bytes(b'changed')
            with self.assertRaises(ValueError):b.initial_sealed_writer_inputs(identity,identity,snapshots,providers,StrictInputs())
        with tempfile.TemporaryDirectory()as tmp:
            _,snapshots,identity,providers=package(Path(tmp));snapshots.pop('page-language')
            with self.assertRaises(ValueError):b.initial_sealed_writer_inputs(identity,identity,snapshots,providers,StrictInputs())

    def test_normal_forwarding_retains_old_book_and_explicit_language_only(self):
        snapshots={'figure-page-observations':Path('/book.json'),'page-language':Path('/page-language.json')}
        expected=['--figure-page-observations-snapshot','/book.json','--page-language-snapshot','/page-language.json']
        providers={name:None for name in (p.SNAPSHOT,p.RAW,p.HTML)}
        self.assertEqual(expected,b.initial_sealed_writer_snapshot_args({},None,snapshots,providers))
        self.assertEqual(expected[:2],b.initial_sealed_writer_snapshot_args(None,{},snapshots))
        self.assertEqual(expected[:2],b.initial_sealed_writer_snapshot_args({},None,snapshots,{}))
        providers[p.SNAPSHOT]=[100,'a'*64]
        self.assertEqual(expected[:2],b.initial_sealed_writer_snapshot_args({},None,snapshots,providers))
        self.assertEqual([],b.initial_sealed_writer_snapshot_args(None,None,snapshots))
        self.assertEqual([],b.initial_sealed_writer_snapshot_args({},None,{}))
        with self.assertRaises((KeyError,TypeError)):b.initial_sealed_writer_snapshot_args(None,{},None)
        with self.assertRaises(KeyError):b.initial_sealed_writer_snapshot_args(None,{},{} )

    def test_complete_normal_shard_route_preserves_worker_and_splits_merge_flags(self):
        from test_build_wiktionaries import InitialSealedWriterBookTests, _initial_sealed_write
        import json
        helper=InitialSealedWriterBookTests()
        class ReachedMerge(Exception):pass
        with tempfile.TemporaryDirectory()as tmp:
            f=helper.book_fixture(Path(tmp))
            f.seal['identity']['providers'].update({name:None for name in (p.SNAPSHOT,p.RAW,p.HTML)})
            helper.reseal_graph(f);f.roles.initial_sealed_generation=f.selection
            page_root=f.root/'language';page_root.mkdir();page=page_root/p.SNAPSHOT
            _initial_sealed_write(page,{'controlled_capture':True});(page_root/p.RAW).write_bytes(b'')
            manifest={'output_sha256':b.sha256_file(page),'namespace_registry_sha256':f.aux['namespace-registry']}
            _initial_sealed_write(page_root/p.MANIFEST,manifest)
            inventory={q.name:b.sha256_file(q)for q in page_root.iterdir()}
            captures={'figure-page-observations':(*f.capture,f.manifest_name),'page-language':(manifest,inventory,p.MANIFEST)}
            manifests,artifacts=b._project_auxiliary_capture_identities(captures)
            f.aux['page-language']=manifest['output_sha256']
            for identity in (f.expected,f.identity):
                identity['auxiliary_capture_sha256']=copy.deepcopy(manifests)
                identity['auxiliary_capture_artifact_sha256']=copy.deepcopy(artifacts)
            snapshots={'figure-page-observations':f.book,'page-language':page}
            sealed_before=(f.expander/'.completed-expander.json').read_bytes()
            staged=f.root/'input';staged.mkdir();(staged/'.complete.json').write_text(json.dumps({'source_pages':1}))
            (f.expander/'page-index.tsv').write_text('retained index')
            writer_args=[];merge_args=[]
            def writer(tool,args,shard,*unused,**kwargs):
                writer_args.append(args);shard.mkdir();return 1
            def merge(args,*unused,**kwargs):merge_args.append(args);raise ReachedMerge
            from types import SimpleNamespace
            tools={name:SimpleNamespace(run=merge if name=='dict-blob-merge'else lambda *a,**k:None)for name in b.BLOB_TOOL_NAMES}
            def capture(role,*args):return captures[role][:2]
            with helper.contexts(f)[0],helper.contexts(f)[1],helper.contexts(f)[2],mock.patch.object(b,'validated_auxiliary_capture',side_effect=capture):
                helper.adopt(f,auxiliary_snapshots=snapshots)
                with mock.patch.object(b._PREPARED_SOURCE,'request',None,create=True),mock.patch.object(b._PREPARED_SOURCE,'value',None,create=True),mock.patch.object(b,'expander_ready',return_value=True)as ready,mock.patch.object(b,'inspect_page_index',return_value=dict(rows=1,sha256='0'*64,offsets={0:0},identity={'controlled_index':True})),mock.patch.object(b,'require_index_identity'),mock.patch.object(b,'prepare_blob_tools',return_value=tools),mock.patch.object(b,'build_shard_with_retries',side_effect=writer),mock.patch.object(b,'validate_page_coverage',return_value={'pages_seen':1}),mock.patch.object(b,'compress_verified_shard'),mock.patch.object(b,'require_merge_disk_space',return_value={}):
                    with self.assertRaises(ReachedMerge):b.build_sharded(f.dump,f.root/'staging',f.destination,f.root/'registry','zig',1,[dict(wiki=f.expected['edition'],date='20261001')],123,compress_shards=True,build_identity=f.identity,auxiliary_hashes=f.aux,auxiliary_snapshots=snapshots,interwiki_sha=f.interwiki,retained_roles=f.roles,staged_input_root=staged)
                    self.assertEqual(f.worker_hashes,ready.call_args.args[1])
            self.assertEqual(sealed_before,(f.expander/'.completed-expander.json').read_bytes())
            self.assertFalse((f.expander/p.SNAPSHOT).exists())
            self.assertEqual(len(writer_args),1);args=writer_args[0]
            self.assertEqual(str(page),args[args.index('--page-language-snapshot')+1])
            self.assertEqual(str(f.book),args[args.index('--figure-page-observations-snapshot')+1])
            self.assertNotIn('--shard-pages',args)
            self.assertEqual(len(merge_args),1)
            self.assertEqual(merge_args[0][:2],['--compress-output',str(f.root/'staging')])
            self.assertFalse(any(value.startswith('--page-language')or value.startswith('--figure-')for value in merge_args[0]))


if __name__=='__main__':unittest.main()
