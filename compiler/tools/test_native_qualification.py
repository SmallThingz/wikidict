#!/usr/bin/env python3
"""Pure planning and fake-executor controls; never launches a native process."""
import copy
import hashlib
import os
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch

import native_qualification as qualification
import native_qualification_helpers as helpers


def worker_role_ast():
    """Extract only the maintained worker role, excluding the closure owner."""
    import ast
    tree = ast.parse(Path(qualification.__file__).read_text())
    main = [node for node in tree.body if isinstance(node, ast.If)
            and ast.unparse(node.test) == "__name__ == '__main__'"]
    assert len(main) == 1
    roles = [node for node in main[0].body if isinstance(node, ast.If)
             and ast.unparse(node.test) == "role == 'owner'"]
    assert len(roles) == 1 and roles[0].orelse
    worker = ast.Module(body=roles[0].orelse, type_ignores=[])
    assert sum(isinstance(node, ast.FunctionDef) and node.name == 'prepare_focus_group'
               for node in ast.walk(worker)) == 1
    return worker


def groups():
    return [dict(id=group, prepared_group=group + '_prepared',
                 test_names=[group + '.test.first', group + '.test.second'],
                 declaration_names=['first', 'second'],
                 compiled_expected_occurrences=[group + '.test.first', group + '.test.second'])
            for group in ('encoder', 'lua', 'tools')]


def identities(cases):
    return [(group['id'], index, name, declaration)
            for group, index, name, declaration in cases]


def binding(selected, root):
    count = sum(len(group['test_names']) for group in selected)
    distinct = len({name for group in selected for name in group['test_names']})
    cfg = dict(private_source_binding={'sha256': 'source'}, private_manifest={'sha256': 'manifest'},
               groups=selected, focused_expected=count, saved_expected=0,
               focused_distinct_names=distinct)
    proof = dict(source_binding=copy.deepcopy(cfg['private_source_binding']),
                 private_manifest=copy.deepcopy(cfg['private_manifest']), cwd=str(root),
                 groups=copy.deepcopy(selected), total_selected=count,
                 total_distinct_selected=distinct, carried_count=0)
    return cfg, proof


class AdmissionRefusalPathTests(unittest.TestCase):
    def test_sparse_history_is_scanned_once_only_after_a_refusal(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            for name in ('admission-refusal0001.json', 'admission-refusal0004.json',
                         'admission-refusal-note.json'):
                (folder / name).write_text('retained')
            with patch.object(Path, 'glob', autospec=True, side_effect=Path.glob) as scan:
                paths = qualification.admission_refusal_paths(folder)
                scan.assert_not_called()
                for number in range(5, 8):
                    path = next(paths)
                    self.assertEqual(path.name, f'admission-refusal{number:04d}.json')
                    with path.open('x') as receipt:
                        receipt.write('new')
                scan.assert_called_once()
            self.assertEqual((folder / 'admission-refusal0004.json').read_text(), 'retained')
            self.assertEqual(next(qualification.admission_refusal_paths(folder)).name, 'admission-refusal0008.json')


class FailureOutputTests(unittest.TestCase):
    key = 'WIKIDICT_TEST_FAILURE_OUTPUT_DIR'

    def test_repeated_binary_indices_keep_separate_complete_failure_streams(self):
        payload = b'complete diagnostic\x00\xff\n' * 1000
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {self.key: '/unused-inherited'}):
            out = Path(tmp)
            calls = []

            def execute(output, label, argv, cwd):
                self.assertEqual((output, argv, cwd), (out, ['same-test-binary'], out))
                directory = Path(os.environ[self.key])
                calls.append(directory)
                (directory / 'same-binary-17.stderr').write_bytes(payload)
                return {'status': 'exited', 'returncode': 1}

            for label in ('focused-tools-17', 'full-tools'):
                self.assertEqual(qualification.execute_with_failure_output(
                    execute, out, label, ['same-test-binary'], out),
                    {'status': 'exited', 'returncode': 1})
                self.assertEqual(os.environ[self.key], '/unused-inherited')
            self.assertNotEqual(*calls)
            for directory in calls:
                self.assertEqual((directory / 'same-binary-17.stderr').read_bytes(), payload)

    def test_success_removes_empty_directory_and_restores_absent_environment(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ):
            os.environ.pop(self.key, None)
            out = Path(tmp)

            def execute(*_):
                self.assertTrue(Path(os.environ[self.key]).is_dir())
                return 0

            self.assertEqual(qualification.execute_with_failure_output(execute, out, 'passed', [], out), 0)
            self.assertNotIn(self.key, os.environ)
            self.assertEqual(list((out / 'test-failures').iterdir()), [])

    def test_executor_exception_preserves_partial_diagnostic_and_restores_environment(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {self.key: '/previous'}):
            out = Path(tmp)

            def execute(*_):
                (Path(os.environ[self.key]) / 'partial.stderr').write_bytes(b'original failure')
                raise RuntimeError('interrupted executor')

            with self.assertRaisesRegex(RuntimeError, 'interrupted executor'):
                qualification.execute_with_failure_output(execute, out, 'interrupted', [], out)
            self.assertEqual(os.environ[self.key], '/previous')
            self.assertEqual((out / 'test-failures/interrupted/partial.stderr').read_bytes(), b'original failure')

    def test_existing_command_directory_and_invalid_label_refuse_before_dispatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            existing = out / 'test-failures/failed'
            existing.mkdir(parents=True)
            (existing / 'original.stderr').write_bytes(b'preserve')

            def never(*_):
                self.fail('must not dispatch')

            with self.assertRaises(FileExistsError):
                qualification.execute_with_failure_output(never, out, 'failed', [], out)
            for label in ('../outside', '', '/absolute'):
                with self.assertRaises(ValueError):
                    qualification.execute_with_failure_output(never, out, label, [], out)
            self.assertEqual((existing / 'original.stderr').read_bytes(), b'preserve')


class FocusPlanTests(unittest.TestCase):
    def test_default_preserves_inventory_order_and_receipt_indices(self):
        selected = groups()
        cfg, proof = binding(selected, '/fixture/source')
        ordered, cases = qualification.bound_focus_plan(cfg, proof, Path('/fixture/source'))
        self.assertEqual(ordered, selected)
        self.assertEqual(identities(cases), [
            (group['id'], index, name, group['declaration_names'][index])
            for group in selected for index, name in enumerate(group['test_names'])])
        self.assertEqual(len(cases), 6)
        selected.append(dict(id='closure', prepared_group='closure_prepared',
                             test_names=['closure.test.new'], declaration_names=['new']))
        cfg, proof = binding(selected, '/fixture/source')
        self.assertEqual(len(qualification.bound_focus_plan(cfg, proof, Path('/fixture/source'))[1]), 7)

    def test_tools_priority_matches_existing_carrier_order_without_renumbering(self):
        selected = groups()
        original = copy.deepcopy(selected)
        priority = selected[-1]['test_names'][1]
        ordered, cases = qualification.selected_focus_plan(
            selected, [dict(group='tools', name=priority)])
        old_order = sorted(selected, key=lambda group: group['id'] != 'tools')
        old_cases = [(group, index, name, declaration)
                     for group in old_order
                     for index, (name, declaration) in sorted(
                         enumerate(zip(group['test_names'], group['declaration_names'], strict=True)),
                         key=lambda item: item[1][0] != priority)]
        self.assertEqual(ordered, old_order)
        self.assertEqual(identities(cases), identities(old_cases))
        self.assertEqual(identities(cases)[:2], [
            ('tools', 1, 'tools.test.second', 'second'),
            ('tools', 0, 'tools.test.first', 'first')])
        self.assertEqual(selected, original)

    def test_ordered_cross_group_subset_preserves_every_selected_test_once(self):
        selected = groups()
        priority = [dict(group='tools', name='tools.test.second'),
                    dict(group='lua', name='lua.test.first'),
                    dict(group='tools', name='tools.test.first')]
        ordered, cases = qualification.selected_focus_plan(selected, priority)
        self.assertEqual([group['id'] for group in ordered], ['tools', 'lua', 'encoder'])
        self.assertEqual([(case[0]['id'], case[2]) for case in cases[:3]],
                         [(row['group'], row['name']) for row in priority])
        self.assertCountEqual(identities(cases), identities(
            qualification.selected_focus_plan(selected, [])[1]))
        self.assertEqual(len({(case[0]['id'], case[2]) for case in cases}), 6)

    def test_unknown_duplicate_wrong_group_or_malformed_priority_is_rejected(self):
        invalid = [None, {}, [dict(group='tools', name='missing')],
                   [dict(group='lua', name='tools.test.first')],
                   [dict(group='absent', name='tools.test.first')],
                   [dict(group='tools', name='tools.test.first')] * 2,
                   [dict(group='tools', name='tools.test.first', ignored=True)],
                   [dict(group='tools')], [dict(group=[], name='tools.test.first')]]
        for priority in invalid:
            with self.subTest(priority=priority), self.assertRaises(AssertionError):
                qualification.selected_focus_plan(groups(), priority)

    def test_ambiguous_or_incomplete_inventory_is_rejected(self):
        invalid = [[]]
        duplicate_group = groups(); duplicate_group.append(copy.deepcopy(duplicate_group[0]))
        invalid.append(duplicate_group)
        for field, value in [('test_names', []),
                             ('test_names', ['encoder.test.first'] * 2),
                             ('declaration_names', ['first']),
                             ('declaration_names', ['first', ''])]:
            selected = groups(); selected[0][field] = value; invalid.append(selected)
        for selected in invalid:
            with self.subTest(groups=selected), self.assertRaises(AssertionError):
                qualification.selected_focus_plan(selected, [])
        changes = [
            ('proof', 'cwd', '/different/source'),
            ('proof', 'source_binding', {'sha256': 'different-source'}),
            ('proof', 'private_manifest', {'sha256': 'different-manifest'}),
            ('proof', 'groups', list(reversed(groups()))),
            ('proof', 'total_selected', 5),
            ('cfg', 'focused_expected', 7),
            ('proof', 'total_distinct_selected', 5),
            ('cfg', 'focused_distinct_names', 7),
            ('proof', 'carried_count', 1),
            ('cfg', 'saved_expected', 1),
        ]
        for target, key, value in changes:
            cfg, proof = binding(groups(), '/fixture/source')
            (cfg if target == 'cfg' else proof)[key] = value
            with self.subTest(target=target, key=key), self.assertRaises(AssertionError):
                qualification.bound_focus_plan(cfg, proof, Path('/fixture/source'))
        cfg, proof = binding(groups(), '/fixture/source')
        cfg['focused_expected'] = proof['total_selected'] = 7
        with self.assertRaises(AssertionError):
            qualification.bound_focus_plan(cfg, proof, Path('/fixture/source'))


class FakeExecution:
    def __init__(self, root):
        self.phase = root / 'commands'; self.phase.mkdir()
        self.source = root / 'source'; self.source.mkdir()
        self.calls = []
        self.events = []
        self.saved = []
        self.outcomes = {}
        self.outputs = {}
        self.groups = groups()
        self.command_error = None
        self.guard_error = None
        self.dynamic_error = None
        self.auth_error = None
        self.fail_guard_at = None
        self.guard_count = 0
        self.mutate_after = None
        self.result = dict(focused_tests=[])
        self.binaries = {}
        for group in self.groups:
            path = root / group['prepared_group']; path.write_bytes(group['id'].encode())
            self.binaries[group['prepared_group']] = self.ref(path)

    @staticmethod
    def ref(path):
        path = Path(path); content = path.read_bytes()
        return dict(path=str(path), bytes=len(content), sha256=hashlib.sha256(content).hexdigest())

    def auth(self, descriptor):
        self.events.append(('auth', descriptor['path']))
        if self.auth_error is not None:
            raise self.auth_error
        if self.ref(descriptor['path']) != descriptor:
            raise AssertionError('prepared binary changed')
        return Path(descriptor['path'])

    def guard(self):
        self.guard_count += 1
        self.events.append(('guard', self.guard_count))
        if self.guard_count == self.fail_guard_at:
            raise self.guard_error

    def dynamic(self):
        self.events.append(('dynamic', None))
        if self.dynamic_error is not None:
            raise self.dynamic_error

    def save(self):
        self.saved.append(copy.deepcopy(self.result))

    def execute(self, phase, label, argv, source):
        self.calls.append((label, argv, source))
        self.events.append(('execute', label))
        if self.command_error is not None:
            raise self.command_error
        stdout, stderr = self.outputs.get(label, ('selected assertion\n', ''))
        (phase / (label + '.stdout')).write_text(stdout)
        (phase / (label + '.stderr')).write_text(stderr)
        command = self.outcomes.get(label, dict(status='exited', returncode=0))
        if label == self.mutate_after:
            Path(argv[0]).write_bytes(b'changed after execution')
        return command

    def run(self, priority=None):
        _, cases = qualification.selected_focus_plan(self.groups, priority or [])
        qualification.execute_focused_cases(
            cases, binaries=self.binaries, phase=self.phase, source_root=self.source,
            helper=dict(execute=self.execute, ANSI=re.compile(r'\x1b\[[0-9;]*m')),
            guard=self.guard, validate_dynamic=self.dynamic, auth=self.auth, ref=self.ref,
            result=self.result, save=self.save)
        return cases


class FocusExecutionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.fake = FakeExecution(Path(self.tmp.name))

    def test_exact_argv_labels_source_and_receipts_survive_priority_reordering(self):
        cases = self.fake.run([dict(group='tools', name='tools.test.second')])
        self.assertEqual([row['name'] for row in self.fake.result['focused_tests']],
                         [case[2] for case in cases])
        self.assertEqual([call[0] for call in self.fake.calls],
                         ['tools-01', 'tools-00', 'encoder-00', 'encoder-01', 'lua-00', 'lua-01'])
        for (group, index, name, _), (label, argv, source), row in zip(
                cases, self.fake.calls, self.fake.result['focused_tests'], strict=True):
            binary = self.fake.binaries[group['prepared_group']]
            self.assertEqual(argv, [binary['path'], '--dict-run-test', name])
            self.assertEqual(source, self.fake.source)
            self.assertEqual(row, dict(name=name, group=group['id'],
                command=dict(status='exited', returncode=0),
                stdout=self.fake.ref(self.fake.phase / (label + '.stdout')),
                stderr=self.fake.ref(self.fake.phase / (label + '.stderr')),
                outcome='passed', passed=True, binary=binary, exact_name_discovered=True,
                exact_name_discovery=dict(prepared_occurrences=1, unknown_name_rejected=False),
                runner_mode='--dict-run-test', full_suite_credit=False))

    def test_failed_assertions_are_retained_and_remaining_selectors_still_execute(self):
        self.fake.outcomes['encoder-01'] = dict(status='exited', returncode=1)
        self.fake.outcomes['lua-00'] = dict(status='timeout', returncode=None)
        self.fake.run()
        rows = self.fake.result['focused_tests']
        self.assertEqual(len(rows), 6)
        self.assertEqual([row['name'] for row in rows if not row['passed']],
                         ['encoder.test.second', 'lua.test.first'])
        self.assertFalse(all(row['passed'] for row in rows))
        self.assertTrue(all(not row['full_suite_credit'] for row in rows))
        self.assertTrue(next(row for row in rows if row['name'] == 'encoder.test.second')['exact_name_discovered'])
        self.assertIsNone(next(row for row in rows if row['name'] == 'lua.test.first')['exact_name_discovered'])
        self.assertEqual(self.fake.saved[-1]['focused_tests'], rows)

    def test_executor_exception_is_not_converted_to_a_test_pass_and_final_guard_runs(self):
        error = OSError('executor interrupted')
        self.fake.command_error = error
        with self.assertRaises(OSError) as caught:
            self.fake.run()
        self.assertIs(caught.exception, error)
        self.assertEqual(len(self.fake.calls), 1)
        self.assertEqual(self.fake.result['focused_tests'], [])
        self.assertEqual(self.fake.events[-1], ('guard', 2))

    def test_source_guard_failure_preserves_command_error_and_takes_priority(self):
        self.fake.command_error = OSError('command failure')
        error = RuntimeError('source changed')
        self.fake.guard_error = error; self.fake.fail_guard_at = 2
        with self.assertRaises(RuntimeError) as caught:
            self.fake.run()
        self.assertIs(caught.exception, error)
        self.assertEqual(self.fake.result['group_guard_failures'], [dict(
            group='encoder', guard_error=repr(error), command_error=repr(self.fake.command_error))])
        self.assertEqual(self.fake.saved[-1], self.fake.result)
        self.assertEqual(len(self.fake.calls), 1)

    def test_source_failure_after_success_keeps_assertion_but_blocks_remaining_groups(self):
        error = RuntimeError('source changed after group')
        self.fake.guard_error = error; self.fake.fail_guard_at = 2
        with self.assertRaises(RuntimeError) as caught:
            self.fake.run()
        self.assertIs(caught.exception, error)
        self.assertEqual(len(self.fake.calls), 2)
        self.assertTrue(all(row['passed'] for row in self.fake.result['focused_tests']))
        self.assertEqual(self.fake.result['group_guard_failures'], [dict(
            group='encoder', guard_error=repr(error), command_error=None)])

    def test_preexecution_source_dynamic_and_binary_refusals_never_launch(self):
        for kind in ('source', 'dynamic', 'binary'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as tmp:
                fake = FakeExecution(Path(tmp)); error = RuntimeError(kind + ' rejected')
                if kind == 'source':
                    fake.guard_error = error; fake.fail_guard_at = 1
                elif kind == 'dynamic':
                    fake.dynamic_error = error
                else:
                    fake.auth_error = error
                with self.assertRaises(RuntimeError) as caught:
                    fake.run()
                self.assertIs(caught.exception, error)
                self.assertEqual(fake.calls, [])
                self.assertEqual(fake.result['focused_tests'], [])
        code = Path(self.tmp.name) / 'qualification.py'
        code.write_bytes(b'original qualification code\n')
        descriptor = self.fake.ref(code)
        self.assertEqual(qualification.bound_qualification_tool(descriptor, self.fake.auth, code), code)
        other = Path(self.tmp.name) / 'other.py'; other.write_bytes(code.read_bytes())
        with self.assertRaises(AssertionError):
            qualification.bound_qualification_tool(self.fake.ref(other), self.fake.auth, code)
        linked = Path(self.tmp.name) / 'linked.py'; linked.symlink_to(code)
        with self.assertRaises(AssertionError):
            qualification.bound_qualification_tool(self.fake.ref(linked), self.fake.auth, linked)
        code.write_bytes(b'changed qualification code\n')
        with self.assertRaises(AssertionError):
            qualification.bound_qualification_tool(descriptor, self.fake.auth, code)
        self.assertEqual(self.fake.calls, [])
        self.assertEqual(self.fake.result['focused_tests'], [])

    def test_mutated_prepared_binary_is_rejected_after_its_assertion_and_guarded(self):
        self.fake.mutate_after = 'encoder-00'
        with self.assertRaisesRegex(AssertionError, 'prepared binary changed'):
            self.fake.run()
        self.assertEqual(len(self.fake.calls), 1)
        self.assertEqual(len(self.fake.result['focused_tests']), 1)
        self.assertTrue(self.fake.result['focused_tests'][0]['passed'])
        self.assertEqual(self.fake.events[-1], ('guard', 2))

    def test_cross_group_priority_reentry_preserves_each_exact_call_and_guard_boundary(self):
        cases = self.fake.run([dict(group='tools', name='tools.test.second'),
                              dict(group='lua', name='lua.test.first'),
                              dict(group='tools', name='tools.test.first')])
        self.assertEqual([call[0] for call in self.fake.calls],
                         ['tools-01', 'lua-00', 'tools-00', 'lua-01', 'encoder-00', 'encoder-01'])
        self.assertEqual([row['name'] for row in self.fake.result['focused_tests']],
                         [case[2] for case in cases])
        for index, event in enumerate(self.fake.events):
            if event[0] == 'dynamic':
                self.assertEqual(self.fake.events[index - 1][0], 'guard')
        self.assertEqual(self.fake.events[-1][0], 'guard')
        self.assertTrue(all(row['passed'] for row in self.fake.result['focused_tests']))



class DocumentPartitionPreparationTests(unittest.TestCase):
    def preparation_checks(self):
        def check(value):
            return qualification.validate_preparation_plan(value['cfg'], value['group_binding'],
                value['expect'], value['ordered_groups'], value['focus_cases'])
        return check

    def fixture(self):
        discovery = 'root.test.encoder root imports bundle-time presentation modules'
        modes = [
            ('encoder_compile', 'encoder_compile', ['presentation_compile.test.', 'encoder root imports bundle-time presentation modules'], [discovery]),
            ('encoder_document', 'encoder_document', ['presentation_document.test.', 'encoder root imports bundle-time presentation modules'], [discovery]),
            ('encoder_writer', 'encoder_writer', ['blob_builder.test.', 'encoder root imports bundle-time presentation modules'], [discovery]),
            ('encoder_support', 'encoder_support', ['font_scale.test.', 'hieroglyph_unicode.test.', 'language_source.test.', 'presentation_citations.test.', 'presentation_heading_anchors.test.', 'presentation_layout.test.', 'presentation_media.test.', 'redirect_source.test.', 'root.test.', 'table_style_profile.test.'], []),
            ('lua', 'lua_tests', [], []), ('closure', 'closure_tests', [], []), ('tools', 'blob_build_tests', [], []),
        ]
        selected = []; roots = []; inventory = {}; discoveries = {}
        for group_id, physical, filters, extra in modes:
            name = ('presentation_document' if group_id == 'encoder_document' else group_id) + '.test.selected'
            compiled = [name, *extra]
            selected.append(dict(id=group_id, prepared_group=group_id, physical_root=physical,
                test_names=[name], declaration_names=['selected'], compile_time_filtered=bool(filters),
                compile_filter_origin='fixed-normal-encoder-partition' if filters else 'normal-unfiltered-root',
                external_compile_filter_names=[], compile_filter_names=filters,
                compiled_only_discovery_names=extra, compiled_expected_occurrences=compiled,
                compiled_expected_count=len(compiled)))
            roots.append(dict(root=physical, expected_occurrences=[name]))
            inventory[group_id] = compiled; discoveries[group_id] = extra
        cfg, proof = binding(selected, '/fixture/source')
        cfg['execution_stage'] = 'full'
        proof.update(prepared_groups=[group['id'] for group in selected],
            compile_time_filtered_preparation=True, prepare_target='prepare-tests',
            prepared_relative_directory='bin/wikidict-tests', prepare_test_error_tracing=False,
            full_normal_partitioned_graph_required=True, prepared_discovery_filters=discoveries,
            prepared_expected_occurrences=inventory)
        ordered, cases = qualification.bound_focus_plan(cfg, proof, Path('/fixture/source'))
        return dict(cfg=cfg, group_binding=proof, ordered_groups=ordered, focus_cases=cases,
                    selected_ids=[group['id'] for group in selected],
                    prepared_names=tuple(group['id'] for group in selected),
                    expect=dict(expected=dict(logical_expected_groups=23, expected_groups=26,
                        logical_global_occurrences_equal_physical=True, groups=roots)))

    def test_document_partition_accepts_exact_seven_groups_and_rejects_mismatched_roles(self):
        code = self.preparation_checks()
        valid = self.fixture(); prepared_names, _, _ = code(valid)
        self.assertEqual(list(prepared_names),
            ['encoder_compile', 'encoder_document', 'encoder_writer', 'encoder_support', 'lua', 'closure', 'tools'])
        changes = [
            lambda value: value['ordered_groups'][1].update(physical_root='encoder_compile'),
            lambda value: value['ordered_groups'][1].update(compile_filter_names=['presentation_compile.test.']),
            lambda value: value['ordered_groups'][1].update(external_compile_filter_names=['selected']),
            lambda value: value['ordered_groups'][1].update(compile_time_filtered=False),
            lambda value: value['ordered_groups'][1].update(compiled_only_discovery_names=[]),
            lambda value: value['group_binding']['prepared_discovery_filters'].update(encoder_document=[]),
            lambda value: value['ordered_groups'][1].update(compiled_expected_occurrences=['presentation_document.test.selected'] * 2),
            lambda value: value['ordered_groups'][1].update(compiled_expected_count=99),
            lambda value: value['ordered_groups'][1].update(test_names=['foreign_root.test.selected']),
            lambda value: value['group_binding'].update(prepared_groups=[x for x in value['group_binding']['prepared_groups'] if x != 'encoder_document']),
        ]
        for change in changes:
            value = self.fixture(); change(value)
            with self.subTest(change=change), self.assertRaises(AssertionError):
                code(value)



class PreparationFailFastTests(unittest.TestCase):
    def execute_prefix(self, cfg, proof, expectation, commands, tools='compiler/tools'):
        # Run the real fresh-worker prefix up to prepared-output inspection.
        # Source/authentication/process ownership are tested by the ordinary job;
        # only subprocess execution and unrelated metadata loading are faked here.
        import ast
        from types import SimpleNamespace
        source = worker_role_ast()
        branches = [node.orelse for node in ast.walk(source) if isinstance(node, ast.If)
                    and ast.unparse(node.test) == "cfg['execution_stage'] == 'tail'"]
        self.assertEqual(len(branches), 1)
        block = branches[0]
        end = next(index for index, node in enumerate(block) if isinstance(node, ast.FunctionDef)
                   and node.name == 'prepare_focus_group')
        preparation = copy.deepcopy(block[end])
        inspect = next(index for index, node in enumerate(preparation.body) if isinstance(node, ast.Assign)
                       and any(isinstance(target, ast.Name) and target.id == 'prepared_dir' for target in node.targets))
        preparation.body = preparation.body[:inspect]
        calls = ast.parse('for group in ordered_groups:\n prepare_focus_group(group)\n').body
        argv_functions = [node for node in ast.walk(source) if isinstance(node, ast.FunctionDef)
                          and node.name == 'prepare_tests_argv']
        self.assertEqual(len(argv_functions), 1)
        stage_guards = [node for node in ast.walk(source) if isinstance(node, ast.Assert)
                        and isinstance(node.test, ast.Compare)
                        and ast.unparse(node.test.left) == "cfg['execution_stage']"]
        self.assertEqual(len(stage_guards), 1)
        prefix = compile(ast.Module(body=copy.deepcopy(argv_functions + stage_guards + block[:end] + [preparation] + calls),
                                    type_ignores=[]), str(qualification.__file__), 'exec')
        cfg = copy.deepcopy(cfg)
        cfg.setdefault('runtime_python', {'sha256': 'python'})
        cfg.setdefault('metadata_python_reuse', {'sha256': 'metadata'})
        cfg.setdefault('metadata_python_expected', 8)
        cfg.setdefault('python_bin', '/fixture/python')
        ordered, cases = qualification.bound_focus_plan(cfg, proof, Path(proof['cwd']))
        metadata = dict(current_manifest=cfg['private_manifest'], runtime_python=cfg['runtime_python'],
                        current_execution_required=True, dependency_files={})
        result = dict(phases=[], compiles=[])
        def read(descriptor):
            self.assertEqual(descriptor, cfg['metadata_python_reuse'])
            return metadata
        def execute(label, argv):
            commands.append((label, argv))
            result['phases'].append(dict(name=label, command=dict(argv=argv, status='exited', returncode=0)))
            if label == 'reviewed-language-aliases':
                return ('Ran ' + str(cfg['metadata_python_expected']) + ' tests in 0.001s\nOK\n', '')
            return ('', '')
        def execute_outcome(label, argv):
            so, se = execute(label, argv)
            return result['phases'][-1]['command'], so, se
        def unexpected_auth(value):
            self.fail('unrelated metadata dependency unexpectedly accessed: ' + repr(value))
        compiler = Path('/fixture/zig')
        with tempfile.TemporaryDirectory() as tmp:
            namespace = dict(qualification_build_argv=qualification.qualification_build_argv,
                qualification_source_key=qualification.qualification_source_key,
                cfg=cfg, group_binding=proof, expect=expectation,
                ordered_groups=ordered, focus_cases=cases, Path=Path, re=re,
                private=Path(proof['cwd']), private_manifest={tools + '/test_reviewed_language_aliases.py': {}}, read=read, auth=unexpected_auth,
                execute=execute, execute_outcome=execute_outcome,
                require_ordinary_preparation_compile_failure=qualification.require_ordinary_preparation_compile_failure, save=lambda: None, result=result, out=Path(tmp),
                args=SimpleNamespace(compiler=compiler), cache=Path('/fixture/cache'),
                validate_preparation_plan=qualification.validate_preparation_plan,
                focused_encoder_preparation=qualification.focused_encoder_preparation,
                w=dict(ANSI=re.compile(r'\x1b\[[0-9;]*m'),
                       native_build_argv=lambda args, cache: [str(args.compiler), 'build', 'test', '-j1']))
            exec(prefix, namespace)
            return namespace

    def fixture(self):
        value = DocumentPartitionPreparationTests().fixture()
        # Match the real run's tools-first priority while keeping document later.
        value['group_binding']['focus_priority'] = [dict(group='tools', name='tools.test.selected')]
        return value['cfg'], value['group_binding'], value['expect']

    def test_nonfirst_missing_document_discovery_launches_zero_commands(self):
        cfg, proof, expectation = self.fixture()
        ordered, _ = qualification.bound_focus_plan(cfg, proof, Path(proof['cwd']))
        self.assertGreater([group['id'] for group in ordered].index('encoder_document'), 0)
        del proof['prepared_discovery_filters']['encoder_document']
        commands = []
        with self.assertRaises(AssertionError):
            self.execute_prefix(cfg, proof, expectation, commands)
        self.assertEqual(commands, [])

    def test_other_nonfirst_mismatches_launch_zero_commands(self):
        for defect in ('root', 'filters', 'selected', 'counter', 'count'):
            cfg, proof, expectation = self.fixture()
            group = cfg['groups'][4]  # lua follows tools and all encoder groups
            if defect == 'root': group['physical_root'] = 'closure_tests'
            elif defect == 'filters': group['external_compile_filter_names'] = ['selected']
            elif defect == 'selected': group['test_names'] = ['foreign.test.selected']
            elif defect == 'counter': group['compiled_expected_occurrences'] *= 2
            else: group['compiled_expected_count'] += 1
            proof['groups'] = copy.deepcopy(cfg['groups'])
            commands = []
            with self.subTest(defect=defect), self.assertRaises(AssertionError):
                self.execute_prefix(cfg, proof, expectation, commands)
            self.assertEqual(commands, [])

    def test_good_plan_keeps_all_preparation_labels_and_arguments(self):
        cfg, proof, expectation = self.fixture(); commands = []
        result = self.execute_prefix(cfg, proof, expectation, commands)
        ordered, _ = qualification.bound_focus_plan(cfg, proof, Path(proof['cwd']))
        self.assertEqual([label for label, _ in commands], ['reviewed-language-aliases'] +
                         ['focused-prepare-' + group['id'] for group in ordered])
        self.assertEqual(commands[0][1], ['/fixture/python/python3', '-B', 'compiler/tools/test_reviewed_language_aliases.py'])
        for (_, argv), group in zip(commands[1:], ordered, strict=True):
            self.assertEqual(argv[:4], ['/fixture/zig', 'build', 'prepare-tests', '-j2'])
            self.assertEqual(argv[-1], '-Dprepare-test-group=' + group['id'])
            self.assertEqual(argv[4], '--prefix')
        self.assertEqual(result['prepared_names'], tuple(group['id'] for group in cfg['groups']))
        self.assertEqual(result['prepare_discovery'], proof['prepared_discovery_filters'])
        self.assertIs(result['result']['metadata_python']['command'], result['result']['phases'][0])
        self.assertEqual([phase['name'] for phase in result['result']['phases']], [label for label, _ in commands])

    def test_retained_graph_uses_its_original_reviewed_alias_script(self):
        cfg, proof, expectation = self.fixture(); commands = []
        self.execute_prefix(cfg, proof, expectation, commands, tools='tools')
        self.assertEqual(commands[0][1], ['/fixture/python/python3', '-B', 'tools/test_reviewed_language_aliases.py'])



class SupportedRootSubsetTests(unittest.TestCase):
    def fixture(self, selected):
        cfg, proof, expectation = PreparationFailFastTests().fixture()
        cfg['groups'] = [group for group in cfg['groups'] if group['id'] in selected]
        self.bind_selection(cfg, proof)
        return cfg, proof, expectation

    def bind_selection(self, cfg, proof):
        proof['groups'] = copy.deepcopy(cfg['groups'])
        names = [name for group in cfg['groups'] for name in group['test_names']]
        cfg['focused_expected'] = proof['total_selected'] = len(names)
        cfg['focused_distinct_names'] = proof['total_distinct_selected'] = len(set(names))
        ids = [group['id'] for group in cfg['groups']]
        proof['prepared_groups'] = ids
        for key in ('prepared_discovery_filters', 'prepared_expected_occurrences'):
            proof[key] = {name: value for name, value in proof[key].items() if name in ids}
        proof['focus_priority'] = [item for item in proof.get('focus_priority', []) if item['group'] in ids]

    def execute(self, cfg, proof, expectation, commands):
        return PreparationFailFastTests().execute_prefix(cfg, proof, expectation, commands)

    def test_single_supported_root_prepares_only_its_normal_artifact(self):
        cfg, proof, expectation = self.fixture(['encoder_compile'])
        commands = []; result = self.execute(cfg, proof, expectation, commands)
        self.assertEqual([name for name, _ in commands],
                         ['reviewed-language-aliases', 'focused-prepare-encoder_compile'])
        self.assertEqual(result['prepared_names'], ('encoder_compile',))
        self.assertEqual(result['prepare_filters'], {'encoder_compile': []})
        self.assertEqual(result['prepare_discovery'], {'encoder_compile':
            ['root.test.encoder root imports bundle-time presentation modules']})
        self.assertEqual(commands[1][1][-1], '-Dprepare-test-group=encoder_compile')
        self.assertEqual(cfg['execution_stage'], 'full')
        self.assertTrue(proof['full_normal_partitioned_graph_required'])
        self.assertEqual(proof['carried_count'], 0)

    def test_subset_rejects_unknown_duplicate_reordered_and_wrong_bound_roots(self):
        for defect in ('unknown', 'duplicate', 'order', 'prepared', 'filter', 'discovery', 'counter', 'full-graph'):
            cfg, proof, expectation = self.fixture(['encoder_compile', 'lua'])
            if defect == 'unknown': cfg['groups'][1]['id'] = 'unknown'
            elif defect == 'duplicate': cfg['groups'][1] = copy.deepcopy(cfg['groups'][0])
            elif defect == 'order': cfg['groups'].reverse()
            elif defect == 'prepared': cfg['groups'][1]['prepared_group'] = 'encoder_compile'
            elif defect == 'filter': cfg['groups'][1]['external_compile_filter_names'] = ['selected']
            elif defect == 'discovery': cfg['groups'][0]['compiled_only_discovery_names'] = []
            elif defect == 'counter': cfg['groups'][1]['compiled_expected_occurrences'] *= 2
            else: proof['full_normal_partitioned_graph_required'] = False
            self.bind_selection(cfg, proof)
            commands = []
            with self.subTest(defect=defect), self.assertRaises(AssertionError):
                self.execute(cfg, proof, expectation, commands)
            self.assertEqual(commands, [])

    def test_subset_priority_and_complete_plan_keep_normal_preparation_order(self):
        cfg, proof, expectation = self.fixture(['encoder_compile', 'tools'])
        commands = []; result = self.execute(cfg, proof, expectation, commands)
        self.assertEqual(result['prepared_names'], ('encoder_compile', 'tools'))
        self.assertEqual([name for name, _ in commands],
                         ['reviewed-language-aliases', 'focused-prepare-tools', 'focused-prepare-encoder_compile'])
        cfg, proof, expectation = PreparationFailFastTests().fixture()
        commands = []; result = self.execute(cfg, proof, expectation, commands)
        self.assertEqual(result['prepared_names'], tuple(group['id'] for group in cfg['groups']))
        self.assertEqual([name for name, _ in commands], ['reviewed-language-aliases',
            'focused-prepare-tools', 'focused-prepare-encoder_compile', 'focused-prepare-encoder_document',
            'focused-prepare-encoder_writer', 'focused-prepare-encoder_support',
            'focused-prepare-lua', 'focused-prepare-closure'])



class RepositoryRootBindingTests(unittest.TestCase):
    def fixture(self, base, tools='tools'):
        root = base / 'checkout'; (root / tools).mkdir(parents=True)
        helper = root / tools / 'build_resource_limits.py'; helper.write_bytes(b'qualified helper bytes')
        descriptor = FakeExecution.ref(helper)
        inputs = {tools + '/' + name: dict(reference=dict(path=str(root / tools / name))) for name in
                  ('build_watchdog_guardian.py', 'build_disk_limits.py', 'extraction_cache.py')}
        inputs[tools + '/build_resource_limits.py'] = dict(reference=copy.deepcopy(descriptor))
        return root, helper, descriptor, inputs

    def auth(self, descriptor):
        self.assertEqual(FakeExecution.ref(Path(descriptor['path'])), descriptor)
        return Path(descriptor['path'])

    def test_source_member_selection_requires_one_explicit_layout(self):
        for old,new in (('tools/test_reviewed_language_aliases.py','compiler/tools/test_reviewed_language_aliases.py'),
                        ('tools/ffi_integration_test.c','compiler/tools/ffi_integration_test.c'),
                        ('src/ffi/dict.h','renderer/src/ffi/dict.h')):
            for chosen in (old,new):
                with self.subTest(chosen=chosen):
                    self.assertEqual(qualification.qualification_source_key({chosen:{}},old),chosen)
            for inventory in ({},{old:{},new:{}}):
                with self.subTest(inventory=inventory),self.assertRaises(AssertionError):
                    qualification.qualification_source_key(inventory,old)

    def test_authenticated_helper_locates_checkout_independent_of_tool_or_working_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            for name, tools in (('first location', 'tools'), ('second-checkout', 'compiler/tools')):
                root, helper, descriptor, inputs = self.fixture(base / name, tools)
                self.assertEqual(qualification.bound_repository_root(descriptor, inputs, self.auth), root)
                self.assertEqual(helper.read_bytes(), b'qualified helper bytes')
                self.assertNotEqual(root, Path.cwd())

    def test_current_layout_rejects_mixed_or_misdirected_canonical_inputs(self):
        for defect in ('duplicate-helper', 'legacy-companion', 'wrong-root'):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary).resolve()
                root, helper, descriptor, inputs = self.fixture(base, 'compiler/tools')
                if defect == 'duplicate-helper':
                    inputs['tools/build_resource_limits.py'] = copy.deepcopy(inputs['compiler/tools/build_resource_limits.py'])
                elif defect == 'legacy-companion':
                    inputs['tools/extraction_cache.py'] = inputs.pop('compiler/tools/extraction_cache.py')
                else:
                    inputs['compiler/tools/extraction_cache.py']['reference']['path'] = str(base / 'other/compiler/tools/extraction_cache.py')
                with self.assertRaises(AssertionError):
                    qualification.bound_repository_root(descriptor, inputs, self.auth)

    def test_changed_helper_or_disagreeing_canonical_paths_are_rejected(self):
        for defect in ('bytes', 'relative', 'filename', 'parent', 'symlink', 'canonical-helper', 'canonical-other'):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary).resolve(); root, helper, descriptor, inputs = self.fixture(base)
                if defect == 'bytes': helper.write_bytes(b'changed helper bytes')
                elif defect == 'relative':
                    import os
                    descriptor['path'] = os.path.relpath(helper, Path.cwd())
                    inputs['tools/build_resource_limits.py']['reference'] = copy.deepcopy(descriptor)
                elif defect in ('filename', 'parent', 'symlink'):
                    replacement = root / ('tools/renamed.py' if defect == 'filename' else
                                          'helpers/build_resource_limits.py' if defect == 'parent' else
                                          'alias/tools/build_resource_limits.py')
                    replacement.parent.mkdir(parents=True, exist_ok=True)
                    if defect == 'symlink': replacement.symlink_to(helper)
                    else: replacement.write_bytes(helper.read_bytes())
                    descriptor = FakeExecution.ref(replacement)
                    inputs['tools/build_resource_limits.py']['reference'] = copy.deepcopy(descriptor)
                elif defect == 'canonical-helper':
                    other = base / 'other/tools/build_resource_limits.py'; other.parent.mkdir(parents=True)
                    other.write_bytes(helper.read_bytes())
                    inputs['tools/build_resource_limits.py']['reference'] = FakeExecution.ref(other)
                else:
                    inputs['tools/extraction_cache.py']['reference']['path'] = str(base / 'other/tools/extraction_cache.py')
                with self.assertRaises(AssertionError):
                    qualification.bound_repository_root(descriptor, inputs, self.auth)


class BlobEncoderPreparationTests(unittest.TestCase):
    def fixture(self):
        cfg, proof, expectation = PreparationFailFastTests().fixture()
        name = 'presentation_codec.test.fixture round trip'
        root_test = 'blob_root.test.blob encoder root imports data-only presentation codecs'
        group = dict(id='blob_encoder', prepared_group='blob_encoder', physical_root='blob_encoder_tests',
            test_names=[name], declaration_names=['fixture round trip'], compile_time_filtered=False,
            compile_filter_origin='normal-unfiltered-root', external_compile_filter_names=[],
            compile_filter_names=[], compiled_only_discovery_names=[],
            compiled_expected_occurrences=[name, root_test], compiled_expected_count=2)
        cfg['groups'].insert(4, group)
        proof['prepared_discovery_filters']['blob_encoder'] = []
        proof['prepared_expected_occurrences']['blob_encoder'] = [name, root_test]
        expectation['expected']['groups'].append(dict(root='blob_encoder_tests', expected_occurrences=[name, root_test]))
        SupportedRootSubsetTests().bind_selection(cfg, proof)
        return cfg, proof, expectation

    def test_blob_encoder_uses_unfiltered_normal_root_and_counts_discovery_once(self):
        cfg, proof, expectation = self.fixture(); commands = []
        result = PreparationFailFastTests().execute_prefix(cfg, proof, expectation, commands)
        self.assertEqual(result['prepared_names'], ('encoder_compile', 'encoder_document', 'encoder_writer',
                         'encoder_support', 'blob_encoder', 'lua', 'closure', 'tools'))
        self.assertEqual(result['prepare_filters']['blob_encoder'], [])
        self.assertEqual(result['prepare_discovery']['blob_encoder'], [])
        self.assertEqual([label for label, _ in commands], ['reviewed-language-aliases', 'focused-prepare-tools',
            'focused-prepare-encoder_compile', 'focused-prepare-encoder_document', 'focused-prepare-encoder_writer',
            'focused-prepare-encoder_support', 'focused-prepare-blob_encoder', 'focused-prepare-lua', 'focused-prepare-closure'])
        blob_argv = next(argv for label, argv in commands if label == 'focused-prepare-blob_encoder')
        self.assertEqual(blob_argv[-1], '-Dprepare-test-group=blob_encoder')
        self.assertFalse(any(arg.startswith('-Dprepare-test-filter') for arg in blob_argv))
        for defect in ('physical-root', 'filter', 'discovery', 'counter', 'count', 'order'):
            cfg, proof, expectation = self.fixture(); group = cfg['groups'][4]
            if defect == 'physical-root': group['physical_root'] = 'encoder_support'
            elif defect == 'filter': group['compile_filter_names'] = ['presentation_codec.test.']
            elif defect == 'discovery':
                discovery = group['compiled_expected_occurrences'][-1]
                group['compiled_only_discovery_names'] = [discovery]
                proof['prepared_discovery_filters']['blob_encoder'] = [discovery]
            elif defect == 'counter':
                group['compiled_expected_occurrences'].append(group['compiled_expected_occurrences'][-1])
                group['compiled_expected_count'] += 1
                proof['prepared_expected_occurrences']['blob_encoder'] = list(group['compiled_expected_occurrences'])
            elif defect == 'count': group['compiled_expected_count'] += 1
            else: cfg['groups'][3], cfg['groups'][4] = cfg['groups'][4], cfg['groups'][3]
            SupportedRootSubsetTests().bind_selection(cfg, proof)
            commands = []
            with self.subTest(defect=defect), self.assertRaises(AssertionError):
                PreparationFailFastTests().execute_prefix(cfg, proof, expectation, commands)
            self.assertEqual(commands, [])


class RetiredContinuationTests(unittest.TestCase):
    def test_retired_support_tail_refuses_before_commands_and_full_still_prepares(self):
        cfg, proof, expectation = PreparationFailFastTests().fixture()
        cfg['execution_stage'] = 'support-tail'
        cfg['support_reuse'] = {'historical_metadata_must_not_be_consumed': True}
        commands = []
        with self.assertRaises(AssertionError):
            PreparationFailFastTests().execute_prefix(cfg, proof, expectation, commands)
        self.assertEqual(commands, [])
        cfg['execution_stage'] = 'full'
        commands = []
        result = PreparationFailFastTests().execute_prefix(cfg, proof, expectation, commands)
        ordered, _ = qualification.bound_focus_plan(cfg, proof, Path(proof['cwd']))
        self.assertEqual([name for name, _ in commands], ['reviewed-language-aliases'] +
                         ['focused-prepare-' + group['id'] for group in ordered])
        self.assertEqual(result['prepared_names'], tuple(group['id'] for group in cfg['groups']))


class CurrentTailRecoveryTests(unittest.TestCase):
    def fixture(self):
        # Execute the actual tail branch, with file authentication retained and
        # closed native inventories substituted at their existing API boundary.
        import ast
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        cfg, proof, expectation = PreparationFailFastTests().fixture()
        cfg.update(execution_stage='full', full_native_expected=7, groups_expected=26,
            reader_expected_checks=50, bundle_expected_checks=182, metadata_python_expected=8)
        for name in ('retained_source', 'retained_cache', 'compiler', 'runtime_python', 'python_bin',
                     'canonical_runtime_inputs', 'runtime_helpers', 'dynamic_helper', 'dynamic_state',
                     'helper', 'expectation', 'focused_groups', 'metadata_python_reuse', 'install_root'):
            cfg[name] = {'bound': name}
        prior_cfg = copy.deepcopy(cfg); cfg['execution_stage'] = 'tail'
        cfg['tail_reuse'] = dict(configuration='configuration', result='result', closure='closure', release='release')
        ordered, cases = qualification.bound_focus_plan(cfg, proof, Path(proof['cwd']))
        phase_names = ['reviewed-language-aliases', 'focused-prepare-tools',
            'focused-prepare-encoder_compile', 'focused-prepare-encoder_document',
            'focused-prepare-encoder_writer', 'focused-prepare-encoder_support',
            'focused-prepare-lua', 'focused-prepare-closure',
            'filtered-discovery-encoder_compile-0', 'filtered-discovery-encoder_document-0',
            'filtered-discovery-encoder_writer-0', 'cli-ffi-install', 'full-native-suite', 'bundle-pipeline']
        output = root / 'stdout'; output.write_text('ok root.test.required\nREADER_INTEGRATION_PASS checks=50\n')
        errors = root / 'stderr'; errors.write_text('')
        binary = root / 'binary'; binary.write_bytes(b'authenticated installed and prepared fixture')
        stdout, stderr, compiled = map(FakeExecution.ref, (output, errors, binary))
        command = dict(status='exited', returncode=0, argv=['zig', 'build'])
        phases = [dict(name=name, command=copy.deepcopy(command), stdout=stdout, stderr=stderr) for name in phase_names]
        report = dict(status='passed', cases=[dict(width=80, checks=['check'] * 68)])
        marks = dict(reader_checks=50, child_report='report', child_summary=dict(status='passed'),
                     marker_lines=[dict(line=2, text='READER_INTEGRATION_PASS checks=50')])
        prior = dict(phases=phases, full_native_pass=True, bundle_pipeline_pass=True,
            cli_ffi_install_pass=True, bundle_pass=False, reader_markers=copy.deepcopy(marks),
            installed={'bin/wikidict': compiled}, metadata_python=dict(passed=True, executed=8),
            focused_tests=[dict(name=case[2], passed=True, command=copy.deepcopy(command),
                                stdout=stdout, stderr=stderr, binary=compiled) for case in cases])
        closed = dict(result='result', configuration='configuration', source_guard=True,
            cleanup_proven=True, locks_free=True, full_native_pass=True, bundle_pipeline_pass=True,
            full_actual_passed_tests=7, required_test_occurrences=1,
            reader_markers=copy.deepcopy(marks), installed=copy.deepcopy(prior['installed']))
        released = dict(closure='closure', cleanup_proven=True, source_guard=True, locks_free=True)
        objects = dict(configuration=prior_cfg, result=prior, closure=closed, release=released, report=report)
        expectation['required_test_counts'] = {'required': 1}
        marker_calls = []; dynamic_calls = []; commands = []
        native = dict(passed=True, status_count=7); grouped = dict(passed=True)
        def auth(descriptor):
            self.assertEqual(FakeExecution.ref(descriptor['path']), descriptor)
            return Path(descriptor['path'])
        def markers(text, contract, actual_report):
            marker_calls.append((text, contract, actual_report))
            self.assertEqual(text.splitlines().count('READER_INTEGRATION_PASS checks=50'), 1)
            self.assertEqual(contract, dict(observed_child_summary=marks['child_summary'],
                child_report=marks['child_report'], marker_lines=marks['marker_lines']))
            self.assertIs(actual_report, report)
            return copy.deepcopy(marks)
        def old_markers(*args):
            self.fail('tail used the obsolete 47-check reader validator')
        def execute(*args):
            commands.append(args); self.fail('tail validation launched a command')
        namespace = dict(bound_captured_source_fingerprint=qualification.bound_captured_source_fingerprint,
            captured_fingerprint=None, cfg=cfg, group_binding=proof, expect=expectation, private=Path(proof['cwd']),
            focus_cases=cases, read=objects.__getitem__, auth=auth,
            bound_focus_plan=qualification.bound_focus_plan,
            validate_preparation_plan=qualification.validate_preparation_plan,
                focused_encoder_preparation=qualification.focused_encoder_preparation,
            w=dict(ANSI=re.compile(r'\x1b\[[0-9;]*m'), STATUS=re.compile(r'^(ok) (.+)$', re.M),
                   classify=lambda so, se, standalone: native),
            inv=dict(validate_grouped=lambda helper, expected, so, se: grouped),
            markers=markers, ev=dict(markers=old_markers), ds=object(),
            dynamic=dict(validate=lambda state, **kwargs: dynamic_calls.append((state, kwargs))),
            result={}, save=lambda: None, execute=execute)
        source = worker_role_ast()
        branches = [node.body for node in ast.walk(source) if isinstance(node, ast.If)
                    and ast.unparse(node.test) == "cfg['execution_stage'] == 'tail'"]
        self.assertEqual(len(branches), 1)
        code = compile(ast.Module(body=branches[0], type_ignores=[]), str(qualification.__file__), 'exec')
        return dict(namespace=namespace, code=code, objects=objects, marker_calls=marker_calls,
                    dynamic_calls=dynamic_calls, commands=commands, source=source, marks=marks)

    def add_failed_bundle(self, value, returncode=1):
        prior = value['objects']['result']
        row = copy.deepcopy(prior['phases'][-1]); row['name'] = 'bundle'
        row['command']['returncode'] = returncode
        prior['phases'].append(row)
        prior.update(passed=False, status='failed', error="AssertionError('bundle contract failed')")
        return row

    def test_current_partitioned_tail_uses_the_same_reader_checker_as_full(self):
        import ast
        # A terminal command can fail itself or return zero before its required
        # bundle marker fails. Neither grants successful bundle credit.
        for returncode in (None, 1, 0):
            with self.subTest(trailing_bundle_returncode=returncode):
                value = self.fixture(); namespace = value['namespace']
                failed = self.add_failed_bundle(value, returncode) if returncode is not None else None
                prior_before = copy.deepcopy(value['objects']['result'])
                exec(value['code'], namespace)
                result = namespace['result']
                self.assertTrue(result['full_native_pass'] and result['bundle_pipeline_pass'])
                self.assertFalse(result['focused_current_execution'] or result['full_native_current_execution'])
                self.assertFalse(result.get('bundle_pass', False))
                self.assertEqual(result['focused_inherited_count'], 7)
                self.assertEqual(result['reader_markers'], value['marks'])
                self.assertEqual(value['objects']['result'], prior_before)
                if failed is None:
                    self.assertNotIn('inherited_failed_bundle', result)
                else:
                    self.assertEqual(result['inherited_failed_bundle'], dict(phase=failed,
                        status='failed', error=prior_before['error'], passed=False, current_execution=False))
                self.assertEqual(len(value['marker_calls']), 1)
                self.assertEqual(len(value['dynamic_calls']), 1)
                self.assertEqual(value['commands'], [])
                # The full path now delegates reader verification to its assessor.
                import inspect
                assessor = ast.parse(inspect.getsource(qualification.assess_completed_native_full))
                assignments = [node for node in ast.walk(assessor) if isinstance(node, ast.Assign)
                               and any(ast.unparse(target) == "result['reader_markers']" for target in node.targets)]
                self.assertEqual(len(assignments), 1)
                text, contract, report = value['marker_calls'][0]
                namespace.update(text=text, contract=contract, report=report, result={})
                exec(compile(ast.Module(body=assignments, type_ignores=[]), '<actual full reader call>', 'exec'), namespace)
                self.assertEqual(namespace['result']['reader_markers'], result['reader_markers'])
                self.assertEqual(value['marker_calls'][0], value['marker_calls'][1])

    def test_current_tail_rejects_missing_extra_and_reordered_phases(self):
        for defect in ('metadata', 'preparation', 'discovery', 'bundle-pipeline', 'extra',
                       'prepare-order', 'discovery-order', 'legacy-single-encoder',
                       'trailing-wrong-phase', 'trailing-duplicate', 'trailing-running',
                       'trailing-unknown-status', 'trailing-missing-exit', 'trailing-passed',
                       'trailing-no-error', 'trailing-mutated-output'):
            value = self.fixture(); phases = value['objects']['result']['phases']
            if defect == 'metadata': del phases[0]
            elif defect == 'preparation': del phases[3]
            elif defect == 'discovery': del phases[9]
            elif defect == 'bundle-pipeline': phases.pop()
            elif defect == 'extra': phases.insert(2, copy.deepcopy(phases[1]))
            elif defect == 'prepare-order': phases[1], phases[2] = phases[2], phases[1]
            elif defect == 'discovery-order': phases[8], phases[9] = phases[9], phases[8]
            elif defect == 'legacy-single-encoder':
                phases[:] = [dict(phases[0], name='focused-prepare-encoder'), *phases[-3:]]
            else:
                failed = self.add_failed_bundle(value)
                if defect == 'trailing-wrong-phase': failed['name'] = 'cli-smoke'
                elif defect == 'trailing-duplicate': phases.append(copy.deepcopy(failed))
                elif defect == 'trailing-running': failed['command']['status'] = 'running'
                elif defect == 'trailing-unknown-status': failed['command']['status'] = 'unknown'
                elif defect == 'trailing-missing-exit': failed['command']['returncode'] = None
                elif defect == 'trailing-passed': value['objects']['result']['passed'] = True
                elif defect == 'trailing-no-error': value['objects']['result']['error'] = ''
                else: failed['stderr'] = dict(failed['stderr'], sha256='different')
            with self.subTest(defect=defect), self.assertRaises(AssertionError):
                exec(value['code'], value['namespace'])
            self.assertEqual(value['commands'], [])
            self.assertEqual(value['marker_calls'], [])
            self.assertEqual(value['dynamic_calls'], [])

    def test_current_tail_preserves_plan_source_count_cleanup_and_reader_guards(self):
        for defect in ('prior-stage', 'source', 'reader-count', 'metadata-count', 'discovery-map',
                       'compiled-inventory', 'cleanup', 'failed-command', 'full-count', 'grouped-inventory',
                       'required-name', 'binary-bytes', 'reader-receipt', 'reader-log'):
            value = self.fixture(); namespace = value['namespace']; objects = value['objects']
            if defect == 'prior-stage': objects['configuration']['execution_stage'] = 'tail'
            elif defect == 'source': objects['configuration']['private_source_binding'] = {'sha256': 'other'}
            elif defect == 'reader-count': objects['configuration']['reader_expected_checks'] = 47
            elif defect == 'metadata-count': objects['configuration']['metadata_python_expected'] = 7
            elif defect == 'discovery-map': del namespace['group_binding']['prepared_discovery_filters']['encoder_document']
            elif defect == 'compiled-inventory': namespace['group_binding']['prepared_expected_occurrences']['encoder_document'] *= 2
            elif defect == 'cleanup': objects['closure']['cleanup_proven'] = False
            elif defect == 'failed-command': objects['result']['phases'][3]['command']['returncode'] = 1
            elif defect == 'full-count': namespace['w']['classify'] = lambda *args, **kwargs: dict(passed=True, status_count=6)
            elif defect == 'grouped-inventory': namespace['inv']['validate_grouped'] = lambda *args: dict(passed=False)
            elif defect == 'required-name': namespace['expect']['required_test_counts'] = {'other': 1}
            elif defect == 'binary-bytes': Path(objects['result']['installed']['bin/wikidict']['path']).write_bytes(b'changed')
            elif defect == 'reader-receipt':
                objects['result']['reader_markers']['reader_checks'] = 47
                objects['closure']['reader_markers']['reader_checks'] = 47
            else:
                path = Path(objects['result']['phases'][0]['stdout']['path'])
                path.write_text(path.read_text().replace('checks=50', 'checks=47'))
                descriptor = FakeExecution.ref(path)
                for row in objects['result']['phases'] + objects['result']['focused_tests']:
                    row['stdout'] = descriptor
            with self.subTest(defect=defect), self.assertRaises(AssertionError):
                exec(value['code'], namespace)
            self.assertEqual(value['commands'], [])
            self.assertEqual(value['dynamic_calls'], [])



class InterleavedPreparationTests(unittest.TestCase):
    def plan(self):
        cfg, proof, expectation = PreparationFailFastTests().fixture()
        # Two obligations in the first priority group prove batch completion on failure.
        tools = next(group for group in cfg['groups'] if group['id'] == 'tools')
        tools['test_names'].append('tools.test.second')
        tools['declaration_names'].append('second')
        tools['compiled_expected_occurrences'].append('tools.test.second')
        tools['compiled_expected_count'] += 1
        proof['prepared_expected_occurrences']['tools'] = list(tools['compiled_expected_occurrences'])
        next(root for root in expectation['expected']['groups'] if root['root'] == 'blob_build_tests')['expected_occurrences'].append('tools.test.second')
        SupportedRootSubsetTests().bind_selection(cfg, proof)
        return cfg, proof, expectation

    def run_fresh(self, cfg, proof, expectation, *, failure=None, discovery_failure=False, extra_binary=False,
                  mutate_previous_on_prepare=False, mutate_earlier_on_last_focus=False,
                  compile_failures=(), unsafe_compile_outcome=None, compile_guard_failure=False,
                  compile_guard_stage=None, mutate_selected_on_normal_prepare=False):
        import ast
        import os
        from types import SimpleNamespace
        root = Path(self.tmp.name)
        out = root / 'commands'; out.mkdir()
        phase = out / 'fixed'; phase.mkdir()
        cfg = copy.deepcopy(cfg)
        cfg.update(runtime_python={'sha256': 'python'}, metadata_python_reuse={'sha256': 'metadata'},
                   metadata_python_expected=8, python_bin='/fixture/python')
        ordered, cases = qualification.bound_focus_plan(cfg, proof, Path(proof['cwd']))
        result = dict(phases=[], compiles=[], focused_tests=[])
        events = []; snapshots = []
        def auth(descriptor):
            self.assertEqual(FakeExecution.ref(descriptor['path']), descriptor)
            return Path(descriptor['path'])
        def read(descriptor):
            self.assertEqual(descriptor, cfg['metadata_python_reuse'])
            return dict(current_manifest=cfg['private_manifest'], runtime_python=cfg['runtime_python'],
                        current_execution_required=True, dependency_files={})
        def execute(label, argv):
            events.append(label)
            if label.startswith('focused-prepare-'):
                stage = label.removeprefix('focused-prepare-')
                prepared = next(arg.removeprefix('-Dprepare-test-group=') for arg in argv
                                if arg.startswith('-Dprepare-test-group='))
                prefix = Path(argv[argv.index('--prefix') + 1]) / proof['prepared_relative_directory']
                prefix.mkdir(parents=True, exist_ok=True)
                binary = prefix / prepared
                if stage not in compile_failures:
                    binary.write_bytes(stage.encode()); binary.chmod(0o755)
                if mutate_selected_on_normal_prepare and stage == 'tools':
                    selected = out / 'selected-tools' / proof['prepared_relative_directory'] / 'tools'
                    selected.write_bytes(b'changed selected binary during normal preparation')
                previous = [path for path in prefix.iterdir() if path != binary]
                if mutate_previous_on_prepare and previous:
                    previous[0].write_bytes(b'changed by subsequent preparation')
                if extra_binary:
                    unwanted = prefix / 'unselected'; unwanted.write_bytes(b'unselected'); unwanted.chmod(0o755)
            failed_compile = label.startswith('focused-prepare-') and label.removeprefix('focused-prepare-') in compile_failures
            command = dict(status='exited', returncode=int(failed_compile), argv=argv)
            so, se = '', self.compile_diagnostic() if failed_compile else ''
            if failed_compile and unsafe_compile_outcome is not None:
                status, code, so, se = unsafe_compile_outcome
                command.update(status=status, returncode=code)
            result['phases'].append(dict(name=label, command=command))
            if discovery_failure and label.startswith('filtered-discovery-'):
                raise OSError('discovery refused')
            if label == 'reviewed-language-aliases':
                return ('Ran 8 tests in 0.001s\nOK\n', '')
            return (so, se)
        def guard():
            if compile_guard_failure and events[-1].startswith('focused-prepare-') and (
                    compile_guard_stage is None or events[-1] == 'focused-prepare-' + compile_guard_stage):
                if isinstance(compile_guard_failure, BaseException):
                    raise compile_guard_failure
                raise OSError('source guard after compilation')
        def execute_outcome(label, argv):
            so, se = execute(label, argv)
            guard()
            return result['phases'][-1]['command'], so, se
        def focused(directory, label, argv, source):
            name = argv[-1]; events.append('focus:' + name)
            if mutate_earlier_on_last_focus and name == cases[-1][2]:
                prefix = out / ('selected-tools' if cfg.get('filtered_tools_only') else 'prepared-tests') / proof['prepared_relative_directory']
                earlier = next(path for path in prefix.iterdir() if path != Path(argv[0]))
                earlier.write_bytes(b'changed by last focused case')
            self.assertEqual(source, Path(proof['cwd']))
            (directory / (label + '.stdout')).write_text('ordinary focused outcome\n')
            (directory / (label + '.stderr')).write_text('')
            return dict(status='exited', returncode=1 if name == failure else 0)
        tree = worker_role_ast()
        branches = [node.orelse for node in ast.walk(tree) if isinstance(node, ast.If)
                    and ast.unparse(node.test) == "cfg['execution_stage'] == 'tail'"]
        self.assertEqual(len(branches), 1)
        branch = branches[0]
        # The unique worker branch, not the closure owner's tail reconciliation.
        finish = next(index for index, node in enumerate(branch) if isinstance(node, ast.If)
                      and ast.unparse(node.test) == "cfg['execution_stage'] != 'focused-diagnostic'")
        argv_function = next(node for node in ast.walk(tree) if isinstance(node, ast.FunctionDef)
                             and node.name == 'prepare_tests_argv')
        # Native full-suite execution is the only replaced boundary; all preparation,
        # discovery, focus and qualification predicates above it are actual code.
        full_boundary = copy.deepcopy(branch[finish])
        full_boundary.body = ast.parse("result['fake_full_boundary_reached'] = True").body
        full_boundary.orelse = []
        code = compile(ast.Module(body=copy.deepcopy([argv_function] + branch[:finish] + [full_boundary]),
                                  type_ignores=[]), str(qualification.__file__), 'exec')
        namespace = dict(qualification_build_argv=qualification.qualification_build_argv,
            cfg=cfg, group_binding=proof, expect=expectation, ordered_groups=ordered,
            focus_cases=cases, private=Path(proof['cwd']), private_manifest={}, out=out, phase=phase,
            Path=Path, re=re, os=os, args=SimpleNamespace(compiler=Path('/fixture/zig')),
            cache=Path('/fixture/cache'), read=read, auth=auth, ref=FakeExecution.ref, execute=execute, execute_outcome=execute_outcome,
            require_ordinary_preparation_compile_failure=qualification.require_ordinary_preparation_compile_failure,
            result=result, save=lambda: snapshots.append(copy.deepcopy(result)), guard=guard,
            ds=object(), dynamic=dict(validate=lambda state: None),
            validate_preparation_plan=qualification.validate_preparation_plan,
                focused_encoder_preparation=qualification.focused_encoder_preparation,
            execute_focused_cases=qualification.execute_focused_cases,
            w=dict(ANSI=re.compile(r'\x1b\[[0-9;]*m'), execute=focused,
                   native_build_argv=lambda args, cache: [str(args.compiler), 'build', 'test', '-j1']))
        self.events, self.result, self.snapshots, self.namespace = events, result, snapshots, namespace
        exec(code, namespace)
        return result, events, cases

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_failed_first_group_retains_all_independent_outcomes_and_blocks_full(self):
        cfg, proof, expectation = self.plan()
        with self.assertRaisesRegex(AssertionError, 'focused_functional_failure'):
            self.run_fresh(cfg, proof, expectation, failure='tools.test.selected')
        ordered, cases = qualification.bound_focus_plan(cfg, proof, Path(proof['cwd']))
        expected = ['reviewed-language-aliases']
        for group in ordered:
            expected += ['focused-prepare-' + group['id']]
            expected += ['filtered-discovery-' + group['id'] + '-' + str(number)
                         for number, _ in enumerate(group['compiled_only_discovery_names'])]
            expected += ['focus:' + case[2] for case in cases if case[0]['id'] == group['id']]
        self.assertEqual(self.events, expected)
        self.assertEqual([row['name'] for row in self.result['focused_tests']],
                         [case[2] for case in cases])
        self.assertEqual([row['name'] for row in self.result['focused_tests'] if not row['passed']],
                         ['tools.test.selected'])
        self.assertEqual(self.result['focused_preparation_order'], [group['id'] for group in ordered])
        self.assertTrue(self.result['all_selected_executed'])
        self.assertFalse(self.result['focused_qualified'])
        self.assertNotIn('fake_full_boundary_reached', self.result)
        self.assertEqual(self.snapshots[-1], self.result)

    def test_all_pass_interleaves_exact_discovery_and_focus_then_reaches_full_once(self):
        cfg, proof, expectation = self.plan()
        result, events, cases = self.run_fresh(cfg, proof, expectation)
        self.assertEqual(events[:5], ['reviewed-language-aliases', 'focused-prepare-tools',
                         'focus:tools.test.selected', 'focus:tools.test.second', 'focused-prepare-encoder_compile'])
        ordered, _ = qualification.bound_focus_plan(cfg, proof, Path(proof['cwd']))
        expected = ['reviewed-language-aliases']
        for group in ordered:
            expected += ['focused-prepare-' + group['id']]
            expected += ['filtered-discovery-' + group['id'] + '-' + str(number)
                         for number, _ in enumerate(group['compiled_only_discovery_names'])]
            expected += ['focus:' + case[2] for case in cases if case[0]['id'] == group['id']]
        self.assertEqual(events, expected)
        self.assertEqual([row['name'] for row in result['focused_tests']], [case[2] for case in cases])
        self.assertEqual(len({(row['group'], row['name']) for row in result['focused_tests']}), len(cases))
        self.assertEqual(set(result['compiles'][0]['binaries']), set(proof['prepared_groups']))
        self.assertTrue(result['compiles'][0]['passed'] and result['all_selected_executed'] and
                        result['focused_qualified'] and result['fake_full_boundary_reached'])
        self.assertEqual(len(result['compiled_discovery']), 3)
        self.assertTrue(all(not row['semantic_focus_credit'] for row in result['compiled_discovery']))

    def test_cross_group_priority_reentry_preserves_global_cases_and_prepares_each_binary_once(self):
        cfg, proof, expectation = self.plan()
        proof['focus_priority'] = [dict(group='tools', name='tools.test.selected'),
                                   dict(group='lua', name='lua.test.selected'),
                                   dict(group='tools', name='tools.test.second')]
        result, events, cases = self.run_fresh(cfg, proof, expectation)
        self.assertEqual(events[:6], ['reviewed-language-aliases', 'focused-prepare-tools',
                         'focus:tools.test.selected', 'focused-prepare-lua',
                         'focus:lua.test.selected', 'focus:tools.test.second'])
        self.assertEqual(events.count('focused-prepare-tools'), 1)
        self.assertEqual([row['name'] for row in result['focused_tests']], [case[2] for case in cases])
        self.assertEqual(result['focused_preparation_order'][:2], ['tools', 'lua'])

    def test_discovery_failure_blocks_focus_later_preparation_and_full(self):
        cfg, proof, expectation = self.plan(); proof['focus_priority'] = []
        with self.assertRaisesRegex(OSError, 'discovery refused'):
            self.run_fresh(cfg, proof, expectation, discovery_failure=True)
        self.assertEqual(self.events, ['reviewed-language-aliases', 'focused-prepare-encoder_compile',
                         'filtered-discovery-encoder_compile-0'])
        self.assertEqual(self.result['focused_tests'], [])
        self.assertNotIn('fake_full_boundary_reached', self.result)

    def test_unselected_prepared_binary_refuses_before_any_focus(self):
        cfg, proof, expectation = self.plan()
        with self.assertRaises(AssertionError):
            self.run_fresh(cfg, proof, expectation, extra_binary=True)
        self.assertEqual(self.events, ['reviewed-language-aliases', 'focused-prepare-tools'])
        self.assertEqual(self.result['focused_tests'], [])
        self.assertNotIn('fake_full_boundary_reached', self.result)

    def test_later_preparation_mutation_refuses_before_current_discovery_or_focus(self):
        cfg, proof, expectation = self.plan()
        with self.assertRaises(AssertionError):
            self.run_fresh(cfg, proof, expectation, mutate_previous_on_prepare=True)
        self.assertEqual(self.events, ['reviewed-language-aliases', 'focused-prepare-tools',
                         'focus:tools.test.selected', 'focus:tools.test.second', 'focused-prepare-encoder_compile'])
        self.assertEqual(len(self.result['focused_tests']), 2)
        self.assertEqual(self.result['compiled_discovery'], [])
        self.assertNotIn('fake_full_boundary_reached', self.result)

    def test_last_focus_mutation_of_earlier_binary_refuses_before_full(self):
        cfg, proof, expectation = self.plan()
        with self.assertRaises(AssertionError):
            self.run_fresh(cfg, proof, expectation, mutate_earlier_on_last_focus=True)
        self.assertEqual(len(self.result['focused_tests']), cfg['focused_expected'])
        self.assertTrue(all(row['passed'] for row in self.result['focused_tests']))
        self.assertNotIn('fake_full_boundary_reached', self.result)

    def test_tail_accepts_exact_recorded_new_order_and_preserves_strict_old_order(self):
        helper = CurrentTailRecoveryTests(); self.addCleanup(helper.doCleanups)
        value = helper.fixture(); namespace = value['namespace']; prior = value['objects']['result']
        cfg, proof = namespace['cfg'], namespace['group_binding']
        ordered, cases = qualification.bound_focus_plan(cfg, proof, Path(proof['cwd']))
        by_name = {row['name']: row for row in prior['phases']}
        names = ['reviewed-language-aliases']
        for group in ordered:
            names += ['focused-prepare-' + group['id']]
            names += ['filtered-discovery-' + group['id'] + '-' + str(number)
                      for number, _ in enumerate(group['compiled_only_discovery_names'])]
        names += ['cli-ffi-install', 'full-native-suite', 'bundle-pipeline']
        prior['phases'] = [by_name[name] for name in names]
        prior['focused_execution_plan'] = 'prepare-on-first-use.v1'
        prior['focused_preparation_order'] = [group['id'] for group in ordered]
        exec(value['code'], namespace)
        self.assertEqual(namespace['result']['inherited_focused_execution_plan'], 'prepare-on-first-use.v1')
        self.assertTrue(namespace['result']['full_native_pass'])
        for defect in ('unknown-plan', 'wrong-order', 'old-phases-new-plan'):
            trial = helper.fixture(); ns = trial['namespace']; old = trial['objects']['result']
            old['focused_execution_plan'] = 'prepare-on-first-use.v1'
            old['focused_preparation_order'] = [group['id'] for group in ordered]
            if defect == 'unknown-plan': old['focused_execution_plan'] = 'arbitrary'
            elif defect == 'wrong-order': old['focused_preparation_order'].reverse()
            with self.subTest(defect=defect), self.assertRaises(AssertionError):
                exec(trial['code'], ns)



    def prerequisite_plan(self):
        cfg, proof, expectation = self.plan()
        tools = next(group for group in cfg['groups'] if group['id'] == 'tools')
        for number in range(2, 11):
            name = 'tools.test.prerequisite-' + str(number)
            tools['test_names'].append(name)
            tools['declaration_names'].append('prerequisite-' + str(number))
            tools['compiled_expected_occurrences'].append(name)
            tools['compiled_expected_count'] += 1
            next(root for root in expectation['expected']['groups']
                 if root['root'] == 'blob_build_tests')['expected_occurrences'].append(name)
        proof['prepared_expected_occurrences']['tools'] = list(tools['compiled_expected_occurrences'])
        SupportedRootSubsetTests().bind_selection(cfg, proof)
        proof['focus_priority'] = [dict(group='tools', name=name) for name in tools['test_names']]
        cfg['tools_prerequisite'] = proof['tools_prerequisite'] = True
        return cfg, proof, expectation

    def test_tools_prerequisite_all_eleven_pass_then_remaining_and_full_continue(self):
        cfg, proof, expectation = self.prerequisite_plan()
        canonical = [group['id'] for group in cfg['groups']]
        report = qualification.qualification_binding_plan(cfg, proof, expectation, Path(proof['cwd']))
        self.assertTrue(report['tools_prerequisite'])
        self.assertEqual(report['prepared_groups'], canonical)
        result, events, cases = self.run_fresh(cfg, proof, expectation)
        tools = [case[2] for case in cases if case[0]['id'] == 'tools']
        self.assertEqual(len(tools), 11)
        self.assertEqual(events[:13], ['reviewed-language-aliases', 'focused-prepare-tools'] +
                         ['focus:' + name for name in tools])
        self.assertEqual([row['name'] for row in result['focused_tests']], [case[2] for case in cases])
        self.assertTrue(result['focused_qualified'] and result['all_selected_executed'])
        self.assertTrue(result['fake_full_boundary_reached'])
        self.assertNotIn('focused_prerequisite_failure', result)
        self.assertEqual([group['id'] for group in cfg['groups']], canonical)

    def test_tools_prerequisite_functional_failure_finishes_eleven_and_accounts_later_unrun(self):
        cfg, proof, expectation = self.prerequisite_plan()
        _, cases = qualification.bound_focus_plan(cfg, proof, Path(proof['cwd']))
        with self.assertRaisesRegex(AssertionError, 'focused_functional_failure'):
            self.run_fresh(cfg, proof, expectation, failure='tools.test.selected')
        tools = [case[2] for case in cases if case[0]['id'] == 'tools']
        self.assertEqual(self.events, ['reviewed-language-aliases', 'focused-prepare-tools'] +
                         ['focus:' + name for name in tools])
        rows = self.result['focused_tests']
        self.assertEqual([row['name'] for row in rows], [case[2] for case in cases])
        self.assertEqual([row['outcome'] for row in rows[:11]], ['failed'] + ['passed'] * 10)
        self.assertEqual(rows[0]['command']['returncode'], 1)
        self.assertTrue(all(row['command'] is not None and row['binary'] is not None for row in rows[:11]))
        for row in rows[11:]:
            self.assertEqual(row['outcome'], 'unrun')
            self.assertFalse(row['passed'] or row['executed'] or row['full_suite_credit'])
            for key in ('command', 'binary', 'stdout', 'stderr', 'exact_name_discovered'):
                self.assertIsNone(row[key])
        self.assertEqual(self.result['focused_preparation_order'], ['tools'])
        self.assertEqual(self.result['focused_evidence_total'], 11)
        self.assertTrue(self.result['all_selected_accounted'])
        self.assertFalse(self.result['focused_qualified'] or self.result['all_selected_executed'])
        self.assertNotIn('fake_full_boundary_reached', self.result)
        self.assertEqual(self.snapshots[-1], self.result)

    def test_tools_prerequisite_compile_failure_preserves_original_phase_and_all_unrun(self):
        cfg, proof, expectation = self.prerequisite_plan()
        with self.assertRaisesRegex(AssertionError, 'focused_preparation_failure'):
            self.run_fresh(cfg, proof, expectation, compile_failures={'tools'})
        self.assertEqual(self.events, ['reviewed-language-aliases', 'focused-prepare-tools'])
        failure = self.result['focused_preparation_failures']['tools']
        self.assertIs(failure['phase'], self.result['phases'][-1])
        self.assertEqual(failure['phase']['command']['returncode'], 1)
        self.assertIs(self.result['focused_prerequisite_failure']['preparation_failure'], failure)
        self.assertEqual(len(self.result['focused_tests']), cfg['focused_expected'])
        self.assertTrue(all(row['outcome'] == 'unrun' and row['executed'] is False and
                            row['command'] is None and row['binary'] is None
                            for row in self.result['focused_tests']))
        self.assertEqual(self.result['focused_evidence_total'], 0)
        self.assertTrue(self.result['all_selected_accounted'])
        self.assertFalse(self.result['all_selected_executed'] or self.result['focused_qualified'])
        self.assertEqual(self.result['compiles'][0]['binaries'], {})
        self.assertNotIn('fake_full_boundary_reached', self.result)

    def test_tools_prerequisite_preparation_guard_error_retains_exact_exception(self):
        cfg, proof, expectation = self.prerequisite_plan()
        original = OSError('actual source guard refusal')
        with self.assertRaises(OSError) as caught:
            self.run_fresh(cfg, proof, expectation, compile_guard_failure=original)
        self.assertIs(caught.exception, original)
        self.assertEqual(self.events, ['reviewed-language-aliases', 'focused-prepare-tools'])
        self.assertEqual(self.result['focused_prerequisite_failure']['preparation_error'], repr(original))
        self.assertEqual(len(self.result['focused_tests']), cfg['focused_expected'])
        self.assertTrue(all(row['outcome'] == 'unrun' and row['executed'] is False and
                            row['command'] is None and row['binary'] is None
                            for row in self.result['focused_tests']))
        self.assertEqual(self.result['focused_evidence_total'], 0)
        self.assertNotIn('fake_full_boundary_reached', self.result)

    def test_tools_prerequisite_binding_rejects_mismatch_type_and_split_priority(self):
        for defect in ('configuration-only', 'binding-only', 'nonboolean', 'later-tools', 'split-tools'):
            cfg, proof, expectation = self.prerequisite_plan()
            if defect == 'configuration-only': del proof['tools_prerequisite']
            elif defect == 'binding-only': del cfg['tools_prerequisite']
            elif defect == 'nonboolean': cfg['tools_prerequisite'] = proof['tools_prerequisite'] = 1
            elif defect == 'later-tools': proof['focus_priority'] = []
            else: proof['focus_priority'].insert(1, dict(group='lua', name='lua.test.selected'))
            with self.subTest(defect=defect), self.assertRaises(AssertionError):
                qualification.qualification_binding_plan(cfg, proof, expectation, Path(proof['cwd']))

    def filtered_prerequisite_plan(self):
        cfg, proof, expectation = self.prerequisite_plan()
        cfg['filtered_tools_prerequisite'] = proof['filtered_tools_prerequisite'] = True
        tools = next(group for group in cfg['groups'] if group['id'] == 'tools')
        tools['compiled_expected_occurrences'].append('tools.test.unselected ordinary obligation')
        tools['compiled_expected_count'] += 1
        proof['prepared_expected_occurrences']['tools'] = list(tools['compiled_expected_occurrences'])
        next(root for root in expectation['expected']['groups'] if root['root'] == 'blob_build_tests')[
            'expected_occurrences'].append('tools.test.unselected ordinary obligation')
        proof['groups'] = copy.deepcopy(cfg['groups'])
        return cfg, proof, expectation

    def test_filtered_tools_pass_retains_two_binaries_then_normal_groups_and_full(self):
        cfg, proof, expectation = self.filtered_prerequisite_plan()
        report = qualification.qualification_binding_plan(cfg, proof, expectation, Path(proof['cwd']))
        result, events, cases = self.run_fresh(cfg, proof, expectation)
        selected = [case[2] for case in cases if case[0]['id'] == 'tools']
        self.assertEqual(events[:15], ['reviewed-language-aliases', 'focused-prepare-selected-tools'] +
                         ['focus:' + name for name in selected] +
                         ['focused-prepare-tools', 'focused-prepare-encoder_compile'])
        record = result['filtered_tools_preparation']
        self.assertTrue(record['selected_passed'] and record['normal_preparation_passed'])
        self.assertEqual(record['filters'], selected)
        self.assertEqual(record['compiled_expected_occurrences'], selected)
        self.assertNotEqual(record['binary']['path'], record['normal_binary']['path'])
        self.assertNotEqual(record['binary']['sha256'], record['normal_binary']['sha256'])
        self.assertEqual(FakeExecution.ref(record['binary']['path']), record['binary'])
        self.assertEqual(FakeExecution.ref(record['normal_binary']['path']), record['normal_binary'])
        self.assertEqual(result['compiles'][0]['binaries']['tools'], record['normal_binary'])
        self.assertEqual(report['filtered_tools_prerequisite']['positive_path_preparations'], 2)
        for row in result['focused_tests'][:11]:
            self.assertEqual(row['binary'], record['binary'])
            self.assertEqual(row['exact_name_discovery']['prepared_occurrences'], 1)
            self.assertFalse(row['full_suite_credit'])
        for phase in result['phases']:
            filters = [arg for arg in phase['command']['argv'] if arg.startswith('-Dprepare-test-filter')]
            self.assertEqual(filters, ['-Dprepare-test-filter=' + name for name in selected]
                             if phase['name'] == 'focused-prepare-selected-tools' else [])
        self.assertNotIn('focused-prepare-selected-tools',
                         [row['name'] for row in result['compiles'][0]['commands']])
        self.assertTrue(result['compiles'][0]['passed'] and result['focused_qualified'] and
                        result['fake_full_boundary_reached'])

    def filtered_only_plan(self):
        cfg, proof, expectation = self.filtered_prerequisite_plan()
        cfg['groups'] = [group for group in cfg['groups'] if group['id'] == 'tools']
        SupportedRootSubsetTests().bind_selection(cfg, proof)
        proof['compile_time_filtered_preparation'] = False
        cfg['execution_stage'] = 'focused-diagnostic'
        cfg['filtered_tools_only'] = proof['filtered_tools_only'] = True
        return cfg, proof, expectation

    def test_filtered_only_success_compiles_selected_once_without_normal_or_full_credit(self):
        cfg, proof, expectation = self.filtered_only_plan()
        report = qualification.qualification_binding_plan(cfg, proof, expectation, Path(proof['cwd']))
        result, events, cases = self.run_fresh(cfg, proof, expectation)
        selected = [case[2] for case in cases]
        self.assertEqual(events, ['reviewed-language-aliases', 'focused-prepare-selected-tools'] +
                         ['focus:' + name for name in selected])
        self.assertEqual(result['compiles'], [])
        self.assertNotIn('fake_full_boundary_reached', result)
        record = result['filtered_tools_preparation']
        self.assertTrue(record['selected_passed'] and result['focused_qualified'])
        self.assertFalse(record['normal_preparation_passed'] or record['full_suite_credit'])
        self.assertEqual(record['ordinary_preparation_status'], 'deferred-focused-diagnostic')
        self.assertNotIn('normal_binary', record)
        self.assertEqual(FakeExecution.ref(record['binary']['path']), record['binary'])
        self.assertEqual(report['compiled_counts'], {'tools': len(selected)})
        self.assertFalse(report['normal_full_required'])
        self.assertFalse(report['filtered_tools_prerequisite']['ordinary_unfiltered_preparation_after_pass'])
        self.assertEqual(report['filtered_tools_prerequisite']['positive_path_preparations'], 1)
        self.assertTrue(all(row['passed'] and row['binary'] == record['binary'] and
                            row['exact_name_discovery']['prepared_occurrences'] == 1 and
                            not row['full_suite_credit'] for row in result['focused_tests']))
        self.assertFalse((Path(self.tmp.name) / 'commands' / 'prepared-tests').exists())

    def mixed_filtered_only_plan(self, encoders=('encoder_compile',)):
        cfg, proof, expectation = self.filtered_prerequisite_plan()
        discovery = 'root.test.encoder root imports bundle-time presentation modules'
        support = next(group for group in cfg['groups'] if group['id'] == 'encoder_support')
        support['compiled_expected_occurrences'].append(discovery)
        support['compiled_expected_count'] += 1
        proof['prepared_expected_occurrences']['encoder_support'] = list(support['compiled_expected_occurrences'])
        next(row for row in expectation['expected']['groups'] if row['root'] == 'encoder_support')['expected_occurrences'].append(discovery)
        cfg['groups'] = [group for group in cfg['groups'] if group['id'] in (*encoders, 'tools')]
        SupportedRootSubsetTests().bind_selection(cfg, proof)
        proof['compile_time_filtered_preparation'] = any(group['compile_time_filtered'] for group in cfg['groups'])
        cfg['execution_stage'] = 'focused-diagnostic'
        cfg['filtered_tools_only'] = proof['filtered_tools_only'] = True
        return cfg, proof, expectation

    def test_mixed_filtered_only_preserves_each_encoder_partition_and_selected_tools(self):
        for encoder in ('encoder_compile', 'encoder_document', 'encoder_writer', 'encoder_support'):
            with self.subTest(encoder=encoder):
                self.tmp.cleanup(); self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
                cfg, proof, expectation = self.mixed_filtered_only_plan((encoder,))
                report = qualification.qualification_binding_plan(cfg, proof, expectation, Path(proof['cwd']))
                result, events, cases = self.run_fresh(cfg, proof, expectation)
                tools = [case[2] for case in cases if case[0]['id'] == 'tools']
                group = next(group for group in cfg['groups'] if group['id'] == encoder)
                selected = report['filtered_encoder_preparation']
                self.assertEqual(events, ['reviewed-language-aliases', 'focused-prepare-selected-tools'] +
                    ['focus:' + name for name in tools] + ['focused-prepare-selected-encoder'] +
                    ['filtered-discovery-encoder-' + str(i) for i, _ in enumerate(selected['discovery'])] +
                    ['focus:' + name for name in group['test_names']])
                self.assertEqual(result['compiles'], [])
                self.assertEqual(report['compiled_counts'], {'encoder': len(selected['compiled_expected_occurrences']), 'tools': len(tools)})
                self.assertEqual(report['prepared_groups'], [encoder, 'tools'])
                self.assertEqual([row['name'] for row in result['focused_tests']], [case[2] for case in cases])
                self.assertTrue(result['focused_qualified'] and result['all_selected_executed'])
                self.assertTrue(all(row['exact_name_discovery']['prepared_occurrences'] == 1 and
                                    not row['full_suite_credit'] for row in result['focused_tests']))
                self.assertEqual(result['filtered_encoder_preparation']['compiled_expected_occurrences'], selected['compiled_expected_occurrences'])
                self.assertFalse(result['filtered_encoder_preparation']['full_suite_credit'])
                self.assertNotIn('fake_full_boundary_reached', result)
                for row in result['phases']:
                    filters = [arg for arg in row['command']['argv'] if arg.startswith('-Dprepare-test-filter')]
                    expected = tools if row['name'] == 'focused-prepare-selected-tools' else (
                        group['test_names'] if row['name'] == 'focused-prepare-selected-encoder' else [])
                    self.assertEqual(filters, ['-Dprepare-test-filter=' + name for name in expected])

    def test_mixed_filtered_only_tools_failure_keeps_encoder_unrun(self):
        for defect in ('compile', 'functional', 'source'):
            with self.subTest(defect=defect):
                self.tmp.cleanup(); self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
                cfg, proof, expectation = self.mixed_filtered_only_plan()
                if defect == 'source':
                    original = OSError('mixed selected source changed')
                    with self.assertRaises(OSError) as caught:
                        self.run_fresh(cfg, proof, expectation, compile_guard_failure=original,
                                       compile_guard_stage='selected-tools')
                    self.assertIs(caught.exception, original)
                elif defect == 'compile':
                    with self.assertRaisesRegex(AssertionError, 'focused_preparation_failure'):
                        self.run_fresh(cfg, proof, expectation, compile_failures={'selected-tools'})
                else:
                    with self.assertRaisesRegex(AssertionError, 'focused_functional_failure'):
                        self.run_fresh(cfg, proof, expectation, failure='tools.test.selected')
                self.assertNotIn('focused-prepare-encoder_compile', self.events)
                self.assertNotIn('focused-prepare-tools', self.events)
                self.assertTrue(self.result['all_selected_accounted'])
                rows = [row for row in self.result['focused_tests'] if row['group'] == 'encoder_compile']
                self.assertTrue(rows and all(row['outcome'] == 'unrun' and not row['executed'] for row in rows))
                self.assertFalse(self.result['focused_qualified'])
                self.assertNotIn('fake_full_boundary_reached', self.result)

    def test_mixed_filtered_only_encoder_refusals_preserve_tools_and_failure_accounting(self):
        for defect in ('compile', 'functional', 'source'):
            with self.subTest(defect=defect):
                self.tmp.cleanup(); self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
                cfg, proof, expectation = self.mixed_filtered_only_plan()
                name = next(group['test_names'][0] for group in cfg['groups'] if group['id'] == 'encoder_compile')
                if defect == 'source':
                    original = OSError('mixed encoder source changed')
                    with self.assertRaises(OSError) as caught:
                        self.run_fresh(cfg, proof, expectation, compile_guard_failure=original,
                                       compile_guard_stage='selected-encoder')
                    self.assertIs(caught.exception, original)
                else:
                    message = 'focused_preparation_failure' if defect == 'compile' else 'focused_functional_failure'
                    with self.assertRaisesRegex(AssertionError, message):
                        self.run_fresh(cfg, proof, expectation,
                            compile_failures={'selected-encoder'} if defect == 'compile' else (),
                            failure=name if defect == 'functional' else None)
                    rows = [row for row in self.result['focused_tests'] if row['group'] == 'encoder_compile']
                    self.assertEqual([row['outcome'] for row in rows], ['unrun' if defect == 'compile' else 'failed'])
                    self.assertEqual(self.result['all_selected_executed'], defect == 'functional')
                    self.assertTrue(self.result['all_selected_accounted'])
                    self.assertFalse(self.result['focused_qualified'])
                self.assertTrue(self.result['filtered_tools_preparation']['selected_passed'])
                self.assertNotIn('normal_binary', self.result['filtered_tools_preparation'])
                self.assertNotIn('focused-prepare-tools', self.events)
                self.assertNotIn('fake_full_boundary_reached', self.result)

    def test_mixed_filtered_only_retains_discovery_and_binary_mutation_refusals(self):
        for defect in ('discovery', 'binary'):
            with self.subTest(defect=defect):
                self.tmp.cleanup(); self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
                cfg, proof, expectation = self.mixed_filtered_only_plan(('encoder_compile', 'encoder_document'))
                if defect == 'discovery':
                    with self.assertRaisesRegex(OSError, 'discovery refused'):
                        self.run_fresh(cfg, proof, expectation, discovery_failure=True)
                else:
                    with self.assertRaises(AssertionError):
                        self.run_fresh(cfg, proof, expectation, mutate_earlier_on_last_focus=True)
                self.assertTrue(self.result['filtered_tools_preparation']['selected_passed'])
                self.assertNotIn('focused-prepare-tools', self.events)
                self.assertNotIn('fake_full_boundary_reached', self.result)

    def test_mixed_filtered_only_rejects_partition_inventory_or_filter_drift(self):
        for defect in ('counter', 'discovery', 'external-filter', 'partition', 'unsupported-root'):
            cfg, proof, expectation = self.mixed_filtered_only_plan()
            group = cfg['groups'][0]
            if defect == 'counter': group['compiled_expected_occurrences'].pop()
            elif defect == 'discovery': group['compiled_only_discovery_names'] = []
            elif defect == 'external-filter': group['external_compile_filter_names'] = group['test_names'][:]
            elif defect == 'partition': group['compile_time_filtered'] = False
            else:
                cfg, proof, expectation = self.mixed_filtered_only_plan(('lua',))
            proof['groups'] = copy.deepcopy(cfg['groups'])
            with self.subTest(defect=defect), self.assertRaises(AssertionError):
                qualification.qualification_binding_plan(cfg, proof, expectation, Path(proof['cwd']))

    def encoder_only_plan(self, encoders=('encoder_compile',)):
        cfg, proof, expectation = self.mixed_filtered_only_plan(encoders)
        cfg['groups'] = [group for group in cfg['groups'] if group['id'] != 'tools']
        cfg['tools_prerequisite'] = proof['tools_prerequisite'] = False
        cfg['filtered_tools_prerequisite'] = proof['filtered_tools_prerequisite'] = False
        SupportedRootSubsetTests().bind_selection(cfg, proof)
        return cfg, proof, expectation

    def test_selected_encoder_union_compiles_once_with_exact_logical_outcomes(self):
        cfg, proof, expectation = self.encoder_only_plan(('encoder_compile', 'encoder_document', 'encoder_writer', 'encoder_support'))
        proof['focus_priority'] = [dict(group='encoder_writer', name=cfg['groups'][2]['test_names'][0])]
        proof['prepare_test_error_tracing'] = True
        report = qualification.qualification_binding_plan(cfg, proof, expectation, Path(proof['cwd']))
        result, events, cases = self.run_fresh(cfg, proof, expectation)
        selected = result['filtered_encoder_preparation']
        self.assertEqual(events.count('focused-prepare-selected-encoder'), 1)
        self.assertEqual(events.count('filtered-discovery-encoder-0'), 1)
        self.assertEqual([row['name'] for row in result['focused_tests']], [case[2] for case in cases])
        self.assertEqual(selected['filters'], [name for group in cfg['groups'] for name in group['test_names']])
        self.assertEqual(len(selected['compiled_expected_occurrences']), len(cases) + 1)
        self.assertEqual(report['compiled_counts'], {'encoder': len(cases) + 1})
        self.assertTrue(all(row['binary'] == selected['binary'] and row['passed'] for row in result['focused_tests']))
        self.assertEqual(result['compiles'], [])
        self.assertEqual(len(result['compiled_discovery']), 1)
        self.assertFalse(result['compiled_discovery'][0]['semantic_focus_credit'])
        argv = selected['phase']['command']['argv']
        self.assertEqual([arg for arg in argv if arg.startswith('-Dprepare-test-group=')], ['-Dprepare-test-group=encoder'])
        self.assertEqual([arg for arg in argv if arg.startswith('-Dprepare-test-filter=')], ['-Dprepare-test-filter=' + name for name in selected['filters']])
        self.assertIn('-Dprepare-test-error-tracing=true', argv)
        self.assertNotIn('fake_full_boundary_reached', result)

    def test_selected_encoder_discovery_selected_as_real_obligation_runs_once(self):
        cfg, proof, expectation = self.encoder_only_plan(('encoder_support',))
        discovery = 'root.test.encoder root imports bundle-time presentation modules'
        cfg['groups'][0]['test_names'] = [discovery]
        cfg['groups'][0]['declaration_names'] = ['encoder root imports bundle-time presentation modules']
        SupportedRootSubsetTests().bind_selection(cfg, proof)
        result, events, cases = self.run_fresh(cfg, proof, expectation)
        self.assertEqual(result['compiled_discovery'], [])
        self.assertEqual(result['filtered_encoder_preparation']['compiled_expected_occurrences'], [discovery])
        self.assertEqual(events.count('focus:' + discovery), 1)
        self.assertEqual(len(result['focused_tests']), 1)
        self.assertTrue(result['focused_tests'][0]['passed'])

    def test_selected_encoder_rejects_missing_extra_duplicate_and_cross_logical_matches(self):
        for defect in ('missing-selected', 'extra-match', 'duplicate-source', 'duplicate-selected',
                       'missing-discovery', 'extra-discovery', 'cross-logical', 'duplicate-root'):
            cfg, proof, expectation = self.encoder_only_plan()
            roots = expectation['expected']['groups']
            support = next(row for row in roots if row['root'] == 'encoder_support')
            compile_root = next(row for row in roots if row['root'] == 'encoder_compile')
            name = cfg['groups'][0]['test_names'][0]
            if defect == 'missing-selected': compile_root['expected_occurrences'].remove(name)
            elif defect == 'extra-match': support['expected_occurrences'].append(name + ' extra')
            elif defect == 'duplicate-source': support['expected_occurrences'].append(name)
            elif defect == 'duplicate-selected':
                cfg['groups'][0]['test_names'].append(name)
                cfg['groups'][0]['declaration_names'].append('selected')
                SupportedRootSubsetTests().bind_selection(cfg, proof)
            elif defect == 'missing-discovery': support['expected_occurrences'].pop()
            elif defect == 'extra-discovery': support['expected_occurrences'].append('root.test.encoder root imports bundle-time presentation modules extra')
            elif defect == 'cross-logical':
                other = next(row for row in roots if row['root'] == 'encoder_document')['expected_occurrences'][0]
                cfg['groups'][0]['test_names'] = [other]
                SupportedRootSubsetTests().bind_selection(cfg, proof)
            else: roots.append(copy.deepcopy(support))
            with self.subTest(defect=defect), self.assertRaises(AssertionError):
                qualification.qualification_binding_plan(cfg, proof, expectation, Path(proof['cwd']))

    def test_selected_encoder_shared_compile_failure_accounts_every_logical_group_once(self):
        cfg, proof, expectation = self.encoder_only_plan(('encoder_compile', 'encoder_document', 'encoder_writer'))
        with self.assertRaisesRegex(AssertionError, 'focused_preparation_failure'):
            self.run_fresh(cfg, proof, expectation, compile_failures={'selected-encoder'})
        self.assertEqual(self.events.count('focused-prepare-selected-encoder'), 1)
        self.assertEqual(len(self.result['focused_tests']), 3)
        self.assertTrue(all(row['outcome'] == 'unrun' and not row['executed'] for row in self.result['focused_tests']))
        self.assertEqual(set(self.result['focused_preparation_failures']), {cfg['groups'][0]['id']})
        self.assertEqual(self.result['focused_preparation_order'], [cfg['groups'][0]['id']])
        self.assertEqual(self.result['focused_interruption'], 'focused_preparation_failure')
        self.assertFalse(self.result['all_selected_executed'] or self.result['focused_qualified'])
        self.assertTrue(self.result['all_selected_accounted'])

    def test_selected_encoder_unproven_failure_stops_independent_later_logical_results(self):
        cfg, proof, expectation = self.encoder_only_plan(('encoder_compile', 'encoder_document', 'encoder_writer'))
        name = cfg['groups'][0]['test_names'][0]
        with self.assertRaisesRegex(AssertionError, 'focused_functional_failure'):
            self.run_fresh(cfg, proof, expectation, failure=name)
        self.assertEqual(self.events.count('focused-prepare-selected-encoder'), 1)
        self.assertEqual([row['outcome'] for row in self.result['focused_tests']], ['failed', 'unrun', 'unrun'])
        self.assertFalse(self.result['all_selected_executed'])
        self.assertTrue(self.result['all_selected_accounted'])
        self.assertEqual(self.result['focused_interruption'], 'unproven_focused_termination')
        self.assertFalse(self.result['focused_qualified'])
        self.assertNotIn('fake_full_boundary_reached', self.result)

    def test_selected_encoder_reentry_authenticates_shared_binary_without_recompilation(self):
        cfg, proof, expectation = self.encoder_only_plan(('encoder_compile', 'encoder_document'))
        first = cfg['groups'][0]
        first['test_names'].append('encoder_compile.test.second')
        first['declaration_names'].append('second')
        first['compiled_expected_occurrences'].append('encoder_compile.test.second')
        first['compiled_expected_count'] += 1
        next(row for row in expectation['expected']['groups'] if row['root'] == 'encoder_compile')['expected_occurrences'].append('encoder_compile.test.second')
        proof['prepared_expected_occurrences']['encoder_compile'] = list(first['compiled_expected_occurrences'])
        SupportedRootSubsetTests().bind_selection(cfg, proof)
        proof['focus_priority'] = [dict(group='encoder_compile', name=first['test_names'][0]),
                                   dict(group='encoder_document', name=cfg['groups'][1]['test_names'][0]),
                                   dict(group='encoder_compile', name=first['test_names'][1])]
        result, events, cases = self.run_fresh(cfg, proof, expectation)
        self.assertEqual(events.count('focused-prepare-selected-encoder'), 1)
        self.assertEqual(result['focused_preparation_order'], ['encoder_compile', 'encoder_document'])
        self.assertEqual([row['name'] for row in result['focused_tests']], [case[2] for case in cases])

    def test_selected_encoder_union_preserves_mapping_counter_multiplicity(self):
        from collections import Counter
        for count in (1, 2, 0, -1, True):
            cfg, proof, expectation = self.encoder_only_plan()
            for row in expectation['expected']['groups']:
                row['expected_occurrences'] = dict(Counter(row['expected_occurrences']))
            support = next(row for row in expectation['expected']['groups'] if row['root'] == 'encoder_support')
            support['expected_occurrences']['encoder_support.test.selected'] = count
            with self.subTest(count=count):
                if type(count) is int and count == 1:
                    report = qualification.qualification_binding_plan(cfg, proof, expectation, Path(proof['cwd']))
                    self.assertEqual(report['compiled_counts'], {'encoder': 2})
                else:
                    with self.assertRaises(AssertionError):
                        qualification.qualification_binding_plan(cfg, proof, expectation, Path(proof['cwd']))

    def test_selected_encoder_failed_union_reentry_preserves_all_unrun_accounting(self):
        cfg, proof, expectation = self.encoder_only_plan(('encoder_compile', 'encoder_document'))
        first = cfg['groups'][0]
        first['test_names'].append('encoder_compile.test.second')
        first['declaration_names'].append('second')
        first['compiled_expected_occurrences'].append('encoder_compile.test.second')
        first['compiled_expected_count'] += 1
        next(row for row in expectation['expected']['groups'] if row['root'] == 'encoder_compile')['expected_occurrences'].append('encoder_compile.test.second')
        proof['prepared_expected_occurrences']['encoder_compile'] = list(first['compiled_expected_occurrences'])
        SupportedRootSubsetTests().bind_selection(cfg, proof)
        proof['focus_priority'] = [dict(group='encoder_compile', name=first['test_names'][0]),
                                   dict(group='encoder_document', name=cfg['groups'][1]['test_names'][0]),
                                   dict(group='encoder_compile', name=first['test_names'][1])]
        with self.assertRaisesRegex(AssertionError, 'focused_preparation_failure'):
            self.run_fresh(cfg, proof, expectation, compile_failures={'selected-encoder'})
        self.assertEqual(self.events.count('focused-prepare-selected-encoder'), 1)
        self.assertEqual(self.result['focused_preparation_order'], ['encoder_compile'])
        self.assertEqual(self.result['focused_interruption'], 'focused_preparation_failure')
        self.assertEqual([row['name'] for row in self.result['focused_tests']],
                         [item['name'] for item in proof['focus_priority']])
        self.assertTrue(all(row['outcome'] == 'unrun' and not row['executed'] for row in self.result['focused_tests']))
        self.assertTrue(self.result['all_selected_accounted'])
        self.assertFalse(self.result['all_selected_executed'] or self.result['focused_qualified'])
        self.assertEqual(self.result['focused_evidence_total'], 0)

    def test_filtered_only_failures_preserve_selected_results_and_source_errors(self):
        for defect in ('functional', 'compile', 'source-guard'):
            with self.subTest(defect=defect):
                self.tmp.cleanup(); self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
                cfg, proof, expectation = self.filtered_only_plan()
                if defect == 'source-guard':
                    original = OSError('selected source changed')
                    with self.assertRaises(OSError) as caught:
                        self.run_fresh(cfg, proof, expectation, compile_guard_failure=original,
                                       compile_guard_stage='selected-tools')
                    self.assertIs(caught.exception, original)
                elif defect == 'compile':
                    with self.assertRaisesRegex(AssertionError, 'focused_preparation_failure'):
                        self.run_fresh(cfg, proof, expectation, compile_failures={'selected-tools'})
                    self.assertEqual(self.result['focused_preparation_failures']['tools']['phase']['command']['returncode'], 1)
                else:
                    with self.assertRaisesRegex(AssertionError, 'focused_functional_failure'):
                        self.run_fresh(cfg, proof, expectation, failure='tools.test.selected')
                    self.assertEqual([row['outcome'] for row in self.result['focused_tests']],
                                     ['failed'] + ['unrun'] * 10)
                    self.assertEqual(self.result['focused_interruption'], 'unproven_focused_termination')
                self.assertEqual(self.result['compiles'], [])
                self.assertNotIn('focused-prepare-tools', self.events)
                self.assertNotIn('fake_full_boundary_reached', self.result)
                self.assertFalse(self.result['focused_qualified'])
                self.assertTrue(self.result['all_selected_accounted'])

    def test_filtered_only_binding_refuses_full_tail_mixed_and_unbound_modes(self):
        for defect in ('full', 'tail', 'mixed', 'no-filter', 'configuration-only', 'binding-only', 'integer',
                       'substring-extra'):
            cfg, proof, expectation = self.filtered_only_plan()
            if defect in ('full', 'tail'): cfg['execution_stage'] = defect
            elif defect == 'mixed':
                cfg, proof, expectation = self.filtered_prerequisite_plan()
                cfg['execution_stage'] = 'focused-diagnostic'
                cfg['filtered_tools_only'] = proof['filtered_tools_only'] = True
            elif defect == 'no-filter':
                cfg['filtered_tools_prerequisite'] = proof['filtered_tools_prerequisite'] = False
            elif defect == 'configuration-only': del proof['filtered_tools_only']
            elif defect == 'binding-only': del cfg['filtered_tools_only']
            elif defect == 'integer': cfg['filtered_tools_only'] = proof['filtered_tools_only'] = 1
            else:
                tools = cfg['groups'][0]
                extra = tools['test_names'][0] + ' also matches'
                tools['compiled_expected_occurrences'].append(extra); tools['compiled_expected_count'] += 1
                proof['prepared_expected_occurrences']['tools'].append(extra)
                next(root for root in expectation['expected']['groups'] if root['root'] == 'blob_build_tests')[
                    'expected_occurrences'].append(extra)
                proof['groups'] = copy.deepcopy(cfg['groups'])
            with self.subTest(defect=defect), self.assertRaises(AssertionError):
                qualification.qualification_binding_plan(cfg, proof, expectation, Path(proof['cwd']))

    def test_tail_cannot_adopt_a_filtered_only_producer_as_full(self):
        helper = CurrentTailRecoveryTests(); self.addCleanup(helper.doCleanups)
        value = helper.fixture()
        value['objects']['configuration']['filtered_tools_only'] = True
        with self.assertRaises(AssertionError):
            exec(value['code'], value['namespace'])
        self.assertEqual(value['commands'], [])

    def test_filtered_tools_failure_finishes_selected_and_never_prepares_normal_or_later(self):
        cfg, proof, expectation = self.filtered_prerequisite_plan()
        with self.assertRaisesRegex(AssertionError, 'focused_functional_failure'):
            self.run_fresh(cfg, proof, expectation, failure='tools.test.selected')
        self.assertEqual(self.events[:2], ['reviewed-language-aliases', 'focused-prepare-selected-tools'])
        self.assertEqual(len(self.events), 13)
        self.assertEqual([row['outcome'] for row in self.result['focused_tests'][:11]],
                         ['failed'] + ['passed'] * 10)
        self.assertTrue(all(row['outcome'] == 'unrun' and row['binary'] is None and row['command'] is None
                            for row in self.result['focused_tests'][11:]))
        self.assertEqual(self.result['compiles'][0]['binaries'], {})
        self.assertFalse(self.result['filtered_tools_preparation']['normal_preparation_passed'])
        self.assertTrue(self.result['all_selected_accounted'])
        self.assertNotIn('fake_full_boundary_reached', self.result)

    def test_filtered_tools_compile_failure_and_guard_error_keep_original_and_all_unrun(self):
        for guard_error in (False, OSError('selected preparation source changed')):
            with self.subTest(guard_error=bool(guard_error)):
                self.tmp.cleanup(); self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
                cfg, proof, expectation = self.filtered_prerequisite_plan()
                if guard_error:
                    with self.assertRaises(OSError) as caught:
                        self.run_fresh(cfg, proof, expectation, compile_guard_failure=guard_error,
                                       compile_guard_stage='selected-tools')
                    self.assertIs(caught.exception, guard_error)
                else:
                    with self.assertRaisesRegex(AssertionError, 'focused_preparation_failure'):
                        self.run_fresh(cfg, proof, expectation, compile_failures={'selected-tools'})
                    failure = self.result['focused_preparation_failures']['tools']
                    self.assertEqual(failure['preparation_scope'], 'selected')
                    self.assertEqual(failure['phase']['command']['returncode'], 1)
                self.assertEqual(self.events, ['reviewed-language-aliases', 'focused-prepare-selected-tools'])
                self.assertTrue(all(row['outcome'] == 'unrun' and not row['executed']
                                    for row in self.result['focused_tests']))
                self.assertEqual(self.result['focused_evidence_total'], 0)
                self.assertNotIn('fake_full_boundary_reached', self.result)

    def test_filtered_pass_normal_compile_failure_or_guard_error_preserves_earned_selected(self):
        for guard_error in (False, OSError('normal preparation source changed')):
            with self.subTest(guard_error=bool(guard_error)):
                self.tmp.cleanup(); self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
                cfg, proof, expectation = self.filtered_prerequisite_plan()
                if guard_error:
                    with self.assertRaises(OSError) as caught:
                        self.run_fresh(cfg, proof, expectation, compile_guard_failure=guard_error,
                                       compile_guard_stage='tools')
                    self.assertIs(caught.exception, guard_error)
                else:
                    with self.assertRaisesRegex(AssertionError, 'focused_normal_preparation_failure'):
                        self.run_fresh(cfg, proof, expectation, compile_failures={'tools'})
                    self.assertEqual(self.result['focused_preparation_failures']['tools']['preparation_scope'],
                                     'normal-unfiltered')
                self.assertEqual(self.events[-1], 'focused-prepare-tools')
                self.assertEqual(len(self.events), 14)
                self.assertTrue(all(row['passed'] for row in self.result['focused_tests'][:11]))
                self.assertTrue(all(row['outcome'] == 'unrun' and row['binary'] is None
                                    for row in self.result['focused_tests'][11:]))
                self.assertEqual(self.result['focused_evidence_total'], 11)
                self.assertTrue(self.result['all_selected_accounted'])
                self.assertTrue(self.result['filtered_tools_preparation']['selected_passed'])
                self.assertFalse(self.result['filtered_tools_preparation']['normal_preparation_passed'])
                self.assertNotIn('fake_full_boundary_reached', self.result)

    def test_filtered_binary_mutation_during_normal_preparation_refuses(self):
        cfg, proof, expectation = self.filtered_prerequisite_plan()
        with self.assertRaises(AssertionError):
            self.run_fresh(cfg, proof, expectation, mutate_selected_on_normal_prepare=True)
        self.assertEqual(self.events[-1], 'focused-prepare-tools')
        self.assertTrue(all(row['passed'] for row in self.result['focused_tests'][:11]))
        self.assertTrue(all(row['outcome'] == 'unrun' for row in self.result['focused_tests'][11:]))
        self.assertFalse(self.result['filtered_tools_preparation']['normal_preparation_passed'])
        self.assertNotIn('fake_full_boundary_reached', self.result)

    def test_filtered_tools_binding_rejects_unknown_mode_without_prerequisite_and_substring_collisions(self):
        for defect in ('configuration-only', 'binding-only', 'nonboolean', 'no-prerequisite', 'substring-extra'):
            cfg, proof, expectation = self.filtered_prerequisite_plan()
            qualification.qualification_binding_plan(cfg, proof, expectation, Path(proof['cwd']))
            if defect == 'configuration-only': del proof['filtered_tools_prerequisite']
            elif defect == 'binding-only': del cfg['filtered_tools_prerequisite']
            elif defect == 'nonboolean': cfg['filtered_tools_prerequisite'] = proof['filtered_tools_prerequisite'] = 1
            elif defect == 'no-prerequisite': cfg['tools_prerequisite'] = proof['tools_prerequisite'] = False
            else:
                tools = next(group for group in cfg['groups'] if group['id'] == 'tools')
                extra = 'tools.test.selected also matches'
                tools['compiled_expected_occurrences'].append(extra); tools['compiled_expected_count'] += 1
                proof['prepared_expected_occurrences']['tools'].append(extra)
                next(root for root in expectation['expected']['groups'] if root['root'] == 'blob_build_tests')[
                    'expected_occurrences'].append(extra)
                proof['groups'] = copy.deepcopy(cfg['groups'])
            with self.subTest(defect=defect), self.assertRaises(AssertionError):
                qualification.qualification_binding_plan(cfg, proof, expectation, Path(proof['cwd']))

    def test_filtered_tail_requires_both_preparations_and_exact_filtered_binary(self):
        for defect in (None, 'missing-normal', 'wrong-filter', 'same-binary', 'wrong-row', 'unqualified-normal',
                       'unrelated-normal', 'wrong-selected-phase', 'wrong-normal-phase'):
            helper = CurrentTailRecoveryTests(); self.addCleanup(helper.doCleanups)
            value = helper.fixture(); ns = value['namespace']; prior = value['objects']['result']
            cfg, proof, prior_cfg = ns['cfg'], ns['group_binding'], value['objects']['configuration']
            for obj in (cfg, proof, prior_cfg):
                obj['tools_prerequisite'] = True; obj['filtered_tools_prerequisite'] = True
            tools = next(group for group in cfg['groups'] if group['id'] == 'tools')
            ordered, cases = qualification.bound_focus_plan(cfg, proof, Path(proof['cwd']))
            by_name = {row['name']: row for row in prior['phases']}
            names = ['reviewed-language-aliases']
            for group in ordered:
                names += ['focused-prepare-' + group['id']]
                names += ['filtered-discovery-' + group['id'] + '-' + str(number)
                          for number, _ in enumerate(group['compiled_only_discovery_names'])]
            names += ['cli-ffi-install', 'full-native-suite', 'bundle-pipeline']
            prior['phases'] = [by_name[name] for name in names]
            prior['focused_execution_plan'] = 'prepare-on-first-use.v1'
            prior['focused_preparation_order'] = [group['id'] for group in ordered]
            ordinary = prior['focused_tests'][0]['binary']
            selected_path = Path(ordinary['path']).with_name('selected-binary')
            selected_path.write_bytes(b'actual selected preparation')
            selected = FakeExecution.ref(selected_path)
            selected_phase = copy.deepcopy(by_name['focused-prepare-tools'])
            selected_phase['name'] = 'focused-prepare-selected-tools'
            selected_phase['command']['argv'] += ['-Dprepare-test-filter=' + name for name in tools['test_names']]
            prior['phases'].insert(1, selected_phase)
            prior['filtered_tools_preparation'] = dict(filters=list(tools['test_names']),
                compiled_expected_occurrences=list(tools['test_names']), binary=selected, normal_binary=ordinary,
                phase=selected_phase, selected_passed=True, normal_preparation_passed=True, full_suite_credit=False)
            prior['compiles'] = [dict(passed=True, binaries={'tools': ordinary},
                                     commands=[by_name['focused-prepare-tools']])]
            for row, case in zip(prior['focused_tests'], cases, strict=True):
                row['group'] = case[0]['id']
                if row['group'] == 'tools': row['binary'] = selected
            if defect == 'missing-normal': prior['phases'].remove(by_name['focused-prepare-tools'])
            elif defect == 'wrong-filter': selected_phase['command']['argv'].append('-Dprepare-test-filter=other')
            elif defect == 'same-binary': prior['filtered_tools_preparation']['normal_binary'] = selected
            elif defect == 'wrong-row': prior['focused_tests'][0]['binary'] = ordinary
            elif defect == 'unqualified-normal': prior['filtered_tools_preparation']['normal_preparation_passed'] = False
            elif defect == 'unrelated-normal':
                unrelated = selected_path.with_name('unrelated-binary'); unrelated.write_bytes(b'unrelated valid bytes')
                prior['filtered_tools_preparation']['normal_binary'] = FakeExecution.ref(unrelated)
            elif defect == 'wrong-selected-phase': prior['filtered_tools_preparation']['phase'] = by_name['focused-prepare-tools']
            elif defect == 'wrong-normal-phase': prior['compiles'][0]['commands'] = [by_name['cli-ffi-install']]
            with self.subTest(defect=defect):
                if defect is None:
                    exec(value['code'], ns)
                    self.assertTrue(ns['result']['full_native_pass'])
                    self.assertEqual(value['commands'], [])
                else:
                    with self.assertRaises(AssertionError): exec(value['code'], ns)

    @staticmethod
    def compile_diagnostic():
        return ("prepare-tests\n+- install test\n   +- compile test safe x86_64-native 1 errors\n"
                "src/encoder/presentation_compile.zig:11304:59: error: expected type 'T', found '?T'\n"
                "    const original = try missingSlice(self.a, self.inline_missing, input);\n"
                "                                                      ~~~~^~~~~~~~~~~~~~~\n"
                "error: 1 compilation errors\n"
                "failed command: /fixture/zig test --test-filter OutOfMemory\n\n"
                "Build Summary: 1/4 steps succeeded (1 failed)\n"
                "prepare-tests transitive failure\n+- install test transitive failure\n"
                "   +- compile test safe x86_64-native 1 errors\n")

    def test_joined_compile_failure_accounts_unrun_then_executes_later_groups(self):
        cfg, proof, expectation = self.plan()
        with self.assertRaisesRegex(AssertionError, 'focused_preparation_failure'):
            self.run_fresh(cfg, proof, expectation, compile_failures={'tools'})
        ordered, cases = qualification.bound_focus_plan(cfg, proof, Path(proof['cwd']))
        self.assertEqual([row['name'] for row in self.result['focused_tests']], [case[2] for case in cases])
        unrun = [row for row in self.result['focused_tests'] if row['outcome'] == 'unrun']
        self.assertEqual([row['name'] for row in unrun], ['tools.test.selected', 'tools.test.second'])
        self.assertTrue(all(row['passed'] is False and row['executed'] is False and row['binary'] is None
                            and row['command'] is None and row['exact_name_discovered'] is None for row in unrun))
        self.assertTrue(all(row['passed'] for row in self.result['focused_tests'] if row not in unrun))
        self.assertEqual(self.result['focused_preparation_order'], [group['id'] for group in ordered])
        self.assertEqual(self.result['focused_evidence_total'], len(cases) - 2)
        self.assertTrue(self.result['all_selected_accounted'])
        self.assertFalse(self.result['all_selected_executed'] or self.result['focused_qualified'] or self.result['compiles'][0]['passed'])
        self.assertNotIn('tools', self.result['compiles'][0]['binaries'])
        self.assertNotIn('fake_full_boundary_reached', self.result)
        self.assertEqual(self.events.count('focused-prepare-tools'), 1)
        self.assertNotIn('focus:tools.test.selected', self.events)

    def test_failed_group_priority_reentry_never_recompiles_or_claims_execution(self):
        cfg, proof, expectation = self.plan()
        proof['focus_priority'] = [dict(group='tools', name='tools.test.selected'),
                                   dict(group='lua', name='lua.test.selected'),
                                   dict(group='tools', name='tools.test.second')]
        with self.assertRaisesRegex(AssertionError, 'focused_preparation_failure'):
            self.run_fresh(cfg, proof, expectation, compile_failures={'tools'})
        self.assertEqual(self.events.count('focused-prepare-tools'), 1)
        self.assertEqual([row['outcome'] for row in self.result['focused_tests'][:3]], ['unrun', 'passed', 'unrun'])
        self.assertNotIn('fake_full_boundary_reached', self.result)

    def test_unsafe_compile_outcomes_abort_without_later_preparation(self):
        diagnostic = self.compile_diagnostic()
        variants = [('timeout', 1, '', diagnostic), ('exited', -9, '', diagnostic),
                    ('exited', True, '', diagnostic), ('exited', 1, '', 'error: OutOfMemory\n'),
                    ('exited', 1, '', diagnostic + 'error: ContainmentUnavailable\n'),
                    ('exited', 1, '', diagnostic + 'LLVM ERROR: out of memory\n'),
                    ('exited', 1, '', diagnostic + 'thread 123 panic: reached unreachable code\n'),
                    ('exited', 1, '', diagnostic + '    LLVM ERROR: out of memory\n'),
                    ('exited', 1, '', diagnostic + '    thread 123 panic: reached unreachable code\n'),
                    ('exited', 1, '', diagnostic.replace('failed command:', 'unknown command:')),
                    ('exited', 1, '', diagnostic.replace('/fixture/zig test ', '/fixture/zig build-exe ')),
                    ('exited', 1, 'unbound stdout', diagnostic)]
        # Each trial gets its own actual worker output root.
        for trial in variants:
            with self.subTest(trial=trial):
                with tempfile.TemporaryDirectory() as directory:
                    old = self.tmp; self.tmp = type('Root', (), {'name': directory})()
                    try:
                        cfg, proof, expectation = self.plan()
                        with self.assertRaises(AssertionError):
                            self.run_fresh(cfg, proof, expectation, compile_failures={'tools'}, unsafe_compile_outcome=trial)
                        self.assertEqual(self.events, ['reviewed-language-aliases', 'focused-prepare-tools'])
                        self.assertEqual(self.result['focused_tests'], [])
                        self.assertNotIn('fake_full_boundary_reached', self.result)
                    finally:
                        self.tmp = old

    def test_compile_failure_preserves_source_guard_abort_before_unrun(self):
        cfg, proof, expectation = self.plan()
        with self.assertRaisesRegex(OSError, 'source guard after compilation'):
            self.run_fresh(cfg, proof, expectation, compile_failures={'tools'}, compile_guard_failure=True)
        self.assertEqual(self.events, ['reviewed-language-aliases', 'focused-prepare-tools'])
        self.assertEqual(self.result['focused_tests'], [])
        self.assertNotIn('fake_full_boundary_reached', self.result)

    def test_compile_failure_reauthenticates_prior_binary_and_refuses_partial_output(self):
        for defect in ('prior-binary', 'partial-output'):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as directory:
                old = self.tmp; self.tmp = type('Root', (), {'name': directory})()
                try:
                    cfg, proof, expectation = self.plan()
                    with self.assertRaises(AssertionError):
                        self.run_fresh(cfg, proof, expectation,
                            compile_failures={'encoder_compile'} if defect == 'prior-binary' else {'tools'},
                            mutate_previous_on_prepare=defect == 'prior-binary', extra_binary=defect == 'partial-output')
                    self.assertNotIn('fake_full_boundary_reached', self.result)
                    self.assertNotIn('encoder_compile', self.result['focused_preparation_failures'])
                finally:
                    self.tmp = old

    def test_compile_diagnostic_accepts_only_exact_successful_options_dependency_row(self):
        command = dict(argv=['/fixture/zig', 'build', 'prepare-tests'], status='exited', returncode=1)
        helper = dict(ANSI=re.compile(r'\x1b\[[0-9;]*m'))
        diagnostic = self.compile_diagnostic()
        accepted = diagnostic + '      +- options success\n'
        proof = qualification.require_ordinary_preparation_compile_failure(command, '', accepted, helper)
        self.assertEqual(proof['compilation_errors'], 1)
        self.assertFalse(proof['selected_tests_executed'] or proof['full_suite_credit'])
        for line in ('      +- options failure', '      +- options success garbage',
                     '      +- options success LLVM ERROR: out of memory',
                     '      +- options success OutOfMemory',
                     '      +- options success\nLLVM ERROR: out of memory',
                     '      +- options success\n    thread 123 panic: reached unreachable code'):
            with self.subTest(line=line), self.assertRaises(AssertionError):
                qualification.require_ordinary_preparation_compile_failure(command, '', diagnostic + line + '\n', helper)

    def test_compile_diagnostic_ignores_filter_names_and_expected_error_prose(self):
        command = dict(argv=['/fixture/zig', 'build', 'prepare-tests'], status='exited', returncode=1)
        helper = dict(ANSI=re.compile(r'\x1b\[[0-9;]*m'))
        diagnostic = self.compile_diagnostic().replace('    const original = try missingSlice(self.a, self.inline_missing, input);',
            '    const original = \"OutOfMemory ContainmentUnavailable LLVM ERROR: out of memory\";')
        proof = qualification.require_ordinary_preparation_compile_failure(command, '', diagnostic, helper)
        self.assertEqual(proof['compilation_errors'], 1)
        self.assertFalse(proof['selected_tests_executed'] or proof['full_suite_credit'])

class DiagnosticPreparationPlanTests(unittest.TestCase):
    def plan(self, selected, stage):
        cfg, proof, expectation = PreparationFailFastTests().fixture()
        cfg['groups'] = [group for group in cfg['groups'] if group['id'] in selected]
        SupportedRootSubsetTests().bind_selection(cfg, proof)
        cfg['execution_stage'] = stage
        proof['compile_time_filtered_preparation'] = any(group['compile_time_filtered'] for group in cfg['groups'])
        return cfg, proof, expectation

    def test_tools_only_full_and_diagnostic_use_truthful_unfiltered_aggregate(self):
        for stage in ('full', 'focused-diagnostic'):
            cfg, proof, expectation = self.plan(['tools'], stage)
            commands = []
            result = PreparationFailFastTests().execute_prefix(cfg, proof, expectation, commands)
            self.assertFalse(proof['compile_time_filtered_preparation'])
            self.assertEqual(result['prepared_names'], ('tools',))
            self.assertEqual(result['prepare_filters'], {'tools': []})
            self.assertEqual(result['prepare_discovery'], {'tools': []})
            self.assertEqual([name for name, _ in commands],
                             ['reviewed-language-aliases', 'focused-prepare-tools'])
            self.assertEqual(commands[-1][1][-1], '-Dprepare-test-group=tools')
            self.assertFalse(any(arg.startswith('-Dprepare-test-filter') for arg in commands[-1][1]))

    def test_unknown_preparation_stage_refuses_before_commands(self):
        for stage in ('unknown', 'focused_diagnostic', 'support-tail', None):
            cfg, proof, expectation = self.plan(['tools'], stage)
            commands = []
            with self.subTest(stage=stage), self.assertRaises(AssertionError):
                PreparationFailFastTests().execute_prefix(cfg, proof, expectation, commands)
            self.assertEqual(commands, [])

    def test_tail_recovers_evidence_without_entering_fresh_preparation(self):
        fixture_owner = CurrentTailRecoveryTests()
        self.addCleanup(fixture_owner.doCleanups)
        value = fixture_owner.fixture()
        self.assertEqual(value['namespace']['cfg']['execution_stage'], 'tail')
        exec(value['code'], value['namespace'])
        self.assertEqual(value['commands'], [])
        self.assertFalse(value['namespace']['result']['focused_current_execution'])
        self.assertFalse(value['namespace']['result']['full_native_current_execution'])
        self.assertTrue(value['namespace']['result']['full_native_pass'])

    def test_misreported_or_nonboolean_aggregate_refuses_for_both_stages(self):
        for stage in ('full', 'focused-diagnostic'):
            for roots, wrong in ((['tools'], True), (['tools'], 0), (['tools'], None),
                                 (['encoder_compile', 'tools'], False),
                                 (['encoder_compile', 'tools'], 1), (['encoder_compile', 'tools'], None)):
                cfg, proof, expectation = self.plan(roots, stage)
                proof['compile_time_filtered_preparation'] = wrong
                commands = []
                with self.subTest(stage=stage, roots=roots, wrong=wrong), self.assertRaises(AssertionError):
                    PreparationFailFastTests().execute_prefix(cfg, proof, expectation, commands)
                self.assertEqual(commands, [])
            cfg, proof, expectation = self.plan(['encoder_compile', 'tools'], stage)
            commands = []
            result = PreparationFailFastTests().execute_prefix(cfg, proof, expectation, commands)
            self.assertTrue(proof['compile_time_filtered_preparation'])
            self.assertEqual(result['prepared_names'], ('encoder_compile', 'tools'))

    def test_diagnostic_retains_per_root_counter_discovery_and_metadata_predicates(self):
        for defect in ('root', 'origin', 'filters', 'external', 'discovery', 'counter', 'count', 'full-graph', 'target', 'tracing'):
            cfg, proof, expectation = self.plan(['tools'], 'focused-diagnostic')
            group = cfg['groups'][0]
            if defect == 'root': group['physical_root'] = 'encoder_compile'
            elif defect == 'origin': group['compile_filter_origin'] = 'fixed-normal-encoder-partition'
            elif defect == 'filters': group['compile_filter_names'] = ['blob_build.test.']
            elif defect == 'external': group['external_compile_filter_names'] = ['tools.test.selected']
            elif defect == 'discovery':
                group['compiled_only_discovery_names'] = ['unselected discovery']
                proof['prepared_discovery_filters']['tools'] = ['unselected discovery']
            elif defect == 'counter':
                group['compiled_expected_occurrences'] *= 2
                group['compiled_expected_count'] *= 2
                proof['prepared_expected_occurrences']['tools'] = list(group['compiled_expected_occurrences'])
            elif defect == 'count': group['compiled_expected_count'] += 1
            elif defect == 'full-graph': proof['full_normal_partitioned_graph_required'] = False
            elif defect == 'target': proof['prepare_target'] = 'other'
            else: proof['prepare_test_error_tracing'] = 'true'
            proof['groups'] = copy.deepcopy(cfg['groups'])
            commands = []
            with self.subTest(defect=defect), self.assertRaises(AssertionError):
                PreparationFailFastTests().execute_prefix(cfg, proof, expectation, commands)
            self.assertEqual(commands, [])


    def test_tail_still_requires_authenticated_prior_full_execution_stage(self):
        helper = CurrentTailRecoveryTests(); self.addCleanup(helper.doCleanups)
        value = helper.fixture(); namespace = value['namespace']
        prior_cfg = value['objects']['configuration']
        prior_cfg['execution_stage'] = 'focused-diagnostic'
        ordered, cases = qualification.bound_focus_plan(prior_cfg, namespace['group_binding'], Path(namespace['group_binding']['cwd']))
        qualification.validate_preparation_plan(prior_cfg, namespace['group_binding'], namespace['expect'], ordered, cases)
        with self.assertRaises(AssertionError):
            exec(value['code'], namespace)
        self.assertEqual(value['commands'], [])


class CapturedFingerprintTests(unittest.TestCase):
    def test_inventory_digest_is_authenticated_and_omission_is_exact(self):
        digest = 'a' * 64
        descriptor = dict(path='/fixture/current-inventory.json', bytes=123, sha256=digest)
        seen = []
        cfg = dict(private_manifest=descriptor)
        self.assertIsNone(qualification.bound_captured_source_fingerprint(cfg, seen.append))
        self.assertEqual(seen, [])
        cfg['captured_source_fingerprint'] = digest
        self.assertEqual(qualification.bound_captured_source_fingerprint(cfg, seen.append), digest)
        self.assertEqual(seen, [descriptor])
        for invalid in (None, True, '', 'A' * 64, 'a' * 63, 'g' * 64, 'b' * 64,
                        digest + ' -Dother=true'):
            with self.subTest(invalid=invalid):
                cfg['captured_source_fingerprint'] = invalid
                with self.assertRaises(AssertionError):
                    qualification.bound_captured_source_fingerprint(cfg, seen.append)
        cfg['captured_source_fingerprint'] = digest
        def refused(value):
            raise OSError('changed inventory')
        with self.assertRaisesRegex(OSError, 'changed inventory'):
            qualification.bound_captured_source_fingerprint(cfg, refused)

    def test_every_build_family_preserves_old_argv_and_gets_one_bound_option(self):
        from types import SimpleNamespace
        compiler, cache, prefix = Path('/fixture/zig'), Path('/fixture/cache'), Path('/fixture/install')
        def native(args, cache):
            return [str(args.compiler), 'build', 'test', '-j1', '-Doptimize=safe',
                    '-Dtarget=x86_64-native', '-Dcpu=baseline', '--search-prefix', '/usr',
                    '--summary', 'all', '--cache-dir', str(cache / 'local')]
        args = SimpleNamespace(compiler=compiler)
        old_full = native(args, cache); old_full[3] = '-j2'
        old_prepare = old_full.copy(); old_prepare[2] = 'prepare-tests'; old_prepare += ['--prefix', str(prefix)]
        common = [str(compiler), 'build', '-j2', '-Doptimize=safe', '-Dtarget=x86_64-native',
                  '-Dcpu=baseline', '--summary', 'all', '--search-prefix', '/usr',
                  '--cache-dir', str(cache / 'local'), '--prefix', str(prefix)]
        old = dict(prepare=old_prepare, full=old_full,
                   install=common[:2] + ['cli', 'ffi'] + common[2:],
                   **{'bundle-pipeline': common[:2] + ['test-bundle-pipeline'] + common[2:],
                      'bundle': common[:2] + ['test-bundle'] + common[2:]})
        for family, expected in old.items():
            with self.subTest(family=family):
                options = dict(family=family, prefix=None if family == 'full' else prefix)
                self.assertEqual(qualification.qualification_build_argv(args, cache, native, **options), expected)
                args.captured_source_fingerprint = 'a' * 64
                actual = qualification.qualification_build_argv(args, cache, native, **options)
                self.assertEqual(actual, expected + ['-Dcaptured-source-fingerprint=' + 'a' * 64])
                self.assertEqual(sum(value.startswith('-Dcaptured-source-fingerprint=') for value in actual), 1)
                del args.captured_source_fingerprint
        with self.assertRaises(AssertionError):
            qualification.qualification_build_argv(args, cache, native, family='arbitrary', prefix=prefix)
        with self.assertRaises(AssertionError):
            qualification.qualification_build_argv(args, cache,
                lambda args, cache: native(args, cache) + ['-Dcaptured-source-fingerprint=' + 'b' * 64], family='full')

    def test_actual_command_sites_use_common_builder_and_both_roles_bind_before_commands(self):
        import ast
        tree = ast.parse(Path(qualification.__file__).read_text())
        calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call)
                 and isinstance(node.func, ast.Name) and node.func.id == 'qualification_build_argv']
        families = [next(keyword.value for keyword in call.keywords if keyword.arg == 'family') for call in calls]
        self.assertEqual({value.value for value in families if isinstance(value, ast.Constant)},
                         {'full', 'install', 'prepare', 'bundle-pipeline'})
        parents = {child: node for node in ast.walk(tree) for child in ast.iter_child_nodes(node)}
        prepare_owners = []
        for call in calls:
            family = next(k.value for k in call.keywords if k.arg == 'family')
            if not isinstance(family, ast.Constant) or family.value != 'prepare':
                continue
            owner = parents[call]
            while not isinstance(owner, ast.FunctionDef):
                owner = parents[owner]
            prepare_owners.append(owner.name)
        self.assertEqual(sorted(prepare_owners), ['diagnostic_prepare', 'prepare_tests_argv'])
        diagnostic = [node for node in ast.walk(tree) if isinstance(node, ast.FunctionDef)
                      and node.name == 'diagnostic_prepare']
        self.assertEqual(len(diagnostic), 1)
        diagnostic_calls = [node for node in ast.walk(diagnostic[0]) if isinstance(node, ast.Call)
                            and isinstance(node.func, ast.Name) and node.func.id == 'qualification_build_argv']
        self.assertEqual(len(diagnostic_calls), 1)
        self.assertEqual([ast.unparse(k.value) for k in diagnostic_calls[0].keywords if k.arg == 'family'], ["'prepare'"])
        self.assertEqual([ast.unparse(value) for value in families if not isinstance(value, ast.Constant)], ['label'])
        # Bundle labels are the fixed family allowlist; Reader is in the full normal graph.
        self.assertEqual(qualification.bundle_pipeline_tail_stages('full', None),
                         [('bundle-pipeline', ['test-bundle-pipeline'], 'bundle_pipeline_pass'),
                          ('bundle', ['test-bundle'], 'bundle_pass')])
        bindings = [node for node in ast.walk(tree) if isinstance(node, ast.Assign)
                    and any(isinstance(target, ast.Name) and target.id == 'captured_fingerprint'
                            for target in node.targets)]
        self.assertEqual(len(bindings), 2)
        self.assertTrue(all(ast.unparse(node.value) == 'bound_captured_source_fingerprint(cfg, auth)'
                            for node in bindings))
        self.assertIn('captured_source_fingerprint=captured_fingerprint', Path(qualification.__file__).read_text())

    def test_enabled_tail_requires_option_in_every_inherited_build_receipt(self):
        helper = CurrentTailRecoveryTests()
        self.addCleanup(helper.doCleanups)
        for defect in (None, 'missing', 'different', 'duplicate'):
            value = helper.fixture()
            namespace = value['namespace']
            namespace['captured_fingerprint'] = 'a' * 64
            namespace['bound_captured_source_fingerprint'] = lambda cfg, auth: 'a' * 64
            builds = [phase for phase in value['objects']['result']['phases']
                      if phase['name'].startswith('focused-prepare-') or phase['name'] in
                      ('cli-ffi-install', 'full-native-suite', 'bundle-pipeline', 'bundle')]
            for phase in builds:
                phase['command']['argv'] = ['zig', 'build', '-Dcaptured-source-fingerprint=' + 'a' * 64]
            if defect == 'missing': builds[-1]['command']['argv'].pop()
            elif defect == 'different': builds[-1]['command']['argv'][-1] = '-Dcaptured-source-fingerprint=' + 'b' * 64
            elif defect == 'duplicate': builds[-1]['command']['argv'].append(builds[-1]['command']['argv'][-1])
            with self.subTest(defect=defect):
                if defect is None:
                    exec(value['code'], namespace)
                    self.assertTrue(namespace['result']['full_native_pass'])
                else:
                    with self.assertRaises(AssertionError):
                        exec(value['code'], namespace)
                self.assertEqual(value['commands'], [])

    def test_tail_refuses_changed_captured_identity_before_any_command(self):
        helper = CurrentTailRecoveryTests()
        self.addCleanup(helper.doCleanups)
        value = helper.fixture()
        value['namespace']['captured_fingerprint'] = 'a' * 64
        with self.assertRaises(AssertionError):
            exec(value['code'], value['namespace'])
        self.assertEqual(value['commands'], [])


class PresentationSourceContractTests(unittest.TestCase):
    def test_abi10_source_requires_dprg_capability_without_relabeling_old_records(self):
        value = {'ABI': 10, 'wire': 'DPRG', 'selected_patch': {'sha256': 'source'}}
        original = copy.deepcopy(value)
        self.assertIsNone(qualification.require_presentation_source_contract(value))
        self.assertEqual(value, original)
        for invalid in (None, [], {}, {'ABI': 9, 'wire': 'DPRE'},
                        {'ABI': 9, 'wire': 'DPRG'}, {'ABI': 10, 'wire': 'DPRE'},
                        {'ABI': 10, 'wire': 'DPRD'}, {'ABI': 10, 'wire': 'DPRF'},
                        {'ABI': 10, 'wire': 'DPRH'}, {'ABI': 10.0, 'wire': 'DPRG'},
                        {'ABI': True, 'wire': 'DPRG'}, {'ABI': 10}, {'wire': 'DPRG'}):
            with self.subTest(binding=invalid), self.assertRaises(AssertionError):
                qualification.require_presentation_source_contract(invalid)

    def test_worker_checks_capability_before_full_suite_and_preserves_paired_reader_checks(self):
        import ast
        text = Path(qualification.__file__).read_text()
        tree = ast.parse(text)
        calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call)
                 and isinstance(node.func, ast.Name)
                 and node.func.id == 'require_presentation_source_contract']
        self.assertEqual(len(calls), 1)
        self.assertEqual([ast.unparse(arg) for arg in calls[0].args], ['private_binding'])
        control = FailedFullCollectionTests()
        code = control.full_boundary(include_capability=True)
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as tmp:
            private = Path(tmp)
            header = private / 'dict.h'
            header.write_text('#define DICT_ABI_VERSION 10u\n')
            (private / 'compiler/tools').mkdir(parents=True)
            (private / 'compiler/tools/ffi_integration_test.c').write_text('DICT_ABI_VERSION == 10u && dict_abi_version() == DICT_ABI_VERSION')
            for binding, expected_events in (({'ABI': 9, 'wire': 'DPRG'}, ['capability']),
                                             ({'ABI': 10, 'wire': 'DPRF'}, ['capability']),
                                             ({'ABI': 10, 'wire': 'DPRG'}, ['capability','cli-auth','dynamic','full'])):
                events = []
                def capability(value):
                    events.append('capability')
                    qualification.require_presentation_source_contract(value)
                def full(label, argv):
                    events.append('full')
                    self.assertEqual(label, 'full-native-suite')
                    self.assertIn('-Doptimize=safe', argv)
                    return dict(status='exited',returncode=1), '', ''
                result = dict(full_native_pass=False, installed={
                    'include/dict/dict.h': dict(path=str(header),sha256='fixture'),
                    'bin/wikidict': dict(path='/bound-cli')})
                ns = dict(require_presentation_source_contract=capability,private_binding=binding,
                    result=result,private_manifest={'renderer/src/ffi/dict.h':{'sha256':'fixture'},'compiler/tools/ffi_integration_test.c':{}},private=private,Path=Path,
                    qualification_source_key=qualification.qualification_source_key,
                    auth=lambda value:events.append('cli-auth'),
                    dynamic={'validate':lambda state,**kw:events.append('dynamic')},ds={},save=lambda:None,
                    qualification_build_argv=qualification.qualification_build_argv,
                    args=SimpleNamespace(compiler=Path('/zig')),cache=private/'cache',
                    w={'native_build_argv':lambda a,c:['/zig','build','test','-j1','-Doptimize=safe']},
                    execute_outcome=full,cfg={})
                with self.assertRaises(AssertionError):exec(code,ns)
                self.assertEqual(events,expected_events)
                self.assertFalse(result['full_native_pass'])
        # This old-format fixture remains mandatory even though capability is G.
        self.assertIn("auth(ref(payload)).read_bytes().startswith(b'DPRD')", text)
        self.assertIn('normal_reader_checks=50', text)
        self.assertIn('ffi_child_marker_asserted_inside_native_harness=True', text)
        self.assertIn("result['full_native_pass']=True", text)


class BindingContractTests(unittest.TestCase):
    def fixture(self, selected=None):
        value = DocumentPartitionPreparationTests().fixture()
        cfg, proof = value['cfg'], value['group_binding']
        if selected is not None:
            cfg['groups'] = [group for group in cfg['groups'] if group['id'] in selected]
            SupportedRootSubsetTests().bind_selection(cfg, proof)
        proof['compile_time_filtered_preparation'] = any(
            group['compile_time_filtered'] for group in cfg['groups'])
        return cfg, proof, value['expect']

    def plan(self, cfg, proof, expectation):
        return qualification.qualification_binding_plan(
            cfg, proof, expectation, Path('/fixture/source'))

    def test_canonical_order_preserves_selected_groups_and_priority(self):
        cfg, proof, expectation = self.fixture()
        shuffled = list(reversed(cfg['groups']))
        before = copy.deepcopy(shuffled)
        ordered = qualification.canonical_preparation_groups(shuffled)
        self.assertEqual([group['id'] for group in ordered],
                         ['encoder_compile', 'encoder_document', 'encoder_writer',
                          'encoder_support', 'lua', 'closure', 'tools'])
        self.assertEqual(shuffled, before)
        self.assertEqual(ordered, cfg['groups'])
        doc = next(group for group in ordered if group['id'] == 'encoder_document')
        proof['focus_priority'] = [dict(group=doc['id'], name=doc['test_names'][0])]
        plan = self.plan(cfg, proof, expectation)
        self.assertEqual(plan['prepared_groups'][0], 'encoder_compile')
        self.assertEqual(plan['actual_case_order'][0]['group'], 'encoder_document')

    def test_canonical_order_rejects_unknown_or_duplicate_roots(self):
        for groups in ([dict(id='unknown')], [dict(id='tools'), dict(id='tools')], []):
            with self.subTest(groups=groups), self.assertRaises(AssertionError):
                qualification.canonical_preparation_groups(groups)

    def test_contract_derives_full_gate_and_independent_failure_collection(self):
        cfg, proof, expectation = self.fixture()
        for stage, full_required in (('full', True), ('focused-diagnostic', False)):
            cfg['execution_stage'] = stage
            plan = self.plan(cfg, proof, expectation)
            self.assertEqual(len(plan['actual_case_order']), 7)
            self.assertEqual(plan['compiled_counts'], dict(
                encoder_compile=2, encoder_document=2, encoder_writer=2,
                encoder_support=1, lua=1, closure=1, tools=1))
            self.assertIs(plan['functional_failures_collected'], True)
            self.assertIs(plan['aggregate_full_gate_retained'], True)
            self.assertIs(plan['normal_full_required'], full_required)

    def test_required_roles_counts_and_independent_inventory_refuse(self):
        for key in ('private_manifest', 'private_source_binding'):
            cfg, proof, expectation = self.fixture()
            del cfg[key]
            with self.subTest(missing=key), self.assertRaises(KeyError):
                self.plan(cfg, proof, expectation)
        for defect in ('compiled-count', 'source-binding', 'expected-inventory'):
            cfg, proof, expectation = self.fixture()
            if defect == 'compiled-count':
                cfg['groups'][0]['compiled_expected_count'] -= 1
                proof['groups'] = copy.deepcopy(cfg['groups'])
            elif defect == 'source-binding':
                proof['source_binding'] = {'sha256': 'different'}
            else:
                expectation['expected']['groups'][0]['expected_occurrences'] = ['foreign.test.name']
            with self.subTest(defect=defect), self.assertRaises(AssertionError):
                self.plan(cfg, proof, expectation)

    def test_tools_only_and_mixed_selection_require_matching_structural_flag(self):
        for selected, expected_flag in ((['tools'], False), (['encoder_document', 'tools'], True)):
            cfg, proof, expectation = self.fixture(selected)
            self.assertIs(proof['compile_time_filtered_preparation'], expected_flag)
            plan = self.plan(cfg, proof, expectation)
            self.assertEqual(plan['prepared_groups'], selected)
            self.assertEqual(len(plan['actual_case_order']), len(selected))
            proof['compile_time_filtered_preparation'] = not expected_flag
            with self.subTest(selected=selected), self.assertRaises(AssertionError):
                self.plan(cfg, proof, expectation)




class ExactDiscoveryEvidenceTests(unittest.TestCase):
    def fixture(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        return FakeExecution(Path(tmp.name))

    def test_exact_unknown_name_rejection_overrides_bound_inventory(self):
        fake = self.fixture(); name = 'encoder.test.second'
        fake.outcomes['encoder-01'] = dict(status='exited', returncode=1)
        fake.outputs['encoder-01'] = ('', 'unknown test: ' + name + '\n')
        fake.run(); rows = fake.result['focused_tests']
        rejected = next(row for row in rows if row['name'] == name)
        self.assertFalse(rejected['passed'] or rejected['exact_name_discovered'])
        self.assertEqual(rejected['exact_name_discovery'], dict(prepared_occurrences=1, unknown_name_rejected=True))
        self.assertEqual(len(rows), 6)
        self.assertTrue(all(row['exact_name_discovered'] for row in rows if row is not rejected))

    def test_page_prose_and_partial_unknown_lines_are_not_rejection_authority(self):
        name = 'encoder.test.second'
        for stdout, stderr in [('raw page unknown test: ' + name + '\n', ''),
                               ('', 'context\nunknown test: ' + name + '\nInvalidPreContext\n'),
                               ('', 'unknown test: other.test.name\n'),
                               ('printed output\n', 'unknown test: ' + name + '\n')]:
            with self.subTest(stdout=stdout, stderr=stderr):
                fake = self.fixture(); fake.outcomes['encoder-01'] = dict(status='exited', returncode=1)
                fake.outputs['encoder-01'] = stdout, stderr
                fake.run(); row = fake.result['focused_tests'][1]
                self.assertTrue(row['exact_name_discovered'])
                self.assertFalse(row['passed'] or row['exact_name_discovery']['unknown_name_rejected'])

    def test_unbound_or_nonunique_inventory_and_failed_dispatch_remain_uncertain(self):
        for inventory in (None, [], {'encoder.test.second': 2}, {'encoder.test.second': True}):
            with self.subTest(inventory=inventory):
                fake = self.fixture()
                if inventory is None: del fake.groups[0]['compiled_expected_occurrences']
                else: fake.groups[0]['compiled_expected_occurrences'] = inventory
                fake.outcomes['encoder-01'] = dict(status='exited', returncode=1)
                fake.run(); row = fake.result['focused_tests'][1]
                self.assertIsNone(row['exact_name_discovered']); self.assertFalse(row['passed'])
        for status, returncode in (('timeout', None), ('running', None), ('unknown', None),
                                   ('exited', -9), ('exited', False), ('exited', True),
                                   ('exited', 0.0), ('exited', '0')):
            fake = self.fixture(); fake.outcomes['encoder-01'] = dict(status=status, returncode=returncode)
            fake.run(); row = fake.result['focused_tests'][1]
            self.assertIsNone(row['exact_name_discovered']); self.assertFalse(row['passed'])


class PreparationTracingTests(unittest.TestCase):
    def test_tracing_is_explicit_correctness_prepare_only_with_old_default_argv(self):
        from types import SimpleNamespace
        args = SimpleNamespace(compiler=Path('/fixture/zig'))
        cache, prefix = Path('/fixture/cache'), Path('/fixture/install')
        def native(args, cache): return [str(args.compiler), 'build', 'test', '-j1']
        old = [str(args.compiler), 'build', 'prepare-tests', '-j2', '--prefix', str(prefix)]
        self.assertEqual(qualification.qualification_build_argv(args, cache, native, family='prepare', prefix=prefix), old)
        traced = qualification.qualification_build_argv(args, cache, native, family='prepare', prefix=prefix, prepare_test_error_tracing=True)
        self.assertEqual(traced, old + ['-Dprepare-test-error-tracing=true'])
        for family in ('full', 'install', 'bundle-pipeline', 'bundle'):
            options = dict(family=family, prefix=None if family == 'full' else prefix)
            plain = qualification.qualification_build_argv(args, cache, native, **options)
            self.assertFalse(any(arg.startswith('-Dprepare-test-error-tracing') for arg in plain))
            with self.assertRaises(AssertionError):
                qualification.qualification_build_argv(args, cache, native, prepare_test_error_tracing=True, **options)
        for bad in (None, 1, 'true'):
            with self.assertRaises(AssertionError):
                qualification.qualification_build_argv(args, cache, native, family='prepare', prefix=prefix, prepare_test_error_tracing=bad)
        with self.assertRaises(AssertionError):
            qualification.qualification_build_argv(args, cache,
                lambda args, cache: native(args, cache) + ['-Dprepare-test-error-tracing=true'], family='prepare', prefix=prefix, prepare_test_error_tracing=True)

    def test_real_preparation_prefix_forwards_one_tracing_flag_in_both_correctness_stages(self):
        for stage in ('full', 'focused-diagnostic'):
            cfg, proof, expect = DiagnosticPreparationPlanTests().plan(['tools'], stage)
            proof['prepare_test_error_tracing'] = True
            commands = []
            PreparationFailFastTests().execute_prefix(cfg, proof, expect, commands)
            prepared = [argv for label, argv in commands if label.startswith('focused-prepare-')]
            self.assertEqual(len(prepared), 1)
            self.assertEqual([arg for arg in prepared[0] if arg.startswith('-Dprepare-test-error-tracing')], ['-Dprepare-test-error-tracing=true'])
        for bad in (1, None, 'true'):
            cfg, proof, expect = DiagnosticPreparationPlanTests().plan(['tools'], 'full')
            proof['prepare_test_error_tracing'] = bad; commands = []
            with self.assertRaises(AssertionError):
                PreparationFailFastTests().execute_prefix(cfg, proof, expect, commands)
            self.assertEqual(commands, [])

    def test_traced_tail_requires_exact_inherited_prepare_flags_without_other_build_changes(self):
        choices = [(True, defect) for defect in (None, 'missing', 'duplicate', 'false', 'full')] + [(False, None), (False, 'unexpected-trace')]
        for traced, defect in choices:
            owner = CurrentTailRecoveryTests(); self.addCleanup(owner.doCleanups)
            value = owner.fixture(); namespace = value['namespace']
            namespace['group_binding']['prepare_test_error_tracing'] = traced
            phases = value['objects']['result']['phases']
            for phase in phases:
                phase['command']['argv'] = ['zig', 'build']
                if traced and phase['name'].startswith('focused-prepare-'):
                    phase['command']['argv'].append('-Dprepare-test-error-tracing=true')
            first = next(phase for phase in phases if phase['name'].startswith('focused-prepare-'))
            if defect == 'missing': first['command']['argv'].pop()
            elif defect == 'duplicate': first['command']['argv'].append('-Dprepare-test-error-tracing=true')
            elif defect == 'false': first['command']['argv'][-1] = '-Dprepare-test-error-tracing=false'
            elif defect == 'full': next(phase for phase in phases if phase['name'] == 'full-native-suite')['command']['argv'].append('-Dprepare-test-error-tracing=true')
            elif defect == 'unexpected-trace': first['command']['argv'].append('-Dprepare-test-error-tracing=true')
            if defect is None:
                exec(value['code'], namespace)
                self.assertTrue(namespace['result']['full_native_pass'])
            else:
                with self.assertRaises(AssertionError): exec(value['code'], namespace)
            self.assertEqual(value['commands'], [])


class FailedFullCollectionTests(unittest.TestCase):
    helper = dict(ANSI=re.compile(r'\x1b\[[0-9;]*m'),
                  STATUS=re.compile(r'^(ok|error|skip|leak|crash) (.*?)(?: \| .*|)$', re.M),
                  SUMMARY=re.compile(r'^pass: (\d+)  fail: (\d+)  skip: (\d+)  leak: (\d+)  crash: (\d+)$', re.M))

    def fixture(self):
        groups = [dict(root=root, expected_occurrences={root+'.test.fixture': 1})
                  for root, _, _ in qualification.LEGACY_FULL_DIAGNOSTIC_ROOTS]
        return dict(groups=groups, expected_groups=26, expected_total=26)

    def output(self, groups, failed=()):
        lines = []
        for g in groups:
            bad = g['root'] in failed
            for name, count in g['expected_occurrences'].items():
                lines.extend([('error ' if bad else 'ok ')+name+(' | err: TestUnexpectedResult error return trace unavailable (enable error tracing for this test build)  | exit 1' if bad else '')]*count)
            count = sum(g['expected_occurrences'].values())
            lines += [f'pass: {0 if bad else count}  fail: {count if bad else 0}  skip: 0  leak: 0  crash: 0']
        return '\n'.join(lines)+'\n'

    def failed_output(self, expected, index):
        groups = expected['groups'][:index+1]
        text = self.output(groups, {groups[-1]['root']})
        return text+'error: process exited with code 1\nBuild Summary: 3/9 steps succeeded (1 failed)\n+- run test failure\n   +- compile test safe transitive failure\n'

    def plan(self, index=0):
        e = self.fixture()
        return qualification.failed_full_diagnostic_plan(e, self.helper,
                    dict(status='exited', returncode=1), '', self.failed_output(e, index))

    def test_early_and_middle_failure_collect_only_unrun_serial_roots(self):
        for index in (0, 12):
            plan = self.plan(index); events=[]; saved=[]
            def prepare(g):
                events.append(('prepare', g['root'])); return dict(path=g['root'])
            def run(g,b):
                events.append(('run', g['root']));return dict(status='exited',returncode=0),'',self.output([g])
            report=qualification.collect_failed_full_roots(plan,helper=self.helper,guarded_prepare=prepare,guarded_run=run,
                          auth=lambda b:None,save=lambda r:saved.append(copy.deepcopy(r)))
            remaining=[g['root'] for g in plan['remaining']]
            self.assertEqual(events,[(action,root) for root in remaining for action in ('prepare','run')])
            self.assertEqual([r['root'] for r in report['roots']],remaining)
            self.assertTrue(report['completed']);self.assertFalse(report['full_suite_credit'])
            self.assertTrue(report['original_full_failure_preserved'])
            self.assertTrue(all(not r['full_suite_credit'] for r in report['roots']))
            self.assertNotIn('current_root',saved[-1])

    def test_returned_terminal_survives_truncated_human_prefix_and_keeps_legacy(self):
        e = self.fixture()
        legacy = 'TestUnexpectedResult error return trace unavailable (enable error tracing for this test build)  | exit 1'
        for error in qualification.FUNCTIONAL_TEST_ERRORS:
            for human in ('short assertion', 'expected false, found true ' * 100):
                terminal = human[:2000] + '... | exit 1 | returned-error-hex=' + error.encode().hex()
                text = self.failed_output(e, 0).replace(legacy, terminal)
                plan = qualification.failed_full_diagnostic_plan(e, self.helper, dict(status='exited', returncode=1), '', text)
                self.assertTrue(plan['observed']['closure_tests']['failed'])
                self.assertEqual(len(plan['remaining']), 25)
        self.assertEqual(len(self.plan()['remaining']), 25)

    def test_returned_terminal_never_admits_malformed_or_nonfunctional_error(self):
        e = self.fixture()
        legacy = 'TestUnexpectedResult error return trace unavailable (enable error tracing for this test build)  | exit 1'
        functional = b'TestExpectedEqual'.hex()
        encoded_cases = ['', functional[:-1], functional.upper(), 'gg', '00', 'ff',
                         b'1TestExpectedEqual'.hex(), b'TestExpectedEqual\n'.hex(), '61' * 129]
        encoded_cases += [name.encode().hex() for name in ('OutOfMemory', 'InvalidLanguageMetadataModel',
                          'ContainmentUnavailable', 'UnknownReturnedError', 'SkipZigTest',
                          'FileNotFound', 'InvalidFigurePageObservations')]
        terminals = [legacy + ' | returned-error-hex=' + value for value in encoded_cases]
        terminals += ['assertion | exit 3 | returned-error-hex=' + functional,
                      'assertion | signal 9 | returned-error-hex=' + functional,
                      'assertion | unknown 1 | returned-error-hex=' + functional,
                      'assertion | exit 1 | returned-error-hex=' + functional + ' trailing',
                      'assertion | returned-error-hex=' + functional + ' | exit 1',
                      legacy + ' | returned-error-hex: ' + functional]
        for terminal in terminals:
            with self.subTest(terminal=terminal), self.assertRaises(AssertionError):
                qualification.failed_full_diagnostic_plan(e, self.helper, dict(status='exited', returncode=1), '', self.failed_output(e, 0).replace(legacy, terminal))

    def test_returned_terminal_retains_inventory_exit_and_nonfailure_status_guards(self):
        e = self.fixture()
        legacy = 'TestUnexpectedResult error return trace unavailable (enable error tracing for this test build)  | exit 1'
        text = self.failed_output(e, 0).replace(legacy, 'assertion... | exit 1 | returned-error-hex=' + b'TestUnexpectedResult'.hex())
        for status in ('leak', 'crash', 'skip'):
            with self.subTest(status=status), self.assertRaises(AssertionError):
                qualification.failed_full_diagnostic_plan(e, self.helper, dict(status='exited', returncode=1), '', text.replace('error closure_tests', status + ' closure_tests'))
        for command in (dict(status='timeout', returncode=1), dict(status='exited', returncode=3), dict(status='exited', returncode=True)):
            with self.subTest(command=command), self.assertRaises(AssertionError):
                qualification.failed_full_diagnostic_plan(e, self.helper, command, '', text)
        for changed in (text.replace('closure_tests.test.fixture', 'foreign.test.fixture'),
                        text.replace('pass: 0  fail: 1', 'pass: 1  fail: 0'),
                        text + 'error: compiler executable missing\n'):
            with self.subTest(changed=changed), self.assertRaises(AssertionError):
                qualification.failed_full_diagnostic_plan(e, self.helper, dict(status='exited', returncode=1), '', changed)

    def test_unknown_duplicate_missing_or_ambiguous_inventory_refuses(self):
        for defect in ('unknown','duplicate','missing','empty','count','bool','ambiguous'):
            e=self.fixture()
            if defect=='unknown':e['groups'][0]['root']='foreign'
            elif defect=='duplicate':e['groups'][0]['root']=e['groups'][1]['root']
            elif defect=='missing':e['groups'].pop()
            elif defect=='empty':e['groups'][0]['expected_occurrences']={}
            elif defect=='count':e['expected_total']+=1
            elif defect=='bool':e['groups'][0]['expected_occurrences'][e['groups'][0]['root']+'.test.fixture']=True
            else:e['groups'][1]['expected_occurrences']=dict(e['groups'][0]['expected_occurrences'])
            with self.subTest(defect=defect),self.assertRaises(AssertionError):qualification.full_diagnostic_groups(e)

    def test_nonfunctional_full_outcomes_never_authorize_collection(self):
        e=self.fixture();text=self.failed_output(e,0)
        variants=[(dict(status='timeout',returncode=1),text),(dict(status='exited',returncode=True),text),
                  (dict(status='exited',returncode=-9),text),(dict(status='exited',returncode=0),text)]
        variants += [(dict(status='exited',returncode=1),changed) for changed in (
            text.replace('TestUnexpectedResult','OutOfMemory'),text.replace(' | exit 1',' | signal 9'),
            text.replace('TestUnexpectedResult','ContainmentUnavailable'),
            text.replace('TestUnexpectedResult','UnknownReturnedError'),
            text.replace('error return trace unavailable (enable error tracing for this test build)','/source/code.zig:99: traced error'),
            text+'error: compiler executable missing\n',text.replace('+- run test failure','+- compile test failure'),
            text.replace('(1 failed)','(2 failed)'),text.replace('closure_tests.test.fixture','foreign.test.fixture'),
            text+self.output(e['groups'][:1]),text.replace('pass: 0  fail: 1','pass: 1  fail: 0'),
            text.replace('error closure_tests','crash closure_tests'),text.replace('error: process exited with code 1',''),
            text.replace('pass: 0  fail: 1  skip: 0  leak: 0  crash: 0',''))]
        for command,se in variants:
            with self.subTest(command=command,se=se),self.assertRaises(AssertionError):
                qualification.failed_full_diagnostic_plan(e,self.helper,command,'',se)

    def test_pass_names_and_assertion_prose_are_not_resource_authority(self):
        e=self.fixture()
        e['groups'][0]['expected_occurrences']={'site_info.test.site info allocation failures preserve OutOfMemory and release parser storage':1}
        e['groups'][1]['expected_occurrences']={'provider.test.watchdog Timeout literal user title':1}
        text=self.failed_output(e,1).replace('TestUnexpectedResult error return',
                  'expected OutOfMemory ContainmentUnavailable SystemResources from watchdog Timeout input TestUnexpectedResult error return')
        plan=qualification.failed_full_diagnostic_plan(e,self.helper,dict(status='exited',returncode=1),'',text)
        self.assertEqual(set(plan['observed']),{'closure_tests','provider_tests'})
        repeated=text+'|  +- run test failure\n'
        duplicate=qualification.failed_full_diagnostic_plan(e,self.helper,dict(status='exited',returncode=1),'',repeated)
        self.assertEqual(duplicate['observed'],plan['observed'])
        report=qualification.collect_failed_full_roots(plan,helper=self.helper,
            guarded_prepare=lambda g:dict(path=g['root']),guarded_run=lambda g,b:(dict(status='exited',returncode=0),'',self.output([g])+'literal OutOfMemory watchdog expected-error prose\n'),
            auth=lambda b:None,save=lambda r:None)
        self.assertTrue(report['completed']);self.assertFalse(report['full_suite_credit'])

    def test_compile_guard_and_resource_errors_stop_without_pass_credit(self):
        for defect in ('compile','guard','auth','resource','tool','unknown','status'):
            plan=self.plan();events=[];saved=[]
            def guard():
                if defect=='guard':raise RuntimeError('source changed')
            def auth(b):
                if defect=='auth':raise RuntimeError('binary changed')
            def prepare(g):
                guard()
                events.append('prepare')
                if defect=='compile':raise RuntimeError('compile failed; command retained')
                return dict(path=g['root'])
            def run(g,b):
                events.append('run');out=self.output([g])
                if defect=='resource':out=self.output([g],{g['root']}).replace('TestUnexpectedResult','ContainmentUnavailable')
                if defect=='tool':out=self.output([g],{g['root']})+'error: tool execution failed\n'
                if defect=='unknown':out=out.replace(g['root'],'unknown')
                return dict(status='exited',returncode=True if defect=='status' else int(defect in ('resource','tool'))),'',out
            with self.subTest(defect=defect),self.assertRaises((RuntimeError,AssertionError)):
                qualification.collect_failed_full_roots(plan,helper=self.helper,guarded_prepare=prepare,guarded_run=run,auth=auth,save=lambda r:saved.append(copy.deepcopy(r)))
            self.assertLessEqual(events.count('prepare'),1)
            self.assertFalse(saved[-1]['completed']);self.assertEqual(saved[-1]['roots'],[])
            self.assertFalse(saved[-1]['full_suite_credit'])

    def test_later_functional_failure_does_not_hide_remaining_roots(self):
        plan=self.plan(23);fail=plan['remaining'][0]['root']
        def run(g,b):return dict(status='exited',returncode=int(g['root']==fail)),'',self.output([g],{fail})
        report=qualification.collect_failed_full_roots(plan,helper=self.helper,guarded_prepare=lambda g:dict(path=g['root']),
                      guarded_run=run,auth=lambda b:None,save=lambda r:None)
        self.assertEqual([r['passed'] for r in report['roots']],[False,True])
        self.assertTrue(report['completed']);self.assertFalse(report['full_suite_credit'])

    def guarded_collection_fixture(self, *, source_change=None, binary_change=None, fail_first=False):
        """Run the actual command boundary with real files and a fake native executor."""
        import ast
        tree = ast.parse(Path(qualification.__file__).read_text())
        functions = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == 'execute_outcome']
        self.assertEqual(len(functions), 1)
        code = compile(ast.fix_missing_locations(ast.Module(body=functions, type_ignores=[])),
                       '<actual-guarded-command-boundary>', 'exec')
        state = dict(started=[], guards=[], saved=[], report=None, error=None)
        plan = self.plan(23)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); out = root / 'commands'; out.mkdir()
            source = root / 'source.zig'; source.write_bytes(b'const original = true;\n')
            expected_source = hashlib.sha256(source.read_bytes()).hexdigest()
            def ref(path):
                data = Path(path).read_bytes()
                return dict(path=str(path), bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
            def guard():
                state['guards'].append(len(state['started']))
                self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), expected_source, 'source changed')
            def auth(binary):
                self.assertEqual(ref(binary['path']), binary, 'binary changed')
            def mutate_source():
                source.write_bytes(b'const changed = true;\n')
            def fake_execute(directory, label, argv, cwd):
                phase, name = label.split(':', 1)
                group = next(g for g in plan['remaining'] if g['root'] == name)
                state['started'].append(label)
                binary = root / (name + '.binary')
                if phase == 'compile': binary.write_bytes(b'exact prepared test bytes')
                if source_change == ('during', phase): mutate_source()
                if binary_change == 'during-test' and phase == 'test': binary.write_bytes(b'changed binary')
                failed = phase == 'test' and fail_first and group == plan['remaining'][0]
                (directory / (label + '.stdout')).write_text('')
                (directory / (label + '.stderr')).write_text(self.output([group], {name} if failed else ()) if phase == 'test' else '')
                return dict(status='exited', returncode=int(failed))
            ns = dict(guard=guard, dynamic={'validate': lambda state: None}, ds={},
                      w={'execute': fake_execute}, out=out, private=root, result={'phases': []},
                      ref=ref, save=lambda: None,
                      execute_with_failure_output=qualification.execute_with_failure_output)
            exec(code, ns)
            def prepare(group):
                if source_change == ('before', 'compile'): mutate_source()
                command, _, _ = ns['execute_outcome']('compile:' + group['root'], [])
                self.assertEqual(command['returncode'], 0)
                binary = ref(root / (group['root'] + '.binary'))
                if binary_change == 'after-prepare': Path(binary['path']).write_bytes(b'changed binary')
                return binary
            def run(group, binary):
                if source_change == ('before', 'test'): mutate_source()
                return ns['execute_outcome']('test:' + group['root'], [binary['path']])
            try:
                state['report'] = qualification.collect_failed_full_roots(plan, helper=self.helper,
                    guarded_prepare=prepare, guarded_run=run, auth=auth,
                    save=lambda report: state['saved'].append(copy.deepcopy(report)))
            except AssertionError as error:
                state['error'] = error
        return state, plan

    def test_actual_command_boundary_refuses_source_mutation_before_and_during_compile_and_test(self):
        for when, phase, started, guards in (('before', 'compile', 0, 1), ('during', 'compile', 1, 2),
                                             ('before', 'test', 1, 3), ('during', 'test', 2, 4)):
            with self.subTest(when=when, phase=phase):
                state, _ = self.guarded_collection_fixture(source_change=(when, phase))
                self.assertIsInstance(state['error'], AssertionError)
                self.assertIn('source changed', str(state['error']))
                self.assertEqual(len(state['started']), started)
                self.assertEqual(len(state['guards']), guards)
                self.assertIsNone(state['report'])
                self.assertEqual(state['saved'][-1]['roots'], [])
                self.assertFalse(state['saved'][-1]['completed'])
                self.assertFalse(state['saved'][-1]['full_suite_credit'])

    def test_collector_refuses_actual_binary_mutation_after_prepare_and_test(self):
        for change, started in (('after-prepare', 1), ('during-test', 2)):
            with self.subTest(change=change):
                state, _ = self.guarded_collection_fixture(binary_change=change)
                self.assertIsInstance(state['error'], AssertionError)
                self.assertIn('binary changed', str(state['error']))
                self.assertEqual(len(state['started']), started)
                self.assertIsNone(state['report'])
                self.assertEqual(state['saved'][-1]['roots'], [])
                self.assertFalse(state['saved'][-1]['full_suite_credit'])

    def test_guarded_commands_keep_all_roots_and_failure_evidence_without_duplicate_scans(self):
        state, plan = self.guarded_collection_fixture(fail_first=True)
        self.assertIsNone(state['error'])
        expected = [phase + ':' + group['root'] for group in plan['remaining'] for phase in ('compile', 'test')]
        self.assertEqual(state['started'], expected)
        self.assertEqual(state['guards'], [0, 1, 1, 2, 2, 3, 3, 4])
        report = state['report']
        self.assertEqual([row['root'] for row in report['roots']], [group['root'] for group in plan['remaining']])
        self.assertEqual([row['passed'] for row in report['roots']], [False, True])
        self.assertTrue(report['completed'])
        self.assertTrue(report['original_full_failure_preserved'])
        self.assertFalse(report['full_suite_credit'])

    def full_boundary(self, include_capability=False):
        import ast
        tree=ast.parse(Path(qualification.__file__).read_text())
        def search(node):
            for _,value in ast.iter_fields(node):
                if isinstance(value,list):
                    for i,item in enumerate(value):
                        if isinstance(item,ast.Assign) and isinstance(item.targets[0],ast.Tuple) and any(isinstance(n,ast.Name) and n.id=='full_command' for n in item.targets[0].elts):
                            start = i
                            if include_capability:
                                matches = [j for j, statement in enumerate(value[:i]) if isinstance(statement,ast.Expr)
                                           and isinstance(statement.value,ast.Call) and isinstance(statement.value.func,ast.Name)
                                           and statement.value.func.id=='require_presentation_source_contract']
                                self.assertEqual(len(matches),1)
                                start=matches[0]
                            return value[start:i+2]
                        if isinstance(item,ast.AST):
                            found=search(item)
                            if found:return found
                elif isinstance(value,ast.AST):
                    found=search(value)
                    if found:return found
        body=search(tree);self.assertGreaterEqual(len(body),2)
        return compile(ast.fix_missing_locations(ast.Module(body=body,type_ignores=[])),'<actual-full-failure-boundary>','exec')

    def test_actual_worker_boundary_retains_original_failure_and_normal_build_args(self):
        from types import SimpleNamespace
        e=self.fixture();recorded=[]
        with tempfile.TemporaryDirectory() as tmp:
            out=Path(tmp);cache=out/'same-cache';args=SimpleNamespace(compiler=Path('/zig'),captured_source_fingerprint='a'*64)
            def build_args(a,c):
                self.assertIs(a,args);self.assertEqual(c,cache)
                return ['/zig','build','test','-j1','-Doptimize=safe','-Dtarget=x86_64-native','-Dcpu=baseline','--cache-dir',str(c/'local')]
            result=dict(full_native_pass=False,phases=[])
            def execute_outcome(label,argv):
                recorded.append((label,argv));command=dict(status='exited',returncode=1 if label=='full-native-suite' else 0)
                result['phases'].append(dict(name=label,command=command))
                if label=='full-native-suite':return command,'',self.failed_output(e,23)
                g=next(g for g in qualification.full_diagnostic_groups(e) if label=='failed-full-run-'+g['root'])
                return command,'',self.output([g])
            def execute(label,argv):
                recorded.append((label,argv));prefix=Path(argv[argv.index('--prefix')+1]);alias=argv[-1].split('=',1)[1]
                d=prefix/'bin/wikidict-tests';d.mkdir(parents=True);f=d/alias;f.write_text('fixture');f.chmod(0o755)
            ns=dict(cfg={'collect_unrun_full_roots':True},expect={'expected':e},w={'native_build_argv':build_args,**self.helper},
                    full_argv=['original-full-argv'],args=args,cache=cache,out=out,Path=Path,os=__import__('os'),result=result,
                    save=lambda:None,auth=lambda b:None,ref=lambda p:dict(path=str(p)),execute=execute,
                    execute_outcome=execute_outcome,qualification_build_argv=qualification.qualification_build_argv,
                    failed_full_diagnostic_plan=qualification.failed_full_diagnostic_plan,collect_failed_full_roots=qualification.collect_failed_full_roots)
            with self.assertRaisesRegex(AssertionError,'full-native-suite'):exec(self.full_boundary(),ns)
            self.assertFalse(result['full_native_pass']);self.assertTrue(result['failed_full_collection']['completed'])
            self.assertEqual(result['original_full_failure']['name'],'full-native-suite')
            self.assertEqual([label for label,_ in recorded],['full-native-suite','failed-full-prepare-blob_file_tools_tests','failed-full-run-blob_file_tools_tests','failed-full-prepare-missing_dependency_tests','failed-full-run-missing_dependency_tests'])
            for label,argv in recorded:
                if 'prepare' in label:
                    self.assertIn('-j2',argv);self.assertIn('-Doptimize=safe',argv)
                    self.assertIn('-Dcaptured-source-fingerprint='+'a'*64,argv)
                    self.assertFalse(any(a.startswith('-Dprepare-test-error-tracing') for a in argv))
                    self.assertEqual(argv[argv.index('--cache-dir')+1],str(cache/'local'))

    def test_default_and_success_boundary_do_not_start_collection(self):
        for status,code in [('exited',0),('exited',1),('timeout',None)]:
            result={'full_native_pass':False};calls=[]
            ns=dict(execute_outcome=lambda *a:(dict(status=status,returncode=code),'',''),full_argv=[],cfg={},result=result,
                    failed_full_diagnostic_plan=lambda *a:calls.append('forbidden'))
            if code==0:exec(self.full_boundary(),ns)
            else:
                with self.assertRaises(AssertionError):exec(self.full_boundary(),ns)
            self.assertEqual(calls,[]);self.assertFalse(result['full_native_pass'])




class BundlePipelineFullReuseTests(unittest.TestCase):
    def fixture(self):
        f = FailedFullCollectionTests()
        expected = f.fixture()
        pipeline = next(g for g in expected['groups'] if g['root'] == 'bundle_pipeline_tests')
        pipeline['expected_occurrences'] = {'bundle_pipeline.test.case%d' % n: 1 for n in range(23)}
        expected['expected_total'] = 48
        graph = qualification.PIPELINE_REUSE_GRAPH_FRAGMENT + '\n'.join([
            '    const test_optimize: std.builtin.Optimize = .safe;',
            '    run_bundle_pipeline_tests.step.dependOn(&blob_wasm_smoke.step);',
            '    run_blob_build_tests.step.dependOn(&run_bundle_pipeline_tests.step);',
            '    test_step.dependOn(&run_blob_build_tests.step);',
            '    b.step("test-bundle-pipeline", "Run bundle build scheduler and cache bitmap unit tests only").dependOn(&run_bundle_pipeline_tests_only.step);'])
        descriptor = dict(path='/source/build.zig', bytes=len(graph.encode()), sha256=hashlib.sha256(graph.encode()).hexdigest())
        expected['build_graph'] = descriptor
        # Mock only the trusted profile bytes for this bounded synthetic graph.
        # Production always uses the literal reviewed installed-graph fingerprint.
        from unittest.mock import patch
        profile = patch.object(qualification, 'PIPELINE_REUSE_GRAPH_PROFILE', {key: descriptor[key] for key in ('bytes','sha256')})
        profile.start(); self.addCleanup(profile.stop)
        common = ['-j2','-Doptimize=safe','-Dtarget=x86_64-native','-Dcpu=baseline',
                  '--summary','all','--search-prefix','/usr','--cache-dir','/cache/local',
                  '-Dcaptured-source-fingerprint='+'a'*64]
        full = ['/zig','build','test'] + common
        return dict(expected=expected,helper=f.helper,
                    phase=dict(name='full-native-suite',command=dict(status='exited',returncode=0,cwd='/source',argv=full)),
                    stdout='',stderr=f.output(expected['groups']),build_graph=descriptor,build_source=graph,
                    source_manifest=dict(path='/source-inventory.json',sha256='a'*64),
                    full_configuration=dict(path='/full-config.json',sha256='b'*64),source_root=Path('/source'),
                    full_argv=full,standalone_argv=['/zig','build','test-bundle-pipeline']+common+['--prefix','/install'],
                    native_passed=True,grouped_passed=True)

    def test_successful_full_root_satisfies_two_obligations_with_no_binary_hash(self):
        record = qualification.full_pipeline_reuse_record(**self.fixture())
        self.assertEqual(record['summary'],[23,0,0,0,0])
        self.assertEqual(record['executions'],1)
        self.assertEqual(record['satisfies'],['full-native-suite','bundle-pipeline-tail'])
        self.assertFalse(record['standalone_command_executed'])
        self.assertIsNone(record['emitted_binary_descriptor'])

    def test_incomplete_failed_and_nonfunctional_full_evidence_refuses(self):
        for defect in ('exit','bool','timeout','native','grouped','missing','duplicate','foreign','failed','skip'):
            args=self.fixture()
            if defect=='exit':args['phase']['command']['returncode']=1
            elif defect=='bool':args['phase']['command']['returncode']=False
            elif defect=='timeout':args['phase']['command']['status']='timeout'
            elif defect=='native':args['native_passed']=False
            elif defect=='grouped':args['grouped_passed']=False
            elif defect=='missing':args['stderr']=args['stderr'].replace('ok bundle_pipeline.test.case0\n','',1)
            elif defect=='duplicate':args['stderr']=args['stderr'].replace('ok bundle_pipeline.test.case0\n','ok bundle_pipeline.test.case1\n',1)
            elif defect=='foreign':args['stderr']=args['stderr'].replace('bundle_pipeline.test.case0','foreign.test.name',1)
            elif defect=='failed':args['stderr']=args['stderr'].replace('ok bundle_pipeline.test.case0','error bundle_pipeline.test.case0 | err: TestUnexpectedResult error return trace unavailable (enable error tracing for this test build)  | exit 1',1)
            else:args['stderr']=args['stderr'].replace('ok bundle_pipeline.test.case0','skip bundle_pipeline.test.case0',1)
            with self.subTest(defect=defect),self.assertRaises(AssertionError):
                qualification.full_pipeline_reuse_record(**args)

    def test_changed_options_source_graph_and_dependencies_refuse(self):
        for defect in ('cpu','cache','captured','unknown','duplicate','cwd','graph','descriptor','root','count'):
            args=self.fixture()
            if defect=='cpu':args['standalone_argv'][args['standalone_argv'].index('-Dcpu=baseline')]='-Dcpu=native'
            elif defect=='cache':args['standalone_argv'][args['standalone_argv'].index('/cache/local')]='/other-cache'
            elif defect=='captured':args['source_manifest']['sha256']='c'*64
            elif defect=='unknown':args['standalone_argv'].append('--unknown-option')
            elif defect=='duplicate':args['standalone_argv'].append('-Dcpu=baseline')
            elif defect=='cwd':args['phase']['command']['cwd']='/other-source'
            elif defect=='graph':
                args['build_source']=args['build_source'].replace('b.addRunArtifact(bundle_pipeline_tests);','b.addRunArtifact(other_tests);',1)
                args['build_graph']['bytes']=len(args['build_source'].encode());args['build_graph']['sha256']=hashlib.sha256(args['build_source'].encode()).hexdigest()
            elif defect=='descriptor':args['build_graph']=dict(args['build_graph'],sha256='d'*64)
            elif defect=='root':args['source_root']=Path('/other-source')
            else:
                g=next(g for g in args['expected']['groups']if g['root']=='bundle_pipeline_tests');g['expected_occurrences'].pop('bundle_pipeline.test.case22');args['expected']['expected_total']-=1
            with self.subTest(defect=defect),self.assertRaises(AssertionError):
                qualification.full_pipeline_reuse_record(**args)

    def test_reuse_record_recomputes_exactly_and_malformed_record_never_skips(self):
        args=self.fixture();record=qualification.full_pipeline_reuse_record(**args)
        self.assertEqual(record,qualification.full_pipeline_reuse_record(**args))
        for field,value in [('authority','diagnostic-only'),('executions',2),('executions',True),('executions',1.0),('standalone_command_executed',True),('summary',[22,0,0,0,0]),('summary',[23,False,0,0,0]),('summary',[23,0.0,0,0,0]),('summary',(23,0,0,0,0))]:
            changed=copy.deepcopy(record);changed[field]=value
            with self.subTest(field=field),self.assertRaises(AssertionError):
                qualification.bundle_pipeline_tail_stages('full',changed)

    def test_alias_and_prefix_dependent_graph_mutations_refuse_even_with_matching_descriptor(self):
        for mutation in (
            'const alias = run_bundle_pipeline_tests_only; alias.addArg("--test-filter=foreign");',
            'const alias = run_bundle_pipeline_tests_only; alias.setEnvironmentVariable("MODE", "changed");',
            'const alias = bundle_pipeline_tests.root_module; alias.addImport("other", another_module);',
            'pipeline_paths.addOption([]const u8, "prefix", b.install_prefix);',
        ):
            args = self.fixture()
            args['build_source'] += '\n' + mutation + '\n'
            args['build_graph']['bytes'] = len(args['build_source'].encode())
            args['build_graph']['sha256'] = hashlib.sha256(args['build_source'].encode()).hexdigest()
            with self.subTest(mutation=mutation), self.assertRaisesRegex(AssertionError, 'Unreviewed pipeline'):
                qualification.full_pipeline_reuse_record(**args)

    def test_actual_worker_tail_stage_selection_preserves_legacy_and_bundle(self):
        import ast, inspect
        # Exercise the real worker assignment, not a mirrored phase-list oracle.
        tree=ast.parse(inspect.getsource(qualification))
        assignments=[node for node in ast.walk(tree)if isinstance(node,ast.Assign)and any(isinstance(t,ast.Name)and t.id=='tail_stages'for t in node.targets)]
        self.assertEqual(len(assignments),1)
        code=compile(ast.fix_missing_locations(ast.Module(body=assignments,type_ignores=[])),'<actual-tail-selection>','exec')
        reuse=qualification.full_pipeline_reuse_record(**self.fixture())
        for stage,record,expected in [('full',None,['bundle-pipeline','bundle']),('full',reuse,['bundle']),('tail',None,['bundle'])]:
            ns=dict(cfg={'execution_stage':stage},result={}if record is None else{'bundle_pipeline_reuse':record},bundle_pipeline_tail_stages=qualification.bundle_pipeline_tail_stages)
            exec(code,ns);self.assertEqual([row[0]for row in ns['tail_stages']],expected)

    def test_actual_worker_reuse_is_after_full_checks_and_tail_recomputes(self):
        import inspect
        source=inspect.getsource(qualification)
        self.assertIn("assert type(cfg.get('reuse_full_bundle_pipeline',False))is bool",source)
        self.assertIn("assert cfg.get('reuse_full_bundle_pipeline',False)==prior_cfg.get('reuse_full_bundle_pipeline',False)",source)
        self.assertIn("assert full_pipeline_reuse_record(",source)
        self.assertIn("native_passed=native['passed'],grouped_passed=result['grouped_inventory']['passed']",source)
        self.assertLess(source.index("result['writer_image_border']=dict"),source.index("if cfg.get('reuse_full_bundle_pipeline',False):"))
        # Reuse is admitted by the full assessor before it publishes full pass;
        # the actual worker consumes that assessor only after the full command.
        assessor = inspect.getsource(qualification.assess_completed_native_full)
        self.assertLess(assessor.index("result['bundle_pipeline_reuse']=full_pipeline_reuse_record("),
                        assessor.index("result['full_native_pass']=True"))
        import ast
        worker = ast.unparse(worker_role_ast())
        self.assertLess(worker.index("execute_outcome('full-native-suite', full_argv)"),
                        worker.index('result.update(assess_completed_native_full('))


class PrivateManifestAuthenticationTests(unittest.TestCase):
    guard_observations = []
    def fixture(self, root):
        import ast
        import os
        import runpy
        import stat
        import time
        tree = ast.parse(Path(qualification.__file__).read_text())
        main = next(n for n in tree.body if isinstance(n, ast.If))
        roles = [n for n in main.body if isinstance(n, ast.If)
                 and ast.unparse(n.test) == "role == 'owner'"]
        self.assertEqual(len(roles), 1)
        body = roles[0].orelse
        names = {'state', 'ref', 'auth', 'final_source_guard'}
        variables = {'_hash_reads', 'source_guard_metrics', '_expected_inputs', '_expected_inputs_pid'}
        selected = [n for n in body if isinstance(n, ast.FunctionDef) and n.name in names or
                    isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id in variables for t in n.targets)]
        self.assertEqual({n.name for n in selected if isinstance(n, ast.FunctionDef)}, names)
        ns = dict(os=os, stat=stat, time=time, Path=Path, hashlib=hashlib,
                  qualification_file_reference=qualification.qualification_file_reference)
        exec(compile(ast.fix_missing_locations(ast.Module(body=selected, type_ignores=[])),
                     '<actual-worker-authentication>', 'exec'), ns)
        helper = runpy.run_path(str(Path(qualification.__file__).with_name('native_qualification_helpers.py')))
        private = root / 'source'; private.mkdir()
        (private / 'first.zig').write_bytes(b'alpha')
        (private / 'second.zig').write_bytes(b'beta')
        model = dict(files={}, modes={})
        for path in private.iterdir():
            model['files'][path.name] = helper['ref'](path)
            model['modes'][path.name] = stat.S_IMODE(path.stat().st_mode)
        expected = helper['private_manifest'](model, private, expected_changes=set())
        ns.update(private_helper=helper, private_model=model, private=private, private_manifest=expected)
        guard = copy.deepcopy(next(n for n in body if isinstance(n, ast.FunctionDef) and n.name == 'source_guard'))
        # Execute the actual manifest/timing portion; unrelated startup pins are
        # separately qualified and are not manufactured by these tiny fixtures.
        start = next(i for i, n in enumerate(guard.body) if isinstance(n, ast.Assign) and
                     any(isinstance(t, ast.Name) and t.id == 'began' for t in n.targets))
        guard.body = guard.body[start:]
        exec(compile(ast.fix_missing_locations(ast.Module(body=[guard], type_ignores=[])),
                     '<actual-source-manifest-guard>', 'exec'), ns)
        type(self).guard_observations.append(dict(case=self.id(), fixture_bytes=9, checks=ns['source_guard_metrics']))
        return ns, helper, model, private

    def test_unchanged_members_reuse_hashes_and_final_guard_forces_every_member(self):
        with tempfile.TemporaryDirectory() as tmp:
            ns, _, model, _ = self.fixture(Path(tmp))
            self.assertTrue(ns['source_guard']())
            self.assertTrue(ns['source_guard']())
            self.assertTrue(ns['final_source_guard']())
            rows = ns['source_guard_metrics']
            self.assertEqual([r['kind'] for r in rows], ['private_manifest', 'private_manifest', 'final_forced_hashes', 'private_manifest'])
            self.assertEqual([r['content_bytes_read'] for r in rows], [9, 0, 9, 0])
            self.assertEqual([r['content_files_read'] for r in rows], [2, 0, 2, 0])
            self.assertTrue(all(r['passed'] and r['elapsed_seconds'] >= 0 for r in rows))
            self.assertEqual(len(ns['_expected_inputs']), len(model['files']))

    def test_default_and_changed_source_callers_keep_full_hashing(self):
        with tempfile.TemporaryDirectory() as tmp:
            ns, helper, model, private = self.fixture(Path(tmp))
            globals_ = helper['private_manifest'].__globals__
            original = globals_['ref']; reads = []
            def counted(path):
                reads.append(path)
                return original(path)
            globals_['ref'] = counted
            for _ in range(2):
                helper['private_manifest'](model, private, expected_changes=set())
            self.assertEqual(len(reads), 4)
            (private / 'first.zig').write_bytes(b'omega')
            changed = helper['private_manifest'](model, private, expected_changes={'first.zig'})
            self.assertEqual(len(reads), 6)
            self.assertNotEqual(changed['first.zig']['sha256'], model['files']['first.zig']['sha256'])
            with self.assertRaisesRegex(AssertionError, 'Cached authentication requires unchanged source'):
                helper['private_manifest'](model, private, expected_changes={'first.zig'}, authenticate_expected=ns['auth'])
            self.assertEqual(ns['_expected_inputs'], {})

    def test_same_size_mutation_and_replacement_rehash_instead_of_reusing_stale_bytes(self):
        import os
        for replacement in (False, True):
            with self.subTest(replacement=replacement), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); ns, _, _, private = self.fixture(root)
                ns['source_guard'](); path = private / 'first.zig'; before = path.stat()
                if replacement:
                    other = root / 'replacement'; other.write_bytes(b'omega'); other.replace(path)
                else:
                    path.write_bytes(b'omega')
                os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
                with self.assertRaises(AssertionError): ns['source_guard']()
                self.assertFalse(ns['source_guard_metrics'][-1]['passed'])
                self.assertGreater(ns['source_guard_metrics'][-1]['content_bytes_read'], 0)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); ns, _, _, private = self.fixture(root); ns['source_guard']()
            replacement = root / 'identical'; replacement.write_bytes(b'alpha')
            replacement.replace(private / 'first.zig')
            ns['source_guard']()
            self.assertEqual(ns['source_guard_metrics'][-1]['content_bytes_read'], 5)

    def test_inventory_mode_hardlink_and_symlink_changes_remain_refused(self):
        import os
        for defect in ('added', 'removed', 'mode', 'hardlink', 'symlink'):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); ns, _, _, private = self.fixture(root); ns['source_guard']()
                path = private / 'first.zig'
                if defect == 'added': (private / 'extra.zig').write_bytes(b'extra')
                elif defect == 'removed': path.unlink()
                elif defect == 'mode': path.chmod((path.stat().st_mode & 0o777) ^ 0o100)
                elif defect == 'hardlink': os.link(path, root / 'alias')
                else:
                    path.rename(root / 'target'); path.symlink_to(root / 'target')
                with self.assertRaises(AssertionError): ns['source_guard']()
                self.assertFalse(ns['source_guard_metrics'][-1]['passed'])

    def test_final_rehash_ignores_a_cached_stat_hint_and_refuses_late_mutation(self):
        with tempfile.TemporaryDirectory() as tmp:
            ns, _, model, private = self.fixture(Path(tmp)); ns['source_guard']()
            path = private / 'first.zig'; path.write_bytes(b'omega')
            expected = model['files'][path.name]
            key = tuple(expected[k] for k in ('path', 'bytes', 'sha256'))
            # Even a misleading cache hint cannot turn the final forced hash
            # into a stat-only check. This is not a production override seam.
            ns['_expected_inputs'][key] = ns['state'](path.stat())
            with self.assertRaises(AssertionError): ns['final_source_guard']()
            row = ns['source_guard_metrics'][-1]
            self.assertEqual(row['kind'], 'final_forced_hashes')
            self.assertFalse(row['passed']); self.assertEqual(row['content_bytes_read'], 5)

    def test_actual_compile_and_test_boundaries_refuse_before_and_during_mutation(self):
        import ast
        tree = ast.parse(Path(qualification.__file__).read_text())
        execute = next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == 'execute_outcome')
        for when in ('before', 'during'):
            for phase in ('compile', 'test'):
                with self.subTest(when=when, phase=phase), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp); ns, _, _, private = self.fixture(root); ns['source_guard']()
                    out = root / 'commands'; out.mkdir(); started = []
                    def mutate(): (private / 'first.zig').write_bytes(b'omega')
                    def fake_execute(directory, label, argv, cwd):
                        started.append(label)
                        (directory / (label + '.stdout')).write_text('')
                        (directory / (label + '.stderr')).write_text('retained command evidence')
                        mutate()
                        return dict(status='exited', returncode=1)
                    ns.update(guard=ns['source_guard'], dynamic={'validate': lambda _: None}, ds={},
                              w={'execute': fake_execute}, out=out, result={'phases': []}, save=lambda: None,
                              execute_with_failure_output=qualification.execute_with_failure_output)
                    exec(compile(ast.fix_missing_locations(ast.Module(body=[execute], type_ignores=[])),
                                 '<actual-guarded-subprocess>', 'exec'), ns)
                    if when == 'before': mutate()
                    with self.assertRaises(AssertionError): ns['execute_outcome'](phase, [])
                    self.assertEqual(started, [] if when == 'before' else [phase])
                    self.assertEqual(len(ns['result']['phases']), 0 if when == 'before' else 1)
                    if when == 'during':
                        self.assertEqual((out / (phase + '.stderr')).read_text(), 'retained command evidence')
                        self.assertEqual(ns['result']['phases'][0]['command']['returncode'], 1)


    def test_added_member_requires_its_own_declared_source_and_mode(self):
        import stat
        with tempfile.TemporaryDirectory() as tmp:
            _, helper, model, private = self.fixture(Path(tmp))
            name = 'tools/source_language_banner.zig'
            added = private / name
            added.parent.mkdir()
            added.write_bytes(b'declared source')
            with self.assertRaisesRegex(AssertionError, 'Private source file inventory differs'):
                helper['private_manifest'](model, private, expected_changes={name})
            model['files'][name] = helper['ref'](added)
            with self.assertRaises(KeyError):
                helper['private_manifest'](model, private, expected_changes=set())
            model['modes'][name] = stat.S_IMODE(added.stat().st_mode)
            result = helper['private_manifest'](model, private, expected_changes=set())
            self.assertEqual(set(result), set(model['files']))
            self.assertEqual(result[name]['sha256'], model['files'][name]['sha256'])
            added.write_bytes(b'altered source!')
            with self.assertRaises(AssertionError):
                helper['private_manifest'](model, private, expected_changes=set())


class TestCacheRetentionTests(unittest.TestCase):
    def setUp(self):
        # These earlier controls isolate selection/closure policy. Actual h
        # invalidation and post-retirement rebuild have separate controls below.
        import contextlib
        from unittest import mock
        patcher=mock.patch.object(qualification,'_retention_manifest_retirement',
            side_effect=lambda *args,**kwargs:contextlib.nullcontext(dict(selection_fixture=True)))
        patcher.start();self.addCleanup(patcher.stop)

    def pair(self, root, key):
        path=root/'o'/key;path.mkdir(parents=True)
        (path/'test').write_bytes(b'test executable fixture')
        (path/'test_zcu.o').write_bytes(b'object fixture')
        return path

    def descriptor(self, path):
        raw=path.read_bytes()
        return dict(path=str(path),bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())

    def document(self, path, value):
        import json
        path.write_text(json.dumps(value,sort_keys=True)+'\n')
        return self.descriptor(path)

    def context(self, local, groups):
        return dict(cache_local=str(local),groups=sorted(groups),family='full',
                    configuration={'path':'/cfg','bytes':1,'sha256':'c'*64},
                    source_manifest={'path':'/source','bytes':1,'sha256':'s'*64})

    def report(self, root, local, context, paths, name='report.json'):
        import json
        token=hashlib.sha256(json.dumps(context,sort_keys=True,separators=(',',':')).encode()).hexdigest()
        qualification.record_test_cache_artifacts(root/name,local,token,[x for group,path in paths for x in (group,str(path/'test'))])
        return dict(context=context,report=self.descriptor(root/name))

    def test_report_preserves_exact_selected_options_and_never_reads_elf_bytes(self):
        from unittest import mock
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);local=root/'local';pair=self.pair(local,'a'*32)
            context=self.context(local,['tools'])
            # A record operation may stat/open its own output, but never read payload.
            with mock.patch.object(Path,'read_bytes',side_effect=AssertionError('payload read')):
                token=hashlib.sha256(__import__('json').dumps(context,sort_keys=True,separators=(',',':')).encode()).hexdigest()
                payload=qualification.record_test_cache_artifacts(root/'report.json',local,token,['tools',str(pair/'test')])
            self.assertEqual(payload['artifacts'][0]['path'],str(pair/'test'))
            argv=['/zig','build','prepare-tests','-Dprepare-test-group=tools','-Dprepare-test-filter=specific','--cache-dir',str(local),'-Doptimize=safe']
            exported=qualification.test_cache_report_command(argv,report=root/'next.json',recorder='/bound/helper.py',context=context)
            self.assertEqual(exported[:len(argv)],[*argv[:2],'qualification-cache-artifacts',*argv[3:]])
            self.assertEqual(argv[2],'prepare-tests')
            self.assertNotIn('-Dprepare-test-group=encoder_compile',exported)

    def test_filtered_cache_report_selects_a_logical_root_before_build(self):
        def command(options):
            return qualification.test_cache_report_command(['zig', 'build', 'prepare-tests', *options],
                                                           report='/out', recorder='/recorder', context={})

        selected = '-Dprepare-test-filter=ordinary Writer retained EN imagemap error'
        for group in ('tools_partitioned', 'tools_normal', 'tools_core', 'tools_observations', 'tools_support',
                      'encoder_compile', 'encoder_document', 'encoder_writer', 'encoder_support'):
            with self.subTest(group=group):
                flag = '-Dprepare-test-group=' + group
                with self.assertRaisesRegex(ValueError, '-Dprepare-test-group=' + group.partition('_')[0] + '$'):
                    command([flag, selected])
                self.assertIn(flag, command([flag]))
        for root in ('tools', 'encoder', 'lua', 'provider'):
            flags = ['-Dprepare-test-group=' + root, selected]
            self.assertEqual(command(flags)[3:5], flags)
        with self.assertRaisesRegex(ValueError, 'one prepare-test group'):
            command([selected])

    def test_cache_report_flags_use_the_build_environment_for_global_cache(self):
        for flags in (['--global-cache-dir', '/cache/global'], ['--global-cache-dir=/cache/global']):
            with self.subTest(flags=flags), self.assertRaisesRegex(ValueError, 'ZIG_GLOBAL_CACHE_DIR'):
                qualification.test_cache_report_command(['zig', 'build', 'prepare-tests', *flags],
                                                        report='/out', recorder='/recorder', context={})

    def test_interrupted_report_leaves_no_final_file_and_retry_preserves_the_first_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / 'local'
            pair = self.pair(cache, 'a' * 32)
            final = root / 'result.json'
            args = (final, cache, 'c' * 64, ['tools', str(pair / 'test')])

            def interrupted(payload, stream, **kwargs):
                stream.write('{')
                stream.flush()
                self.assertFalse(final.exists())
                raise OSError('interrupted write')

            with patch('json.dump', side_effect=interrupted), self.assertRaisesRegex(OSError, 'interrupted'):
                qualification.record_test_cache_artifacts(*args)
            self.assertEqual(set(root.iterdir()), {cache})
            qualification.record_test_cache_artifacts(*args)
            original = self.descriptor(final)
            with self.assertRaises(FileExistsError):
                qualification.record_test_cache_artifacts(final, cache, 'd' * 64, args[3])
            self.assertEqual(self.descriptor(final), original)
            self.assertEqual(set(root.iterdir()), {cache, final})

    def test_report_refuses_wrong_root_duplicate_group_symlink_and_drift(self):
        import os
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);local=root/'local';pair=self.pair(local,'a'*32);context=self.context(local,['tools'])
            token='a'*64
            for arguments in [['tools',str(root/'elsewhere/test')],['tools',str(pair/'test'),'tools',str(pair/'test')]]:
                with self.assertRaises((AssertionError,ValueError,FileNotFoundError)):
                    qualification.record_test_cache_artifacts(root/'bad.json',local,token,arguments)
                self.assertFalse((root/'bad.json').exists())
            report=self.report(root,local,context,[('tools',pair)])
            report['context']['groups']=['other']
            with self.assertRaises(AssertionError):qualification.validated_test_cache_keys(local,[report])
            report['context']=context=self.context(local,['tools'])
            old=(pair/'test').stat();os.utime(pair/'test',ns=(old.st_atime_ns,old.st_mtime_ns+1_000_000))
            with self.assertRaises(AssertionError):qualification.validated_test_cache_keys(local,[report])
            (pair/'test').unlink();(pair/'test').symlink_to(pair/'test_zcu.o')
            with self.assertRaises(AssertionError):qualification.record_test_cache_artifacts(root/'linked.json',local,token,['tools',str(pair/'test')])

    def test_retirement_only_obsolete_pure_pairs_current_production_and_links_survive(self):
        import os,time
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);local=root/'local'
            current=self.pair(local,'a'*32);old=self.pair(local,'b'*32)
            production=self.pair(local,'c'*32);(production/'dict-llvm-build').write_bytes(b'production')
            linked=self.pair(local,'d'*32);os.link(linked/'test',root/'held-test')
            result=qualification.retire_obsolete_test_pairs(local,{current},journal=root/'journal',deadline_monotonic=time.monotonic()+30,open_probe=lambda paths:(1,'',''),lock_probe=lambda nodes:True)
            self.assertEqual(result['removed_files'],2);self.assertFalse(old.exists())
            for path in [current,production,linked]:self.assertTrue(path.exists())
            self.assertIsNone(result['exclusive_gain_bytes'])

    def test_retirement_refuses_open_lock_and_post_probe_identity_drift(self):
        import time
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);local=root/'local';old=self.pair(local,'b'*32)
            for code,stdout,stderr in [(0,'123',''),(1,'','warning'),(2,'','')]:
                with self.assertRaises(AssertionError):qualification.retire_obsolete_test_pairs(local,set(),journal=root/'journal',deadline_monotonic=time.monotonic()+30,open_probe=lambda paths:(code,stdout,stderr),lock_probe=lambda nodes:True)
                self.assertTrue((old/'test').exists())
            with self.assertRaises(AssertionError):qualification.retire_obsolete_test_pairs(local,set(),journal=root/'journal',deadline_monotonic=time.monotonic()+30,open_probe=lambda paths:(1,'',''),lock_probe=lambda nodes:False)
            def drift(paths):
                (old/'test').write_bytes(b'changed')
                return 1,'',''
            with self.assertRaises(AssertionError):qualification.retire_obsolete_test_pairs(local,set(),journal=root/'journal',deadline_monotonic=time.monotonic()+30,open_probe=drift,lock_probe=lambda nodes:True)
            self.assertTrue((old/'test_zcu.o').exists())

    def test_generated_pair_families_retire_only_exact_obsolete_entries(self):
        import time
        families = ('test', 'dict-reader-integration-test', 'dict-bundle-integration-test',
                    'dict-storage-integration-test', 'dict-blob-build', 'dict-bundle-runtime.o')
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);local=root/'local';keep=set()
            for index,name in enumerate(families):
                for offset in (0,16):
                    entry=local/'o'/format(index+offset,'032x');entry.mkdir(parents=True)
                    (entry/name).write_bytes(b'executable or runtime object')
                    object_name = 'dict-bundle-runtime_zcu.o' if name == 'dict-bundle-runtime.o' else name+'_zcu.o'
                    (entry/object_name).write_bytes(b'generated object')
                    if offset:keep.add(entry)
            result=qualification.retire_obsolete_test_pairs(local,keep,journal=root/'journal',
                deadline_monotonic=time.monotonic()+30,open_probe=lambda paths:(1,'',''),lock_probe=lambda nodes:True)
            self.assertEqual(result['removed_files'],12)
            self.assertEqual(set((local/'o').iterdir()),keep)

    def test_generated_pairs_preserve_mixed_shared_linked_and_unknown_entries(self):
        import os,time
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);local=root/'local'
            specs = [ ('dict-blob-build','dict-bundle-runtime.o_zcu.o'),
                      ('dict-bundle-runtime.o','worker_object.o'),
                      ('module.o','module_zcu.o'), ('value_leaf.o','value_leaf_zcu.o'),
                      ('dict-llvm-build','dict-llvm-build_zcu.o'),
                      ('dict-blob-build','dict-blob-build_zcu.o'),
                      ('dict-storage-integration-test','dict-storage-integration-test_zcu.o') ]
            for index,names in enumerate(specs):
                entry=local/'o'/format(index,'032x');entry.mkdir(parents=True)
                for name in names:(entry/name).write_bytes(b'preserved')
                if index==5:os.link(entry/names[0],root/'external-hardlink')
                if index==6:(entry/'source-proof.json').write_bytes(b'unique evidence')
            result=qualification.retire_obsolete_test_pairs(local,set(),journal=root/'journal',
                deadline_monotonic=time.monotonic()+30,open_probe=lambda paths:(1,'',''),lock_probe=lambda nodes:True)
            self.assertEqual(result['removed_files'],0)
            self.assertEqual(len(list((local/'o').iterdir())),len(specs))

    def test_generated_pair_probe_replacement_refuses_all_unlinks(self):
        import time
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);local=root/'local';entry=local/'o'/('a'*32);entry.mkdir(parents=True)
            executable=entry/'dict-blob-build';executable.write_bytes(b'writer')
            obj=entry/'dict-blob-build_zcu.o';obj.write_bytes(b'object')
            def replace(paths):
                obj.rename(root/'retained-object');obj.write_bytes(b'replacement')
                return 1,'',''
            with self.assertRaises(AssertionError):
                qualification.retire_obsolete_test_pairs(local,set(),journal=root/'journal',
                    deadline_monotonic=time.monotonic()+30,open_probe=replace,lock_probe=lambda nodes:True)
            self.assertTrue(executable.exists());self.assertTrue(obj.exists())

    def test_dependency_report_records_requested_outputs_without_payload_reads(self):
        from unittest import mock
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);local=root/'local';pair=self.pair(local,'a'*32)
            dep=local/'o'/('b'*32);dep.mkdir();(dep/'dict-blob-build').write_bytes(b'writer')
            with mock.patch.object(Path,'read_bytes',side_effect=AssertionError('payload read')):
                record=qualification.record_test_cache_artifacts(root/'report',local,'a'*64,
                    ['dependency_report_v2','selected','tools',str(pair/'test'),
                     'dependency',str(dep/'dict-blob-build'),'dependency',str(dep/'dict-blob-build')])
            self.assertEqual(len(record['dependencies']),1)
            self.assertEqual(record['dependencies'][0]['path'],str(dep/'dict-blob-build'))
            self.assertTrue(record['coverage']['selected_graph_complete'])
            self.assertEqual(record['coverage']['runtime_spawned_artifacts'],'unknown')
            legacy=qualification.record_test_cache_artifacts(root/'legacy',local,'a'*64,['tools',str(pair/'test')])
            self.assertEqual(legacy['schema'],'wikidict.qualification-test-cache-paths.v1')
            self.assertNotIn('coverage',legacy)
            context=self.context(local,['tools']);argv=['/zig','build','prepare-tests','-Dprepare-test-group=tools']
            before=qualification.test_cache_report_command(argv,report=root/'old',recorder='/helper',context=context)
            self.assertNotIn('-Dqualification-cache-dependencies=true',before)
            context['report_dependencies']=True
            after=qualification.test_cache_report_command(argv,report=root/'new',recorder='/helper',context=context)
            self.assertIn('-Dqualification-cache-dependencies=true',after)
            # Default v1 still authorizes the unchanged closed-pass path.
            closed_root=root/'closed';closed_root.mkdir()
            request,cfg,_=self.closed_fixture(closed_root)
            obsolete=self.pair(closed_root/'cache/local','f'*32)
            backend=qualification.retire_obsolete_test_pairs
            def fixture_backend(*args,**kwargs):
                return backend(*args,**kwargs,open_probe=lambda paths:(1,'',''),lock_probe=lambda nodes:True)
            with mock.patch.object(qualification,'retire_obsolete_test_pairs',side_effect=fixture_backend):
                result=qualification.cleanup_closed_test_cache(request,reconcile_protected=lambda cfg:
                    dict(cache_root=cfg['retained_cache'],entry_paths=[]))
            self.assertEqual(result['status'],'retired');self.assertEqual(result['removed_files'],2)
            self.assertFalse(obsolete.exists())


    def test_dependency_report_unknown_runtime_or_graph_never_authorizes_cleanup(self):
        import json
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);local=root/'local';pair=self.pair(local,'a'*32)
            context=self.context(local,['tools'])
            token=hashlib.sha256(json.dumps(context,sort_keys=True,separators=(',',':')).encode()).hexdigest()
            record=qualification.record_test_cache_artifacts(root/'report',local,token,
                ['dependency_report_v2','selected','tools',str(pair/'test')])
            with self.assertRaisesRegex(AssertionError,'nested artifact coverage unknown'):
                qualification.validated_test_cache_keys(local,[dict(context=context,report=self.descriptor(root/'report'))])
            record=qualification.record_test_cache_artifacts(root/'partial',local,token,
                ['dependency_report_v2','selected','tools',str(pair/'test'),
                 'dependency_graph_unknown','run-step','dependency_graph_unknown','unrequested-output'])
            self.assertFalse(record['coverage']['selected_graph_complete'])
            self.assertEqual(record['coverage']['unknown_graph_steps'],['run-step','unrequested-output'])
            with self.assertRaises(AssertionError):
                qualification.validated_test_cache_keys(local,[dict(context=context,report=self.descriptor(root/'partial'))])
            self.assertTrue((pair/'test').exists())

    def test_dependency_report_refuses_outside_cache_and_symlink_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);local=root/'local';pair=self.pair(local,'a'*32)
            outside=root/'dict-blob-build';outside.write_bytes(b'outside')
            for path in [outside,pair/'linked']:
                if path.name=='linked':path.symlink_to(outside)
                with self.assertRaises((AssertionError,ValueError)):
                    qualification.record_test_cache_artifacts(root/'bad',local,'a'*64,
                        ['dependency_report_v2','selected','tools',str(pair/'test'),'dependency',str(path)])
                self.assertFalse((root/'bad').exists())

    def closed_fixture(self, root):
        import os,stat,time
        cache=root/'cache';local=cache/'local';q=root/'qualification';q.mkdir()
        lock=q/'ownership.lock';lock.write_bytes(b'');s=lock.stat()
        manifest=self.document(root/'source.json',{})
        cfg=dict(qualification_root=str(q),ownership_locks=[dict(path=str(lock),dev=s.st_dev,ino=s.st_ino)],private_manifest=manifest)
        groups=sorted(row[1] for row in qualification.FULL_DIAGNOSTIC_ROOTS)
        pairs=[(group,self.pair(local,hashlib.md5(group.encode()).hexdigest())) for group in groups]
        z=cache.stat();cfg['retained_cache']=dict(path=str(cache),device=z.st_dev,inode=z.st_ino,uid=z.st_uid,mode=stat.S_IMODE(z.st_mode))
        cfgref=self.document(root/'cfg.json',cfg);context=self.context(local,groups);context.update(configuration=cfgref,source_manifest=manifest)
        report=self.report(root,local,context,pairs)
        result=self.document(root/'result.json',dict(passed=True,full_native_pass=True,source_guard_after=True,test_cache_retention=dict(reports=[report],deferred=[])))
        closure=dict(schema='existing-private-native-independent-closure.v1',status='PASSED-CLOSED',result=result,configuration=cfgref)
        closure.update({k:True for k in ['passed','physical_closure','source_guard_after','source_custody_released','ps_absence','locks_free','cleanup_complete','full_current_executed','full_current_passed']})
        closed=self.document(root/'closed.json',closure)
        release=self.document(root/'release.json',dict(schema='native-resource-release.v1',released=True,physical_closure=closed,cache_custody_released=True))
        request=dict(result=result,closure=closed,release=release,configuration=cfgref,journal=str(root/'retirement.jsonl'),deadline_monotonic=time.monotonic()+30)
        return request,cfg,report

    def failed_cleanup_fixture(self, root):
        import json
        request,cfg,report=self.closed_fixture(root)
        result=json.loads(Path(request['result']['path']).read_text())
        argv=['/zig','build','prepare-tests','-Doptimize=safe']
        context=report['context'];context.update(family='prepare',argv=argv)
        local=root/'cache/local'
        groups=context['groups']
        pairs=[(group,local/'o'/hashlib.md5(group.encode()).hexdigest()) for group in groups]
        fresh=self.report(root,local,context,pairs,name='failed-report.json')
        fresh['command']=dict(status='exited',returncode=0)
        result.update(passed=False,status='failed',all_selected_executed=True,all_selected_accounted=True,
            phases=[dict(name='prepare',command=dict(argv=argv,status='exited',returncode=0))],
            test_cache_retention=dict(reports=[fresh],deferred=[]))
        request['result']=self.document(root/'result.json',result)
        closure=json.loads(Path(request['closure']['path']).read_text())
        closure.update(status='FOCUSED-FAILED-CLOSED',passed=False,result=request['result'])
        request['closure']=self.document(root/'closed.json',closure)
        request['release']=self.document(root/'release.json',dict(schema='native-resource-release.v1',
            released=True,physical_closure=request['closure'],cache_custody_released=True))
        request['allow_reconciled_failure']=True
        return request,cfg

    def test_failed_closed_cleanup_retires_only_old_generic_and_keeps_all_non_test_families(self):
        import json
        from unittest import mock
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);request,cfg=self.failed_cleanup_fixture(root);local=root/'cache/local'
            old=self.pair(local,'f'*32);queued=self.pair(local,'e'*32)
            held=[]
            for index,pair in enumerate(qualification._RETENTION_GENERATED_PAIRS):
                if pair==frozenset(('test','test_zcu.o')):continue
                entry=local/'o'/format(index,'032x');entry.mkdir()
                for name in pair:(entry/name).write_bytes(b'held nested product')
                held.append(entry)
            originals={k:Path(request[k]['path']).read_bytes() for k in ('configuration','result','closure','release')}
            backend=qualification.retire_obsolete_test_pairs
            def guarded(*args,**kwargs):return backend(*args,**kwargs,open_probe=lambda paths:(1,'',''),lock_probe=lambda nodes:True)
            with mock.patch.object(qualification,'retire_obsolete_test_pairs',side_effect=guarded):
                outcome=qualification.cleanup_closed_test_cache(request,reconcile_protected=lambda cfg:
                    dict(cache_root=cfg['retained_cache'],entry_paths=[str(queued)]))
            self.assertEqual(outcome['status'],'retired');self.assertEqual(outcome['removed_files'],2)
            self.assertFalse(old.exists());self.assertTrue(queued.exists())
            self.assertTrue(all(entry.exists() for entry in held))
            for key,value in originals.items():self.assertEqual(Path(request[key]['path']).read_bytes(),value)
            self.assertFalse(json.loads(originals['result'])['passed'])

    def test_failed_cleanup_refuses_unknown_preparation_or_incomplete_report_coverage(self):
        import json
        for mode in ('missing-report','failed-build','unknown-build','duplicate-build','unaccounted'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);request,cfg=self.failed_cleanup_fixture(root)
                result=json.loads(Path(request['result']['path']).read_text())
                if mode=='missing-report':result['test_cache_retention']['reports']=[]
                elif mode=='failed-build':result['phases'][0]['command']['returncode']=1
                elif mode=='unknown-build':result['phases'][0]['command']['argv'][2]='test-bundle'
                elif mode=='duplicate-build':result['phases']*=2
                else:result['all_selected_accounted']=False
                request['result']=self.document(root/'result.json',result)
                closure=json.loads(Path(request['closure']['path']).read_text());closure['result']=request['result']
                request['closure']=self.document(root/'closed.json',closure)
                request['release']=self.document(root/'release.json',dict(schema='native-resource-release.v1',released=True,
                    physical_closure=request['closure'],cache_custody_released=True))
                outcome=qualification.cleanup_closed_test_cache(request,reconcile_protected=lambda cfg:self.fail('incomplete proof must defer'))
                self.assertEqual(outcome['status'],'cleanup-deferred');self.assertFalse((root/'retirement.jsonl').exists())

    def test_failed_cleanup_refuses_source_uncertainty_and_requires_explicit_opt_in(self):
        import json
        for mode in ('source','raw-unknown','not-opted-in','report-source'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);request,cfg=self.failed_cleanup_fixture(root)
                closure=json.loads(Path(request['closure']['path']).read_text())
                if mode=='source':closure['source_guard_after']=False
                elif mode=='raw-unknown':closure['cleanup_complete']=False
                elif mode=='not-opted-in':request.pop('allow_reconciled_failure')
                else:
                    result=json.loads(Path(request['result']['path']).read_text())
                    result['test_cache_retention']['reports'][0]['context']['source_manifest']={'path':'/wrong','bytes':0,'sha256':'0'*64}
                    request['result']=self.document(root/'result.json',result);closure['result']=request['result']
                request['closure']=self.document(root/'closed.json',closure)
                request['release']=self.document(root/'release.json',dict(schema='native-resource-release.v1',released=True,
                    physical_closure=request['closure'],cache_custody_released=True))
                outcome=qualification.cleanup_closed_test_cache(request,reconcile_protected=lambda cfg:self.fail('uncertain proof must defer'))
                self.assertEqual(outcome['status'],'cleanup-deferred');self.assertFalse((root/'retirement.jsonl').exists())

    def test_closed_cleanup_busy_shared_interlock_defers_without_reconciliation(self):
        import os,fcntl
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);request,cfg,_=self.closed_fixture(root)
            fd=os.open(cfg['ownership_locks'][0]['path'],os.O_RDWR)
            try:
                fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
                result=qualification.cleanup_closed_test_cache(request,reconcile_protected=lambda cfg:self.fail('busy interlock must not reconcile'))
                self.assertEqual(result['status'],'cleanup-deferred')
                self.assertFalse((root/'retirement.jsonl').exists())
            finally:os.close(fd)

    def test_closed_cleanup_requires_fresh_pins_under_shared_interlock(self):
        import os,fcntl
        from unittest import mock
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);request,cfg,_=self.closed_fixture(root)
            old=self.pair(root/'cache/local','f'*32)
            self.assertEqual(qualification.cleanup_closed_test_cache(request)['status'],'cleanup-deferred')
            def fresh(actual):
                self.assertEqual(actual,cfg)
                fd=os.open(cfg['ownership_locks'][0]['path'],os.O_RDWR)
                try:
                    with self.assertRaises(BlockingIOError):fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
                finally:os.close(fd)
                return dict(cache_root=cfg['retained_cache'],entry_paths=[str(old)])
            backend=qualification.retire_obsolete_test_pairs
            def guarded(*args,**kwargs):return backend(*args,**kwargs,open_probe=lambda paths:(1,'',''),lock_probe=lambda nodes:True)
            with mock.patch.object(qualification,'retire_obsolete_test_pairs',side_effect=guarded):
                result=qualification.cleanup_closed_test_cache(request,reconcile_protected=fresh)
            self.assertEqual(result['status'],'retired');self.assertEqual(result['removed_files'],0);self.assertTrue(old.exists())

    def test_closed_cleanup_wrong_source_incomplete_report_or_failed_run_never_retires(self):
        import json
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);request,cfg,report=self.closed_fixture(root)
            # Authenticated fixture mutation: update downstream refs deliberately,
            # so refusal is semantic rather than a stale-descriptor shortcut.
            closure=json.loads(Path(request['closure']['path']).read_text())
            for mode in ['source','incomplete','failed']:
                original=json.loads(Path(request['result']['path']).read_text())
                value=json.loads(json.dumps(original))
                if mode=='source':value['test_cache_retention']['reports'][0]['context']['source_manifest']={'path':'/wrong','bytes':0,'sha256':'0'*64}
                elif mode=='incomplete':value['test_cache_retention']['deferred']=[dict(reason='report unavailable')]
                else:value['passed']=False
                request['result']=self.document(root/'result.json',value);closure['result']=request['result'];request['closure']=self.document(root/'closed.json',closure)
                request['release']=self.document(root/'release.json',dict(schema='native-resource-release.v1',released=True,physical_closure=request['closure'],cache_custody_released=True))
                self.assertEqual(qualification.cleanup_closed_test_cache(request,reconcile_protected=lambda cfg:self.fail('invalid proof cannot reconcile'))['status'],'cleanup-deferred')
                self.assertFalse((root/'retirement.jsonl').exists())
                self.document(root/'result.json',original)

    def test_actual_worker_optional_wrapper_default_and_export_failure_preserve_outcome(self):
        import ast,json
        source=Path(qualification.__file__).read_text()
        optional=[n for n in ast.walk(ast.parse(source)) if isinstance(n,ast.If) and ast.unparse(n.test)=="cfg.get('retain_test_cache', False) is True"]
        self.assertEqual(len(optional),1)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);original=(dict(status='exited',returncode=0),'original stdout','original stderr');calls=[]
            def guarded(label,argv):calls.append(('original',label,argv));return original
            ns=dict(cfg={},result={},execute_outcome=guarded)
            exec(compile(ast.Module(body=optional,type_ignores=[]),'<actual-optional-worker>', 'exec'),ns)
            self.assertIs(ns['execute_outcome'],guarded);self.assertEqual(ns['result'],{})
            ns.update(cfg=dict(retain_test_cache=True,private_manifest={'sha256':'source'}),start=dict(configuration={'sha256':'cfg'}),out=root,cache=root/'cache',__file__='/bound/helper.py',FULL_DIAGNOSTIC_ROOTS=qualification.FULL_DIAGNOSTIC_ROOTS,guard=lambda:calls.append(('guard',)),save=lambda:None,Path=Path,json=json,hashlib=hashlib,test_cache_report_command=qualification.test_cache_report_command,w={'execute':lambda *args:dict(status='exited',returncode=2)})
            exec(compile(ast.Module(body=optional,type_ignores=[]),'<actual-optional-worker>', 'exec'),ns)
            argv=['/zig','build','prepare-tests','-Dprepare-test-group=tools']
            outcome=ns['execute_outcome']('focus',argv)
            self.assertEqual(outcome,original);self.assertIs(outcome[0],original[0])
            self.assertEqual(len(ns['result']['test_cache_retention']['deferred']),1)
            self.assertEqual(ns['result']['test_cache_retention']['reports'],[])
            self.assertEqual(sum(row[0]=='original' for row in calls),1)
            self.assertEqual(sum(row[0]=='guard' for row in calls),2)


    def test_closed_cleanup_rejects_empty_or_wrong_shared_interlock_after_valid_rebinding(self):
        import json,os
        from unittest import mock
        for mode in ['empty','wrong']:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root=Path(directory);request,cfg,report=self.closed_fixture(root);calls=[]
                def pins(value):
                    calls.append('pins');return dict(cache_root=value['retained_cache'],entry_paths=[])
                with mock.patch.object(qualification,'retire_obsolete_test_pairs',side_effect=lambda *args,**kwargs:(calls.append('retire') or dict(status='retired'))):
                    self.assertEqual(qualification.cleanup_closed_test_cache(request,reconcile_protected=pins)['status'],'retired')
                    self.assertEqual(calls,['pins','retire']);calls.clear()
                    if mode=='empty':cfg['ownership_locks']=[]
                    else:
                        wrong=root/'other.lock';wrong.write_bytes(b'');s=wrong.stat()
                        cfg['ownership_locks']=[dict(path=str(wrong),dev=s.st_dev,ino=s.st_ino)]
                    request['configuration']=self.document(root/'cfg.json',cfg)
                    result=json.loads(Path(request['result']['path']).read_text())
                    for item in result['test_cache_retention']['reports']:
                        item['context']['configuration']=request['configuration']
                        payload=json.loads(Path(item['report']['path']).read_text())
                        payload['context']=hashlib.sha256(json.dumps(item['context'],sort_keys=True,separators=(',',':')).encode()).hexdigest()
                        item['report']=self.document(Path(item['report']['path']),payload)
                    request['result']=self.document(root/'result.json',result)
                    closed=json.loads(Path(request['closure']['path']).read_text());closed.update(result=request['result'],configuration=request['configuration'])
                    request['closure']=self.document(root/'closed.json',closed)
                    request['release']=self.document(root/'release.json',dict(schema='native-resource-release.v1',released=True,physical_closure=request['closure'],cache_custody_released=True))
                    self.assertEqual(qualification.cleanup_closed_test_cache(request,reconcile_protected=pins)['status'],'cleanup-deferred')
                    self.assertEqual(calls,[])


class QualificationFileReferenceTests(unittest.TestCase):
    def test_descriptor_and_accounting_use_bounded_reads(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'artifact'
            payload = b'0123456789abcdef' * 100_003
            path.write_bytes(payload)
            counters = {'files': 0, 'bytes': 0}
            with path.open('rb') as stream:
                readinto = stream.readinto

                def bounded(buffer):
                    self.assertGreater(len(buffer), 0)
                    self.assertLessEqual(len(buffer), 1024 * 1024)
                    return readinto(buffer)

                with patch.object(stream, 'readinto', bounded), patch.object(Path, 'open', return_value=stream):
                    result = qualification.qualification_file_reference(path, counters=counters)
            self.assertEqual(result, {'path': str(path), 'bytes': len(payload),
                                      'sha256': hashlib.sha256(payload).hexdigest()})
            self.assertEqual(counters, {'files': 1, 'bytes': len(payload)})


class PassedClosureRetentionTests(unittest.TestCase):
    def fixture(self, root, *, retain=False, collect=None):
        import os
        import runpy
        import stat
        import json
        q = root / 'qualification'; q.mkdir()
        run = q / 'run1'; run.mkdir()
        (run / 'dispatch').mkdir(); (run / 'commands').mkdir()
        source = root / 'source'; (source / 'src/ffi').mkdir(parents=True)
        (source / 'src/ffi/dict.h').write_text('#define DICT_ABI_VERSION 10u\n')
        (source / 'build.zig').write_text('// source-bound fixture graph\n')
        install = run / 'install'
        (install / 'bin').mkdir(parents=True)
        (install / 'lib').mkdir()
        (install / 'include/dict').mkdir(parents=True)
        (install / 'bin/wikidict').write_bytes(b'fixture CLI descriptor only')
        (install / 'lib/libdictffi.so').write_bytes(b'fixture FFI descriptor only')
        (install / 'include/dict/dict.h').write_bytes((source / 'src/ffi/dict.h').read_bytes())
        compiler = q / 'zig'; compiler.write_bytes(b'fixture compiler descriptor only')
        helper_path = Path(qualification.__file__).with_name('native_qualification_helpers.py')
        helper = runpy.run_path(str(helper_path))
        def ref(path):
            raw = path.read_bytes()
            return dict(path=str(path), bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())
        def document(path, value):
            path.write_text(json.dumps(value, sort_keys=True) + '\n')
            return ref(path)
        inventory = {str(path.relative_to(source)): dict(bytes=path.stat().st_size,
            sha256=ref(path)['sha256'], mode=stat.S_IMODE(path.stat().st_mode))
            for path in source.rglob('*') if path.is_file()}
        manifest = document(q / 'source.json', inventory)
        names = ['fixture.test.' + name for name in helper['REQUIRED_SUFFIXES']]
        inventory_helper = q / 'inventory.py'
        inventory_helper.write_text('def validate_grouped(helper, expected, stdout, stderr):\n'
            '    names = [name for status, name in helper["STATUS"].findall(stdout + "\\n" + stderr) if status == "ok"]\n'
            '    return dict(passed=names == expected["names"], exact_grouped_names_and_multiplicity=names == expected["names"])\n')
        expectation = document(q / 'expectation.json', dict(inventory_source=ref(inventory_helper),
            expected=dict(names=names, build_graph=ref(source / 'build.zig')),
            required_test_counts={name: 1 for name in helper['REQUIRED_SUFFIXES']}))
        lock = q / 'ownership.lock'; lock.touch(); lock_stat = lock.stat(); source_stat = source.stat()
        cache = q / 'cache'; (cache / 'local/o').mkdir(parents=True)
        cache_stat = cache.stat()
        cfg = dict(qualification_root=str(q), execution_stage='full', retain_test_cache=retain,
            retained_cache=dict(path=str(cache), device=cache_stat.st_dev, inode=cache_stat.st_ino,
                uid=cache_stat.st_uid, mode=stat.S_IMODE(cache_stat.st_mode)),
            retained_source=dict(path=str(source), device=source_stat.st_dev, inode=source_stat.st_ino,
                uid=source_stat.st_uid, mode=stat.S_IMODE(source_stat.st_mode)),
            private_manifest=manifest, ownership_locks=[dict(path=str(lock), dev=lock_stat.st_dev, ino=lock_stat.st_ino)],
            canonical_runtime_inputs={}, helper=ref(helper_path), expectation=expectation,
            compiler=ref(compiler), install_root=str(install),
            focused_expected=1, full_native_expected=len(names), groups_expected=1,
            reader_expected_checks=50, bundle_expected_checks=3, reuse_full_bundle_pipeline=True,
            admission_derivation=dict(own_bytes=536870912), profile=dict(memory_limit_bytes=536870912))
        if collect is not None: cfg['collect_unrun_full_roots'] = collect
        cfg_path = q / 'configuration.json'; cfg_ref = document(cfg_path, cfg)
        direct = dict(configuration=cfg_ref, runtime_inputs=dict(helper=ref(helper_path), qualification_tool=ref(Path(qualification.__file__))),
            maintained_qualification_execution=dict(qualification_tool=ref(Path(qualification.__file__))))
        document(run / 'dispatch/start.json', direct)
        document(run / 'dispatch/outer-start.json', dict(owner=dict(pid=2147483001, starttime=1, process_group=2147483001, session=2147483001),
            outer=dict(pid=2147483002, starttime=2, process_group=2147483002, session=2147483002)))
        document(run / 'dispatch/outer-result.json', dict(reaped=True, exit_code=0))
        document(run / 'dispatch/owner-result.json', dict(returncode=0, error=None))
        document(run / 'watchdog.json', dict(runtime_started=True, admission_refused=False,
            cleanup_complete=True, child_exit_status=0, guardian_exit_status=0,
            child_pid=2147483003, child_start_time_ticks=3, guardian_pid=2147483004,
            guardian_start_time_ticks=4, elapsed_seconds=1.0, peak_pss_bytes=1234))
        output = ''.join('ok ' + name + '\n' for name in names)
        output += 'pass: %d  fail: 0  skip: 0  leak: 0  crash: 0\n' % len(names)
        output += 'CLI_SWATCH_PTY_PASS\nCLI_ANCHORED_PARENT_PTY_PASS\nSTORAGE_INTEGRATION_PASS\nREADER_INTEGRATION_PASS checks=50:\n'
        stdout = run / 'commands/full.stdout'; stdout.write_text(output)
        stderr = run / 'commands/full.stderr'; stderr.write_text('')
        full = dict(name='full-native-suite', command=dict(status='exited', returncode=0,
            argv=['zig', 'build', 'test', '-Dcaptured-source-fingerprint=' + manifest['sha256']], cwd=str(source)),
            stdout=ref(stdout), stderr=ref(stderr))
        bundle_output = run / 'commands/bundle.stdout'; bundle_output.write_text('BUNDLE_INTEGRATION_PASS checks=3:\n')
        bundle = dict(name='bundle', command=dict(status='exited', returncode=0,
            argv=['zig', 'build', 'test-bundle', '-Dcaptured-source-fingerprint=' + manifest['sha256']], cwd=str(source)),
            stdout=ref(bundle_output), stderr=ref(stderr))
        install_phase = dict(name='cli-ffi-install', command=dict(status='exited', returncode=0,
            argv=[str(compiler), 'build', 'cli', 'ffi', '--prefix', str(install),
                '-Dcaptured-source-fingerprint=' + manifest['sha256']], cwd=str(source)),
            stdout=ref(stderr), stderr=ref(stderr))
        smoke = dict(name='cli-smoke', command=dict(status='exited', returncode=0,
            argv=[str(install / 'bin/wikidict'), '--help'], cwd=str(source)),
            stdout=ref(stderr), stderr=ref(stderr))
        reader = document(q / 'reader.json', dict(passed=True))
        result = dict(passed=True, status='passed', source_guard_after=True, focused_qualified=True,
            cli_ffi_install_pass=True, full_native_pass=True, bundle_pipeline_pass=True,
            bundle_pass=True, cli_smoke_pass=True,
            focused_tests=[dict(passed=True, command=dict(status='exited', returncode=0),
                stdout=ref(stdout), stderr=ref(stderr), binary=ref(source / 'src/ffi/dict.h'))],
            phases=[install_phase, full, bundle, smoke], reader_markers=dict(reader_checks=50, child_report=reader,
                marker_lines=[dict(line=len(output.splitlines()), text='READER_INTEGRATION_PASS checks=50:')],
                child_summary=dict(passed=True), standalone_pty_counts=dict(passed=True)),
            installed={name: ref(install / name) for name in ('bin/wikidict', 'lib/libdictffi.so', 'include/dict/dict.h')},
            bundle_pipeline_reuse=dict(authority='successful-normal-full-root', executions=1,
                summary=[23, 0, 0, 0, 0], standalone_command_executed=False, emitted_binary_descriptor=None,
                source_manifest=manifest, full_phase=full, full_configuration=cfg_ref,
                build_graph=ref(source / 'build.zig'), satisfies=['full-native-suite', 'bundle-pipeline-tail']),
            metadata_python=dict(passed=True, executed=1))
        document(run / 'commands/result.json', result)
        request = dict(configuration=cfg_ref, run_directory=str(run), closure_path=str(q / 'closed.json'),
            release_path=str(q / 'release.json'), expected_abi_version=10, cleanup_seconds=30)
        return request, dict(q=q, run=run, source=source, cfg=cfg, cfg_path=cfg_path,
            direct=direct, result=result, document=document, ref=ref)

    def test_normal_passed_closer_preserves_inputs_and_default_does_not_clean(self):
        import json
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as tmp:
            request, f = self.fixture(Path(tmp))
            before = {p: p.read_bytes() for p in Path(tmp).rglob('*') if p.is_file()}
            with patch.object(qualification, 'cleanup_closed_test_cache') as cleanup:
                result = qualification.close_passed_native_qualification(request)
            cleanup.assert_not_called()
            self.assertEqual(result['test_cache_retention'], {'status': 'not-selected'})
            self.assertTrue(all(p.read_bytes() == raw for p, raw in before.items()))
            closed = json.loads(Path(result['closure']['path']).read_text())
            released = json.loads(Path(result['release']['path']).read_text())
            self.assertEqual(closed['status'], 'PASSED-CLOSED')
            self.assertTrue(closed['physical_closure'] and closed['full_current_passed'])
            self.assertEqual(closed['focused_current_executed'], 1)
            self.assertFalse(closed['collect_unrun_full_roots_selected'])
            self.assertEqual(closed['full_current_occurrences_passed'], f['cfg']['full_native_expected'])
            self.assertEqual(released['physical_closure'], result['closure'])
        for collect in (False, True):
            with self.subTest(collect=collect), tempfile.TemporaryDirectory() as tmp:
                request, _ = self.fixture(Path(tmp), collect=collect)
                result = qualification.close_passed_native_qualification(request)
                closed = json.loads(Path(result['closure']['path']).read_text())
                self.assertIs(closed['collect_unrun_full_roots_selected'], collect)
        with tempfile.TemporaryDirectory() as tmp:
            request, _ = self.fixture(Path(tmp), collect='yes')
            with self.assertRaises(AssertionError):
                qualification.close_passed_native_qualification(request)
            self.assertFalse(Path(request['closure_path']).exists())

    def test_failed_unknown_scoped_and_changed_source_never_publish_a_pass(self):
        import json
        from unittest.mock import patch
        for defect in ('owner_error', 'owner_nonzero', 'unreaped', 'unknown_cleanup', 'child_error',
                       'scoped', 'result_failed', 'source_guard_failed', 'metadata_failed', 'phase_failed',
                       'changed_source', 'wrong_configuration', 'missing_cli', 'missing_ffi',
                       'missing_install_phase', 'missing_smoke_phase', 'wrong_install_prefix',
                       'wrong_smoke_command', 'duplicate_full'):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as valid, tempfile.TemporaryDirectory() as tmp:
                valid_request, _ = self.fixture(Path(valid))
                self.assertIn('closure', qualification.close_passed_native_qualification(valid_request))
                request, f = self.fixture(Path(tmp)); run = f['run']
                if defect.startswith('owner_'):
                    path = run / 'dispatch/owner-result.json'; value = json.loads(path.read_text())
                    value['error' if defect == 'owner_error' else 'returncode'] = 'actual original failure' if defect == 'owner_error' else 2
                    f['document'](path, value)
                elif defect == 'unreaped':
                    f['document'](run / 'dispatch/outer-result.json', dict(reaped=False, exit_code=0))
                elif defect in ('unknown_cleanup', 'child_error'):
                    path = run / 'watchdog.json'; value = json.loads(path.read_text())
                    value['cleanup_complete' if defect == 'unknown_cleanup' else 'child_exit_status'] = False if defect == 'unknown_cleanup' else 1
                    f['document'](path, value)
                elif defect == 'scoped':
                    f['cfg']['execution_stage'] = 'focused-diagnostic'
                    request['configuration'] = f['document'](f['cfg_path'], f['cfg'])
                    f['direct']['configuration'] = request['configuration']
                    f['document'](run / 'dispatch/start.json', f['direct'])
                elif defect in ('result_failed', 'source_guard_failed', 'metadata_failed', 'phase_failed'):
                    if defect == 'result_failed': f['result']['passed'] = False
                    elif defect == 'source_guard_failed': f['result']['source_guard_after'] = False
                    elif defect == 'metadata_failed': f['result']['metadata_python']['passed'] = False
                    else: f['result']['phases'][0]['command']['returncode'] = 1
                    f['document'](run / 'commands/result.json', f['result'])
                elif defect in ('missing_cli', 'missing_ffi', 'missing_install_phase', 'missing_smoke_phase',
                                'wrong_install_prefix', 'wrong_smoke_command', 'duplicate_full'):
                    value = f['result']
                    if defect in ('missing_cli', 'missing_ffi'):
                        del value['installed']['bin/wikidict' if defect == 'missing_cli' else 'lib/libdictffi.so']
                    elif defect in ('missing_install_phase', 'missing_smoke_phase'):
                        name = 'cli-ffi-install' if defect == 'missing_install_phase' else 'cli-smoke'
                        value['phases'] = [phase for phase in value['phases'] if phase['name'] != name]
                    elif defect == 'wrong_install_prefix':
                        command = next(phase['command'] for phase in value['phases'] if phase['name'] == 'cli-ffi-install')
                        command['argv'][command['argv'].index('--prefix') + 1] = str(f['q'] / 'elsewhere')
                    elif defect == 'wrong_smoke_command':
                        next(phase for phase in value['phases'] if phase['name'] == 'cli-smoke')['command']['argv'][-1] = '--version'
                    else:
                        value['phases'].append(next(phase for phase in value['phases'] if phase['name'] == 'full-native-suite'))
                    f['document'](run / 'commands/result.json', value)
                elif defect == 'changed_source': (f['source'] / 'build.zig').write_text('changed source\n')
                else: f['direct']['configuration'] = {}; f['document'](run / 'dispatch/start.json', f['direct'])
                before = {p: p.read_bytes() for p in Path(tmp).rglob('*') if p.is_file()}
                with patch.object(qualification, 'cleanup_closed_test_cache') as cleanup:
                    with self.assertRaises(AssertionError): qualification.close_passed_native_qualification(request)
                cleanup.assert_not_called()
                self.assertFalse(Path(request['closure_path']).exists())
                self.assertFalse(Path(request['release_path']).exists())
                self.assertTrue(all(p.read_bytes() == raw for p, raw in before.items()))

    def test_live_owned_pid_or_scope_refuses_closure_without_signals(self):
        import os
        import json
        from unittest.mock import patch
        for defect in ('birth', 'scope'):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as tmp:
                request, f = self.fixture(Path(tmp))
                text = Path('/proc/self/stat').read_text(); fields = text[text.rfind(')') + 2:].split()
                path = f['run'] / 'dispatch/outer-start.json'; value = json.loads(path.read_text())
                value['owner'] = dict(pid=os.getpid(), starttime=int(fields[19]) + (defect == 'scope'),
                    process_group=os.getpid(), session=os.getpid())
                f['document'](path, value)
                # A residual member of an exclusive owned scope must refuse even
                # after the recorded PID identity itself no longer matches.
                residual = f"2147482000 {os.getpid()} {os.getpid()}\n"
                with patch('os.kill', side_effect=AssertionError('must never signal')) as kill, \
                        patch('subprocess.check_output', return_value=residual) as process_listing:
                    with self.assertRaises(AssertionError): qualification.close_passed_native_qualification(request)
                kill.assert_not_called()
                if defect == 'birth':
                    process_listing.assert_not_called()
                else:
                    process_listing.assert_called_once_with(['ps', '-eo', 'pid=,pgid=,sid='], text=True)
                self.assertFalse(Path(request['closure_path']).exists())

    def test_shared_launcher_session_is_explicitly_excluded_from_owned_scopes(self):
        import os
        import json
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as tmp:
            request, f = self.fixture(Path(tmp))
            fields = Path('/proc/self/stat').read_text().rsplit(')', 1)[1].split()
            path = f['run'] / 'dispatch/outer-start.json'
            value = json.loads(path.read_text())
            shared_group = 2147481001
            shared_session = 2147481002
            owned = {value[key]['pid'] for key in ('owner', 'outer')} | {os.getpid()}
            self.assertNotIn(shared_group, owned)
            self.assertNotIn(shared_session, owned)
            value['owner'] = dict(pid=os.getpid(), starttime=int(fields[19]) + 1,
                process_group=shared_group, session=shared_session)
            f['document'](path, value)
            residual = f"{os.getpid()} {shared_group} {shared_session}\n"
            with patch('os.kill', side_effect=AssertionError('must never signal')) as kill, \
                    patch('subprocess.check_output', return_value=residual):
                closed = qualification.close_passed_native_qualification(request)
            kill.assert_not_called()
            closure = json.loads(Path(closed['closure']['path']).read_text())
            self.assertIn(shared_session,
                closure['additional_session_exclusions_from_start_new_session_contract'])
            self.assertEqual(closure['exclusive_scope_residuals'], [])
            self.assertTrue(closure['physical_closure'])

    def test_retention_is_called_only_after_durable_full_closure_and_errors_defer(self):
        import json
        from unittest.mock import patch
        for outcome in ('retired', 'error', 'missing_reports'):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as tmp:
                request, f = self.fixture(Path(tmp), retain=True)
                original = (f['run'] / 'commands/result.json').read_bytes()
                callback = lambda cfg: dict(entry_paths=[])
                calls = []
                def cleanup(value, *, reconcile_protected):
                    calls.append(value)
                    self.assertIs(reconcile_protected, callback)
                    closed = json.loads(Path(value['closure']['path']).read_text())
                    released = json.loads(Path(value['release']['path']).read_text())
                    self.assertTrue(closed['full_current_passed'] and closed['physical_closure'])
                    self.assertEqual(released['physical_closure'], value['closure'])
                    self.assertEqual(value['configuration'], request['configuration'])
                    if outcome == 'error': raise OSError('cleanup fixture failure')
                    return dict(status='retired', removed_files=0)
                if outcome == 'missing_reports':
                    result = qualification.close_passed_native_qualification(request, reconcile_protected=callback)
                else:
                    with patch.object(qualification, 'cleanup_closed_test_cache', side_effect=cleanup):
                        result = qualification.close_passed_native_qualification(request, reconcile_protected=callback)
                    self.assertEqual(len(calls), 1)
                self.assertEqual(result['test_cache_retention']['status'], 'retired' if outcome == 'retired' else 'cleanup-deferred')
                if outcome == 'missing_reports':
                    self.assertIn('test_cache_retention', result['test_cache_retention']['reason'])
                receipt = json.loads(Path(result['test_cache_retention_receipt']['path']).read_text())
                self.assertEqual(receipt['outcome'], result['test_cache_retention'])
                self.assertEqual(receipt['closure'], result['closure'])
                self.assertEqual((f['run'] / 'commands/result.json').read_bytes(), original)
                self.assertEqual(json.loads(Path(result['closure']['path']).read_text())['status'], 'PASSED-CLOSED')

    def test_required_release_write_error_does_not_enter_cleanup(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as tmp:
            request, f = self.fixture(Path(tmp), retain=True)
            original = Path.open
            def opened(path, *args, **kwargs):
                if path == Path(request['release_path']): raise OSError('required release write failed')
                return original(path, *args, **kwargs)
            with patch.object(Path, 'open', opened), patch.object(qualification, 'cleanup_closed_test_cache') as cleanup:
                with self.assertRaisesRegex(OSError, 'required release write failed'):
                    qualification.close_passed_native_qualification(request)
            cleanup.assert_not_called()
            self.assertTrue(Path(request['closure_path']).exists())
            self.assertFalse(Path(request['release_path']).exists())


class RetentionArgvBudgetTests(unittest.TestCase):
    def limits(self, arg_max=2097152, page_size=4096):
        from unittest.mock import patch
        return patch('os.sysconf', side_effect=lambda name: {
            'SC_ARG_MAX': arg_max, 'SC_PAGESIZE': page_size}[name])

    def cost(self, chunk, environment):
        import os, struct
        prefix = ['/usr/bin/fuser', '-I']
        strings = prefix + list(chunk) + [key + '=' + value for key, value in environment.items()]
        return (sum(len(os.fsencode(value)) + 1 for value in strings)
                + struct.calcsize('P') * (len(strings) + 2)
                + len(os.fsencode(prefix[0])) + 1)

    def test_literal_inventory_uses_larger_batches_with_exact_order_and_byte_bounds(self):
        import os
        paths = ['/owned/' + str(index) + '/' + chr(233) * 80 for index in range(7000)]
        environment = {'LANG': 'C.UTF-8', 'TOKEN': 'x' * 177}
        with self.limits():
            chunks = list(qualification._retention_path_chunks(paths, environment=environment))
        self.assertEqual([path for chunk in chunks for path in chunk], paths)
        self.assertGreater(len(chunks[0]), 64)
        self.assertGreater(len(chunks), 1)
        for chunk in chunks:
            self.assertLessEqual(self.cost(chunk, environment), 1024 * 1024)
        for chunk, following in zip(chunks, chunks[1:]):
            self.assertGreater(self.cost(chunk + following[:1], environment), 1024 * 1024)
        self.assertGreater(len(os.fsencode(paths[0])), len(paths[0]))

    def test_low_arg_max_and_many_environment_pointers_reduce_capacity(self):
        paths = ['/owned/' + str(index) + 'x' * 25 for index in range(300)]
        environment = {'V' + str(index): '' for index in range(70)}
        with self.limits(arg_max=4096):
            bare = list(qualification._retention_path_chunks(paths, environment={}))
            loaded = list(qualification._retention_path_chunks(paths, environment=environment))
        self.assertLess(len(loaded[0]), len(bare[0]))
        self.assertEqual([path for chunk in loaded for path in chunk], paths)
        for chunk in loaded: self.assertLessEqual(self.cost(chunk, environment), 2048)
        for chunk, following in zip(loaded, loaded[1:]):
            self.assertGreater(self.cost(chunk + following[:1], environment), 2048)

    def test_unknown_limits_oversize_environment_and_strings_refuse(self):
        from unittest.mock import patch
        for limit in (0, -1, True, '2097152'):
            with self.limits(arg_max=limit), self.assertRaises(AssertionError):
                list(qualification._retention_path_chunks(['/owned/x'], environment={}))
        with patch('os.sysconf', side_effect=OSError('limit unavailable')), self.assertRaises(OSError):
            list(qualification._retention_path_chunks(['/owned/x'], environment={}))
        with self.limits(), self.assertRaises(AssertionError):
            list(qualification._retention_path_chunks(['/' + 'x' * 131071], environment={}))
        with self.limits(), self.assertRaises(AssertionError):
            list(qualification._retention_path_chunks(['/owned/x'], environment={'E': 'x' * 131070}))
        with self.limits(arg_max=4096), self.assertRaises(AssertionError):
            list(qualification._retention_path_chunks(['/owned/x'], environment={'E': 'x' * 2048}))
        for paths, environment in [(['/owned/x', '/owned/x'], {}), (['relative'], {}),
                                   (['/owned/\0x'], {}), (['/owned/x'], {'X=Y': 'z'}),
                                   (['/owned/x'], {'X': 'y\0z'})]:
            with self.limits(), self.assertRaises(AssertionError):
                list(qualification._retention_path_chunks(paths, environment=environment))
        with patch('os.sysconf', side_effect=AssertionError('empty selection must not query limits')):
            self.assertEqual(list(qualification._retention_path_chunks([], environment={})), [])

    def test_actual_probe_uses_budgeted_environment_and_late_open_use_preserves_every_pair(self):
        import os, time
        from types import SimpleNamespace
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); local = root / 'local'
            pairs = [TestCacheRetentionTests().pair(local, format(index, '032x')) for index in range(18)]
            expected_paths = [str(path) for pair in pairs for path in [pair, pair / 'test', pair / 'test_zcu.o']]
            original_environment = {'LANG': 'C', 'BOUND': 'value'}
            for code, stdout, stderr in ((0, '123', ''), (1, '', 'warning'), (2, '', '')):
                calls = []
                def probe(argv, **kwargs):
                    self.assertEqual(argv[:2], ['/usr/bin/fuser', '-I'])
                    self.assertEqual(kwargs['env'], original_environment)
                    self.assertLessEqual(self.cost(argv[2:], kwargs['env']), 2048)
                    self.assertTrue(kwargs['capture_output']); self.assertTrue(kwargs['text'])
                    self.assertGreater(kwargs['timeout'], 0)
                    calls.append(argv[2:])
                    os.environ['LATE'] = 'x' * 3000
                    return SimpleNamespace(returncode=1, stdout='', stderr='') if len(calls) == 1 else SimpleNamespace(returncode=code, stdout=stdout, stderr=stderr)
                with patch.dict(os.environ, original_environment, clear=True), self.limits(arg_max=4096), patch('subprocess.run', side_effect=probe):
                    with self.assertRaisesRegex(AssertionError, 'open-use probe not clear'):
                        qualification.retire_obsolete_test_pairs(local, set(), journal=root / 'journal',
                            deadline_monotonic=time.monotonic() + 30, lock_probe=lambda nodes: True)
                self.assertEqual(len(calls), 2)
                self.assertEqual([path for chunk in calls for path in chunk], expected_paths[:sum(map(len, calls))])
                self.assertFalse((root / 'journal').exists())
                for pair in pairs:
                    self.assertEqual(sorted(path.name for path in pair.iterdir()), ['test', 'test_zcu.o'])




class ManifestInvalidationTests(unittest.TestCase):
    def compiler(self):
        return dict(path='/home/a/.local/share/zig/0.17.0/zig',bytes=185514480,
            sha256='7c61539af19fa4082c94848f1c2b57b89e76dc6cfd5bd4c57764c3caf8f82272')

    def raw(self, digest=b'x'*16, path=b'fixture.zig'):
        import struct
        return struct.pack('<QQq16sB',17,31,47,digest,0)+path+b'\0'+b'\0'

    def fixture(self, root, name='1'*32):
        local=root/'local';(local/'h').mkdir(parents=True,exist_ok=True)
        raw=self.raw();manifest=local/'h'/name;manifest.write_bytes(raw)
        key=qualification._retention_zig017_output_key(name,raw)
        entry=local/'o'/key;entry.mkdir(parents=True)
        (entry/'test').write_bytes(b'executable fixture');(entry/'test_zcu.o').write_bytes(b'object fixture')
        return local,entry,manifest,raw

    def retire(self, local, root, keep=(), **kwargs):
        import time
        return qualification.retire_obsolete_test_pairs(local,set(keep),journal=root/'journal',
            deadline_monotonic=time.monotonic()+30,open_probe=lambda paths:(1,'',''),
            lock_probe=lambda nodes:True,compiler=kwargs.pop('compiler',self.compiler()),**kwargs)

    def test_manifest_format_mapping_uses_input_hash_and_ordered_digests(self):
        import struct
        raw=self.raw();name='1'*32;key=qualification._retention_zig017_output_key(name,raw)
        changed=struct.pack('<QQq',99,101,103)+raw[24:]
        self.assertEqual(key,qualification._retention_zig017_output_key(name,changed))
        self.assertNotEqual(key,qualification._retention_zig017_output_key('2'*32,raw))
        self.assertNotEqual(key,qualification._retention_zig017_output_key(name,self.raw(b'y'*16)))
        first=self.raw(b'a'*16)[:-1];second=self.raw(b'b'*16)[:-1]
        self.assertNotEqual(qualification._retention_zig017_output_key(name,first+second+b'\0'),
                            qualification._retention_zig017_output_key(name,second+first+b'\0'))
        for malformed in (b'',b'x',raw[:-1],raw[:40]+b'\xff'+raw[41:]):
            with self.assertRaises(AssertionError):qualification._retention_zig017_output_key(name,malformed)

    def test_retirement_preserves_original_manifest_and_invalidates_before_unlink(self):
        import os
        from unittest import mock
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);local,entry,manifest,raw=self.fixture(root)
            _,current,unrelated,other_raw=self.fixture(root,'2'*32)
            inode=manifest.stat().st_ino;unlink=Path.unlink;removed=[]
            def checked(path,*args,**kwargs):
                self.assertEqual(manifest.read_bytes(),b'');self.assertEqual(manifest.stat().st_ino,inode)
                removed.append(str(path));return unlink(path,*args,**kwargs)
            with mock.patch.object(Path,'unlink',checked):result=self.retire(local,root,{current})
            self.assertEqual(result['removed_files'],2);self.assertEqual(len(removed),2)
            self.assertFalse(entry.exists());self.assertTrue(current.exists())
            self.assertEqual(unrelated.read_bytes(),other_raw)
            record=result['manifest_invalidation']['invalidated'][0]
            self.assertEqual(Path(record['backup']).read_bytes(),raw)
            self.assertEqual(record['sha256'],hashlib.sha256(raw).hexdigest())
            self.assertEqual(manifest.stat().st_ino,inode)

    def test_locked_manifest_preserves_every_output_and_original_h_bytes(self):
        import os,fcntl
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);local,entry,manifest,raw=self.fixture(root)
            fd=os.open(manifest,os.O_RDWR)
            try:
                fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
                with self.assertRaises(BlockingIOError):self.retire(local,root)
                self.assertEqual(manifest.read_bytes(),raw)
                self.assertEqual(sorted(x.name for x in entry.iterdir()),['test','test_zcu.o'])
                self.assertFalse((root/'journal.manifests').exists())
            finally:os.close(fd)

    def test_missing_mapping_or_unsupported_compiler_preserves_outputs(self):
        for mode in ('missing','compiler','malformed'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);local,entry,manifest,raw=self.fixture(root)
                compiler=self.compiler()
                if mode=='missing':manifest.unlink()
                elif mode=='compiler':compiler=dict(compiler,sha256='0'*64)
                else:(local/'h'/('3'*32)).write_bytes(b'invalid\0')
                with self.assertRaises(AssertionError):self.retire(local,root,compiler=compiler)
                self.assertTrue((entry/'test').exists());self.assertTrue((entry/'test_zcu.o').exists())
                if manifest.exists():self.assertEqual(manifest.read_bytes(),raw)
                self.assertFalse((root/'journal.manifests').exists())

    def test_late_manifest_replacement_refuses_before_any_output_unlink(self):
        import fcntl
        from unittest import mock
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);local,entry,manifest,raw=self.fixture(root)
            flock=fcntl.flock;changed=False
            def replace(fd,operation):
                nonlocal changed
                result=flock(fd,operation)
                if operation==fcntl.LOCK_EX|fcntl.LOCK_NB and not changed:
                    changed=True;manifest.rename(root/'original-h');manifest.write_bytes(raw)
                return result
            with mock.patch.object(fcntl,'flock',replace),self.assertRaises(AssertionError):self.retire(local,root)
            self.assertTrue((entry/'test').exists());self.assertEqual((root/'original-h').read_bytes(),raw)
            self.assertFalse((root/'journal.manifests').exists())

    def test_manifest_hardlink_and_symlink_are_refused(self):
        import os
        for mode in ('hardlink','symlink'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);local,entry,manifest,raw=self.fixture(root)
                if mode=='hardlink':os.link(manifest,root/'external-h')
                else:manifest.rename(root/'external-h');manifest.symlink_to(root/'external-h')
                with self.assertRaises(AssertionError):self.retire(local,root)
                self.assertTrue((entry/'test').exists());self.assertEqual((root/'external-h').read_bytes(),raw)

    def test_backup_files_and_both_directory_entries_are_synced_before_truncate(self):
        import os
        from unittest import mock
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);local,entry,manifest,raw=self.fixture(root)
            fsync=os.fsync;truncate=os.ftruncate;durable=set()
            def synced(fd):
                durable.add(str(Path('/proc/self/fd/'+str(fd)).resolve()));return fsync(fd)
            def zero(fd,size):
                self.assertEqual(size,0)
                self.assertIn(str(root),durable);self.assertIn(str(root/'journal.manifests'),durable)
                self.assertTrue(any(name.endswith('.bin') for name in durable))
                return truncate(fd,size)
            with mock.patch.object(os,'fsync',synced),mock.patch.object(os,'ftruncate',zero):result=self.retire(local,root)
            self.assertEqual(result['removed_files'],2)





class OrphanManifestRetirementTests(unittest.TestCase):
    def compiler(self):
        return dict(path='/home/a/.local/share/zig/0.17.0/zig', bytes=185514480,
                    sha256='7c61539af19fa4082c94848f1c2b57b89e76dc6cfd5bd4c57764c3caf8f82272')

    def fixture(self, root):
        import struct
        local = root / 'local'
        (local / 'h').mkdir(parents=True)
        raw = struct.pack('<QQq16sB', 17, 31, 47, b'x' * 16, 0) + b'fixture.zig\0\0'
        manifest = local / 'h' / ('1' * 32)
        manifest.write_bytes(raw)
        mapped = qualification._retention_zig017_output_key(manifest.name, raw)
        entries = []
        for key in ('0' * 32, mapped):
            entry = local / 'o' / key
            entry.mkdir(parents=True)
            for name in ('test', 'test_zcu.o'):
                (entry / name).write_bytes(('owned fixture ' + name).encode())
            entries.append(entry)
        return local, entries[0], entries[1], manifest, raw

    def retire(self, local, root, keep, **kwargs):
        import time
        return qualification.retire_obsolete_test_pairs(
            local, set(keep), journal=root / 'journal', deadline_monotonic=time.monotonic() + 30,
            open_probe=lambda paths: (1, '', ''), compiler=self.compiler(),
            lock_probe=kwargs.pop('lock_probe', lambda nodes: True), **kwargs)

    def test_default_missing_mapping_stays_strict(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            local, orphan, current, manifest, raw = self.fixture(root)
            with self.assertRaisesRegex(AssertionError, 'missing manifest mapping'):
                self.retire(local, root, {current})
            self.assertTrue((orphan / 'test').exists())
            self.assertEqual(manifest.read_bytes(), raw)

    def test_generic_orphan_uses_complete_locked_absence_and_preserves_current(self):
        import json
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            local, orphan, current, manifest, raw = self.fixture(root)
            before = qualification._retention_stamp(manifest)
            result = self.retire(local, root, {current}, generic_only=True)
            self.assertEqual(result['removed_files'], 2)
            self.assertFalse(orphan.exists())
            self.assertTrue((current / 'test').exists())
            self.assertEqual(manifest.read_bytes(), raw)
            self.assertEqual(qualification._retention_stamp(manifest), before)
            self.assertEqual(result['manifest_invalidation']['orphan_output_keys'], [orphan.name])
            self.assertEqual(result['manifest_invalidation']['invalidated'], [])
            events = [json.loads(line) for line in (root / 'journal').read_text().splitlines()]
            self.assertTrue(any(row['event'] == 'orphan-absence-verified' for row in events))

    def test_mixed_orphan_and_mapped_keeps_existing_invalidation_transaction(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            local, orphan, mapped, manifest, raw = self.fixture(root)
            inode = manifest.stat().st_ino
            result = self.retire(local, root, set(), generic_only=True)
            self.assertEqual(result['removed_files'], 4)
            self.assertEqual(manifest.stat().st_ino, inode)
            self.assertEqual(manifest.read_bytes(), b'')
            invalidated = result['manifest_invalidation']['invalidated']
            self.assertEqual(len(invalidated), 1)
            self.assertEqual(Path(invalidated[0]['backup']).read_bytes(), raw)

    def test_locked_unrelated_manifest_refuses_orphan_before_any_unlink(self):
        import fcntl
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            local, orphan, current, manifest, raw = self.fixture(root)
            with manifest.open('r+b') as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with self.assertRaises(BlockingIOError):
                    self.retire(local, root, {current}, generic_only=True)
            self.assertTrue((orphan / 'test').exists())
            self.assertEqual(manifest.read_bytes(), raw)

    def test_new_or_changed_manifest_before_unlink_refuses(self):
        for mode in ('new', 'changed'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                local, orphan, current, manifest, raw = self.fixture(root)
                calls = 0
                def probe(nodes):
                    nonlocal calls
                    calls += 1
                    if calls == 3:
                        if mode == 'new':
                            (local / 'h' / ('2' * 32)).write_bytes(raw)
                        else:
                            manifest.write_bytes(raw.replace(b'fixture', b'changed'))
                    return True
                with self.assertRaisesRegex(AssertionError, 'manifest .*changed'):
                    self.retire(local, root, {current}, generic_only=True, lock_probe=probe)
                self.assertTrue((orphan / 'test').exists())
                self.assertTrue((orphan / 'test_zcu.o').exists())

    def test_unsupported_and_fd_budget_refuse_without_payload_change(self):
        from unittest import mock
        import resource
        for mode in ('unsupported', 'fd-budget'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                local, orphan, current, manifest, raw = self.fixture(root)
                if mode == 'unsupported':
                    manifest.write_bytes(b'bad')
                    context = mock.patch.object(resource, 'getrlimit', wraps=resource.getrlimit)
                else:
                    context = mock.patch.object(resource, 'getrlimit', return_value=(1, 1))
                with context, self.assertRaises(AssertionError):
                    self.retire(local, root, {current}, generic_only=True)
                self.assertTrue((orphan / 'test').exists())
                self.assertFalse((root / 'journal.manifests').exists())




class RawTestConsumerWiringTests(unittest.TestCase):
    def fixture(self, root):
        import json
        q = root / 'qualification'
        q.mkdir()
        cache = root / 'cache'
        binary = cache / 'local/o' / ('a' * 32) / 'test'
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b'closed raw ELF fixture')
        lock = q / 'ownership.lock'
        lock.touch()
        def document(path, value):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(value, sort_keys=True) + '\n')
            return dict(path=str(path), bytes=path.stat().st_size, sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        info = cache.stat()
        locks = [dict(path=str(lock), dev=lock.stat().st_dev, ino=lock.stat().st_ino)]
        cfg = dict(qualification_root=str(q), retained_cache=dict(path=str(cache), device=info.st_dev,
                   inode=info.st_ino, uid=info.st_uid, mode=info.st_mode & 0o7777), ownership_locks=locks)
        source = document(root / 'source.json', {'immutable': 'old producer source'})
        prior_cfg = document(q / 'configuration-prior.json', dict(private_manifest=source))
        context = dict(family='prepare', groups=['encoder_compile'], cache_local=str(cache / 'local'),
                       configuration=prior_cfg, source_manifest=source, argv=['zig', 'build', 'prepare-tests'])
        token = hashlib.sha256(json.dumps(context, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        report = document(root / 'report.json', dict(schema='wikidict.qualification-test-cache-paths.v1',
            context=token, cache_local=str(cache / 'local'), artifacts=[dict(group='encoder_compile',
            path=str(binary), stamp=qualification._retention_stamp(binary))]))
        item = dict(context=context, report=report, command=dict(status='exited', returncode=0))
        prior = document(root / 'prior-result.json', dict(source_guard_after=True,
                         focused_preparation_failures={}, cache_preparations=[item]))
        closed = document(root / 'prior-closure.json', dict(configuration=prior_cfg, result=prior,
                          physical_closure=True, source_guard_after=True, locks_free=True))
        release = document(root / 'prior-release.json', dict(released=True, physical_closure=closed))
        payload = document(root / 'reuse.json', dict(configuration=prior_cfg, result=prior, closure=closed,
                           release=release, source_manifest=source))
        raw = document(q / 'configuration-raw.json', dict(retained_cache=cfg['retained_cache'],
            ownership_locks=locks, execution_stage='focused-diagnostic', prepared_root_runtime_collect=True,
            prepared_group_reuse=payload, private_manifest=source, groups=[dict(prepared_group='encoder_compile')]))
        cfg['private_manifest'] = source
        cfg['retain_test_cache'] = True
        own_cfg = document(q / 'configuration-current.json', cfg)
        invocation = q / 'direct-invocation-current.json'
        return dict(q=q, cfg=cfg, raw=raw, own_cfg=own_cfg, invocation=invocation,
                    binary=binary, report=report, document=document)

    def publish(self, f):
        selection = qualification.generic_raw_test_selection(f['cfg'], [f['raw']], invocation_path=f['invocation'])
        f['document'](f['invocation'], dict(configuration=f['own_cfg'], generic_raw_test_selection=selection))
        return selection

    def test_existing_invocation_publishes_and_reconciles_exact_raw_keys_under_q_lock(self):
        import fcntl
        with tempfile.TemporaryDirectory() as tmp:
            f = self.fixture(Path(tmp))
            with (f['q'] / 'ownership.lock').open('r+b') as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                selection = self.publish(f)
                result = qualification.reconcile_generic_raw_test_consumers(f['cfg'], selection)
                self.assertEqual(result['entry_paths'], [str(f['binary'].parent)])
                self.assertTrue(result['generic_only'])
                with (f['q'] / 'ownership.lock').open('r+b') as competitor:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(competitor, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_unknown_new_or_changed_configuration_epoch_refuses(self):
        for mode in ('new-config', 'new-direct', 'changed', 'unresolved'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                f = self.fixture(Path(tmp))
                selection = self.publish(f)
                if mode == 'new-config':
                    f['document'](f['q'] / 'configuration-unknown.json', {'direct': 'unknown raw ELF'})
                elif mode == 'new-direct':
                    f['document'](f['q'] / 'direct-invocation-unknown.json', {'committed': True})
                elif mode == 'changed':
                    f['document'](Path(f['raw']['path']), {'changed': True})
                else:
                    selection['unresolved'] = ['unknown committed raw consumer']
                with self.assertRaises(AssertionError):
                    qualification.reconcile_generic_raw_test_consumers(f['cfg'], selection)
                self.assertTrue(f['binary'].exists())

    def test_stale_raw_report_and_wrong_cache_or_lock_authority_refuse(self):
        for mode in ('report', 'cache', 'lock'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                f = self.fixture(Path(tmp))
                selection = self.publish(f)
                if mode == 'report':
                    Path(f['report']['path']).write_text('{}')
                elif mode == 'cache':
                    selection['cache_root'] = {}
                else:
                    selection['ownership_locks'] = []
                with self.assertRaises(AssertionError):
                    qualification.reconcile_generic_raw_test_consumers(f['cfg'], selection)

    def test_ordinary_future_build_is_not_an_old_raw_elf_lease(self):
        with tempfile.TemporaryDirectory() as tmp:
            f = self.fixture(Path(tmp))
            f['document'](f['q'] / 'configuration-future-build.json',
                          dict(execution_stage='full', prepare_tests_from_cache=True))
            selection = self.publish(f)
            result = qualification.reconcile_generic_raw_test_consumers(f['cfg'], selection)
            self.assertEqual(result['entry_paths'], [str(f['binary'].parent)])


class FocusedFailureContinuationTests(unittest.TestCase):
    @staticmethod
    def terminal(name='TestUnexpectedResult'):
        return 'assertion diagnostics\n\nDICT_TEST_RETURN_ERROR_HEX=' + name.encode().hex() + '\n'

    def fake(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        fake = FakeExecution(Path(tmp.name))
        fake.groups = [fake.groups[2], fake.groups[0]]
        return fake

    def run_cases(self, fake, *, collect=True, prepare=None):
        _, cases = qualification.selected_focus_plan(fake.groups, [])
        qualification.execute_focused_cases(cases, binaries=fake.binaries, phase=fake.phase,
            source_root=fake.source, helper=dict(execute=fake.execute, ANSI=re.compile(r'\x1b\[[0-9;]*m')),
            guard=fake.guard, validate_dynamic=fake.dynamic, auth=fake.auth, ref=fake.ref,
            result=fake.result, save=fake.save, tools_prerequisite=True,
            collect_returned_failures=collect, prepare_group=prepare)
        return cases

    def test_typed_assertions_preserve_rows_and_execute_independent_groups(self):
        fake = self.fake()
        for label, name in (('tools-00', 'TestUnexpectedResult'), ('encoder-01', 'TestExpectedEqual')):
            fake.outcomes[label] = dict(status='exited', returncode=1)
            fake.outputs[label] = ('page payload cannot provide status', self.terminal(name))
        cases = self.run_cases(fake)
        rows = fake.result['focused_tests']
        self.assertEqual([row['name'] for row in rows], [case[2] for case in cases])
        self.assertEqual([row.get('returned_test_error') for row in rows],
                         ['TestUnexpectedResult', None, None, 'TestExpectedEqual'])
        self.assertEqual([row['passed'] for row in rows], [False, True, True, False])
        self.assertTrue(all(not row['full_suite_credit'] for row in rows))
        self.assertNotIn('focused_prerequisite_failure', fake.result)
        self.assertEqual(len(fake.calls), 4)
        self.assertEqual(fake.events[-1][0], 'guard')

    def test_clean_fixture_errors_remain_failed_and_execute_independent_groups(self):
        fake = self.fake()
        for label, name in (('tools-00', 'FileNotFound'), ('tools-01', 'InvalidFigurePageObservations')):
            fake.outcomes[label] = dict(status='exited', returncode=1)
            fake.outputs[label] = ('', self.terminal(name))
        cases = self.run_cases(fake)
        rows = fake.result['focused_tests']
        self.assertEqual([row['name'] for row in rows], [case[2] for case in cases])
        self.assertEqual([row.get('returned_test_error') for row in rows],
                         ['FileNotFound', 'InvalidFigurePageObservations', None, None])
        self.assertEqual([row['passed'] for row in rows], [False, False, True, True])
        self.assertEqual([row['outcome'] for row in rows], ['failed', 'failed', 'passed', 'passed'])
        self.assertTrue(all(not row['full_suite_credit'] for row in rows))
        self.assertEqual(len(fake.calls), 4)
        self.assertEqual(fake.events[-1][0], 'guard')

    def test_renderer_context_error_stays_failed_without_hiding_independent_cases(self):
        fake = self.fake()
        fake.outcomes['tools-00'] = dict(status='exited', returncode=1)
        fake.outputs['tools-00'] = ('', self.terminal('InvalidPreContext'))
        cases = self.run_cases(fake)
        rows = fake.result['focused_tests']
        self.assertEqual([row['name'] for row in rows], [case[2] for case in cases])
        self.assertEqual([row['outcome'] for row in rows], ['failed', 'passed', 'passed', 'passed'])
        self.assertEqual(rows[0]['returned_test_error'], 'InvalidPreContext')
        self.assertFalse(rows[0]['passed'])
        self.assertTrue(all(not row['full_suite_credit'] for row in rows))
        self.assertEqual(len(fake.calls), 4)
        self.assertEqual(fake.events[-1][0], 'guard')

    def test_clean_unknown_domain_names_stay_failed_and_continue(self):
        for name in ('UnknownDomainError', 'SyntaxError', 'UncompiledPresentation', 'A', 'x' * 128, 'Quoted domain name'):
            with self.subTest(error=name):
                fake = self.fake()
                fake.outcomes['tools-00'] = dict(status='exited', returncode=1)
                fake.outputs['tools-00'] = ('', self.terminal(name))
                self.run_cases(fake)
                self.assertEqual(len(fake.calls), 4)
                self.assertEqual(fake.result['focused_tests'][0]['returned_test_error'], name)
                self.assertEqual([row['outcome'] for row in fake.result['focused_tests']],
                                 ['failed', 'passed', 'passed', 'passed'])
                self.assertTrue(all(not row['full_suite_credit'] for row in fake.result['focused_tests']))

    def test_returned_allocation_error_is_not_a_watchdog_resource_stop(self):
        fake = self.fake()
        fake.outcomes['tools-00'] = dict(status='exited', returncode=1)
        fake.outputs['tools-00'] = ('', self.terminal('OutOfMemory'))
        self.run_cases(fake)
        self.assertEqual(len(fake.calls), 4)
        self.assertEqual(fake.result['focused_tests'][0]['outcome'], 'failed')
        self.assertEqual(fake.result['focused_tests'][0]['returned_test_error'], 'OutOfMemory')
        for status, code in (('timeout', None), ('oom', None), ('exited', -9), ('exited', 3)):
            with self.subTest(status=status, code=code):
                stopped = self.fake()
                stopped.outcomes['tools-00'] = dict(status=status, returncode=code)
                stopped.outputs['tools-00'] = ('', self.terminal('OutOfMemory'))
                with self.assertRaisesRegex(AssertionError, 'focused_functional_failure'):
                    self.run_cases(stopped)
                self.assertEqual(len(stopped.calls), 1)
                self.assertTrue(all(row['outcome'] == 'unrun' for row in stopped.result['focused_tests'][1:]))

    def test_unproven_termination_stops_before_any_later_test(self):
        valid = self.terminal()
        defects = [
            ('exited', 1, ''), ('exited', 1, valid + 'later output\n'),
            ('exited', 1, valid.replace('HEX=', 'HEX=0')), ('exited', 1, valid.rstrip('\n')),
            ('exited', 2, 'SkipZigTest\n'), ('exited', 3, 'memory leak\n'),
            ('exited', 1, 'OutOfMemory\n'), ('oom', None, 'OutOfMemory\n'),
            ('exited', 1, self.terminal('')), ('exited', 1, self.terminal('x' * 129)),
            ('exited', 1, self.terminal('NonAsciié')),
            ('exited', 1, '\nDICT_TEST_CHILD_PANIC\n'), ('exited', 3, valid),
            ('exited', 2, valid), ('exited', -9, valid), ('timeout', None, valid),
            ('running', None, valid), ('exited', True, valid), ('exited', 1, 'unknown test: tools.test.first\n')]
        for status, code, stderr in defects:
            with self.subTest(status=status, code=code, stderr=stderr):
                fake = self.fake(); fake.outcomes['tools-00'] = dict(status=status, returncode=code)
                fake.outputs['tools-00'] = ('', stderr)
                with self.assertRaisesRegex(AssertionError, 'focused_functional_failure'):
                    self.run_cases(fake)
                self.assertEqual(len(fake.calls), 1)
                self.assertFalse(fake.result['focused_qualified'])
                self.assertEqual(fake.result['focused_evidence_total'], 1)
                self.assertTrue(fake.result['all_selected_accounted'])
                self.assertFalse(fake.result['all_selected_executed'])
                self.assertTrue(all(row['outcome'] == 'unrun' for row in fake.result['focused_tests'][1:]))
                self.assertEqual(fake.events[-1][0], 'guard')

    def test_nonunique_unknown_or_unbound_name_never_grants_continuation(self):
        for count in (None, 0, 2, True):
            with self.subTest(count=count):
                fake = self.fake()
                fake.groups[0]['compiled_expected_occurrences'] = {} if count is None else {'tools.test.first': count}
                fake.outcomes['tools-00'] = dict(status='exited', returncode=1)
                fake.outputs['tools-00'] = ('', self.terminal())
                with self.assertRaisesRegex(AssertionError, 'focused_functional_failure'):
                    self.run_cases(fake)
                self.assertEqual(len(fake.calls), 1)
        self.assertIsNone(qualification.focused_returned_test_error(
            dict(status='exited', returncode=1), self.terminal(), 1, True))

    def test_default_tools_prerequisite_policy_is_unchanged(self):
        fake = self.fake(); fake.outcomes['tools-00'] = dict(status='exited', returncode=1)
        fake.outputs['tools-00'] = ('', self.terminal())
        with self.assertRaisesRegex(AssertionError, 'focused_functional_failure'):
            self.run_cases(fake, collect=False)
        self.assertEqual(len(fake.calls), 2)
        self.assertEqual(fake.result['focused_prerequisite_failure']['reason'], 'focused_functional_failure')
        self.assertTrue(all(row['outcome'] == 'unrun' for row in fake.result['focused_tests'][2:]))
        self.assertTrue(all('returned_test_error' not in row for row in fake.result['focused_tests']))

    def test_post_assertion_source_and_binary_changes_still_stop(self):
        for defect in ('source', 'binary', 'executor'):
            with self.subTest(defect=defect):
                fake = self.fake(); fake.outcomes['tools-00'] = dict(status='exited', returncode=1)
                fake.outputs['tools-00'] = ('', self.terminal())
                if defect == 'source':
                    fake.fail_guard_at = 2; fake.guard_error = RuntimeError('source changed')
                elif defect == 'binary': fake.mutate_after = 'tools-00'
                else: fake.command_error = OSError('dispatch failed')
                with self.assertRaises((AssertionError, RuntimeError, OSError)):
                    self.run_cases(fake)
                self.assertFalse(any(label.startswith('encoder') for label, _, _ in fake.calls))
                if defect == 'source': self.assertTrue(fake.result['group_guard_failures'])

    def test_clean_fixture_error_still_checks_source_and_binary_before_next_group(self):
        for name in ('FileNotFound', 'InvalidFigurePageObservations', 'InvalidPreContext', 'UnknownDomainError', 'SyntaxError', 'UncompiledPresentation', 'OutOfMemory'):
            for defect in ('source', 'binary', 'executor'):
                with self.subTest(error=name, defect=defect):
                    fake = self.fake(); fake.outcomes['tools-00'] = dict(status='exited', returncode=1)
                    fake.outputs['tools-00'] = ('', self.terminal(name))
                    if defect == 'source':
                        fake.fail_guard_at = 2; fake.guard_error = RuntimeError('source changed')
                    elif defect == 'binary': fake.mutate_after = 'tools-00'
                    else: fake.command_error = OSError('dispatch failed')
                    with self.assertRaises((AssertionError, RuntimeError, OSError)):
                        self.run_cases(fake)
                    self.assertFalse(any(label.startswith('encoder') for label, _, _ in fake.calls))
                    if defect == 'source': self.assertTrue(fake.result['group_guard_failures'])

    def test_compile_and_setup_failures_do_not_continue(self):
        for defect in ('compile', 'setup'):
            with self.subTest(defect=defect):
                fake = self.fake(); prepared = []
                def prepare(group):
                    prepared.append(group['id'])
                    if group['id'] == 'tools': return None
                    if defect == 'setup': raise OSError('encoder setup failed')
                    fake.result['focused_preparation_failures'] = {group['prepared_group']: {'status': 'compile failed'}}
                    return False
                with self.assertRaises((AssertionError, OSError)):
                    self.run_cases(fake, prepare=prepare)
                self.assertEqual(prepared, ['tools', 'encoder'])
                self.assertEqual(len(fake.calls), 2)
                if defect == 'compile':
                    self.assertTrue(fake.result['all_selected_accounted'])
                    self.assertFalse(fake.result['all_selected_executed'] or fake.result['focused_qualified'])

    def test_actual_filtered_worker_collects_tools_assertion_and_stays_failed(self):
        for error in qualification.FUNCTIONAL_TEST_ERRORS + ('FileNotFound', 'InvalidFigurePageObservations', 'InvalidPreContext', 'UnknownDomainError', 'SyntaxError', 'UncompiledPresentation', 'OutOfMemory', 'AccessDenied', 'ContainmentUnavailable'):
            with self.subTest(error=error):
                self.check_filtered_worker_failure(error)

    def check_filtered_worker_failure(self, error):
        control = InterleavedPreparationTests(); control.setUp(); self.addCleanup(control.doCleanups)
        cfg, proof, expectation = control.mixed_filtered_only_plan(('encoder_compile', 'encoder_writer'))
        original = qualification.execute_focused_cases
        observed = []
        def execute(cases, **kwargs):
            observed.append(kwargs['collect_returned_failures'])
            native = kwargs['helper']['execute']
            def output(directory, label, argv, source):
                command = native(directory, label, argv, source)
                if command['returncode'] == 1:
                    (directory / (label + '.stderr')).write_text(self.terminal(error))
                return command
            kwargs['helper'] = dict(kwargs['helper'], execute=output)
            return original(cases, **kwargs)
        with patch.object(qualification, 'execute_focused_cases', execute), self.assertRaisesRegex(AssertionError, 'focused_functional_failure'):
            control.run_fresh(cfg, proof, expectation, failure='tools.test.selected')
        result = control.result
        self.assertEqual(observed, [True])
        self.assertFalse(result['focused_qualified'])
        self.assertTrue(result['all_selected_accounted'] and result['all_selected_executed'])
        self.assertEqual(result['focused_evidence_total'], cfg['focused_expected'])
        self.assertEqual([row['name'] for row in result['focused_tests'] if not row['passed']], ['tools.test.selected'])
        self.assertEqual([row['returned_test_error'] for row in result['focused_tests'] if not row['passed']], [error])
        self.assertEqual(control.events.count('focused-prepare-selected-encoder'), 1)
        self.assertEqual(len(result['filtered_encoder_preparation']['groups']), 2)
        self.assertNotIn('fake_full_boundary_reached', result)
        self.assertFalse(result['filtered_tools_preparation']['selected_passed'])
        self.assertTrue(all(not row['full_suite_credit'] for row in result['focused_tests']))


class DirectSelectionFieldsTests(unittest.TestCase):
    def test_all_coverage_fields_follow_one_order_and_final_partition(self):
        cases = [dict(root='encoder_compile', name='root.test.discovery', kind='driver'),
                 dict(root='encoder_compile', name='profile.test.bytes', kind='audit'),
                 dict(root='blob_query_tests', name='model.test.version', kind='audit')]
        before = copy.deepcopy(cases)
        for final in (0, 1, 3):
            fields = helpers.direct_qualification_fields(cases, final_execution_count=final)
            plan, selector = fields['plan'], fields['selector']
            self.assertEqual(plan['execution_cases'], cases)
            self.assertEqual(selector['first_execution_selection'] + selector['second_execution_selection'],
                             selector['execution_order'])
            self.assertEqual(len(selector['second_execution_selection']), plan['final_execution_count'])
            self.assertEqual(selector['required_execution_selection'], selector['execution_order'])
            self.assertEqual(sum(map(len, selector['scope_partitions'].values())), 2)
            self.assertEqual(len(selector['qualification_selection']), 2)
            self.assertEqual(plan['expected_execution_occurrences'], 3)
            self.assertEqual(plan['expected_root_count'], 2)
            self.assertEqual(plan['expected_execution_body_count'], 2)
            self.assertEqual(plan['expected_discovery_occurrence_count'], 1)
        self.assertEqual(cases, before)
        fields['selector']['execution_order'][0]['selector'] = 'changed'
        self.assertEqual(cases, before)

    def test_rejects_duplicate_malformed_and_ambiguous_partition_without_mutation(self):
        case = dict(root='encoder_compile', name='profile.test.bytes', kind='audit')
        for cases, final in [([case, case], 0), ([dict(case, kind='unknown')], 0),
                             ([dict(case, unexpected=True)], 0), ([], 0),
                             ([case], True), ([case], -1), ([case], 2)]:
            before = copy.deepcopy(cases)
            with self.assertRaises(ValueError):
                helpers.direct_qualification_fields(cases, final_execution_count=final)
            self.assertEqual(cases, before)


class DirectControlProgressTests(unittest.TestCase):
    def fixture(self):
        cases = [dict(root='encoder_compile', name='root.test.' + name, kind='audit')
                 for name in ('first', 'second', 'third')]
        raw = dict(schema='existing-direct-root-controls-result.v1', tests_run=0,
                   compiled_inventory={}, test_results=[], stages=[dict(name='compile-encoder_compile', returncode=1)],
                   source_before=True, source_after=True)
        return cases, raw

    def test_compile_failure_preserves_absent_null_and_setup_evidence(self):
        for state in ('absent', 'null', 'setup'):
            with self.subTest(state=state):
                cases, raw = self.fixture()
                if state == 'null':
                    raw.update(first_test_started_unix=None, elapsed_to_first_test_seconds=None)
                if state == 'setup':
                    raw['stages'] = []
                before = copy.deepcopy(raw)
                result = helpers.normalize_direct_control_result(raw, cases)
                self.assertEqual(raw, before)
                self.assertEqual(result['phase'], 'setup_only' if state == 'setup' else 'compile_only')
                self.assertEqual(result['selected_counts'], dict(passed=0, failed=0, skipped=0, leaked=0, crashed=0, unrun=3))
                self.assertEqual(result['controls_unrun'], cases)
                self.assertEqual(result['compiled_root_count'], 0)
                self.assertIsNone(result['elapsed_to_first_test_seconds'])
                self.assertEqual(set(result['first_test_field_states'].values()), {'null' if state == 'null' else 'absent'})

    def started(self):
        cases, raw = self.fixture()
        raw.update(tests_run=2, first_test_started_unix=100.5, elapsed_to_first_test_seconds=0.5,
                   compiled_inventory={'encoder_compile': dict(inventory=dict(compiled_test_count=3, tests=[c['name'] for c in cases]))},
                   test_results=[dict(cases[0], returncode=0, status='passed'), dict(cases[1], returncode=1, status='failed')])
        return cases, raw

    def test_mixed_partial_execution_retains_unrun_and_raw_evidence(self):
        cases, raw = self.started()
        before = copy.deepcopy(raw)
        result = helpers.normalize_direct_control_result(raw, cases)
        self.assertEqual(raw, before)
        self.assertEqual(result['phase'], 'tests_started')
        self.assertEqual(result['selected_counts'], dict(passed=1, failed=1, skipped=0, leaked=0, crashed=0, unrun=1))
        self.assertEqual(result['controls_unrun'], [cases[2]])
        self.assertEqual(result['compiled_inventory_occurrences'], 3)
        self.assertEqual(result['first_test_started_unix'], 100.5)

    def test_started_attempt_without_returned_result_is_not_compile_only(self):
        cases, raw = self.fixture()
        raw.update(first_test_started_unix=100.5, elapsed_to_first_test_seconds=0.5)
        result = helpers.normalize_direct_control_result(raw, cases)
        self.assertEqual(result['phase'], 'tests_started')
        self.assertEqual(result['tests_run'], 0)
        self.assertEqual(result['selected_counts']['unrun'], 3)

    def test_inconsistent_counts_identity_verdict_inventory_and_timing_refuse(self):
        changes = [lambda r: r.update(tests_run=1),
                   lambda r: r['test_results'][0].update(name='foreign'),
                   lambda r: r['test_results'].append(copy.deepcopy(r['test_results'][0])),
                   lambda r: r['test_results'][0].update(status='failed'),
                   lambda r: r.update(first_test_started_unix=None),
                   lambda r: r.pop('elapsed_to_first_test_seconds'),
                   lambda r: r.update(elapsed_to_first_test_seconds=-1),
                   lambda r: r.update(first_test_started_unix=True),
                   lambda r: r['compiled_inventory']['encoder_compile']['inventory'].update(compiled_test_count=4)]
        for change in changes:
            with self.subTest(change=change):
                cases, raw = self.started()
                change(raw)
                before = copy.deepcopy(raw)
                with self.assertRaises(ValueError):
                    helpers.normalize_direct_control_result(raw, cases)
                self.assertEqual(raw, before)


class ToolsPartitionAdoptionTests(unittest.TestCase):
    def test_current_and_legacy_full_roots_are_both_exact(self):
        for layout in (qualification.FULL_DIAGNOSTIC_ROOTS, qualification.LEGACY_FULL_DIAGNOSTIC_ROOTS):
            expected=dict(groups=[dict(root=root,expected_occurrences={root+'.test.fixture':1}) for root,_,_ in layout],expected_groups=len(layout),expected_total=len(layout))
            groups=qualification.full_diagnostic_groups(expected)
            self.assertEqual([g['root'] for g in groups],[r[0] for r in layout])
        self.assertEqual(len(qualification.FULL_DIAGNOSTIC_ROOTS),29)
        self.assertEqual(len(qualification.LEGACY_FULL_DIAGNOSTIC_ROOTS),26)

    def test_mixed_missing_or_duplicate_partition_is_refused(self):
        layout=qualification.FULL_DIAGNOSTIC_ROOTS
        base=dict(groups=[dict(root=root,expected_occurrences={root+'.test.fixture':1}) for root,_,_ in layout],expected_groups=len(layout),expected_total=len(layout))
        for changed in (base['groups'][:-1],base['groups']+[dict(root='blob_build_tests',expected_occurrences={'unexpected':1})],base['groups']+[base['groups'][0]]):
            with self.assertRaises(AssertionError):
                qualification.full_diagnostic_groups(dict(base,groups=changed,expected_groups=len(changed)))

    def test_default_full_and_unfiltered_tools_cache_selection_use_four_parts(self):
        parts=sorted(row[1] for row in qualification.TOOLS_DIAGNOSTIC_ROOTS)
        for selected in ('tools_partitioned',):
            self.assertEqual(qualification.prepared_cache_groups(selected,[]),parts)
        self.assertEqual(qualification.prepared_cache_groups('tools',['specific']),['tools'])
        self.assertEqual(qualification.prepared_cache_groups('tools',[]),['tools'])
        default=qualification.prepared_cache_groups(None,[])
        self.assertEqual(sorted(g for g in default if g.startswith('tools_')),parts)
        self.assertNotIn('tools',default)
        self.assertEqual(qualification.prepared_cache_groups(None,[],full=True),sorted(r[1] for r in qualification.FULL_DIAGNOSTIC_ROOTS))

    def test_tools_partitions_refuse_overlapping_names_and_retain_failure_statuses(self):
        layout=qualification.FULL_DIAGNOSTIC_ROOTS
        expected=dict(groups=[dict(root=root,expected_occurrences={root+'.test.fixture':1}) for root,_,_ in layout],expected_groups=len(layout),expected_total=len(layout))
        parts=[row for row in expected['groups'] if row['root'].startswith('blob_build_')]
        parts[1]['expected_occurrences']=dict(parts[0]['expected_occurrences'])
        with self.assertRaises(AssertionError): qualification.full_diagnostic_groups(expected)
        fixture=FailedFullCollectionTests()
        original=dict(groups=[dict(root=root,expected_occurrences={root+'.test.fixture':1}) for root,_,_ in layout],expected_groups=len(layout),expected_total=len(layout))
        groups=qualification.full_diagnostic_groups(original)
        output=fixture.output(groups,{'blob_build_normal_tests','blob_build_observations_tests'})
        observed=qualification.completed_diagnostic_roots(groups,fixture.helper,output,'')
        self.assertTrue(observed['blob_build_normal_tests']['failed'])
        self.assertTrue(observed['blob_build_observations_tests']['failed'])
        self.assertFalse(observed['blob_build_support_tests']['failed'])
        self.assertEqual(set(observed),{group['root'] for group in groups})


    def test_logical_tools_union_preserves_list_and_counted_record_multiplicities(self):
        roots={root:[root+'.test.one'] for root,_,_ in qualification.TOOLS_DIAGNOSTIC_ROOTS}
        expected={values[0]:1 for values in roots.values()}
        self.assertEqual(qualification.tools_logical_occurrences(roots),expected)
        counted={root:{values[0]:1} for root,values in roots.items()}
        self.assertEqual(qualification.tools_logical_occurrences(counted),expected)
        one=next(iter(counted));name=next(iter(counted[one]));counted[one][name]=2
        with self.assertRaises(AssertionError):qualification.tools_logical_occurrences(counted)
        counted[one][name]=0
        with self.assertRaises(AssertionError):qualification.tools_logical_occurrences(counted)
        del counted[one]
        with self.assertRaises(KeyError):qualification.tools_logical_occurrences(counted)

    def test_focused_subset_binding_keeps_legacy_contract_and_composes_current_tools(self):
        fixture=DocumentPartitionPreparationTests()
        legacy=fixture.fixture()
        self.assertEqual(legacy['expect']['expected']['expected_groups'],26)
        self.assertLess(len(legacy['expect']['expected']['groups']),26)
        fixture.preparation_checks()(legacy)
        current=fixture.fixture()
        expected=current['expect']['expected'];expected['expected_groups']=29
        old=next(row for row in expected['groups'] if row['root']=='blob_build_tests')
        names=[old['expected_occurrences'][0],'tools.test.core','tools.test.observations','tools.test_0']
        expected['groups'].remove(old)
        expected['groups'].extend(dict(root=root,expected_occurrences=[name]) for (root,_,_),name in zip(qualification.TOOLS_DIAGNOSTIC_ROOTS,names))
        group=next(group for group in current['cfg']['groups'] if group['id']=='tools')
        group['compiled_expected_occurrences']=names;group['compiled_expected_count']=len(names)
        current['group_binding']['prepared_expected_occurrences']['tools']=names
        fixture.preparation_checks()(current)
        mixed=copy.deepcopy(current);mixed['expect']['expected']['groups'].append(old)
        with self.assertRaises(AssertionError):fixture.preparation_checks()(mixed)
        missing=copy.deepcopy(current);missing['expect']['expected']['groups'].pop()
        with self.assertRaises(KeyError):fixture.preparation_checks()(missing)


class InstalledCacheProvenanceTests(unittest.TestCase):
    def fixture(self, root, key='a' * 32, content=b'fake executable'):
        cache = root / 'local'
        raw = cache / 'o' / key / 'dict-blob-build'
        raw.parent.mkdir(parents=True)
        raw.write_bytes(content); raw.chmod(0o755)
        keeper = root / 'prefix/bin/dict-blob-build'
        keeper.parent.mkdir(parents=True, exist_ok=True)
        keeper.write_bytes(content); keeper.chmod(0o755)
        output = root / 'prefix/share/wikidict/writer-cache-output.json'
        return cache, raw, keeper, output

    def reference(self, path):
        return dict(path=str(path), bytes=path.stat().st_size,
                    sha256=hashlib.sha256(path.read_bytes()).hexdigest(), mode=path.stat().st_mode & 0o777)

    def record(self, cache, raw, keeper, output):
        return qualification.record_installed_cache_artifact(output, cache, 'dict-blob-build', raw, keeper, 'b' * 64)

    def test_actual_key_pair_and_keeper_are_recorded_without_scanning(self):
        with tempfile.TemporaryDirectory() as temp:
            cache, raw, keeper, output = self.fixture(Path(temp))
            obj = raw.with_name('dict-blob-build_zcu.o'); obj.write_bytes(b'paired object')
            with patch.object(Path, 'iterdir', side_effect=AssertionError('cache walk')), patch.object(Path, 'glob', side_effect=AssertionError('cache glob')):
                report = self.record(cache, raw, keeper, output)
            self.assertEqual(report['cache_key'], 'a' * 32)
            self.assertEqual(report['historical_compiler_outputs']['final']['recorded_path'], str(raw))
            self.assertEqual(report['historical_compiler_outputs']['paired_object']['output']['recorded_sha256'], hashlib.sha256(b'paired object').hexdigest())
            self.assertEqual(report['installed_at_install']['sha256'], self.reference(keeper)['sha256'])
            self.assertFalse(report['retirement_authorized'])
            self.assertFalse(report['raw_output_retention_required'])
            def operative_refs(value):
                if isinstance(value, dict):
                    return ([value['path']] if {'path', 'bytes', 'sha256'} <= value.keys() else []) + [p for v in value.values() for p in operative_refs(v)]
                return [p for v in value for p in operative_refs(v)] if isinstance(value, list) else []
            self.assertEqual(operative_refs(report), [str(keeper)])

    def test_sealed_keeper_validates_after_raw_outputs_retire(self):
        with tempfile.TemporaryDirectory() as temp:
            cache, raw, keeper, output = self.fixture(Path(temp))
            obj = raw.with_name('dict-blob-build_zcu.o'); obj.write_bytes(b'paired object')
            self.record(cache, raw, keeper, output)
            report_ref = self.reference(output)
            raw.unlink(); obj.unlink(); keeper.chmod(0o555)
            report = qualification.validate_installed_cache_provenance(report_ref, self.reference(keeper))
            self.assertTrue(report['raw_and_installed_same_bytes'])

    def test_changed_installed_bytes_cannot_restamp_old_provenance(self):
        with tempfile.TemporaryDirectory() as temp:
            cache, raw, keeper, output = self.fixture(Path(temp))
            self.record(cache, raw, keeper, output)
            report_ref = self.reference(output)
            keeper.write_bytes(b'replacement executable')
            with self.assertRaises(ValueError):
                qualification.validate_installed_cache_provenance(report_ref, self.reference(keeper))

    def test_report_cannot_overwrite_cache_or_installed_keeper(self):
        with tempfile.TemporaryDirectory() as temp:
            cache, raw, keeper, output = self.fixture(Path(temp))
            for invalid in (raw, raw.with_name('report.json'), keeper):
                with self.assertRaises(ValueError): self.record(cache, raw, keeper, invalid)
            self.assertEqual(raw.read_bytes(), b'fake executable')
            self.assertEqual(keeper.read_bytes(), b'fake executable')

    def test_ambiguous_paired_objects_are_not_presented_as_one_output(self):
        with tempfile.TemporaryDirectory() as temp:
            cache, raw, keeper, output = self.fixture(Path(temp))
            raw.with_name('dict-blob-build_zcu.o').write_bytes(b'ELF object')
            raw.with_name('dict-blob-build_zcu.obj').write_bytes(b'COFF object')
            report = self.record(cache, raw, keeper, output)
            pair = report['historical_compiler_outputs']['paired_object']
            self.assertEqual(pair['status'], 'ambiguous')
            self.assertNotIn('output', pair)
            self.assertFalse(pair['operative'])

    def test_mutation_before_publication_is_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            cache, raw, keeper, output = self.fixture(Path(temp))
            obj = raw.with_name('dict-blob-build_zcu.o'); obj.write_bytes(b'paired object')
            original = qualification._installed_cache_file
            def observed(path):
                result = original(path)
                if path == obj:
                    stamp = raw.stat(); raw.write_bytes(b'mutated executable')
                    os.utime(raw, ns=(stamp.st_atime_ns, stamp.st_mtime_ns + 1))
                return result
            with patch.object(qualification, '_installed_cache_file', side_effect=observed):
                with self.assertRaises(ValueError): self.record(cache, raw, keeper, output)
            self.assertFalse(output.exists())

    def test_repeated_install_replaces_only_one_concise_record(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cache, raw, keeper, output = self.fixture(root)
            self.record(cache, raw, keeper, output)
            cache, raw, keeper, output = self.fixture(root, key='c' * 32, content=b'new executable')
            report = self.record(cache, raw, keeper, output)
            self.assertEqual(report['cache_key'], 'c' * 32)
            self.assertEqual(report['historical_compiler_outputs']['paired_object']['status'], 'missing')
            self.assertEqual([p.name for p in output.parent.iterdir()], ['writer-cache-output.json'])

    def test_unchanged_receipt_reuses_exact_identities_without_hashes_or_fsync(self):
        with tempfile.TemporaryDirectory() as temp:
            cache, raw, keeper, output = self.fixture(Path(temp))
            raw.with_name('dict-blob-build_zcu.o').write_bytes(b'paired object')
            first = self.record(cache, raw, keeper, output)
            original = output.read_bytes(); stamp = qualification._retention_stamp(output)
            with patch.object(qualification, '_installed_cache_file', side_effect=AssertionError('rehashed unchanged artifact')), patch.object(os, 'fsync', side_effect=AssertionError('rewrote unchanged receipt')):
                self.assertEqual(self.record(cache, raw, keeper, output), first)
            self.assertEqual(output.read_bytes(), original)
            self.assertEqual(qualification._retention_stamp(output), stamp)

    def test_changed_identity_or_receipt_integrity_requires_fresh_verification(self):
        import json
        with tempfile.TemporaryDirectory() as temp:
            cache, raw, keeper, output = self.fixture(Path(temp))
            obj = raw.with_name('dict-blob-build_zcu.o'); obj.write_bytes(b'paired object')
            self.record(cache, raw, keeper, output)
            # Same bytes on another inode are still a new compiler output.
            replacement = obj.with_name('replacement'); replacement.write_bytes(obj.read_bytes()); os.replace(replacement, obj)
            with patch.object(qualification, '_installed_cache_file', wraps=qualification._installed_cache_file) as observed:
                self.record(cache, raw, keeper, output)
                self.assertEqual(observed.call_count, 3)
            payload = json.loads(output.read_text()); payload['recorded_unix_ns'] += 1
            output.write_text(json.dumps(payload))
            with patch.object(qualification, '_installed_cache_file', wraps=qualification._installed_cache_file) as observed:
                self.record(cache, raw, keeper, output)
                self.assertEqual(observed.call_count, 3)


if __name__ == '__main__':
    unittest.main()
