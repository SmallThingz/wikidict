"""Normal combined-role receipts: real retained input plus closed fixture mutations."""
import copy
import hashlib
import json
import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

import build_wiktionaries as b
from test_direct_writer_successor import BoundInputs, descriptor, fixture as writer_fixture


def fixture(root, change=None, role='writer'):
    original = writer_fixture(root, 'transport-gap' if change == 'transport-gap' else None)
    def write(name, value):
        path = root / name; path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value)); return descriptor(path)
    def load(reference): return json.loads(Path(reference['path']).read_text())
    row = original.row
    command = load(row['compilation_recipe']); closed = load(row['qualification_closure'])
    result = load(row['actual_emission_result']); source = load(row['source'])
    roots = {'writer':'tools/blob_build.zig', 'cli':'src/frontend/main.zig', 'verify':'tools/blob_verify.zig'}
    types = 'src/encoder/presentation_types.zig'; codec = 'src/encoder/presentation_codec.zig'
    protocol = 'src/lua/bundle_protocol.zig'
    compiled = load(row['compiled_source_authority'])
    for name in [roots['cli'], roots['verify'], types, codec, protocol]:
        path = root / 'view' / name; path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('// controlled receipt source: ' + name + '\n')
        compiled[name] = descriptor(path, mode=True)
    manifest = write('manifest.json', compiled)
    members = {key:{name:compiled[name] for name in [value,types,codec]+([protocol] if key=='writer' else [])}
               for key,value in roots.items()}
    wire = {name:compiled[name] for name in (types,codec,protocol)}
    reached = {name:[key for key in roots if name in members[key]] for name in wire}
    join = dict(source_manifest=manifest, same_graph_roles=True, wire_source_equal=True,
                new_roles_required=['writer','cli','verify'], artifacts_emitted=False,
                role_roots=roots, role_members=members, wire_members=wire, wire_reached_roles=reached)
    if change == 'missing-wire': del join['wire_members'][codec]; del join['wire_reached_roles'][codec]
    if change == 'invented-reach': join['wire_reached_roles'][types] = ['writer','cli']
    if change == 'different-role-bytes': join['role_members']['verify'][types] = compiled[codec]
    if change == 'wrong-root': join['role_roots']['verify'] = 'tools/test_runner.zig'
    if change == 'source-only-as-emitted': join['artifacts_emitted'] = True
    join_ref = write('role-source-join.json', join)
    projection = write('projection.json', dict(scope='controlled receipt projection'))
    qualification = write('qualification.json', dict(scope='controlled source qualification'))
    owner_path = root/'owner.py'; owner_path.write_text('# controlled owner receipt\n'); owner_ref = descriptor(owner_path)
    refs = [manifest, descriptor(root/'view'/roots['writer'])]
    refs += [descriptor(Path(d['path'])) for name,d in compiled.items() if name != roots['writer']]
    refs += [join_ref,projection,qualification,owner_ref]
    command.update(source_manifest=manifest, role_source_join=join_ref,
                   canonical_projection=projection, source_qualification=qualification, source_refs=refs)
    command['argv'][3:3] = ['cli','prepare-blob-verify']
    command['argv'] = [('-Dcaptured-source-fingerprint='+manifest['sha256']) if arg.startswith('-Dcaptured-source-fingerprint=') else arg for arg in command['argv']]
    if change == 'extra-target': command['argv'].insert(5,'test')
    if change == 'different-order': command['argv'][3:5] = ['prepare-blob-verify','cli']
    if change == 'unknown-option': command['argv'].append('-Dskip-source=true')
    if change == 'extra-jobs': command['argv'].append('-j2')
    if change == 'duplicate-option': command['argv'].extend(['--prefix',str(root/'install')])
    artifacts = {'writer':descriptor(original.artifact)}
    for key,name in (('cli','wikidict'),('verify','dict-blob-verify')):
        path=root/'install/bin'/name;path.write_bytes(b'controlled non-executed receipt artifact\n');path.chmod(0o555)
        artifacts[key]=descriptor(path)
    command['expected_install'] = {key:d['path'] for key,d in artifacts.items()}
    if change == 'optional-command-owner': command['required_owner'] = owner_ref
    command_ref = write('command.json', command)
    config = dict(input_ref=command_ref,source_refs_ref=command_ref,source_refs=refs[:2],required_owner=owner_ref)
    if change == 'different-bootstrap': config['source_refs'] = refs[1:3]
    config_ref = write('owner-config.json',config)
    start = load(closed['start']);start.update(input_authority=command_ref,source_refs_ref=command_ref,source_refs=refs[:2],
        source_ref_count=len(refs),source_refs_sha256=hashlib.sha256(json.dumps(refs,sort_keys=True,separators=(',',':'),ensure_ascii=True).encode()).hexdigest())
    if change == 'wrong-ref-count': start['source_ref_count'] += 1
    if change == 'wrong-ref-digest': start['source_refs_sha256'] = '0'*64
    if change == 'foreign-command-ref': start['source_refs_ref'] = manifest
    result.update(argv=command['argv'],cwd=command['cwd'],environment=command['env'])
    result_ref = write('runtime01/result01.json',result)
    closed.update(result=result_ref,start=write('runtime01/direct-runtime01/start.json',start),owner_config=config_ref,
        selected_owner=owner_ref,source_ref_count=start['source_ref_count'],source_refs_sha256=start['source_refs_sha256'],
        source_manifest=manifest,source_projection=projection,source_qualification=qualification,role_source_join=join_ref,
        normal_roles_emission_passed=True,writer_emission_passed=True,normal_writer_build_completed=True,errors=[],installed_artifacts=artifacts)
    if change == 'one-role-missing': del closed['installed_artifacts']['cli']
    if change == 'failed-role': closed['normal_roles_emission_passed'] = False
    if change == 'unclosed-source': closed['source_after'] = False
    if change == 'different-owner': closed['selected_owner'] = manifest
    closure = write('runtime01/direct-runtime01/independent-closure01.json',closed)
    source.update(actual_normal_command=command_ref,actual_result=result_ref,actual_closure=closure,
        compiled_source_manifest=manifest,fingerprint=manifest['sha256'],files=compiled,matched_role_source_join=join_ref)
    row.update(compilation_recipe=command_ref,actual_emission_result=result_ref,qualification_closure=closure,
        source=write('source-guard.json',source),compiled_source_authority=manifest,producer_source=manifest['sha256'],
        artifact=descriptor(root/'install/bin'/('dict-blob-build' if role=='writer' else 'dict-blob-verify'),mode=True),
        source_paths=[roots[role],types,codec])
    if change == 'changed-other-artifact': (root/'install/bin/wikidict').write_bytes(b'changed\n')
    if change == 'writable-other-artifact': (root/'install/bin/wikidict').chmod(0o755)
    return SimpleNamespace(row=row,roles=BoundInputs(),argv=command['argv'])


class StrictInputs:
    bind_input = b.RetainedNativeToolRoles.bind_input
    def __init__(self):
        self.inputs = {}; self.input_identities = {}
    def require_unchanged(self):
        for path in self.inputs: self.bind_input(path)


class MatchedTripleSuccessorTests(unittest.TestCase):
    def test_writer_and_verify_require_same_complete_trio(self):
        for role,target in (('writer','prepare-captured-writer'),('verify','prepare-blob-verify')):
            for change in (None,'transport-gap','optional-command-owner'):
                with self.subTest(role=role,change=change), tempfile.TemporaryDirectory() as tmp:
                    f=fixture(Path(tmp),change,role)
                    argv,_=b.initial_sealed_target_emission(f.row,f.roles,target=target)
                    self.assertEqual(argv,f.argv)
                    self.assertTrue(all(Path(tmp,'install/bin',name) in f.roles.inputs for name in ('dict-blob-build','wikidict','dict-blob-verify')))
                    f.roles.require_unchanged()

    def test_role_wire_targets_and_all_artifact_custody_refuse(self):
        for change in ('missing-wire','invented-reach','different-role-bytes','wrong-root','source-only-as-emitted',
                       'extra-target','different-order','unknown-option','extra-jobs','duplicate-option','one-role-missing',
                       'failed-role','unclosed-source','changed-other-artifact','writable-other-artifact'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as tmp:
                f=fixture(Path(tmp),change,'verify')
                with self.assertRaises(ValueError): b.initial_sealed_target_emission(f.row,f.roles,target='prepare-blob-verify')

    def test_compact_authority_cannot_be_rebound_or_recounted(self):
        for change in ('different-bootstrap','wrong-ref-count','wrong-ref-digest','foreign-command-ref','different-owner'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as tmp:
                f=fixture(Path(tmp),change)
                with self.assertRaises(ValueError): b.initial_sealed_target_emission(f.row,f.roles,target='prepare-captured-writer')

    def test_triple_does_not_authorize_merge_cli_or_full_graph(self):
        with tempfile.TemporaryDirectory() as tmp:
            f=fixture(Path(tmp))
            for target,full in (('prepare-blob-tools',True),('cli',False),('prepare-captured-writer',True)):
                with self.subTest(target=target,full=full), self.assertRaises(ValueError):
                    b.initial_sealed_target_emission(f.row,f.roles,target=target,full_graph=full)

    def test_interface_only_leaves_require_original_policy_and_current_exact_payload(self):
        for change in (None,'unbound-origin','different-bytes','foreign-leaf','different-policy','changed-payload'):
            with self.subTest(change=change),tempfile.TemporaryDirectory()as tmp:
                root=Path(tmp);f=fixture(root);name='src/ffi/dict.h'
                if change=='foreign-leaf':name='tools/unrelated.zig'
                payload=root/'old-interface';payload.write_bytes(b'original ABI, never a new compiler read\n')
                d=descriptor(payload,mode=True);f.row['source_paths'].append(name)
                previous_source=root/'old-source.json';previous_source.write_text(json.dumps({'files':{name:d}}))
                original=root/'original-policy.json';original.write_text('{}');f.row['previous_role_binding']=descriptor(original)
                previous=root/'old-roles.json';previous.write_text(json.dumps({'dict-blob-build':{'source':descriptor(previous_source),'source_paths':f.row['source_paths'],'previous_role_binding':descriptor(original)}}))
                source=json.loads(Path(f.row['source']['path']).read_text())
                source['interface_only_role_binding']=descriptor(previous)
                source['interface_only_sources']={name:d};source['files'][name]=d
                if change=='unbound-origin':source['interface_only_role_binding']=descriptor(previous_source)
                if change=='different-bytes':source['interface_only_sources'][name]=dict(d,sha256='0'*64);source['files'][name]=source['interface_only_sources'][name]
                if change=='different-policy':f.row['source_paths'].append('tools/absent.zig')
                Path(f.row['source']['path']).write_text(json.dumps(source));f.row['source']=descriptor(Path(f.row['source']['path']))
                if change=='changed-payload':payload.write_bytes(b'changed\n')
                if change is None:
                    self.assertEqual(f.argv,b.initial_sealed_target_emission(f.row,f.roles,target='prepare-captured-writer')[0])
                else:
                    with self.assertRaises((ValueError,KeyError)):b.initial_sealed_target_emission(f.row,f.roles,target='prepare-captured-writer')

    @unittest.skipUnless(os.environ.get('WIKIDICT_MATCHED_TRIPLE_ROOT'),'guarded actual FR emission supplied by qualification')
    def test_actual_fr_writer_and_verify_receipts(self):
        q=Path(os.environ['WIKIDICT_MATCHED_TRIPLE_ROOT']);command_ref=descriptor(q/'command01.json')
        result_ref=descriptor(q/'runtime01/result01.json');closure_ref=descriptor(q/'runtime01/direct-runtime01/independent-closure01.json')
        command=json.loads(Path(command_ref['path']).read_text());closed=json.loads(Path(closure_ref['path']).read_text())
        self.assertTrue(closed['normal_roles_emission_passed'])
        manifest=command['source_manifest'];compiled=json.loads(Path(manifest['path']).read_text())
        resolved={name:dict(d,path=str(Path(d['path']).resolve(strict=True))) for name,d in compiled.items()}
        normal_path=Path(__file__).resolve().parents[1]/'.tmp/figure-normal-inputs01/shared-provider01/retained-bundle-driver01/fr-current222-whole-binding01/normal-roles01.json'
        normal=json.loads(normal_path.read_text());prior_ref=normal['dict-blob-build']['previous_role_binding']
        prior=b.prepared_metadata(prior_ref);prior_source=b.prepared_metadata(normal['dict-blob-build']['source'])
        prior_files=prior_source.get('files',prior_source)
        interface={}
        for name in prior['dict-blob-build']['source_paths']:
            if name not in compiled:
                d=descriptor((Path(normal['dict-blob-build']['source_root'])/name).resolve(strict=True),mode=True)
                self.assertEqual({k:d[k]for k in ('bytes','sha256')},{k:prior_files[name][k]for k in ('bytes','sha256')})
                self.assertEqual(d['mode'],prior_source.get('modes',{}).get(name,prior_files[name].get('mode',0o644)))
                interface[name]=d
        self.assertEqual(len(interface),7)
        with tempfile.TemporaryDirectory() as tmp:
            source=dict(actual_normal_command=command_ref,actual_result=result_ref,actual_closure=closure_ref,
                compiled_source_manifest=manifest,fingerprint=manifest['sha256'],files=dict(resolved,**interface),
                resolved_compiled_source_files=resolved,compiled_aliases_documentary_only=True,
                interface_only_sources=interface,interface_only_role_binding=descriptor(normal_path),interface_only_not_claimed_as_compiler_reads=True,
                matched_role_source_join=command['role_source_join'])
            p=Path(tmp)/'source-guard.json';p.write_text(json.dumps(source));source_ref=descriptor(p)
            roles=StrictInputs()
            for role,target,entry in (('writer','prepare-captured-writer','tools/blob_build.zig'),('verify','prepare-blob-verify','tools/blob_verify.zig')):
                row=dict(compilation_recipe=command_ref,actual_emission_result=result_ref,qualification_closure=closure_ref,
                    source=source_ref,compiled_source_authority=manifest,producer_source=manifest['sha256'],
                    artifact=dict(closed['installed_artifacts'][role],mode=0o555),source_paths=prior['dict-blob-build'if role=='writer'else'dict-blob-verify']['source_paths'],previous_role_binding=prior_ref,
                    dependencies=dict(zig=dict(path=command['argv'][0])))
                argv,_=b.initial_sealed_target_emission(row,roles,target=target)
                self.assertEqual(argv,command['argv'])
            roles.require_unchanged()


if __name__=='__main__': unittest.main()
