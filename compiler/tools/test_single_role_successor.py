"""Standalone receipt authenticity; fixture binaries are data, never executed."""
import copy, hashlib, json, os, stat, tempfile, unittest
from pathlib import Path
from types import SimpleNamespace
import build_wiktionaries as b
from test_direct_writer_successor import fixture as legacy_fixture, descriptor, BoundInputs


def fixture(root, role='writer', compact=True, change=None):
    f=legacy_fixture(root)
    def load(ref):return json.loads(Path(ref['path']).read_text())
    def write(name,value):
        p=root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(value));return descriptor(p)
    row=f.row;cmd=load(row['compilation_recipe']);closed=load(row['qualification_closure']);start=load(closed['start']);result=load(row['actual_emission_result']);source=load(row['source'])
    compiled=load(row['compiled_source_authority'])
    if role=='verify':
        p=root/'view/tools/blob_verify.zig';p.write_text('// exact Verify source\n');compiled={'tools/blob_verify.zig':descriptor(p,True)}
        f.artifact.rename(root/'install/bin/dict-blob-verify');f.artifact=root/'install/bin/dict-blob-verify'
        cmd['argv'][2]='prepare-blob-verify'
    mf=write('single-manifest.json',compiled);row['compiled_source_authority']=mf;row['producer_source']=mf['sha256']
    cmd['argv']=[('-Dcaptured-source-fingerprint='+mf['sha256'])if x.startswith('-Dcaptured-source-fingerprint=')else x for x in cmd['argv']]
    owner_file=root/'owner.py';owner_file.write_text('# controlled owner\n');owner_ref=descriptor(owner_file,True)
    infra=root/'infra.py';infra.write_text('# controlled infra\n')
    refs=[descriptor(infra,True),owner_ref,dict(mf,mode=0o644),*compiled.values()]
    qualify=write('qualify.json',{'closed':True});project=write('project.json',{'exact':True});refs += [qualify,project]
    cmd.update(required_owner=owner_ref,source_refs=refs,source_manifest=dict(mf,mode=0o644),qualification=qualify,canonical_projection=project,expected_install={role:str(f.artifact)},env={'TMPDIR':str(root/'tmp')})
    result.update(argv=cmd['argv'][:],environment=cmd['env'])
    artifact=descriptor(f.artifact)
    closed.pop('artifact');closed.update(installed_artifacts={role:artifact,'stat':list(f.artifact.lstat()),'aliases':{}},source_manifest=cmd['source_manifest'],source_projection=project,source_qualification=qualify)
    closed[role+'_emission_passed']=True;closed['normal_writer_build_completed'if role=='writer'else'canonical_verify_build_completed']=True
    row.update(artifact=dict(artifact,mode=0o555),source_paths=list(compiled),source_payload_files=copy.deepcopy(compiled))
    source.update(normal_single_role=role,compiled_source_manifest=mf,fingerprint=mf['sha256'],files=compiled)
    if change=='wrong-selector':cmd['argv'][2]='prepare-blob-tools';result['argv']=cmd['argv'][:]
    elif change=='extra-target':cmd['argv'].insert(3,'cli');result['argv']=cmd['argv'][:]
    elif change=='wrong-role':source['normal_single_role']='verify'if role=='writer'else'writer'
    elif change=='extra-env':cmd['env']['UNBOUND']='1';result['environment']=cmd['env']
    elif change=='escaped-tmp':cmd['env']['TMPDIR']=str(root.parent/'foreign');result['environment']=cmd['env']
    elif change=='failed-emission':closed[role+'_emission_passed']=False
    elif change=='source-after':closed['source_after']=False
    elif change=='source-projection':row['source_payload_files']={}
    elif change=='wrong-payload':row['source_payload_files'][next(iter(compiled))]['sha256']='0'*64
    elif change=='logical-source':source['files']=copy.deepcopy(compiled);source['files'][next(iter(compiled))]['sha256']='0'*64
    elif change=='coherent-source-substitution':
        name=next(iter(compiled));foreign=root/'foreign.zig';foreign.write_text('// substituted source with internally coherent pointers\n');substituted=copy.deepcopy(compiled);substituted[name]=descriptor(foreign,True)
        source.update(resolved_compiled_source_files=substituted,compiled_aliases_documentary_only=True,files=substituted);row['source_payload_files']=copy.deepcopy(substituted)
    elif change=='unguarded-source':cmd['source_refs']=[x for x in refs if x.get('path')not in {v['path']for v in compiled.values()}];refs=cmd['source_refs']
    elif change=='wrong-artifact':closed['installed_artifacts'][role]['sha256']='0'*64
    elif change=='aliases':closed['installed_artifacts']['aliases']={'unexpected':'copy'}
    elif change=='stale-stat':closed['installed_artifacts']['stat'][1]+=1
    elif change=='transport-gap':closed.update(reaped=False,terminal=None,rd_terminal_receipt=None)
    elif change=='invented-terminal':closed.update(reaped=False,terminal=0,rd_terminal_receipt=None)
    elif change=='unknown-child':result['returncode']=None
    elif change=='live-child':closed['local_proc_absent']=False
    cr=write('single-command.json',cmd);control=dict(cr,mode=0o644)
    cfg=dict(input_ref=control,output_root=cmd['qualification_root'],required_owner=owner_ref,source_refs=refs[:2]if compact else refs)
    start.update(input_authority=control,source_refs=refs[:2]if compact else refs)
    if compact:
        cfg['source_refs_ref']=control;start.update(source_refs_ref=control,source_ref_count=len(refs),source_refs_sha256=hashlib.sha256(json.dumps(refs,sort_keys=True,separators=(',',':'),ensure_ascii=True).encode()).hexdigest())
    if change=='wrong-config':cfg['input_ref']=dict(control,sha256='0'*64)
    elif change=='wrong-digest':start['source_refs_sha256']='0'*64
    elif change=='wrong-count':start['source_ref_count']+=1
    elif change=='wrong-bootstrap':start['source_refs']=[]
    elif change=='wrong-full-refs':start['source_refs']=[]
    elif change=='wrong-owner':cmd['required_owner']=descriptor(infra,True)
    rr=write('runtime01/result01.json',result)
    closed.update(command=cr,result=rr,owner_config=write('config.json',cfg),start=write('runtime01/direct-runtime01/start.json',start))
    cl=write('runtime01/direct-runtime01/independent-closure01.json',closed)
    source.update(actual_normal_command=cr,actual_result=rr,actual_closure=cl)
    row.update(compilation_recipe=cr,actual_emission_result=rr,qualification_closure=cl,source=write('single-source.json',source))
    if change=='changed-binary':f.artifact.chmod(0o755);f.artifact.write_bytes(b'changed artifact\n')
    if change=='changed-source':Path(next(iter(compiled.values()))['path']).write_text('changed source\n')
    f.target='prepare-captured-writer'if role=='writer'else'prepare-blob-verify';f.argv=cmd['argv'];return f


class SingleRoleSuccessorTests(unittest.TestCase):
    def test_exact_full_compact_roles_and_honest_shell_gap(self):
        for role in ('writer','verify'):
            for compact in (False,True):
                for change in (None,'transport-gap'):
                    with self.subTest(role=role,compact=compact,change=change),tempfile.TemporaryDirectory()as tmp:
                        f=fixture(Path(tmp),role,compact,change);before=copy.deepcopy(f.row)
                        argv,_=b.initial_sealed_target_emission(f.row,f.roles,target=f.target)
                        self.assertEqual(argv,f.argv);self.assertEqual(f.row,before);f.roles.require_unchanged()
    def test_forged_selector_source_output_and_outcomes_refuse(self):
        changes=('wrong-selector','extra-target','wrong-role','extra-env','escaped-tmp','failed-emission','source-after','source-projection','wrong-payload','logical-source','coherent-source-substitution','unguarded-source','wrong-artifact','aliases','stale-stat','invented-terminal','unknown-child','live-child','wrong-config','wrong-digest','wrong-count','wrong-bootstrap','changed-binary','changed-source')
        for role in ('writer','verify'):
            for change in changes:
                with self.subTest(role=role,change=change),tempfile.TemporaryDirectory()as tmp:
                    f=fixture(Path(tmp),role,True,change)
                    with self.assertRaises((ValueError,OSError)):b.initial_sealed_target_emission(f.row,f.roles,target=f.target)
    def test_full_refs_and_other_role_or_full_graph_still_refuse(self):
        with tempfile.TemporaryDirectory()as tmp:
            f=fixture(Path(tmp),'verify',False,'wrong-full-refs')
            with self.assertRaises(ValueError):b.initial_sealed_target_emission(f.row,f.roles,target=f.target)
        with tempfile.TemporaryDirectory()as tmp:
            f=fixture(Path(tmp))
            for target,full in [('prepare-blob-verify',False),('prepare-blob-tools',True),('prepare-captured-writer',True)]:
                with self.subTest(target=target,full=full),self.assertRaises(ValueError):b.initial_sealed_target_emission(f.row,f.roles,target=target,full_graph=full)
if __name__=='__main__':unittest.main()
