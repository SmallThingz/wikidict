"""Authenticate a paid test-then-Writer install without running any phase again."""
import copy
import hashlib
import json
from pathlib import Path
import shlex
import tempfile
import unittest
import build_wiktionaries as b
from test_direct_writer_successor import descriptor
from test_direct_merge_successor import fixture as merge_fixture

def fixture(root, change=None):
    f = merge_fixture(root, 'transport-gap' if change == 'transport-gap' else None)

    def write(name, value):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))
        return descriptor(path)

    def load(ref):
        return json.loads(Path(ref['path']).read_text())
    row = f.row
    command = load(row['compilation_recipe'])
    closed = load(row['qualification_closure'])
    result = load(row['actual_emission_result'])
    source = load(row['source'])
    files = load(row['compiled_source_authority'])
    files['tools/blob_build.zig'] = descriptor(root / 'view/tools/blob_build.zig', mode=True)
    manifest = write('phased-manifest.json', files)
    manifest_control = dict(manifest, mode=292 if change == 'wrong-manifest-mode' else 420)
    argv = command['argv'][:-2]
    argv[2] = 'prepare-captured-writer'
    argv = ['-Dcaptured-source-fingerprint=' + manifest['sha256'] if x.startswith('-Dcaptured-source-fingerprint=') else x for x in argv]
    argv.append('-Dprepare-test-error-tracing=true')
    if change == 'wrong-final-target':
        argv[2] = 'prepare-blob-tools'
    consumer = root / 'consume.py'
    consumer.write_text('# controlled consumer\n')
    helper = write('helper.json', {'controlled': True})
    data = write('data.json', {'controlled': True})
    phases = []
    logs = {}
    for name, args in [('prepare-tools', [str(root / 'zig'), 'build', 'qualification-cache-artifacts']), ('execute-tools', ['/usr/bin/python3.14', '-I', '-S', '-B', str(consumer), json.dumps(helper), json.dumps(data), 'blob_build_tests']), ('prepare-writer', argv)]:
        phase = dict(name=name, argv=args, stdout=str(root / (name + '.stdout')), stderr=str(root / (name + '.stderr')))
        phases.append(phase)
        logs[name] = {}
        for k in ('stdout', 'stderr'):
            path = Path(phase[k])
            path.write_text('controlled closed phase\n')
            logs[name][k] = descriptor(path)
    if change == 'phase-order':
        phases[0], phases[1] = (phases[1], phases[0])
    phase_ref = dict(write('phases.json', dict(phases=phases, expected_executions=12, tests_before_writer=True, baseline_replayed=False)), mode=420)
    statements = []
    for phase in phases:
        out, err = (shlex.quote(phase['stdout']), shlex.quote(phase['stderr']))
        statements.append(f"""if {shlex.join(phase['argv'])} > {out} 2> {err}; then cat {out}; cat {err} >&2; else rc=$?; cat {out}; cat {err} >&2; exit "$rc"; fi""")
    shell = ['/bin/sh', '-ec', '\n'.join(statements)]
    if change == 'shell-extra':
        shell[2] += '\ntrue'
    refs = [manifest_control, command['source_refs'][1]] + [descriptor(Path(d['path'])) for d in files.values()] + [phase_ref, descriptor(consumer), helper, data]
    if change == 'unguarded-consumer':
        refs.remove(descriptor(consumer))
    if change == 'unguarded-data':
        refs.remove(data)
    qualification = write('qualification.json', {'controlled': True})
    projection = write('projection.json', {'controlled': True})
    refs += [qualification, projection]
    artifact = descriptor(root / 'install/bin/dict-blob-build')
    command.update(argv=shell, source_manifest=manifest_control, source_refs=refs, phases=phase_ref, data=data, expected_install={'writer': artifact['path']}, canonical_projection=dict(projection, mode=420), source_qualification=qualification)
    cr = write('phased-command.json', command)
    command_control = dict(cr, mode=292 if change == 'wrong-command-mode' else 420)
    config = load(closed['owner_config'])
    config.update(input_ref=command_control, source_refs_ref=command_control, source_refs=refs[:2])
    cf = write('phased-owner.json', config)
    start = load(closed['start'])
    start.update(input_authority=command_control, source_refs_ref=command_control, source_refs=refs[:2], source_ref_count=len(refs), source_refs_sha256=hashlib.sha256(json.dumps(refs, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()).hexdigest())
    result.update(argv=shell)
    rr = write('runtime01/result01.json', result)
    closed.update(result=rr, start=write('runtime01/direct-runtime01/start.json', start), owner_config=cf, source_ref_count=start['source_ref_count'], source_refs_sha256=start['source_refs_sha256'], source_manifest=manifest, source_projection=projection, source_qualification=qualification, installed_artifacts={'writer': artifact}, installed_artifact_stats={'writer': list(Path(artifact['path']).lstat())}, normal_roles_emission_passed=True, writer_emission_passed=True, normal_writer_build_completed=True, focused_native_tests_passed=True, actual_named_audits=12, required_named_audits=12, partial_phase_logs=logs)
    closed.pop('normal_merge_emission_passed')
    closed['source_manifest'] = manifest_control
    closed['source_projection'] = command['canonical_projection']
    if change == 'failed-tests':
        closed['focused_native_tests_passed'] = False
    if change == 'wrong-count':
        closed['actual_named_audits'] = 11
    if change == 'foreign-log':
        closed['partial_phase_logs']['prepare-writer']['stderr'] = descriptor(root / 'prepare-tools.stderr')
    if change in ('prefixed-chunk', 'zero-chunk', 'foreign-chunk', 'malformed-chunk'):
        chunk = {'prefixed-chunk': 'chunk-17', 'zero-chunk': 'chunk-0', 'foreign-chunk': 'chunk-18', 'malformed-chunk': 'chunk-17junk'}[change]
        closed['rd_terminal_receipt'] = {'chunk': chunk, 'exit_code': 0}
        closed['reaped_chunk'] = 'chunk-17'
    cl = write('runtime01/direct-runtime01/independent-closure01.json', closed)
    source.update(actual_normal_command=cr, actual_result=rr, actual_closure=cl, compiled_source_manifest=manifest, fingerprint=manifest['sha256'], files=files, normal_writer_phases=phase_ref)
    row.update(compilation_recipe=cr, actual_emission_result=rr, qualification_closure=cl, source=write('phased-source.json', source), compiled_source_authority=manifest, producer_source=manifest['sha256'], artifact=dict(artifact, mode=365), source_paths=['tools/blob_build.zig', 'src/encoder/blob_format.zig'])
    if change == 'log-changed':
        (root / 'prepare-writer.stderr').write_text('changed\n')
    f.argv = argv
    return f


class PhasedWriterSuccessorTests(unittest.TestCase):

    def test_prefixed_terminal_receipt_preserves_exact_identity(self):
        for change in ('prefixed-chunk', 'zero-chunk', 'foreign-chunk', 'malformed-chunk'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as tmp:
                f = fixture(Path(tmp), change)
                if change == 'prefixed-chunk':
                    argv, _ = b.initial_sealed_target_emission(f.row, f.roles, target='prepare-captured-writer')
                    self.assertEqual(argv, f.argv)
                else:
                    with self.assertRaisesRegex(ValueError, 'RD receipt differs'):
                        b.initial_sealed_target_emission(f.row, f.roles, target='prepare-captured-writer')

    def test_phased_cache_and_failure_directory_must_match_the_guarded_controls(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            local = str(root / 'cache')
            output = root / 'controls'
            env = {'ZIG_LOCAL_CACHE_DIR': local, 'WIKIDICT_TEST_FAILURE_OUTPUT_DIR': str(output / 'tmp')}
            phases = [{'argv': ['zig', 'build', '--cache-dir', local]}, {}, {'argv': ['zig', 'build', '--cache-dir', local]}]
            for change in ('valid', 'extra-variable', 'changed-data', 'foreign-output', 'changed-cache', 'absent-option'):
                with self.subTest(change=change):
                    actual = dict(env)
                    commands = copy.deepcopy(phases)
                    if change == 'extra-variable':
                        actual['EXTRA'] = '1'
                    if change == 'foreign-output':
                        actual['WIKIDICT_TEST_FAILURE_OUTPUT_DIR'] = str(root / 'tmp')
                    if change == 'changed-cache':
                        commands[-1]['argv'][-1] = str(root / 'other')
                    if change == 'absent-option':
                        commands[0]['argv'] = ['zig', 'build']
                    recipe = {'qualification_root': str(root / 'runtime01'), 'env': actual}
                    data = root / 'data.json'
                    data.write_text(json.dumps({'environment': {} if change == 'changed-data' else actual, 'output': str(output)}))
                    if change == 'valid':
                        b.initial_sealed_phased_environment(recipe, commands, descriptor(data))
                    else:
                        with self.assertRaises(ValueError):
                            b.initial_sealed_phased_environment(recipe, commands, descriptor(data))

    def test_explicit_metadata_mode_is_authenticated(self):
        for change in ('wrong-manifest-mode', 'wrong-command-mode'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as tmp:
                f = fixture(Path(tmp), change)
                with self.assertRaisesRegex(ValueError, 'metadata mode changed'):
                    b.initial_sealed_target_emission(f.row, f.roles, target='prepare-captured-writer')

    def test_exact_closed_phases_and_honest_transport_gap(self):
        for change in (None, 'transport-gap'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as tmp:
                f = fixture(Path(tmp), change)
                before = copy.deepcopy(f.row)
                argv, _ = b.initial_sealed_target_emission(f.row, f.roles, target='prepare-captured-writer')
                self.assertEqual(argv, f.argv)
                self.assertEqual(f.row, before)
                f.roles.require_unchanged()

    def test_shell_phase_log_and_outcome_mutations_refuse(self):
        for change in ('wrong-final-target', 'phase-order', 'shell-extra', 'failed-tests', 'wrong-count', 'foreign-log', 'log-changed', 'unguarded-consumer', 'unguarded-data'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as tmp:
                f = fixture(Path(tmp), change)
                with self.assertRaises(ValueError):
                    b.initial_sealed_target_emission(f.row, f.roles, target='prepare-captured-writer')


if __name__ == "__main__":
    unittest.main()
