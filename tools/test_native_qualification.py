#!/usr/bin/env python3
"""Pure planning and fake-executor controls; never launches a native process."""
import copy
import hashlib
from pathlib import Path
import re
import tempfile
import unittest

import native_qualification as qualification


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
    def execute_prefix(self, cfg, proof, expectation, commands):
        # Run the real fresh-worker prefix up to prepared-output inspection.
        # Source/authentication/process ownership are tested by the ordinary job;
        # only subprocess execution and unrelated metadata loading are faked here.
        import ast
        from types import SimpleNamespace
        source = ast.parse(Path(qualification.__file__).read_text())
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
                cfg=cfg, group_binding=proof, expect=expectation,
                ordered_groups=ordered, focus_cases=cases, Path=Path, re=re,
                private=Path(proof['cwd']), private_manifest={}, read=read, auth=unexpected_auth,
                execute=execute, execute_outcome=execute_outcome,
                require_ordinary_preparation_compile_failure=qualification.require_ordinary_preparation_compile_failure, save=lambda: None, result=result, out=Path(tmp),
                args=SimpleNamespace(compiler=compiler), cache=Path('/fixture/cache'),
                validate_preparation_plan=qualification.validate_preparation_plan,
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
        self.assertEqual(commands[0][1], ['/fixture/python/python3', '-B', 'tools/test_reviewed_language_aliases.py'])
        for (_, argv), group in zip(commands[1:], ordered, strict=True):
            self.assertEqual(argv[:4], ['/fixture/zig', 'build', 'prepare-tests', '-j2'])
            self.assertEqual(argv[-1], '-Dprepare-test-group=' + group['id'])
            self.assertEqual(argv[4], '--prefix')
        self.assertEqual(result['prepared_names'], tuple(group['id'] for group in cfg['groups']))
        self.assertEqual(result['prepare_discovery'], proof['prepared_discovery_filters'])
        self.assertIs(result['result']['metadata_python']['command'], result['result']['phases'][0])
        self.assertEqual([phase['name'] for phase in result['result']['phases']], [label for label, _ in commands])



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
    def fixture(self, base):
        root = base / 'checkout'; (root / 'tools').mkdir(parents=True)
        helper = root / 'tools/build_resource_limits.py'; helper.write_bytes(b'qualified helper bytes')
        descriptor = FakeExecution.ref(helper)
        inputs = {name: dict(reference=dict(path=str(root / name))) for name in
                  ('tools/build_watchdog_guardian.py', 'tools/build_disk_limits.py', 'tools/extraction_cache.py')}
        inputs['tools/build_resource_limits.py'] = dict(reference=copy.deepcopy(descriptor))
        return root, helper, descriptor, inputs

    def auth(self, descriptor):
        self.assertEqual(FakeExecution.ref(Path(descriptor['path'])), descriptor)
        return Path(descriptor['path'])

    def test_authenticated_helper_locates_checkout_independent_of_tool_or_working_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            for name in ('first location', 'second-checkout'):
                root, helper, descriptor, inputs = self.fixture(base / name)
                self.assertEqual(qualification.bound_repository_root(descriptor, inputs, self.auth), root)
                self.assertEqual(helper.read_bytes(), b'qualified helper bytes')
                self.assertNotEqual(root, Path.cwd())

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
            w=dict(ANSI=re.compile(r'\x1b\[[0-9;]*m'), STATUS=re.compile(r'^(ok) (.+)$', re.M),
                   classify=lambda so, se, standalone: native),
            inv=dict(validate_grouped=lambda helper, expected, so, se: grouped),
            markers=markers, ev=dict(markers=old_markers), ds=object(),
            dynamic=dict(validate=lambda state, **kwargs: dynamic_calls.append((state, kwargs))),
            result={}, save=lambda: None, execute=execute)
        source = ast.parse(Path(qualification.__file__).read_text())
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
                assignments = [node for node in ast.walk(value['source']) if isinstance(node, ast.Assign)
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
                  compile_failures=(), unsafe_compile_outcome=None, compile_guard_failure=False):
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
                prepared = label.removeprefix('focused-prepare-')
                prefix = Path(argv[argv.index('--prefix') + 1]) / proof['prepared_relative_directory']
                prefix.mkdir(parents=True, exist_ok=True)
                binary = prefix / prepared
                if prepared not in compile_failures:
                    binary.write_bytes(prepared.encode()); binary.chmod(0o755)
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
            if compile_guard_failure and events[-1].startswith('focused-prepare-'):
                raise OSError('source guard after compilation')
        def execute_outcome(label, argv):
            so, se = execute(label, argv)
            guard()
            return result['phases'][-1]['command'], so, se
        def focused(directory, label, argv, source):
            name = argv[-1]; events.append('focus:' + name)
            if mutate_earlier_on_last_focus and name == cases[-1][2]:
                prefix = out / 'prepared-tests' / proof['prepared_relative_directory']
                earlier = next(path for path in prefix.iterdir() if path != Path(argv[0]))
                earlier.write_bytes(b'changed by last focused case')
            self.assertEqual(source, Path(proof['cwd']))
            (directory / (label + '.stdout')).write_text('ordinary focused outcome\n')
            (directory / (label + '.stderr')).write_text('')
            return dict(status='exited', returncode=1 if name == failure else 0)
        tree = ast.parse(Path(qualification.__file__).read_text())
        branch = next(node.orelse for node in ast.walk(tree) if isinstance(node, ast.If)
                      and ast.unparse(node.test) == "cfg['execution_stage'] == 'tail'")
        finish = next(index for index, node in enumerate(branch) if isinstance(node, ast.If)
                      and ast.unparse(node.test) == "cfg['execution_stage'] != 'focused-diagnostic'")
        argv_function = next(node for node in ast.walk(tree) if isinstance(node, ast.FunctionDef)
                             and node.name == 'prepare_tests_argv')
        # Native full-suite execution is the only replaced boundary; all preparation,
        # discovery, focus and qualification predicates above it are actual code.
        full_boundary = ast.parse("result['fake_full_boundary_reached'] = True").body
        code = compile(ast.Module(body=copy.deepcopy([argv_function] + branch[:finish] + full_boundary),
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
        for stage in ('unknown', 'focused_diagnostic', 'tail', 'support-tail', None):
            cfg, proof, expectation = self.plan(['tools'], stage)
            commands = []
            with self.subTest(stage=stage), self.assertRaises(AssertionError):
                PreparationFailFastTests().execute_prefix(cfg, proof, expectation, commands)
            self.assertEqual(commands, [])

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
            (private / 'tools').mkdir()
            (private / 'tools/ffi_integration_test.c').write_text('DICT_ABI_VERSION == 10u && dict_abi_version() == DICT_ABI_VERSION')
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
                    result=result,private_manifest={'src/ffi/dict.h':{'sha256':'fixture'}},private=private,Path=Path,
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
        self.assertIn("payload.read_bytes().startswith(b'DPRD')", text)
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
                  for root, _, _ in qualification.FULL_DIAGNOSTIC_ROOTS]
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
            report=qualification.collect_failed_full_roots(plan,helper=self.helper,prepare=prepare,run=run,
                          guard=lambda:None,auth=lambda b:None,save=lambda r:saved.append(copy.deepcopy(r)))
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
                          'ContainmentUnavailable', 'UnknownReturnedError', 'SkipZigTest')]
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
            prepare=lambda g:dict(path=g['root']),run=lambda g,b:(dict(status='exited',returncode=0),'',self.output([g])+'literal OutOfMemory watchdog expected-error prose\n'),
            guard=lambda:None,auth=lambda b:None,save=lambda r:None)
        self.assertTrue(report['completed']);self.assertFalse(report['full_suite_credit'])

    def test_compile_guard_and_resource_errors_stop_without_pass_credit(self):
        for defect in ('compile','guard','auth','resource','tool','unknown','status'):
            plan=self.plan();events=[];saved=[]
            def guard():
                if defect=='guard':raise RuntimeError('source changed')
            def auth(b):
                if defect=='auth':raise RuntimeError('binary changed')
            def prepare(g):
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
                qualification.collect_failed_full_roots(plan,helper=self.helper,prepare=prepare,run=run,guard=guard,auth=auth,save=lambda r:saved.append(copy.deepcopy(r)))
            self.assertLessEqual(events.count('prepare'),1)
            self.assertFalse(saved[-1]['completed']);self.assertEqual(saved[-1]['roots'],[])
            self.assertFalse(saved[-1]['full_suite_credit'])

    def test_later_functional_failure_does_not_hide_remaining_roots(self):
        plan=self.plan(23);fail=plan['remaining'][0]['root']
        def run(g,b):return dict(status='exited',returncode=int(g['root']==fail)),'',self.output([g],{fail})
        report=qualification.collect_failed_full_roots(plan,helper=self.helper,prepare=lambda g:dict(path=g['root']),
                      run=run,guard=lambda:None,auth=lambda b:None,save=lambda r:None)
        self.assertEqual([r['passed'] for r in report['roots']],[False,True])
        self.assertTrue(report['completed']);self.assertFalse(report['full_suite_credit'])

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
                    save=lambda:None,guard=lambda:None,auth=lambda b:None,ref=lambda p:dict(path=str(p)),execute=execute,
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
        self.assertLess(source.index("result['bundle_pipeline_reuse']=full_pipeline_reuse_record("),source.index("result['full_native_pass']=True;save()"))


if __name__ == '__main__':
    unittest.main()
