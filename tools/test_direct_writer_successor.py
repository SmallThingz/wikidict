"""Receipt-family tests; fixture executables are data and are never launched."""
import copy
import hashlib
import json
import stat
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

import build_wiktionaries as b


def descriptor(path, mode=False):
    value = dict(path=str(path), bytes=path.stat().st_size,
                 sha256=hashlib.sha256(path.read_bytes()).hexdigest())
    if mode:
        value['mode'] = stat.S_IMODE(path.stat().st_mode)
    return value


class BoundInputs:
    def __init__(self):
        self.inputs = {}

    def bind_input(self, path):
        value = descriptor(path, mode=True)
        self.inputs.setdefault(path, value)
        return value

    def require_unchanged(self):
        for path, expected in self.inputs.items():
            if descriptor(path, mode=True) != expected:
                raise ValueError('Bound input changed')


def fixture(root, change=None):
    def write(name, value):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))
        return descriptor(path)

    native = root / 'install/bin/dict-blob-build'
    native.parent.mkdir(parents=True)
    native.write_bytes(b'non-executable receipt test fixture\n')
    native.chmod(0o555)
    source_path = root / 'view/tools/blob_build.zig'
    source_path.parent.mkdir(parents=True)
    source_path.write_text('// receipt test source\n')
    compiled = {'tools/blob_build.zig': descriptor(source_path, mode=True)}
    if change == 'extra-fixture':
        extra = root / 'view/tools/testdata/example.txt'
        extra.parent.mkdir(parents=True)
        extra.write_text('not a production role dependency\n')
        compiled['tools/testdata/example.txt'] = descriptor(extra, mode=True)
    manifest = write('manifest.json', compiled)
    refs = [manifest, descriptor(source_path)]
    if change == 'extra-fixture': refs.append(descriptor(extra))
    if change == 'source-modes': refs[1] = descriptor(source_path, mode=True)
    argv = [str(root / 'zig'), 'build', 'prepare-captured-writer', '-j1',
            '-Doptimize=safe', '-Dtarget=x86_64-native', '-Dcpu=baseline',
            '-Dcaptured-source-fingerprint=' + manifest['sha256'],
            '--prefix', str(root / 'install'), '--summary', 'all']
    if change == 'another-target': argv[2] = 'prepare-blob-verify'
    if change == 'extra-target': argv.insert(3, 'cli')
    if change == 'unknown-option': argv.append('-Dskip-source=true')
    if change == 'duplicate-option': argv.extend(['--prefix', str(root / 'install')])
    if change == 'unguarded-source': refs = refs[:1]
    command = dict(argv=argv, cwd=str(root / 'view'), env={},
                   qualification_root=str(root / 'runtime01'), source_refs=refs)
    command_ref = write('command.json', command)
    stdout = root / 'stdout'; stdout.write_text('fixture success\n')
    stderr = root / 'stderr'; stderr.write_text('fixture build summary\n')
    result = dict(argv=argv[:], cwd=command['cwd'], environment={}, returncode=0,
                  stdout=descriptor(stdout), stderr=descriptor(stderr))
    if change == 'failed-child': result['returncode'] = 1
    if change == 'different-argv': result['argv'].append('cli')
    result_ref = write('runtime01/result01.json', result)
    start = dict(input_authority=command_ref, source_refs=copy.deepcopy(refs))
    if change == 'different-start': start['source_refs'] = []
    start_ref = write('runtime01/direct-runtime01/start.json', start)
    owner = dict(returncode=0, source_after=True)
    if change == 'source-changed': owner['source_after'] = False
    owner_ref = write('runtime01/direct-runtime01/owner-result.json', owner)
    watchdog = dict(child_exit_status=0, guardian_exit_status=0, runtime_started=True,
                    cleanup_complete=True, admission_refused=False, termination_reason='child_exit')
    if change == 'cleanup-pending': watchdog['cleanup_complete'] = False
    watchdog_ref = write('runtime01/direct-runtime01/watchdog.json', watchdog)
    closed = dict(outcome='PASSED-PHYSICALLY-SOURCE-CLOSED', source_after=True,
                  source_lease_released=True, allocation_released=True,
                  local_proc_absent=True, ps_absent=True, host_namespace_identity_absent=True,
                  result=result_ref, start=start_ref, owner_result=owner_ref, watchdog=watchdog_ref,
                  artifact=descriptor(native), reaped=True, terminal=0)
    if change == 'transport-gap': closed.update(reaped=False, terminal=None)
    if change == 'invented-reaping': closed.update(reaped=False, terminal=0)
    if change == 'process-live': closed['host_namespace_identity_absent'] = False
    if change == 'foreign-result': closed['result'] = write('another/result01.json', result)
    if change == 'different-artifact': closed['artifact']['sha256'] = '0' * 64
    closure_ref = write('runtime01/direct-runtime01/independent-closure01.json', closed)
    guard = dict(actual_normal_command=command_ref, actual_result=result_ref,
                 actual_closure=closure_ref, compiled_source_manifest=manifest,
                 fingerprint=manifest['sha256'], files=copy.deepcopy(compiled),
                 interface_only_sources={}, interface_only_not_claimed_as_compiler_reads=True)
    if change == 'invented-source': guard['files']['tools/foreign.zig'] = descriptor(source_path, mode=True)
    source_ref = write('source-guard.json', guard)
    row = dict(compilation_recipe=command_ref, actual_emission_result=result_ref,
               qualification_closure=closure_ref, source=source_ref,
               compiled_source_authority=manifest, producer_source=manifest['sha256'],
               artifact=descriptor(native, mode=True), source_paths=['tools/blob_build.zig'],
               dependencies=dict(zig=dict(path=str(root / 'zig'))))
    if change == 'binary-mutated': native.write_bytes(b'changed after closure\n')
    return SimpleNamespace(row=row, roles=BoundInputs(), argv=argv, artifact=native)


class DirectWriterSuccessorTests(unittest.TestCase):
    def test_success_and_honest_transport_gap_retain_binary_and_receipt_bindings(self):
        for change in (None, 'transport-gap', 'source-modes', 'extra-fixture'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temporary:
                f = fixture(Path(temporary), change)
                argv, refs = b.initial_sealed_target_emission(
                    f.row, f.roles, target='prepare-captured-writer')
                self.assertEqual(argv, f.argv)
                self.assertIn(f.artifact, f.roles.inputs)
                self.assertEqual(len(refs), 10)
                f.roles.require_unchanged()

    def test_foreign_commands_sources_outcomes_and_changed_binary_refuse(self):
        changes = ('another-target', 'extra-target', 'unknown-option', 'duplicate-option',
                   'unguarded-source', 'failed-child', 'different-argv', 'different-start',
                   'source-changed', 'cleanup-pending', 'invented-reaping', 'process-live',
                   'foreign-result', 'different-artifact', 'invented-source', 'binary-mutated')
        for change in changes:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temporary:
                f = fixture(Path(temporary), change)
                with self.assertRaises(ValueError):
                    b.initial_sealed_target_emission(f.row, f.roles, target='prepare-captured-writer')

    def test_direct_family_does_not_authorize_other_roles_or_full_graph(self):
        with tempfile.TemporaryDirectory() as temporary:
            f = fixture(Path(temporary))
            for target, full in [('prepare-blob-verify', False), ('prepare-blob-tools', True),
                                 ('prepare-captured-writer', True)]:
                with self.subTest(target=target, full=full), self.assertRaises(ValueError):
                    b.initial_sealed_target_emission(f.row, f.roles, target=target, full_graph=full)


if __name__ == '__main__':
    unittest.main()
