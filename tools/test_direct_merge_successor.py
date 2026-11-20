"""One normal Merge install with compact receipts and an exact sibling graph."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import build_wiktionaries as b
from test_direct_writer_successor import descriptor, fixture as writer_fixture


def fixture(root, change=None):
    f = writer_fixture(root, 'transport-gap' if change == 'transport-gap' else None)
    def write(name, value):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))
        return descriptor(path)
    def load(reference):
        return json.loads(Path(reference['path']).read_text())
    row = f.row
    command = load(row['compilation_recipe'])
    result = load(row['actual_emission_result'])
    closed = load(row['qualification_closure'])
    source = load(row['source'])
    files = {}
    for name in ('tools/blob_merge.zig', 'src/encoder/blob_format.zig', 'build-fr-merge01.zig'):
        path = root / 'view' / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('// controlled receipt source: ' + name + '\n')
        files[name] = descriptor(path, mode=True)
    manifest = write('manifest-merge.json', files)
    native = root / 'install/bin/dict-blob-merge'
    native.write_bytes(b'controlled Merge artifact, never executed\n')
    native.chmod(0o555)
    artifact = descriptor(native)
    owner = root / 'compact-owner.py'
    owner.write_text('# controlled compact owner\n')
    owner_ref = descriptor(owner)
    refs = [manifest, owner_ref] + [descriptor(Path(value['path'])) for value in files.values()]
    command['argv'][2] = 'prepare-blob-merge'
    command['argv'] = [('-Dcaptured-source-fingerprint=' + manifest['sha256']) if value.startswith('-Dcaptured-source-fingerprint=') else value for value in command['argv']]
    command['argv'] += ['--build-file', str(root / 'view/build-fr-merge01.zig')]
    command.update(source_refs=refs, source_manifest=manifest, expected_install={'merge': str(native)})
    if change == 'extra-target': command['argv'].insert(3, 'cli')
    if change == 'wrong-target': command['argv'][2] = 'prepare-captured-writer'
    if change == 'wrong-graph': command['argv'][-1] = str(root / 'view/unobserved.zig')
    if change == 'unbounded-jobs': command['argv'][3] = '-j2'
    if change == 'wrong-install': command['expected_install']['merge'] = str(f.artifact)
    command_ref = write('merge-command.json', command)
    config = dict(input_ref=command_ref, source_refs_ref=command_ref, source_refs=refs[:2], required_owner=owner_ref)
    config_ref = write('merge-owner-config.json', config)
    start = load(closed['start'])
    start.update(input_authority=command_ref, source_refs_ref=command_ref, source_refs=refs[:2],
        source_ref_count=len(refs), source_refs_sha256=hashlib.sha256(json.dumps(refs, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()).hexdigest())
    if change == 'wrong-count': start['source_ref_count'] += 1
    if change == 'wrong-digest': start['source_refs_sha256'] = '0' * 64
    if change == 'wrong-bootstrap': start['source_refs'] = refs[1:3]
    result.update(argv=command['argv'], cwd=command['cwd'], environment=command['env'])
    if change == 'failed-child': result['returncode'] = 1
    result_ref = write('runtime01/result01.json', result)
    closed.update(result=result_ref, start=write('runtime01/direct-runtime01/start.json', start),
        owner_config=config_ref, selected_owner=owner_ref, source_ref_count=start['source_ref_count'],
        source_refs_sha256=start['source_refs_sha256'], normal_merge_emission_passed=True, errors=[],
        source_manifest=manifest, installed_artifacts={'merge': artifact}, installed_artifact_stats={'merge': list(native.lstat())})
    closed.pop('artifact')
    if change == 'source-open': closed['source_after'] = False
    if change == 'no-merge-success': closed['normal_merge_emission_passed'] = False
    if change == 'wrong-artifact': closed['installed_artifacts']['merge'] = descriptor(f.artifact)
    if change == 'wrong-manifest': closed['source_manifest'] = owner_ref
    closure = write('runtime01/direct-runtime01/independent-closure01.json', closed)
    source.update(actual_normal_command=command_ref, actual_result=result_ref, actual_closure=closure,
        compiled_source_manifest=manifest, fingerprint=manifest['sha256'], files=files)
    row.update(compilation_recipe=command_ref, actual_emission_result=result_ref, qualification_closure=closure,
        source=write('merge-source-guard.json', source), compiled_source_authority=manifest, producer_source=manifest['sha256'],
        artifact=dict(artifact, mode=0o555), source_paths=['tools/blob_merge.zig', 'src/encoder/blob_format.zig'])
    if change == 'source-changed': (root / 'view/tools/blob_merge.zig').write_text('// changed\n')
    if change == 'artifact-replaced':
        saved = native.with_suffix('.original')
        native.rename(saved)
        native.write_bytes(saved.read_bytes())
        native.chmod(0o555)
    if change == 'artifact-writable': native.chmod(0o755)
    if change == 'artifact-hardlinked': native.with_suffix('.link').hardlink_to(native)
    if change == 'role-entry-missing': row['source_paths'] = ['src/encoder/blob_format.zig']
    f.argv = command['argv']
    f.artifact = native
    return f


class DirectMergeSuccessorTests(unittest.TestCase):
    def test_exact_single_merge_and_honest_terminal_gap(self):
        for change in (None, 'transport-gap'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as tmp:
                f = fixture(Path(tmp), change)
                before = copy.deepcopy(f.row)
                argv, _ = b.initial_sealed_target_emission(f.row, f.roles, target='prepare-blob-merge')
                self.assertEqual(argv, f.argv)
                self.assertEqual(f.row, before)
                f.roles.require_unchanged()

    def test_command_graph_and_role_are_exact(self):
        for change in ('extra-target', 'wrong-target', 'wrong-graph', 'unbounded-jobs', 'wrong-install', 'role-entry-missing'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as tmp:
                f = fixture(Path(tmp), change)
                with self.assertRaises(ValueError):
                    b.initial_sealed_target_emission(f.row, f.roles, target='prepare-blob-merge')
        with tempfile.TemporaryDirectory() as tmp:
            f = fixture(Path(tmp))
            with self.assertRaises(ValueError):
                b.initial_sealed_target_emission(f.row, f.roles, target='prepare-blob-merge', full_graph=True)

    def test_compact_source_and_closed_outcome_are_required(self):
        for change in ('wrong-count', 'wrong-digest', 'wrong-bootstrap', 'failed-child', 'source-open',
                       'no-merge-success', 'wrong-manifest', 'source-changed'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as tmp:
                f = fixture(Path(tmp), change)
                with self.assertRaises(ValueError):
                    b.initial_sealed_target_emission(f.row, f.roles, target='prepare-blob-merge')

    def test_paid_artifact_identity_is_not_reconstructed_from_equal_bytes(self):
        for change in ('wrong-artifact', 'artifact-replaced', 'artifact-writable', 'artifact-hardlinked'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as tmp:
                f = fixture(Path(tmp), change)
                with self.assertRaises(ValueError):
                    b.initial_sealed_target_emission(f.row, f.roles, target='prepare-blob-merge')


if __name__ == '__main__':
    unittest.main()
