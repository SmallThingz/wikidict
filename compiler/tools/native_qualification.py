#!/usr/bin/env python3
"""Existing native qualification owner/worker, with authenticated per-run data."""


LEGACY_FULL_DIAGNOSTIC_ROOTS = (
    ('closure_tests', 'closure', None), ('provider_tests', 'provider', None),
    ('storage_unit', 'storage_unit', None), ('namespace_registry_tests', 'namespace_registry', None),
    ('encoder_compile', 'encoder_compile', 'presentation_compile.test.'),
    ('encoder_document', 'encoder_document', 'presentation_document.test.'),
    ('encoder_writer', 'encoder_writer', 'blob_builder.test.'),
    ('encoder_support', 'encoder_support', None),
    ('blob_encoder_tests', 'blob_encoder', None), ('blob_decoder_tests', 'blob_decoder', None),
    ('blob_query_tests', 'blob_query', None), ('wikimedia_dump_tests', 'wikimedia_dump', None),
    ('lua_tests', 'lua', None), ('lua_core_tests', 'lua_core', None),
    ('global_index_tests', 'global_index', None), ('program_shapes_tests', 'program_shapes', None),
    ('lua_abi_tests', 'lua_abi', None), ('lua_stdlib_tests', 'lua_stdlib', None),
    ('lua_ustring_tests', 'lua_ustring', None), ('lua_scribunto_tests', 'lua_scribunto', None),
    ('lua_wikitext_tests', 'lua_wikitext', None), ('bundle_protocol_tests', 'bundle_protocol', None),
    ('bundle_pipeline_tests', 'bundle_pipeline', None), ('blob_build_tests', 'tools', None),
    ('blob_file_tools_tests', 'blob_file_tools', None), ('missing_dependency_tests', 'missing_dependency', None),
)
TOOLS_DIAGNOSTIC_ROOTS = (
    ('blob_build_normal_tests', 'tools_normal', None),
    ('blob_build_core_tests', 'tools_core', None),
    ('blob_build_observations_tests', 'tools_observations', None),
    ('blob_build_support_tests', 'tools_support', None),
)
FULL_DIAGNOSTIC_ROOTS = tuple(part for row in LEGACY_FULL_DIAGNOSTIC_ROOTS
                            for part in (TOOLS_DIAGNOSTIC_ROOTS if row[0] == 'blob_build_tests' else (row,)))


def full_diagnostic_root_layout(expected):
    """Select the exact current or sealed legacy physical-root inventory."""
    roots = {group['root'] for group in expected['groups']}
    for layout in (FULL_DIAGNOSTIC_ROOTS, LEGACY_FULL_DIAGNOSTIC_ROOTS):
        if roots == {row[0] for row in layout}:
            assert expected['expected_groups'] == len(expected['groups']) == len(layout)
            return layout
    raise AssertionError('Unknown or mixed full native root inventory')



def tools_logical_occurrences(roots):
    """Join current Tools physical roots without dropping multiplicities."""
    from collections import Counter
    counts = Counter()
    for root, _, _ in TOOLS_DIAGNOSTIC_ROOTS:
        counts.update(roots[root])
    assert counts and all(count == 1 for count in counts.values()), 'Overlapping Tools partition names'
    return counts


def prepared_cache_groups(selected, filters, *, full=False):
    """Normal physical cache selection; explicit focused Tools keeps one root."""
    groups = sorted(row[1] for row in FULL_DIAGNOSTIC_ROOTS)
    if full:
        return groups
    if selected is None:
        return [g for g in groups if g.startswith('encoder_') or g.startswith('tools_') or
                g in ('lua', 'lua_core', 'lua_abi', 'lua_stdlib', 'lua_wikitext')]
    if selected == 'encoder':
        return ['encoder'] if filters else [g for g in groups if g.startswith('encoder_')]
    if selected == 'tools_partitioned':
        return sorted(row[1] for row in TOOLS_DIAGNOSTIC_ROOTS)
    return [selected]


FUNCTIONAL_TEST_ERRORS = ('TestExpectedEqual', 'TestUnexpectedResult')
# These clean test-local failures do not prevent independent focused cases from
# running. They remain failures; full-suite and preparation policies are unchanged.


def execute_with_failure_output(executor, out, label, argv, cwd):
    """Keep bounded native failure streams in a fresh command-owned directory."""
    import errno
    import os
    from pathlib import Path
    import re

    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}', label):
        raise ValueError('Invalid command label for failure output')
    parent = Path(out) / 'test-failures'
    parent.mkdir(mode=0o700, exist_ok=True)
    if parent.is_symlink() or not parent.is_dir():
        raise ValueError('Failure output parent is not an owned directory')
    directory = parent / label
    directory.mkdir(mode=0o700)
    key = 'WIKIDICT_TEST_FAILURE_OUTPUT_DIR'
    previous = os.environ.get(key)
    os.environ[key] = str(directory.absolute())
    try:
        return executor(out, label, argv, cwd)
    finally:
        if previous is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = previous
        # Passing commands leave no payload; failed streams remain verbatim.
        try:
            directory.rmdir()
        except OSError as error:
            if error.errno != errno.ENOTEMPTY:
                raise


def full_diagnostic_groups(expected):
    from collections import Counter
    groups = expected['groups']
    layout = full_diagnostic_root_layout(expected)
    assert len({g['root'] for g in groups}) == len(groups)
    assert {g['root'] for g in groups} == {r for r, _, _ in layout}
    by_root = {g['root']: g for g in groups}
    signatures = set()
    for group in groups:
        counts = group['expected_occurrences']
        assert type(counts) is dict and counts
        assert all(type(n) is str and n and '\n' not in n and type(c) is int and c > 0 for n, c in counts.items())
        signature = tuple(sorted(counts.items()))
        assert signature not in signatures, 'Ambiguous normal root inventory'
        signatures.add(signature)
    if layout == FULL_DIAGNOSTIC_ROOTS:
        tools_logical_occurrences({root: by_root[root]['expected_occurrences'] for root, _, _ in TOOLS_DIAGNOSTIC_ROOTS})
    assert sum(sum(g['expected_occurrences'].values()) for g in groups) == expected['expected_total']
    return [dict(root=root, prepared_group=alias, runtime_filter=runtime_filter,
                 expected_occurrences=Counter(by_root[root]['expected_occurrences']))
            for root, alias, runtime_filter in layout]


def completed_diagnostic_roots(groups, helper, stdout, stderr):
    """Only complete, exact normal runner inventories identify executed roots."""
    from collections import Counter
    import re
    signatures = {tuple(sorted(g['expected_occurrences'].items())): g['root'] for g in groups}
    observed = {}
    for stream in (stdout, stderr):
        pending = []
        for line in helper['ANSI'].sub('', stream).splitlines():
            status = helper['STATUS'].fullmatch(line)
            summary = helper['SUMMARY'].fullmatch(line)
            if status:
                kind, name = status.groups()
                assert '\ufffd' not in name
                if kind == 'error':
                    # The recorder emits this final field after clean allocator
                    # cleanup and the actual parent-observed exit. Never search
                    # the bounded human prefix for a returned-error marker.
                    field = line.rpartition(' | ')[2]
                    if field.startswith('returned-error-hex'):
                        terminal = re.search(r' \| exit 1 \| returned-error-hex=([0-9a-f]{2,256})$', line)
                        assert terminal and len(terminal[1]) % 2 == 0, 'Malformed returned-error terminal'
                        try:
                            error_name = bytes.fromhex(terminal[1]).decode('ascii')
                        except (ValueError, UnicodeError):
                            raise AssertionError('Malformed returned-error identifier') from None
                        assert re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', error_name), 'Malformed returned-error identifier'
                        assert error_name in FUNCTIONAL_TEST_ERRORS, 'Unproven functional runner termination'
                    else:
                        # Historical binaries retain their strict uncapped
                        # returned-error trailer; assertion prose is not proof.
                        diagnostic = line.rpartition(' | err: ')[2]
                        typed = re.search(r'(?:^| )([A-Za-z_][A-Za-z0-9_]*) error return trace unavailable \(enable error tracing for this test build\)  \| exit 1$', diagnostic)
                        assert typed and typed[1] in FUNCTIONAL_TEST_ERRORS, 'Unproven functional runner termination'
                assert kind in ('ok', 'error'), 'Resource/leak/crash/skip is not continuation authority'
                pending.append((kind, name))
            elif summary:
                counts = list(map(int, summary.groups()))
                assert counts == [sum(k == 'ok' for k, _ in pending), sum(k == 'error' for k, _ in pending), 0, 0, 0]
                signature = tuple(sorted(Counter(n for _, n in pending).items()))
                root = signatures.get(signature)
                assert root is not None and root not in observed, 'Unknown or duplicate completed root'
                observed[root] = dict(failed=bool(counts[1]), statuses=pending)
                pending = []
            else:
                assert not re.match(r'^(?:ok|error|skip|leak|crash) |^pass:', line), 'Malformed runner evidence'
        assert not pending, 'Incomplete normal root inventory'
    return observed


def failed_full_diagnostic_plan(expected, helper, command, stdout, stderr):
    """Conservative functional-failure authority, never a full acceptance path."""
    import re
    assert command['status'] == 'exited' and type(command['returncode']) is int and command['returncode'] == 1
    groups = full_diagnostic_groups(expected)
    text = helper['ANSI'].sub('', stdout + '\n' + stderr)
    observed = completed_diagnostic_roots(groups, helper, stdout, stderr)
    failures = sum(v['failed'] for v in observed.values())
    assert failures > 0
    # A direct compiler/tool failure must not be mistaken for a blocked test edge.
    assert re.findall(r'^error:.*$', text, re.M) == ['error: process exited with code 1'] * failures
    summaries = re.findall(r'^Build Summary: (\d+)/(\d+) steps succeeded \((\d+) failed\)$', text, re.M)
    assert len(summaries) == 1 and int(summaries[0][2]) == failures
    direct = re.findall(r'\brun test failure\s*$', text, re.M)
    assert len(direct) >= failures  # A failed graph node may be displayed through multiple dependency paths.
    assert not re.search(r'\b(?:compile|translate-c|run exe|run lib).* (?<!transitive )failure\s*$', text, re.M)
    return dict(groups=groups, observed=observed, remaining=[g for g in groups if g['root'] not in observed])


def collect_failed_full_roots(plan, *, helper, guarded_prepare, guarded_run, auth, save):
    """Serial diagnostics using the worker's source-guarded command callbacks.

    Both callbacks must use execute_outcome: it checks source before and after
    every subprocess and preserves the normal owner caps. This collector owns
    binary authentication and coverage, not a second set of source scans.
    """
    report = dict(diagnostic_only=True, full_suite_credit=False, original_full_failure_preserved=True,
                  already_executed=list(plan['observed']), roots=[], completed=False)
    save(report)
    for group in plan['remaining']:
        report['current_root'] = group['root']
        save(report)
        binary = guarded_prepare(group)  # Source/tool/resource/compile errors propagate.
        auth(binary)
        command, stdout, stderr = guarded_run(group, binary)
        auth(binary)
        assert command['status'] == 'exited' and type(command['returncode']) is int and command['returncode'] in (0, 1)
        text = helper['ANSI'].sub('', stdout + '\n' + stderr)
        assert not any(line.startswith('error:') for line in text.splitlines()), 'Unexpected tool diagnostic'
        observed = completed_diagnostic_roots([group], helper, stdout, stderr)
        assert list(observed) == [group['root']]
        failed = observed[group['root']]['failed']
        assert command['returncode'] == int(failed)
        report['roots'].append(dict(root=group['root'], binary=binary, command=command,
                                    passed=not failed, exact_inventory=True, full_suite_credit=False))
        save(report)
    report['completed'] = True
    report.pop('current_root', None)
    save(report)
    return report


def require_ordinary_preparation_compile_failure(command, stdout, stderr, helper):
    """Only a joined Zig test compilation diagnostic permits independent work."""
    import re
    import shlex
    assert command['status'] == 'exited' and type(command['returncode']) is int and command['returncode'] == 1
    assert command['argv'][:3] == [command['argv'][0], 'build', 'prepare-tests']
    assert stdout.strip() == '', 'Unexpected compiler stdout'
    text = helper['ANSI'].sub('', stderr)
    errors = re.findall(r'^error: ([1-9][0-9]*) compilation errors$', text, re.M)
    assert len(errors) == 1
    count = int(errors[0])
    assert re.findall(r'^error:.*$', text, re.M) == ['error: ' + str(count) + ' compilation errors']
    assert len(re.findall(r'^[^\r\n]+\.zig:[0-9]+:[0-9]+: error: .+$', text, re.M)) == count
    failed = re.findall(r'^failed command: (.+)$', text, re.M)
    assert len(failed) == 1 and shlex.split(failed[0])[:2] == [command['argv'][0], 'test']
    summaries = re.findall(r'^Build Summary: ([0-9]+)/([0-9]+) steps succeeded \(1 failed\)$', text, re.M)
    assert len(summaries) == 1 and int(summaries[0][0]) < int(summaries[0][1])
    assert re.findall(r'^Build Summary:.*$', text, re.M) == ['Build Summary: ' + summaries[0][0] + '/' + summaries[0][1] + ' steps succeeded (1 failed)']
    compile_counts = re.findall(r'compile test [^\r\n]+ ([1-9][0-9]*) errors$', text, re.M)
    assert compile_counts and all(int(n) == count for n in compile_counts)
    # Validate whole diagnostic lines, not resource-looking words in source
    # excerpts, selected test names, or failed-command arguments.
    lines = text.splitlines()
    source_line = re.compile(r'^[^\r\n]+\.zig:[0-9]+:[0-9]+: (?:error|note): .+$')
    pointer_line = re.compile(r'^[ \t]*[~^]+[ \t]*$')
    excerpts = set()
    for index, line in enumerate(lines):
        if (index > 0 and index + 1 < len(lines) and source_line.fullmatch(lines[index - 1])
                and pointer_line.fullmatch(lines[index + 1])):
            excerpts.update((index, index + 1))
    for index, line in enumerate(lines):
        if not line.strip() or index in excerpts or source_line.fullmatch(line):
            continue
        if line in ('prepare-tests', 'prepare-tests transitive failure', 'referenced by:',
                    'error: ' + str(count) + ' compilation errors'):
            continue
        if line.startswith('failed command: ') or line.startswith('Build Summary: '):
            continue  # Exact single instances and content checked above.
        if re.fullmatch(r'info\(verbose\): ' + re.escape(command['argv'][0]) +
                        r' (?:build-exe|build-obj|build-lib|translate-c|test) .+', line):
            continue
        if re.fullmatch(r'[ \t|]*\+- (?:install [A-Za-z0-9_-]+(?: transitive failure)?|'
                        r'compile test .+ [1-9][0-9]* errors|options success|'
                        r'(?:translate-c|options|WriteFile(?: [^\r\n]+)?) cached(?: .*)?)', line):
            continue
        if re.fullmatch(r'    (?:[^:\r\n]+: [^\r\n]+\.zig:[0-9]+:[0-9]+|'
                        r"[0-9]+ reference\(s\) hidden; use '-freference-trace=[0-9]+' to see all references)", line):
            continue
        raise AssertionError('Unrecognized preparation diagnostic line: ' + line)

    return dict(kind='ordinary_test_compile_failure', compilation_errors=count,
                command_exited=True, selected_tests_executed=False, full_suite_credit=False)


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
    # DPRG is this source cut's newest format; the selector still emits older wires
    # when those fields are absent. Legacy Reader/Writer checks remain required.
    assert binding.get('wire') == 'DPRG'


def qualification_build_argv(args, cache, native_build_argv, *, family, prefix=None,
                             prepare_test_error_tracing=False):
    """One source for every normal build's optional captured-source option."""
    assert family in ('prepare', 'full', 'install', 'bundle-pipeline', 'bundle')
    assert type(prepare_test_error_tracing) is bool
    assert family == 'prepare' or prepare_test_error_tracing is False
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
    assert not any(arg.startswith('-Dprepare-test-error-tracing') for arg in argv)
    if prepare_test_error_tracing:
        argv.append('-Dprepare-test-error-tracing=true')
    assert not any(arg.startswith('-Dcaptured-source-fingerprint') for arg in argv)
    fingerprint = getattr(args, 'captured_source_fingerprint', None)
    if fingerprint is not None:
        import re
        assert type(fingerprint) is str and re.fullmatch(r'[0-9a-f]{64}', fingerprint)
        argv.append('-Dcaptured-source-fingerprint=' + fingerprint)
    return argv


# Exact reviewed graph profile also proves absence of alias/prefix-dependent mutations.
PIPELINE_REUSE_GRAPH_PROFILE = dict(bytes=69486, sha256='10d87167663d9576898d3cfec1233a4193941d51b0019d8683acb99b0acdc0c2')
# The two public routes share this one artifact; no emitted-binary hash is inferred.
PIPELINE_REUSE_GRAPH_FRAGMENT = '''    const bundle_pipeline_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bundle_build.zig"),
            .target = b.graph.host,
            .optimize = test_optimize,
            .imports = &.{.{ .name = "pipeline_paths", .module = pipeline_paths.createModule() }},
        }),
        .test_runner = .{ .path = test_runner, .mode = .simple },
    });
    const run_bundle_pipeline_tests = b.addRunArtifact(bundle_pipeline_tests);
    const run_bundle_pipeline_tests_only = b.addRunArtifact(bundle_pipeline_tests);
'''


def full_pipeline_reuse_record(*, expected, helper, phase, stdout, stderr,
                               build_graph, build_source, source_manifest,
                               full_configuration, source_root, full_argv,
                               standalone_argv, native_passed, grouped_passed):
    """One successful normal execution, two obligations; never a second command."""
    from pathlib import Path
    import hashlib, re
    assert native_passed is True and grouped_passed is True
    command = phase['command']
    assert phase['name'] == 'full-native-suite'
    assert command['status'] == 'exited' and type(command['returncode']) is int and command['returncode'] == 0
    assert command['argv'] == full_argv and command['cwd'] == str(source_root)
    assert full_argv[:3] == [full_argv[0], 'build', 'test']
    assert standalone_argv[:3] == [full_argv[0], 'build', 'test-bundle-pipeline']

    def options(argv, prefix):
        values = {}; index = 3; seen_prefix = False
        while index < len(argv):
            arg = argv[index]; index += 1
            if arg == '--prefix':
                assert prefix and not seen_prefix and index < len(argv) and Path(argv[index]).is_absolute()
                seen_prefix = True; index += 1; continue
            if arg in ('--summary', '--search-prefix', '--cache-dir'):
                assert index < len(argv); key, value = arg, argv[index]; index += 1
            elif arg.startswith('-D') and '=' in arg:
                key, value = arg.split('=', 1)
            elif arg.startswith('-j') and arg[2:].isdigit():
                key, value = '-j', arg[2:]
            else:
                raise AssertionError('Unproved pipeline build option')
            assert key not in values; values[key] = value
        assert seen_prefix is prefix
        return values
    effective = options(full_argv, False)
    assert effective == options(standalone_argv, True)
    allowed = {'-j','-Doptimize','-Dtarget','-Dcpu','--summary','--search-prefix','--cache-dir'}
    assert set(effective) in (allowed, allowed | {'-Dcaptured-source-fingerprint'})
    assert effective['--summary'] == 'all' and effective['--search-prefix'] == '/usr'
    assert effective['-j'] == '2' and effective['-Doptimize'] == 'safe'
    assert effective['-Dtarget'] == 'x86_64-native' and effective['-Dcpu'] == 'baseline'
    if '-Dcaptured-source-fingerprint' in effective:
        assert effective['-Dcaptured-source-fingerprint'] == source_manifest['sha256']
    assert build_graph == expected['build_graph'] and Path(build_graph['path']) == Path(source_root) / 'build.zig'
    encoded = build_source.encode()
    assert len(encoded) == build_graph['bytes'] and hashlib.sha256(encoded).hexdigest() == build_graph['sha256']
    assert {key: build_graph[key] for key in ('bytes','sha256')} == PIPELINE_REUSE_GRAPH_PROFILE, 'Unreviewed pipeline artifact or prefix-dependency graph'
    for fragment in (PIPELINE_REUSE_GRAPH_FRAGMENT,
                     '    const test_optimize: std.builtin.Optimize = .safe;',
                     '    run_bundle_pipeline_tests.step.dependOn(&blob_wasm_smoke.step);',
                     '    run_blob_build_tests.step.dependOn(&run_bundle_pipeline_tests.step);',
                     '    test_step.dependOn(&run_blob_build_tests.step);',
                     '    b.step("test-bundle-pipeline", "Run bundle build scheduler and cache bitmap unit tests only").dependOn(&run_bundle_pipeline_tests_only.step);'):
        assert build_source.count(fragment) == 1, 'Unproved shared pipeline artifact graph'
    assert not re.search(r"\brun_bundle_pipeline_tests(?:_only)?\.(?!step\b)", build_source), 'Unproved pipeline child arguments or environment'
    groups = full_diagnostic_groups(expected)
    observed = completed_diagnostic_roots(groups, helper, stdout, stderr)
    assert set(observed) == {group['root'] for group in groups} and all(not row['failed'] for row in observed.values())
    pipeline = next(group for group in groups if group['root'] == 'bundle_pipeline_tests')
    assert sum(pipeline['expected_occurrences'].values()) == 23
    statuses = observed['bundle_pipeline_tests']['statuses']
    assert len(statuses) == 23 and all(kind == 'ok' for kind, name in statuses)
    return dict(authority='successful-normal-full-root', full_phase=phase,
                full_configuration=full_configuration, source_manifest=source_manifest,
                source_root=str(source_root), build_graph=build_graph, reviewed_graph_profile=dict(PIPELINE_REUSE_GRAPH_PROFILE),
                effective_build_options=effective, expected_occurrences=dict(pipeline['expected_occurrences']),
                summary=[23, 0, 0, 0, 0], executions=1,
                satisfies=['full-native-suite', 'bundle-pipeline-tail'],
                standalone_command_executed=False, emitted_binary_descriptor=None,
                artifact_authority='Same authenticated addTest object, module/options/runner/dependencies and no child arguments; no per-binary descriptor claimed')


def assess_completed_native_full(*, cfg, expect, full, execution_configuration, helper,
                                inventory, markers, auth, ref, source_files):
    """Recompute retained full evidence; this function executes no commands."""
    from pathlib import Path
    from types import SimpleNamespace
    import pathlib, json, re
    w=helper;inv=inventory;private=Path(cfg['retained_source']['path'])
    cache=Path(cfg['retained_cache']['path']);private_model=dict(files=source_files)
    args=SimpleNamespace(compiler=Path(cfg['compiler']['path']),captured_source_fingerprint=cfg.get('captured_source_fingerprint'))
    full_argv=qualification_build_argv(args,cache,w['native_build_argv'],family='full')
    assert full['command']['status']=='exited' and full['command']['returncode']==0
    assert full['command']['argv']==full_argv and full['command']['cwd']==str(private)
    so=auth(full['stdout']).read_text(errors='replace');se=auth(full['stderr']).read_text(errors='replace')
    result={}
    native=w['classify'](so,se,standalone=False);assert native['passed'];result['native_inventory']=native;result['grouped_inventory']=inv['validate_grouped'](w,expect['expected'],so,se)
    text=w['ANSI'].sub('',so+'\n'+se);names=[name for status,name in w['STATUS'].findall(text) if status=='ok'];assert len(names)==cfg['full_native_expected']
    actual={name:sum(n.endswith('.test.'+name) for n in names) for name in expect['required_test_counts']};assert actual==expect['required_test_counts'];result['required_test_counts']=actual
    lines=text.splitlines();prefix='CLI_SWATCH_PTY_PASS child summary/report: ';summaries=[json.loads(line[len(prefix):]) for line in lines if line.startswith(prefix)];assert len(summaries)==1;summary=summaries[0];rp=pathlib.Path(summary['report']);relative_report=rp.relative_to(cache/'local')
    assert rp.is_absolute()and rp.resolve()==rp and rp.is_file()and not rp.is_symlink()
    assert len(relative_report.parts)==3 and re.fullmatch(r'reader-integration-[0-9]+',relative_report.parts[0])and re.fullmatch(r'reader-ux-[A-Za-z0-9_-]+',relative_report.parts[1])and relative_report.parts[2]=='report.json'
    report=json.loads(auth(ref(rp)).read_text());contract=dict(observed_child_summary=summary,child_report=ref(rp),marker_lines=[dict(line=i,text=line)for i,line in enumerate(lines,1)if any(m in line for m in ('CLI_SWATCH_PTY_PASS','CLI_ANCHORED_PARENT_PTY_PASS','STORAGE_INTEGRATION_PASS','READER_INTEGRATION_PASS checks=50'))]);result['reader_markers']=markers(text,contract,report)
    reader_lines=[line for line in lines if line.startswith('READER_INTEGRATION_PASS checks=50:')];assert len(reader_lines)==1
    artifacts=Path(reader_lines[0].split(' Artifacts: ',1)[1]);assert artifacts==rp.parent.parent and artifacts.resolve()==artifacts
    border=artifacts/'writer-image-border';payload=border/'image-border-contract.dprd';body=border/'image-border-contract.json';fixture=border/'.reader-fixture'
    assert auth(ref(payload)).read_bytes().startswith(b'DPRD') and auth(ref(fixture)).read_text()=='Synthetic ordinary Writer image border conformance fixture.\n'
    obj=json.loads(auth(ref(body)).read_text());assert len(obj['entries'])==1
    entry=obj['entries'][0];images=[span for section in entry['sections']for block in section['blocks']for span in block.get('spans',[])if 'image'in span]
    assert len(images)==4 and sum(span['image'].get('border',False)is True for span in images)==3
    assert images[0]['image']['file']=='Flag of Poland.svg' and images[0]['image']['width_px']==40 and images[0]['target']=='File:Flag of Poland.svg'
    assert images[1]['image']['width_px']==30 and 'border'not in images[1]['image']
    result['writer_image_border']=dict(payload=ref(payload),normal_cli_json=ref(body),fixture_marker=ref(fixture),reader_source=private_model['files'][qualification_source_key(private_model['files'], 'tools/reader_integration_test.zig')],ffi_test_source=private_model['files'][qualification_source_key(private_model['files'], 'tools/ffi_integration_test.c')],normal_reader_checks=50,ffi_child_marker_asserted_inside_native_harness=True,ffi_stdout_retained=False,genuine_writer_fixture=True)
    if cfg.get('reuse_full_bundle_pipeline',False):
     graph=ref(private/'build.zig')
     result['bundle_pipeline_reuse']=full_pipeline_reuse_record(expected=expect['expected'],helper=w,phase=full,stdout=so,stderr=se,build_graph=graph,build_source=auth(graph).read_text(),source_manifest=cfg['private_manifest'],full_configuration=execution_configuration,source_root=private,full_argv=full_argv,standalone_argv=qualification_build_argv(args,cache,w['native_build_argv'],family='bundle-pipeline',prefix=Path(cfg['install_root'])),native_passed=native['passed'],grouped_passed=result['grouped_inventory']['passed'])
     result['bundle_pipeline_pass']=True
    result['full_native_pass']=True
    return result


def reconcile_accounting_tail(*, cfg, expect, reuse, prior_cfg, prior, closed,
                              released, read, auth, ref, helper, inventory,
                              markers, source_files):
    """Adopt only a proven metadata-accounting failure, retaining raw authority.

    The supplied assessment is an authenticated evidence locator, never a source
    of PASS booleans. All actual full/Reader/image/pipeline evidence is recomputed.
    """
    from pathlib import Path
    import copy
    evidence=read(reuse['accounting_assessment'])
    assert evidence['original_configuration']==reuse['configuration']
    assert evidence['original_result']==reuse['result']
    assert evidence['original_failed_closure']==reuse['closure']
    assert evidence['corrected_expectation']==cfg['expectation']
    assert prior['status']=='failed' and prior['passed'] is False
    assert prior['error']=='AssertionError()' and prior['source_guard_after'] is True
    assert prior['full_native_pass'] is False and prior['bundle_pipeline_pass'] is False
    assert not prior['bundle_pass'] and prior['cli_ffi_install_pass'] is True
    assert closed['status']=='FULL-ACCOUNTING-FAILED-CLOSED'
    assert closed['configuration']==reuse['configuration'] and closed['result']==reuse['result']
    assert closed['physical_closure'] and closed['cleanup_complete'] and closed['source_guard_after'] and closed['locks_free']
    assert released['physical_closure']==reuse['closure'] and released['released']
    assert released['source_custody_released'] and released['cache_custody_released']
    assert closed['expected_source_inventory']==cfg['private_manifest']==prior_cfg['private_manifest']
    old=read(prior_cfg['expectation']);corrected=copy.deepcopy(old)
    qualified={name for group in old['expected']['groups']for name in group['expected_occurrences']}
    normalized={};changes=[]
    for name,count in old['required_test_counts'].items():
        title=name
        if name in qualified:
            assert '.test.' in name
            title=name.split('.test.',1)[1]
            changes.append((name,title))
        assert title not in normalized and type(count)is int and count>0
        normalized[title]=count
    assert changes and len(normalized)==len(old['required_test_counts'])
    assert sum(normalized.values())==sum(old['required_test_counts'].values())
    corrected['required_test_counts']=normalized
    corrected['expected']['normal_required_names']=sorted(normalized)
    manifest=read(cfg['private_manifest']);graph=manifest['build.zig']
    assert old['expected']['build_graph']['path']==str(Path(cfg['retained_source']['path'])/'build.zig')
    corrected['expected']['build_graph']=dict(path=old['expected']['build_graph']['path'],bytes=graph['bytes'],sha256=graph['sha256'])
    assert corrected==expect, 'Unrelated expectation correction'
    fulls=[phase for phase in prior['phases']if phase['name']=='full-native-suite'];assert len(fulls)==1
    assert prior['native_inventory']['passed'] and prior['grouped_inventory']['passed']
    assessed=assess_completed_native_full(cfg=cfg,expect=expect,full=fulls[0],execution_configuration=reuse['configuration'],helper=helper,inventory=inventory,markers=markers,auth=auth,ref=ref,source_files=source_files)
    assert assessed['native_inventory']==prior['native_inventory']
    assert assessed['grouped_inventory']==prior['grouped_inventory']
    assert assessed['full_native_pass'] and assessed['bundle_pipeline_pass']
    names=[name for kind,name in helper['STATUS'].findall(helper['ANSI'].sub('',auth(fulls[0]['stdout']).read_text(errors='replace')+'\n'+auth(fulls[0]['stderr']).read_text(errors='replace')))if kind=='ok']
    for original,title in changes:
        assert names.count(original)==old['required_test_counts'][original]
    derived=copy.deepcopy(prior);derived.update(assessed)
    derived['accounting_reconciliation']=dict(original_configuration=reuse['configuration'],original_result=reuse['result'],original_failed_closure=reuse['closure'],original_release=reuse['release'],assessment=reuse['accounting_assessment'],corrected_expectation=cfg['expectation'],normalized_required_keys=len(changes),original_status=prior['status'],original_error=prior['error'],execution_configuration=reuse['configuration'],native_commands_executed=0)
    # These local views satisfy the existing tail contracts; no raw receipt changes.
    prior_view=copy.deepcopy(prior_cfg);prior_view['expectation']=cfg['expectation']
    closed_view=copy.deepcopy(closed);closed_view.update(source_guard=True,cleanup_proven=True,full_native_pass=True,bundle_pipeline_pass=True,full_actual_passed_tests=cfg['full_native_expected'],required_test_occurrences=sum(normalized.values()),reader_markers=assessed['reader_markers'],installed=prior['installed'])
    released_view=copy.deepcopy(released);released_view.update(closure=reuse['closure'],source_guard=True,cleanup_proven=True,locks_free=True)
    return prior_view,derived,closed_view,released_view


def bundle_pipeline_tail_stages(execution_stage, reuse):
    if reuse is not None:
        assert type(reuse) is dict and reuse.get('authority') == 'successful-normal-full-root'
        assert type(reuse.get('executions')) is int and reuse['executions'] == 1
        assert reuse.get('standalone_command_executed') is False
        summary = reuse.get('summary')
        assert type(summary) is list and len(summary) == 5 and all(type(value) is int for value in summary)
        assert summary == [23, 0, 0, 0, 0]
    if execution_stage == 'tail' or reuse is not None:
        return [('bundle', ['test-bundle'], 'bundle_pass')]
    return [('bundle-pipeline', ['test-bundle-pipeline'], 'bundle_pipeline_pass'),
            ('bundle', ['test-bundle'], 'bundle_pass')]


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


def qualification_source_key(inventory, legacy_name):
    """Select one authenticated current or retained legacy source member."""
    if legacy_name.startswith('tools/'):
        current = 'compiler/' + legacy_name
    elif legacy_name.startswith('src/ffi/'):
        current = 'renderer/' + legacy_name
    else:
        raise ValueError('Unsupported qualification source member: ' + legacy_name)
    selected = [name for name in (current, legacy_name) if name in inventory]
    assert len(selected) == 1, 'Missing or mixed qualification source member'
    return selected[0]


def canonical_runtime_input_keys(canonical_inputs):
    selected = qualification_source_key(canonical_inputs, 'tools/build_resource_limits.py')
    prefix = selected.removesuffix('build_resource_limits.py')
    return {prefix + name for name in ('build_resource_limits.py', 'build_watchdog_guardian.py',
                                      'build_disk_limits.py', 'extraction_cache.py')}


def bound_repository_root(limits_descriptor, canonical_inputs, auth):
    """Derive the checkout from the exact canonical helper consumed by both roles."""
    from pathlib import Path
    limits = auth(limits_descriptor)
    assert limits == Path(limits_descriptor['path']) and limits.is_absolute()
    assert not limits.is_symlink() and limits.resolve() == limits
    assert limits.name == 'build_resource_limits.py' and limits.parent.name == 'tools'
    name = qualification_source_key(canonical_inputs, 'tools/build_resource_limits.py')
    canonical_limits = canonical_inputs[name]['reference']
    assert {key: canonical_limits[key] for key in ('path', 'bytes', 'sha256')} == \
        {key: limits_descriptor[key] for key in ('path', 'bytes', 'sha256')}
    root = limits.parents[len(Path(name).parts) - 1]
    assert limits == root / name
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
    prerequisite = cfg.get('tools_prerequisite', False)
    assert type(prerequisite) is bool and type(binding.get('tools_prerequisite', False)) is bool
    assert prerequisite == binding.get('tools_prerequisite', False)
    if prerequisite:
        tools = [case for case in cases if case[0]['id'] == 'tools']
        assert tools and cases[:len(tools)] == tools, 'Tools prerequisite must be one complete initial group'
    filtered = cfg.get('filtered_tools_prerequisite', False)
    assert type(filtered) is bool and type(binding.get('filtered_tools_prerequisite', False)) is bool
    assert filtered == binding.get('filtered_tools_prerequisite', False)
    assert not filtered or prerequisite, 'Filtered tools require the complete initial tools prerequisite'
    filtered_only = cfg.get('filtered_tools_only', False)
    assert type(filtered_only) is bool and type(binding.get('filtered_tools_only', False)) is bool
    assert filtered_only == binding.get('filtered_tools_only', False)
    if filtered_only:
        assert cfg['execution_stage'] == 'focused-diagnostic'
        assert filtered if any(group['id'] == 'tools' for group in ordered) else not prerequisite
        fixed_encoder = {name for name, (_, filters, _) in normal_preparation_modes().items() if filters}
        assert {group['id'] for group in ordered} <= fixed_encoder | {'tools'}
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
    assert cfg['execution_stage'] in ('full','tail','focused-diagnostic') and cfg['focused_expected']>0
    normal_modes=normal_preparation_modes()
    assert prepared_names==tuple(name for name in normal_modes if name in selected_ids) and selected_ids==list(prepared_names) and cfg['focused_expected']==len(focus_cases)
    assert group_binding['compile_time_filtered_preparation'] is any(group['compile_time_filtered'] for group in cfg['groups']) and group_binding['prepare_target']=='prepare-tests' and group_binding['prepared_relative_directory']=='bin/wikidict-tests'
    assert type(group_binding['prepare_test_error_tracing']) is bool and group_binding['full_normal_partitioned_graph_required'] is True
    assert expect['expected']['logical_expected_groups']==23 and expect['expected']['logical_global_occurrences_equal_physical'] is True
    physical_groups=expect['expected']['expected_groups']
    assert type(physical_groups)is int and physical_groups in (26,29)
    # Focused binding describes selected roots, not a full runtime inventory.
    # Full-outcome parsing separately requires an exact26 or29 root layout.
    all_roots={root['root']:root['expected_occurrences'] for root in expect['expected']['groups']}
    partition_roots={root for root,_,_ in TOOLS_DIAGNOSTIC_ROOTS}
    present=partition_roots.intersection(all_roots)
    if physical_groups==26:
     assert not present
    else:
     assert 'blob_build_tests' not in all_roots
     if present:all_roots['blob_build_tests']=tools_logical_occurrences(all_roots)
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
     if cfg.get('filtered_tools_prerequisite', False) and prepared=='tools':
      selected=group['test_names']
      # Zig ORs substring filters; refuse a selected name matching an extra test.
      assert Counter(name for name in expected if any(item in name for item in selected))==Counter(selected)
      assert not filters and not discovery
     prepare_filters[prepared]=[];prepare_discovery[prepared]=discovery
    focused_encoder_preparation(cfg, expect)
    return prepared_names, prepare_filters, prepare_discovery


def _qualification_stat_fields(info):
    return [getattr(info, 'st_' + key) for key in ('dev','ino','mode','uid','gid','nlink','size','mtime_ns','ctime_ns')]


def qualification_input_file(path):
    """Authenticate a physical input or issued executable by descriptor and identity."""
    import hashlib, os, stat
    from pathlib import Path
    path = Path(path)
    observed = path.lstat()
    if not stat.S_ISREG(observed.st_mode):
        raise ValueError(f'Expected physical regular file: {path}')
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), 'rb') as stream:
        if _qualification_stat_fields(os.fstat(stream.fileno())) != _qualification_stat_fields(observed):
            raise ValueError(f'Input replaced before open: {path}')
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        if _qualification_stat_fields(os.fstat(stream.fileno())) != _qualification_stat_fields(observed) or _qualification_stat_fields(path.lstat()) != _qualification_stat_fields(observed):
            raise ValueError(f'Input changed while read: {path}')
    return [str(path), _qualification_stat_fields(observed), digest]


def qualification_pin_source(overlay, repo, branch, relative_file, revision, sha256):
    """Create a fresh sparse branch before qualification_input_inventory.

    Create the previously absent `branch` with one selected Git file and links
    to its siblings. The caller exclusively owns the unstarted overlay.
    Existing branch entries stay under their current owner's custody.
    """
    import hashlib, os, re, subprocess, tempfile
    from pathlib import Path
    repo, overlay = Path(repo).absolute(), Path(overlay).absolute()
    branch, relative_file = Path(branch), Path(relative_file)
    if (not branch.parts or not relative_file.parts or branch.is_absolute() or relative_file.is_absolute()
            or '..' in branch.parts or '..' in relative_file.parts or not relative_file.is_relative_to(branch)
            or not re.fullmatch('[0-9a-f]{40}', revision) or not re.fullmatch('[0-9a-f]{64}', sha256)):
        raise ValueError('Invalid qualification source pin')
    target = overlay / branch
    source = repo / relative_file
    if (repo.resolve(strict=True) != repo or overlay.resolve(strict=True) != overlay
            or not overlay.is_relative_to(repo / '.tmp') or overlay == repo / '.tmp'
            or target.parent.resolve(strict=True) != target.parent or os.path.lexists(target)
            or source.resolve(strict=True) != source or target.parent.stat().st_uid != os.geteuid()):
        raise ValueError('Qualification pin requires a fresh branch in an owned physical overlay')
    git = ['git', '--no-replace-objects', '--literal-pathspecs']
    if subprocess.check_output([*git,'cat-file','-t',revision],cwd=repo) != b'commit\n':
        raise ValueError('Qualification source pin requires an exact commit')
    entry = subprocess.check_output([*git,'ls-tree','-z',revision,'--',str(relative_file)],cwd=repo)
    metadata, separator, name = entry.partition(b'\t')
    fields = metadata.split()
    if (not separator or name != os.fsencode(relative_file) + b'\0' or len(fields) != 3
            or fields[0] not in (b'100644',b'100755') or fields[1] != b'blob'):
        raise ValueError('Qualification pin is not a regular file in the selected revision')
    raw = subprocess.check_output([*git,'cat-file','blob',fields[2]],cwd=repo)
    if hashlib.sha256(raw).hexdigest() != sha256 or qualification_input_file(source)[2] != sha256:
        raise ValueError('Qualification pin differs from the selected Git or checkout bytes')
    with tempfile.TemporaryDirectory(prefix='.qualification-pin-', dir=target.parent) as temp:
        staged = Path(temp) / 'branch'
        destination, origin = staged, repo / branch
        for part in relative_file.relative_to(branch).parts:
            destination.mkdir()
            for sibling in origin.iterdir():
                if sibling.name != part:
                    (destination / sibling.name).symlink_to(sibling)
            destination = destination / part
            origin = origin / part
        with destination.open('xb') as out:
            out.write(raw)
        destination.chmod(int(fields[0],8) & 0o777)
        if qualification_input_file(destination)[2] != sha256 or os.path.lexists(target):
            raise ValueError('Qualification pin changed before publication')
        from build_wiktionaries import _publish_prepared_metadata_no_replace
        _publish_prepared_metadata_no_replace(staged, target)
    return overlay / relative_file


def qualification_input_inventory(overlay, allowed_root, roots, extras=()):
    """Snapshot the source projection actually used by a scoped native build.

    Call before and after the build and compare the returned dictionaries.
    Track Git lineage separately, including commits affecting only private copies.
    """
    import os
    from pathlib import Path
    overlay = Path(overlay)
    allowed_root = Path(allowed_root).resolve(strict=True)
    entries = {}
    def collect(path, active=()):
        key = str(path.relative_to(overlay))
        physical = path.resolve(strict=True)
        if not physical.is_relative_to(allowed_root):
            raise ValueError(f'Source escapes issued checkout: {path}')
        # Preserve every projection link's own identity as well as its target.
        for link in reversed((path, *path.parents)):
            if link.is_relative_to(overlay) and link.is_symlink():
                entries['link:' + str(link.relative_to(overlay))] = [_qualification_stat_fields(link.lstat()), os.readlink(link)]
        before = _qualification_stat_fields(physical.lstat())
        if not physical.is_dir():
            entries['file:' + key] = qualification_input_file(physical)
            return
        if physical in active:
            raise ValueError(f'Source projection cycle: {path}')
        entries['dir:' + key] = [str(physical), before]
        for child in sorted(path.iterdir()):
            collect(child, (*active, physical))
        if _qualification_stat_fields(physical.lstat()) != before:
            raise ValueError(f'Input changed during enumeration: {path}')
    for key in roots:
        collect(overlay / key)
    for extra in extras:
        extra = Path(extra)
        entries['extra:' + str(extra)] = qualification_input_file(extra)
    return entries


def focused_prepared_names(group, selected, *, imported_discovery=(), source_occurrences=None):
    """Exact artifact inventory for fully qualified, explicitly chosen test names."""
    if not selected or len(set(selected)) != len(selected):
        raise ValueError('Focused native tests must be nonempty and unique')
    discovery = {'encoder': 'root.test.encoder root imports bundle-time presentation modules',
                 'lua': 'tests.test_0', 'blob_query': 'main.test_0'}.get(group)
    required = [discovery] if discovery else []
    # Unnamed tests in reached dependency modules may be emitted independently
    # of Zig's root-name filters. Require source-bound inventory for such cases.
    for name in imported_discovery:
        if (group != 'lua_wikitext' or name != 'ustring_pattern.test_0' or name in required or
                source_occurrences is None or source_occurrences.get(name) != 1):
            raise ValueError('Invalid source-bound discovery test: ' + name)
        required.append(name)
    return list(selected) + [name for name in required if name not in selected]


def focused_encoder_preparation(cfg, expect):
    """Bind one selected encoder artifact to all requested logical partitions."""
    if not cfg.get('filtered_tools_only', False):
        return None
    from collections import Counter
    modes = normal_preparation_modes()
    encoders = {name: physical for name, (physical, filters, _) in modes.items() if filters}
    groups = [group for group in cfg['groups'] if group['id'] in encoders]
    if not groups:
        return None
    roots = expect['expected']['groups']
    assert len({row['root'] for row in roots}) == len(roots)
    source = Counter()
    for row in roots:
        if row['root'] in encoders.values():
            members = Counter(row['expected_occurrences'])
            assert all(type(count) is int and count == 1 for count in members.values())
            source.update(members)
    assert {row['root'] for row in roots} >= set(encoders.values())
    assert all(type(count) is int and count == 1 for count in source.values())
    selected = [name for group in groups for name in group['test_names']]
    assert selected and len(selected) == len(set(selected))
    discovery = 'root.test.encoder root imports bundle-time presentation modules'
    assert source[discovery] == 1
    compiled = focused_prepared_names('encoder', selected)
    # Build.zig ORs substring filters across the whole encoder root, including
    # partitions not requested here. No extra or ambiguous match is admissible.
    filters = selected + ['encoder root imports bundle-time presentation modules']
    assert Counter(name for name, count in source.items() for _ in range(count)
                   if any(value in name for value in filters)) == Counter(compiled)
    return dict(groups=[group['id'] for group in groups], filters=selected,
                compiled_expected_occurrences=compiled,
                discovery=[] if discovery in selected else [discovery],
                source_occurrences=sum(source.values()), full_suite_credit=False)


def qualification_binding_plan(cfg, group_binding, expect, source_root):
    """Derive the binding report from the same required runtime contracts."""
    ordered, cases = bound_focus_plan(cfg, group_binding, source_root)
    prepared, _, _ = validate_preparation_plan(cfg, group_binding, expect, ordered, cases)
    report = {
        'actual_case_order': [dict(group=group['id'], name=name)
                              for group, _, name, _ in cases],
        'prepared_groups': list(prepared),
        'compiled_counts': {group['id']: group['compiled_expected_count']
                            for group in cfg['groups']},
        'functional_failures_collected': True,
        'aggregate_full_gate_retained': True,
        'normal_full_required': cfg['execution_stage'] == 'full',
    }
    if cfg.get('tools_prerequisite', False):
        report['tools_prerequisite'] = True
    if cfg.get('filtered_tools_prerequisite', False):
        tools = next(group for group in cfg['groups'] if group['id'] == 'tools')
        filtered_only = cfg.get('filtered_tools_only', False)
        report['filtered_tools_prerequisite'] = dict(
            filters=list(tools['test_names']), compiled_expected_occurrences=list(tools['test_names']),
            ordinary_unfiltered_preparation_after_pass=not filtered_only,
            positive_path_preparations=1 if filtered_only else 2,
            other_group_preparations_unchanged=not filtered_only, full_suite_credit=False)
        if filtered_only:
            report['filtered_tools_only'] = True
            report['compiled_counts']['tools'] = len(tools['test_names'])
    encoder = focused_encoder_preparation(cfg, expect)
    if cfg.get('filtered_tools_only', False):
        report['filtered_tools_only'] = True
    if encoder is not None:
        report['filtered_encoder_preparation'] = encoder
        report['logical_source_counts'] = {group['id']: group['compiled_expected_count']
                                          for group in cfg['groups']}
        for name in encoder['groups']:
            del report['compiled_counts'][name]
        report['compiled_counts']['encoder'] = len(encoder['compiled_expected_occurrences'])
    return report


def record_independent_abort(result, commands):
    """Account an already-stopped worker; never classify, continue, or signal it."""
    from collections import Counter
    recorded=result.get('commands',[])
    names=[command['name'] for command in commands]
    if (len(names)!=len(set(names)) or len(recorded)>len(commands) or
            [row['name'] for row in recorded]!=names[:len(recorded)]):
        raise ValueError('Interrupted worker result is not an exact command prefix')
    remaining=[];unrun_tests=[]
    for command in commands[len(recorded):]:
        remaining.append(dict(name=command['name'],argv=list(command['argv']),cwd=command['cwd'],
            status='unrun',passed=False,returncode=None,reason='worker execution aborted',
            aborted_at=result.get('current_phase')))
        if 'independent_root' in command:
            unrun_tests.extend(Counter(command['independent_root']['expected_occurrences']).elements())
        elif 'independent_test' in command:
            unrun_tests.append(command['independent_test']['name'])
    result.setdefault('test_failures',[])
    # The raw exited row is already durable input. Add a failed classification
    # only when its ordinary classifier never completed; retain its logs/code.
    if recorded and recorded[-1]['name']==result.get('current_phase'):
        row=recorded[-1];command=commands[len(recorded)-1]
        if row.get('status')=='exited' and 'passed' not in row:
            row.update(passed=False,outcome='aborted',unclassified_termination=True)
            result['aborted_command']=row['name']
            if 'independent_test' in command or 'independent_root' in command:
                failures=result.setdefault('test_failures',[])
                if row['name'] not in failures:failures.append(row['name'])
    result.setdefault('unrun_commands',[]).extend(row['name'] for row in remaining)
    result.setdefault('unrun_tests',[]).extend(unrun_tests)
    recorded.extend(remaining)
    result['commands']=recorded
    result['passed']=False


def focused_returned_test_error(command, stderr, occurrences, unknown_name):
    """Recognize only the runner's terminal clean returned test error, never prose."""
    import re
    if (command.get('status') != 'exited' or type(command.get('returncode')) is not int
            or command['returncode'] != 1 or type(occurrences) is not int
            or occurrences != 1 or unknown_name):
        return None
    terminal = re.search(r'\nDICT_TEST_RETURN_ERROR_HEX=([0-9a-f]{2,256})\n\Z', stderr)
    if terminal is None or len(terminal[1]) % 2:
        return None
    try:
        name = bytes.fromhex(terminal[1]).decode('ascii')
    except (ValueError, UnicodeError):
        return None
    return name if name else None


def execute_focused_cases(cases, *, binaries, phase, source_root, helper, guard,
                          validate_dynamic, auth, ref, result, save,
                          prepare_group=None, stop_on_failure=False, tools_prerequisite=False,
                          compiled_inventories=None, after_group_pass=None, collect_returned_failures=False):
    """Use the existing exact-name executor and retain group/failure guards."""
    from collections import Counter
    assert type(tools_prerequisite) is bool and type(collect_returned_failures) is bool
    if tools_prerequisite:
        tools = [case for case in cases if case[0]['id'] == 'tools']
        assert tools and cases[:len(tools)] == tools

    def stop_tools(remaining, reason, *, preparation_failure=None, preparation_error=None):
        result['focused_prerequisite_failure'] = dict(group='tools', reason=reason,
            preparation_failure=preparation_failure, preparation_error=preparation_error)
        for group, index, name, declaration_name in remaining:
            result['focused_tests'].append(dict(name=name, group=group['id'], outcome='unrun',
                passed=False, executed=False, reason='tools_prerequisite_failed',
                command=None, stdout=None, stderr=None, binary=None,
                exact_name_discovered=None, prerequisite_group='tools',
                runner_mode='--dict-run-test', full_suite_credit=False))
        result['focused_qualified'] = False
        result['focused_evidence_total'] = sum(row.get('executed', True) for row in result['focused_tests'])
        result['all_selected_accounted'] = len(result['focused_tests']) == len(cases)
        result['all_selected_executed'] = result['focused_evidence_total'] == len(cases)
        save()

    def stop_independent(remaining, reason):
        result['focused_interruption'] = reason
        for group, index, name, declaration_name in remaining:
            result['focused_tests'].append(dict(name=name, group=group['id'], outcome='unrun',
                passed=False, executed=False, reason=reason, command=None, stdout=None, stderr=None,
                binary=None, exact_name_discovered=None, runner_mode='--dict-run-test', full_suite_credit=False))
        result['focused_qualified'] = False
        result['focused_evidence_total'] = sum(row.get('executed', True) for row in result['focused_tests'])
        result['all_selected_accounted'] = len(result['focused_tests']) == len(cases)
        result['all_selected_executed'] = result['focused_evidence_total'] == len(cases)
        save()

    offset = 0
    while offset < len(cases):
        group = cases[offset][0]
        end = offset + 1
        while end < len(cases) and cases[end][0]['id'] == group['id']:
            end += 1
        try:
            preparation = prepare_group(group) if prepare_group is not None else None
        except BaseException as error:
            if tools_prerequisite and group['id'] == 'tools':
                stop_tools(cases[offset:], 'preparation_error', preparation_error=repr(error))
            raise
        if preparation is False:
            guard(); validate_dynamic()
            failure = result['focused_preparation_failures'][group['prepared_group']]
            for _, index, name, declaration_name in cases[offset:end]:
                result['focused_tests'].append(dict(name=name, group=group['id'], outcome='unrun',
                    passed=False, executed=False, reason='preparation_compile_failed',
                    command=None, stdout=None, stderr=None, binary=None,
                    exact_name_discovered=None, preparation_failure=failure,
                    runner_mode='--dict-run-test', full_suite_credit=False))
                save()
            guard()
            if tools_prerequisite and group['id'] == 'tools':
                stop_tools(cases[end:], 'focused_preparation_failure', preparation_failure=failure)
                raise AssertionError('focused_preparation_failure')
            if collect_returned_failures:
                stop_independent(cases[end:], 'focused_preparation_failure')
                raise AssertionError('focused_preparation_failure')
            if stop_on_failure:
                result['focused_qualified'] = False
                result['focused_evidence_total'] = sum(row.get('executed', True) for row in result['focused_tests'])
                result['all_selected_executed'] = False
                save()
                raise AssertionError('focused_preparation_failure')
            offset = end
            continue
        first_row = len(result['focused_tests'])
        guard(); validate_dynamic()
        binary = binaries[group['prepared_group']]
        auth(binary)
        prepared_occurrences = Counter((compiled_inventories or {}).get(
            group['id'], group.get('compiled_expected_occurrences', ())))
        command_error = None
        try:
            for case_offset, (_, index, name, declaration_name) in enumerate(cases[offset:end], offset):
                auth(binary)
                label = group['id'] + '-' + str(index).zfill(2)
                command = helper['execute'](phase, label, [binary['path'], '--dict-run-test', name], source_root)
                stdout, stderr = phase / (label + '.stdout'), phase / (label + '.stderr')
                stdout_text = helper['ANSI'].sub('', stdout.read_text(errors='replace'))
                stderr_raw = stderr.read_text(errors='replace')
                stderr_text = helper['ANSI'].sub('', stderr_raw)
                exited = (command.get('status') == 'exited' and type(command.get('returncode')) is int
                          and command['returncode'] >= 0)
                unknown_name = (exited and command['returncode'] == 1 and stdout_text == '' and
                                stderr_text in ('unknown test: ' + name + '\n',
                                                'unknown test: ' + name + '\r\n'))
                occurrences = prepared_occurrences[name]
                # This is authenticated inventory discovery, not proof of body entry.
                discovered = (type(occurrences) is int and occurrences == 1) if exited else None
                if discovered is False:
                    discovered = None
                if unknown_name:
                    discovered = False
                passed = exited and command['returncode'] == 0
                row = dict(name=name, group=group['id'], command=command, stdout=ref(stdout),
                           stderr=ref(stderr), outcome='passed' if passed else 'failed', passed=passed,
                           binary=binary, exact_name_discovered=discovered,
                           exact_name_discovery=dict(prepared_occurrences=occurrences,
                                                     unknown_name_rejected=unknown_name),
                           runner_mode='--dict-run-test',
                           full_suite_credit=False)
                if collect_returned_failures and not passed:
                    row['returned_test_error'] = focused_returned_test_error(command, stderr_raw, occurrences, unknown_name)
                result['focused_tests'].append(row)
                save(); auth(binary)
                if collect_returned_failures and not passed and row['returned_test_error'] is None:
                    stop_independent(cases[case_offset + 1:], 'unproven_focused_termination')
                    raise AssertionError('focused_functional_failure')
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
        failed = not all(row['passed'] for row in result['focused_tests'][first_row:])
        if tools_prerequisite and group['id'] == 'tools' and failed and not collect_returned_failures:
            stop_tools(cases[end:], 'focused_functional_failure')
            raise AssertionError('focused_functional_failure')
        if stop_on_failure and failed:
            result['focused_qualified'] = False
            result['focused_evidence_total'] = len(result['focused_tests'])
            result['all_selected_executed'] = len(result['focused_tests']) == len(cases)
            save()
            raise AssertionError('focused_functional_failure')
        if not failed and after_group_pass is not None:
            try:
                after_group_pass(group)
            except BaseException as error:
                if tools_prerequisite and group['id'] == 'tools':
                    stop_tools(cases[end:], 'normal_preparation_error', preparation_error=repr(error),
                        preparation_failure=result.get('focused_preparation_failures', {}).get('tools'))
                raise
        offset = end


# Optional qualification cache retention. No production/global cache is selected.
def _retention_stamp(path):
    import os
    s = path.lstat()
    return {k: getattr(s, 'st_' + k) for k in ('dev','ino','mode','uid','gid','nlink','size','mtime_ns','ctime_ns')}


def _retention_path(path):
    import os
    from pathlib import Path
    path = Path(path)
    assert path.is_absolute() and str(path) == os.path.normpath(str(path))
    assert not any(node.is_symlink() for node in (path, *path.parents))
    return path


def _retention_json(reference):
    import hashlib, json
    path = _retention_path(reference['path']); before = _retention_stamp(path)
    raw = path.read_bytes()
    assert len(raw) == reference['bytes'] and hashlib.sha256(raw).hexdigest() == reference['sha256']
    assert _retention_stamp(path) == before
    return json.loads(raw)


def test_cache_report_command(argv, *, report, recorder, context):
    """Resolve the same already-selected graph separately; never alter its result."""
    import hashlib, json
    assert argv[1] == 'build' and argv[2] in ('prepare-tests', 'test')
    if any(arg == '--global-cache-dir' or arg.startswith('--global-cache-dir=') for arg in argv[3:]):
        raise ValueError('Set ZIG_GLOBAL_CACHE_DIR in the build environment for this toolchain')
    assert not any(a.startswith('-Dqualification-cache-') for a in argv)
    family = 'prepare' if argv[2] == 'prepare-tests' else 'full'
    if family == 'prepare' and any(arg.startswith('-Dprepare-test-filter=') for arg in argv[3:]):
        groups = [arg.removeprefix('-Dprepare-test-group=') for arg in argv[3:]
                  if arg.startswith('-Dprepare-test-group=')]
        if len(groups) != 1:
            raise ValueError('Explicit prepare-test filters require one prepare-test group')
        # Zig combines filters with OR. Named cases use the logical root;
        # a fixed partition already supplies its own filters in build.zig.
        group = groups[0]
        partitions = {row[1] for row in FULL_DIAGNOSTIC_ROOTS if row[1].startswith(('tools_', 'encoder_'))}
        if group in partitions or group == 'tools_partitioned':
            root = group.partition('_')[0]
            raise ValueError(f'Explicit filters for {group} require -Dprepare-test-group={root}')
    token = hashlib.sha256(json.dumps(context, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    result = list(argv); result[2] = 'qualification-cache-artifacts'
    if context.get('report_dependencies', False) is True:
        result.append('-Dqualification-cache-dependencies=true')
    return result + ['-Dqualification-cache-family=' + family,
                     '-Dqualification-cache-report=' + str(report),
                     '-Dqualification-cache-recorder=' + str(recorder),
                     '-Dqualification-cache-context=' + token]


def _installed_cache_file(path):
    """Read one exact build output or keeper without admitting a mutable alias."""
    import hashlib, os, stat
    path = _retention_path(path)
    before = _retention_stamp(path)
    if not stat.S_ISREG(before['mode']) or before['uid'] != os.geteuid():
        raise ValueError('Installed-cache provenance requires owned regular files')
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    if _retention_stamp(path) != before:
        raise ValueError('Installed-cache file changed while recording')
    return dict(path=str(path), bytes=before['size'], sha256=digest.hexdigest(),
                mode=stat.S_IMODE(before['mode']), stamp=before)


def _installed_cache_history(file_record):
    # Historical raw outputs must never become generic operative source refs.
    return dict(recorded_path=file_record['path'], recorded_bytes=file_record['bytes'],
                recorded_sha256=file_record['sha256'], recorded_mode=file_record['mode'],
                recorded_stamp=file_record['stamp'], present_at_install=True, operative=False)


def _reuse_installed_cache_receipt(output, cache_local, role, raw_path, installed_path, source_fingerprint):
    """Reuse an owned receipt only while every recorded file identity is exact."""
    import hashlib, json, os, stat
    from pathlib import Path
    try:
        before = _retention_stamp(output)
        if not stat.S_ISREG(before['mode']) or before['uid'] != os.geteuid() or before['mode'] & 0o022 or before['size'] > 65536:
            return None
        payload = json.loads(output.read_bytes())
        if not isinstance(payload, dict):
            return None
        if _retention_stamp(output) != before:
            return None
        integrity = payload.pop('receipt_payload_sha256')
        encoded = json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()
        if hashlib.sha256(encoded).hexdigest() != integrity:
            return None
        payload['receipt_payload_sha256'] = integrity
        if (payload['schema'], payload['role'], payload['cache_local'], payload['cache_key'], payload['captured_source_fingerprint']) != (
                'wikidict.installed-cache-provenance.v1', role, str(cache_local), raw_path.parent.name, source_fingerprint):
            return None
        final = payload['historical_compiler_outputs']['final']
        keeper = payload['installed_at_install']
        if not payload['raw_and_installed_same_bytes'] or payload['retirement_authorized'] or payload['raw_output_retention_required']:
            return None
        if (final['recorded_path'], keeper['path']) != (str(raw_path), str(installed_path)):
            return None
        if (final['recorded_bytes'], final['recorded_sha256']) != (keeper['bytes'], keeper['sha256']):
            return None
        if final['recorded_stamp'] != _retention_stamp(raw_path) or keeper['stamp'] != _retention_stamp(installed_path):
            return None
        candidates = [raw_path.parent / (role + suffix) for suffix in ('_zcu.o', '_zcu.obj')]
        present = [path for path in candidates if os.path.lexists(path)]
        pair = payload['historical_compiler_outputs']['paired_object']
        if pair['status'] == 'missing':
            if present:
                return None
        elif pair['status'] == 'recorded':
            recorded = pair['output']
            if len(present) != 1 or str(present[0]) != recorded['recorded_path'] or _retention_stamp(present[0]) != recorded['recorded_stamp']:
                return None
        else:
            return None
        return payload
    except (OSError, ValueError, KeyError, TypeError):
        return None


def record_installed_cache_artifact(output, cache_local, role, raw_path, installed_path, source_fingerprint):
    """Bind the actual Build LazyPath to its installed keeper; never scans or deletes."""
    import json, os, re, tempfile, time
    from pathlib import Path
    output = _retention_path(output)
    cache_local = _retention_path(cache_local)
    raw_path = _retention_path(raw_path)
    installed_path = _retention_path(installed_path)
    if output.is_relative_to(cache_local) or installed_path.is_relative_to(cache_local) or output == installed_path:
        raise ValueError('Install provenance cannot write into a live cache or overwrite its keeper')
    if installed_path.name != raw_path.name:
        raise ValueError('Installed keeper name differs from the emitted artifact')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+', role) or role in ('.', '..'):
        raise ValueError('Invalid installed role name')
    if source_fingerprint and not re.fullmatch(r'[0-9a-f]{64}', source_fingerprint):
        raise ValueError('Invalid captured source fingerprint')
    relative = raw_path.relative_to(cache_local)
    if len(relative.parts) != 3 or relative.parts[0] != 'o' or not re.fullmatch(r'[0-9a-f]{32}', relative.parts[1]):
        raise ValueError('Emitted artifact is outside the selected cache output namespace')
    if raw_path.name not in (role, role + '.exe'):
        raise ValueError('Emitted artifact name differs from the installed role')
    prior = _reuse_installed_cache_receipt(output, cache_local, role, raw_path, installed_path, source_fingerprint)
    if prior is not None:
        return prior
    raw = _installed_cache_file(raw_path)
    installed = _installed_cache_file(installed_path)
    if not raw['bytes'] or not raw['mode'] & 0o111 or not installed['mode'] & 0o111:
        raise ValueError('Installed role is not a nonempty executable')
    if (raw['bytes'], raw['sha256']) != (installed['bytes'], installed['sha256']):
        raise ValueError('Installed keeper differs from the emitted artifact')
    candidates = [raw_path.parent / (role + suffix) for suffix in ('_zcu.o', '_zcu.obj')]
    present = [path for path in candidates if os.path.lexists(path)]
    paired = dict(pair_basis='same emitted cache key and Zig zcu filename', status='missing', recorded_candidates=[str(path) for path in candidates], operative=False)
    object_record = None
    if len(present) == 1:
        object_record = _installed_cache_file(present[0])
        paired = dict(pair_basis='same emitted cache key and Zig zcu filename', status='recorded', output=_installed_cache_history(object_record), operative=False)
    elif len(present) > 1:
        paired['status'] = 'ambiguous'
    for item in (raw, installed, object_record):
        if item is not None and _retention_stamp(Path(item['path'])) != item['stamp']:
            raise ValueError('Installed-cache inputs changed before publication')
    payload = dict(schema='wikidict.installed-cache-provenance.v1', recorded_unix_ns=time.time_ns(), role=role,
        cache_local=str(cache_local), cache_key=relative.parts[1],
        captured_source_fingerprint=source_fingerprint, source_fingerprint_bound=bool(source_fingerprint),
        installed_at_install=installed,
        historical_compiler_outputs=dict(final=_installed_cache_history(raw), paired_object=paired),
        raw_and_installed_same_bytes=True,
        raw_and_installed_same_inode=(raw['stamp']['dev'], raw['stamp']['ino']) == (installed['stamp']['dev'], installed['stamp']['ino']),
        raw_output_retention_required=False, retirement_authorized=False,
        retirement_policy='Separate current-borrower and cache-index-coherent retirement required; no raw path is a consumer dependency.')
    import hashlib
    payload['receipt_payload_sha256'] = hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    output.parent.mkdir(parents=True, exist_ok=True)
    _retention_path(output)
    # One concise current-install record, also for repeated builds into one prefix.
    with tempfile.TemporaryDirectory(dir=output.parent) as staging:
        staged = Path(staging) / 'report.json'
        with staged.open('x') as stream:
            json.dump(payload, stream, indent=2, sort_keys=True); stream.write('\n')
            stream.flush(); os.fsync(stream.fileno())
        os.replace(staged, output)
        if os.name == 'posix':
            directory = os.open(output.parent, os.O_RDONLY | os.O_DIRECTORY)
            try: os.fsync(directory)
            finally: os.close(directory)
    return payload


def validate_installed_cache_provenance(report_reference, installed_reference):
    """Authenticate history and the keeper only, even after raw outputs retire."""
    from pathlib import Path
    report = _retention_json(report_reference)
    if report.get('schema') != 'wikidict.installed-cache-provenance.v1':
        raise ValueError('Unknown installed-cache provenance schema')
    original = report['installed_at_install']
    current = _installed_cache_file(installed_reference['path'])
    for key in ('path', 'bytes', 'sha256'):
        if current[key] != installed_reference[key] or current[key] != original[key]:
            raise ValueError('Installed keeper no longer matches its install receipt')
    for key in ('dev', 'ino', 'uid', 'gid', 'nlink', 'size', 'mtime_ns'):
        if current['stamp'][key] != original['stamp'][key]:
            raise ValueError('Installed keeper identity changed after installation')
    old_mode = original['mode']
    if current['mode'] not in (old_mode, old_mode & ~0o222):
        raise ValueError('Unexpected keeper mode transition')
    if 'mode' in installed_reference and current['mode'] != installed_reference['mode']:
        raise ValueError('Installed role mode differs from its closure')
    return report


def record_test_cache_artifacts(output, cache_local, context, pairs):
    """Build.Run passes actual LazyPath outputs; read metadata, never ELF bytes."""
    import json, os, re, stat
    import tempfile
    from pathlib import Path
    output = _retention_path(output); cache_local = _retention_path(cache_local)
    assert re.fullmatch('[0-9a-f]{64}', context)
    assert pairs and len(pairs) % 2 == 0
    records = []; dependencies = []; unknown = []; extended = False
    for group, raw_path in zip(pairs[::2], pairs[1::2]):
        if group == "dependency_report_v2":
            assert raw_path == "selected" and not extended
            extended = True; continue
        if group == "dependency_graph_unknown":
            assert extended and raw_path in ("run-step", "unrequested-output", "full-run-dependencies", "selected-extra-object")
            unknown.append(raw_path); continue
        assert re.fullmatch('[a-z][a-z0-9_]*', group)
        path = _retention_path(raw_path)
        relative = path.relative_to(cache_local)
        assert len(relative.parts) == 3 and relative.parts[0] == 'o'
        assert group == 'dependency' or relative.parts[2] == 'test'
        assert group != 'dependency' or extended
        assert re.fullmatch('[0-9a-f]{32}', relative.parts[1])
        before = _retention_stamp(path)
        assert stat.S_ISREG(before['mode']) and before['uid'] == os.geteuid()
        row = dict(group=group, path=str(path), stamp=before)
        if group == 'dependency':
            if not any(r['path'] == row['path'] for r in dependencies): dependencies.append(row)
        else: records.append(row)
    assert len({r['group'] for r in records}) == len(records)
    records.sort(key=lambda row: row['group'])
    assert records
    for row in records + dependencies: assert _retention_stamp(Path(row['path'])) == row['stamp']
    payload = dict(schema='wikidict.qualification-test-cache-paths.v1', context=context,
                   cache_local=str(cache_local), artifacts=records)
    if extended:
        payload.update(schema='wikidict.qualification-test-cache-paths.v2', dependencies=dependencies,
            coverage=dict(selected_graph_complete=not unknown, unknown_graph_steps=sorted(set(unknown)),
                          runtime_spawned_artifacts='unknown'))
    # A concurrent reader can open the final name immediately. Publish only a
    # complete report, retaining exclusive-create semantics for competing writers.
    with tempfile.TemporaryDirectory(dir=output.parent) as staging:
        staged = Path(staging) / 'report.json'
        with staged.open('x') as stream:
            json.dump(payload, stream, indent=2, sort_keys=True); stream.write('\n')
            stream.flush(); os.fsync(stream.fileno())
        os.link(staged, output)
    return payload


def validated_test_cache_keys(cache_local, report_records, *, failed_generic_only=False):
    import hashlib, json, re
    from pathlib import Path
    cache_local = _retention_path(cache_local); keys = set(); families = set()
    assert report_records
    for item in report_records:
        context = item['context']; report = _retention_json(item['report'])
        assert context['cache_local'] == str(cache_local)
        token = hashlib.sha256(json.dumps(context, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        assert report['schema'] in ('wikidict.qualification-test-cache-paths.v1', 'wikidict.qualification-test-cache-paths.v2')
        if report['schema'].endswith('.v2'):
            coverage = report['coverage']
            assert coverage['selected_graph_complete'] is True and coverage['unknown_graph_steps'] == []
            if not failed_generic_only:
                assert coverage['runtime_spawned_artifacts'] == 'authenticated-complete', 'Current nested artifact coverage unknown'
        assert report['context'] == token and report['cache_local'] == str(cache_local)
        rows = report['artifacts']; assert isinstance(rows, list)
        assert [r['group'] for r in rows] == context['groups']
        assert len(context['groups']) == len(set(context['groups']))
        for row in rows:
            path = _retention_path(row['path']); relative = path.relative_to(cache_local)
            assert len(relative.parts) == 3 and relative.parts[0] == 'o' and relative.parts[2] == 'test'
            assert re.fullmatch('[0-9a-f]{32}', relative.parts[1])
            assert _retention_stamp(path) == row['stamp']
            keys.add(path.parent)
        if report['schema'].endswith('.v2'):
            for row in report['dependencies']:
                path = _retention_path(row['path']); relative = path.relative_to(cache_local)
                assert row['group'] == 'dependency'
                assert len(relative.parts) == 3 and relative.parts[0] == 'o'
                assert re.fullmatch('[0-9a-f]{32}', relative.parts[1])
                assert _retention_stamp(path) == row['stamp']
                keys.add(path.parent)
        families.add(context['family'])
    assert ('full' in families) if not failed_generic_only else families == {'prepare'}
    return keys


def _retention_path_chunks(paths, *, environment=None):
    """Bound literal fuser arguments against the actual Linux exec budget."""
    import os, struct, sys
    paths = list(paths); assert len(paths) == len(set(paths))
    if not paths: return
    assert sys.platform.startswith('linux'), 'unqualified exec argument limits'
    environment = dict(os.environ if environment is None else environment)
    arg_max = os.sysconf('SC_ARG_MAX'); page_size = os.sysconf('SC_PAGESIZE')
    assert type(arg_max) is int and arg_max > 0
    assert type(page_size) is int and page_size > 0
    # Linux MAX_ARG_STRLEN includes NUL and is 32 pages. Keep half of the
    # current ARG_MAX unused; additionally cap each request at one MiB.
    string_limit = 32 * page_size
    budget = min(arg_max // 2, 1024 * 1024)
    pointer = struct.calcsize('P')
    def string_bytes(value):
        assert isinstance(value, str) and '\0' not in value
        size = len(os.fsencode(value)) + 1
        assert size <= string_limit, 'exec argument string exceeds kernel limit'
        return size
    prefix = ('/usr/bin/fuser', '-I')
    environment_bytes = 0
    for key, value in environment.items():
        assert isinstance(key, str) and key and '=' not in key
        assert isinstance(value, str)
        environment_bytes += string_bytes(key + '=' + value)
    # Count both pointer vectors and their terminating NULLs. Count the
    # executable filename separately too; it need not share argv[0] storage.
    base = (sum(string_bytes(value) for value in prefix) + environment_bytes
            + pointer * (len(prefix) + len(environment) + 2)
            + string_bytes(prefix[0]))
    assert base < budget, 'environment exhausts bounded exec argument budget'
    chunk = []; size = base
    for path in paths:
        assert isinstance(path, str) and os.path.isabs(path) and '\0' not in path
        needed = string_bytes(path) + pointer
        assert base + needed <= budget, 'selected path exceeds exec argument budget'
        if chunk and size + needed > budget:
            yield chunk; chunk = []; size = base
        chunk.append(path); size += needed
    if chunk: yield chunk


def _retention_locks_clear(nodes):
    import os
    from pathlib import Path
    identities = {(os.major(s['dev']), os.minor(s['dev']), s['ino']) for _, s in nodes}
    for name in ('/proc/locks', '/mnt/ogroot/proc/locks'):
        for line in Path(name).read_text().splitlines():
            for field in line.split():
                parts = field.split(':')
                if len(parts) == 3:
                    try: key = (int(parts[0], 16), int(parts[1], 16), int(parts[2]))
                    except ValueError: continue
                    if key in identities: return False
    return True


_RETENTION_GENERATED_PAIRS = frozenset(frozenset(pair) for pair in (
    ('test', 'test_zcu.o'),
    ('dict-reader-integration-test', 'dict-reader-integration-test_zcu.o'),
    ('dict-bundle-integration-test', 'dict-bundle-integration-test_zcu.o'),
    ('dict-storage-integration-test', 'dict-storage-integration-test_zcu.o'),
    ('dict-blob-build', 'dict-blob-build_zcu.o'),
    ('dict-bundle-runtime.o', 'dict-bundle-runtime_zcu.o'),
))


def _retention_zig017_output_key(manifest_name, contents):
    """Exact installed Cache.zig format; no source/object payload is read."""
    import re, struct
    assert re.fullmatch('[0-9a-f]{32}', manifest_name), 'unsupported manifest name'
    assert contents and contents[-1] == 0, 'incomplete manifest'
    chunks = [bytes.fromhex(manifest_name)]
    offset = 0
    while offset + 1 < len(contents):
        assert offset + 41 < len(contents), 'unsupported manifest record'
        flags = contents[offset + 40]
        assert flags >> 2 < 5, 'unsupported manifest prefix'
        end = contents.find(b'\0', offset + 41)
        assert end >= 0, 'unterminated manifest path'
        chunks.append(contents[offset + 24:offset + 40])
        # All extern File fields explicitly have align(1), including ino_t=u64.
        offset = end + 1
    assert offset + 1 == len(contents), 'unsupported manifest termination'
    key = bytes.fromhex('02e9fafee0958155f55a15cb4af40009')
    k0, k1 = struct.unpack('<QQ', key)
    mask = (1 << 64) - 1
    v = [k0 ^ 0x736f6d6570736575, k1 ^ 0x646f72616e646f6d ^ 0xee,
         k0 ^ 0x6c7967656e657261, k1 ^ 0x7465646279746573]
    def rotate(x, n): return ((x << n) | (x >> (64-n))) & mask
    def round_():
        v[0] = (v[0]+v[1]) & mask; v[1] = rotate(v[1],13) ^ v[0]; v[0] = rotate(v[0],32)
        v[2] = (v[2]+v[3]) & mask; v[3] = rotate(v[3],16) ^ v[2]
        v[0] = (v[0]+v[3]) & mask; v[3] = rotate(v[3],21) ^ v[0]
        v[2] = (v[2]+v[1]) & mask; v[1] = rotate(v[1],17) ^ v[2]; v[2] = rotate(v[2],32)
    def block(word):
        v[3] ^= word; round_(); v[0] ^= word
    size = 0
    for chunk in chunks:
        assert len(chunk) == 16
        for word in struct.unpack('<QQ', chunk): block(word)
        size += len(chunk)
    block((size & 255) << 56)
    v[2] ^= 0xee
    for _ in range(3): round_()
    first = v[0] ^ v[1] ^ v[2] ^ v[3]
    v[1] ^= 0xdd
    for _ in range(3): round_()
    second = v[0] ^ v[1] ^ v[2] ^ v[3]
    return struct.pack('<QQ', first, second).hex()


def _retention_manifest_retirement(cache_local, entries, *, compiler, journal,
                                   deadline_monotonic, append, allow_orphan_outputs=False):
    """Hold h inodes; compiler descriptor comes from the authenticated closed caller.

    The native worker source_guard/final_source_guard authenticates cfg.compiler;
    cleanup joins that same hash-bound cfg, independent closure and final result.
    A caller-supplied dictionary alone is not a new compiler-authentication API.
    """
    import contextlib, fcntl, hashlib, os, re, stat, time
    from pathlib import Path
    @contextlib.contextmanager
    def transaction():
        fds = []
        try:
            if not entries:
                yield dict(invalidated=[], manifest_read_bytes=0)
                return
            assert compiler and compiler['bytes'] == 185514480 and compiler['sha256'] == '7c61539af19fa4082c94848f1c2b57b89e76dc6cfd5bd4c57764c3caf8f82272', 'unsupported Zig manifest format'
            targets = {entry.name for entry in entries}
            assert type(allow_orphan_outputs) is bool
            matches = {key: [] for key in targets}; read_bytes = 0
            snapshots = []
            hroot = _retention_path(cache_local / 'h')
            for path in sorted(hroot.iterdir()):
                assert time.monotonic() < deadline_monotonic
                if not re.fullmatch('[0-9a-f]{32}', path.name): continue
                path = _retention_path(path); before = _retention_stamp(path)
                assert stat.S_ISREG(before['mode']) and before['uid'] == os.geteuid() and before['gid'] == os.getegid() and before['nlink'] == 1
                # Bound one metadata record's allocation, never an artifact payload.
                assert before['size'] <= 64*1024*1024, 'manifest metadata exceeds supported memory bound'
                with path.open('rb') as stream:
                    assert {k:getattr(os.fstat(stream.fileno()),'st_'+k) for k in before} == before
                    raw = stream.read(before['size']+1)
                    assert {k:getattr(os.fstat(stream.fileno()),'st_'+k) for k in before} == before
                assert len(raw) == before['size'] and _retention_stamp(path) == before
                read_bytes += len(raw)
                snapshots.append(dict(path=path,stamp=before,sha256=hashlib.sha256(raw).hexdigest()))
                if not raw: continue  # A placeholder is already a cache miss.
                output_key = _retention_zig017_output_key(path.name, raw)
                if output_key in matches:
                    matches[output_key].append(dict(path=path, stamp=before, sha256=hashlib.sha256(raw).hexdigest(), key=output_key))
            orphans = sorted(key for key, rows in matches.items() if not rows)
            if orphans:
                assert allow_orphan_outputs, 'missing manifest mapping'
                # Only generic tests have a reviewed no-production-writer scope.
                assert all({child.name for child in entry.iterdir()} == {'test','test_zcu.o'} for entry in entries)
            rows = [row for key in sorted(matches) for row in matches[key]]
            locked = snapshots if orphans else rows
            if orphans:
                import resource
                soft, _ = resource.getrlimit(resource.RLIMIT_NOFILE)
                opened = len(os.listdir('/proc/self/fd'))
                # Journal/archive/directory operations need at most eight spare FDs.
                assert soft == resource.RLIM_INFINITY or opened + len(locked) + 8 <= soft, 'insufficient manifest lock FD budget'
            # Orphan absence requires every current h inode exclusively stable.
            # The caller also holds the existing test-admission Q interlock.
            for row in locked:
                assert time.monotonic() < deadline_monotonic
                fd = os.open(row['path'], os.O_RDWR | os.O_NOFOLLOW); fds.append(fd)
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                before = row['stamp']
                assert {k:getattr(os.fstat(fd),'st_'+k) for k in before} == before
                assert _retention_stamp(row['path']) == before
                row['fd'] = fd
            if orphans:
                descriptors = {str(row['path']):row['fd'] for row in locked}
                for row in rows: row['fd'] = descriptors[str(row['path'])]
            expected_h = {str(row['path']):row['stamp'] for row in snapshots}
            def unchanged_h():
                current = {str(path) for path in hroot.iterdir() if re.fullmatch('[0-9a-f]{32}',path.name)}
                assert current == set(expected_h), 'manifest membership changed during orphan proof'
                assert all(_retention_stamp(Path(path)) == stamp for path,stamp in expected_h.items()), 'manifest identity changed during orphan proof'
            if orphans:
                unchanged_h()
                append(dict(event='orphan-absence-verified', output_keys=orphans,
                    manifests=[dict(path=str(row['path']),stamp=row['stamp'],sha256=row['sha256']) for row in snapshots]))
            archive = _retention_path(Path(str(journal)+'.manifests'))
            archive.mkdir(mode=0o700)
            for row in rows:
                backup = archive / (row['path'].name+'.'+row['sha256']+'.bin')
                before = row['stamp']; raw = os.pread(row['fd'], before['size']+1, 0)
                assert len(raw) == before['size'] and hashlib.sha256(raw).hexdigest() == row['sha256']
                assert _retention_zig017_output_key(row['path'].name, raw) == row['key']
                assert {k:getattr(os.fstat(row['fd']),'st_'+k) for k in before} == before
                assert _retention_stamp(row['path']) == before
                fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                with os.fdopen(fd, 'wb') as stream:
                    stream.write(raw); stream.flush(); os.fsync(stream.fileno())
                row['backup'] = str(backup)
                append(dict(event='manifest-preserved', path=str(row['path']), output_key=row['key'], stamp=row['stamp'], bytes=row['stamp']['size'], sha256=row['sha256'], backup=str(backup)))
            directory_fd = os.open(archive, os.O_RDONLY | os.O_DIRECTORY)
            try: os.fsync(directory_fd)
            finally: os.close(directory_fd)
            parent_fd = os.open(archive.parent, os.O_RDONLY | os.O_DIRECTORY)
            try: os.fsync(parent_fd)
            finally: os.close(parent_fd)
            for row in rows:
                assert time.monotonic() < deadline_monotonic
                assert _retention_stamp(row['path']) == row['stamp']
                os.ftruncate(row['fd'], 0); os.fsync(row['fd'])
                after = _retention_stamp(row['path'])
                assert (after['dev'],after['ino']) == (row['stamp']['dev'],row['stamp']['ino']) and after['size'] == 0
                row['invalidated_stamp'] = after
                if orphans: expected_h[str(row['path'])] = after
                append(dict(event='manifest-invalidated', path=str(row['path']), output_key=row['key'], stamp=after))
            record = dict(invalidated=[dict(path=str(r['path']), output_key=r['key'], backup=r['backup'], sha256=r['sha256']) for r in rows], manifest_read_bytes=read_bytes)
            if orphans:
                unchanged_h()
                record.update(orphan_output_keys=orphans, absence_manifest_count=len(snapshots),
                              _before_payload_unlink=unchanged_h)
            yield record
            if orphans: unchanged_h()
            for row in rows: assert _retention_stamp(row['path']) == row['invalidated_stamp']
        finally:
            for fd in reversed(fds):
                fcntl.flock(fd, fcntl.LOCK_UN); os.close(fd)
    return transaction()


def retire_obsolete_test_pairs(cache_local, keep, *, journal, deadline_monotonic,
                               open_probe=None, lock_probe=None, generic_only=False, compiler=None):
    """Exact generated-pair retirement; called only after closed proof and fresh pins."""
    import json, os, re, stat, subprocess, time
    from pathlib import Path
    cache_local = _retention_path(cache_local); object_root = _retention_path(cache_local / 'o')
    keep = {_retention_path(p) for p in keep}; journal = _retention_path(journal)
    for p in keep: assert p.parent == object_root and re.fullmatch('[0-9a-f]{32}', p.name)
    def append(event):
        with journal.open('a') as stream:
            json.dump(event, stream, sort_keys=True); stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
    assert type(generic_only) is bool
    allowed_pairs = {frozenset(('test', 'test_zcu.o'))} if generic_only else _RETENTION_GENERATED_PAIRS
    selected = []; nodes = []
    # One flat metadata inventory only. Never recurse into a cache entry.
    for entry in sorted(object_root.iterdir()):
        if entry in keep or not re.fullmatch('[0-9a-f]{32}', entry.name) or entry.is_symlink(): continue
        es = _retention_stamp(entry)
        if not stat.S_ISDIR(es['mode']) or es['uid'] != os.geteuid() or es['gid'] != os.getegid(): continue
        children = sorted(entry.iterdir())
        if frozenset(p.name for p in children) not in allowed_pairs: continue
        stamps = [_retention_stamp(p) for p in children]
        if not all(stat.S_ISREG(s['mode']) and s['uid'] == os.geteuid() and s['gid'] == os.getegid() and s['nlink'] == 1 for s in stamps): continue
        selected.append((entry, es, list(zip(children, stamps))))
        nodes.extend([(entry, es), *zip(children, stamps)])
    lock_probe = lock_probe or _retention_locks_clear
    assert lock_probe(nodes), 'cache entry locked'
    paths = [str(p) for p, _ in nodes]
    probe_environment = dict(os.environ)
    for chunk in _retention_path_chunks(paths, environment=probe_environment):
        assert time.monotonic() < deadline_monotonic
        if open_probe is None:
            observation = subprocess.run(['/usr/bin/fuser', '-I', *chunk], capture_output=True,
                text=True, env=probe_environment, timeout=deadline_monotonic-time.monotonic())
            code, stdout, stderr = observation.returncode, observation.stdout, observation.stderr
        else: code, stdout, stderr = open_probe(chunk)
        assert code == 1 and stdout == '' and stderr == '', 'open-use probe not clear'
    assert lock_probe(nodes), 'cache entry locked after open-use probe'
    for path, stamp in nodes: assert _retention_stamp(path) == stamp, str(path)
    before = os.statvfs(cache_local); allocated = logical = removed = 0
    with _retention_manifest_retirement(cache_local, [p for p, _, _ in selected], compiler=compiler,
            journal=journal, deadline_monotonic=deadline_monotonic, append=append,
            allow_orphan_outputs=generic_only) as invalidation:
        before_payload_unlink = invalidation.pop('_before_payload_unlink', lambda: None)
        append(dict(event='selected', entries=[dict(path=str(p), stamp=s) for p, s in nodes]))
        for entry, stamp, children in selected:
            assert time.monotonic() < deadline_monotonic
            assert _retention_stamp(entry) == stamp
            assert {p.name for p in entry.iterdir()} == {p.name for p, _ in children}
            assert lock_probe([(entry, stamp), *children])
            for path, expected in children:
                before_payload_unlink()
                assert _retention_stamp(path) == expected
                s = path.lstat(); path.unlink(); allocated += s.st_blocks*512; logical += s.st_size; removed += 1
                append(dict(event='unlinked', path=str(path), stamp=expected))
            entry.rmdir()
    after = os.statvfs(cache_local)
    result = dict(status='retired', removed_files=removed, allocated_names_bytes=allocated,
        logical_bytes=logical, shared_available_delta_bytes=after.f_bavail*after.f_frsize-before.f_bavail*before.f_frsize,
        exclusive_gain_bytes=None, manifest_invalidation=invalidation)
    append(dict(event='result', **result)); return result


def generic_raw_test_selection(cfg, raw_configurations, *, invocation_path=None):
    """Bind existing Batch raw consumers to its Q bookkeeping epoch.

    Called by the normal direct-invocation publisher under the existing Q lock;
    planning a future Zig build is not a lease on its previous cache outputs.
    Store this value in that existing invocation record, not a new registry.
    """
    import re
    from pathlib import Path
    assert isinstance(raw_configurations,list) and all(isinstance(v,dict) and set(v)=={'path','bytes','sha256'} for v in raw_configurations)
    q = _retention_path(cfg['qualification_root'])
    if invocation_path is not None:
        own = _retention_path(invocation_path)
        assert own.parent == q and re.fullmatch(r'direct-invocation[A-Za-z0-9._-]*\.json',own.name)
    else: own = None
    entries = {path.name:_retention_stamp(path) for path in q.iterdir()
               if path != own and re.fullmatch(r'(?:configuration|direct-?invocation)[A-Za-z0-9._-]*\.json',path.name)}
    return dict(cache_root=cfg['retained_cache'], ownership_locks=cfg['ownership_locks'],
                configuration_epoch=entries, raw_configurations=list(raw_configurations),
                unresolved=[],invocation_path=str(own) if own is not None else None)


def reconcile_generic_raw_test_consumers(cfg, selection):
    """Fresh generic-test KEEP only, while cleanup owns the shared Q lock.

    Batch supplies all committed direct raw-test consumers; Runtime's ordinary
    tools/installations do not execute these generic test/test_zcu.o families.
    Unknown/changed configuration bookkeeping invalidates this bounded scope.
    """
    from pathlib import Path
    import re
    assert isinstance(selection,dict) and set(selection) == {
        'cache_root','ownership_locks','configuration_epoch','raw_configurations','unresolved','invocation_path'}
    assert selection['unresolved'] == []
    assert selection['cache_root'] == cfg['retained_cache']
    assert selection['ownership_locks'] == cfg['ownership_locks']
    own = selection['invocation_path']
    if own is not None:
        import json
        own = _retention_path(own)
        own_before = _retention_stamp(own)
        invocation = json.loads(own.read_text())
        assert _retention_stamp(own) == own_before
        assert _retention_json(invocation['configuration']) == cfg
        assert invocation['generic_raw_test_selection'] == selection
    expected = selection['configuration_epoch']
    assert isinstance(expected,dict) and isinstance(selection['raw_configurations'],list)
    def unchanged():
        current = generic_raw_test_selection(cfg,selection['raw_configurations'],invocation_path=own)['configuration_epoch']
        assert current == expected, 'Q configuration epoch changed; reconcile direct raw consumers'
        if own is not None: assert _retention_stamp(own) == own_before, 'Invocation selection changed'
    unchanged()
    local = _retention_path(Path(cfg['retained_cache']['path'])/'local')
    keys=set();seen=set()
    for reference in selection['raw_configurations']:
        assert reference['path'] not in seen;seen.add(reference['path'])
        raw_cfg = _retention_json(reference)
        path = _retention_path(reference['path'])
        assert path.parent == _retention_path(cfg['qualification_root']) and path.name in expected
        assert raw_cfg['retained_cache'] == cfg['retained_cache']
        assert raw_cfg['ownership_locks'] == cfg['ownership_locks']
        assert raw_cfg['execution_stage'] == 'focused-diagnostic' and raw_cfg['prepared_root_runtime_collect'] is True
        payload = _retention_json(raw_cfg['prepared_group_reuse'])
        prior_cfg = _retention_json(payload['configuration'])
        prior = _retention_json(payload['result'])
        closed = _retention_json(payload['closure']);release = _retention_json(payload['release'])
        assert closed['configuration'] == payload['configuration'] and closed['result'] == payload['result']
        assert closed['physical_closure'] and closed['source_guard_after'] and closed['locks_free']
        assert release['released'] and release['physical_closure'] == payload['closure']
        assert prior['source_guard_after'] and not prior['focused_preparation_failures']
        assert raw_cfg['private_manifest'] == prior_cfg['private_manifest'] == payload['source_manifest']
        aliases = {group['prepared_group'] for group in raw_cfg['groups']}
        reports = [item for item in prior['cache_preparations'] if item['context']['groups'][0] in aliases]
        assert len(reports) == len(aliases)
        assert {item['context']['groups'][0] for item in reports} == aliases
        for item in reports:
            assert item['context']['groups'] == [item['context']['groups'][0]]
            assert item['context']['configuration'] == payload['configuration']
            assert item['context']['source_manifest'] == payload['source_manifest']
            assert item['command']['status'] == 'exited' and item['command']['returncode'] == 0
        keys.update(validated_test_cache_keys(local,reports,failed_generic_only=True))
    unchanged()
    return dict(cache_root=cfg['retained_cache'],entry_paths=sorted(map(str,keys)),generic_only=True)


def cleanup_closed_test_cache(request, *, reconcile_protected=None):
    """Closed housekeeping preserves qualification outcome; failed scope is opt-in."""
    fds = []
    try:
        from pathlib import Path
        import time, os, stat, fcntl
        result = _retention_json(request['result']); closure = _retention_json(request['closure'])
        release = _retention_json(request['release']); cfg = _retention_json(request['configuration'])
        assert closure['schema'] == 'existing-private-native-independent-closure.v1'
        failed = request.get('allow_reconciled_failure', False)
        assert type(failed) is bool
        assert closure['status'] == ('FOCUSED-FAILED-CLOSED' if failed else 'PASSED-CLOSED')
        assert closure['result'] == request['result']
        assert closure['configuration'] == request['configuration']
        for key in ('physical_closure','source_guard_after','source_custody_released','ps_absence','locks_free','cleanup_complete'):
            assert closure[key] is True
        if failed:
            assert closure['passed'] is False and result['passed'] is False and result['status'] == 'failed'
            assert result['all_selected_executed'] is True and result['all_selected_accounted'] is True
        else:
            for key in ('passed','full_current_executed','full_current_passed'): assert closure[key] is True
        assert release['schema'] == 'native-resource-release.v1' and release['released'] is True
        assert release['physical_closure'] == request['closure'] and release['cache_custody_released'] is True
        assert result['source_guard_after'] is True
        if not failed: assert result['passed'] is True and result['full_native_pass'] is True
        # This is the shared qualification admission interlock, not Zig's h-lock.
        shared = str(_retention_path(cfg['qualification_root'])/'ownership.lock')
        locks = cfg['ownership_locks']; assert locks
        assert len({row['path'] for row in locks}) == len(locks)
        assert sum(row['path'] == shared for row in locks) == 1
        for row in cfg['ownership_locks']:
            fd=os.open(_retention_path(row['path']), os.O_RDWR|os.O_NOFOLLOW);fds.append(fd)
            s=os.fstat(fd);assert (s.st_dev,s.st_ino)==(row['dev'],row['ino'])
            fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        root=_retention_path(cfg['retained_cache']['path']);s=root.stat();identity=cfg['retained_cache']
        assert (s.st_dev,s.st_ino,s.st_uid,stat.S_IMODE(s.st_mode))==tuple(identity[k] for k in ('device','inode','uid','mode'))
        retention = result['test_cache_retention']; assert not retention['deferred']
        reports = retention['reports']; cache_local = Path(cfg['retained_cache']['path'])/'local'
        expected_groups = sorted(row[1] for row in FULL_DIAGNOSTIC_ROOTS)
        if not failed:
            assert any(r['context']['family'] == 'full' and r['context']['groups'] in (expected_groups, sorted(row[1] for row in LEGACY_FULL_DIAGNOSTIC_ROOTS)) for r in reports)
        else:
            # A source-reviewed caller opts in only for selected runtime paths
            # that cannot dynamically compile generic tests. Nested production
            # families remain untouched even if their coverage is unknown.
            from collections import Counter
            import json
            builds = [p['command'] for p in result['phases']
                      if len(p['command']['argv']) > 1 and p['command']['argv'][1] == 'build']
            assert builds and all(len(c['argv']) > 2 and c['argv'][2] == 'prepare-tests' and c['status'] == 'exited' and c['returncode'] == 0 for c in builds)
            assert all(r['context']['family'] == 'prepare' and r['command']['status'] == 'exited' and r['command']['returncode'] == 0 for r in reports)
            assert Counter(json.dumps(c['argv']) for c in builds) == Counter(json.dumps(r['context']['argv']) for r in reports)
            assert all(count == 1 for count in Counter(json.dumps(c['argv']) for c in builds).values())
        for item in reports:
            assert item['context']['configuration'] == request['configuration']
            assert item['context']['source_manifest'] == cfg['private_manifest']
        keys = validated_test_cache_keys(cache_local, reports, failed_generic_only=failed)
        # Existing closure owner supplies fresh authoritative diagnostic/live pins.
        # Omitting that obligation never silently means an empty keep set.
        assert callable(reconcile_protected), 'Fresh protected-pin reconciliation required'
        protected = reconcile_protected(cfg)  # Called only under the shared qualification interlock.
        assert protected['cache_root'] == cfg['retained_cache']
        assert not protected.get('generic_only',False) or failed, 'Generic raw KEEP cannot authorize broad retirement'
        keys.update(Path(p) for p in protected['entry_paths'])
        return retire_obsolete_test_pairs(cache_local, keys, journal=request['journal'],
            deadline_monotonic=request['deadline_monotonic'], generic_only=failed, compiler=cfg.get('compiler'))
    except Exception as error:
        return dict(status='cleanup-deferred', reason=repr(error), qualification_result_unchanged=True)

    finally:
        for fd in fds:
            import os, fcntl
            fcntl.flock(fd,fcntl.LOCK_UN);os.close(fd)


def admission_refusal_paths(directory):
    """Continue the numbered receipt sequence without rereading it on each poll."""
    from itertools import count

    prefix = 'admission-refusal'
    last = 0
    for path in directory.glob(prefix + '*.json'):
        digits = path.stem[len(prefix):]
        if digits.isascii() and digits.isdecimal():
            last = max(last, int(digits))
    for number in count(last + 1):
        yield directory / f'{prefix}{number:04d}.json'


def qualification_file_reference(path, *, counters=None):
    """Hash one stable file and count the bytes read without retaining its contents."""
    import hashlib
    import os
    from pathlib import Path

    def identity(stamp):
        return (stamp.st_dev, stamp.st_ino, stamp.st_mode, stamp.st_size,
                stamp.st_mtime_ns, stamp.st_ctime_ns)

    path = Path(path)
    expected = identity(path.stat())
    digest = hashlib.sha256()
    size = 0
    buffer = memoryview(bytearray(min(256 * 1024, max(4096, expected[3]))))
    with path.open('rb', buffering=0) as stream:
        assert identity(os.fstat(stream.fileno())) == expected, str(path)
        if counters is not None:
            counters['files'] += 1
        while count := stream.readinto(buffer):
            size += count
            digest.update(buffer[:count])
            if counters is not None:
                counters['bytes'] += count
        assert identity(os.fstat(stream.fileno())) == expected, str(path)
    assert identity(path.stat()) == expected, str(path)
    return {'path': str(path), 'bytes': size, 'sha256': digest.hexdigest()}


def close_passed_native_qualification(request, *, reconcile_protected=None):
    """Verify and close the existing full-pass route, then run optional housekeeping.

    The existing closure owner calls this in-process. Failed, scoped and unknown
    outcomes keep their own closure path and cannot enter test-cache retirement.
    """
    import pathlib, json, hashlib, stat, os, fcntl, subprocess, time
    cfg = _retention_json(request['configuration'])
    Q = _retention_path(cfg['qualification_root'])
    O = _retention_path(request['run_directory'])
    D = _retention_path(cfg['retained_source']['path'])
    closure_path = _retention_path(request['closure_path'])
    release_path = _retention_path(request['release_path'])
    assert O.parent == Q
    assert closure_path.parent == release_path.parent == Q
    assert closure_path != release_path and not closure_path.exists() and not release_path.exists()
    assert type(request['expected_abi_version']) is int and request['expected_abi_version'] > 0
    assert type(cfg.get('retain_test_cache', False)) is bool
    collect_unrun = cfg.get('collect_unrun_full_roots', False)
    assert type(collect_unrun) is bool
    source_identity = D.stat()
    assert (source_identity.st_dev, source_identity.st_ino, source_identity.st_uid,
            stat.S_IMODE(source_identity.st_mode)) == tuple(
                cfg['retained_source'][key] for key in ('device', 'inode', 'uid', 'mode'))
    ref = qualification_file_reference
    def load(n):return json.loads((O/n).read_bytes())
    def identity(pid,base):
     try:s=(pathlib.Path(base)/str(pid)/'stat').read_text().rsplit(')',1)[1].split();return dict(pid=pid,birth=int(s[19]),group=int(s[2]),session=int(s[3]))
     except FileNotFoundError:return None
    outer=load('dispatch/outer-start.json');end=load('dispatch/outer-result.json');wd=load('watchdog.json');owner=load('dispatch/owner-result.json');result=load('commands/result.json');direct=load('dispatch/start.json');assert direct['configuration']==request['configuration']
    assert direct['runtime_inputs']['qualification_tool'] == ref(pathlib.Path(__file__))
    assert direct['maintained_qualification_execution']['qualification_tool'] == direct['runtime_inputs']['qualification_tool']
    assert cfg['execution_stage'] in ('full','tail');assert end['reaped']and end['exit_code']==0 and owner['returncode']==0 and owner['error']is None
    assert wd['runtime_started']and not wd['admission_refused'];assert wd['cleanup_complete']and wd['child_exit_status']==0 and wd['guardian_exit_status']==0
    ids=[dict(pid=x['pid'],birth=x['starttime'],group=x['process_group'],session=x['session'])for x in [outer['owner'],outer['outer']]]+[dict(pid=wd[k+'_pid'],birth=wd[k+'_start_time_ticks'],group=wd[k+'_pid'],session=wd[k+'_pid'])for k in ['child','guardian']]
    obs={base:{str(x['pid']):identity(x['pid'],base)for x in ids}for base in ['/proc','/mnt/ogroot/proc']};absence={base:{str(x['pid']):obs[base][str(x['pid'])]is None or obs[base][str(x['pid'])]['birth']!=x['birth']for x in ids}for base in obs};assert all(all(v.values())for v in absence.values())
    owned_pids={x['pid']for x in ids};excluded_sessions=sorted({x['session']for x in ids if x['session']not in owned_pids});scopes={x[k]for x in ids for k in ('group','session')if x[k]in owned_pids};ps=subprocess.check_output(['ps','-eo','pid=,pgid=,sid='],text=True);remaining=[s for s in ps.splitlines()if any(int(v)in scopes for v in s.split()[1:])];assert not remaining,remaining
    lock=Q/'ownership.lock'
    lock_rows=[row for row in cfg['ownership_locks']if row['path']==str(lock)];assert len(cfg['ownership_locks'])==len(lock_rows)==1
    fd=os.open(lock,os.O_RDWR|os.O_NOFOLLOW)
    try:
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);st=os.fstat(fd);assert(st.st_dev,st.st_ino)==(lock_rows[0]['dev'],lock_rows[0]['ino'])
        manifest=cfg['private_manifest'];assert ref(manifest['path'])==manifest;inv=json.loads(pathlib.Path(manifest['path']).read_bytes());actual={str(p.relative_to(D))for p in D.rglob('*')if p.is_file()or p.is_symlink()};assert actual==set(inv)
        for name,v in inv.items():
         p=D/name;s=p.lstat();a=ref(p);assert stat.S_ISREG(s.st_mode)and s.st_nlink==1 and stat.S_IMODE(s.st_mode)==v['mode']and all(a[k]==v[k]for k in ['bytes','sha256']),name
        authenticated=[]
        for key,v in direct['runtime_inputs'].items():
         if isinstance(v,dict)and all(k in v for k in ['path','bytes','sha256']):assert ref(v['path'])==v,key;authenticated.append(key)
        for name,v in cfg['canonical_runtime_inputs'].items():assert ref(v['reference']['path'])==v['reference']and stat.S_IMODE(pathlib.Path(v['reference']['path']).stat().st_mode)==v['mode'],name
        inherited=None;execution_configuration=request['configuration'];phases=result['phases']
        if cfg['execution_stage']=='tail':
            import runpy, ast, re
            reuse=cfg['tail_reuse'];assert 'accounting_assessment'in reuse
            def authenticate(v):assert ref(v['path'])==v;return pathlib.Path(v['path'])
            def read(v):return json.loads(authenticate(v).read_text())
            helper=runpy.run_path(str(authenticate(cfg['helper'])))
            expectation=read(cfg['expectation']);inventory=runpy.run_path(str(authenticate(expectation['inventory_source'])))
            marker_text=authenticate(direct['runtime_inputs']['reader_markers']).read_text()
            marker_node=next(n for n in ast.parse(marker_text).body if isinstance(n,ast.FunctionDef)and n.name=='markers')
            marker_source=ast.get_source_segment(marker_text,marker_node)+'\n'
            assert marker_source.count('checks=47')==3 and marker_source.count('reader_checks=47')==1
            marker_source=marker_source.replace('checks=47','checks=50').replace('reader_checks=47','reader_checks=50')
            scope=dict(json=json,re=re,Path=pathlib.Path);exec(compile(marker_source,'<reader-marker-contract>','exec'),scope)
            prior_cfg,inherited,_,_=reconcile_accounting_tail(cfg=cfg,expect=expectation,reuse=reuse,prior_cfg=read(reuse['configuration']),prior=read(reuse['result']),closed=read(reuse['closure']),released=read(reuse['release']),read=read,auth=authenticate,ref=ref,helper=helper,inventory=inventory,markers=scope['markers'],source_files={n:dict(path=str(D/n),bytes=z['bytes'],sha256=z['sha256'])for n,z in inv.items()})
            assert result['accounting_reconciliation']==inherited['accounting_reconciliation']
            for key in ('native_inventory','grouped_inventory','required_test_counts','reader_markers','installed','metadata_python','bundle_pipeline_reuse'):
                assert result[key]==inherited[key],key
            assert result['selected_current_count']==0 and result['full_native_current_execution']is False
            assert result['focused_current_execution']is False and result['bundle_pipeline_current_execution']is False
            assert result['focused_tests']==[] and [p['name']for p in phases]==['bundle','cli-smoke']
            phases=inherited['phases']+phases;execution_configuration=reuse['configuration']
        focus=(inherited or result)['focused_tests'];assert len(focus)==cfg['focused_expected'] and all(x['passed']for x in focus)
        for x in focus:
         for key in ['stdout','stderr','binary']:assert ref(x[key]['path'])==x[key]
         assert x['command']['status']=='exited'and x['command']['returncode']==0
        assert result['passed']and result['source_guard_after']is True and result['status']=='passed'and all(result[k]for k in ['focused_qualified','cli_ffi_install_pass','full_native_pass','bundle_pipeline_pass','bundle_pass','cli_smoke_pass'])
        mandatory = {}
        for name in ('cli-ffi-install', 'full-native-suite', 'bundle', 'cli-smoke'):
            rows = [phase for phase in phases if phase['name'] == name]
            assert len(rows) == 1, name
            mandatory[name] = rows[0]
        install_root = _retention_path(cfg['install_root'])
        assert install_root == (pathlib.Path(cfg['tail_reuse']['result']['path']).parent.parent if inherited else O)/'install'
        assert set(result['installed']) == {'bin/wikidict', 'lib/libdictffi.so', 'include/dict/dict.h'}
        for name, installed in result['installed'].items():
            assert _retention_path(installed['path']) == install_root/name
        install_argv = mandatory['cli-ffi-install']['command']['argv']
        assert install_argv[:4] == [cfg['compiler']['path'], 'build', 'cli', 'ffi']
        assert install_argv.count('--prefix') == 1
        prefix_at = install_argv.index('--prefix')
        assert prefix_at + 1 < len(install_argv) and install_argv[prefix_at + 1] == str(install_root)
        assert mandatory['cli-smoke']['command']['argv'] == [result['installed']['bin/wikidict']['path'], '--help']
        for phase in phases:
         assert phase['command']['status']=='exited'and phase['command']['returncode']==0
         for k in ['stdout','stderr']:assert ref(phase[k]['path'])==phase[k]
         argv=phase['command']['argv'];assert '--global-cache-dir'not in argv
         if phase['name'].startswith('focused-prepare-')or phase['name']in ['cli-ffi-install','full-native-suite','bundle-pipeline','bundle']:
          assert [v for v in argv if v.startswith('-Dcaptured-source-fingerprint=')]==['-Dcaptured-source-fingerprint='+manifest['sha256']]
        import runpy,re
        assert ref(cfg['helper']['path'])==cfg['helper'];h=runpy.run_path(cfg['helper']['path']);assert ref(cfg['expectation']['path'])==cfg['expectation'];expect=json.loads(pathlib.Path(cfg['expectation']['path']).read_text());assert ref(expect['inventory_source']['path'])==expect['inventory_source'];iv=runpy.run_path(expect['inventory_source']['path'])
        full=next(x for x in phases if x['name']=='full-native-suite');so=pathlib.Path(full['stdout']['path']).read_text(errors='replace');se=pathlib.Path(full['stderr']['path']).read_text(errors='replace');native=h['classify'](so,se,standalone=False);assert native['passed']and native['status_count']==cfg['full_native_expected'] and len(native['groups'])==cfg['groups_expected'] and all(not any(x[1:])for x in native['groups'])
        grouped=iv['validate_grouped'](h,expect['expected'],so,se);assert grouped['passed']and grouped['exact_grouped_names_and_multiplicity']
        text=h['ANSI'].sub('',so+'\n'+se);names=[n for status,n in h['STATUS'].findall(text)if status=='ok'];actual={n:sum(v.endswith('.test.'+n)for v in names)for n in expect['required_test_counts']};assert actual==expect['required_test_counts']and sum(actual.values())==sum(expect['required_test_counts'].values())
        marks=result['reader_markers'];assert marks['reader_checks']==cfg['reader_expected_checks'];assert ref(marks['child_report']['path'])==marks['child_report'];lines=text.splitlines()
        for m in marks['marker_lines']:assert lines[m['line']-1]==m['text']
        for marker in ['CLI_SWATCH_PTY_PASS','CLI_ANCHORED_PARENT_PTY_PASS','STORAGE_INTEGRATION_PASS','READER_INTEGRATION_PASS checks=50:']:assert marker in text
        for n,v in result['installed'].items():assert ref(v['path'])==v
        header=pathlib.Path(result['installed']['include/dict/dict.h']['path']).read_text();assert ('#define DICT_ABI_VERSION '+str(request['expected_abi_version'])+'u\n')in header;assert result['installed']['include/dict/dict.h']['sha256']==inv[qualification_source_key(inv, 'src/ffi/dict.h')]['sha256']
        reuse=result['bundle_pipeline_reuse'];assert cfg['reuse_full_bundle_pipeline']is True and reuse['authority']=='successful-normal-full-root' and reuse['executions']==1 and reuse['summary']==[23,0,0,0,0] and reuse['standalone_command_executed']is False and reuse['emitted_binary_descriptor']is None
        assert reuse['source_manifest']==manifest and reuse['full_phase']==full and reuse['full_configuration']==execution_configuration and reuse['build_graph']==expect['expected']['build_graph']
        assert not any(x['name']=='bundle-pipeline'for x in phases);assert reuse['satisfies']==['full-native-suite','bundle-pipeline-tail']
        bundle=next(x for x in phases if x['name']=='bundle');bt=pathlib.Path(bundle['stdout']['path']).read_text()+pathlib.Path(bundle['stderr']['path']).read_text();assert len(re.findall(r'BUNDLE_INTEGRATION_PASS checks='+str(cfg['bundle_expected_checks'])+r':',bt))==1
        assert result['metadata_python']['passed'] is True
        closure=dict(schema='existing-private-native-independent-closure.v1',status='PASSED-CLOSED',passed=True,physical_closure=True,source_guard_after=True,source_member_count=len(inv),source_custody_released=True,recorded_identities=ids,matching_identity_absence=absence,other_namespace_observations=obs,ps_absence=True,exclusive_scope_residuals=remaining,additional_session_exclusions_from_start_new_session_contract=excluded_sessions,raw_observed_identities=ids,locks=[dict(path=str(lock),dev=st.st_dev,ino=st.st_ino)],locks_free=True,cleanup_complete=True,configuration=request['configuration'],watchdog=ref(O/'watchdog.json'),outer_result=ref(O/'dispatch/outer-result.json'),owner_result=ref(O/'dispatch/owner-result.json'),result=ref(O/'commands/result.json'),maintained_tool=direct['maintained_qualification_execution']['qualification_tool'],authenticated_runtime_inputs=authenticated,expected_source_inventory=manifest,expected_rows_changed=[],missing_paths=[],added_files=[],focused_current_executed=len(focus),focused_current_passed=len(focus),full_current_executed=True,full_current_passed=True,full_current_occurrences_passed=cfg['full_native_expected'],full_current_occurrences_failed=0,full_current_completed_roots=cfg['groups_expected'],required_named_occurrences=sum(expect['required_test_counts'].values()),exact_grouped_names_and_multiplicity=True,normal_metadata_pass=result['metadata_python']['passed'],normal_metadata_executed=result['metadata_python']['executed'],install_current_passed=True,bundle_pipeline_passed=True,bundle_passed=True,cli_smoke_passed=True,Reader_checks_passed=cfg['reader_expected_checks'],PTY_checks_passed=marks['child_summary'],standalone_PTY_markers_passed=marks['standalone_pty_counts'],Reader_report=marks['child_report'],elapsed_seconds=wd['elapsed_seconds'],peak_pss_bytes=wd['peak_pss_bytes'],installed=result['installed'],captured_source_fingerprint=manifest['sha256'],actual_fingerprint_build_phases=[x['name']for x in phases if x['name'].startswith('focused-prepare-')or x['name']in ['cli-ffi-install','full-native-suite','bundle-pipeline','bundle']],canonical_acceptance=False,apps_acceptance=False,producer_reader_semantic_acceptance=False,observed_unix=time.time())
        closure.update(bundle_pipeline_reuse=reuse,bundle_pipeline_obligations_satisfied_by_one_actual_full_execution=True,emitted_pipeline_binary_descriptor_not_claimed=True,private_qualified_helper_adopted=True,collect_unrun_full_roots_selected=collect_unrun,current_focused_setup_checks=len(focus),repeat_setup_scope_explicitly_selected=True)
        if inherited is not None:
            closure.update(execution_stage='tail',accounting_reconciliation=result['accounting_reconciliation'],inherited_qualification=cfg['tail_reuse'],focused_current_executed=0,focused_current_passed=0,focused_inherited_count=len(focus),full_current_executed=False,full_current_passed=False,full_current_occurrences_passed=0,full_current_completed_roots=0,full_inherited_pass=True,full_inherited_occurrences=cfg['full_native_expected'],full_inherited_roots=cfg['groups_expected'],install_current_passed=False,install_inherited_pass=True,bundle_pipeline_inherited_pass=True,actual_current_phases=[p['name']for p in result['phases']],original_full_configuration=execution_configuration)
    finally:
        os.close(fd)
    def publish(path, value):
        with path.open('x') as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
        return ref(path)
    closure_ref = publish(closure_path, closure)
    release = dict(schema='native-resource-release.v1', released=True,
        own_memory_bytes=cfg['admission_derivation']['own_bytes'],
        execution_memory_cap_bytes=cfg['profile']['memory_limit_bytes'],
        source_custody_released=True, cache_custody_released=True,
        physical_closure=closure_ref, recorded_identities=ids, observed_unix=time.time())
    release_ref = publish(release_path, release)
    housekeeping = dict(status='not-selected')
    housekeeping_ref = None
    if cfg.get('retain_test_cache', False):
        housekeeping_path = Q/('test-cache-retention-'+O.name+'.json')
        journal_path = Q/('test-cache-retirement-'+O.name+'.jsonl')
        try:
            assert not housekeeping_path.exists() and not journal_path.exists()
            seconds = request['cleanup_seconds']
            assert type(seconds) in (int, float) and 0 < seconds <= 300
            housekeeping = cleanup_closed_test_cache(dict(
                result=ref(O/'commands/result.json'), closure=closure_ref,
                release=release_ref, configuration=request['configuration'],
                journal=str(journal_path),
                deadline_monotonic=time.monotonic()+seconds),
                reconcile_protected=reconcile_protected)
        except Exception as error:
            housekeeping = dict(status='cleanup-deferred', reason=repr(error),
                qualification_result_unchanged=True)
        try:
            housekeeping_ref = publish(housekeeping_path, dict(configuration=request['configuration'],
                closure=closure_ref, release=release_ref, outcome=housekeeping,
                journal=ref(journal_path) if journal_path.exists() else None))
        except Exception as error:
            housekeeping = dict(status='cleanup-deferred', reason=repr(error),
                prior_outcome=housekeeping, qualification_result_unchanged=True)
    return dict(closure=closure_ref, release=release_ref, test_cache_retention=housekeeping,
        test_cache_retention_receipt=housekeeping_ref)


if __name__ == '__main__':
    import sys
    if len(sys.argv)>1 and sys.argv[1]=='record-installed-cache':
        # Optional install provenance must not change an existing artifact result.
        try:
            from pathlib import Path
            if len(sys.argv) != 8: raise ValueError('Expected prefix cache role emitted installed fingerprint')
            record_installed_cache_artifact(Path(sys.argv[2])/'share/wikidict/writer-cache-output.json', *sys.argv[3:])
        except Exception as error: print('INSTALLED_CACHE_REPORT_DEFERRED '+repr(error),file=sys.stderr)
        raise SystemExit(0)
    if len(sys.argv)>1 and sys.argv[1]=='record-test-cache':
        # Reporting is optional housekeeping, never a qualification exit status.
        try: record_test_cache_artifacts(sys.argv[2],sys.argv[3],sys.argv[4],sys.argv[5:])
        except Exception as error: print('TEST_CACHE_REPORT_DEFERRED '+repr(error),file=sys.stderr)
        raise SystemExit(0)
    assert len(sys.argv) == 3 and sys.argv[1] in ('owner', 'worker'), 'Expected owner|worker and existing dispatch directory'
    role = sys.argv.pop(1)
    if role == 'owner':
        from pathlib import Path
        import os,json,hashlib,subprocess,time,stat,ast,runpy,sys,fcntl
        D=Path(sys.argv[1]);N=D.parent.parent;Q=N
        ref = qualification_file_reference
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
         required_canonical_inputs=canonical_runtime_input_keys(cfg['canonical_runtime_inputs'])
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
        assert os.getpid()==os.getpgrp()==os.getsid(0);sys.path.insert(0,str(auth(start['runtime_inputs']['limits_api']).parent));import build_resource_limits as limits
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
        refusal_paths=admission_refusal_paths(D)
        def record_refusal(reason,sample):
         print(json.dumps(write(next(refusal_paths),dict(reason=reason,sample=sample,runtime_started=False))),flush=True)
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
        _hash_reads = dict(bytes=0, files=0)
        source_guard_metrics = []
        def ref(p):
            return qualification_file_reference(p, counters=_hash_reads)
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
         # Every authenticated source member joins this forced read, including
         # startup-only pins. This interval excludes the following manifest check.
         began=time.monotonic();before=dict(_hash_reads);passed=False
         try:
          for path, size, digest in list(_expected_inputs):
           auth(dict(path=path, bytes=size, sha256=digest), force=True)
          passed=True
         finally:
          source_guard_metrics.append(dict(kind='final_forced_hashes',passed=passed,
           elapsed_seconds=time.monotonic()-began,
           content_bytes_read=_hash_reads['bytes']-before['bytes'],
           content_files_read=_hash_reads['files']-before['files']))
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
         required_canonical_inputs=canonical_runtime_input_keys(cfg['canonical_runtime_inputs'])
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
         began=time.monotonic();before=dict(_hash_reads);manifest_passed=False
         try:
          assert private_helper['private_manifest'](private_model,private,expected_changes=set(),authenticate_expected=auth)==private_manifest
          manifest_passed=True
         finally:
          source_guard_metrics.append(dict(kind='private_manifest',passed=manifest_passed,
           elapsed_seconds=time.monotonic()-began,
           content_bytes_read=_hash_reads['bytes']-before['bytes'],
           content_files_read=_hash_reads['files']-before['files']))
         return True
        guard=source_guard
        def prepare_tests_argv(args,cache,prefix,native_build_argv):
         return qualification_build_argv(args,cache,native_build_argv,family='prepare',prefix=prefix,prepare_test_error_tracing=group_binding['prepare_test_error_tracing'])
        import pathlib,re
        from types import SimpleNamespace
        sys.path.insert(0,str(auth(start['runtime_inputs']['limits_api']).parent));import build_resource_limits as limits
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
        result['source_guard_metrics']=source_guard_metrics
        def save():w['write'](out/'result.json',result)
        def execute_outcome(label,argv):
         guard();dynamic['validate'](ds);command=execute_with_failure_output(w['execute'],out,label,argv,private);so=(out/(label+'.stdout')).read_text(errors='replace');se=(out/(label+'.stderr')).read_text(errors='replace');result['phases'].append(dict(name=label,command=command,stdout=ref(out/(label+'.stdout')),stderr=ref(out/(label+'.stderr'))));save();guard();return command,so,se
        def execute(label,argv):
         command,so,se=execute_outcome(label,argv);assert command['status']=='exited' and command['returncode']==0,(label,command);return so,se
        if cfg.get('retain_test_cache',False) is True:
         result['test_cache_retention']=dict(reports=[],deferred=[])
         guarded_execute_outcome=execute_outcome
         def retention_execute_outcome(label,argv):
          command,so,se=guarded_execute_outcome(label,argv)
          if len(argv)>2 and argv[1]=='build' and argv[2] in ('prepare-tests','test') and command['status']=='exited' and command['returncode']==0:
           guard()
           try:
            family='prepare' if argv[2]=='prepare-tests' else 'full'
            selected=[a.split('=',1)[1] for a in argv if a.startswith('-Dprepare-test-group=')]
            filters=[a for a in argv if a.startswith('-Dprepare-test-filter=')]
            assert len(selected)<=1
            groups=(sorted(row[1] for row in full_diagnostic_root_layout(expect['expected'])) if family=='full' else prepared_cache_groups(selected[0] if selected else None,filters))
            report=out/('test-cache-'+label+'.json')
            context=dict(configuration=start['configuration'],source_manifest=cfg['private_manifest'],family=family,groups=groups,cache_local=str(cache/'local'),argv=argv)
            export_argv=test_cache_report_command(argv,report=report,recorder=__file__,context=context)
            export_label='test-cache-export-'+label
            export=w['execute'](out,export_label,export_argv,private)
            if export['status']!='exited' or export['returncode']!=0: raise ValueError(('cache report command',export))
            item=dict(context=context,report=ref(report),command=export)
            # Same validation as post-closure, without requiring a full report yet.
            record=read(item['report']);token=hashlib.sha256(json.dumps(context,sort_keys=True,separators=(',',':')).encode()).hexdigest()
            assert record['context']==token and record['cache_local']==context['cache_local']
            assert [r['group'] for r in record['artifacts']]==groups
            for row in record['artifacts']:assert _retention_stamp(Path(row['path']))==row['stamp']
            result['test_cache_retention']['reports'].append(item)
           except Exception as error:result['test_cache_retention']['deferred'].append(dict(phase=label,reason=repr(error)))
           guard();save()
          return command,so,se
         execute_outcome=retention_execute_outcome
        save()
        try:
         assert cfg['execution_stage'] in ('full','tail','focused-diagnostic')
         assert type(cfg.get('collect_unrun_full_roots',False))is bool
         assert type(cfg.get('reuse_full_bundle_pipeline',False))is bool
         if cfg['execution_stage']=='tail':
          reuse=cfg['tail_reuse'];prior_cfg=read(reuse['configuration']);prior=read(reuse['result']);closed=read(reuse['closure']);released=read(reuse['release'])
          if 'accounting_assessment'in reuse:
           prior_cfg,prior,closed,released=reconcile_accounting_tail(cfg=cfg,expect=expect,reuse=reuse,prior_cfg=prior_cfg,prior=prior,closed=closed,released=released,read=read,auth=auth,ref=ref,helper=w,inventory=inv,markers=markers,source_files=private_model['files'])
           result['accounting_reconciliation']=prior['accounting_reconciliation']
          assert bound_captured_source_fingerprint(prior_cfg,auth)==captured_fingerprint
          assert released['closure']==reuse['closure'] and released['cleanup_proven'] and released['source_guard'] and released['locks_free']
          assert closed['result']==reuse['result'] and closed['configuration']==reuse['configuration'] and closed['source_guard'] and closed['cleanup_proven'] and closed['locks_free']
          assert closed['full_native_pass'] and closed['bundle_pipeline_pass'] and closed['full_actual_passed_tests']==cfg['full_native_expected'] and closed['required_test_occurrences']==sum(expect['required_test_counts'].values())
          for key in ('private_manifest','private_source_binding','retained_source','retained_cache','compiler','runtime_python','python_bin','canonical_runtime_inputs','runtime_helpers','dynamic_helper','dynamic_state','helper','expectation','focused_groups','groups','focused_expected','focused_distinct_names','saved_expected','full_native_expected','groups_expected','reader_expected_checks','bundle_expected_checks','metadata_python_reuse','metadata_python_expected','install_root'):
           assert cfg[key]==prior_cfg[key],key
          assert prior_cfg['execution_stage']=='full'
          assert cfg.get('reuse_full_bundle_pipeline',False)==prior_cfg.get('reuse_full_bundle_pipeline',False)
          assert cfg.get('filtered_tools_prerequisite',False)==prior_cfg.get('filtered_tools_prerequisite',False)
          assert not cfg.get('filtered_tools_only',False) and not prior_cfg.get('filtered_tools_only',False)
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
          filtered_tools=cfg.get('filtered_tools_prerequisite',False)
          if filtered_tools:
           assert execution_plan=='prepare-on-first-use.v1'
           tools_group=next(group for group in cfg['groups']if group['id']=='tools')
           expected_phases.insert(expected_phases.index('focused-prepare-tools'),'focused-prepare-selected-tools')
           selected_prepare=prior['filtered_tools_preparation']
           assert selected_prepare['selected_passed'] is True and selected_prepare['normal_preparation_passed'] is True
           assert selected_prepare['filters']==selected_prepare['compiled_expected_occurrences']==tools_group['test_names']
           assert selected_prepare['full_suite_credit'] is False
           auth(selected_prepare['binary']);auth(selected_prepare['normal_binary'])
           assert selected_prepare['binary']['path']!=selected_prepare['normal_binary']['path']
           selected_phases=[row for row in prior['phases']if row['name']=='focused-prepare-selected-tools']
           normal_phases=[row for row in prior['phases']if row['name']=='focused-prepare-tools']
           assert len(selected_phases)==len(normal_phases)==1
           selected_phase,normal_phase=selected_phases[0],normal_phases[0]
           assert selected_prepare['phase']==selected_phase
           assert len(prior['compiles'])==1
           normal_compile=prior['compiles'][0]
           assert normal_compile['passed'] is True and normal_compile['binaries']['tools']==selected_prepare['normal_binary']
           assert normal_phase in normal_compile['commands'] and selected_phase not in normal_compile['commands']
          expected_phases+=['cli-ffi-install','full-native-suite']+([]if prior.get('bundle_pipeline_reuse')is not None else['bundle-pipeline'])
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
          for inherited in prior['phases']:
           if inherited['name'].startswith('focused-prepare-') or inherited['name'] in ('cli-ffi-install','full-native-suite','bundle-pipeline','bundle'):
            tracing=[arg for arg in inherited['command']['argv'] if arg.startswith('-Dprepare-test-error-tracing')]
            assert tracing==(['-Dprepare-test-error-tracing=true'] if group_binding['prepare_test_error_tracing'] and inherited['name'].startswith('focused-prepare-') else [])
            if filtered_tools:
             filters=[arg for arg in inherited['command']['argv'] if arg.startswith('-Dprepare-test-filter')]
             assert filters==(['-Dprepare-test-filter='+name for name in tools_group['test_names']]if inherited['name']=='focused-prepare-selected-tools'else[])
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
           if filtered_tools and r['group']=='tools':assert r['binary']==selected_prepare['binary']
          full=next(p for p in prior['phases']if p['name']=='full-native-suite');so=auth(full['stdout']).read_text(errors='replace');se=auth(full['stderr']).read_text(errors='replace')
          native=w['classify'](so,se,standalone=False);assert native['passed'] and native['status_count']==cfg['full_native_expected']
          grouped=inv['validate_grouped'](w,expect['expected'],so,se);assert grouped['passed']
          if prior.get('bundle_pipeline_reuse')is not None:
           assert cfg.get('reuse_full_bundle_pipeline',False)is True
           graph=ref(private/'build.zig')
           assert full_pipeline_reuse_record(expected=expect['expected'],helper=w,phase=full,stdout=so,stderr=se,build_graph=graph,build_source=auth(graph).read_text(),source_manifest=cfg['private_manifest'],full_configuration=reuse['configuration'],source_root=private,full_argv=qualification_build_argv(args,cache,w['native_build_argv'],family='full'),standalone_argv=qualification_build_argv(args,cache,w['native_build_argv'],family='bundle-pipeline',prefix=Path(cfg['install_root'])),native_passed=native['passed'],grouped_passed=grouped['passed'])==prior['bundle_pipeline_reuse']
           result['bundle_pipeline_reuse']=prior['bundle_pipeline_reuse']
          names=[name for status,name in w['STATUS'].findall(w['ANSI'].sub('',so+'\n'+se))if status=='ok']
          actual={name:sum(n.endswith('.test.'+name)for n in names)for name in expect['required_test_counts']};assert actual==expect['required_test_counts']
          assert prior['reader_markers']==closed['reader_markers'] and prior['installed']==closed['installed']
          marks=prior['reader_markers'];report=read(marks['child_report']);contract=dict(observed_child_summary=marks['child_summary'],child_report=marks['child_report'],marker_lines=marks['marker_lines'])
          assert markers(w['ANSI'].sub('',so+'\n'+se),contract,report)==marks
          for installed in prior['installed'].values():auth(installed)
          cli=prior['installed']['bin/wikidict'];dynamic['validate'](ds,binary=cli['path'])
          result.update(execution_stage='tail',selected_current_count=0,focused_current_execution=False,full_native_current_execution=False,bundle_pipeline_current_execution=False,inherited_qualification=reuse,focused_qualified=True,focused_inherited_count=len(selected),native_inventory=native,grouped_inventory=grouped,required_test_counts=actual,reader_markers=prior['reader_markers'],writer_image_border=prior.get('writer_image_border'),metadata_python=prior['metadata_python'],installed=prior['installed'],cli_ffi_install_pass=True,full_native_pass=True,bundle_pipeline_pass=True)
          save()
         else:
          prepared_names,prepare_filters,prepare_discovery=validate_preparation_plan(cfg,group_binding,expect,ordered_groups,focus_cases)
          metadata=read(cfg['metadata_python_reuse']);assert metadata['current_manifest']==cfg['private_manifest'] and metadata['runtime_python']==cfg['runtime_python'] and metadata['current_execution_required'] is True
          for name,row in metadata['dependency_files'].items():
           assert row['reference']['path']==str(private/name) and private_manifest[name]['sha256']==row['reference']['sha256'] and private_manifest[name]['bytes']==row['reference']['bytes']
           path=auth(row['reference']);assert not path.is_symlink() and stat.S_IMODE(path.stat().st_mode)==row['mode']
          so,se=execute('reviewed-language-aliases',[str(Path(cfg['python_bin'])/'python3'),'-B',qualification_source_key(private_manifest, 'tools/test_reviewed_language_aliases.py')])
          metadata_text=w['ANSI'].sub('',so+'\n'+se)
          metadata_counts=re.findall(r'^Ran ([0-9]+) tests? in ',metadata_text,re.M)
          assert metadata_counts==[str(cfg['metadata_python_expected'])] and re.search(r'^OK\s*$',metadata_text,re.M),metadata_text
          result['metadata_python']=dict(passed=True,executed=cfg['metadata_python_expected'],native_credit=False,command=result['phases'][-1]);save()
          prepared_prefix=out/'prepared-tests';assert not prepared_prefix.exists()
          filtered_tools=cfg.get('filtered_tools_prerequisite',False)
          filtered_tools_only=cfg.get('filtered_tools_only',False)
          encoder_plan=focused_encoder_preparation(cfg,expect)
          normal_prepared_names=() if filtered_tools_only else prepared_names
          encoder_prefix=out/'selected-encoder'
          if encoder_plan:assert not encoder_prefix.exists()
          encoder_binary=None;encoder_failure=None
          selected_prefix=out/'selected-tools'
          if filtered_tools:assert not selected_prefix.exists()
          binaries={};normal_binaries={};selected_binaries={};prepared_commands=[];failed_preparations={}
          result['focused_preparation_failures']=failed_preparations
          result['focused_execution_plan']='prepare-on-first-use.v1'
          result['focused_preparation_order']=[]
          result['compiled_discovery']=[]
          compile_record=dict(groups=[],commands=prepared_commands,passed=False,binaries=normal_binaries,compile_time_filtered=group_binding['compile_time_filtered_preparation'],external_compile_filters=prepare_filters,fixed_partition_filters={g['id']:g['compile_filter_names'] for g in cfg['groups']},compiled_only_discovery={g['id']:g['compiled_only_discovery_names'] for g in cfg['groups']},full_suite_credit=False,interleaved_with_focus=True,prepare_test_error_tracing=group_binding['prepare_test_error_tracing'])
          # Focused-only artifacts have separate records and no full-root credit.
          if not filtered_tools_only:result['compiles'].append(compile_record)
          save()
          def prepare_focus_group(group,normal=False):
           global encoder_binary,encoder_failure
           prepared=group['id']
           if encoder_plan and prepared in encoder_plan['groups']:
            if prepared in failed_preparations:return False
            if prepared in binaries:auth(binaries[prepared]);return
            if encoder_binary is None and encoder_failure is None:
             argv=prepare_tests_argv(args,cache,encoder_prefix,w['native_build_argv'])
             assert not any(arg.startswith('-Dprepare-test-filter') for arg in argv)
             argv+=['-Dprepare-test-group=encoder']+['-Dprepare-test-filter='+name for name in encoder_plan['filters']]
             command,so,se=execute_outcome('focused-prepare-selected-encoder',argv)
             for bound_binary in list(normal_binaries.values())+list(selected_binaries.values()):auth(bound_binary)
             directory=encoder_prefix/group_binding['prepared_relative_directory']
             assert not directory.is_symlink()
             entries=list(directory.iterdir()) if directory.exists() else []
             if not(command['status']=='exited' and type(command['returncode'])is int and command['returncode']==0):
              encoder_failure=require_ordinary_preparation_compile_failure(command,so,se,w)
              assert not entries
              encoder_failure.update(phase=result['phases'][-1],preparation_scope='selected-encoder-union')
             else:
              assert len(entries)==1 and entries[0].name=='encoder' and entries[0].is_file() and not entries[0].is_symlink() and os.access(entries[0],os.X_OK)
              encoder_binary=ref(entries[0]);auth(encoder_binary)
              selected_binaries['encoder']=encoder_binary
              result['filtered_encoder_preparation']=dict(encoder_plan,binary=encoder_binary,phase=result['phases'][-1],ordinary_preparation_status='deferred-focused-diagnostic')
              for number,discovery in enumerate(encoder_plan['discovery']):
               execute('filtered-discovery-encoder-'+str(number),[encoder_binary['path'],'--dict-run-test',discovery]);auth(encoder_binary)
               result['compiled_discovery'].append(dict(name=discovery,binary=encoder_binary,command=result['phases'][-1],passed=True,semantic_focus_credit=False,full_suite_credit=False));save()
            result['focused_preparation_order'].append(prepared)
            if encoder_failure is not None:
             failed_preparations[prepared]=dict(encoder_failure,group=prepared);save();return False
            auth(encoder_binary);binaries[prepared]=encoder_binary;save();return
           selected=filtered_tools and prepared=='tools'and not normal
           prefix=selected_prefix if selected else prepared_prefix
           target_binaries=selected_binaries if selected else normal_binaries
           if prepared in failed_preparations:return False
           if prepared in target_binaries:
            auth(target_binaries[prepared]);return
           argv=prepare_tests_argv(args,cache,prefix,w['native_build_argv'])
           assert not any(arg.startswith('-Dprepare-test-filter') for arg in argv)
           tracing=[arg for arg in argv if arg.startswith('-Dprepare-test-error-tracing')]
           assert tracing==(['-Dprepare-test-error-tracing=true'] if group_binding['prepare_test_error_tracing'] else [])
           argv+=['-Dprepare-test-group='+prepared]
           if selected:argv+=['-Dprepare-test-filter='+name for name in group['test_names']]
           command,so,se=execute_outcome('focused-prepare-'+('selected-tools'if selected else prepared),argv)
           if not selected:prepared_commands.append(result['phases'][-1])
           if not(command['status']=='exited' and type(command['returncode'])is int and command['returncode']==0):
            failure=require_ordinary_preparation_compile_failure(command,so,se,w)
            for bound_binary in list(normal_binaries.values())+list(selected_binaries.values()):auth(bound_binary)
            directory=prefix/group_binding['prepared_relative_directory']
            assert not directory.is_symlink()
            entries=list(directory.iterdir()) if directory.exists() else []
            assert {p.name for p in entries}==set(target_binaries) and all(p.is_file()and not p.is_symlink()and os.access(p,os.X_OK)for p in entries)
            failure.update(group=prepared,phase=result['phases'][-1])
            if filtered_tools and prepared=='tools':failure['preparation_scope']='selected'if selected else'normal-unfiltered'
            failed_preparations[prepared]=failure
            compile_record['failed_groups']=list(failed_preparations)
            if not normal:result['focused_preparation_order'].append(prepared)
            save()
            return False
           prepared_dir=prefix/group_binding['prepared_relative_directory'];entries=list(prepared_dir.iterdir())
           assert not prepared_dir.is_symlink()
           assert {p.name for p in entries}==set(target_binaries)|{prepared} and all(p.is_file()and not p.is_symlink()and os.access(p,os.X_OK)for p in entries)
           binary=ref(prepared_dir/prepared);auth(binary);binaries[prepared]=binary;target_binaries[prepared]=binary
           for bound_binary in list(normal_binaries.values())+list(selected_binaries.values()):auth(bound_binary)
           if not normal:result['focused_preparation_order'].append(prepared)
           if selected:
            result['filtered_tools_preparation']=dict(filters=list(group['test_names']),compiled_expected_occurrences=list(group['test_names']),binary=binary,phase=result['phases'][-1],selected_passed=False,normal_preparation_passed=False,full_suite_credit=False)
           compile_record['groups']=list(normal_binaries);compile_record['passed']=set(normal_binaries)==set(normal_prepared_names);save()
           for number,discovery in enumerate(prepare_discovery[prepared]):
            execute('filtered-discovery-'+prepared+'-'+str(number),[binary['path'],'--dict-run-test',discovery]);auth(binary)
            result['compiled_discovery'].append(dict(name=discovery,binary=binary,command=result['phases'][-1],passed=True,semantic_focus_credit=False,full_suite_credit=False));save()
          def complete_focus_group(group):
           if filtered_tools and group['id']=='tools':
            selected=result['filtered_tools_preparation'];auth(selected['binary'])
            selected['selected_passed']=True;save()
            if filtered_tools_only:
             selected['ordinary_preparation_status']='deferred-focused-diagnostic';save();return
            if prepare_focus_group(group,normal=True)is False:raise AssertionError('focused_normal_preparation_failure')
            auth(selected['binary']);selected['normal_binary']=normal_binaries['tools']
            assert selected['binary']['path']!=selected['normal_binary']['path']
            selected['normal_preparation_passed']=True;save()
          selected_inventory={'tools':next(group['test_names']for group in cfg['groups']if group['id']=='tools')}if filtered_tools else {}
          if encoder_plan:selected_inventory.update({name:encoder_plan['compiled_expected_occurrences']for name in encoder_plan['groups']})
          execute_focused_cases(focus_cases,binaries=binaries,phase=phase,source_root=private,helper=w,guard=guard,validate_dynamic=lambda:dynamic['validate'](ds),auth=auth,ref=ref,result=result,save=save,prepare_group=prepare_focus_group,stop_on_failure=False,tools_prerequisite=cfg.get('tools_prerequisite',False),compiled_inventories=selected_inventory,after_group_pass=complete_focus_group if filtered_tools else None,collect_returned_failures=filtered_tools_only)
          assert set(binaries)|set(failed_preparations)==set(prepared_names)
          if filtered_tools_only:
           assert not normal_binaries and not prepared_commands and result['compiles']==[]
           if filtered_tools:
            assert 'tools'not in failed_preparations
            selected=result['filtered_tools_preparation']
            assert selected['selected_passed'] is all(row['passed']for row in result['focused_tests']if row['group']=='tools')
            assert selected['normal_preparation_passed'] is False
            assert selected.get('ordinary_preparation_status')==('deferred-focused-diagnostic'if selected['selected_passed']else None)
            assert 'normal_binary'not in selected
           if encoder_plan:
            assert set(failed_preparations)<=set(encoder_plan['groups'])
            assert (encoder_binary is None)==(encoder_failure is not None)
            if encoder_binary:assert all(binaries[name]==encoder_binary for name in encoder_plan['groups'])
          else:assert compile_record['passed'] is (not failed_preparations)
          for bound_binary in list(normal_binaries.values())+list(selected_binaries.values()):auth(bound_binary)
          if filtered_tools and not filtered_tools_only:assert result['filtered_tools_preparation']['normal_preparation_passed'] is True
          assert result['focused_preparation_order']==[group['id']for group in ordered_groups]
          assert [row['name']for row in result['focused_tests']]==[case[2]for case in focus_cases]
          assert len(result['focused_tests'])==cfg['focused_expected'] and cfg['saved_expected']==0
          result['all_selected_accounted']=True;result['all_selected_executed']=not failed_preparations;result['focused_evidence_total']=sum(row.get('executed',True)for row in result['focused_tests']);result['focused_qualified']=not failed_preparations and all(row['passed']for row in result['focused_tests']);save();assert result['focused_qualified'],('focused_preparation_failure' if failed_preparations else 'focused_functional_failure')
          if cfg['execution_stage']!='focused-diagnostic':
           assert not Path(cfg['install_root']).exists()
           execute('cli-ffi-install',qualification_build_argv(args,cache,w['native_build_argv'],family='install',prefix=Path(cfg['install_root'])))
           result['cli_ffi_install_pass']=True
           result['installed']={n:ref(Path(cfg['install_root'])/n)for n in ('bin/wikidict','lib/libdictffi.so','include/dict/dict.h')}
           require_presentation_source_contract(private_binding)
           assert result['installed']['include/dict/dict.h']['sha256']==private_manifest[qualification_source_key(private_manifest, 'src/ffi/dict.h')]['sha256']
           assert '#define DICT_ABI_VERSION 10u'+chr(10) in Path(result['installed']['include/dict/dict.h']['path']).read_text()
           assert 'DICT_ABI_VERSION == 10u && dict_abi_version() == DICT_ABI_VERSION' in (private/qualification_source_key(private_manifest, 'tools/ffi_integration_test.c')).read_text()
           cli=result['installed']['bin/wikidict'];auth(cli)
           result['installed_dynamic_identity']=dynamic['validate'](ds,binary=cli['path']);save()
           full_argv=qualification_build_argv(args,cache,w['native_build_argv'],family='full')
           full_command,so,se=execute_outcome('full-native-suite',full_argv)
           if not(full_command['status']=='exited' and type(full_command['returncode'])is int and full_command['returncode']==0):
            if cfg.get('collect_unrun_full_roots',False):
             plan=failed_full_diagnostic_plan(expect['expected'],w,full_command,so,se)
             result['original_full_failure']=result['phases'][-1];save()
             def diagnostic_save(report):
              result['failed_full_collection']=report;assert result['full_native_pass']is False;save()
             def diagnostic_prepare(group):
              prefix=out/'failed-full-prepared'/group['prepared_group'];assert not prefix.exists()
              argv=qualification_build_argv(args,cache,w['native_build_argv'],family='prepare',prefix=prefix)+['-Dprepare-test-group='+group['prepared_group']]
              execute('failed-full-prepare-'+group['root'],argv)
              directory=prefix/'bin/wikidict-tests';entries=list(directory.iterdir())
              assert len(entries)==1 and entries[0].name==group['prepared_group'] and entries[0].is_file()and not entries[0].is_symlink()and os.access(entries[0],os.X_OK)
              binary=ref(entries[0]);auth(binary);return binary
             def diagnostic_run(group,binary):
              argv=[binary['path']]+(['--test-filter',group['runtime_filter']]if group['runtime_filter']else[])
              return execute_outcome('failed-full-run-'+group['root'],argv)
             collect_failed_full_roots(plan,helper=w,guarded_prepare=diagnostic_prepare,guarded_run=diagnostic_run,auth=auth,save=diagnostic_save)
            raise AssertionError(('full-native-suite',full_command))
           for binary in list(normal_binaries.values())+list(selected_binaries.values()):auth(binary)
           guard();full=next(p for p in result['phases']if p['name']=='full-native-suite')
           result.update(assess_completed_native_full(cfg=cfg,expect=expect,full=full,execution_configuration=start['configuration'],helper=w,inventory=inv,markers=markers,auth=auth,ref=ref,source_files=private_model['files']));save()
         if cfg['execution_stage']!='focused-diagnostic':
          tail_stages=bundle_pipeline_tail_stages(cfg['execution_stage'],result.get('bundle_pipeline_reuse'))
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
