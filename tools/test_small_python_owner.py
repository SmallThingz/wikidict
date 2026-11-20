import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import tracemalloc
import unittest
from unittest import mock

D = Path(__file__).resolve().parent
PROJECT = next(p for p in D.parents if (p / 'tools/build_resource_limits.py').is_file())
spec = importlib.util.spec_from_file_location('stream_owner', D / 'small_python_owner.py')
owner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(owner)


def ref(path):
    return dict(path=str(path), bytes=path.stat().st_size, sha256=hashlib.sha256(path.read_bytes()).hexdigest())


class Tapped:
    def __init__(self, stream, action):
        self.stream = stream
        self.action = action
    def __enter__(self):
        self.stream.__enter__()
        return self
    def __exit__(self, *args):
        return self.stream.__exit__(*args)
    def fileno(self):
        return self.stream.fileno()
    def readinto(self, buffer):
        count = self.stream.readinto(buffer)
        if self.action is not None:
            action, self.action = self.action, None
            action()
        return count


class SourceValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=PROJECT / '.tmp')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = self.root / 'original'
        self.path.write_bytes(b'original source\n' * 1024)
        self.bound = ref(self.path)

    def test_hardlinks_reuse_bytes_but_each_path_has_identity_receipt(self):
        alias = self.root / 'alias'
        os.link(self.path, alias)
        alias_ref = dict(self.bound, path=str(alias))
        result = owner.authenticate_sources([self.bound, alias_ref])
        self.assertEqual((2, 1, 1, self.bound['bytes']), tuple(result[k] for k in ('references', 'distinct_objects', 'aliases_reused', 'bytes_hashed')))
        self.assertEqual({str(self.path), str(alias)}, set(result['path_identities']))
        with mock.patch.object(owner, 'open_source', wraps=owner.open_source) as opened:
            owner.authenticate_sources([self.bound, alias_ref])
        self.assertEqual([str(self.path), str(alias), str(self.path), str(alias)], [str(call.args[0]) for call in opened.call_args_list])

    def test_distinct_inodes_with_equal_bytes_are_each_hashed(self):
        other = self.root / 'copy'
        other.write_bytes(self.path.read_bytes())
        result = owner.authenticate_sources([self.bound, dict(self.bound, path=str(other))])
        self.assertEqual(2, result['distinct_objects'])
        self.assertEqual(2 * self.bound['bytes'], result['bytes_hashed'])
        self.assertEqual(0, result['aliases_reused'])

    def test_conflicting_expected_digest_for_same_inode_refuses(self):
        alias = self.root / 'alias'
        os.link(self.path, alias)
        with self.assertRaisesRegex(ValueError, 'Conflicting'):
            owner.authenticate_sources([self.bound, dict(self.bound, path=str(alias), sha256='0' * 64)])

    def test_bad_size_digest_and_mode_refuse(self):
        for fields in ({'bytes': self.bound['bytes'] + 1}, {'sha256': '0' * 64}, {'mode': 0o777}):
            with self.subTest(fields=fields), self.assertRaises(ValueError):
                owner.authenticate_sources([dict(self.bound, **fields)])

    def test_separate_post_pass_reads_all_objects_again(self):
        before = owner.authenticate_sources([self.bound])
        after = owner.authenticate_sources([self.bound])
        self.assertEqual(before['bytes_hashed'], after['bytes_hashed'])
        self.assertEqual(self.bound['bytes'], after['bytes_hashed'])
        self.path.write_bytes(b'x' * self.bound['bytes'])
        with self.assertRaises(ValueError):
            owner.authenticate_sources([self.bound])

    def test_path_replaced_before_open_refuses_even_same_bytes(self):
        original = owner.open_source
        def replace(path):
            replacement = self.root / 'new'
            replacement.write_bytes(self.path.read_bytes())
            os.replace(replacement, self.path)
            return original(path)
        with mock.patch.object(owner, 'open_source', side_effect=replace), self.assertRaisesRegex(ValueError, 'identity'):
            owner.authenticate_sources([self.bound])

    def test_replacement_and_inplace_change_during_read_refuse(self):
        for mutation in ('replace', 'write', 'mode'):
            with self.subTest(mutation=mutation):
                self.path.write_bytes(b'original source\n' * 1024)
                self.path.chmod(0o644)
                bound = ref(self.path)
                def change():
                    if mutation == 'replace':
                        replacement = self.root / 'new'
                        replacement.write_bytes(self.path.read_bytes())
                        os.replace(replacement, self.path)
                    elif mutation == 'write':
                        with self.path.open('r+b') as stream:
                            stream.write(b'changed!')
                    else:
                        self.path.chmod(0o600)
                original = owner.open_source
                with mock.patch.object(owner, 'open_source', side_effect=lambda p: Tapped(original(p), change)), self.assertRaises(ValueError):
                    owner.authenticate_sources([bound])

    def test_earlier_path_replaced_while_later_file_read_is_refused_at_finish(self):
        other = self.root / 'other'
        other.write_bytes(b'other')
        def replace():
            replacement = self.root / 'new'
            replacement.write_bytes(self.path.read_bytes())
            os.replace(replacement, self.path)
        original = owner.open_source
        with mock.patch.object(owner, 'open_source', side_effect=lambda p: Tapped(original(p), replace if Path(p) == other else None)), self.assertRaisesRegex(ValueError, 'identity'):
            owner.authenticate_sources([self.bound, ref(other)])

    def test_stable_symlink_allowed_and_retarget_refused(self):
        link = self.root / 'link'
        link.symlink_to(self.path.name)
        owner.authenticate_sources([dict(self.bound, path=str(link))])
        other = self.root / 'other'
        other.write_bytes(self.path.read_bytes())
        def change():
            link.unlink()
            link.symlink_to(other.name)
        original = owner.open_source
        with mock.patch.object(owner, 'open_source', side_effect=lambda p: Tapped(original(p), change)), self.assertRaisesRegex(ValueError, 'identity'):
            owner.authenticate_sources([dict(self.bound, path=str(link))])

    def test_streams_source_and_diagnostic_without_whole_file_allocation(self):
        block = b'x' * (256 * 1024)
        digest = hashlib.sha256()
        with self.path.open('wb') as stream:
            for _ in range(64):
                stream.write(block)
                digest.update(block)
        expected = dict(path=str(self.path), bytes=16 * 1024**2, sha256=digest.hexdigest())
        tracemalloc.start()
        try:
            with mock.patch.object(Path, 'read_bytes', side_effect=AssertionError('whole read')):
                actual = owner.authenticate_sources([expected])
                diagnostic = owner.file_reference(self.path)
            peak = tracemalloc.get_traced_memory()[1]
        finally:
            tracemalloc.stop()
        self.assertEqual(expected, diagnostic)
        self.assertEqual(expected['bytes'], actual['bytes_hashed'])
        self.assertLess(peak, 2 * 1024**2)

    def test_command_is_authenticated_before_json_parse_in_owner_and_worker(self):
        self.path.write_bytes(b'not JSON')
        bad = dict(ref(self.path), sha256='0' * 64)
        with self.assertRaisesRegex(ValueError, 'Source changed'):
            owner.prepare({'input_ref': bad})
        request = [bad, str(self.root), True]
        with mock.patch('sys.argv', ['worker', json.dumps(request)]), self.assertRaisesRegex(ValueError, 'Source changed'):
            exec(compile(owner.WORKER, '<worker>', 'exec'), {})
        with self.assertRaisesRegex(ValueError, 'Source changed'):
            owner.main([str(self.path), str(bad['bytes']), bad['sha256']])

    def test_prepare_preserves_direct_mode_and_subprocess_worker_outputs(self):
        output = self.root / 'output'
        output.mkdir()
        command = self.root / 'command.json'
        plan = dict(qualification_root=str(output), cwd=str(self.root), argv=['/usr/bin/python3', '-B', '-c', 'pass'], env={}, scope='unit', source_refs=[self.bound])
        command.write_text(json.dumps(plan))
        config = dict(input_ref=ref(command), output_root=str(output), source_refs=[self.bound, self.bound], profile=dict(memory_bytes=1, reserve_bytes=1, cpu_seconds=120, wall_seconds=300, max_tasks=64, disk_floor_bytes=1, cpus=[0]))
        # Invalid launch settings must fail before reading large bound inputs.
        with mock.patch.object(owner, 'authenticate_sources') as bulk_read, \
                mock.patch.object(owner.os, 'getpriority', return_value=0):
            with self.assertRaisesRegex(ValueError, 'inherited nice'):
                owner.prepare(dict(config, child_nice=10))
            with self.assertRaisesRegex(ValueError, 'Invalid resource profile'):
                owner.prepare(dict(config, profile=dict(config['profile'], wall_seconds=0)))
            bulk_read.assert_not_called()
        child = owner.prepare(config)[3]
        self.assertEqual([config['input_ref'], str(output)], json.loads(child[3]))
        config['direct_cli'] = True
        self.assertEqual([config['input_ref'], str(output), True], json.loads(owner.prepare(config)[3][3]))
        for value in (0, 1, 'true', None):
            config['direct_cli'] = value
            with self.assertRaises(ValueError):
                owner.prepare(config)
        with mock.patch('sys.argv', ['worker', child[3]]), mock.patch('subprocess.run', return_value=mock.Mock(returncode=23)), self.assertRaises(SystemExit) as stopped:
            exec(compile(child[2], '<worker>', 'exec'), {})
        self.assertEqual(23, stopped.exception.code)
        result = json.loads((output / 'result01.json').read_text())
        self.assertEqual(23, result['returncode'])
        self.assertEqual(plan['argv'], result['argv'])
        self.assertEqual(ref(output / 'tests.stdout'), result['stdout'])

    def test_direct_receipts_keep_all_refs_console_is_compact_and_post_pass_fresh(self):
        from types import SimpleNamespace
        output = self.root / 'output'
        output.mkdir()
        command = self.root / 'command.json'
        refs = [self.bound] * 20
        plan = dict(qualification_root=str(output), cwd=str(self.root), argv=['/usr/bin/python3'], env={}, scope='unit', source_refs=refs)
        command.write_text(json.dumps(plan))
        config = dict(input_ref=ref(command), output_root=str(output), source_refs=refs, child_nice=max(0, os.getpriority(os.PRIO_PROCESS, 0)), profile=dict(memory_bytes=1, reserve_bytes=1, cpu_seconds=120, wall_seconds=300, max_tasks=64, disk_floor_bytes=1, cpus=[0]))
        limits = SimpleNamespace(__file__=str(self.path), HostMemoryObservation=lambda policy: SimpleNamespace(sample=lambda: {}), supervise_watchdog=mock.Mock(return_value=0))
        guardian = SimpleNamespace(__file__=str(self.path))
        console = io.StringIO()
        with mock.patch.dict('sys.modules', {'build_resource_limits': limits, 'build_watchdog_guardian': guardian}), mock.patch('sys.path', list(__import__('sys').path)), mock.patch.object(owner.os, 'sched_setaffinity'), mock.patch.object(owner.resource, 'setrlimit'), contextlib.redirect_stdout(console):
            self.assertEqual(0, owner.run(config))
        runtime = output / 'direct-runtime01'
        self.assertEqual(refs, json.loads((runtime / 'start.json').read_text())['source_refs'])
        compact = json.loads(console.getvalue().split('CHECK ', 1)[1])
        self.assertNotIn('source_refs', compact)
        self.assertEqual(20, compact['source_ref_count'])
        for phase in ('before', 'after'):
            receipt = json.loads((runtime / ('source-validation-' + phase + '01.json')).read_text())
            self.assertEqual(self.bound['bytes'], receipt['bytes_hashed'])
            self.assertEqual(19, receipt['aliases_reused'])



class DirectCliWatchdogTests(unittest.TestCase):
    def exercise(self, expected_exit):
        import os
        import sys
        selected = D / 'small_python_owner.py'
        spec = importlib.util.spec_from_file_location('actual_direct_cli_owner', selected)
        direct = importlib.util.module_from_spec(spec); spec.loader.exec_module(direct)
        root = PROJECT
        resources = root / 'tools/build_resource_limits.py'
        guardian = root / 'tools/build_watchdog_guardian.py'
        with tempfile.TemporaryDirectory(prefix='direct-cli-proof-', dir=PROJECT / '.tmp') as tmp:
            output = Path(tmp)
            command = output / 'command.json'
            memory = 256 * 1024**2
            code = "import os,sys,json;sys.path.insert(0," + repr(str(resources.parent)) + ");import build_resource_limits as l;assert l.inside_watchdog();assert l.inside_watchdog();assert os.getpid()==os.getsid(0)==os.getpgrp();assert os.getppid()==int(os.environ[l.WATCHDOG_PARENT_PID]);assert l.watchdog_physical_memory_limit_bytes()==" + str(memory) + ";print(json.dumps(dict(pid=os.getpid(),parent=os.getppid(),session=os.getsid(0),budget=l.watchdog_physical_memory_limit_bytes())));print('direct stderr',file=sys.stderr);sys.exit(" + str(expected_exit) + ")"
            plan = dict(qualification_root=str(output), cwd=str(root), argv=[sys.executable, '-B', '-c', code], env={}, scope='actual direct-exec one-use watchdog proof fixture', source_refs=[ref(resources), ref(guardian)])
            command.write_text(json.dumps(plan))
            config = dict(input_ref=ref(command), output_root=str(output), source_refs=[ref(resources), ref(guardian)], child_nice=max(0, os.getpriority(os.PRIO_PROCESS, 0)), direct_cli=True, profile=dict(memory_bytes=memory, reserve_bytes=1024**3, cpu_seconds=120, wall_seconds=60, max_tasks=32, disk_floor_bytes=1024**2, cpus=[min(os.sched_getaffinity(0))]))
            self.assertEqual(expected_exit, direct.run(config))
            result = json.loads((output / 'result01.json').read_text())
            owner_result = json.loads((output / 'direct-runtime01/owner-result.json').read_text())
            report = json.loads((output / 'direct-runtime01/watchdog.json').read_text())
            proof = json.loads((output / 'tests.stdout').read_text())
            self.assertEqual(expected_exit, result['returncode']); self.assertEqual(expected_exit, owner_result['returncode'])
            self.assertTrue(owner_result['source_after'])
            self.assertEqual(plan['argv'], result['argv']); self.assertEqual(plan['env'], result['environment'])
            self.assertEqual(ref(output / 'tests.stdout'), result['stdout']); self.assertEqual(ref(output / 'tests.stderr'), result['stderr'])
            self.assertEqual('direct stderr\n', (output / 'tests.stderr').read_text())
            self.assertEqual(proof['pid'], proof['session']); self.assertEqual(os.getpid(), proof['parent'])
            self.assertEqual(memory, proof['budget']); self.assertEqual(memory, report['memory_limit_bytes'])
            self.assertEqual('child_exit', report['termination_reason']); self.assertTrue(report['cleanup_complete'])

    def test_actual_direct_cli_preserves_one_use_proof_and_success(self):
        self.exercise(0)

    def test_actual_direct_cli_preserves_one_use_proof_and_nonzero(self):
        self.exercise(23)


if __name__ == '__main__':
    unittest.main()
