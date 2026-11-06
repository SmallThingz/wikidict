#!/usr/bin/env python3
"""Existing native qualification owner/worker, with authenticated per-run data."""


def bound_captured_source_fingerprint(cfg, auth):
    """Optional captured CLI identity is the authenticated current inventory digest."""
    if 'captured_source_fingerprint' not in cfg:
        return None
    import re
    fingerprint = cfg['captured_source_fingerprint']
    assert type(fingerprint) is str and re.fullmatch(r'[0-9a-f]{64}', fingerprint)
    descriptor = cfg['private_manifest']
    assert fingerprint == descriptor['sha256']
    auth(descriptor)
    return fingerprint


def require_presentation_source_contract(binding):
    """wire names the newest supported format, not every record's selected wire."""
    assert type(binding) is dict
    assert type(binding.get('ABI')) is int and binding['ABI'] == 10
    # DPRF adds explicit components; the normal selector still emits older wires
    # when those fields are absent. Legacy Reader/Writer checks remain required.
    assert binding.get('wire') == 'DPRF'


def qualification_build_argv(args, cache, native_build_argv, *, family, prefix=None):
    """One source for every normal build's optional captured-source option."""
    assert family in ('prepare', 'full', 'install', 'bundle-pipeline', 'bundle')
    if family in ('prepare', 'full'):
        argv = list(native_build_argv(args, cache))
        assert argv[:3] == [str(args.compiler), 'build', 'test'] and argv.count('-j1') == 1
        argv[argv.index('-j1')] = '-j2'
        if family == 'prepare':
            assert prefix is not None
            assert not any(arg == '--test-filter' or arg.startswith('--test-filter=') for arg in argv)
            argv[2] = 'prepare-tests'
            argv += ['--prefix', str(prefix)]
        else:
            assert prefix is None
    else:
        assert prefix is not None
        targets = {'install': ['cli', 'ffi'], 'bundle-pipeline': ['test-bundle-pipeline'],
                   'bundle': ['test-bundle']}[family]
        argv = [str(args.compiler), 'build'] + targets + ['-j2', '-Doptimize=safe',
                '-Dtarget=x86_64-native', '-Dcpu=baseline', '--summary', 'all',
                '--search-prefix', '/usr', '--cache-dir', str(cache / 'local'),
                '--prefix', str(prefix)]
    assert not any(arg.startswith('-Dcaptured-source-fingerprint') for arg in argv)
    fingerprint = getattr(args, 'captured_source_fingerprint', None)
    if fingerprint is not None:
        import re
        assert type(fingerprint) is str and re.fullmatch(r'[0-9a-f]{64}', fingerprint)
        argv.append('-Dcaptured-source-fingerprint=' + fingerprint)
    return argv


def selected_focus_plan(groups, priority):
    """Order exact existing selectors; preserve their original receipt labels."""
    assert type(groups) is list and groups
    assert type(priority) is list
    by_key = {}
    by_group = {}
    for group in groups:
        group_id = group['id']
        assert type(group_id) is str and group_id and group_id not in by_group
        names, declarations = group['test_names'], group['declaration_names']
        assert type(names) is list and names and type(declarations) is list
        assert len(names) == len(declarations) and len(names) == len(set(names))
        assert all(type(name) is str and name for name in names + declarations)
        entries = [(group, index, name, declaration)
                   for index, (name, declaration) in enumerate(zip(names, declarations, strict=True))]
        by_group[group_id] = entries
        by_key.update(((group_id, entry[2]), entry) for entry in entries)
    ordered_priority = []
    seen = set()
    priority_groups = []
    for selector in priority:
        assert type(selector) is dict and set(selector) == {'group', 'name'}
        assert type(selector['group']) is str and type(selector['name']) is str
        key = (selector['group'], selector['name'])
        assert key in by_key and key not in seen, key
        seen.add(key)
        ordered_priority.append(by_key[key])
        if key[0] not in priority_groups:
            priority_groups.append(key[0])
    order = priority_groups + [group['id'] for group in groups if group['id'] not in priority_groups]
    ordered_groups = [by_group[group_id][0][0] for group_id in order]
    entries = ordered_priority + [entry for group_id in order for entry in by_group[group_id]
                                  if (group_id, entry[2]) not in seen]
    assert len(entries) == len(by_key)
    return ordered_groups, entries


def bound_qualification_tool(descriptor, auth, script_path):
    from pathlib import Path
    path = auth(descriptor)
    assert not path.is_symlink() and path.resolve() == Path(script_path).resolve()
    return path


def bound_repository_root(limits_descriptor, canonical_inputs, auth):
    """Derive the checkout from the exact canonical helper consumed by both roles."""
    from pathlib import Path
    limits = auth(limits_descriptor)
    assert limits == Path(limits_descriptor['path']) and limits.is_absolute()
    assert not limits.is_symlink() and limits.resolve() == limits
    assert limits.name == 'build_resource_limits.py' and limits.parent.name == 'tools'
    canonical_limits = canonical_inputs['tools/build_resource_limits.py']['reference']
    assert {key: canonical_limits[key] for key in ('path', 'bytes', 'sha256')} == \
        {key: limits_descriptor[key] for key in ('path', 'bytes', 'sha256')}
    root = limits.parent.parent
    for name, row in canonical_inputs.items():
        assert row['reference']['path'] == str(root / name)
    return root


def bound_focus_plan(cfg, binding, source_root):
    assert binding['source_binding'] == cfg['private_source_binding']
    assert binding['private_manifest'] == cfg['private_manifest']
    assert binding['cwd'] == str(source_root) and cfg['groups'] == binding['groups']
    assert cfg['focused_expected'] == binding['total_selected'] and cfg['saved_expected'] == 0
    assert len({(group['id'], name) for group in cfg['groups']
                for name in group['test_names']}) == cfg['focused_expected']
    assert len({name for group in cfg['groups'] for name in group['test_names']}) == \
        cfg['focused_distinct_names'] == binding['total_distinct_selected']
    assert binding['carried_count'] == 0
    ordered, cases = selected_focus_plan(cfg['groups'], binding.get('focus_priority', []))
    assert len(cases) == cfg['focused_expected']
    return ordered, cases


def normal_preparation_modes():
    """The fixed normal graph order shared by role binding and validation."""
    return {
     'encoder_compile':('encoder_compile',['presentation_compile.test.','encoder root imports bundle-time presentation modules'],['root.test.encoder root imports bundle-time presentation modules']),
     'encoder_document':('encoder_document',['presentation_document.test.','encoder root imports bundle-time presentation modules'],['root.test.encoder root imports bundle-time presentation modules']),
     'encoder_writer':('encoder_writer',['blob_builder.test.','encoder root imports bundle-time presentation modules'],['root.test.encoder root imports bundle-time presentation modules']),
     'encoder_support':('encoder_support',['font_scale.test.','hieroglyph_unicode.test.','language_source.test.','presentation_citations.test.','presentation_heading_anchors.test.','presentation_layout.test.','presentation_media.test.','redirect_source.test.','root.test.','table_style_profile.test.'],[]),
     'blob_encoder':('blob_encoder_tests',[],[]),
     'lua':('lua_tests',[],[]),
     'closure':('closure_tests',[],[]),
     'tools':('blob_build_tests',[],[]),
    }


def canonical_preparation_groups(groups):
    """Order physical roots without changing selectors or focus priority."""
    assert type(groups) is list and groups
    modes = normal_preparation_modes()
    selected = {}
    for group in groups:
        name = group['id']
        assert name in modes and name not in selected
        selected[name] = group
    return [selected[name] for name in modes if name in selected]


def validate_preparation_plan(cfg, group_binding, expect, ordered_groups, focus_cases):
    """Reject inconsistent preparation data before any qualification command."""
    prepared_names=tuple(group_binding['prepared_groups']);selected_ids=[group['id']for group in cfg['groups']]
    assert cfg['execution_stage'] in ('full','focused-diagnostic') and cfg['focused_expected']>0
    normal_modes=normal_preparation_modes()
    assert prepared_names==tuple(name for name in normal_modes if name in selected_ids) and selected_ids==list(prepared_names) and cfg['focused_expected']==len(focus_cases)
    assert group_binding['compile_time_filtered_preparation'] is any(group['compile_time_filtered'] for group in cfg['groups']) and group_binding['prepare_target']=='prepare-tests' and group_binding['prepared_relative_directory']=='bin/wikidict-tests'
    assert group_binding['prepare_test_error_tracing'] is False and group_binding['full_normal_partitioned_graph_required'] is True
    assert expect['expected']['logical_expected_groups']==23 and expect['expected']['expected_groups']==26 and expect['expected']['logical_global_occurrences_equal_physical'] is True
    all_roots={root['root']:root['expected_occurrences'] for root in expect['expected']['groups']}
    from collections import Counter
    prepare_filters={};prepare_discovery={}
    for group in ordered_groups:
     prepared=group['id'];physical,filters,discovery=normal_modes[prepared]
     assert group['prepared_group']==prepared and group['physical_root']==physical
     assert group['test_names'] and len(group['test_names'])==len(set(group['test_names'])) and len(group['declaration_names'])==len(group['test_names'])
     assert set(group['test_names'])<=set(all_roots[physical])
     partition=bool(filters);assert group['compile_time_filtered'] is partition
     assert group['compile_filter_origin']==('fixed-normal-encoder-partition' if partition else 'normal-unfiltered-root')
     assert group['external_compile_filter_names']==[] and group['compile_filter_names']==filters
     assert group['compiled_only_discovery_names']==discovery and group_binding['prepared_discovery_filters'].get(prepared,[])==discovery
     expected=Counter(all_roots[physical]);expected.update(discovery)
     assert all(n==1 for n in expected.values()) and Counter(group_binding['prepared_expected_occurrences'][prepared])==expected
     assert Counter(group['compiled_expected_occurrences'])==expected and group['compiled_expected_count']==sum(expected.values())
     prepare_filters[prepared]=[];prepare_discovery[prepared]=discovery
    return prepared_names, prepare_filters, prepare_discovery


def qualification_binding_plan(cfg, group_binding, expect, source_root):
    """Derive the binding report from the same required runtime contracts."""
    ordered, cases = bound_focus_plan(cfg, group_binding, source_root)
    prepared, _, _ = validate_preparation_plan(cfg, group_binding, expect, ordered, cases)
    return {
        'actual_case_order': [dict(group=group['id'], name=name)
                              for group, _, name, _ in cases],
        'prepared_groups': list(prepared),
        'compiled_counts': {group['id']: group['compiled_expected_count']
                            for group in cfg['groups']},
        'functional_failures_collected': True,
        'aggregate_full_gate_retained': True,
        'normal_full_required': cfg['execution_stage'] == 'full',
    }


def execute_focused_cases(cases, *, binaries, phase, source_root, helper, guard,
                          validate_dynamic, auth, ref, result, save,
                          prepare_group=None, stop_on_failure=False):
    """Use the existing exact-name executor and retain group/failure guards."""
    offset = 0
    while offset < len(cases):
        group = cases[offset][0]
        end = offset + 1
        while end < len(cases) and cases[end][0]['id'] == group['id']:
            end += 1
        if prepare_group is not None:
            prepare_group(group)
        first_row = len(result['focused_tests'])
        guard(); validate_dynamic()
        binary = binaries[group['prepared_group']]
        auth(binary)
        command_error = None
        try:
            for _, index, name, declaration_name in cases[offset:end]:
                auth(binary)
                label = group['id'] + '-' + str(index).zfill(2)
                command = helper['execute'](phase, label, [binary['path'], '--dict-run-test', name], source_root)
                stdout, stderr = phase / (label + '.stdout'), phase / (label + '.stderr')
                text = helper['ANSI'].sub('', stdout.read_text(errors='replace') + '\n' + stderr.read_text(errors='replace'))
                passed = command.get('status') == 'exited' and command.get('returncode') == 0
                row = dict(name=name, group=group['id'], command=command, stdout=ref(stdout),
                           stderr=ref(stderr), outcome='passed' if passed else 'failed', passed=passed,
                           binary=binary, exact_name_discovered=passed, runner_mode='--dict-run-test',
                           full_suite_credit=False)
                result['focused_tests'].append(row)
                save(); auth(binary)
        except BaseException as error:
            command_error = error
            raise
        finally:
            try:
                guard()
            except BaseException as guard_error:
                result.setdefault('group_guard_failures', []).append(dict(
                    group=group['id'], guard_error=repr(guard_error),
                    command_error=repr(command_error) if command_error is not None else None))
                save()
                raise
        if stop_on_failure and not all(row['passed'] for row in result['focused_tests'][first_row:]):
            result['focused_qualified'] = False
            result['focused_evidence_total'] = len(result['focused_tests'])
            result['all_selected_executed'] = len(result['focused_tests']) == len(cases)
            save()
            raise AssertionError('focused_functional_failure')
        offset = end


if __name__ == '__main__':
    import sys
    assert len(sys.argv) == 3 and sys.argv[1] in ('owner', 'worker'), 'Expected owner|worker and existing dispatch directory'
    role = sys.argv.pop(1)
    if role == 'owner':
        from pathlib import Path
        import os,json,hashlib,subprocess,time,stat,ast,runpy,sys,fcntl
        D=Path(sys.argv[1]);N=D.parent.parent;Q=N
        def state(s):return(s.st_dev,s.st_ino,s.st_mode,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
        def ref(p):
         p=Path(p);s=p.stat();h=hashlib.sha256()
         with p.open('rb')as f:
          assert state(os.fstat(f.fileno()))==state(s)
          for z in iter(lambda:f.read(1048576),b''):h.update(z)
          assert state(os.fstat(f.fileno()))==state(s)
         assert state(p.stat())==state(s);return dict(path=str(p),bytes=s.st_size,sha256=h.hexdigest())
        def auth(v):assert ref(v['path'])=={k:v[k]for k in ('path','bytes','sha256')},v['path'];return Path(v['path'])
        def read(v):return json.loads(auth(v).read_text())
        def write(p,v):
         with p.open('x')as f:json.dump(v,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
         return ref(p)
        def function(p,name):
         t=p.read_text();ns=[n for n in ast.parse(t).body if isinstance(n,ast.FunctionDef)and n.name==name];assert len(ns)==1;return ast.get_source_segment(t,ns[0])+'\n'
        start=json.loads((D/'start.json').read_text());cfg=read(start['configuration']);source=read(cfg['source']);expect=read(cfg['expectation']);cache=Path(cfg['retained_cache']['path']);cl=read(start['latest_runtime_boundary']);b=dict(deadline_unix=cfg['deadline_unix'],locks=cfg['ownership_locks'])
        qualification_tool=bound_qualification_tool(start['runtime_inputs']['qualification_tool'],auth,__file__)
        captured_fingerprint=bound_captured_source_fingerprint(cfg,auth)
        R=bound_repository_root(start['runtime_inputs']['limits_api'],cfg['canonical_runtime_inputs'],auth);E=R/'.tmp/renderer-core-oct28'
        observed_core_provenance=None
        private_binding=read(cfg['private_source_binding']);private_manifest=read(cfg['private_manifest']);private=Path(cfg['retained_source']['path'])
        assert private_binding['canonical_source']==cfg['source'] and private_binding['private_manifest']==cfg['private_manifest']
        assert private_binding['source_path']==str(private) and private_binding['source_identity']=={k:cfg['retained_source'][k]for k in ('device','inode','uid','mode')}
        assert len(private_manifest)==private_binding['new_count'] and private_binding['new_count']>0
        private_model=dict(files={name:dict(path=str(private/name),bytes=value['bytes'],sha256=value['sha256'])for name,value in private_manifest.items()},modes={name:value['mode']for name,value in private_manifest.items()})
        private_helper=runpy.run_path(str(auth(cfg['helper'])))
        group_binding=read(cfg['focused_groups'])
        ordered_groups,focus_cases=bound_focus_plan(cfg,group_binding,private)
        assert cfg['full_native_expected']==expect['expected']['expected_total'] and cfg['groups_expected']==expect['expected']['expected_groups'] and cfg['bundle_expected_checks']>0
        if cfg['execution_stage']!='tail':
         validate_preparation_plan(cfg,group_binding,expect,ordered_groups,focus_cases)
        def source_guard():
         global observed_core_provenance
         assert time.time()<cfg['deadline_unix']==start['deadline_unix'];auth(start['configuration'])
         assert cfg['expected_head']==source['head']
         # The compiler consumes the complete private tree below, not the live canonical tree.
         # The archived canonical inventory remains immutable baseline evidence only.
         required_canonical_inputs={'tools/build_resource_limits.py','tools/build_watchdog_guardian.py','tools/build_disk_limits.py','tools/extraction_cache.py'}
         assert set(cfg['canonical_runtime_inputs'])==required_canonical_inputs
         for name,row in cfg['canonical_runtime_inputs'].items():
          assert row['reference']['path']==str(R/name)
          path=auth(row['reference']);assert not path.is_symlink() and stat.S_IMODE(path.stat().st_mode)==row['mode']
         for v in [cfg['source'],cfg['expectation'],cfg['helper'],cfg['compiler'],cfg['dynamic_helper'],cfg['dynamic_state'],*cfg['runtime_helpers']]:auth(v)
         ci=cfg['retained_cache'];assert not cache.is_symlink()and cache.resolve()==cache;s=cache.stat();assert(s.st_dev,s.st_ino,s.st_uid,stat.S_IMODE(s.st_mode))==tuple(ci[k]for k in ('device','inode','uid','mode'))
         assert expect['expected']['expected_total']==cfg['full_native_expected'] and expect['expected']['expected_groups']==cfg['groups_expected']
         py=read(cfg['runtime_python']);assert py['returncode']==0
         for v in list(py['files'].values())+py['environment_files']:auth(v)
         assert Path(__import__('shutil').which('python3'))==Path(py['executable'])
         for v in start['runtime_inputs'].values():auth(v)
         observed_core_provenance=dict(baseline_head=source['head'],baseline_inventory=cfg['source'],private_manifest=cfg['private_manifest'],source_domain='complete retained private source plus exact consumed canonical runtime helpers',canonical_runtime_inputs=cfg['canonical_runtime_inputs'],canonical_acceptance=False,apps_acceptance=False)
         auth(cfg['private_source_binding']);auth(cfg['private_manifest']);auth(cfg['focused_groups']);auth(private_binding['selected_patch'])
         auth(expect['inventory_source'])
         identity=cfg['retained_source'];assert not private.is_symlink()and private.resolve()==private;ps=private.stat();assert(ps.st_dev,ps.st_ino,ps.st_uid,stat.S_IMODE(ps.st_mode))==tuple(identity[k]for k in ('device','inode','uid','mode'))
         assert private_helper['private_manifest'](private_model,private,expected_changes=set())==private_manifest
         return True
        guard=source_guard
        assert os.getpid()==os.getpgrp()==os.getsid(0);sys.path.insert(0,str(R/'tools'));import build_resource_limits as limits
        assert Path(limits.__file__).resolve()==auth(start['runtime_inputs']['limits_api']);assert 'PYTHONSAFEPATH'not in os.environ
        observer=limits.HostMemoryObservation(start['host_observation_policy'])
        assert cfg['profile']['wall_seconds']==10800 and start['admission_deadline_unix']==cfg['admission_deadline_unix']
        assert cfg['deadline_unix']>=cfg['admission_deadline_unix']+cfg['profile']['wall_seconds']+120
        ids={(x['pid'],x['birth'])for x in cl['recorded_identities']};groups={x['group']for x in cl['recorded_identities']if 'group'in x and x.get('session')!=3};sessions={x['session']for x in cl['recorded_identities']if 'session'in x and x['session']!=3};groups.update(cl['additional_session_exclusions_from_start_new_session_contract']);sessions.update(cl['additional_session_exclusions_from_start_new_session_contract'])
        def reconcile():
         counts={}
         for root in ['/proc','/mnt/ogroot/proc']:
          assert Path(root+'/sys/kernel/random/boot_id').read_text().strip()==start['boot_id'];count=0
          for p in Path(root).iterdir():
           if not p.name.isdecimal():continue
           try:z=(p/'stat').read_text();v=z[z.rfind(')')+2:].split();pid=int(p.name);birth=int(v[19]);g=int(v[2]);se=int(v[3]);count+=1
           except FileNotFoundError:continue
           assert(pid,birth)not in ids and g not in groups and se not in sessions,(root,pid,birth)
          counts[root]=count
         for line in subprocess.check_output(['ps','-eo','pid=,pgid=,sid='],text=True).splitlines():
          pid,g,se=map(int,line.split());assert g not in groups and se not in sessions
         return counts
        counts=reconcile();baseguard=guard
        def guard():
         reconcile();baseguard();sv=os.statvfs(R);assert sv.f_bavail*sv.f_frsize>=cfg['profile']['disk_floor_bytes'];cur=int(Path('/sys/fs/cgroup/pids.current').read_text());mx=Path('/sys/fs/cgroup/pids.max').read_text().strip();assert mx=='max'or int(mx)-cur>=256;return True
        def record_refusal(reason,sample):
         number=len(list(D.glob('admission-refusal*.json')))+1
         print(json.dumps(write(D/f'admission-refusal{number:04d}.json',dict(reason=reason,sample=sample,runtime_started=False))),flush=True)
        fds,sample=limits.wait_for_build_admission(deadline_unix=cfg['admission_deadline_unix'],locks=b['locks'],host_observation=observer,final_guard=guard,record_refusal=record_refusal,poll_seconds=5)
        run=D.parent;assert not(run/'watchdog.json').exists()and not(run/'commands').exists();(run/'tmp').mkdir();os.environ['TMPDIR']=str(run/'tmp');os.environ['ZIG_LOCAL_CACHE_DIR']=str(cache/'local');os.environ['ZIG_GLOBAL_CACHE_DIR']=str(cache/'global');os.sched_setaffinity(0,set(cfg['profile']['cpus']));assert os.getpriority(os.PRIO_PROCESS,0)==0
        write(D/'admitted.json',dict(sample=sample,process_view_counts=counts,locks=cfg['ownership_locks'],admitted_unix=time.time(),profile=cfg['profile'],host_pressure_termination_enabled=False,core_provenance=observed_core_provenance));print('ADMITTED',json.dumps(sample),flush=True)
        rc=None;error=None
        try:rc=limits.supervise_watchdog(argv=['-B',str(auth(start['runtime_inputs']['qualification_tool'])),'worker',str(D)],report_path=run/'watchdog.json',memory_limit_bytes=cfg['profile']['memory_limit_bytes'],max_cpus=4,max_tasks=256,address_space_limit_bytes='unlimited',wall_seconds=cfg['profile']['wall_seconds'],disk_paths=[R,Q],disk_floor_bytes=cfg['profile']['runtime_disk_floor_bytes'],child_nice=0,host_observation=observer)
        except BaseException as exc:error=repr(exc);raise
        finally:
         write(D/'owner-result.json',dict(returncode=rc,error=error,watchdog=ref(run/'watchdog.json')if(run/'watchdog.json').exists()else None,finished_unix=time.time(),host_pressure_termination_enabled=False));[os.close(fd)for fd in fds]
        raise SystemExit(rc)
    else:
        from pathlib import Path
        import os,json,hashlib,subprocess,time,stat,ast,runpy,sys,fcntl
        D=Path(sys.argv[1]);N=D.parent.parent;Q=N
        def state(s):return(s.st_dev,s.st_ino,s.st_mode,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
        def ref(p):
         p=Path(p);s=p.stat();h=hashlib.sha256()
         with p.open('rb')as f:
          assert state(os.fstat(f.fileno()))==state(s)
          for z in iter(lambda:f.read(1048576),b''):h.update(z)
          assert state(os.fstat(f.fileno()))==state(s)
         assert state(p.stat())==state(s);return dict(path=str(p),bytes=s.st_size,sha256=h.hexdigest())
        # Private replacement for auth() in the existing embedded owner/worker source.
        # Each process authenticates its own expected inputs; ref() remains uncached.
        _expected_inputs = {}
        _expected_inputs_pid = os.getpid()

        def auth(v, *, force=False):
         global _expected_inputs_pid
         pid = os.getpid()
         if pid != _expected_inputs_pid:
          _expected_inputs.clear()
          _expected_inputs_pid = pid
         expected = {k: v[k] for k in ('path', 'bytes', 'sha256')}
         key = tuple(expected[k] for k in ('path', 'bytes', 'sha256'))
         p = Path(expected['path'])
         before = state(p.stat())
         try:
          if force or _expected_inputs.get(key) != before:
           assert ref(p) == expected, str(p)
           assert state(p.stat()) == before, str(p)
          else:
           # Check the opened target as well as the name before trusting cached bytes.
           with p.open('rb') as stream:
            assert state(os.fstat(stream.fileno())) == before, str(p)
            assert state(p.stat()) == before, str(p)
          _expected_inputs[key] = before
         except BaseException:
          _expected_inputs.pop(key, None)
          raise
         return p

        def final_source_guard():
         # Include startup-only pinned inputs, not just those repeated by source_guard.
         for path, size, digest in list(_expected_inputs):
          auth(dict(path=path, bytes=size, sha256=digest), force=True)
         return source_guard()
        def read(v):return json.loads(auth(v).read_text())
        def write(p,v):
         with p.open('x')as f:json.dump(v,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
         return ref(p)
        def function(p,name):
         t=p.read_text();ns=[n for n in ast.parse(t).body if isinstance(n,ast.FunctionDef)and n.name==name];assert len(ns)==1;return ast.get_source_segment(t,ns[0])+'\n'
        start=json.loads((D/'start.json').read_text());cfg=read(start['configuration']);source=read(cfg['source']);expect=read(cfg['expectation']);cache=Path(cfg['retained_cache']['path']);cl=read(start['latest_runtime_boundary']);b=dict(deadline_unix=cfg['deadline_unix'],locks=cfg['ownership_locks'])
        qualification_tool=bound_qualification_tool(start['runtime_inputs']['qualification_tool'],auth,__file__)
        captured_fingerprint=bound_captured_source_fingerprint(cfg,auth)
        R=bound_repository_root(start['runtime_inputs']['limits_api'],cfg['canonical_runtime_inputs'],auth);E=R/'.tmp/renderer-core-oct28'
        observed_core_provenance=None
        private_binding=read(cfg['private_source_binding']);private_manifest=read(cfg['private_manifest']);private=Path(cfg['retained_source']['path'])
        assert private_binding['canonical_source']==cfg['source'] and private_binding['private_manifest']==cfg['private_manifest']
        assert private_binding['source_path']==str(private) and private_binding['source_identity']=={k:cfg['retained_source'][k]for k in ('device','inode','uid','mode')}
        assert len(private_manifest)==private_binding['new_count'] and private_binding['new_count']>0
        private_model=dict(files={name:dict(path=str(private/name),bytes=value['bytes'],sha256=value['sha256'])for name,value in private_manifest.items()},modes={name:value['mode']for name,value in private_manifest.items()})
        private_helper=runpy.run_path(str(auth(cfg['helper'])))
        group_binding=read(cfg['focused_groups'])
        ordered_groups,focus_cases=bound_focus_plan(cfg,group_binding,private)
        assert cfg['full_native_expected']==expect['expected']['expected_total'] and cfg['groups_expected']==expect['expected']['expected_groups'] and cfg['bundle_expected_checks']>0
        def source_guard():
         global observed_core_provenance
         assert time.time()<cfg['deadline_unix']==start['deadline_unix'];auth(start['configuration'])
         assert cfg['expected_head']==source['head']
         # The compiler consumes the complete private tree below, not the live canonical tree.
         # The archived canonical inventory remains immutable baseline evidence only.
         required_canonical_inputs={'tools/build_resource_limits.py','tools/build_watchdog_guardian.py','tools/build_disk_limits.py','tools/extraction_cache.py'}
         assert set(cfg['canonical_runtime_inputs'])==required_canonical_inputs
         for name,row in cfg['canonical_runtime_inputs'].items():
          assert row['reference']['path']==str(R/name)
          path=auth(row['reference']);assert not path.is_symlink() and stat.S_IMODE(path.stat().st_mode)==row['mode']
         for v in [cfg['source'],cfg['expectation'],cfg['helper'],cfg['compiler'],cfg['dynamic_helper'],cfg['dynamic_state'],*cfg['runtime_helpers']]:auth(v)
         ci=cfg['retained_cache'];assert not cache.is_symlink()and cache.resolve()==cache;s=cache.stat();assert(s.st_dev,s.st_ino,s.st_uid,stat.S_IMODE(s.st_mode))==tuple(ci[k]for k in ('device','inode','uid','mode'))
         assert expect['expected']['expected_total']==cfg['full_native_expected'] and expect['expected']['expected_groups']==cfg['groups_expected']
         py=read(cfg['runtime_python']);assert py['returncode']==0
         for v in list(py['files'].values())+py['environment_files']:auth(v)
         assert Path(__import__('shutil').which('python3'))==Path(py['executable'])
         for v in start['runtime_inputs'].values():auth(v)
         observed_core_provenance=dict(baseline_head=source['head'],baseline_inventory=cfg['source'],private_manifest=cfg['private_manifest'],source_domain='complete retained private source plus exact consumed canonical runtime helpers',canonical_runtime_inputs=cfg['canonical_runtime_inputs'],canonical_acceptance=False,apps_acceptance=False)
         auth(cfg['private_source_binding']);auth(cfg['private_manifest']);auth(cfg['focused_groups']);auth(private_binding['selected_patch'])
         auth(expect['inventory_source'])
         identity=cfg['retained_source'];assert not private.is_symlink()and private.resolve()==private;ps=private.stat();assert(ps.st_dev,ps.st_ino,ps.st_uid,stat.S_IMODE(ps.st_mode))==tuple(identity[k]for k in ('device','inode','uid','mode'))
         assert private_helper['private_manifest'](private_model,private,expected_changes=set())==private_manifest
         return True
        guard=source_guard
        def prepare_tests_argv(args,cache,prefix,native_build_argv):
         return qualification_build_argv(args,cache,native_build_argv,family='prepare',prefix=prefix)
        import pathlib,re
        from types import SimpleNamespace
        sys.path.insert(0,str(R/'tools'));import build_resource_limits as limits
        assert limits.inside_watchdog()
        out=D.parent/'commands';out.mkdir();phase=out/'fixed';phase.mkdir();w=private_helper;inv=runpy.run_path(str(auth(expect['inventory_source'])));assert callable(inv.get('validate_grouped'))
        dynamic=runpy.run_path(str(auth(cfg['dynamic_helper'])));ds=read(cfg['dynamic_state']);ev=runpy.run_path(str(auth(start['runtime_inputs']['reader_markers'])))
        marker_path=auth(start['runtime_inputs']['reader_markers']);marker_source=function(marker_path,'markers')
        assert marker_source.count('checks=47')==3 and marker_source.count('reader_checks=47')==1
        marker_source=marker_source.replace('checks=47','checks=50').replace('reader_checks=47','reader_checks=50')
        marker_globals=dict(json=json,re=re,Path=Path);exec(compile(marker_source,'<current-reader-marker-contract>','exec'),marker_globals);markers=marker_globals['markers']
        assert cfg['reader_expected_checks']==50 and cfg['bundle_expected_checks']==182
        cs={};exec(compile(function(auth(start['runtime_inputs']['classifier']),'focused_test_outcome'),'<earned-classifier>','exec'),cs);classify=cs['focused_test_outcome']
        args=SimpleNamespace(compiler=pathlib.Path(cfg['compiler']['path']),captured_source_fingerprint=captured_fingerprint)
        result=dict(passed=False,status='running',compiles=[],focused_tests=[],saved_tests=[],phases=[],full_native_pass=False,bundle_pipeline_pass=False,bundle_pass=False,cli_ffi_install_pass=False,canonical_source=False,source_copies=False,retained_private_source=str(private))
        result['selected_current_count']=cfg['focused_expected'];result['historical_pass_admission']=False
        def save():w['write'](out/'result.json',result)
        def execute(label,argv):
         guard();dynamic['validate'](ds);command=w['execute'](out,label,argv,private);so=(out/(label+'.stdout')).read_text(errors='replace');se=(out/(label+'.stderr')).read_text(errors='replace');result['phases'].append(dict(name=label,command=command,stdout=ref(out/(label+'.stdout')),stderr=ref(out/(label+'.stderr'))));save();guard();assert command['status']=='exited' and command['returncode']==0,(label,command);return so,se
        save()
        try:
         assert cfg['execution_stage'] in ('full','tail','focused-diagnostic')
         if cfg['execution_stage']=='tail':
          reuse=cfg['tail_reuse'];prior_cfg=read(reuse['configuration']);prior=read(reuse['result']);closed=read(reuse['closure']);released=read(reuse['release'])
          assert bound_captured_source_fingerprint(prior_cfg,auth)==captured_fingerprint
          assert released['closure']==reuse['closure'] and released['cleanup_proven'] and released['source_guard'] and released['locks_free']
          assert closed['result']==reuse['result'] and closed['configuration']==reuse['configuration'] and closed['source_guard'] and closed['cleanup_proven'] and closed['locks_free']
          assert closed['full_native_pass'] and closed['bundle_pipeline_pass'] and closed['full_actual_passed_tests']==cfg['full_native_expected'] and closed['required_test_occurrences']==sum(expect['required_test_counts'].values())
          for key in ('private_manifest','private_source_binding','retained_source','retained_cache','compiler','runtime_python','python_bin','canonical_runtime_inputs','runtime_helpers','dynamic_helper','dynamic_state','helper','expectation','focused_groups','groups','focused_expected','focused_distinct_names','saved_expected','full_native_expected','groups_expected','reader_expected_checks','bundle_expected_checks','metadata_python_reuse','metadata_python_expected','install_root'):
           assert cfg[key]==prior_cfg[key],key
          assert prior_cfg['execution_stage']=='full'
          prior_ordered,prior_cases=bound_focus_plan(prior_cfg,group_binding,private)
          prepared_names,_,prepare_discovery=validate_preparation_plan(prior_cfg,group_binding,expect,prior_ordered,prior_cases)
          execution_plan=prior.get('focused_execution_plan','prepare-all-then-focus.v1')
          assert execution_plan in ('prepare-all-then-focus.v1','prepare-on-first-use.v1')
          if execution_plan=='prepare-on-first-use.v1':
           assert prior['focused_preparation_order']==[group['id']for group in prior_ordered]
           expected_phases=['reviewed-language-aliases']+[name for group in prior_ordered for name in ['focused-prepare-'+group['id']]+['filtered-discovery-'+group['id']+'-'+str(number)for number,_ in enumerate(prepare_discovery[group['id']])]]
          else:
           assert 'focused_preparation_order'not in prior
           expected_phases=['reviewed-language-aliases']+['focused-prepare-'+group['id']for group in prior_ordered]+['filtered-discovery-'+prepared+'-'+str(number)for prepared in prepared_names for number,_ in enumerate(prepare_discovery[prepared])]
          expected_phases+=['cli-ffi-install','full-native-suite','bundle-pipeline']
          result['inherited_focused_execution_plan']=execution_plan
          assert prior['full_native_pass'] and prior['bundle_pipeline_pass'] and prior['cli_ffi_install_pass'] and not prior['bundle_pass']
          phase_names=[p['name']for p in prior['phases']]
          assert phase_names in (expected_phases,expected_phases+['bundle'])
          if phase_names==expected_phases+['bundle']:
           failed_bundle=prior['phases'][-1]
           assert prior['status']=='failed' and prior['passed'] is False and isinstance(prior['error'],str) and prior['error']
           assert failed_bundle['command']['status']=='exited' and type(failed_bundle['command']['returncode'])is int
           auth(failed_bundle['stdout']);auth(failed_bundle['stderr'])
           result['inherited_failed_bundle']=dict(phase=failed_bundle,status=prior['status'],error=prior['error'],passed=False,current_execution=False)
          if captured_fingerprint is not None:
           for inherited in prior['phases']:
            if inherited['name'].startswith('focused-prepare-') or inherited['name'] in ('cli-ffi-install','full-native-suite','bundle-pipeline','bundle'):
             options=[arg for arg in inherited['command']['argv'] if arg.startswith('-Dcaptured-source-fingerprint')]
             assert options==['-Dcaptured-source-fingerprint='+captured_fingerprint]
          for p in prior['phases'][:len(expected_phases)]:
           assert p['command']['status']=='exited' and p['command']['returncode']==0
           auth(p['stdout']);auth(p['stderr'])
          selected=[case[2]for case in focus_cases]
          assert [r['name']for r in prior['focused_tests']]==selected and len(selected)==cfg['focused_expected']
          for r in prior['focused_tests']:
           assert r['passed'] and r['command']['status']=='exited' and r['command']['returncode']==0
           auth(r['stdout']);auth(r['stderr']);auth(r['binary'])
          full=next(p for p in prior['phases']if p['name']=='full-native-suite');so=auth(full['stdout']).read_text(errors='replace');se=auth(full['stderr']).read_text(errors='replace')
          native=w['classify'](so,se,standalone=False);assert native['passed'] and native['status_count']==cfg['full_native_expected']
          grouped=inv['validate_grouped'](w,expect['expected'],so,se);assert grouped['passed']
          names=[name for status,name in w['STATUS'].findall(w['ANSI'].sub('',so+'\n'+se))if status=='ok']
          actual={name:sum(n.endswith('.test.'+name)for n in names)for name in expect['required_test_counts']};assert actual==expect['required_test_counts']
          assert prior['reader_markers']==closed['reader_markers'] and prior['installed']==closed['installed']
          marks=prior['reader_markers'];report=read(marks['child_report']);contract=dict(observed_child_summary=marks['child_summary'],child_report=marks['child_report'],marker_lines=marks['marker_lines'])
          assert markers(w['ANSI'].sub('',so+'\n'+se),contract,report)==marks
          for installed in prior['installed'].values():auth(installed)
          cli=prior['installed']['bin/wikidict'];dynamic['validate'](ds,binary=cli['path'])
          result.update(execution_stage='tail',selected_current_count=0,focused_current_execution=False,full_native_current_execution=False,bundle_pipeline_current_execution=False,inherited_qualification=reuse,focused_qualified=True,focused_inherited_count=len(selected),native_inventory=native,grouped_inventory=grouped,required_test_counts=actual,reader_markers=prior['reader_markers'],metadata_python=prior['metadata_python'],installed=prior['installed'],cli_ffi_install_pass=True,full_native_pass=True,bundle_pipeline_pass=True)
          save()
         else:
          prepared_names,prepare_filters,prepare_discovery=validate_preparation_plan(cfg,group_binding,expect,ordered_groups,focus_cases)
          metadata=read(cfg['metadata_python_reuse']);assert metadata['current_manifest']==cfg['private_manifest'] and metadata['runtime_python']==cfg['runtime_python'] and metadata['current_execution_required'] is True
          for name,row in metadata['dependency_files'].items():
           assert row['reference']['path']==str(private/name) and private_manifest[name]['sha256']==row['reference']['sha256'] and private_manifest[name]['bytes']==row['reference']['bytes']
           path=auth(row['reference']);assert not path.is_symlink() and stat.S_IMODE(path.stat().st_mode)==row['mode']
          so,se=execute('reviewed-language-aliases',[str(Path(cfg['python_bin'])/'python3'),'-B','tools/test_reviewed_language_aliases.py'])
          metadata_text=w['ANSI'].sub('',so+'\n'+se)
          metadata_counts=re.findall(r'^Ran ([0-9]+) tests? in ',metadata_text,re.M)
          assert metadata_counts==[str(cfg['metadata_python_expected'])] and re.search(r'^OK\s*$',metadata_text,re.M),metadata_text
          result['metadata_python']=dict(passed=True,executed=cfg['metadata_python_expected'],native_credit=False,command=result['phases'][-1]);save()
          prepared_prefix=out/'prepared-tests';assert not prepared_prefix.exists()
          binaries={};prepared_commands=[]
          result['focused_execution_plan']='prepare-on-first-use.v1'
          result['focused_preparation_order']=[]
          result['compiled_discovery']=[]
          compile_record=dict(groups=[],commands=prepared_commands,passed=False,binaries=binaries,compile_time_filtered=group_binding['compile_time_filtered_preparation'],external_compile_filters=prepare_filters,fixed_partition_filters={g['id']:g['compile_filter_names'] for g in cfg['groups']},compiled_only_discovery={g['id']:g['compiled_only_discovery_names'] for g in cfg['groups']},full_suite_credit=False,interleaved_with_focus=True)
          result['compiles'].append(compile_record);save()
          def prepare_focus_group(group):
           prepared=group['id']
           if prepared in binaries:
            auth(binaries[prepared]);return
           argv=prepare_tests_argv(args,cache,prepared_prefix,w['native_build_argv'])
           assert not any(arg.startswith('-Dprepare-test-filter') or arg.startswith('-Dprepare-test-error-tracing') for arg in argv)
           argv+=['-Dprepare-test-group='+prepared]
           execute('focused-prepare-'+prepared,argv)
           prepared_commands.append(result['phases'][-1])
           prepared_dir=prepared_prefix/group_binding['prepared_relative_directory'];entries=list(prepared_dir.iterdir())
           assert {p.name for p in entries}==set(binaries)|{prepared} and all(p.is_file()and not p.is_symlink()and os.access(p,os.X_OK)for p in entries)
           binary=ref(prepared_dir/prepared);auth(binary);binaries[prepared]=binary
           for bound_binary in binaries.values():auth(bound_binary)
           result['focused_preparation_order'].append(prepared)
           compile_record['groups']=list(binaries);compile_record['passed']=set(binaries)==set(prepared_names);save()
           for number,discovery in enumerate(prepare_discovery[prepared]):
            execute('filtered-discovery-'+prepared+'-'+str(number),[binary['path'],'--dict-run-test',discovery]);auth(binary)
            result['compiled_discovery'].append(dict(name=discovery,binary=binary,command=result['phases'][-1],passed=True,semantic_focus_credit=False,full_suite_credit=False));save()
          execute_focused_cases(focus_cases,binaries=binaries,phase=phase,source_root=private,helper=w,guard=guard,validate_dynamic=lambda:dynamic['validate'](ds),auth=auth,ref=ref,result=result,save=save,prepare_group=prepare_focus_group,stop_on_failure=False)
          assert set(binaries)==set(prepared_names) and compile_record['passed']
          for bound_binary in binaries.values():auth(bound_binary)
          assert result['focused_preparation_order']==[group['id']for group in ordered_groups]
          assert [row['name']for row in result['focused_tests']]==[case[2]for case in focus_cases]
          assert len(result['focused_tests'])==cfg['focused_expected'] and cfg['saved_expected']==0
          result['all_selected_executed']=True;result['focused_evidence_total']=len(result['focused_tests']);result['focused_qualified']=all(row['passed']for row in result['focused_tests']);save();assert result['focused_qualified'],'focused_functional_failure'
          if cfg['execution_stage']!='focused-diagnostic':
           assert not Path(cfg['install_root']).exists()
           execute('cli-ffi-install',qualification_build_argv(args,cache,w['native_build_argv'],family='install',prefix=Path(cfg['install_root'])))
           result['cli_ffi_install_pass']=True
           result['installed']={n:ref(Path(cfg['install_root'])/n)for n in ('bin/wikidict','lib/libdictffi.so','include/dict/dict.h')}
           require_presentation_source_contract(private_binding)
           assert result['installed']['include/dict/dict.h']['sha256']==private_manifest['src/ffi/dict.h']['sha256']
           assert '#define DICT_ABI_VERSION 10u'+chr(10) in Path(result['installed']['include/dict/dict.h']['path']).read_text()
           assert 'DICT_ABI_VERSION == 10u && dict_abi_version() == DICT_ABI_VERSION' in (private/'tools/ffi_integration_test.c').read_text()
           cli=result['installed']['bin/wikidict'];auth(cli)
           result['installed_dynamic_identity']=dynamic['validate'](ds,binary=cli['path']);save()
           full_argv=qualification_build_argv(args,cache,w['native_build_argv'],family='full')
           so,se=execute('full-native-suite',full_argv);native=w['classify'](so,se,standalone=False);assert native['passed'];result['native_inventory']=native;result['grouped_inventory']=inv['validate_grouped'](w,expect['expected'],so,se)
           for binary in binaries.values():auth(binary)
           text=w['ANSI'].sub('',so+'\n'+se);names=[name for status,name in w['STATUS'].findall(text) if status=='ok'];assert len(names)==cfg['full_native_expected']
           actual={name:sum(n.endswith('.test.'+name) for n in names) for name in expect['required_test_counts']};assert actual==expect['required_test_counts'];result['required_test_counts']=actual
           lines=text.splitlines();prefix='CLI_SWATCH_PTY_PASS child summary/report: ';summaries=[json.loads(line[len(prefix):]) for line in lines if line.startswith(prefix)];assert len(summaries)==1;summary=summaries[0];rp=pathlib.Path(summary['report']);relative_report=rp.relative_to(cache/'local')
           assert rp.is_absolute()and rp.resolve()==rp and rp.is_file()and not rp.is_symlink()
           assert len(relative_report.parts)==3 and re.fullmatch(r'reader-integration-[0-9]+',relative_report.parts[0])and re.fullmatch(r'reader-ux-[A-Za-z0-9_-]+',relative_report.parts[1])and relative_report.parts[2]=='report.json'
           report=json.loads(rp.read_text());contract=dict(observed_child_summary=summary,child_report=ref(rp),marker_lines=[dict(line=i,text=line)for i,line in enumerate(lines,1)if any(m in line for m in ('CLI_SWATCH_PTY_PASS','CLI_ANCHORED_PARENT_PTY_PASS','STORAGE_INTEGRATION_PASS','READER_INTEGRATION_PASS checks=50'))]);result['reader_markers']=markers(text,contract,report)
           reader_lines=[line for line in lines if line.startswith('READER_INTEGRATION_PASS checks=50:')];assert len(reader_lines)==1
           artifacts=Path(reader_lines[0].split(' Artifacts: ',1)[1]);assert artifacts==rp.parent.parent and artifacts.resolve()==artifacts
           border=artifacts/'writer-image-border';payload=border/'image-border-contract.dprd';body=border/'image-border-contract.json';fixture=border/'.reader-fixture'
           assert payload.read_bytes().startswith(b'DPRD') and fixture.read_text()=='Synthetic ordinary Writer image border conformance fixture.\n'
           obj=json.loads(body.read_text());assert len(obj['entries'])==1
           entry=obj['entries'][0];images=[span for section in entry['sections']for block in section['blocks']for span in block.get('spans',[])if 'image'in span]
           assert len(images)==4 and sum(span['image'].get('border',False)is True for span in images)==3
           assert images[0]['image']['file']=='Flag of Poland.svg' and images[0]['image']['width_px']==40 and images[0]['target']=='File:Flag of Poland.svg'
           assert images[1]['image']['width_px']==30 and 'border'not in images[1]['image']
           result['writer_image_border']=dict(payload=ref(payload),normal_cli_json=ref(body),fixture_marker=ref(fixture),reader_source=private_model['files']['tools/reader_integration_test.zig'],ffi_test_source=private_model['files']['tools/ffi_integration_test.c'],normal_reader_checks=50,ffi_child_marker_asserted_inside_native_harness=True,ffi_stdout_retained=False,genuine_writer_fixture=True)
           result['full_native_pass']=True;save()
         if cfg['execution_stage']!='focused-diagnostic':
          tail_stages=[('bundle',['test-bundle'],'bundle_pass')] if cfg['execution_stage']=='tail' else [('bundle-pipeline',['test-bundle-pipeline'],'bundle_pipeline_pass'),('bundle',['test-bundle'],'bundle_pass')]
          for label,targets,key in tail_stages:
           so,se=execute(label,qualification_build_argv(args,cache,w['native_build_argv'],family=label,prefix=Path(cfg['install_root'])))
           if label=='bundle':assert len(re.findall(r'BUNDLE_INTEGRATION_PASS checks='+str(cfg['bundle_expected_checks'])+r':',so+'\n'+se))==1
           result[key]=True;save()
          execute('cli-smoke',[cli['path'],'--help']);result['cli_smoke_pass']=True
          for installed in result['installed'].values():auth(installed)
          result['installed_dynamic_identity']=dynamic['validate'](ds,binary=cli['path']);guard();result.update(passed=True,status='passed');save()
         else:
          guard();result.update(passed=True,status='passed',qualification_scope='focused-diagnostic-only',full_native_pass=False);save()
        except BaseException as exc:
         result.update(error=repr(exc),passed=False,status='failed');save();raise
        finally:
         try:result['source_guard_after']=final_source_guard()
         except BaseException as guard_error:
          result['source_guard_after']=False;result['final_guard_error']=repr(guard_error);result['core_provenance']=observed_core_provenance;save();raise
         result['core_provenance']=observed_core_provenance;save()
