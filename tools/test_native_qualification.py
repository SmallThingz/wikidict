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
                 declaration_names=['first', 'second'])
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
        self.command_error = None
        self.guard_error = None
        self.dynamic_error = None
        self.auth_error = None
        self.fail_guard_at = None
        self.guard_count = 0
        self.mutate_after = None
        self.result = dict(focused_tests=[])
        self.binaries = {}
        for group in groups():
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
        (phase / (label + '.stdout')).write_text('selected assertion\n')
        (phase / (label + '.stderr')).write_text('')
        command = self.outcomes.get(label, dict(status='exited', returncode=0))
        if label == self.mutate_after:
            Path(argv[0]).write_bytes(b'changed after execution')
        return command

    def run(self, priority=None):
        _, cases = qualification.selected_focus_plan(groups(), priority or [])
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
        self.assertTrue(all(not row['exact_name_discovered'] for row in rows if not row['passed']))
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
        end = next(index for index, node in enumerate(block) if isinstance(node, ast.For)
                   and isinstance(node.iter, ast.Name) and node.iter.id == 'ordered_groups')
        argv_functions = [node for node in ast.walk(source) if isinstance(node, ast.FunctionDef)
                          and node.name == 'prepare_tests_argv']
        self.assertEqual(len(argv_functions), 1)
        stage_guards = [node for node in ast.walk(source) if isinstance(node, ast.Assert)
                        and isinstance(node.test, ast.Compare)
                        and ast.unparse(node.test.left) == "cfg['execution_stage']"]
        self.assertEqual(len(stage_guards), 1)
        prefix = compile(ast.Module(body=copy.deepcopy(argv_functions + stage_guards + block[:end + 1]),
                                    type_ignores=[]), str(qualification.__file__), 'exec')
        cfg = copy.deepcopy(cfg)
        cfg.setdefault('runtime_python', {'sha256': 'python'})
        cfg.setdefault('metadata_python_reuse', {'sha256': 'metadata'})
        cfg.setdefault('metadata_python_expected', 8)
        cfg.setdefault('python_bin', '/fixture/python')
        ordered, cases = qualification.bound_focus_plan(cfg, proof, Path(proof['cwd']))
        metadata = dict(current_manifest=cfg['private_manifest'], runtime_python=cfg['runtime_python'],
                        current_execution_required=True, dependency_files={})
        result = dict(phases=[])
        def read(descriptor):
            self.assertEqual(descriptor, cfg['metadata_python_reuse'])
            return metadata
        def execute(label, argv):
            commands.append((label, argv))
            result['phases'].append(dict(name=label, command=dict(argv=argv, status='exited', returncode=0)))
            if label == 'reviewed-language-aliases':
                return ('Ran ' + str(cfg['metadata_python_expected']) + ' tests in 0.001s\nOK\n', '')
            return ('', '')
        def unexpected_auth(value):
            self.fail('unrelated metadata dependency unexpectedly accessed: ' + repr(value))
        compiler = Path('/fixture/zig')
        with tempfile.TemporaryDirectory() as tmp:
            namespace = dict(cfg=cfg, group_binding=proof, expect=expectation,
                ordered_groups=ordered, focus_cases=cases, Path=Path, re=re,
                private=Path(proof['cwd']), private_manifest={}, read=read, auth=unexpected_auth,
                execute=execute, save=lambda: None, result=result, out=Path(tmp),
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
        command = dict(status='exited', returncode=0)
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
        namespace = dict(cfg=cfg, group_binding=proof, expect=expectation, private=Path(proof['cwd']),
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


if __name__ == '__main__':
    unittest.main()
