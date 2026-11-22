import copy
import hashlib
from pathlib import Path
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import build_python_tooling
from build_python_tooling import normal_build_catalog, PythonTooling


class NormalCatalogTests(unittest.TestCase):
    def test_first_selection_checks_source_before_and_after_install(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            def reference(path):
                data = path.read_bytes()
                return dict(path=str(path), bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
                            mode=path.stat().st_mode & 0o777)
            modules = {}
            for role in ('build_wiktionaries', 'corpus_controller'):
                path = root / (role + '.py')
                path.write_text('VALUE = 1\n')
                modules[role] = reference(path)
            st = root.stat()
            directory = dict(path=str(root), device=st.st_dev, inode=st.st_ino,
                             uid=st.st_uid, mode=st.st_mode & 0o777)
            spec = dict(source_root=directory, workspace_root=directory,
                        selector=reference(Path(build_python_tooling.__file__)), modules=modules)
            role = 'build_wiktionaries'
            path = Path(modules[role]['path'])
            def select(origin=path):
                return build_python_tooling.select(spec, role=role, origin=origin)
            with (patch.object(build_python_tooling, '_ACTIVE', None),
                  patch.dict(build_python_tooling.sys.modules),
                  patch.object(PythonTooling, 'install') as install,
                  patch.object(build_python_tooling, '_regular', wraps=build_python_tooling._regular) as read):
                for name in modules:
                    build_python_tooling.sys.modules.pop(name, None)
                with self.assertRaisesRegex(ValueError, 'differs from selected tooling role'):
                    select(root / 'other.py')
                install.assert_not_called()
                read.reset_mock()
                install.side_effect = lambda: self.assertEqual(read.call_count, len(modules) + 1)
                active = select()
                self.assertEqual(read.call_count, 2 * (len(modules) + 1))
                self.assertIs(select(), active)
                self.assertEqual(read.call_count, 3 * (len(modules) + 1))
                install.assert_called_once()
                path.write_text('VALUE = 2\n')
                with self.assertRaisesRegex(ValueError, 'identity changed'):
                    select()
                path.write_text('VALUE = 1\n')
                build_python_tooling._ACTIVE = None
                install.side_effect = lambda: path.write_text('VALUE = 3\n')
                with self.assertRaisesRegex(ValueError, 'identity changed'):
                    select()

    def test_unused_stale_qa_is_omitted_without_changing_required_refs(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            def source(name, text):
                path = root / (name + '.py')
                path.write_text(text)
                return dict(path=str(path), bytes=path.stat().st_size,
                            sha256=hashlib.sha256(path.read_bytes()).hexdigest(), mode=0o644)
            modules = dict(build_wiktionaries=source('build_wiktionaries', 'import helper\n'),
                           corpus_controller=source('corpus_controller', 'VALUE = 1\n'),
                           helper=source('helper', 'VALUE = 2\n'),
                           verify_reader_ux=source('verify_reader_ux', 'VALUE = 3\n'),
                           verify_wikimedia=source('verify_wikimedia', 'VALUE = 4\n'),
                           verify_wikimedia_test=source('verify_wikimedia_test', 'import verify_wikimedia\n'))
            selector = Path(build_python_tooling.__file__)
            st = root.stat()
            directory = dict(path=str(root), device=st.st_dev, inode=st.st_ino,
                             uid=st.st_uid, mode=st.st_mode & 0o777)
            spec = dict(modules=modules, source_root=directory, workspace_root=directory,
                        selector=dict(path=str(selector), bytes=selector.stat().st_size,
                            sha256=hashlib.sha256(selector.read_bytes()).hexdigest(),
                            mode=selector.stat().st_mode & 0o777))
            original = copy.deepcopy(spec)
            Path(modules['verify_reader_ux']['path']).write_text('changed QA\n')
            Path(modules['verify_wikimedia_test']['path']).unlink()
            selected = normal_build_catalog(spec)
            self.assertEqual(spec, original)
            self.assertEqual(selected['modules'], {k: modules[k] for k in ('build_wiktionaries', 'corpus_controller', 'helper')})
            tooling = PythonTooling(selected)
            tooling.require_unchanged()
            Path(modules['helper']['path']).write_text('changed required\n')
            with self.assertRaisesRegex(ValueError, 'identity changed'):
                tooling.require_unchanged()

    def test_import_and_subprocess_reference_prevent_omission(self):
        for text in ('import verify_reader_ux\n', 'from verify_reader_ux import main\n',
                     'script = "tools/verify_edition_terminal.py"\n',
                     'script = "compiler/tools/verify_edition_terminal.py"\n',
                     'from . import verify_wikimedia\n',
                     'from .tools import verify_wikimedia\n',
                     'from tools.verify_wikimedia import API\n',
                     'import tools.verify_wikimedia\n',
                     'from compiler.tools.verify_wikimedia import API\n',
                     'import compiler.tools.verify_wikimedia\n',
                     'script = "compiler/tools/verify_" "wikimedia_test.py"\n',
                     'script = "tools/verify_" "wikimedia_test.py"\n'):
            with self.subTest(text=text), tempfile.TemporaryDirectory() as folder:
                path = Path(folder) / 'builder.py'
                path.write_text(text)
                reference = dict(path=str(path), bytes=path.stat().st_size,
                                 sha256=hashlib.sha256(path.read_bytes()).hexdigest(), mode=0o644)
                spec = dict(modules=dict(build_wiktionaries=reference,
                    corpus_controller=reference, verify_reader_ux={}, verify_edition_terminal={},
                    verify_wikimedia={}, verify_wikimedia_test={}))
                with self.assertRaisesRegex(ValueError, 'references excluded QA'):
                    normal_build_catalog(spec)


class SelectedRepositoryLayoutTests(unittest.TestCase):
    def test_metadata_loader_rebinds_only_the_authenticated_original_root(self):
        for tools in ('tools', 'compiler/tools'):
            for rebound in (False, True):
                with self.subTest(tools=tools, rebound=rebound), tempfile.TemporaryDirectory() as folder:
                    root = Path(folder).resolve()
                    module_path = root / tools / 'prepare_file_metadata.py'
                    module_path.parent.mkdir(parents=True)
                    value = "Path('/unbound-root')" if rebound else 'Path(__file__).resolve().parent.parent'
                    module_path.write_text('from pathlib import Path\nREPO = ' + value + '\n')
                    raw = module_path.read_bytes()
                    reference = dict(path=str(module_path), bytes=len(raw),
                                     sha256=hashlib.sha256(raw).hexdigest(), mode=0o644)
                    selected_root = root / '.tmp' / 'selected-source'
                    (selected_root / tools).mkdir(parents=True)
                    dependency_root = selected_root / 'compiler' if tools == 'compiler/tools' else selected_root
                    selection = SimpleNamespace(source_root=selected_root,
                        spec={'modules': {'prepare_file_metadata': reference}}, require_unchanged=Mock())
                    module = ModuleType('prepare_file_metadata')
                    loader = build_python_tooling._SourceLoader(selection, module.__name__)
                    if rebound:
                        with self.assertRaisesRegex(ValueError, 'already rebound'):
                            loader.exec_module(module)
                        selection.require_unchanged.assert_not_called()
                    else:
                        loader.exec_module(module)
                        self.assertEqual(module.REPO, dependency_root)
                        self.assertEqual(module.__file__, str(module_path))
                        selection.require_unchanged.assert_called_once_with()

    def test_prepared_imports_remove_both_layouts_without_admitting_foreign_paths(self):
        import sys
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            tooling = object.__new__(PythonTooling)
            tooling.workspace_root = root
            tooling.source_root = root / '.tmp' / 'selected-source'
            standard = [sys._stdlib_dir, sys._stdlib_dir + '/lib-dynload']
            fallbacks = [str(parent / tools) for parent in (root, tooling.source_root)
                         for tools in ('tools', 'compiler/tools')]
            with patch.object(sys, 'path', [*fallbacks, *standard]):
                tooling.require_prepared_imports()
                self.assertEqual(sys.path, standard)
                sys.path.insert(0, str(root / 'unselected-tools'))
                with self.assertRaisesRegex(ValueError, 'import roots changed'):
                    tooling.require_prepared_imports()
            with patch.object(sys, 'path', list(reversed(standard))):
                with self.assertRaisesRegex(ValueError, 'order changed'):
                    tooling.require_prepared_imports()


if __name__ == '__main__':
    unittest.main()
