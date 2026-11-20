"""Explicit invocation-local Python tooling over a separately bound native tree.

Only named source modules are imported; no bytecode or replacement source tree is
created. Native executable producer provenance belongs to the existing role API.
"""
import ast
import hashlib
import importlib.abc
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys

_ACTIVE = None


def normal_build_catalog(spec):
    """Exclude verification entry points unused by the normal producer.

    Selection remains explicit: consumers still authenticate every retained
    module. Refuse narrowing if any retained source names a removed entry point.
    """
    result = json.loads(json.dumps(spec))
    modules = result['modules']
    omitted = {
        'verify_reader_ux', 'verify_reader_navigation', 'verify_edition_terminal', 'verify_terminal',
        'verify_wikimedia', 'verify_wikimedia_test', 'validate_corpus_test',
        'category_stats_snapshot_test', 'category_tree_snapshot_test', 'namespace_registry_snapshot_test',
    } & modules.keys()
    for name, reference in modules.items():
        if name in omitted:
            continue
        path, data = _regular(reference)
        for node in ast.walk(ast.parse(data, filename=str(path))):
            if isinstance(node, ast.Import):
                referenced = any(not omitted.isdisjoint(item.name.split('.')) for item in node.names)
            elif isinstance(node, ast.ImportFrom):
                referenced = not omitted.isdisjoint((node.module or '').split('.')) or any(
                    item.name in omitted for item in node.names)
            elif isinstance(node, ast.Constant) and isinstance(node.value, str):
                referenced = any(candidate in node.value for candidate in omitted)
            else:
                continue
            if referenced:
                raise ValueError('Normal build source references excluded QA: ' + str(path))
    for name in omitted:
        del modules[name]
    return result


def _regular(reference):
    if not isinstance(reference, dict) or set(reference) != {'path', 'bytes', 'sha256', 'mode'}:
        raise ValueError('Invalid selected Python source reference')
    path = Path(reference['path'])
    if (not path.is_absolute() or str(path) != os.path.normpath(str(path))
            or any(p.is_symlink() for p in (path, *path.parents))):
        raise ValueError('Selected Python source path is not canonical')
    with path.open('rb') as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid():
            raise ValueError('Selected Python source is not an owned regular file')
        data = stream.read()
        after = os.fstat(stream.fileno())
    fields = ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns', 'st_mode')
    named = path.stat()
    if (any(getattr(before, k) != getattr(after, k) or getattr(before, k) != getattr(named, k) for k in fields)
            or len(data) != reference['bytes'] or stat.S_IMODE(before.st_mode) != reference['mode']
            or hashlib.sha256(data).hexdigest() != reference['sha256']):
        raise ValueError('Selected Python source identity changed: ' + str(path))
    return path, data


def _directory(reference):
    if not isinstance(reference, dict) or set(reference) != {'path', 'device', 'inode', 'uid', 'mode'}:
        raise ValueError('Invalid selected tooling directory identity')
    path = Path(reference['path'])
    if (not path.is_absolute() or str(path) != os.path.normpath(str(path))
            or any(p.is_symlink() for p in (path, *path.parents)) or not path.is_dir()):
        raise ValueError('Selected tooling directory is not canonical')
    value = path.stat()
    if (value.st_dev, value.st_ino, value.st_uid, stat.S_IMODE(value.st_mode)) != tuple(reference[k] for k in ('device', 'inode', 'uid', 'mode')) or value.st_uid != os.geteuid():
        raise ValueError('Selected tooling directory changed')
    return path


class _SourceLoader(importlib.abc.Loader):
    def __init__(self, selection, name):
        self.selection, self.name = selection, name

    def create_module(self, spec):
        return None

    def exec_module(self, module):
        reference = self.selection.spec['modules'][self.name]
        path, data = _regular(reference)
        module.__file__ = str(path)
        module.__cached__ = None
        exec(compile(data, str(path), 'exec'), module.__dict__)
        if self.name == 'prepare_file_metadata':
            if module.REPO != path.resolve().parent.parent:
                raise ValueError('Selected metadata repository was already rebound')
            module.REPO = self.selection.source_root
        self.selection.require_unchanged()


class _SourceFinder(importlib.abc.MetaPathFinder):
    def __init__(self, selection):
        self.selection = selection

    def find_spec(self, fullname, path=None, target=None):
        if getattr(self.selection,'_prepared_standard_paths',None) is not None:
            self.selection.require_prepared_imports()
        if fullname in self.selection.spec['modules']:
            reference = self.selection.spec['modules'][fullname]
            return importlib.util.spec_from_loader(fullname, _SourceLoader(self.selection, fullname), origin=reference['path'])
        return None


class PythonTooling:
    def __init__(self, spec):
        if not isinstance(spec, dict) or set(spec) != {'source_root', 'workspace_root', 'selector', 'modules'}:
            raise ValueError('Invalid explicit Python tooling selection')
        self.spec = json.loads(json.dumps(spec))
        self.source_root = _directory(spec['source_root'])
        self.workspace_root = _directory(spec['workspace_root'])
        if (self.source_root != self.workspace_root
                and not self.source_root.is_relative_to(self.workspace_root / '.tmp')):
            raise ValueError('Selected native source is outside its workspace')
        modules = spec['modules']
        if (not isinstance(modules, dict) or not {'build_wiktionaries', 'corpus_controller'} <= modules.keys()
                or not modules or len(modules) > 512):
            raise ValueError('Missing selected production scripts')
        for name in modules:
            if not name.isidentifier() or name.startswith('test_') or '.' in name:
                raise ValueError('Invalid selected project module name')
        self.require_unchanged()

    def require_prepared_imports(self):
        """Keep the existing catalog exclusive in an authorized prepared scope.

        Some qualified collectors insert their known tools directory themselves.
        Remove only that redundant fallback route; all other path changes fail.
        The finder calls this before any fallback can execute an unselected name.
        """
        allowed=(sys._stdlib_dir,sys._stdlib_dir+'/lib-dynload',
                 str(Path(sys.base_prefix)/'lib'/('python%d%d.zip' % sys.version_info[:2])))
        tools={str(self.source_root/'tools'),str(self.workspace_root/'tools')}
        standard=[entry for entry in sys.path if entry not in tools]
        if (not all(entry in allowed for entry in standard) or len(standard)!=len(set(standard))
                or sys._stdlib_dir not in standard or sys._stdlib_dir+'/lib-dynload' not in standard):
            raise ValueError('Prepared selected Python import roots changed')
        previous=getattr(self,'_prepared_standard_paths',None)
        if previous is not None and standard!=previous:
            raise ValueError('Prepared selected Python import root order changed')
        self._prepared_standard_paths=list(standard)
        sys.path[:]=standard
        return self

    def require_unchanged(self):
        if getattr(self,'_prepared_standard_paths',None) is not None:self.require_prepared_imports()
        if _directory(self.spec['source_root']) != self.source_root or _directory(self.spec['workspace_root']) != self.workspace_root:
            raise ValueError('Selected tooling roots changed')
        _regular(self.spec['selector'])
        for reference in self.spec['modules'].values():
            _regular(reference)
        for name, module in tuple(sys.modules.items()):
            origin = getattr(module, '__file__', None)
            if origin is None or name == 'wikidict_python_tooling':
                continue
            path = Path(origin).absolute()
            if name == '__main__' and path in {Path(self.spec['modules'][role]['path']) for role in ('build_wiktionaries', 'corpus_controller')}:
                continue
            reference = self.spec['modules'].get(name)
            if reference is not None:
                if path != Path(reference['path']):
                    raise ValueError('Loaded project module differs from selected source: ' + name)
            elif path.is_relative_to(self.workspace_root) and path.suffix in ('.py', '.pyc'):
                raise ValueError('Unbound project Python module: ' + name)
        return self.spec

    def require_role(self, role, origin):
        self.require_unchanged()
        return self._check_role_origin(role, origin)

    def _check_role_origin(self, role, origin):
        if role not in ('build_wiktionaries', 'corpus_controller') or Path(origin).resolve() != Path(self.spec['modules'][role]['path']):
            raise ValueError('Actual production script differs from selected tooling role')
        return self

    def install(self):
        # The absent startup prefix excludes prior unbound bytecode consumption.
        if (not sys.flags.isolated or not sys.flags.no_site or not sys.dont_write_bytecode
                or not sys.pycache_prefix or not Path(sys.pycache_prefix).is_absolute()
                or os.path.lexists(sys.pycache_prefix)):
            raise ValueError('Selected Python tooling requires isolated no-site -B with an absent startup bytecode prefix')
        sys.path[:] = [p for p in sys.path if p and not Path(p).absolute().is_relative_to(self.workspace_root)]
        if sys._xoptions.get('wikidict_prepared_source')=='1':self.require_prepared_imports()
        sys.meta_path.insert(0, _SourceFinder(self))
        return self


def select(spec, *, role, origin):
    global _ACTIVE
    if _ACTIVE is None:
        selected = PythonTooling(spec)
        # Construction already verified the entire catalog. Check the script
        # before installing its finder, then revalidate after installation.
        selected._check_role_origin(role, origin)
        selected.install()
        _ACTIVE = selected
    elif _ACTIVE.spec != spec:
        raise ValueError('Python tooling cannot change within an invocation')
    return _ACTIVE.require_role(role, origin)
