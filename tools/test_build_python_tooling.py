import copy
import hashlib
from pathlib import Path
import tempfile
import unittest

import build_python_tooling
from build_python_tooling import normal_build_catalog, PythonTooling


class NormalCatalogTests(unittest.TestCase):
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
                           verify_reader_ux=source('verify_reader_ux', 'VALUE = 3\n'))
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
            selected = normal_build_catalog(spec)
            self.assertEqual(spec, original)
            self.assertEqual(selected['modules'], {k: v for k, v in modules.items() if k != 'verify_reader_ux'})
            tooling = PythonTooling(selected)
            tooling.require_unchanged()
            Path(modules['helper']['path']).write_text('changed required\n')
            with self.assertRaisesRegex(ValueError, 'identity changed'):
                tooling.require_unchanged()

    def test_import_and_subprocess_reference_prevent_omission(self):
        for text in ('import verify_reader_ux\n', 'from verify_reader_ux import main\n',
                     'script = "tools/verify_edition_terminal.py"\n'):
            with self.subTest(text=text), tempfile.TemporaryDirectory() as folder:
                path = Path(folder) / 'builder.py'
                path.write_text(text)
                reference = dict(path=str(path), bytes=path.stat().st_size,
                                 sha256=hashlib.sha256(path.read_bytes()).hexdigest(), mode=0o644)
                spec = dict(modules=dict(build_wiktionaries=reference,
                    corpus_controller=reference, verify_reader_ux={}, verify_edition_terminal={}))
                with self.assertRaisesRegex(ValueError, 'references terminal QA'):
                    normal_build_catalog(spec)


if __name__ == '__main__':
    unittest.main()
